require "./store"
require "./settings"
require "./intercept_filter"
require "./filter_ast"
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
  # ── performance contract ────────────────────────────────────────────────────────────────
  # `match` runs on the History RENDER path, once per visible row per frame. So:
  #
  #   * `InterceptFilter.new` runs ONLY in `refresh` — once per rule per edit/reload. It must
  #     never appear on the render path; `spec/colormarker_spec.cr` pins this.
  #   * `active?` gates everything: a project with no enabled rule pays one atomic read per row.
  #   * the `Subject` is built once per row and reused across the whole compiled walk, and
  #     `proto` is passed IN because History's row loop already computes it.
  #   * zero allocation is NOT claimed — `InterceptFilter::Term` downcases the subject for its
  #     substring fields. The budget is O(visible rows × rules until first match) short-string
  #     downcases per frame, which is why first-match-wins short-circuiting is load-bearing
  #     rather than cosmetic.
  class Colormarker
    # A rule with its condition already parsed. Same contract, same reason, as
    # `Bindings::Compiled`: the FilterAst walk happens once per rule, not once per row.
    private record Compiled, rule : Store::ColorRule, filter : InterceptFilter

    # How many recent flows `preview` scans. Same cap and the same reason as
    # `Rules::RULE_PREVIEW_SCAN` — this runs on the keystroke path of the rule editor.
    PREVIEW_SCAN = 500

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

    def initialize(@store : Store, rules : Array(Store::ColorRule))
      @mutex = Mutex.new
      @rules = rules
      @custom_colors = Settings.colormarker_colors
      @compiled = compile(rules)
      @active = !@compiled.empty?
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
      @mutex.synchronize do
        return nil unless @active
        subject = InterceptFilter::Subject.new(
          method: row.method, host: row.host, target: row.target,
          scheme: row.scheme, status: row.status, proto: proto)
        @compiled.each { |c| return c.rule if c.filter.matches?(subject) }
      end
      nil
    end

    def match(row : Store::FlowRow) : Store::ColorRule?
      match(row, Proto.classify(row.status, row.content_type, row.request_content_type))
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

    # The fields worth NAMING to an operator. `InterceptFilter::FIELDS` minus `body:`, which is
    # legal to write here (the parser accepts it, and `advise` explains it) but can never match
    # a captured row — so advertising it in the same breath as the rest would contradict the
    # note the operator gets the moment they take the advice.
    USEFUL_FIELDS = InterceptFilter::FIELDS - ["body"]

    # Why this condition cannot be used, or nil if it can.
    #
    # `InterceptFilter.new` NEVER raises — an unknown field degrades to free text and
    # `FilterAst` is total — so there is no parse failure to lean on and every refusal has to be
    # made explicitly. Three of them, and each is a rule that would otherwise fail SILENTLY:
    #
    #   1. an empty condition, and 2. one that folds to match-all (a mid-typed `host:` — a term
    #      with an empty value is DROPPED, and an emptied query matches everything), both paint
    #      every row in History;
    #   3. a `field:` this backend does not know (`size:`, `header:`, `dur:`, `url:`, `stub:` —
    #      all of them History QL fields, which is exactly why an operator reaches for them).
    #      `parse_term` free-texts the whole token, so `size:>10000` becomes a literal substring
    #      search over method/host/target and the rule never fires, with no error anywhere.
    def self.unusable_reason(match_filter : String) : String?
      return "enter a condition" if match_filter.blank?
      if bad = unknown_fields(match_filter).first?
        return "unknown field `#{bad}:` — a colour rule knows #{USEFUL_FIELDS.join(": ")}:"
      end
      return "this condition matches every flow" if InterceptFilter.new(match_filter).blank?
      nil
    end

    # The `field:` names in `match_filter` that `InterceptFilter` does not implement, in order
    # of appearance. Driven by `FilterAst.spans` — the SAME lexer the parser runs — so what is
    # reported as a field is exactly what would ACT as one.
    #
    # `SEPS_FIELD` (":" alone, not ":~"): only QL implements `~`, so `host~x` here is free text
    # and calling it an unknown FIELD would be the wrong complaint.
    def self.unknown_fields(match_filter : String) : Array(String)
      acc = [] of String
      FilterAst.spans(match_filter, FilterAst::SEPS_FIELD).each do |span|
        next unless span.kind.field?
        name = match_filter[span.start, span.size].rchop(':').downcase
        acc << name if !name.empty? && !InterceptFilter::FIELDS.includes?(name) && !acc.includes?(name)
      end
      acc
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
      if lower.includes?("body:")
        notes << "`body:` never matches here — a History row carries no payload, so a rule using it paints nothing."
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
    # Cheap by construction — the condition matches on `FlowRow` alone, so this is one
    # `recent_flows` page and no `get_flow` per row (contrast `Rules#preview`, which must pull
    # bodies).
    record Preview, matched : Int32, painted : Int32, scanned : Int32, total : Int64

    def self.preview(store : Store, match_filter : String,
                     existing : Array(Store::ColorRule) = [] of Store::ColorRule,
                     limit : Int32 = PREVIEW_SCAN) : Preview
      filter = InterceptFilter.new(match_filter)
      ahead = existing.select(&.enabled?).map { |r| InterceptFilter.new(r.match_filter) }
      scanned = 0
      matched = 0
      painted = 0
      store.recent_flows(limit, nil).each do |row|
        scanned += 1
        subject = InterceptFilter::Subject.new(
          method: row.method, host: row.host, target: row.target,
          scheme: row.scheme, status: row.status,
          proto: Proto.classify(row.status, row.content_type, row.request_content_type))
        next unless filter.matches?(subject)
        matched += 1
        painted += 1 unless ahead.any?(&.matches?(subject))
      end
      Preview.new(matched, painted, scanned, store.count)
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
        @strip_active = compiled.any?(&.rule.style.strip?)
        @revision &+= 1
      end
    end

    # ENABLED rules only, in precedence order: `match` then walks a list where every entry is a
    # candidate, rather than re-testing `enabled?` per row per frame.
    private def compile(list : Array(Store::ColorRule)) : Array(Compiled)
      list.select(&.enabled?).map { |r| Compiled.new(r, InterceptFilter.new(r.match_filter)) }
    end
  end
end
