require "./env"
require "./process_hook"
require "./rule_set_change"
require "./proxy/head_rewriter"
require "./rules/stub"
require "./rules/presets"
require "./store"
require "./store/safe_regexp"

module Gori
  # The Match&Replace lens (the "Rewriter" tab): rewrites of request/response messages
  # applied in flight. A rule either REPLACES text (literal substring or regex with
  # $1/\1 capture groups) in the HEAD (request/status line + headers) or BODY (the
  # entity), or performs a header operation by NAME (add / set / remove). Rules can be
  # scoped to a host glob. Human-configured (P4).
  #
  # A rule is persisted in one of TWO places, and which one is part of its identity
  # (`Store::RuleScope`): a PROJECT rule is a `match_rules` row, a GLOBAL rule lives in
  # settings.json and applies in every project. `Rules.merged` folds both into the one ordered
  # list everything below this line reads — globals first, then the project's own — so no
  # rewrite path, preview or count has to know a rule's scope at all. Only the editing half
  # does, which is why every mutator takes the {id, scope} PAIR: the two stores number their
  # rules independently, so an id alone names two different rules.
  #
  # Global-first is the standing-policy-then-local-layer order `Env.effective_vars` and
  # `Probe.custom_rules` already use: a global rule is what the operator wants on every
  # engagement, a project rule refines the traffic in front of them today.
  #
  # One instance is SHARED between the proxy fibers (which call `rewrite_*` on every
  # message) and the TUI (which edits the rule set). A Mutex guards the rule snapshot so
  # an edit can never tear a concurrent rewrite.
  class Rules < Proxy::HeadRewriter
    # Why a `$NAME` in a replacement stopped its rule from applying, and which name did it.
    #
    # `substitute` has TWO refusals and they mean opposite things — "declared but no value
    # yet" and "there IS a value and the head cannot carry it" — and they used to share one
    # `nil`. `report_unbound` only ever understood the first: it computes
    # `Env.unbound(rule.replacement)` and returns when that is empty, and a BOUND name is by
    # definition not unbound. So the boundary refusal fired in total silence — no header on the
    # wire, no event, no log line, no advisory, no status — and every head-scoped injection rule
    # in the project simply ceased to exist the moment an origin minted a cookie with a stray
    # CR in it. That is the origin disarming the operator's test setup invisibly, which is why
    # the two now carry their reason and their key instead of a shared nil.
    private enum Refusal
      Unbound  # declared by an enabled extract rule, no value yet
      Boundary # bound, and the value carries CR/LF/NUL — see `forges_boundary?`
    end

    # The key travels with the reason because the event has to name it: a replacement holding
    # several `$NAME`s makes "the value carries CR" actionable only if it says whose.
    private record Refused, reason : Refusal, key : String

    def initialize(@store : Store, @rules : Array(Store::MatchRule))
      @mutex = Mutex.new
      @stub_bodies = RuleStubBodyCache.new
      # Lock-free fast-path flags: rewrite_* run on EVERY message, but the common case
      # is no rule for that side/part. These let the hot path skip the mutex + select-
      # array allocation entirely when nothing would match. The head counts gate the head
      # rewrite (replace-head AND the header ops, which all act on the head), split PER
      # DIRECTION like the body counts so a request-only rule doesn't tax every response
      # (and vice versa); the body counts also gate whether ClientConn buffers a body at all.
      @req_head_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Request, part: Store::RulePart::Head))
      @resp_head_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Response, part: Store::RulePart::Head))
      @req_body_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Request, part: Store::RulePart::Body))
      @resp_body_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Response, part: Store::RulePart::Body))
      # The WS pair (#500). Same job as the body counts and for the same reason: they gate
      # whether `WS::Relay` buffers a message at all, so a socket with no WS rule stays on
      # the byte-exact streaming pump. Request ⇒ "out" (client→server), Response ⇒ "in".
      @ws_out_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Request, part: Store::RulePart::Ws))
      @ws_in_count = Atomic(Int32).new(active_count(@rules, Store::RuleTarget::Response, part: Store::RulePart::Ws))
      # Short-circuit rules get their OWN gate and are excluded from all four counts above.
      # A stub rule is stored request/head like a header op, so it would otherwise inflate
      # @req_head_count and make every request head pay the mutex + select for a rule that
      # rewrites nothing — and `apply` would then have to skip it anyway, because its
      # `replacement` is a whole HTTP response and gsub'ing that into live traffic is exactly
      # the silent corruption the count exists to avoid.
      @short_circuit_count = Atomic(Int32).new(stub_count(@rules))
      # Pre-merged `$KEY` snapshot for `replacement_for`, invalidated by revision rather
      # than rebuilt per message — see `subst_snapshot`.
      @subst_vars = nil.as(Hash(String, String)?)
      @subst_declared = [] of String
      @subst_env_rev = 0_u32
      @subst_binding_rev = 0_u64
      # Rules already reported as blocked on an unbound binding, at that binding revision.
      # Keyed by {scope, id}, not id: the global library and the project table number their
      # rules independently, so a bare id would let a global rule's report silence a project
      # rule's — and the operator would be told about one of two rules that stopped applying.
      @unbound_reported = Set({Store::RuleScope, Int64}).new
      @unbound_reported_rev = 0_u64
      # A PEER's change to this snapshot, waiting to be announced (#772). Written only by
      # `reload` — never by the private `refresh` the local editing methods call — which is what
      # makes the operator's own edits silent without a flag threaded through all seven of them.
      @pending_peer_change = nil.as(RuleSetChange?)
      # The last pipe-failure sentence reported per {scope, id} — see `report_hook_failure`.
      @hook_reported = {} of {Store::RuleScope, Int64} => String
    end

    # Whether this rule is a live REWRITE rule for {target, part} — the ONE shape test the
    # counts, the per-host gates and `apply`'s own select all share. A nil `target` asks about
    # both sides.
    #
    # `op.header? && !part.head?` is the clause that has to be here rather than only in
    # `apply`. A header op names a header, so it can only act on a head, and every CRUD
    # surface forces that shape (`normalize_shape`) — but a hand-edited settings.json is a
    # supported way to write a global rule, and `parse_rewriter_rules` clamps the four enum
    # fields INDEPENDENTLY, so `{op: set_header, part: ws}` used to parse. `apply` filtered
    # it out, and the counts did not: the rule landed in `@ws_out_count`, which is what
    # decides whether `WS::Relay` keeps its byte-exact pump — so a rule that can never fire
    # took every message on that socket off frame-exact forwarding (P7). `part: body` is the
    # same defect one notch louder: it makes `rewrites_body_for_host?` true, which buffers
    # every body AND costs the host HTTP/2 (`tls/tunnel.cr`). Counting on the same predicate
    # that applies is what keeps "a rule is live" from meaning two different things.
    private def rewrites?(rule : Store::MatchRule, target : Store::RuleTarget?,
                          part : Store::RulePart) : Bool
      rule.enabled? && rule.op.rewrite? && !rule.pattern.empty? && rule.part == part &&
        !(rule.op.header? && !part.head?) && (target.nil? || rule.target == target)
    end

    # Count enabled, non-empty-pattern REWRITE rules matching an optional target + a part.
    # Short-circuit rules are never counted here — see `stub_count`.
    private def active_count(rules : Array(Store::MatchRule), target : Store::RuleTarget? = nil,
                             *, part : Store::RulePart) : Int32
      rules.count { |r| rewrites?(r, target, part) }
    end

    # Count enabled short-circuit rules whose stub is usable. A rule with an unparseable head
    # is counted anyway: it MUST still short-circuit (fail closed — see `stub_for`), because
    # falling through would send a request the operator declared contained.
    private def stub_count(rules : Array(Store::MatchRule)) : Int32
      rules.count { |r| r.enabled? && r.op.short_circuit? && !r.pattern.empty? }
    end

    def self.load(store : Store) : Rules
      new(store, merged(store))
    end

    # Every rule that applies in `store`'s project, in apply order: the global library first
    # (settings.json order), then this project's own rows (`position` order).
    #
    # A global rule arrives carrying its EFFECTIVE state — its own default unless this project
    # overrode it — so `enabled?` means the same thing for both scopes and the hot path never
    # consults the override map. `overridden?` rides along for the list row to mark; nothing
    # below this method reads it.
    def self.merged(store : Store) : Array(Store::MatchRule)
      overrides = store.rewriter_overrides
      out = Settings.rewriter_rules.map do |r|
        if (ov = overrides[r.id]?).nil?
          r.to_rule
        else
          r.to_rule(enabled: ov, overridden: true)
        end
      end
      out.concat(store.match_rules)
      out
    end

    # A copy of the current rules (for the editor UI).
    def rules : Array(Store::MatchRule)
      @mutex.synchronize { @rules.dup }
    end

    # The lens is doing something iff at least one rule is enabled.
    def active? : Bool
      @mutex.synchronize { @rules.any?(&.enabled?) }
    end

    def enabled_count : Int32
      @mutex.synchronize { @rules.count(&.enabled?) }
    end

    # --- editing (persists, then refreshes the snapshot) ---------------------

    # `scope` picks the STORE the new rule lands in — this project's table, or the global
    # library every project reads. A global rule is created ENABLED, like a project one: "add"
    # means the same thing in both scopes, and the surfaces that create one say where it went.
    def add(target : Store::RuleTarget, part : Store::RulePart, pattern : String, replacement : String,
            op : Store::RuleOp = Store::RuleOp::Replace, match_kind : Store::MatchKind = Store::MatchKind::Literal,
            name : String = "", host : String = "", body_file : String = "",
            scope : Store::RuleScope = Store::RuleScope::Project, enabled : Bool = true) : Bool
      return false if pattern.empty?
      target, part = normalize_shape(op, target, part)
      # Both writers already answered — a global add returns the new id (0 = not written),
      # a project add the same through `insert_rule`'s `exec_task`. This threw it away, so a
      # surface printed "rule duplicated" (or silently closed its overlay having "added" the
      # rule) over a write the store dropped. A rewrite rule can be the operator's control —
      # stripping an Authorization header, redacting a token before it leaves — so a silently
      # absent one is not cosmetic. Mirrors `remove` below: true means COMMITTED.
      ok =
        if scope.global?
          Settings.add_rewriter_rule(target.label, part.label, pattern, replacement, op.label,
            match_kind.label, name, host, body_file, enabled) != 0
        else
          @store.insert_rule(target, part, pattern, replacement, op, match_kind, name, host, enabled, body_file: body_file) != 0
        end
      refresh
      # A rewrite rule can be the operator's control — stripping an Authorization header,
      # redacting a token before it leaves — so who installed one, and what it matches, belongs
      # in the audit trail beside the scope rules.
      ConfigLog.record(@store, "rule_add", "#{Rules.scope_word(scope)} rewrite rule added — #{Rules.rule_phrase(name, target, part, pattern)}") if ok
      ok
    end

    # Install every rule of a preset (#821) through the SAME `add` path manual authoring uses
    # (P1) — no private write path, so an installed rule is an ordinary rule the moment it
    # lands: visible in the list, editable, disable-able, deletable (P4). Returns how many of
    # the preset's rules committed; the caller reports it, so a preset added a second time
    # duplicates VISIBLY (each row carries the preset's name) rather than silently. `scope`
    # picks the store exactly as `add` does, and `enabled` lets a surface install a preset
    # switched off for the operator to review before it touches traffic.
    def add_preset(preset : RulePresets::Preset,
                   scope : Store::RuleScope = Store::RuleScope::Project,
                   enabled : Bool = true) : Int32
      committed = 0
      preset.rules.each do |spec|
        committed += 1 if add(spec.target, spec.part, spec.pattern, spec.replacement,
                            spec.op, spec.match_kind, spec.name, host: "", body_file: "",
                            scope: scope, enabled: enabled)
      end
      committed
    end

    def update(id : Int64, target : Store::RuleTarget, part : Store::RulePart, pattern : String, replacement : String,
               op : Store::RuleOp = Store::RuleOp::Replace, match_kind : Store::MatchKind = Store::MatchKind::Literal,
               name : String = "", host : String = "", body_file : String = "",
               scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      return false if pattern.empty?
      target, part = normalize_shape(op, target, part)
      ok =
        if scope.global?
          Settings.update_rewriter_rule(id, target.label, part.label, pattern, replacement,
            op.label, match_kind.label, name, host, body_file)
        else
          @store.update_rule(id, target, part, pattern, replacement, op, match_kind, name, host, body_file)
        end
      refresh
      ConfigLog.record(@store, "rule_update", "#{Rules.scope_word(scope)} rewrite rule changed — #{Rules.rule_phrase(name, target, part, pattern)}") if ok
      ok
    end

    # How an audit line names a rewrite rule. A rule's `name` is optional, so the match itself
    # is the fallback identity — the same thing the Rewriter list falls back to on screen.
    # `replacement` is deliberately absent: it is the half most likely to carry a secret an
    # operator pasted in, and the rule is identifiable without it.
    def self.rule_phrase(name : String?, target : Store::RuleTarget, part : Store::RulePart, pattern : String) : String
      label = (name && !name.empty?) ? "#{name.inspect} " : ""
      "#{label}(#{target.label}/#{part.label} #{pattern.inspect})"
    end

    def self.scope_word(scope : Store::RuleScope) : String
      scope.global? ? "global" : "project"
    end

    # Move a rule to the OTHER scope, keeping its fields and its state in this project. Not an
    # edit of one row but a re-home: the rule is written into the destination store and dropped
    # from the source, so promoting a project rule to global makes it appear in every other
    # project and demoting a global one takes it out of them.
    #
    # Ordered destination-first and refuses if the write does not commit, so a failure leaves
    # the rule where it was rather than deleting it into nowhere. A global rule that this
    # project had overridden loses the override with the rule (there is nothing left to
    # disagree with) — its EFFECTIVE state here is what the project rule inherits, because that
    # is the state the operator is looking at when they press the key.
    #
    # The half the ordering does NOT cover on its own is the second step failing: the copy is
    # committed in the destination and the source store then refuses the delete, which leaves
    # the rule in BOTH scopes — `merged` lists it twice and the proxy applies it twice, while
    # both callers say "the rule is unchanged". So the copy is undone before returning false.
    # The undo targets the store that just accepted a write rather than the one that just
    # refused, so it is far likelier to land; it is still best-effort, and if it too fails the
    # duplicate stands, which is why the id is kept rather than the copy re-found by fields
    # (that would pick the wrong twin).
    def set_scope(rule : Store::MatchRule, to : Store::RuleScope) : Bool
      return false if rule.scope == to
      copy_id =
        if to.global?
          Settings.add_rewriter_rule(rule.target.label, rule.part.label, rule.pattern,
            rule.replacement, rule.op.label, rule.match_kind.label, rule.name, rule.host,
            rule.body_file, rule.enabled?)
        else
          @store.insert_rule(rule.target, rule.part, rule.pattern, rule.replacement, rule.op,
            rule.match_kind, rule.name, rule.host, rule.enabled?, body_file: rule.body_file)
        end
      return false if copy_id == 0
      unless remove(rule.id, rule.scope)
        to.global? ? Settings.delete_rewriter_rule(copy_id) : @store.delete_rule(copy_id)
        refresh
        return false
      end
      refresh
      true
    end

    # The {target, part} an op can actually have. Header ops are head-only; a short-circuit
    # rule is additionally request-only, because it matches a request and there is no response
    # to match against — the request never gets sent. Forced here (and mirrored by the CLI /
    # MCP / TUI surfaces) so a rule can never be persisted in a shape the proxy would ignore.
    #
    # `part: ws` + a header op is REFUSED by the CLI and MCP surfaces (`gori run rewriter`,
    # `create_rule`/`update_rule`) instead of arriving here, because this coercion would
    # silently move the rule off WebSocket messages and onto HTTP heads — a different
    # protocol, not a narrower shape. The TUI cannot produce the pair at all: its `part:` row
    # draws "n/a" the moment a header op is selected.
    # Why this rule's command cannot be run, or nil when it can — the ONE validator all three
    # CRUD surfaces call (`gori run rewriter`, the MCP `create_rule`/`update_rule`, the TUI
    # editor's Save row) so a pipe rule can never be persisted in a shape the proxy would
    # silently skip. Answers nil for every other op, which is what lets the surfaces call it
    # unconditionally.
    #
    # It checks the SPELLING, not the command: whether the file exists and is executable is
    # deliberately not asked here, because a hook may legitimately be installed later, live on
    # a path this process cannot stat, or be resolved through the operator's own PATH at exec
    # time. A wrong path is a run-time failure with a notice (`ProcessHook::Result#failure`); an
    # unparseable argv is a rule that could never run at all.
    def self.pipe_argv_error(op : Store::RuleOp, replacement : String) : String?
      return nil unless op.pipe?
      out = ProcessHook.parse_argv(replacement)
      out.is_a?(String) ? out : nil
    end

    def self.normalize_shape(op : Store::RuleOp, target : Store::RuleTarget,
                             part : Store::RulePart) : {Store::RuleTarget, Store::RulePart}
      return {Store::RuleTarget::Request, Store::RulePart::Head} if op.short_circuit?
      {target, op.header? ? Store::RulePart::Head : part}
    end

    private def normalize_shape(op : Store::RuleOp, target : Store::RuleTarget,
                                part : Store::RulePart) : {Store::RuleTarget, Store::RulePart}
      Rules.normalize_shape(op, target, part)
    end

    # False when the write did NOT commit (store busy, locked or closing) — the rule is still
    # there and still rewriting live traffic. The store has always answered this; it was
    # discarded here, so the TUI reported "rule deleted" for a rollback while the headless
    # surfaces (`mcp/tools/rules.cr`, `cli/run/rewriter.cr`) refused to. It means COMMITTED,
    # not "a row existed", which is the store's own contract.
    def remove(id : Int64, scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      # Named BEFORE the delete — `refresh` below leaves nothing to name it with.
      doomed = rules.find { |r| r.id == id && r.scope == scope }
      ok =
        if scope.global?
          # Drop this project's disagreement with it too, so a later rule that inherits the id
          # cannot inherit the override — belt to the monotonic counter's braces.
          #
          # Only once the rule is actually gone, though. `delete_rewriter_rule` answers false
          # for two different reasons and they want opposite handling here:
          #
          #   no such rule        — nothing left to disagree with, so the stale override is
          #                         swept (this is the case the sweep was written for)
          #   settings not saved  — the rule is still in the library on disk, and clearing the
          #                         override would drop this project back to the library's
          #                         default: a rule the operator switched OFF here turns back
          #                         ON, resuming a live traffic rewrite nobody asked for
          #
          # Which one it was has to be captured BEFORE the call. `delete_rewriter_rule` drops
          # the rule from the in-memory list and only then saves, so asking afterwards reports
          # "gone" for both — it cannot tell them apart.
          existed = Settings.rewriter_rules.any? { |r| r.id == id }
          deleted = Settings.delete_rewriter_rule(id)
          @store.clear_rewriter_override(id) if deleted || !existed
          deleted
        else
          @store.delete_rule(id)
        end
      refresh
      if ok && (r = doomed)
        ConfigLog.record(@store, "rule_remove", "#{Rules.scope_word(scope)} rewrite rule removed — #{Rules.rule_phrase(r.name, r.target, r.part, r.pattern)}")
      end
      ok
    end

    # False when the write did NOT commit; see `remove`. A missing rule is `false` too — there
    # was nothing to toggle, so claiming a state change would be just as wrong.
    #
    # For a GLOBAL rule this writes THIS PROJECT's override, never the rule: `x` in the
    # Rewriter list means "not here" / "yes here", which is the disagreement an engagement
    # has with a standing policy. Changing the policy itself is `toggle_default`, a separate
    # gesture, because it reaches into every other project.
    def toggle(id : Int64, scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      rule = rules.find { |r| r.id == id && r.scope == scope }
      return false unless rule
      ok =
        if scope.global?
          set_effective(id, !rule.enabled?)
        else
          @store.set_rule_enabled(id, !rule.enabled?)
        end
      refresh
      # Enabling and disabling is the same act as installing and removing, as far as what
      # actually rewrites traffic is concerned.
      state = rule.enabled? ? "disabled" : "enabled"
      ConfigLog.record(@store, "rule_toggle", "#{Rules.scope_word(scope)} rewrite rule #{state} — #{Rules.rule_phrase(rule.name, rule.target, rule.part, rule.pattern)}") if ok
      ok
    end

    # Flip a GLOBAL rule's DEFAULT — the state every project without an override follows.
    # Returns false for a project rule (which has no default to flip) and for an unknown id.
    def toggle_default(id : Int64) : Bool
      rule = Settings.rewriter_rules.find { |r| r.id == id }
      return false unless rule
      ok = Settings.set_rewriter_rule_enabled(id, !rule.enabled)
      refresh
      ok
    end

    # Make a global rule effectively `enabled` HERE. When the wanted state is the rule's own
    # default the override is REMOVED rather than pinned to it: a project that toggled a rule
    # off and back on goes back to FOLLOWING the library, so a later change to the default
    # still reaches it. Pinning would silently freeze this project at today's answer.
    private def set_effective(id : Int64, enabled : Bool) : Bool
      rule = Settings.rewriter_rules.find { |r| r.id == id }
      return false unless rule
      rule.enabled == enabled ? @store.clear_rewriter_override(id) : @store.set_rewriter_override(id, enabled)
    end

    # Move a rule one slot up (dir < 0) / down (dir > 0) in the applied order, WITHIN its own
    # scope. The scope boundary is not a position: every global rule applies before every
    # project one, so "past the end of the global block" means "become a project rule", which
    # is `set_scope`'s job and a different decision.
    #
    # False when nothing moved — an unknown rule, an edge of its own block, or a reorder the
    # backing store refused — so the caller can leave the cursor on the rule instead of walking
    # it across a swap that never happened. Precedence decides which of two rules that touch the
    # same header wins, so reporting a reorder that did not reach disk leaves the operator
    # believing an order that reverts at next start.
    def move(id : Int64, dir : Int32, scope : Store::RuleScope = Store::RuleScope::Project) : Bool
      scoped = rules.select { |r| r.scope == scope }
      i = scoped.index { |r| r.id == id }
      return false unless i
      j = i + (dir < 0 ? -1 : 1)
      return false if j < 0 || j >= scoped.size
      ok = scope.global? ? Settings.move_rewriter_rule(id, dir) : @store.move_rule(id, dir)
      refresh
      ok
    end

    # Re-read the snapshot (e.g. after an external MCP / other-instance edit). Same work
    # `refresh` does, exposed so the Rewriter tab can pull external changes on enter.
    #
    # "External" here means the project DB and this process's own global library. A global rule
    # another gori PROCESS wrote is not picked up: that would mean re-reading settings.json,
    # and `Settings.load` replaces every section from disk — including ones this process has
    # changed but not saved yet. Same reach the Decoder's chain library has always had.
    # A peer's edit is also RECORDED here for the operator (#772). The split that makes this
    # correct is the one that already existed: every local edit in this process goes through the
    # private `refresh` (`add`, `update`, `set_scope`, `remove`, `toggle`, `toggle_default`,
    # `move` all call it after their own write), and only a peer adoption or a re-read reaches
    # this method. So "was it mine?" is answered by WHICH METHOD RAN, not by a flag a future
    # mutator could forget to pass.
    #
    # Recorded rather than returned because the re-readers must not be able to eat it: the
    # Rewriter tab's `on_enter` and its `r` key both land here, and a peer's change adopted by one
    # of those is still owed an announcement. The drain takes it whenever it next runs.
    #
    # The comparison is over the MERGED array, which is what makes a peer's `toggle_default` on a
    # global rule THIS project overrides correctly silent — the effective `enabled?` this session
    # rewrites with never moved, so nothing on its wire did either.
    #
    # `announce: false` is for a LOCAL change that has to come in through the front door anyway —
    # the factory reset, which wipes the global library out from under the snapshot.
    def reload(announce : Bool = true) : Nil
      before = @mutex.synchronize { @rules }
      refresh
      return unless announce
      after = @mutex.synchronize { @rules }
      # The `executes` predicate is what makes a peer's `pipe` rule announce louder than a peer's
      # `replace` rule — see `RuleSetChange`. `enabled?` is part of it because a disabled pipe
      # rule forks nothing; it is a row, not a hook.
      return unless change = RuleSetChange.between(before, after,
                      ->(r : Store::MatchRule) { {r.scope, r.id} },
                      ->(r : Store::MatchRule) { r.enabled? && r.op.executes? })
      @mutex.synchronize do
        @pending_peer_change = (held = @pending_peer_change) ? held.merge(change) : change
      end
    end

    # Take the peer change owed to the operator, if any, and forget it. Drained by the surfaces
    # that can speak — the TUI's notification ring, the headless capture's log.
    def take_peer_change : RuleSetChange?
      @mutex.synchronize do
        held = @pending_peer_change
        @pending_peer_change = nil
        held
      end
    end

    # --- one-line rule formatting (shared) -----------------------------------
    # The Rewriter list renders these two as its op and detail columns; `summary` is just the
    # pair joined, for the places that name a rule in one line (a delete confirm). They live
    # here, on the type that owns the rule vocabulary, so a rule can never be described one
    # way in a prompt and another in the row the prompt is about.

    # The short op badge — "re/H", "sub/B", "+hdr", "stub", …
    def self.op_tag(rule : Store::MatchRule) : String
      case rule.op
      when .replace?
        kind = rule.match_kind.regex? ? "re" : "sub"
        "#{kind}/#{rule.part.badge}"
      when .add_header?    then "+hdr"
      when .set_header?    then "~hdr"
      when .remove_header? then "-hdr"
      when .short_circuit? then "stub"
        # The part badge rides along the way `replace` carries it: a pipe rule's part decides
        # WHAT the command is fed, which is the first thing to know about one.
      when .pipe? then "pipe/#{rule.part.badge}"
      else             "?"
      end
    end

    # What the rule does to the bytes, in the op's own shape.
    def self.describe(rule : Store::MatchRule) : String
      case rule.op
      when .add_header?, .set_header? then "#{rule.pattern}: #{rule.replacement}"
      when .remove_header?            then rule.pattern
        # `⇥` (not `→`) because a stub does not transform the request into the response — it
        # answers instead of forwarding, and the row should not read like the other four ops.
      when .short_circuit? then "#{rule.pattern} ⇥ #{RuleStub.summary(rule.replacement, rule.body_file)}"
        # `⇄` (not `→`) because the replacement is not the text on the right — it is whatever
        # that command WRITES. The row names the command so the operator can see, in the list,
        # that this rule executes something.
      when .pipe? then "#{rule.pattern} ⇄ #{rule.replacement}"
      else             "#{rule.pattern} → #{rule.replacement}"
      end
    end

    # Badge + description + the host glob when the rule is scoped to one. The host is worth
    # the width HERE and not in the tab's list (which has its own column for it): a rule scoped
    # to `*.corp.internal` is a different rule from the same pattern unscoped, and a confirm
    # prompt naming only the pattern would not say which of the two it is about.
    def self.summary(rule : Store::MatchRule) : String
      s = "#{op_tag(rule)}  #{describe(rule)}"
      rule.host.empty? ? s : "#{s}  @#{rule.host}"
    end

    # --- HeadRewriter (called from proxy fibers) -----------------------------

    def rewrite_request(head : Bytes, host : String) : Bytes
      apply(head, Store::RuleTarget::Request, Store::RulePart::Head, @req_head_count, host)
    end

    def rewrite_response(head : Bytes, host : String) : Bytes
      apply(head, Store::RuleTarget::Response, Store::RulePart::Head, @resp_head_count, host)
    end

    # A body rule is live iff at least one enabled, non-empty rule targets that side's
    # body — ClientConn keys the (expensive) body buffer on these.
    def rewrites_request_body? : Bool
      @req_body_count.get > 0
    end

    def rewrites_response_body? : Bool
      @resp_body_count.get > 0
    end

    # Whether a body rule that can actually MATCH `host` is live (#526). The two predicates
    # above answer "is any body rule live", which is the right question for `ClientConn` (it
    # is deciding whether to pay for a body buffer on a connection already pinned to one
    # host) and the wrong one for the h2 downgrade gate: that gate costs the host its
    # protocol, and a rule scoped to `alpha.test` was costing `127.0.0.1` its protocol too.
    #
    # The atomic counts are still the fast path — no body rule anywhere means no lock and no
    # select — and `host_matches?` (memoised, see below) then decides the rest. Both sides
    # are folded into one question because the gate downgrades for either.
    #
    # Once per CONNECT, so the mutex here is not on any hot path.
    def rewrites_body_for_host?(host : String) : Bool
      return false if @req_body_count.get == 0 && @resp_body_count.get == 0 # lock-free fast path
      @mutex.synchronize do
        @rules.any? do |r|
          rewrites?(r, nil, Store::RulePart::Body) && host_matches?(r.host, host)
        end
      end
    end

    def rewrite_request_body(entity : Bytes, host : String) : Bytes
      apply(entity, Store::RuleTarget::Request, Store::RulePart::Body, @req_body_count, host)
    end

    def rewrite_response_body(entity : Bytes, host : String) : Bytes
      apply(entity, Store::RuleTarget::Response, Store::RulePart::Body, @resp_body_count, host)
    end

    # --- WebSocket messages (#500 step 1) ------------------------------------

    # Whether a WS rule that can actually MATCH `host` is live for that direction. Asked
    # ONCE per socket (right after the 101), never per message, so the mutex here is not on
    # a hot path — and answering false is what keeps that direction on `WS::Relay`'s
    # byte-exact pump, frame boundaries and mask keys included.
    #
    # Host-scoped rather than host-blind (unlike `rewrites_request_body?`) because a socket
    # is pinned to one host from the handshake, so the narrower question is available and
    # the wrong answer costs every message on an unrelated host its framing.
    def rewrites_ws_out_for_host?(host : String) : Bool
      ws_rule_for_host?(@ws_out_count, Store::RuleTarget::Request, host)
    end

    def rewrites_ws_in_for_host?(host : String) : Bool
      ws_rule_for_host?(@ws_in_count, Store::RuleTarget::Response, host)
    end

    private def ws_rule_for_host?(count : Atomic(Int32), target : Store::RuleTarget, host : String) : Bool
      return false if count.get == 0 # lock-free fast path
      @mutex.synchronize do
        @rules.any? do |r|
          rewrites?(r, target, Store::RulePart::Ws) && host_matches?(r.host, host)
        end
      end
    end

    def rewrite_ws_out(payload : Bytes, host : String) : Bytes
      apply(payload, Store::RuleTarget::Request, Store::RulePart::Ws, @ws_out_count, host)
    end

    def rewrite_ws_in(payload : Bytes, host : String) : Bytes
      apply(payload, Store::RuleTarget::Response, Store::RulePart::Ws, @ws_in_count, host)
    end

    # --- short circuit (#511) ------------------------------------------------

    def short_circuits? : Bool
      @short_circuit_count.get > 0
    end

    # `short_circuits?` narrowed to one host (#526) — the same split, and for the same
    # reason, as `rewrites_body_for_host?` above. The host filter is exactly the one
    # `short_circuit` itself applies, so this answers "could `short_circuit` ever return a
    # stub for this host", which is precisely what the downgrade gate is protecting.
    def short_circuits_for_host?(host : String) : Bool
      return false if @short_circuit_count.get == 0 # lock-free fast path
      @mutex.synchronize do
        @rules.any? do |r|
          r.enabled? && r.op.short_circuit? && !r.pattern.empty? && host_matches?(r.host, host)
        end
      end
    end

    # The stub answering this request head, or nil when no rule claims it. The FIRST matching
    # rule in the applied order wins and the rest are not consulted — a stub terminates the
    # exchange, so "apply them all in order" (what the rewrite ops do) has no meaning here.
    def short_circuit(head : Bytes, host : String) : Proxy::HeadRewriter::Stub?
      return nil if @short_circuit_count.get == 0 # lock-free fast path
      active = @mutex.synchronize do
        @rules.select do |r|
          r.enabled? && r.op.short_circuit? && !r.pattern.empty? && host_matches?(r.host, host)
        end
      end
      return nil if active.empty?
      text = String.new(head)
      rule = active.find { |r| stub_matches?(r, text) }
      rule ? stub_for(rule) : nil
    end

    # Whether a stub rule's pattern claims this request head. Same literal/regex split the
    # `Replace` op uses, so `match:` means the same thing on both. A regex that fails to
    # compile (or meets non-UTF-8 bytes) does NOT match — the rule stays inert rather than
    # capturing every request, which is the safe direction for an op that stops traffic.
    private def stub_matches?(rule : Store::MatchRule, text : String) : Bool
      if rule.match_kind.regex?
        begin
          SafeRegexp.compile(rule.pattern).matches?(text)
        rescue
          false
        end
      else
        text.includes?(rule.pattern)
      end
    end

    # Build the response bytes for a matched stub rule. Never returns nil: once a rule has
    # claimed the request, gori answers it. An unparseable stub or an unreadable `body_file`
    # becomes a gori-authored 502 carrying the reason, which ClientConn records on the flow —
    # falling through to the origin instead would send a request the operator declared
    # contained, and a payload leaking because a stub file was deleted is the worse failure.
    private def stub_for(rule : Store::MatchRule) : Proxy::HeadRewriter::Stub
      head = RuleStub.parse_head(rule.replacement)
      return stub_failure(rule, "stub response head could not be parsed") unless head
      body = if rule.body_file.empty?
               RuleStub.inline_body(rule.replacement)
             else
               begin
                 @stub_bodies.read(rule.body_file)
               rescue ex : Gori::Error
                 return stub_failure(rule, ex.message || "stub body file unreadable")
               end
             end
      Proxy::HeadRewriter::Stub.new(head.bytes, body, head.status, rule.id)
    end

    # gori's own answer when a rule cannot be honoured. Unlike a stub, this one IS marked on
    # the wire (`X-Gori-Short-Circuit: error`): the operator's bytes go out untouched, but
    # bytes gori invented say so.
    private def stub_failure(rule : Store::MatchRule, message : String) : Proxy::HeadRewriter::Stub
      # Names the SCOPE as well as the id: the two stores number rules independently, so
      # "rule #3" would send the operator to the wrong list half the time.
      body = "gori: short-circuit #{rule.scope.label} rule ##{rule.id} could not be applied: #{message}\n".to_slice
      head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nX-Gori-Short-Circuit: error\r\n".to_slice
      Proxy::HeadRewriter::Stub.new(head, body, 502, rule.id, error: message)
    end

    # Live preview for the Rewriter tab: apply every enabled rule for `target` over a
    # full HTTP message (head + body split on the first blank line). Host-scoped rules
    # use `host` (typically parsed from the sample's Host header). Empty host → only
    # unscoped rules match. Order matches the proxy path (head rules then body rules).
    #
    # `report: false` — a preview is a keystroke path over stored flows and must not write
    # an "unbound binding" event per keypress. It still SKIPS such a rule, so the preview
    # shows the operator what the proxy would really do.
    #
    # `run_hooks: false` is for a caller that redraws — the Rewriter tab's OUTPUT pane calls
    # this ONCE PER FRAME. A `pipe` rule there would fork the operator's command sixty times a
    # second over a sample they are merely looking at, and a hook is by definition allowed to
    # have side effects. Such a rule is skipped instead (its region passes through) and the
    # pane says so. The default is TRUE, because the other caller — `mcp/tools/send.cr` — is a
    # real send, where the rule has to do what it says it does.
    def transform_message(text : String, target : Store::RuleTarget, host : String = "",
                          run_hooks : Bool = true) : String
      head, body, sep = split_message(text)
      new_head = String.new(apply(head.to_slice, target, Store::RulePart::Head,
        target.request? ? @req_head_count : @resp_head_count, host, report: false, run_hooks: run_hooks))
      new_body = String.new(apply(body.to_slice, target, Store::RulePart::Body,
        target.request? ? @req_body_count : @resp_body_count, host, report: false, run_hooks: run_hooks))
      "#{new_head}#{sep}#{new_body}"
    end

    # Whether a `pipe` rule is live for this side and host — what a preview surface asks so it
    # can say that the transform it is showing left one out. Same lock-free-then-check shape as
    # `rewrites_body_for_host?`, and off any hot path: a redraw, not a message.
    # `Head` and `Body` only, through the same `rewrites?` predicate every other liveness gate
    # in this file uses. A `part: ws` pipe rule is not reachable from a preview that splits an
    # HTTP sample into a head and a body, and counting it made the pane tell the operator its
    # output was incomplete when it was exact.
    def pipes_for?(target : Store::RuleTarget, host : String) : Bool
      rules = @mutex.synchronize { @rules }
      rules.any? do |r|
        next false unless r.op.pipe? && host_matches?(r.host, host)
        rewrites?(r, target, Store::RulePart::Head) || rewrites?(r, target, Store::RulePart::Body)
      end
    end

    # Split an HTTP message into {head, body, separator}. Separator is "\r\n\r\n" or
    # "\n\n" when a blank line exists; otherwise the whole text is the head and sep/body
    # are empty (so header-only samples still rewrite).
    #
    # The EARLIEST blank line wins, in either spelling. Preferring `\r\n\r\n` wherever it
    # appeared let the message's own BODY move the boundary: the Rewriter preview feeds
    # LF-joined text (`TextArea#text`), so a pasted sample whose body carries a CRLFCRLF —
    # a multipart part, a captured message — put the CRLF hit after the real separator, and
    # the preview then ran the HEAD rules inside the body and the body rules over the head.
    # It showed the operator the opposite of what the proxy does. Same defect as the one
    # fixed in `RuleStub.split`; two spellings of one delimiter take min(index), never a
    # fixed preference order.
    private def split_message(text : String) : {String, String, String}
      crlf = text.index("\r\n\r\n")
      lf = text.index("\n\n")
      if crlf && (lf.nil? || crlf < lf)
        {text[0, crlf], text[crlf + 4..], "\r\n\r\n"}
      elsif lf
        {text[0, lf], text[lf + 2..], "\n\n"}
      else
        {text, "", ""}
      end
    end

    # Apply every enabled rule for {target, part} that also matches `host` over the bytes.
    # Returns the SAME bytes when nothing is configured or nothing is in scope (byte-
    # fidelity, P7). A no-op replace re-serializes to an equal slice (as it always has for
    # heads) — ClientConn's body path compares content, so an unchanged body still frames
    # byte-exact.
    private def apply(bytes : Bytes, target : Store::RuleTarget, part : Store::RulePart,
                      count : Atomic(Int32), host : String, report : Bool = true,
                      run_hooks : Bool = true) : Bytes
      return bytes if count.get == 0 # lock-free fast path: no rules to apply
      # `@rules` is REPLACED on every edit, never mutated in place (see `refresh`), so a bare
      # reference read under the lock is a consistent snapshot with NO allocation — where the
      # old path minted a filtered `select` Array on EVERY proxied head and buffered body. The
      # scope predicate is re-checked inline in the loop instead, and `String.new(bytes)` — the
      # whole-body copy — is deferred to the FIRST rule that is actually in scope for this
      # {target, part, host}, so a message no rule targets (e.g. a body rule scoped to another
      # host) pays neither the Array nor the copy. `host_matches?`/`apply_rule` already ran
      # outside the lock (the old `active.each` did), so nothing new is read unsynchronised.
      rules = @mutex.synchronize { @rules }
      text = nil.as(String?)
      # ONE hook budget for this whole rewrite, shared by every pipe rule in it. Per-RULE
      # deadlines would have multiplied: three enabled pipe rules at the 60s ceiling could hold
      # one head for three minutes, which is not a bound at all. Built lazily so a rewrite with
      # no pipe rule reads no clock.
      pipe_deadline = nil.as(Time::Instant?)
      rules.each do |r|
        next unless rewrites?(r, target, part) && host_matches?(r.host, host)
        next if r.op.pipe? && !run_hooks # see `transform_message`
        pipe_deadline ||= Time.instant + Rules.pipe_budget if r.op.pipe?
        cur = text
        if cur.nil?
          cur = String.new(bytes)
          # A WS message is arbitrary application bytes, and `gsub` over a String holding
          # invalid UTF-8 turns those bytes into U+FFFD — so a rule would corrupt a payload it
          # never even matched. Gate rather than `scrub`: 9 µs vs 130 µs on a 40 KB payload, and
          # this is a per-MESSAGE path, not a per-response one. Heads and bodies keep their
          # pre-existing behaviour (a body rule simply won't match a compressed body).
          return bytes if part.ws? && !cur.valid_encoding?
        end
        text = apply_rule(cur, r, target, part, host, report, pipe_deadline)
      end
      t = text
      t ? t.to_slice : bytes # no rule in scope → same bytes, byte-fidelity preserved
    end

    # Apply ONE rule to `text` (a head or a body already decoded to a String). Returns a
    # new String, or the same content when the rule doesn't touch it. A bad regex or a
    # regex over non-UTF-8 bytes is swallowed → the text passes through unchanged.
    private def apply_rule(text : String, rule : Store::MatchRule,
                           target : Store::RuleTarget, part : Store::RulePart, host : String,
                           report : Bool = true, pipe_deadline : Time::Instant? = nil) : String
      # A rule naming a binding that has no value is NOT applied. Nothing else is a safe
      # answer: injecting `""` sends a request with an empty session header, and injecting
      # the literal `$SESSION` — which is what `Env.expand` does with an unknown key
      # (env.cr) — puts eight meaningless characters on the wire in a credential's place.
      # The operator hears about it through the event feed rather than through a 401.
      # `Pipe` is resolved differently and must not come through here: `replacement_for`
      # expands `$KEY` across the WHOLE string, and for an argv that is an argument-injection
      # primitive — see `pipe_argv`. It resolves per element instead.
      return pipe_apply(text, rule, target, part, host, report, pipe_deadline) if rule.op.pipe?
      repl = replacement_for(rule)
      if repl.is_a?(Refused)
        report_refused(rule, repl) if report
        return text
      end
      case rule.op
      in Store::RuleOp::Replace
        if rule.match_kind.regex?
          begin
            text.gsub(SafeRegexp.compile(rule.pattern), repl)
          rescue
            text
          end
        else
          # `&block`, not `text.gsub(rule.pattern, repl)`: when `rule.pattern` is a single
          # byte, `String#gsub(String, String)` delegates to the `Char` overload, which (for
          # a multi-byte `repl`) walks ALL of `text` with `each_char` — corrupting every
          # invalid UTF-8 byte anywhere in the message, matched or not, to U+FFFD. A body is
          # captured bytes and a one-character literal pattern is an ordinary operator
          # choice, so this reached the wire on any binary body a single-char rule happened
          # to touch. The block form scans by byte index and copies with `unsafe_byte_slice`
          # — byte-exact regardless of what `text` or `repl` contain.
          text.gsub(rule.pattern) { repl }
        end
      in Store::RuleOp::AddHeader    then head_add_header(text, rule.pattern, repl)
      in Store::RuleOp::SetHeader    then head_set_header(text, rule.pattern, repl)
      in Store::RuleOp::RemoveHeader then head_remove_header(text, rule.pattern)
      in Store::RuleOp::ShortCircuit then text # answers, never rewrites — `apply` filters it out
      in Store::RuleOp::Pipe         then text # handled above, before the whole-string resolve
      end
    end

    # --- pipe (#818): the replacement is COMPUTED by an external command --------------------

    # How long the pipe rules of ONE rewrite may hold it, across every rule and every match in
    # it. This is the P6 guarantee at the rewrite seam and it is a BUDGET, not a per-spawn
    # timeout, because the two answer different questions: a per-spawn timeout bounds one child,
    # and a regex matching four hundred times in a body would multiply it by four hundred while
    # the client waits. Per-RULE would multiply it too, by however many pipe rules the operator
    # has. So `apply` mints ONE deadline and every pipe rule in that call shares it; the
    # remaining time is what each match gets, and once it is gone every remaining match passes
    # through UNCHANGED with one notice.
    #
    # The bound a MESSAGE sees is two of these — `apply` is called once for the head and once
    # for the body, and they are separate rewrites of separate bytes — plus, per overrunning
    # spawn, `ProcessHook`'s own kill and collect graces.
    def self.pipe_budget : Time::Span
      Settings.hook_timeout_secs.seconds
    end

    # Feed every matched region to the rule's command and splice its stdout back in.
    #
    # THE FAILURE PATH IS THE FEATURE. A command that will not parse, will not spawn, times
    # out, exits non-zero or overruns `ProcessHook::MAX_OUTPUT` leaves the matched bytes
    # EXACTLY as they arrived — the message keeps flowing, the flow is never dropped and the
    # proxy never blocks on it (P6) — and the reason is written to the event feed as a
    # non-fatal notice. There is no "fail closed" option here worth having: refusing the
    # message would take the operator's traffic down over their own script, and injecting a
    # partial or empty replacement would put corrupt bytes on the wire (P7).
    #
    # `report: false` suppresses the EVENT, not the run — the one caller that must not run the
    # command at all passes `run_hooks: false` to `apply` and never reaches here. The two flags
    # are separate because they answer different questions: "may this write a row" and "may this
    # fork a process", and the surfaces that want one do not all want the other.
    private def pipe_apply(text : String, rule : Store::MatchRule,
                           target : Store::RuleTarget, part : Store::RulePart, host : String,
                           report : Bool, deadline : Time::Instant? = nil) : String
      built = pipe_argv(rule)
      case built
      when Refused
        report_refused(rule, built) if report
        return text
      when String
        report_hook_failure(rule, "command does not parse: #{built}") if report
        return text
      end
      argv = built.as(Array(String))
      env = nil.as(Hash(String, String)?)
      deadline ||= Time.instant + Rules.pipe_budget
      failure = nil.as(String?)
      failure_key = nil.as(String?)
      exhausted = false

      run = ->(matched : String) do
        remaining = deadline - Time.instant
        if remaining <= Time::Span.zero
          exhausted = true
          matched
        else
          # Built on the FIRST match, not per message: a rule live for a side pays nothing
          # for the messages its pattern does not appear in.
          env ||= hook_env(rule, target, part, host)
          res = ProcessHook.run(argv, matched.to_slice, remaining, env)
          if res.ok?
            String.new(res.stdout)
          else
            failure ||= res.failure
            failure_key ||= res.failure_key
            matched
          end
        end
      end

      out =
        if rule.match_kind.regex?
          begin
            text.gsub(SafeRegexp.compile(rule.pattern)) { |m| run.call(m) }
          rescue
            text
          end
        else
          # The block form, for the reason `Replace` documents above it: the `String#gsub`
          # Char overload walks the whole message with `each_char` and would turn every
          # invalid UTF-8 byte in an untouched part of a body into U+FFFD.
          text.gsub(rule.pattern) { |m| run.call(m) }
        end

      if report
        if f = failure
          report_hook_failure(rule, f, key: failure_key)
        elsif exhausted
          report_hook_failure(rule, "ran out of its #{Rules.pipe_budget.total_seconds.to_i}s " \
                                    "budget part-way through this message — the remaining " \
                                    "matches were left unchanged")
        end
      end
      out
    end

    # This rule's command as an ARGV, with `$KEY` resolved INSIDE each element.
    #
    # The order is the security property. `replacement` is tokenized FIRST and every `$KEY` is
    # then expanded within the element it sits in, so a binding's value can never add, split or
    # remove an argument however it is spelled. Resolving first and tokenizing after — which is
    # what every other op does, because for them the result is text spliced into a message —
    # would make a captured value an argument-injection primitive: `./resign.sh --key $TOKEN`
    # against an origin that mints `TOKEN` as `x --config /tmp/evil.yml` would hand the
    # operator's own script a flag it never wrote. There is no shell here, so quoting could not
    # have saved it either; the split has to not happen at all.
    #
    # `forges_boundary?` is deliberately not the guard for this (`head_scoped?` answers false
    # for a pipe rule and says why): CR and LF in an argv element forge nothing, and refusing
    # them would break a legitimate rule the first time an origin minted a cookie with a stray
    # CR. The byte that DOES matter, NUL, is refused by `ProcessHook.parse_argv` — but only in
    # the literal spec, so it is re-checked here over the resolved elements.
    #
    # Answers the argv, a `Refused` when a `$KEY` is declared-but-unbound (same disposition as
    # every other op: the rule does not apply and the operator hears about it), or a String
    # saying why the spec could not be tokenized.
    private def pipe_argv(rule : Store::MatchRule) : Array(String) | Refused | String
      parsed = ProcessHook.parse_argv(rule.replacement)
      return parsed if parsed.is_a?(String)
      out = Array(String).new(parsed.size)
      parsed.each do |tok|
        resolved = resolve_bindings(tok, rule)
        return resolved if resolved.is_a?(Refused)
        return "a binding expanded to a value containing a NUL byte" if resolved.includes?('\0')
        out << resolved
      end
      out
    end

    # The context a hook is handed, on top of the operator's own inherited environment. It is
    # deliberately only what this seam actually KNOWS: `Proxy::HeadRewriter` hands a rewrite
    # the bytes and the host and nothing else, so method/URL/status are not available here
    # without changing that interface for every rewriter. A hook that needs the request line
    # reads it off stdin — for a request-head rule the head IS the input.
    private def hook_env(rule : Store::MatchRule, target : Store::RuleTarget,
                         part : Store::RulePart, host : String) : Hash(String, String)
      {
        "GORI_HOOK"       => "rewriter",
        "GORI_RULE_NAME"  => rule.name,
        "GORI_RULE_SCOPE" => rule.scope.label,
        "GORI_TARGET"     => target.label,
        "GORI_PART"       => part.label,
        "GORI_HOST"       => host,
      }
    end

    # One warn event per (rule, message-with-a-failure). Unlike `report_refused` this is NOT
    # latched on a revision: a hook that fails intermittently (a service it calls is down for
    # ten seconds) is news every time, and there is no counter here that moves when it starts
    # working again. It is rate-limited by shape instead — the same rule reporting the same
    # sentence twice in a row is dropped — so a hook that is simply broken writes one row and
    # then stays quiet until either the rule or the failure changes.
    private def report_hook_failure(rule : Store::MatchRule, reason : String,
                                    key : String? = nil) : Nil
      rid = {rule.scope, rule.id}
      line = "rewrite rule #{(rule.name.presence || rule.pattern).inspect} pipe failed: #{reason}"
      # Suppress on `key` — the command and the failure CLASS — never on `line`, which carries
      # the child's stderr. A hook that prints a timestamp or a request id before failing makes
      # every sentence unique, and de-duplicating on the sentence then writes one SQLite row per
      # proxied message, on the data path, for one broken command.
      seen = key || line
      @mutex.synchronize do
        return if @hook_reported[rid]? == seen
        @hook_reported[rid] = seen
      end
      @store.insert_event("rewriter", "hook_failed", "warn", "#{line} (bytes passed through unchanged)")
    end

    # The replacement string this rule should actually apply, or nil when it names a
    # DECLARED binding that has no value yet (see `apply_rule`).
    #
    # This is the whole injection half of #501: `Store::MatchRule#replacement` is a literal
    # string in the database and becomes a resolved one here, at apply time. That single
    # change buys header injection (`SetHeader`/`AddHeader` with replacement `$SESSION`),
    # body injection (`Replace` with `part: Body`), static env vars in M&R rules — which
    # simply did not work before — and one syntax everywhere, with no schema change and no
    # new rule kind.
    private def replacement_for(rule : Store::MatchRule) : String | Refused
      resolve_bindings(rule.replacement, rule)
    end

    # Resolve `$KEY` in ONE piece of text on this rule's behalf. Split from `replacement_for`
    # so a pipe rule can resolve each ARGV ELEMENT separately — see `pipe_argv`.
    private def resolve_bindings(text : String, rule : Store::MatchRule) : String | Refused
      prefix = Settings.env_prefix
      # The overwhelmingly common case, and the one that must cost nothing: no `$` in the
      # replacement means the identical String comes back, exactly as before this feature.
      return text if prefix.empty? || !text.byte_index(prefix)
      vars, declared = subst_snapshot
      substitute(text, prefix, vars, declared, rule.op.replace? && rule.match_kind.regex?,
        head: head_scoped?(rule))
    end

    # Whether this rule writes into the HEAD of a message, which is where a value carrying
    # CR/LF can forge a header line or a whole second request. The three header ops write
    # header lines by construction; a `Replace` is judged by its `part`. See
    # `Bindings.boundary_forging?` for why the check lives at the injection site rather than
    # at extraction: a CR/LF in a BODY forges nothing and body injection is a designed case.
    private def head_scoped?(rule : Store::MatchRule) : Bool
      return true if rule.op.set_header? || rule.op.add_header? || rule.op.remove_header?
      # A pipe rule's "replacement" is an ARGV, not text spliced into a message: a `$KEY` in it
      # becomes one element of an `execvp` vector, where a CR or an LF is an ordinary byte and
      # cannot forge a header line or a second request. Judging it by `part` would refuse a
      # head-scoped pipe rule the moment an origin minted a cookie with a stray CR in it, and
      # tell the operator it "would forge a message boundary in a header" — which for this op
      # is simply not true. (A NUL still can't get through: `ProcessHook.parse_argv` refuses
      # one, because `execvp` would truncate the argument there and run a different command.)
      return false if rule.op.pipe?
      rule.part.head?
    end

    # ONE left-to-right pass that resolves `$NAME`, translates the Caido-style `$1` capture
    # ref to Crystal's `\1`, and unescapes `$$` → `$`. One pass and not three, because the
    # order between them is the whole safety argument:
    #
    #   * `$1` cannot collide with a binding name — `Env::KEY_HEAD` is `[A-Za-z_]`, so a
    #     digit never starts a key — but a substituted VALUE containing `$1` would be read
    #     as a capture ref if this ran `regex_replacement` afterwards over the result. It
    #     does not: a value is emitted and never re-scanned.
    #   * `$$` resolves LAST in meaning: `$$SESSION` is the literal text `$SESSION`, not the
    #     bound value. That is the only way an operator can write a literal `$NAME` at all.
    #     (New for the literal-replace and header ops, which previously had no escape
    #     because they had nothing to escape from.)
    #   * A binding value is **server-controlled**, and for `MatchKind::Regex` the
    #     replacement is interpreted by `gsub`: Crystal reads `\1`, `\0` and `\k<name>` in a
    #     replacement string, so a token containing `\1` would splice a capture group into
    #     the wire bytes and one containing `\k<x>` raises. `escape_backrefs` doubles every
    #     backslash in a substituted value before it lands there. `$` needs no escaping —
    #     Crystal's replacement grammar does not read it — and the literal-replace and the
    #     three header ops interpret nothing at all, so they take the value verbatim.
    #
    # Byte-level for the same reason `Env.expand` is: a BODY replacement can carry bytes
    # that are not valid UTF-8, and `String#chars` would turn each of them into U+FFFD.
    private def substitute(repl : String, prefix : String, vars : Hash(String, String),
                           declared : Array(String), regex : Bool, head : Bool = false) : String | Refused
      bytes = repl.to_slice
      prefix_bytes = prefix.to_slice
      n = bytes.size
      plen = prefix_bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        unless prefix_at?(bytes, prefix_bytes, i)
          buf.write_byte(bytes[i])
          i += 1
          next
        end
        # `$$` → one literal prefix, consuming both.
        if prefix_at?(bytes, prefix_bytes, i + plen)
          buf << prefix
          i += 2 * plen
          next
        end
        if parsed = Env.read_key_bytes?(bytes, i + plen, n)
          key, consumed = parsed
          # Declared by an extract rule but not bound yet → the rule must not apply.
          #
          # The send seams stopped refusing on this (see `Env.unbound`): everywhere else a
          # `$NAME` with no value is a literal on the wire. This one stays, and it is not the
          # same disposition wearing a different hat:
          #
          #   * It is a rule-scoped SKIP, not a send refusal. Nothing is blocked — the message
          #     reaches the origin, just unrewritten. The policy that changed was about gori
          #     refusing to send bytes the operator authored; here it sends them.
          #   * A `replacement` is a REFERENCE by construction. It is the one field in the
          #     product whose only purpose is to inject a value, so there is no captured-body
          #     collision to protect: nobody's GraphQL document lands in this column by
          #     accident. Emitting the seven characters `$SESSION` into an `Authorization`
          #     header instead would put a known-wrong credential on EVERY proxied request,
          #     silently, for as long as the rule is enabled.
          #   * The two halves of the policy that actually matter against a collision are
          #     already here and predate it: `$$` is the escape (below), and a name that is
          #     neither a var nor declared stays LITERAL (`emit_key`).
          #
          # `report_refused` writes one warn event per (rule, binding revision) naming it.
          return Refused.new(Refusal::Unbound, key) if !vars.has_key?(key) && declared.includes?(key)
          return Refused.new(Refusal::Boundary, key) if head && forges_boundary?(vars, declared, key)
          i += emit_key(buf, bytes, vars, key, consumed, prefix, plen, regex)
          next
        end
        # `$1`..`$9` → `\1`..`\9`, regex replacements only (unchanged from `regex_replacement`).
        if regex && i + plen < n && bytes[i + plen].chr.ascii_number?
          buf << '\\'
          buf.write_byte(bytes[i + plen])
          i += plen + 1
          next
        end
        buf << prefix
        i += plen
      end
      String.new(buf.to_slice)
    end

    # Whether resolving `key` here would write a boundary-forging value into a HEAD, in which
    # case the rule must not apply at all — the same disposition an unbound name gets, and for
    # a stronger reason. A server-controlled `abc\r\nX-Admin: true` in a `SetHeader`
    # replacement becomes two header lines the origin reads as its own. Only for a BINDING
    # (`declared`): an env var is the operator's own bytes and stays byte-exact (P7), and only
    # in the head — the same value in a BODY replacement forges nothing, which is the designed
    # case `Env.expand_bindings` documents.
    private def forges_boundary?(vars : Hash(String, String), declared : Array(String),
                                 key : String) : Bool
      return false unless declared.includes?(key)
      (v = vars[key]?) ? Bindings.boundary_forging?(v) : false
    end

    private def prefix_at?(bytes : Bytes, prefix_bytes : Bytes, at : Int32) : Bool
      return false if at + prefix_bytes.size > bytes.size
      prefix_bytes.each_with_index.all? { |b, j| bytes[at + j] == b }
    end

    # Write one resolved (or literal) `prefix+KEY` and answer how many bytes it consumed.
    # A key that is neither a var nor a declared binding stays LITERAL — `Env.expand`'s
    # documented contract, and the meaning every pre-existing rule already had. Refusing
    # here instead would be a one-way door on a persisted, operator-authored table.
    private def emit_key(buf : IO::Memory, bytes : Bytes, vars : Hash(String, String),
                         key : String, consumed : Int32, prefix : String,
                         plen : Int32, regex : Bool) : Int32
      if val = vars[key]?
        buf << (regex ? Rules.escape_backrefs(val) : val)
        plen + consumed
      else
        buf << prefix
        plen
      end
    end

    # Double every backslash so a substituted value cannot be read as a capture reference
    # by `String#gsub(Regex, String)`. `gsub(String, String)` interprets nothing, so this is
    # applied to the regex path alone.
    #
    # Byte-scanned, not `value.gsub("\\", "\\\\")`: a 1-byte `String` needle makes `gsub`
    # delegate to the `Char` overload, which walks the value with `each_char` and rewrites
    # any invalid UTF-8 byte to U+FFFD — three wire bytes for one. A `value` bound from
    # `TokenExtract.position` is exactly the case this bites: it is `String.new`'d
    # unscrubbed off a captured byte range (see the comment there), so it can carry
    # arbitrary bytes on the way into a regex-rule replacement.
    def self.escape_backrefs(value : String) : String
      bytes = value.to_slice
      return value unless bytes.includes?(0x5C_u8)
      buf = IO::Memory.new(bytes.size + 8)
      bytes.each do |b|
        buf.write_byte(0x5C_u8) if b == 0x5C_u8
        buf.write_byte(b)
      end
      String.new(buf.to_slice)
    end

    # Env vars + currently-bound bindings, plus the declared-name list, cached until either
    # moves. `Env.expand`'s default argument rebuilds a merged Hash on EVERY call
    # (`env.cr`, and `highlight.cr` already carries a comment warning about it) — and this
    # runs on the proxy path per message per matching rule, so calling `display_vars` here
    # would be a per-message allocation. `Env.bump_highlight_rev` fires on a settings load,
    # a project env write, a rule edit and every rebind, which is exactly the set of events
    # that can move either half.
    private def subst_snapshot : {Hash(String, String), Array(String)}
      erev = Env.highlight_rev
      brev = Env.binding_rev
      cached = @subst_vars
      if cached.nil? || erev != @subst_env_rev || brev != @subst_binding_rev
        cached = Env.display_vars
        @subst_vars = cached
        @subst_declared = Env.declared_bindings
        @subst_env_rev = erev
        @subst_binding_rev = brev
      end
      {cached, @subst_declared}
    end

    # One warn event per (rule, binding revision): a rule injecting an unbound `$SESSION`
    # into every proxied request would otherwise write one row per message. The value is
    # never in the message — only the rule, the name and, for a boundary refusal, which byte
    # class was found, which is what #491 asked for.
    #
    # Keyed on `Env.binding_rev` and not latched forever, so the report self-resets exactly
    # when it becomes news again: that revision moves on every rebind, every clear and every
    # extract-rule edit, which is the whole set of events that can change either answer.
    private def report_refused(rule : Store::MatchRule, refused : Refused) : Nil
      brev = Env.binding_rev
      if brev != @unbound_reported_rev
        @unbound_reported_rev = brev
        @unbound_reported.clear
      end
      return unless @unbound_reported.add?({rule.scope, rule.id})
      label = rule.name.presence || rule.pattern
      case refused.reason
      in Refusal::Unbound
        names = Env.unbound(rule.replacement)
        return if names.empty?
        @store.insert_event("bindings", "unbound", "warn",
          "rewrite rule #{label.inspect} not applied: #{Env.token_list(names)} is not bound yet")
      in Refusal::Boundary
        vars, _ = subst_snapshot
        classes = Bindings.boundary_bytes(vars[refused.key]? || "")
        # Empty only if the value changed between the refusal and here, which is a rebind and
        # therefore a new revision — say nothing rather than name a byte class that is no
        # longer in the value.
        return if classes.empty?
        @store.insert_event("bindings", "boundary_refused", "warn",
          "rewrite rule #{label.inspect} not applied: #{Env.token_list([refused.key])}'s value " \
          "carries #{Rules.and_list(classes)} and would forge a message boundary in a header " \
          "(the value is still bound — a body-scoped rule can carry it)")
      end
    end

    # "CR" / "CR and LF" / "CR, LF and NUL". Small enough that reaching for a helper module
    # would cost more than it saves, and the refusal above is its only caller.
    def self.and_list(items : Array(String)) : String
      return items.first? || "" if items.size <= 1
      "#{items[0..-2].join(", ")} and #{items[-1]}"
    end

    # The EOL to give a header line this code ADDS — CRLF for real HTTP, LF as a fallback so
    # a hand-authored / test head still round-trips. It answers for the head as a WHOLE, which
    # is all a new line needs; existing lines keep whatever spelling they arrived with, which
    # is `head_lines`' job.
    private def eol_of(text : String) : String
      text.includes?("\r\n") ? "\r\n" : "\n"
    end

    # `head` split at its LINE breaks, every line still carrying its own trailing `\r` when it
    # had one. The last element is the remainder after the final newline (usually ""), not a
    # line.
    #
    # Splitting on LF and keeping the CR is the whole point. A head is SUPPOSED to be CRLF the
    # whole way down, but a bare-LF header line is exactly the shape a request-smuggling probe
    # puts on the wire — and gori is the tool an operator points at those. The three ops below
    # used to split on `eol_of`, one answer for the whole head, so a single bare-LF break made
    # them read two headers as one "line":
    #
    #   `GET / HTTP/1.1\r\nHost: a\nX-Keep: 1\r\n\r\n`
    #     remove_header "Host"  dropped `X-Keep: 1` with it
    #     set_header    "Host"  overwrote `X-Keep: 1` out of existence
    #
    # …and a head whose terminator was `\n\n` while a CRLF appeared earlier had
    # `add_header`'s `rindex("\r\n\r\n")` miss, so the new header was appended AFTER the blank
    # line — into the BODY, where the origin never reads it as a header at all. All three are
    # silent: the operator sees a rule that "ran" and a header that is gone, or absent.
    private def head_lines(head : String) : Array(String)
      head.split('\n')
    end

    # Whether a `head_lines` entry is a BLANK line: empty, or the lone `\r` such an entry keeps
    # when the head is CRLF-delimited. Everything else below reads the entry as-is — a `:` and
    # the field name in front of it both sit before the trailing CR, so nothing has to chomp it
    # off (and allocate a second String per header line on a per-message path) to find them.
    private def blank_line?(line : String) : Bool
      line.empty? || line == "\r"
    end

    # Whether a `head_lines` entry is an obs-fold CONTINUATION — a line whose first byte is SP
    # or HTAB. RFC 9112 §5.2 makes it part of the PREVIOUS field's value, not a header of its
    # own, and that is the SECOND line view one message carries: `head_lines` sees N lines where
    # the field parser sees fewer fields. The two ops below used to read every line as a header,
    # which broke both ways at once —
    #
    #   `HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self';\r\n script-src 'none'\r\n`
    #     remove_header "Content-Security-Policy"  left ` script-src 'none'` behind as the FIRST
    #     header line, i.e. gori manufactured a malformed head out of a well-formed one; the same
    #     orphan under a `set_header Content-Length: 3` unfolds to `3 5` in a lenient recipient.
    #
    #   `HTTP/1.1 200 OK\r\nX-Note: hello\r\n X-Inner: folded\r\n`
    #     set_header "X-Inner"  matched the CONTINUATION (`ln[0, ci].strip` erases the leading
    #     SP), so `found` went true, the operator's header was never added to the wire at all,
    #     and `X-Note`'s value was rewritten in its place. Silent on both counts.
    #
    # Reachable on the RESPONSE leg: the request leg raises on `Http1.obfuscated_header?` in
    # `Codec::Body.request_framing` and re-pins CL/TE in `restore_framing_headers` afterwards,
    # while `apply_response_rewrite` has no counterpart and `Http1.framing_ambiguous?` only ever
    # compares the FRAMING headers. `Env.fold_or_blank?` refuses a folded Content-Length edit for
    # exactly this reason; this is the same rule, kept by the ops rather than by a refusal.
    #
    # First BYTE, not `starts_with?(' ')`: a header line is captured bytes and can be invalid
    # UTF-8 (obs-text in the value it continues), where char iteration answers about U+FFFD.
    private def fold_line?(line : String) : Bool
      return false if line.empty?
      b = line.to_slice[0]
      b == 0x20_u8 || b == 0x09_u8
    end

    # Where the blank line that TERMINATES the head sits in `head_lines`, or nil when the head
    # carries none — the preview path splits the separator off (`split_message`) and a
    # hand-authored sample may simply not have one. Index 0 is the start line and the trailing
    # element is the remainder after the last newline, so neither is a candidate.
    private def terminator_index(lines : Array(String)) : Int32?
      (1...lines.size - 1).find { |i| blank_line?(lines[i]) }
    end

    # Append `Name: value` as the LAST header, just before the terminating blank line. If the
    # head has no blank-line terminator, append at the end.
    private def head_add_header(head : String, name : String, value : String) : String
      eol = eol_of(head)
      line = "#{name}: #{value}"
      lines = head_lines(head)
      if i = terminator_index(lines)
        lines.insert(i, eol == "\r\n" ? "#{line}\r" : line)
        lines.join('\n')
      elsif head.ends_with?('\n')
        "#{head}#{line}#{eol}"
      else
        "#{head}#{eol}#{line}"
      end
    end

    # Replace the value of every header named `name` (case-insensitive, original casing and
    # the line's own terminator kept); if none exists, append it (upsert). The start line and
    # blank lines are left untouched.
    #
    # An obs-fold continuation of the field being set is part of the VALUE being replaced, so it
    # goes with it (`fold_line?`). One of any other field is carried through untouched, and is
    # never tested for the name.
    private def head_set_header(head : String, name : String, value : String) : String
      target = name.downcase
      found = false
      in_target = false
      out = [] of String
      head_lines(head).each_with_index do |ln, i|
        if i == 0 || blank_line?(ln)
          in_target = false
          out << ln
        elsif fold_line?(ln)
          # Part of the field ABOVE, whatever it is: dropped with a replaced value, kept with
          # every other one. Never a name.
          out << ln unless in_target
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          found = true
          in_target = true
          out << (ln.ends_with?('\r') ? "#{ln[0, ci]}: #{value}\r" : "#{ln[0, ci]}: #{value}")
        else
          in_target = false
          out << ln
        end
      end
      found ? out.join('\n') : head_add_header(head, name, value)
    end

    # Drop every header line named `name` (case-insensitive), and with it every obs-fold
    # continuation of that field — a continuation left behind becomes a header line of its own
    # in the head gori writes back, which is a malformed head manufactured out of a valid one.
    # The start line (index 0) and any blank lines are always kept, so the head stays
    # well-formed.
    private def head_remove_header(head : String, name : String) : String
      target = name.downcase
      kept = [] of String
      dropping = false
      head_lines(head).each_with_index do |ln, i|
        if i == 0 || blank_line?(ln)
          dropping = false
          kept << ln
        elsif fold_line?(ln)
          kept << ln unless dropping # continues the field above, so it shares its fate
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          dropping = true # drop this header
        else
          dropping = false
          kept << ln
        end
      end
      kept.join('\n')
    end

    private def host_matches?(glob : String, host : String) : Bool
      Rules.host_matches?(glob, host)
    end

    # Does `host` satisfy a rule's host glob? Empty = all hosts. A glob with `*` is an
    # anchored wildcard (`*.example.com`); without `*` it matches the host ITSELF or any
    # SUBDOMAIN of it, case-insensitively (`example.com` matches `example.com` and
    # `api.example.com`, but not `xexample.com` or `example.com.evil.net`).
    #
    # Exposed on the class because an extract rule (#501) carries the same host glob and
    # must mean the same thing by it — an operator who learned the dialect in the Rewriter's
    # `rules` sub-tab types it again two sub-tabs over. NOT `HostPattern`, which is Scope's
    # separate suffix-matching dialect.
    def self.host_matches?(glob : String, host : String) : Bool
      return true if glob.empty?
      h = host.downcase
      g = glob.downcase
      if g.includes?('*')
        # Compile the glob→regex ONCE per distinct glob, not per proxied head. host_matches?
        # runs on the hot path for EVERY request/response head while any head rule is active
        # (including messages the rule doesn't target — the scope test is what decides that),
        # so an uncached Regex.new here was a PCRE2 compile per message. SafeRegexp memoises.
        # `\A`/`\z`, not `^`/`$`: PCRE2's `$` also matches just BEFORE a trailing newline, so
        # a host carrying one — an `:authority` is peer-controlled HPACK bytes, not a parsed
        # name — satisfied a glob it does not equal. The absolute anchors are what make this
        # test mean "the whole host", the way the DNS-label branch below already does.
        rx = "\\A#{Regex.escape(g).gsub("\\*", ".*")}\\z"
        begin
          SafeRegexp.compile(rx).matches?(h)
        rescue
          false
        end
      else
        # DNS LABEL boundaries, not a raw substring. The dialect's intent is "this host and
        # its subdomains" — the doc's own example is `example.com` matching `api.example.com`
        # — but `includes?` also matched anything that merely CONTAINED the string, so a rule
        # scoped to `alpha.test` fired on `xalpha.test`, `alpha.testing.com` and
        # `alpha.test.evil.com`. This gate backs EVERY rule op (body, ws, short_circuit, head
        # and header) and the extract rules that mint session bindings, so on a tool whose
        # rules inject credentials (`SetHeader $SESSION`) or answer requests itself
        # (`short_circuit`) that over-match sends the operator's secret to, or fakes a
        # response for, a host they never scoped — one an attacker can simply register.
        # `*` stays the explicit wildcard for anything wider.
        h == g || h.ends_with?(g.starts_with?('.') ? g : ".#{g}")
      end
    end

    # --- preview (shared by the Rewriter tab's test row + the MCP preview_rule tool) ---

    RULE_PREVIEW_SCAN = 500

    # Cap the body bytes pulled per flow for a BODY rule preview: this runs on the
    # interactive keystroke path, so never fetch multi-MiB bodies. Head/header rules read
    # no body at all (body_max: 0). A body match past the cap is missed — acceptable since
    # the preview is already documented as approximate.
    RULE_PREVIEW_BODY_MAX = 64 * 1024

    # Cap the captured WS messages read per flow for a `part: ws` preview, for the same
    # keystroke-path reason: a chatty socket can hold thousands of rows. The MOST RECENT
    # ones are read (`Store#ws_messages`'s `limit` semantics), which is what an operator
    # tuning a rule is looking at.
    RULE_PREVIEW_WS_MAX = 50

    record Preview, scanned : Int32, matched : Int32, total : Int64

    # How many of up to `limit` recent stored flows a candidate rule WOULD affect, by
    # replaying the SAME transform the live proxy uses (so regex / header ops / host-scope
    # are all reflected). Nothing is written. Approximate: bodies are scanned as STORED
    # (possibly compressed) wire bytes, so a text pattern mainly reflects head/text hits.
    def preview(rule : Store::MatchRule, limit : Int32 = RULE_PREVIEW_SCAN) : Preview
      scanned = 0
      matched = 0
      # Head/header rules never touch the body, so fetch head-only; body rules cap the
      # fetched bytes. Without this the preview pulled every flow's FULL request+response
      # body into memory per keystroke, stalling proportionally to stored body size.
      body_max = rule.part.body? ? RULE_PREVIEW_BODY_MAX : 0
      @store.recent_flows(limit, nil).each do |row|
        detail = @store.get_flow(row.id, body_max: body_max)
        next unless detail
        scanned += 1
        matched += 1 if rule_affects?(rule, detail)
      end
      Preview.new(scanned, matched, @store.count)
    end

    # Whether applying `rule` to the relevant part of `detail` would change its bytes — or,
    # for a short-circuit rule, whether it would have ANSWERED that flow instead of letting
    # it reach the origin. Same question the preview line asks of every other op ("how many
    # of your recent flows does this touch"), and the more useful one for a stub: it tells
    # the operator what they are about to stop sending.
    private def rule_affects?(rule : Store::MatchRule, detail : Store::FlowDetail) : Bool
      return false unless host_matches?(rule.host, detail.row.host)
      return stub_matches?(rule, String.new(detail.request_head)) if rule.op.short_circuit?
      return false if rule.op.header? && !rule.part.head?
      return ws_rule_affects?(rule, detail) if rule.part.ws?
      bytes = flow_part_bytes(detail, rule)
      return false unless bytes
      return pattern_matches?(rule, String.new(bytes)) if rule.op.pipe?
      apply_rule(String.new(bytes), rule, rule.target, rule.part, detail.row.host, report: false).to_slice != bytes
    end

    # A pipe rule is counted by whether its PATTERN matches, not by whether the transform
    # changes the bytes — the only question the other ops can answer without running anything.
    #
    # This is the one place the preview deliberately answers a NARROWER question than the wire
    # does, and the reason is arithmetic: `preview` replays a candidate rule over
    # RULE_PREVIEW_SCAN (500) recent flows on the rule editor's keystroke path, and "does the
    # output differ" for a pipe rule means SPAWNING THE OPERATOR'S COMMAND ONCE PER FLOW. Five
    # hundred processes per keystroke is not a preview, it is a fork bomb with a text field in
    # front of it — and it would run a side-effecting script (that is what a hook IS) five
    # hundred times over traffic the operator only asked to look at. So the row counts the
    # flows the command would be RUN ON, which is the honest thing to say about a rule whose
    # output nobody can predict from the row.
    #
    # No preview surface runs a pipe rule at all: the OUTPUT pane's single-sample transform
    # passes `run_hooks: false` for the same reason one notch louder (it redraws per frame) and
    # says so in the pane. A pipe rule is tried on the wire, not in a preview.
    private def pattern_matches?(rule : Store::MatchRule, text : String) : Bool
      if rule.match_kind.regex?
        !!SafeRegexp.compile(rule.pattern).match(text)
      else
        text.includes?(rule.pattern)
      end
    rescue
      false
    end

    # The `part: ws` half of `rule_affects?`. A WS rule's subject is not in `FlowDetail` at
    # all — the messages live in their own table — so the preview reads them from
    # `Store#ws_messages`, which is the same projection the detail view and export show.
    # Only a 101 flow can have any, so a non-upgrade flow costs no query.
    #
    # The three filters here are exactly the live relay's: direction from the rule's target,
    # text opcode only (a binary message is never rewritten, so counting it would promise a
    # match the proxy will not make), and valid UTF-8.
    private def ws_rule_affects?(rule : Store::MatchRule, detail : Store::FlowDetail) : Bool
      return false unless detail.row.status == 101
      want_out = rule.target.request?
      @store.ws_messages(detail.row.id, RULE_PREVIEW_WS_MAX).any? do |msg|
        next false unless msg.text?
        next false unless (msg.direction == "out") == want_out
        text = String.new(msg.payload)
        next false unless text.valid_encoding?
        next pattern_matches?(rule, text) if rule.op.pipe? # see `pattern_matches?`
        apply_rule(text, rule, rule.target, Store::RulePart::Ws, detail.row.host, report: false).to_slice != msg.payload
      end
    end

    private def flow_part_bytes(detail : Store::FlowDetail, rule : Store::MatchRule) : Bytes?
      if rule.target.request?
        rule.part.head? ? detail.request_head : detail.request_body
      else
        rule.part.head? ? detail.response_head : detail.response_body
      end
    end

    private def refresh : Nil
      fresh = Rules.merged(@store)
      # The pipe-failure suppression goes with the snapshot it was about. An edited rule is a
      # different rule as far as "have I already said this" is concerned: repointing a broken
      # command at a working one and back would otherwise stay silent the second time.
      @mutex.synchronize do
        @rules = fresh
        @hook_reported.clear
      end
      @req_head_count.set(active_count(fresh, Store::RuleTarget::Request, part: Store::RulePart::Head))
      @resp_head_count.set(active_count(fresh, Store::RuleTarget::Response, part: Store::RulePart::Head))
      @req_body_count.set(active_count(fresh, Store::RuleTarget::Request, part: Store::RulePart::Body))
      @resp_body_count.set(active_count(fresh, Store::RuleTarget::Response, part: Store::RulePart::Body))
      @ws_out_count.set(active_count(fresh, Store::RuleTarget::Request, part: Store::RulePart::Ws))
      @ws_in_count.set(active_count(fresh, Store::RuleTarget::Response, part: Store::RulePart::Ws))
      @short_circuit_count.set(stub_count(fresh))
      # An edit may have repointed a rule at a different file; the cache is keyed by path and
      # revalidated per read, so this only drops entries no rule refers to any more.
      @stub_bodies.clear
    end
  end
end
