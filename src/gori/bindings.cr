require "./env"
require "./intercept_filter"
require "./store"
require "./token_extract"
require "./proxy/extractor"
require "./proxy/codec/http1"
require "./repeater/engine"
require "./session_slots"

module Gori
  # Session bindings (#501): named values observed from a response and resolved into
  # outgoing requests at SEND time.
  #
  #   extraction observes, injection rewrites, and a binding is the only thing between
  #   them. Injection is not a new rule kind — it is the existing rewrite with its
  #   replacement resolved late.
  #
  # So this class owns exactly two things: the persisted `extract_rules` (the READ half)
  # and an IN-MEMORY name→value table (the binding itself). The WRITE half is an ordinary
  # `Store::MatchRule` whose `replacement` says `$NAME`, plus the four send seams that
  # resolve `$NAME` on their way to the socket.
  #
  # **The rule persists; the value never does.** Not in `settings.json`, and — unlike
  # `oast_sessions` — not in the project DB either. Two reasons, and the second is the
  # real one: a restored token is stale by construction (minutes to days old on reopen)
  # and injecting it produces exactly the 401s this feature exists to remove; and
  # re-extracting costs one request, so there is nothing to save.
  #
  # The guarantee is BOUNDED and stated as such: gori never WRITES a binding value into
  # `settings.json`, the project DB, the event feed, an issue, a note, or a log line. It
  # DOES appear in captured traffic, because that is where it came from — masking a
  # capture would be a P7 violation, not a fix. The same exception covers an author's own
  # bytes: a request draft in which the OPERATOR (TUI editor, `gori run repeater`) or an
  # AGENT (MCP `create_repeater`/`update_repeater`) typed the value is stored as typed.
  # Rewriting a draft to `$NAME` is that same P7 violation one surface earlier, and it split
  # the surfaces apart — see `MCP::Tools#stored_request`.
  #
  # One instance is SHARED between the TUI (which edits rules and reads the table), the
  # Repeater send path (which writes it) and every send seam (which reads it), so a Mutex
  # guards both the rule snapshot and the value table. Same contract as `Rules`.
  class Bindings < Env::Layer
    include Proxy::ResponseExtract

    # What one name looks like to a readout. `value` is the raw bound value and is only
    # ever handed to a surface that masks it (`preview`) or to an explicit one-row reveal;
    # nothing here goes near a log line or an event message.
    record Row,
      name : String,
      rule_id : Int64,
      host : String,
      descriptor : String,
      enabled : Bool,
      value : String?,
      bound_at : Time?,
      # Which SESSION SLOT's table this value lives in, or nil for the one global table. A
      # rule no slot claims yields exactly one row (nil); a rule two slots claim yields one
      # row per slot, because it genuinely holds two values and a readout that folded them
      # would have to pick one identity's credential to show.
      slot : String? = nil do
      def bound? : Bool
        !value.nil?
      end

      # First 4 / last 4 with the length in between — enough to tell two tokens apart and
      # to confirm a rebind happened, without printing a credential. `env_value_preview`
      # truncating to 20 characters showed the first 19, which is fine for `$HOST` and
      # wrong for a session cookie; this is the shape that is right for both.
      def preview : String
        v = value
        return "—" unless v
        Bindings.mask_preview(v)
      end
    end

    # A rule with everything it needs precompiled. The `InterceptFilter` compiles its
    # `FilterAst` tree once (it is the same backend the conditional-intercept bar uses on
    # the proxy path), and a Regex-kind descriptor compiles its pattern once — the same
    # thing `Sequencer::Engine#run_live` does per run, for the same reason.
    private record Compiled,
      rule : Store::ExtractRule,
      filter : InterceptFilter,
      re : Regex? do
      # Does this rule need the response ENTITY buffered? Two independent reasons, and only the
      # first used to be counted: the rule's extraction TARGET may be body-scoped, and so may its
      # CONDITION. A `body:` term cannot be answered without the bytes, and a `-body:` one cannot
      # be answered SAFELY without them — with nothing buffered it evaluates false and negates to
      # a match on every response. Counting the target alone left a rule whose own condition read
      # the body being asked about a body nobody had buffered.
      def wants_body? : Bool
        rule.enabled? && (rule.body_scoped? || filter.mentions_body?)
      end
    end

    # A name's live value plus where it came from. `rule_id` is what lets the readout say
    # WHICH rule wrote a name after the operator has edited several.
    private record Bound, value : String, rule_id : Int64, at : Time

    # Bytes that would forge a message boundary out of a value, so a value carrying one is
    # never bound. `Import::Builder::HEADER_INJECT`, deliberately the same set and the same
    # reasoning: only CR/LF/NUL, because a value may legally contain a horizontal tab and
    # bytes that merely break a value without forging a boundary are not this feature's
    # business.
    #
    # ## Why this is a refusal and not a P7 passthrough
    #
    # The axis is PROVENANCE. Everywhere else in this codebase a malformed value is the
    # OPERATOR'S PAYLOAD and is replayed byte-exact — an imported target, a hand-typed header,
    # a Repeater template. A binding value is the ORIGIN'S, and it is spliced into a request
    # gori then sends: `Rules#substitute` writes it into `Authorization: <value>`, so
    # `abc\r\nX-Admin: true` becomes two header lines and `abc\r\n\r\nGET /...` forges a whole
    # second request onto a pooled keep-alive upstream. `rules.cr` already reasons about a
    # binding value being re-interpreted downstream — that is what `escape_backrefs` is for —
    # and covers `gsub`'s replacement grammar only; the message boundary is the other half.
    #
    # ## Why it is asked at the INJECTION SITE and not at extraction
    #
    # Refusing at extraction was the first answer and it was too wide. `Env.expand_bindings`
    # states that "injecting a token into a body is a designed case (a `Replace` rule with
    # `part: Body`, an operator's Repeater template)", and CR/LF in a BODY forges nothing — a
    # PEM block, a SAML assertion, a formatted JSON sub-document are all legitimate values for
    # exactly that case. So the value is bound either way and the refusal lives where the
    # boundary exists: the head half of a message, and any short field that lands on the
    # request line. `Env.expand_bindings` splits the message and applies it to the head only;
    # `Rules#substitute` applies it for the head ops and the head part.
    #
    # A BYTE scan and not a Regex: a header value or a `position` slice can carry bytes that
    # are not valid UTF-8, and Crystal's Regex raises `ArgumentError` on such a subject — which
    # would turn this guard into an exception on exactly the input it exists to stop.
    def self.boundary_forging?(value : String) : Bool
      value.each_byte do |b|
        return true if b == 0x0d_u8 || b == 0x0a_u8 || b == 0x00_u8
      end
      false
    end

    # Which boundary-forging byte classes `value` carries, named the way an operator reads
    # them ("CR", "LF", "NUL"), in that order. Empty exactly when `boundary_forging?` is false.
    #
    # A SECOND pass and not a widening of the predicate above: that one answers a yes/no per
    # resolved key on the proxy request path and must not allocate, while this one runs only
    # once a refusal has already fired and is going to write an `events` row. A refusal that
    # does not name what it found is barely better than silence — #491's lesson — and "a stray
    # CR" is the difference between an operator editing their extract rule and an operator
    # concluding gori is broken.
    def self.boundary_bytes(value : String) : Array(String)
      cr = lf = nul = false
      value.each_byte do |b|
        case b
        when 0x0d_u8 then cr = true
        when 0x0a_u8 then lf = true
        when 0x00_u8 then nul = true
        end
      end
      found = [] of String
      found << "CR" if cr
      found << "LF" if lf
      found << "NUL" if nul
      found
    end

    @rules : Array(Store::ExtractRule)
    @compiled : Array(Compiled)
    # The GLOBAL table: every rule no session slot claims writes here, which before slots
    # existed was every rule there is. Keeping it as its own table rather than folding it into
    # a nil-named slot is the compatibility statement — with no slots configured this class
    # behaves exactly as it did, down to the lock-free counts.
    @values : Hash(String, Bound)
    # The PER-SLOT tables, `slot name => (binding name => value)`. Created lazily on the first
    # observation into a slot, so a project whose slots are pure header overlays allocates
    # none of them. Values here are memory-only for the same reason the global table's are —
    # see the class doc; a slot changes WHERE a value lives, never WHETHER it persists.
    @slot_values : Hash(String, Hash(String, Bound))

    def initialize(@store : Store, rules : Array(Store::ExtractRule),
                   @slots : SessionSlots? = nil)
      @mutex = Mutex.new
      @rules = rules
      @compiled = compile(rules)
      @values = {} of String => Bound
      @slot_values = {} of String => Hash(String, Bound)
      @rev = 0_u64
      # Lock-free fast-path counts, the same pattern and for the same reason as `Rules`'
      # (`rules.cr`): slice 2 puts this object on the PROXY RESPONSE PATH, where the common
      # case is no extract rule at all. `@enabled_count` lets a response skip the mutex + the
      # select-array allocation entirely; `@body_count` additionally decides whether ClientConn
      # BUFFERS a response body that would otherwise stream, which is the expensive half (P6).
      @enabled_count = Atomic(Int32).new(rules.count(&.enabled?))
      @body_count = Atomic(Int32).new(@compiled.count(&.wants_body?))
      # Rule ids already reported as needing an entity that was not buffered, at that rule
      # revision — see `miss_no_entity`.
      @no_entity_reported = Set(Int64).new
      # Rule ids already reported as having read a body that is not valid UTF-8, at that rule
      # revision — see `report_scrubbed`.
      @scrub_reported = Set(Int64).new
      # Rule ids that already reported a plain miss at binding revision `@miss_reported_rev`
      # — see `report_miss?`.
      @miss_reported = Set(Int64).new
      @miss_reported_rev = 0_u64
      # A per-slot table is keyed by the slot's NAME and nothing else, so a deleted slot's
      # table has to go with the slot: an operator who deletes `admin` and creates a new
      # `admin` for a different identity would otherwise send the DELETED identity's live
      # credential, out of a table the new slot never wrote.
      @slots.try &.on_slots_changed = ->prune_slots(Array(String)?)
    end

    # Drop every per-slot table whose slot is gone, keyed on the surviving NAMES — the same
    # shape `refresh` uses for rule names. Called by `SessionSlots` after a list write, from
    # OUTSIDE its mutex (see `values` on why the two must never nest).
    #
    # Prune only: a RENAME lands here as a delete plus an add, and the renamed slot correctly
    # starts empty for the same reason a freshly created one does — `SessionSlots#save` has
    # already dropped the active pointer for it (spec/session_slots_spec.cr).
    #
    # `nil` means the caller cannot vouch for ANY name and every table goes. That is the
    # out-of-process case: a peer's delete plus re-add collapse into one row by the time
    # `SessionSlots#reload` reads it, so a name present on both sides proves nothing about
    # whether it is still the same identity (see the reasoning there).
    def prune_slots(surviving : Array(String)?) : Nil
      @mutex.synchronize do
        next if @slot_values.empty?
        if surviving
          @slot_values.reject! { |name, _| !surviving.includes?(name) }
        else
          @slot_values.clear
        end
        @rev &+= 1
      end
    end

    def self.load(store : Store, slots : SessionSlots? = nil) : Bindings
      new(store, store.extract_rules, slots)
    end

    # The project's session slots, or nil when this table is running without them (a spec, a
    # `gori run` that never opened a project). Every slot-aware branch below degrades to the
    # pre-slot behaviour on nil, which is the same thing it does when the list is empty.
    def slots : SessionSlots?
      @slots
    end

    # ── Env::Layer ────────────────────────────────────────────────────────────

    # Names declared by an ENABLED rule. A disabled rule declares nothing: its name goes
    # back to being an ordinary unknown key, which plan-build then refuses by #525's rule.
    # That is deliberate — disabling the writer must not leave the reader silently
    # injecting a stale value, and it must not leave `$SESSION` sailing out literally
    # either.
    def declared : Array(String)
      @mutex.synchronize { @compiled.select(&.rule.enabled?).map(&.rule.name) }
    end

    # The OTHER half of `declared`: `{name => rule id}` for every rule that is switched OFF.
    #
    # `declared` filtering on `enabled?` is what makes plan-build refuse `$NAME` when its
    # writer is disabled, and that refusal is right. What was wrong is the sentence it
    # produced: with nothing able to tell "this name has no writer at all" from "this name's
    # writer is one keystroke away from being back on", every surface fell through to the
    # generic env remedy and told the operator to run `gori run project env set TOKEN <value>`
    # — which PERSISTS a live session token into the project DB, the precise outcome the class
    # doc above says this feature exists to prevent, and stale on the next run besides.
    #
    # Returns the id so the refusal can name the exact `rewriter extract enable N`.
    def disabled_rule_ids : Hash(String, Int64)
      @mutex.synchronize do
        h = {} of String => Int64
        @rules.each { |r| h[r.name] = r.id unless r.enabled? }
        h
      end
    end

    # Values an ENABLED rule declares. This is what `Env.expand_bindings` and
    # `Rules#substitute` resolve `$NAME` against, so the enabled test has to be HERE and not
    # only on `declared`: `substitute` asks `vars.has_key?(key)` FIRST and emits the value it
    # finds, so an unfiltered table left every reader — the proxy Match&Replace path most of
    # all, which has no plan-build refusal in front of it — silently injecting the stale value
    # of a rule the operator had switched off. That is the outcome `declared` above documents
    # as ruled out, so both halves now answer the same question.
    #
    # The value itself SURVIVES in `@values` (see `refresh`): toggling a rule off and back on
    # must not lose the token. `rows` and `bound?` read that table directly, which is what
    # keeps the Bindings pane showing a disabled rule's value while nothing resolves it.
    #
    # SLOT-AWARE, and this is the read half of "the active slot is the send context": the
    # global table first, then the ACTIVE slot's table written over it. A slot therefore
    # SHADOWS a global name rather than being a separate namespace an operator has to spell —
    # `$SESSION` means one thing in a request and the active slot decides which session that
    # is. With no slot active (the default, and `as-captured`) this is the global table alone,
    # byte for byte the answer this method gave before slots existed.
    def values : Hash(String, String)
      # OUTSIDE `@mutex`: `SessionSlots` has its own, and the two must never nest — see
      # `candidates`. Nothing here needs the two snapshots to be atomic with each other; a
      # slot switching between these two lines resolves the next send, not this one.
      slot = @slots.try(&.active)
      @mutex.synchronize do
        live = Set(String).new
        @rules.each { |r| live << r.name if r.enabled? }
        h = {} of String => String
        @values.each { |(k, b)| h[k] = b.value if live.includes?(k) }
        if slot && (table = @slot_values[slot.name]?)
          table.each { |(k, b)| h[k] = b.value if live.includes?(k) }
        end
        h
      end
    end

    # Every value held, enabled or not — the MASKING half of the split above. A token whose
    # rule the operator switched off stops resolving, but it was still observed from a real
    # response and is still in memory, so `Env.mask_secrets` must keep redacting it out of
    # everything the operator AUTHORS. See `Env.masking_vars`.
    #
    # Which is: an issue's title / host / notes (`mcp/tools/issues.cr`, `cli/run/issues.cr`), a
    # Repeater tab's target / request / name / tags (`mcp/tools/repeater.cr`,
    # `cli/run/repeater.cr`) and a WS message an operator composed (`store/repeater_sessions.cr`).
    # NOT an export and NOT the flow detail view, and that is deliberate rather than a gap: both
    # render CAPTURED bytes, which is the exception the class doc above states — masking a
    # capture would be a P7 violation, not a fix. (This comment used to name exports and the
    # detail view; it named two surfaces that must never call this, and no surface that does.)
    # Every slot's table too, and NOT merged by name: two slots holding two different
    # `$SESSION` values are two secrets, and a Hash keyed on the name alone would mask one of
    # them and print the other. A slot's entries are keyed `NAME@slot`, so `mask_secrets`
    # redacts both and says which identity's token it found — the readout is `$SESSION@admin`,
    # which is not a resolvable token and is not meant to be. Masking is a display path; the
    # RESOLUTION path is `values` above, where a name is a name.
    def held_values : Hash(String, String)
      @mutex.synchronize do
        h = {} of String => String
        @values.each { |(k, b)| h[k] = b.value }
        @slot_values.each do |(slot, table)|
          table.each { |(k, b)| h["#{k}@#{slot}"] = b.value }
        end
        h
      end
    end

    # ── Env::Layer, the OVERLAY half ──────────────────────────────────────────

    # The active slot's header overlay, applied to wire bytes at a send seam. Returns the
    # same slice when no slot is active, which is `as-captured` — the no-overlay baseline.
    #
    # `$NAME` inside a slot's own header VALUE resolves here, against `values` above — so the
    # "admin" slot's `Authorization: Bearer $SESSION` means admin's `$SESSION` and the "user"
    # slot's means user's, off one persisted string each. `guard_boundary: true` because that
    # resolved value is the ORIGIN'S bytes landing in a header: a CR/LF in it would forge a
    # header line or a whole second request onto a pooled keep-alive upstream, which is the
    # exact case `boundary_forging?` above documents. The operator's own literal header value
    # is NOT guarded — `SessionSlot.overlay_head` copies it verbatim, the same provenance
    # split every other seam in this codebase draws.
    def overlay(wire : Bytes) : Bytes
      slots = @slots
      return wire unless slots
      slots.overlay(wire) { |value| Env.expand_bindings(value, guard_boundary: true) }
    end

    # `Env::Layer#active_slot_name` — the READOUT half of the two methods above. nil is
    # as-captured, which is both the default and the honest answer for a table running
    # without a slot registry (a spec, a `gori run` that never opened a project).
    def active_slot_name : String?
      @slots.try(&.active_name)
    end

    # Bumped on every rule edit and every rebind. Consumers that must not rebuild a merged
    # snapshot per message (`Rules`, on the proxy hot path) cache on this plus
    # `Env.highlight_rev`.
    # A SUM and not just `@rev`: activating a slot changes what `$NAME` resolves to and what
    # a send goes out as, without touching a rule or a value, so a consumer caching on this
    # alone would keep painting the previous identity's snapshot. Both halves only ever
    # increase, so the sum only ever increases — which is the whole contract.
    def rev : UInt64
      @rev &+ (@slots.try(&.rev) || 0_u64)
    end

    # ── rule editing (persists, then refreshes the snapshot) ──────────────────

    def rules : Array(Store::ExtractRule)
      @mutex.synchronize { @rules.dup }
    end

    def enabled_count : Int32
      @mutex.synchronize { @rules.count(&.enabled?) }
    end

    # Why this rule may not be saved, or nil to proceed. Refused at SAVE time and named,
    # the way `upstream_rule_error` refuses — a precedence rule would have been the wrong
    # answer, because "bind from the login response OR the refresh response" is ONE rule
    # with `path:/login OR path:/refresh`, not two rules racing for a name.
    #
    # `except_id` excludes the row being edited from the duplicate-name test.
    #
    # The `position` range lives HERE and not in one surface's argument parsing, because this
    # is the chokepoint all three go through — the CLI's own comment says it calls `Bindings`
    # rather than `store.insert_extract_rule` precisely so it "gets the SAME refusals the TUI
    # and MCP do". While the check sat in MCP's tool layer alone that sentence was false: a
    # `kind=position` rule with no range saved happily from the TUI and the CLI and could
    # never bind (`TokenExtract.position` returns nil for `hi <= lo`), so it logged a miss
    # forever and nothing said why.
    def validate(name : String, kind : Gori::ExtractKind, selector : String,
                 except_id : Int64? = nil, pos_start : Int32 = 0, pos_end : Int32 = 0) : String?
      return "a binding needs a name" if name.empty?
      unless Env.valid_key?(name)
        return "#{name.inspect} is not a valid binding name (letters, digits and _ only, not starting with a digit)"
      end
      if @mutex.synchronize { @rules.any? { |r| r.name == name && r.id != except_id } }
        return "$#{name} is already written by another extract rule — one name, one writer"
      end
      return "a #{kind.label} descriptor needs a selector" if kind_needs_selector?(kind) && selector.empty?
      if kind.position? && pos_end <= pos_start
        return "a position descriptor needs a byte range with an end past its start (got #{pos_start}...#{pos_end})"
      end
      if kind.regex?
        begin
          Regex.new(selector)
        rescue ex : ArgumentError | Regex::Error
          return "regex #{selector.inspect} does not compile: #{ex.message}"
        end
      end
      nil
    end

    private def kind_needs_selector?(kind : Gori::ExtractKind) : Bool
      !kind.position?
    end

    # Returned by `add`/`update` when the STORE refused the write rather than the values being
    # wrong: the project's writer is held by another instance, or a peer added a rule with this
    # `name` since the last refresh and it hit `extract_rules`' UNIQUE(name) (which
    # `insert/update_extract_rule` turn into a no-op rather than a raise). Both are worth
    # retrying, so a caller that distinguishes a transient failure — MCP's PROJECT_BUSY — keys
    # off this exact value; a retry either succeeds or comes back as `validate`'s precise
    # duplicate message once `refresh` has seen the peer's rule.
    STORE_REFUSED = "extract rule NOT saved (project busy, or that name was just taken); it is unchanged"

    # Add a rule. Returns nil on success, or the refusal message.
    def add(name : String, match_filter : String, kind : Gori::ExtractKind,
            selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
            host : String = "") : String?
      if err = validate(name, kind, selector, pos_start: pos_start, pos_end: pos_end)
        return err
      end
      # 0 is `insert_extract_rule`'s "the write was dropped" (its own comment says so), and it
      # was discarded here — so a rule that never landed was reported as added, and the TUI form
      # closed on it.
      return STORE_REFUSED if @store.insert_extract_rule(name, match_filter, kind, selector, pos_start, pos_end, host) == 0
      refresh
      nil
    end

    def update(id : Int64, name : String, match_filter : String, kind : Gori::ExtractKind,
               selector : String = "", pos_start : Int32 = 0, pos_end : Int32 = 0,
               host : String = "") : String?
      if err = validate(name, kind, selector, except_id: id, pos_start: pos_start, pos_end: pos_end)
        return err
      end
      previous = @mutex.synchronize { @rules.find(&.id.==(id)) }
      # BEFORE the rename side effect below, and checked: `update_extract_rule` reports whether
      # the UPDATE landed, and dropping that meant a refused edit still dropped the in-memory
      # value under the old name — an extraction lost for a rename that never happened — while
      # the surface reported `updated: true` for a rule still observing under its old descriptor.
      unless @store.update_extract_rule(id, name, match_filter, kind, selector, pos_start, pos_end, host)
        return STORE_REFUSED
      end
      # A RENAME drops the old name's value rather than carrying it over: the value was
      # observed under the old descriptor, and silently re-labelling it is how a binding
      # would come to disagree with the rule that claims to own it.
      if previous && previous.name != name
        @mutex.synchronize { @values.delete(previous.name) }
      end
      refresh
      nil
    end

    # False when the write did NOT commit (store busy, locked or closing) — the rule is still
    # there and still observing responses. `Rules#remove`'s contract, for the same reason:
    # the store already answers this and dropping the answer is how a surface comes to
    # report work it did not do. It means COMMITTED, not "a row existed" — the store's own
    # contract — so deleting an id that is already gone is still true.
    #
    # The in-memory value is dropped only on a committed delete; `refresh` would restore it
    # anyway on a rollback, but saying so here keeps the two halves from disagreeing.
    def remove(id : Int64) : Bool
      gone = @mutex.synchronize { @rules.find(&.id.==(id)) }
      ok = @store.delete_extract_rule(id)
      @mutex.synchronize { @values.delete(gone.name) } if ok && gone
      refresh
      ok
    end

    # False when the write did NOT commit, or when there is no such rule; see `remove`.
    def toggle(id : Int64) : Bool
      rule = @mutex.synchronize { @rules.find(&.id.==(id)) }
      return false unless rule
      ok = @store.set_extract_rule_enabled(id, !rule.enabled?)
      refresh
      ok
    end

    # Re-read the store snapshot (an MCP / other-instance edit). Same work `refresh` does,
    # exposed so the Rewriter tab can pull external changes on enter, exactly as `Rules#reload`.
    def reload : Nil
      refresh
    end

    # ── the binding table ─────────────────────────────────────────────────────

    # One row per (rule, table it writes). An unscoped rule is one row with `slot: nil`; a
    # rule two slots claim is two rows, one per slot, each carrying that slot's own value.
    def rows : Array(Row)
      slot_names = @slots.try { |s| s.scoped? ? s.slots : nil }
      @mutex.synchronize do
        out = [] of Row
        @rules.each do |r|
          owners = slot_names.try(&.select(&.claims?(r.name)))
          if owners.nil? || owners.empty?
            b = @values[r.name]?
            out << Row.new(r.name, r.id, r.host, r.token_loc.label, r.enabled?,
              b.try(&.value), b.try(&.at))
          else
            owners.each do |slot|
              b = @slot_values[slot.name]?.try(&.[r.name]?)
              out << Row.new(r.name, r.id, r.host, r.token_loc.label, r.enabled?,
                b.try(&.value), b.try(&.at), slot.name)
            end
          end
        end
        out
      end
    end

    # In the CURRENT send context: the active slot's table, else the global one. The same
    # question `values` answers, asked about one name.
    def bound?(name : String) : Bool
      slot = @slots.try(&.active)
      @mutex.synchronize do
        next true if slot && @slot_values[slot.name]?.try(&.has_key?(name))
        @values.has_key?(name)
      end
    end

    # Forget one name (the `bindings` sub-tab's clear action). The RULE is untouched — a
    # cleared name is declared-but-unbound, so the next send naming it refuses rather than
    # going out with a stale value.
    #
    # Clears the name in the CURRENT send context — the active slot's table AND the global
    # one — because both are resolvable through `values` and forgetting only the shadowing
    # half would leave the next send going out with the value underneath it. Other slots'
    # tables are untouched: they are other identities, and the operator asked about this one.
    def clear(name : String) : Nil
      slot = @slots.try(&.active)
      @mutex.synchronize do
        @values.delete(name)
        slot.try { |sl| @slot_values[sl.name]?.try(&.delete(name)) }
        @rev &+= 1
      end
      Env.bump_highlight_rev
    end

    # EVERY table, not only the active slot's: this is the panic button, and a "clear all"
    # that left another identity's live credential in memory would be the one thing an
    # operator pressing it is trying to avoid.
    def clear_all : Nil
      @mutex.synchronize do
        @values.clear
        @slot_values.clear
        @rev &+= 1
      end
      Env.bump_highlight_rev
    end

    # ── extraction ────────────────────────────────────────────────────────────

    # Run every enabled rule whose host glob and condition match this response, and rebind
    # the names that hit. Returns the names rebound (for a status line), never the values.
    #
    # **Only a deliberate single send reaches here.** `Repeater::Sender` documents itself as
    # "a single HAND-AUTHORED send"; `Fuzz::Sender` — the sweep sender for Fuzzer, Miner,
    # Sequencer, Repeater minimize and Probe active — deliberately does not call this. That
    # is a security line, not a scope trim: a sweep sends attacker-shaped payloads, and a
    # response that echoes one back could rebind the operator's session to a payload-derived
    # value which is then injected into every subsequent request. The line between the two
    # is one this codebase had already drawn, at `Repeater::Sender` vs `Fuzz::Sender`.
    #
    # A MISS never clears a binding. The previous value stands and the miss is recorded to
    # the `events` feed at warn level, carrying the rule name and the reason and NEVER the
    # value — `Sequencer::Extract`'s "nil on a miss rather than raising" contract was
    # already right; what was missing is that anybody heard about it.
    def observe(raw : Repeater::Result, subject : InterceptFilter::Subject,
                flow_id : Int64? = nil) : Array(String)
      return [] of String if raw.error
      # Not throttled: one deliberate send is one operator action, and they asked for it.
      run(candidates(subject), raw, flow_id, entity_available: true, throttle: false)
    end

    # ── Proxy::ResponseExtract (the proxy response path, slice 2) ─────────────

    # Both counts are read per response on the proxy path, so both are lock-free.
    def extracts? : Bool
      @enabled_count.get > 0
    end

    def extracts_body? : Bool
      @body_count.get > 0
    end

    # Whether a BODY-scoped extract rule that can actually MATCH `host` is live (#526/#531).
    # `extracts_body?` above answers "is any live", which is the right question for `ClientConn`
    # (already pinned to one host, deciding whether to pay for a buffer) and the WRONG one for
    # the h2 downgrade gate: that gate costs the host its protocol, and a rule scoped to
    # `alpha.test` must not cost `127.0.0.1` anything. Same split, same shape and the same
    # atomic-count fast path as `Rules#rewrites_body_for_host?`.
    #
    # Once per CONNECT, so the mutex here is not on any hot path.
    def extracts_body_for_host?(host : String) : Bool
      return false if @body_count.get == 0 # lock-free fast path
      @mutex.synchronize do
        # `wants_body?`, matching what `@body_count` counts — a rule whose CONDITION reads the
        # body needs the entity on this host just as much as one whose target does.
        @compiled.any? { |c| c.wants_body? && Rules.host_matches?(c.rule.host, host) }
      end
    end

    # A response the proxy DELIVERED to the client. See `Proxy::ResponseExtract` for why the
    # delivered bytes and not the arrived ones, and for the framing contract on the pair.
    #
    # `body` is nil when the response was not buffered (streaming / oversized / the h2 relay).
    # `body_available` is deliberately `!body.nil?` and NOT "the body is non-empty": a buffered
    # response whose body is genuinely empty is a body we HAVE, and a body-scoped rule missing
    # on it is an ordinary miss rather than gori never having offered it one.
    #
    # ## The `ContentDecode` question this settles
    #
    # A body-scoped descriptor runs over the DECODED body, always — `TokenExtract` decodes
    # through `Proxy::Codec::ContentDecode`, and this path reaches it the same way
    # `Repeater::Sender` does in slice 1. There is no per-rule "decode" flag, and that is the
    # answer to the decision the design left open:
    #
    #   * **The two surfaces must not disagree.** The same `TokenLoc` on the same response has
    #     to mean one thing whether a Repeater send or the proxy saw it. A per-rule flag would
    #     make one descriptor mean two things depending on which observer got there first,
    #     which is the drift the design forbade. Here both call the same function.
    #   * **`Position` has no text-only reading at all.** `body[100...140]` over a gzip stream
    #     is forty bytes of DEFLATE. "Document body extraction as text-only" is not a narrower
    #     feature, it is a broken one for two of the five kinds.
    #   * **A flag would re-open the failure class this epic exists to close.** The operator
    #     writes `regex /csrf_token=([a-f0-9]+)/`, the page is gzipped, and the rule silently
    #     never fires unless they also find a checkbox they had no reason to suspect. That is
    #     #488/#489/#491/#493 with an extra step.
    #
    # And the hot-path cost the design was right to ask about is gated in TWO stages, neither
    # of which is a flag:
    #
    #   1. `extracts_body?` — a lock-free atomic. No body-scoped rule anywhere means ClientConn
    #      never buffers a response body at all, so nothing is decoded because nothing is held.
    #   2. the rule's own host glob and `InterceptFilter` condition, evaluated BEFORE any decode
    #      (see the `candidates` call below). This is the structural difference from a
    #      Match&Replace body rule, whose `gsub` runs on EVERY response for a matching host: an
    #      extract descriptor runs only on the responses the operator's condition SELECTS. A
    #      `path:/login AND status:200` rule decodes one response per login, not one per
    #      subresource, and the condition is an opt-in the operator already had to write.
    #
    # Best-effort by contract: an extract rule must never be able to fail a response the client
    # is waiting on, so everything here is caught.
    def observe_response(head : Bytes, body : Bytes?, *,
                         method : String, host : String, target : String,
                         scheme : String, status : Int32, flow_id : Int64? = nil) : Nil
      return unless extracts? # lock-free: nothing configured, nothing allocated
      # `head` and `body` ride along so a rule's CONDITION can read them — this is the one
      # surface handed both, and dropping them here is what used to make `header:`/`body:`
      # answer false against bytes that were sitting in the arguments. Whether a body exists
      # at all is `wants_body?`'s business (see there): a condition naming `body:` is itself a
      # reason to buffer one.
      subject = InterceptFilter::Subject.new(method: method, host: host, target: target,
        scheme: scheme, status: status, head: head, payload: body)
      picked = candidates(subject)
      return if picked.empty?
      # Parsed only now — after the host glob and the condition have both matched. A response
      # no rule claims never pays for this, and neither does one no rule's condition selects.
      raw = Repeater::Result.new(head, body, Proxy::Codec::Http1.parse_response_head(head), 0_i64)
      # Throttled: this runs per RESPONSE, so an unthrottled miss writes one `events` row per
      # message on the response path — see `report_miss?`.
      run(picked, raw, flow_id, entity_available: !body.nil?, throttle: true)
    rescue ex
      ::Log.warn { "extract rules skipped for a proxied response: #{ex.message}" }
    end

    # ── the shared core ───────────────────────────────────────────────────────

    # The enabled rules whose host glob AND condition claim this message. Taken under the lock
    # once; the extraction itself (which decodes a body and can run a regex) runs outside it.
    # A SCOPED rule — one some slot claims — runs only while the slot claiming it is active.
    # That is the whole namespacing decision in one line, and it is deliberately a SELECTION
    # rather than a miss: the rule did not fail to find anything, it was not asked. Reporting
    # it would write one `events` row per response for every identity the operator is not
    # currently using.
    #
    # An UNSCOPED rule (no slot names it) always runs and always writes the global table, so a
    # project with no slots — every project that existed before this — sees the same set of
    # candidates it always did, for the cost of one atomic read.
    #
    # Both slot snapshots are taken BEFORE `@mutex`: `SessionSlots` has a mutex of its own and
    # nesting the two would make the lock order depend on which method you came in through.
    private def candidates(subject : InterceptFilter::Subject) : Array(Compiled)
      slots = @slots
      claimed = nil.as(Set(String)?)
      active = nil.as(SessionSlot?)
      if slots && slots.scoped?
        claimed = slots.claimed_names
        active = slots.active
      end
      @mutex.synchronize do
        @compiled.select do |c|
          next false unless c.rule.enabled? && Rules.host_matches?(c.rule.host, subject.host) && c.filter.matches?(subject)
          next true unless claimed && claimed.includes?(c.rule.name)
          !!active.try(&.claims?(c.rule.name))
        end
      end
    end

    private def run(picked : Array(Compiled), raw : Repeater::Result, flow_id : Int64?,
                    *, entity_available : Bool, throttle : Bool) : Array(String)
      return [] of String if picked.empty?
      bound = [] of String
      now = Time.utc
      # The send context, read ONCE for the whole response: every rule that binds off these
      # bytes belongs to the identity that was active when they arrived, and re-reading per
      # rule could split one response's values across two slots.
      active = @slots.try(&.active)
      # Decided at most ONCE per response and only if a `text_only?` descriptor actually binds
      # off it — the check decodes the entity, so a project of cookie rules never pays for it.
      lossy = nil.as(Bool?)
      picked.each do |c|
        # A body-scoped descriptor on a response gori never buffered cannot possibly match, and
        # saying "found nothing" would blame the selector for gori's own decision. Say which it
        # was — once per rule per revision, because a matching condition over a long-lived SSE
        # stream would otherwise write one row per response.
        if !entity_available && c.rule.body_scoped?
          miss_no_entity(c.rule, flow_id)
          next
        end
        value = Gori::TokenExtract.extract(raw, c.rule.token_loc, c.re)
        if value.nil?
          record_miss(c.rule, "no match", flow_id, throttle)
          next
        end
        if reason = unusable(value)
          record_miss(c.rule, reason, flow_id, throttle)
          next
        end
        # A `regex` / `jsonpath` descriptor can only read the body as text, and Crystal's
        # readers need a valid subject — so on a body that is not valid UTF-8 the descriptor
        # ran over a repaired copy and the value bound is not the bytes the origin sent, while
        # a `cookie`, `header` or `position` descriptor on the SAME response returns them
        # exactly. Bind anyway: a page in a legacy encoding with a CSRF token in it is an
        # ordinary target and refusing would break a case that works today. But say it, because
        # this is the one place a binding's value can differ from its response.
        if c.rule.kind.text_only?
          lossy = Gori::TokenExtract.text_lossy?(raw) if lossy.nil?
          report_scrubbed(c.rule, flow_id) if lossy
        end
        bind(c.rule, value, active, now)
        bound << c.rule.name
      end
      unless bound.empty?
        @mutex.synchronize { @rev &+= 1 }
        # Repaint every `$KEY` token in every open editor: an unbound name paints like an
        # unknown key and a bound one like a set var, and that difference is the operator's
        # only pre-send signal.
        Env.bump_highlight_rev
      end
      bound
    end

    # Write one observed value into the table it belongs in: the ACTIVE slot's when that slot
    # claims this rule, else the global one. `candidates` has already refused every other
    # combination, so this is a two-way choice rather than a search.
    private def bind(rule : Store::ExtractRule, value : String, active : SessionSlot?,
                     now : Time) : Nil
      owner = (active && active.claims?(rule.name)) ? active.name : nil
      @mutex.synchronize do
        table = owner ? (@slot_values[owner] ||= {} of String => Bound) : @values
        table[rule.name] = Bound.new(value, rule.id, now)
      end
    end

    # Why an extracted value may not be bound, or nil to bind it. A value that HIT but cannot
    # be used is still a miss — the previous binding stands and the operator is told which it
    # was, rather than being left to wonder why `$NAME` did not move.
    private def unusable(value : String) : String?
      return "matched an empty value" if value.empty?
      nil
    end

    private def record_miss(rule : Store::ExtractRule, reason : String, flow_id : Int64?,
                            throttle : Bool) : Nil
      miss(rule, reason, flow_id) if !throttle || report_miss?(rule.id)
    end

    # Whether this rule's miss is worth an `events` row right now. One row per (rule, binding
    # revision), which is `Rules#report_unbound`'s key and it is the same flood: on the proxy
    # path `observe_response` runs for every response the rule's host glob AND condition
    # select, so a cookie descriptor scoped to a host the operator browses writes one row —
    # one synchronous store write, on the response path — per subresource. `miss_no_entity`
    # already deduped for exactly this reason; a plain miss is the far more common one.
    #
    # Keyed on the revision rather than latched forever so the report self-resets: `@rev`
    # moves on every rebind, every clear and every rule edit, which is precisely when "this
    # rule found nothing" becomes news again.
    private def report_miss?(rule_id : Int64) : Bool
      @mutex.synchronize do
        if @miss_reported_rev != @rev
          @miss_reported_rev = @rev
          @miss_reported.clear
        end
        @miss_reported.add?(rule_id)
      end
    end

    private def miss(rule : Store::ExtractRule, reason : String, flow_id : Int64?) : Nil
      @store.insert_event("bindings", "extract_miss", "warn",
        "$#{rule.name}: #{rule.token_loc.label} found nothing (#{reason})", flow_id: flow_id)
    end

    # A bind that HAPPENED but not over the origin's bytes. Once per rule per rule revision,
    # the same key and the same reason as `miss_no_entity`: this is a structural fact about
    # the target's body, so it is news when the operator edits the rule and noise on every
    # subsequent response. Warn and not info — the operator's next request carries a value
    # gori repaired, and that is the kind of thing a 401 is later blamed on.
    private def report_scrubbed(rule : Store::ExtractRule, flow_id : Int64?) : Nil
      return unless @mutex.synchronize { @scrub_reported.add?(rule.id) }
      @store.insert_event("bindings", "extract_scrubbed", "warn",
        "$#{rule.name}: #{rule.token_loc.label} read a response body that is not valid UTF-8 — a " \
        "regex/jsonpath descriptor has no byte-level reading, so every invalid byte was replaced " \
        "with U+FFFD before it ran and the bound value may not be the bytes the origin sent " \
        "(a cookie, header or position descriptor reads the same response byte-exact)",
        flow_id: flow_id)
    end

    private def miss_no_entity(rule : Store::ExtractRule, flow_id : Int64?) : Nil
      return unless @mutex.synchronize { @no_entity_reported.add?(rule.id) }
      @store.insert_event("bindings", "extract_no_body", "warn",
        "$#{rule.name}: #{rule.token_loc.label} needs the response body, and this response was " \
        "streamed rather than buffered (a server-sent-event / close-delimited / 101 body, or " \
        "one over the buffering ceiling) — the rule did not run", flow_id: flow_id)
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    # First 4 / last 4 with the length between them. Short values are masked whole rather
    # than half-revealed — a 6-character value showing 4 of its characters is not masked.
    def self.mask_preview(value : String) : String
      return "•" * value.size if value.size <= 12
      "#{value[0, 4]}…#{value.size}…#{value[-4, 4]}"
    end

    private def compile(rules : Array(Store::ExtractRule)) : Array(Compiled)
      rules.map do |r|
        re =
          if r.kind.regex? && !r.selector.empty?
            begin
              Regex.new(r.selector)
            rescue ArgumentError | Regex::Error
              nil
            end
          end
        Compiled.new(r, InterceptFilter.new(r.match_filter), re)
      end
    end

    private def refresh : Nil
      fresh = @store.extract_rules
      compiled = compile(fresh)
      @mutex.synchronize do
        @rules = fresh
        @compiled = compiled
        # Drop values whose rule is gone. Not values whose rule is merely DISABLED: an
        # operator toggling a rule off and back on has not asked to lose the token.
        names = fresh.map(&.name)
        @values.reject! { |k, _| !names.includes?(k) }
        # Every slot's table too. A deleted rule takes its value with it wherever that value
        # landed, and an emptied slot table is dropped rather than kept as an empty Hash.
        @slot_values.each_value { |table| table.reject! { |k, _| !names.includes?(k) } }
        @slot_values.reject! { |_, table| table.empty? }
        @rev &+= 1
        # An edit is the operator looking at this rule, so let it say the no-body thing again.
        @no_entity_reported.clear
        @scrub_reported.clear
      end
      @enabled_count.set(fresh.count(&.enabled?))
      @body_count.set(compiled.count(&.wants_body?))
      # A rule edit changes which names are DECLARED, and `token_regions` paints on that.
      Env.bump_highlight_rev
    end
  end
end
