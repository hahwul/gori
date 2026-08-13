require "./store"
require "./settings"
require "./intercept_filter"
require "./filter_ast"
require "./ql"
require "./proto"

module Gori
  # The History row-colour lens: which captured rows get painted, in what colour, in which
  # style. DISPLAY ONLY — nothing here reaches the proxy, and this object is deliberately NOT
  # passed to `Proxy::Server` / `Tls::Tunnel` / `build_listener`. A colour rule paints a row
  # that has already been captured, so an over-broad one costs an operator a misleading list,
  # never a modified message.
  #
  # Shaped like `Rules` on purpose — same two-scope model (a global library in settings.json,
  # this project's rows in SQLite, and this project's per-rule DISAGREEMENTS with the library
  # as an override map), same `{id, scope}` identity, same "did the write commit" answers — so
  # an operator who knows the Rewriter tab already knows this one.
  #
  # The one axis where the two genuinely differ: rewrite rules COMPOSE (every enabled rule runs,
  # in order) while colour rules RESOLVE (the FIRST enabled match paints the row and the rest
  # are never consulted). Order is therefore the operator's precedence statement, which is why
  # reordering is a first-class action on the TUI, the CLI and MCP alike.
  #
  # ── the two tiers, and why a colour rule speaks full QL ─────────────────────────────────
  # A colour rule's condition is a HISTORY QL string — the same grammar, the same field set and
  # the same answers as the filter bar above the list it paints. That is a deliberate reversal
  # of what this file used to say ("Not a new dialect, and NOT QL: … there is no query to run
  # when the row is already in hand on the render path"), and the reversal is narrow: for
  # `host:`/`status:`/`proto:` there is still no query to run, and none is run. The old statement
  # was wrong only about the fields the ROW PROJECTION cannot answer — `body:`, `header:`,
  # `size:`, `dur:`, `url:` — where there is a query to run, it is bounded by the screenful of
  # ids being painted, and the alternative was what shipped: `body:` parsing fine, painting
  # nothing, and saying so only in a note.
  #
  # So `compile` sorts each rule into one of two tiers, and the tier is a property of the rule,
  # never of the row:
  #
  #   ROW tier — every term answerable from a `FlowRow` (see `ROW_FIELDS`). Matched in memory by
  #     `InterceptFilter`, exactly as before, with no store access at all.
  #   STORE tier — anything else. Compiled by `QL.parse(…, fts: false)` and answered by one
  #     `Store#ids_matching` over the ids being painted.
  #
  # The tiers cover DISJOINT rule sets, so the two matchers can never disagree about one rule;
  # for the fields they both implement (`host` `path` `method` `scheme` `status` `proto`, and
  # bare free text over method/host/target) they already agree term for term.
  #
  # ── performance contract ────────────────────────────────────────────────────────────────
  # `match` runs on the History RENDER path, once per visible row per frame. So:
  #
  #   * `InterceptFilter.new` / `QL.parse` run ONLY in `refresh` — once per rule per edit/reload.
  #     Neither may appear on the render path; `spec/colormarker_spec.cr` pins this.
  #   * `active?` gates everything: a project with no enabled rule pays one atomic read per row.
  #   * the `Subject` is built once per row and reused across the whole compiled walk, and
  #     `proto` is passed IN because History's row loop already computes it.
  #   * zero allocation is NOT claimed — `InterceptFilter::Term` downcases the subject for its
  #     substring fields. The budget is O(visible rows × rules until first match) short-string
  #     downcases per frame, which is why first-match-wins short-circuiting is load-bearing
  #     rather than cosmetic.
  #   * `needs_store?` is the STORE tier's version of that gate, and it is what keeps this change
  #     free for everyone who did not ask for it: with no store-tier rule the render path is
  #     byte-identical to what it was, down to the absent `@sql_hits` lookup. With one, History
  #     calls `prefetch` ONCE per frame for the whole visible window (one query per store-tier
  #     rule, not per row) and every `match` after it reads a memo.
  class Colormarker
    # A rule with its condition already parsed, into whichever tier claims it: `filter` for the
    # ROW tier, `sql` for the STORE tier, exactly one of them non-nil. Same contract, same
    # reason, as `Bindings::Compiled`: the parse happens once per rule, not once per row.
    private record Compiled, rule : Store::ColorRule,
      filter : InterceptFilter?, sql : QL::Filter?

    # How many recent flows `preview` scans. Same cap and the same reason as
    # `Rules::RULE_PREVIEW_SCAN` — this runs on the keystroke path of the rule editor.
    PREVIEW_SCAN = 500

    # How many bytes of EACH side's body a store-tier `body:`/`body~` term reads. The same trade
    # `Rules::RULE_PREVIEW_BODY_MAX` makes, for the same reason and with the same consequence
    # stated out loud: a match past the cap is missed.
    #
    # It is not a taste call. A body is capped at capture time by `Settings.capture_max`, which
    # DEFAULTS TO 2 MiB and can be raised, and this scan runs on the History render path. Measured
    # on cap-sized bodies, resolving one screenful (60 rows) uncapped took ~460 ms — half a second
    # of stall per screen, on the list a proxy scrolls all day. At 64 KiB the same screenful is
    # single-digit milliseconds, and it is still 8× what History's own `body:` index covers, so a
    # colour rule remains STRICTLY more thorough than the query that inspired it.
    BODY_SCAN_MAX = 64 * 1024

    # Bumped by every mutator and by `reload`. History compares it once per frame to decide
    # whether to drop its per-row memo — which is what makes an edit here (or an MCP / CLI /
    # peer-process edit arriving through `Runner#apply_external_change`) repaint the list with
    # no cross-tab callback and no new `Host` method. The counter IS the notification.
    #
    # Read WITHOUT the mutex, deliberately: it is on the render path and a stale read costs one
    # frame drawn from a memo that is about to be dropped, which the next frame corrects. Taking
    # the lock per frame to buy that one frame would be the worse trade.
    getter revision : UInt64

    @rules : Array(Store::ColorRule)
    @compiled : Array(Compiled)
    @active : Bool
    @strip_active : Bool
    # A snapshot of the global custom-colour registry, so `refresh` can notice a hex edit that
    # changes NO rule (a rule references a colour by name) and still bump `revision` — otherwise
    # a recoloured custom would leave History painting the stale hex until the next rule edit.
    @custom_colors : Array(Settings::ColormarkerColor)
    # Whether any enabled rule landed in the STORE tier. Read per FRAME (not per row) to decide
    # whether `prefetch` has anything to do, so it is cached here rather than scanned.
    @needs_store : Bool
    # Store-tier answers: flow id → {rule index in `@compiled` → matched?}. Dropped wholesale by
    # `refresh` (the compiled list those indices refer to is gone) and per id by `forget` (the
    # row's own bytes changed). Bounded by `SQL_CACHE_MAX` flows, so a session that scrolls a
    # million rows past a store-tier rule cannot grow it without limit.
    #
    # Keyed flow-id-OUTER, not by a `{rule, flow}` tuple: `forget` is called once per response
    # that lands, on the render fiber, at capture rate, and against a flat tuple map it had to
    # walk every entry to find the one row's. A nested map makes it one `delete`.
    @sql_hits : Hash(Int64, Hash(Int32, Bool))

    def initialize(@store : Store, rules : Array(Store::ColorRule))
      @mutex = Mutex.new
      # A SECOND lock, and deliberately not `@mutex`: filling this cache means querying the store,
      # `@mutex` is taken on the render path, and holding a render-path lock across DB I/O is how
      # a frame turns into a stall. Nothing is ever held across a query — see `prefetch`.
      @cache_mutex = Mutex.new
      @sql_hits = {} of Int64 => Hash(Int32, Bool)
      @rules = rules
      @custom_colors = Settings.colormarker_colors
      @compiled = compile(rules)
      @active = !@compiled.empty?
      @needs_store = @compiled.any?(&.sql)
      @strip_active = @compiled.any?(&.rule.style.strip?)
      @revision = 1_u64
    end

    def self.load(store : Store) : Colormarker
      new(store, merged(store))
    end

    # Every colour rule that applies in `store`'s project, in PRECEDENCE order: the global
    # library first (settings.json order), then this project's own rows (`position` order).
    #
    # Globals first is not merely apply order here, it is precedence: a standing policy ("red
    # on any 5xx, everywhere") outranks a project-local rule, the same global-base /
    # project-layer story `Env.effective_vars` and `Probe.custom_rules` tell. A reader who
    # knows only `Rules.merged` will read "globals first" as "compose first" — it is not.
    #
    # A global rule arrives carrying its EFFECTIVE state — its own default unless this project
    # overrode it — so `enabled?` means the same thing for both scopes and `match` never
    # consults the override map. `overridden?` rides along for the list row to mark.
    def self.merged(store : Store) : Array(Store::ColorRule)
      overrides = store.colormarker_overrides
      out = Settings.colormarker_rules.map do |r|
        if (ov = overrides[r.id]?).nil?
          r.to_rule
        else
          r.to_rule(enabled: ov, overridden: true)
        end
      end
      out.concat(store.color_rules)
      out
    end

    # A copy of the current rules (for the editor UI), both scopes, precedence order.
    def rules : Array(Store::ColorRule)
      @mutex.synchronize { @rules.dup }
    end

    # The lens is doing something iff at least one rule is enabled.
    def active? : Bool
      @mutex.synchronize { @active }
    end

    # Whether History must reserve its leading swatch column. Cached at refresh rather than
    # scanned per frame — the row loop asks this once per render.
    def strip_active? : Bool
      @mutex.synchronize { @strip_active }
    end

    def enabled_count : Int32
      @mutex.synchronize { @rules.count(&.enabled?) }
    end

    # The rule that paints `row`, or nil. FIRST enabled match wins; the winner carries both the
    # colour AND the style, so a global `full` rule and a project `strip` rule never fight —
    # only one of them is ever resolved for a given row.
    #
    # `proto` is accepted so History can pass the `Proto.classify` it already computed for its
    # PROTO column. The no-argument form classifies for itself, for callers off the render path.
    def match(row : Store::FlowRow, proto : Proto::Kind) : Store::ColorRule?
      compiled = @mutex.synchronize { @active ? @compiled : nil }
      return nil unless compiled
      subject = InterceptFilter::Subject.new(
        method: row.method, host: row.host, target: row.target,
        scheme: row.scheme, status: row.status, proto: proto)
      compiled.each_with_index do |c, i|
        if f = c.filter
          return c.rule if f.matches?(subject)
        elsif sql = c.sql
          return c.rule if store_tier_hit?(i, row.id, sql)
        end
      end
      nil
    end

    def match(row : Store::FlowRow) : Store::ColorRule?
      match(row, Proto.classify(row.status, row.content_type, row.request_content_type))
    end

    # Resolve every store-tier rule for `rows` in ONE query per rule, so the `match` calls that
    # follow read a memo instead of each paying a round trip. History calls this once per frame
    # with its visible window; skipping it is not a correctness bug — `store_tier_hit?` falls back
    # to a single-id query — only a per-row one.
    #
    # A no-op, with no lock taken and no store touched, unless a store-tier rule exists.
    def prefetch(rows : Array(Store::FlowRow)) : Nil
      return if rows.empty? || !needs_store?
      compiled = @mutex.synchronize { @active ? @compiled : nil }
      return unless compiled
      rev = @revision
      compiled.each_with_index do |c, i|
        sql = c.sql
        next unless sql
        want = @cache_mutex.synchronize do
          rows.compact_map { |r| @sql_hits[r.id]?.try(&.has_key?(i)) ? nil : r.id }
        end
        next if want.empty?
        # OUTSIDE both locks — see `@cache_mutex`'s note.
        hits = @store.ids_matching(sql, want)
        next unless hits # the query failed; leave the ids unresolved so the next frame retries
        @cache_mutex.synchronize do
          # A rule edit landed while the query was in flight, so `i` no longer names the rule
          # these answers are about. Drop the batch rather than file it under the new indices.
          if @revision == rev
            trim_sql_cache
            want.each { |id| (@sql_hits[id] ||= {} of Int32 => Bool)[i] = hits.includes?(id) }
          end
        end
      end
    end

    # Forget what is known about one flow, because its own bytes changed. History calls this when
    # a row is REPLACED (`:updated` — the response landed), the same moment it drops its per-row
    # colour memo: a `body:`/`size:` rule resolved against the pending row genuinely answers
    # differently once there is a response, and a cache that outlived the row it described would
    # keep the pending answer for the rest of the session.
    def forget(id : Int64) : Nil
      return unless needs_store?
      @cache_mutex.synchronize { @sql_hits.delete(id) }
    end

    # Is any enabled rule in the STORE tier? Read per frame by History (to decide whether to
    # `prefetch`) and by `forget`, so it is a cached flag rather than a scan.
    def needs_store? : Bool
      @mutex.synchronize { @needs_store }
    end

    # One store-tier rule's answer for one row, memoised. The fallback path for a row `prefetch`
    # did not cover; the cost is one indexed single-id query, paid once per {rule, row}.
    private def store_tier_hit?(index : Int32, id : Int64, filter : QL::Filter) : Bool
      # `unless .nil?`, not a truthiness test: a cached FALSE is a real answer, and `if cached`
      # would re-query for every row a rule does not paint — i.e. for almost every row.
      cached = @cache_mutex.synchronize { @sql_hits[id]?.try(&.[index]?) }
      return cached unless cached.nil?
      rev = @revision
      hits = @store.ids_matching(filter, [id])
      return false unless hits # failed, not "no match" — do not cache it (see `Store#ids_matching`)
      hit = hits.includes?(id)
      @cache_mutex.synchronize do
        if @revision == rev
          trim_sql_cache
          (@sql_hits[id] ||= {} of Int32 => Bool)[index] = hit
        end
      end
      hit
    end

    # Flows remembered — roughly a hundred screenfuls. Cleared wholesale rather than evicted
    # LRU: the rows worth remembering are the ones on screen, the next frame re-resolves them in
    # one `prefetch`, and an LRU's bookkeeping would cost more than the query it saves.
    SQL_CACHE_MAX = 8192

    # Caller MUST hold `@cache_mutex`.
    private def trim_sql_cache : Nil
      @sql_hits.clear if @sql_hits.size >= SQL_CACHE_MAX
    end

    # --- editing (persists, then refreshes the snapshot) ---------------------------------

    # `scope` picks the STORE the new rule lands in. Refuses a condition that would paint every
    # row — see `unusable_reason`. Returns whether anything was written.
    def add(match_filter : String, color : String = "yellow",
            style : Store::MarkerStyle = Store::MarkerStyle::Full, name : String = "",
            scope : Store::RuleScope = Store::RuleScope::Project, enabled : Bool = true) : Bool
      return false if Colormarker.unusable_reason(match_filter)
      if scope.global?
        Settings.add_colormarker_rule(match_filter, color, style.label, name, enabled)
      else
        @store.insert_color_rule(match_filter, color, style, name, enabled)
      end
      refresh
      true
    end

    def update(id : Int64, match_filter : String, color : String,
               style : Store::MarkerStyle, name : String = "",
               scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      return false if Colormarker.unusable_reason(match_filter)
      if scope.global?
        Settings.update_colormarker_rule(id, match_filter, color, style.label, name)
      else
        @store.update_color_rule(id, match_filter, color, style, name)
      end
      refresh
      true
    end

    # Move a rule to the OTHER scope, keeping its fields and its state in this project. Not an
    # edit of one row but a re-home: promoting a project rule to global makes it paint in every
    # other project, demoting a global one takes it out of them.
    #
    # Destination-first, and the copy is UNDONE if the source then refuses the delete. That
    # second failure is the one the ordering does not cover on its own: the rule would be left
    # in BOTH scopes while both callers report "unchanged". Under first-match-wins the duplicate
    # is LESS visible than under the Rewriter (the second copy never resolves), which makes it
    # more insidious, not less — hence the undo. The id is kept rather than the copy re-found by
    # fields, which would pick the wrong twin.
    def set_scope(rule : Store::ColorRule, to : Store::RuleScope) : Bool
      return false if rule.scope == to
      copy_id =
        if to.global?
          Settings.add_colormarker_rule(rule.match_filter, rule.color, rule.style.label,
            rule.name, rule.enabled?)
        else
          @store.insert_color_rule(rule.match_filter, rule.color, rule.style, rule.name, rule.enabled?)
        end
      return false if copy_id == 0
      unless remove(rule.id, rule.scope)
        to.global? ? Settings.delete_colormarker_rule(copy_id) : @store.delete_color_rule(copy_id)
        refresh
        return false
      end
      refresh
      true
    end

    # False when the write did NOT commit (store busy, locked or closing) — the rule is still
    # there and the row colour is unchanged. Means COMMITTED, not "a row existed".
    def remove(id : Int64, scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      ok =
        if scope.global?
          # Drop this project's disagreement with it too, so a later rule cannot inherit the
          # override — belt to the monotonic counter's braces.
          #
          # Only once the rule is actually gone, though. `delete_colormarker_rule` answers false
          # for two different reasons that want opposite handling:
          #
          #   no such rule       — nothing left to disagree with, so the stale override is swept
          #   settings not saved — the rule is still in the library on disk, and clearing the
          #                        override would drop this project back to the library default:
          #                        a rule the operator switched off here starts painting again
          #
          # Which one it was has to be captured BEFORE the call: the delete drops the rule from
          # the in-memory list and only then saves, so asking afterwards reports "gone" for both.
          existed = Settings.colormarker_rules.any? { |r| r.id == id }
          deleted = Settings.delete_colormarker_rule(id)
          @store.clear_colormarker_override(id) if deleted || !existed
          deleted
        else
          @store.delete_color_rule(id)
        end
      refresh
      ok
    end

    # False when the write did NOT commit; see `remove`. A missing rule is false too.
    #
    # For a GLOBAL rule this writes THIS PROJECT's override, never the rule: `x` in the list
    # means "not here" / "yes here", which is the disagreement an engagement has with a standing
    # policy. Changing the policy itself is `toggle_default`, a separate gesture.
    def toggle(id : Int64, scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      rule = rules.find { |r| r.id == id && r.scope == scope }
      return false unless rule
      ok =
        if scope.global?
          set_effective(id, !rule.enabled?)
        else
          @store.set_color_rule_enabled(id, !rule.enabled?)
        end
      refresh
      ok
    end

    # Flip a GLOBAL rule's DEFAULT — the state every project without an override follows.
    # Returns false for a project rule (which has no default to flip) and for an unknown id.
    #
    # Takes the SCOPE as well as the id, unlike `Rules#toggle_default`, and that is not
    # ceremony: the two stores number their rules independently and both count from 1, so a
    # project #1 and a global #1 coexist in almost every project. Looking the id up in the
    # global library alone — which is all a bare-id version can do — silently flips the global
    # rule when the caller meant the project one, and reports success. The pair is the identity
    # everywhere else here; this is the one place where dropping it does damage in another
    # project's list.
    def toggle_default(id : Int64, scope : Store::RuleScope = Store::RuleScope::Global) : Bool
      return false unless scope.global?
      rule = Settings.colormarker_rules.find { |r| r.id == id }
      return false unless rule
      ok = Settings.set_colormarker_rule_enabled(id, !rule.enabled)
      refresh
      ok
    end

    # Make a global rule effectively `enabled` HERE. When the wanted state is the rule's own
    # default the override is REMOVED rather than pinned to it: a project that toggled a rule
    # off and back on goes back to FOLLOWING the library, so a later change to the default still
    # reaches it. Pinning would silently freeze this project at today's answer.
    private def set_effective(id : Int64, enabled : Bool) : Bool
      rule = Settings.colormarker_rules.find { |r| r.id == id }
      return false unless rule
      rule.enabled == enabled ? @store.clear_colormarker_override(id) : @store.set_colormarker_override(id, enabled)
    end

    # Move a rule one slot up (dir < 0) / down (dir > 0) in PRECEDENCE order, WITHIN its own
    # scope. The scope boundary is not a position: every global rule resolves before every
    # project one, so "past the end of the global block" means "become a project rule", which is
    # `set_scope`'s job and a different decision.
    #
    # This changes WHICH rule paints a row, not merely the order two effects apply in — so
    # false means the order is UNCHANGED, whether because the rule was already at the edge of
    # its block or because the write did not commit. `Rules#move` cannot draw that second
    # distinction (`Store#move_rule` returns Nil); this one can, and a caller that reports a
    # reorder it did not get tells the operator the wrong rule paints the row.
    def move(id : Int64, dir : Int32, scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      scoped = rules.select { |r| r.scope == scope }
      i = scoped.index { |r| r.id == id }
      return false unless i
      j = i + (dir < 0 ? -1 : 1)
      return false if j < 0 || j >= scoped.size
      ok = scope.global? ? Settings.move_colormarker_rule(id, dir) : @store.move_color_rule(id, dir)
      refresh
      ok
    end

    # Re-read the snapshot (e.g. after an external MCP / other-instance edit). Same reach
    # `Rules#reload` has: the project DB and this process's own global library, not another
    # gori PROCESS's settings.json (that would mean `Settings.load`, which replaces every
    # section from disk including ones this process has changed but not saved).
    def reload : Nil
      refresh
    end

    # --- validation and advice ------------------------------------------------------------

    # The fields worth NAMING to an operator — every field History's filter bar has, because a
    # colour rule now answers every one of them. It used to be `InterceptFilter::FIELDS` minus
    # `body:` (a field this backend accepted and could never match); the subtraction is gone
    # because the reason is.
    USEFUL_FIELDS = QL::FIELDS

    # What each field means IN A COLOUR RULE. QL's own text is right for a QUERY and wrong here for
    # the two content fields, because `compile` parses with `fts: false, body_max: BODY_SCAN_MAX`:
    # a rule scans the stored bytes rather than the trigram index, and reads 64 KiB of each side
    # rather than the index's 8 KiB. Telling a rule author "8 KiB/side, via an index that lags
    # capture" would be wrong about both the mechanism and the bound — in the direction that makes
    # them narrow a rule that did not need narrowing.
    FIELD_HELP = QL::FIELD_HELP.merge({
      "body"      => "body bytes as captured — 64 KiB/side scan",
      "req.body"  => "request body as captured — 64 KiB scan",
      "resp.body" => "response body as captured — 64 KiB scan",
    })

    # As a proc, built once — the rule overlay draws this every frame while the condition row has
    # focus, and an inline closure there allocates per frame.
    FIELD_HELP_FOR_RULE = ->(f : String) { FIELD_HELP[QL.canonical_field(f)]? }

    # The fields a `FlowRow` answers on its own — the ROW tier's vocabulary, and the whole of it.
    # `InterceptFilter::FIELDS` minus the CONTENT ones: a hold gate fills `Subject#head`/`#payload`
    # with the bytes it has, and a captured row has neither, so `header:` and `body:` belong to
    # the STORE tier however simple the rest of the condition is.
    #
    # Derived by SUBTRACTING rather than listed out, and that is load-bearing: written as a
    # literal list this would silently go stale the next time `InterceptFilter` learns a field.
    # It already did once — `header:` was added to that list and instantly became "row-answerable",
    # so a `header:` rule compiled into the ROW tier and matched a Subject whose `head` is nil.
    ROW_FIELDS = InterceptFilter::FIELDS - QL::CONTENT_FIELDS

    # Can `match` answer this condition from the row projection alone? Drives the tier split in
    # `compile`. Reads `QL.fields_used`, so "which fields does this name" is answered by the same
    # tokenizer that compiles them — a bare free-text word names no field and stays row-answerable
    # (both backends free-text over method/host/target and agree), and a `~` term never is,
    # because only QL implements the regex operator.
    def self.row_answerable?(match_filter : String) : Bool
      QL.fields_used(match_filter).all? { |u| !u.regex && ROW_FIELDS.includes?(u.name) }
    end

    # Why this condition cannot be used, or nil if it can.
    #
    # `InterceptFilter.new` NEVER raises — an unknown field degrades to free text and
    # `FilterAst` is total — so there is no parse failure to lean on and every refusal has to be
    # made explicitly. Three of them, and each is a rule that would otherwise fail SILENTLY:
    #
    #   1. an empty condition, and 2. one that folds to match-all (a mid-typed `host:` — a term
    #      with an empty value is DROPPED, and an emptied query matches everything), both paint
    #      every row in History;
    #   3. a `field:` QL does not implement (`hsot:`, or a literal colon in a value) — both
    #      compilers free-text the whole token, so `hsot:evil.com` becomes a literal substring
    #      search over method/host/target and the rule never fires, with no error anywhere;
    #   4. a `~` pattern that does not compile. QL turns one into a never-match clause on purpose
    #      (see `QL.invalid_regex_terms`), which for a QUERY is a result an operator can see is
    #      empty — but for a RULE it is a colour that never appears, and nothing to look at;
    #   5. a term QL would DROP — a bad numeric or an unknown enum value (`size:>bogus`,
    #      `proto:zzz`). This one arrived WITH the store tier: while `size:` was an unknown field
    #      the whole condition was refused by (3), and the moment it became a real field
    #      `host:acme size:>bogus` started compiling to `host:acme` alone and painting every acme
    #      row. That is the silent-BROADEN direction — the one `QL.body_cond`'s own comment calls
    #      the dangerous one — and a query gets to survive it (the operator sees a too-long list
    #      and `ql_explain` names the term) where a standing rule does not.
    def self.unusable_reason(match_filter : String) : String?
      return "enter a condition" if match_filter.blank?
      if bad = unknown_fields(match_filter).first?
        return "unknown field `#{bad}:` — a colour rule knows #{USEFUL_FIELDS.join(": ")}:"
      end
      if bad = QL.invalid_regex_terms(match_filter).first?
        return "`#{bad}` is not a valid regex — it would match nothing"
      end
      # Compiled the way `compile` compiles it, so what is judged match-all is what would RUN.
      # BEFORE the dropped-term check below, so a condition whose EVERY term was dropped keeps
      # naming the worse consequence: it paints every row, not merely one term fewer.
      return "this condition matches every flow" if QL.reject_empty?(match_filter, QL.parse(match_filter, fts: false))
      if bad = QL.analyze(match_filter).ignored.first?
        return "`#{bad}` is not a value that field takes — it would be dropped, and the rule would paint more"
      end
      nil
    end

    # The `field:` names in `match_filter` that QL does not implement, deduped, in order of
    # appearance. Driven by `QL.fields_used` — the SAME tokenization the compilers run — so what
    # is reported as a field is exactly what would ACT as one, `~` terms included.
    def self.unknown_fields(match_filter : String) : Array(String)
      names = QL.fields_used(match_filter).map(&.name)
      # `QL.known_field?`, NOT `QL::FIELDS.includes?`: `FIELDS` is the pool a surface OFFERS, and
      # QL accepts spellings it does not offer (`res.body`, `req.size` — see `QL::FIELD_ALIASES`).
      # Testing membership of the narrower list would refuse a condition QL compiles perfectly.
      names.uniq!.reject! { |n| QL.known_field?(n) }
    end

    # Non-fatal notes about a condition that IS usable but will not behave the way its author
    # probably expects. Surfaced as a hint line in the TUI, on STDERR by the CLI, and in `notes`
    # by MCP — never as a refusal, because each of these is a legitimate thing to write.
    #
    # Worded identically at all three surfaces on purpose: an operator who reads one of these
    # in `gori run colormarker` and then sees the rule in the TUI must not have to reconcile
    # two accounts of the same caveat.
    def self.advise(match_filter : String) : Array(String)
      notes = [] of String
      lower = match_filter.downcase
      # The inverse of the note that used to stand here ("`body:` never matches here"). It is
      # worth saying because the difference runs the OTHER way from what an operator who knows
      # History's `body:` would assume: the filter bar's reads a trigram index bounded at
      # `Store::FTS_INDEX_MAX` bytes per side, and a rule cannot, because the index lags capture
      # and a colour has to be right for the row that just arrived. So a rule can paint rows the
      # identical query does not list. See `QL.parse`'s `fts:`.
      if lower.includes?("body:") || lower.includes?("body~")
        notes << "a body term scans here rather than reading the text index, so it reaches " \
                 "binary bodies the filter bar's `body:` skips — but only the first " \
                 "#{BODY_SCAN_MAX // 1024} KiB of each side, and the bytes are as CAPTURED, so " \
                 "a match past that bound, or inside a compressed body, is not painted."
      end
      if lower.includes?("host:")
        notes << "`host:` is a substring here, not a DNS-label glob: `host:alpha.test` also matches `xalpha.test`."
      end
      if lower.includes?("status:")
        notes << "a flow with no response yet has no status; the row is painted once the response lands."
      end
      notes
    end

    # How many recent flows a candidate condition would MATCH, and how many it would actually
    # PAINT once the rules that already resolve first are taken into account.
    #
    # The second number is the one the Rewriter's preview cannot produce, and it is the one that
    # answers the real question: "your rule matches 41 rows and paints 17, because an earlier
    # rule already claims 24." `existing` is the enabled rules that would sit AHEAD of this one.
    #
    # Still cheap, and cheap in the same shape `match` is: one `recent_flows` page, plus at most
    # ONE query per condition for the store-tier ones — never a `get_flow` per row (contrast
    # `Rules#preview`, which must pull bodies). A preview of `body:secret` against 500 scanned
    # rows is one query, not 500.
    record Preview, matched : Int32, painted : Int32, scanned : Int32, total : Int64

    def self.preview(store : Store, match_filter : String,
                     existing : Array(Store::ColorRule) = [] of Store::ColorRule,
                     limit : Int32 = PREVIEW_SCAN) : Preview
      rows = store.recent_flows(limit, nil)
      ids = rows.map(&.id)
      candidate = resolve_over(store, match_filter, ids)
      ahead = existing.select(&.enabled?).map { |r| resolve_over(store, r.match_filter, ids) }
      scanned = 0
      matched = 0
      painted = 0
      rows.each do |row|
        scanned += 1
        subject = InterceptFilter::Subject.new(
          method: row.method, host: row.host, target: row.target,
          scheme: row.scheme, status: row.status,
          proto: Proto.classify(row.status, row.content_type, row.request_content_type))
        next unless candidate.hit?(row, subject)
        matched += 1
        painted += 1 unless ahead.any?(&.hit?(row, subject))
      end
      Preview.new(matched, painted, scanned, store.count)
    end

    # One condition resolved over a FIXED set of rows — `preview`'s counterpart to the tier split
    # `compile` does for the render path, so the two cannot disagree about what a rule would paint.
    private record Resolved, filter : InterceptFilter?, ids : Set(Int64)? do
      def hit?(row : Store::FlowRow, subject : InterceptFilter::Subject) : Bool
        if f = filter
          f.matches?(subject)
        elsif s = ids
          s.includes?(row.id)
        else
          false # the query could not run; `Store#ids_matching` has already logged it
        end
      end
    end

    private def self.resolve_over(store : Store, match_filter : String, ids : Array(Int64)) : Resolved
      return Resolved.new(InterceptFilter.new(match_filter), nil) if row_answerable?(match_filter)
      Resolved.new(nil, store.ids_matching(QL.parse(match_filter, fts: false, body_max: BODY_SCAN_MAX), ids))
    end

    # --- one-line rule formatting (shared) -------------------------------------------------
    # The list row, the confirm prompts and `gori run colormarker` all render through this, so a
    # prompt and the row it acts on cannot disagree about what a rule says.
    def self.summary(rule : Store::ColorRule) : String
      label = rule.name.blank? ? rule.match_filter : "#{rule.name} — #{rule.match_filter}"
      "#{rule.color} #{rule.style.label}: #{label}"
    end

    private def refresh : Nil
      fresh = Colormarker.merged(@store)
      fresh_custom = Settings.colormarker_colors
      # Struct value equality, on BOTH the rules and the custom-colour registry. This matters:
      # `reload` rides the TUI's data_version poll, which fires roughly once a second during
      # capture, and the common case is that nothing changed. Without the bail-out every tick
      # would recompile every filter AND bump `revision`, throwing away History's per-row memo on
      # a frame where nothing moved. The custom-colour half is what makes a hex edit — which
      # touches no rule, since a rule names its colour — still repaint the list.
      return if fresh == @rules && fresh_custom == @custom_colors
      compiled = compile(fresh)
      @mutex.synchronize do
        @rules = fresh
        @custom_colors = fresh_custom
        @compiled = compiled
        @active = !compiled.empty?
        @needs_store = compiled.any?(&.sql)
        @strip_active = compiled.any?(&.rule.style.strip?)
        @revision &+= 1
      end
      # Every key names a rule by its index in the list just replaced, so none of them mean
      # anything now. Dropped AFTER the bump, so a `match` racing this either reads the old
      # compiled list with its own answers still cached or the new one with a clean cache —
      # never the new list against the old list's answers.
      @cache_mutex.synchronize { @sql_hits.clear }
    end

    # ENABLED rules only, in precedence order: `match` then walks a list where every entry is a
    # candidate, rather than re-testing `enabled?` per row per frame.
    #
    # This is where a rule is sorted into its tier (see the class header). `row_answerable?`
    # decides, and it decides from the same tokenization the compilers use, so a rule cannot
    # land in the ROW tier carrying a term `InterceptFilter` would silently free-text.
    private def compile(list : Array(Store::ColorRule)) : Array(Compiled)
      list.select(&.enabled?).map do |r|
        if Colormarker.row_answerable?(r.match_filter)
          Compiled.new(r, InterceptFilter.new(r.match_filter), nil)
        else
          Compiled.new(r, nil, QL.parse(r.match_filter, fts: false, body_max: BODY_SCAN_MAX))
        end
      end
    end
  end
end
