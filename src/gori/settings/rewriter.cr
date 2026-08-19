require "json"
require "../store/models"

# REWRITER section: the GLOBAL half of the Match & Replace rule set. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # A Match & Replace rule that lives in settings.json (`rewriter.rules`) instead of a project
  # DB, and therefore applies in EVERY project. The counterpart to a `match_rules` row; both
  # fold into the runtime `Store::MatchRule` list through `Rules.merged`, exactly the way
  # `Settings::ScanRule` and `probe_custom_rules` fold into `Probe.custom_rules`.
  #
  # This REPLACES the old preset library (`rewriter.presets`, an inert recipe you had to load
  # into a project before it did anything). The axis that library got wrong is that a rewrite
  # rule is not a recipe: "strip CSP on *.corp.internal" is a standing policy an operator wants
  # ON, everywhere, without re-loading it per project. What stays per-project is which of them
  # this engagement disagrees with — an OVERRIDE, not a copy (see `Store#rewriter_overrides`).
  #
  # The enum fields are stored as their `label` strings — the same vocabulary `gori run
  # rewriter` and the MCP rule tools already speak — so a hand-edited settings.json reads the
  # way the CLI prints.
  record RewriterRule,
    id : Int64,      # monotonic, from `rewriter_next_rule_id`; never reused (see below)
    enabled : Bool,  # the DEFAULT across projects; a project may override it
    name : String,   # the operator-facing label ("" = unnamed, like a project rule)
    target : String, # Store::RuleTarget label — "request" | "response"
    part : String,   # Store::RulePart label — "head" | "body" | "ws"
    pattern : String,
    replacement : String,
    op : String,          # Store::RuleOp label — "replace" | "add_header" | ... | "short_circuit"
    match_kind : String,  # Store::MatchKind label — "literal" | "regex"
    host : String,        # host glob ("" = every host)
    body_file : String do # ShortCircuit stub path ("" = inline body in `replacement`)
    # The rule as the proxy sees it in one project: `enabled` is the EFFECTIVE state there
    # (this rule's default unless the project overrode it) and `overridden` says which of the
    # two it is, so the list row can mark it.
    #
    # `from_label` RAISES on an unknown label and that is safe here: a rule only reaches memory
    # through `parse_rewriter_rules`, which clamps all four enum fields to their allowed sets,
    # or through the CRUD below, which is handed a live rule's own `.label`. The clamp at the
    # parse boundary is what makes this total.
    def to_rule(enabled : Bool = @enabled, overridden : Bool = false) : Store::MatchRule
      Store::MatchRule.new(id, enabled,
        Store::RuleTarget.from_label(target), Store::RulePart.from_label(part),
        pattern, replacement,
        Store::RuleOp.from_label(op), Store::MatchKind.from_label(match_kind),
        name, host, body_file,
        scope: Store::RuleScope::Global, overridden: overridden)
    end
  end

  class_property rewriter_rules : Array(RewriterRule) = [] of RewriterRule

  # The next global rule id, monotonic and NEVER reused. `max(id) + 1` would hand a deleted
  # rule's number to the next one created, and a project that had overridden the deleted rule
  # would then be silently overriding the new one — the override outlives the rule it names,
  # because it lives in a different file this process may never open again.
  #
  # Counts from ONE, so that 0 is free to mean "the write did not commit" in
  # `add_rewriter_rule`'s answer — the same contract `Store#insert_rule` has.
  class_property rewriter_next_rule_id : Int64 = 1_i64

  RULE_TARGETS = %w[request response]
  RULE_PARTS   = %w[head body ws]
  RULE_OPS     = %w[replace add_header set_header remove_header short_circuit]
  RULE_KINDS   = %w[literal regex]

  # Parse the `rewriter` section: `rules` when present, else the pre-upgrade `presets` block.
  private def self.parse_rewriter(node : JSON::Any) : Nil
    if node["rules"]?
      self.rewriter_rules = parse_rewriter_rules(node["rules"]?)
    else
      self.rewriter_rules = parse_legacy_presets(node["presets"]?)
    end
    stored = node["next_rule_id"]?.try(&.as_i64?) || 0_i64
    # Never go BACKWARDS from the ids actually present, whatever the file says: a hand-edited
    # (or truncated) counter must not be able to mint a duplicate id.
    self.rewriter_next_rule_id = {stored, next_id_after(rewriter_rules.max_of?(&.id) || 0_i64), 1_i64}.max
  end

  # One past `highest`, SATURATING. Crystal's `+` is checked, so a hand-edited (or imported)
  # `"id": 9223372036854775807` made this expression raise OverflowError — inside
  # `apply_sections`, where a raise abandons every section below it and `load`'s blanket rescue
  # swallows it. That is the same #594 room `int_field` and `object_section` (settings.cr) each
  # closed a door into; this is the arithmetic one, and it is why those two rescue rather than
  # let a value's range decide how much of the file gets read. Saturating can hand out an id
  # that is already taken, which costs an ambiguous by-id edit at the very top of the Int64
  # range; raising costs the operator every section below `rewriter`.
  private def self.next_id_after(highest : Int64) : Int64
    highest == Int64::MAX ? highest : highest + 1
  end

  # Tolerant global-rule parse: a non-array (or absent) node keeps the current value; entries
  # missing a pattern are dropped (a rule with no pattern can never match, and `Rules#add`
  # refuses it anyway); the four enum fields are clamped to their allowed sets.
  #
  # Clamping rather than `from_label` is the point: those raise on an unknown label, and a
  # single typo in a hand-edited settings.json would take the whole file down through `load`'s
  # blanket rescue — resetting theme, hotkeys and every other section to factory defaults.
  # Mirrors parse_scan_rules.
  #
  # A missing `enabled` reads as FALSE. These rules rewrite live traffic in every project, so
  # the one direction a malformed or hand-written entry may not default to is "on".
  private def self.parse_rewriter_rules(node : JSON::Any?) : Array(RewriterRule)
    arr = node.try(&.as_a?)
    return rewriter_rules unless arr
    list = [] of RewriterRule
    seen = Set(Int64).new
    arr.each do |e|
      next unless o = e.as_h?
      pattern = o["pattern"]?.try(&.as_s?)
      next if pattern.nil? || pattern.empty?
      list << RewriterRule.new(
        claim_id(o["id"]?.try(&.as_i64?), seen),
        o["enabled"]?.try(&.as_bool?) || false,
        o["name"]?.try(&.as_s?) || "",
        clamp_field(o["target"]?.try(&.as_s?), RULE_TARGETS, "request"),
        clamp_field(o["part"]?.try(&.as_s?), RULE_PARTS, "head"),
        pattern,
        o["replacement"]?.try(&.as_s?) || "",
        clamp_field(o["op"]?.try(&.as_s?), RULE_OPS, "replace"),
        clamp_field(o["match_kind"]?.try(&.as_s?), RULE_KINDS, "literal"),
        o["host"]?.try(&.as_s?) || "",
        o["body_file"]?.try(&.as_s?) || "")
    end
    list
  end

  # The id this parsed entry gets to keep, recording it in `seen`. A missing, non-positive or
  # already-taken id is replaced with one past everything seen so far: two rules sharing an id
  # would make every by-id mutation ambiguous, and dropping the entry would silently lose a
  # rule the operator wrote. (Zero is not a valid id — see `rewriter_next_rule_id`.)
  #
  # `Int64::MAX` is renumbered the same way, for the same reason a duplicate is: it is the one
  # id no counter can be advanced past, so keeping it would make the next mint ambiguous
  # anyway. The rule itself is kept either way — see `next_id_after` for what raising here
  # would have cost.
  private def self.claim_id(id : Int64?, seen : Set(Int64)) : Int64
    return id if id && id > 0 && id < Int64::MAX && seen.add?(id)
    fresh = next_id_after(seen.max? || 0_i64)
    seen << fresh
    fresh
  end

  # Adopt a pre-upgrade `rewriter.presets` block as global rules, DISABLED. A preset was inert
  # by construction — it did nothing until you loaded it into a project — so adopting one as a
  # live rule would start rewriting traffic in every project on the strength of an upgrade.
  # They arrive as rows in the Rewriter list, off, where `x` arms them.
  #
  # No eraser is needed for the legacy key (contrast `drop_legacy_decoder_sessions`): the
  # migration is in-memory and idempotent — `rules` wins the moment it exists, so a stale
  # `presets` block is never read again — and the first save that touches the section replaces
  # it with `rules` outright, because the merge sees the section change.
  private def self.parse_legacy_presets(node : JSON::Any?) : Array(RewriterRule)
    arr = node.try(&.as_a?)
    return rewriter_rules unless arr
    list = [] of RewriterRule
    arr.each do |e|
      next unless o = e.as_h?
      name = o["name"]?.try(&.as_s?)
      pattern = o["pattern"]?.try(&.as_s?)
      next if name.nil? || name.empty? || pattern.nil? || pattern.empty?
      list << RewriterRule.new(
        (list.size + 1).to_i64, false, name,
        clamp_field(o["target"]?.try(&.as_s?), RULE_TARGETS, "request"),
        clamp_field(o["part"]?.try(&.as_s?), RULE_PARTS, "head"),
        pattern,
        o["replacement"]?.try(&.as_s?) || "",
        clamp_field(o["op"]?.try(&.as_s?), RULE_OPS, "replace"),
        clamp_field(o["match_kind"]?.try(&.as_s?), RULE_KINDS, "literal"),
        o["host"]?.try(&.as_s?) || "",
        o["body_file"]?.try(&.as_s?) || "")
    end
    list
  end

  # --- global rule CRUD -----------------------------------------------------------------
  # Each mutation rewrites the array and persists via `save` (atomic + 3-way merge). The array
  # ORDER is the apply order among global rules, which is why add appends and move swaps.

  # Returns the new rule's id, or 0 when the write did not reach disk — the same "did it
  # commit" answer `Store#insert_rule` gives, so `Rules#add` can report the two scopes alike.
  def self.add_rewriter_rule(target : String, part : String, pattern : String, replacement : String,
                             op : String, match_kind : String, name : String, host : String,
                             body_file : String, enabled : Bool = true) : Int64
    # The answer below is a COMMIT answer, so memory has to agree with it: `save` refuses the
    # write outright when the last load only got half the file in (`@@load_partial`), and it
    # returns false on any transient write failure too. Mutating first and answering 0 left
    # the rule in `rewriter_rules` — folded into `Rules.merged` by the unconditional
    # `refresh`, rewriting live traffic in every project — while the operator was told it was
    # not added, and written to disk by the next unrelated save that did succeed. So snapshot
    # both properties and put them back when the write did not commit. The array is replaced
    # wholesale everywhere and never mutated in place, so the old reference IS the snapshot.
    prev_rules = rewriter_rules
    prev_next = rewriter_next_rule_id
    id = rewriter_next_rule_id
    # Saturating, because the counter itself is parsed from the file (`next_rule_id`) and a
    # bare `+ 1` on an `Int64::MAX` one raises out of an operator's "add rule" — see
    # `next_id_after`.
    self.rewriter_next_rule_id = next_id_after(id)
    self.rewriter_rules = rewriter_rules + [RewriterRule.new(id, enabled, name, target, part,
      pattern, replacement, op, match_kind, host, body_file)]
    return id if save
    self.rewriter_rules = prev_rules
    # The counter too: a burned id is not cosmetic — a project's `rewriter_overrides` key
    # outlives the rule it names, which is the whole reason ids are never reused.
    self.rewriter_next_rule_id = prev_next
    0_i64
  end

  # Field update only — `enabled` is untouched, because it is the rule's default across
  # projects and an edit made in one of them is not a statement about the others.
  def self.update_rewriter_rule(id : Int64, target : String, part : String, pattern : String,
                                replacement : String, op : String, match_kind : String,
                                name : String, host : String, body_file : String) : Bool
    prev_rules = rewriter_rules
    found = false
    self.rewriter_rules = rewriter_rules.map do |r|
      next r unless r.id == id
      found = true
      RewriterRule.new(id, r.enabled, name, target, part, pattern, replacement,
        op, match_kind, host, body_file)
    end
    # See `add_rewriter_rule`: a false answer means the edit did not commit, so the edited
    # fields must not stay live either.
    ok = found && save
    self.rewriter_rules = prev_rules unless ok
    ok
  end

  # The rule's DEFAULT state, which every project without an override follows.
  def self.set_rewriter_rule_enabled(id : Int64, enabled : Bool) : Bool
    prev_rules = rewriter_rules
    found = false
    self.rewriter_rules = rewriter_rules.map do |r|
      next r unless r.id == id
      found = true
      r.copy_with(enabled: enabled)
    end
    ok = found && save
    self.rewriter_rules = prev_rules unless ok
    ok
  end

  def self.delete_rewriter_rule(id : Int64) : Bool
    prev_rules = rewriter_rules
    kept = rewriter_rules.reject { |r| r.id == id }
    return false if kept.size == rewriter_rules.size
    self.rewriter_rules = kept
    # This one fails the OTHER way round: a dropped-then-unsaved rule has stopped rewriting
    # while the caller reports "not deleted — it is still rewriting traffic". An operator
    # deleting a containment rule has to be able to trust that sentence.
    return true if save
    self.rewriter_rules = prev_rules
    false
  end

  # Swap the rule one slot earlier (dir < 0) / later (dir > 0) among the GLOBAL rules. Never
  # across the scope boundary: the two blocks are stored in different files and ordered by
  # different mechanisms, so "past the last global rule" is not a position — it is a scope
  # change, which is its own action.
  def self.move_rewriter_rule(id : Int64, dir : Int32) : Bool
    list = rewriter_rules.dup
    i = list.index { |r| r.id == id }
    return false unless i
    j = i + (dir < 0 ? -1 : 1)
    return false if j < 0 || j >= list.size
    list[i], list[j] = list[j], list[i]
    prev_rules = rewriter_rules
    self.rewriter_rules = list
    return true if save
    self.rewriter_rules = prev_rules
    false
  end

  # Omit the whole block when there is nothing to say, so an untouched install never writes a
  # "rewriter" section. The counter is written even with an empty list — it is what keeps a
  # deleted rule's id from being handed out again after the last rule is removed.
  private def self.serialize_rewriter(j : JSON::Builder) : Nil
    return if rewriter_rules.empty? && rewriter_next_rule_id <= 1
    j.field "rewriter" do
      j.object do
        j.field "next_rule_id", rewriter_next_rule_id
        j.field "rules" do
          j.array do
            rewriter_rules.each do |r|
              j.object do
                j.field "id", r.id
                j.field "enabled", r.enabled
                j.field "name", r.name
                j.field "target", r.target
                j.field "part", r.part
                j.field "pattern", r.pattern
                j.field "replacement", r.replacement
                j.field "op", r.op
                j.field "match_kind", r.match_kind
                j.field "host", r.host
                j.field "body_file", r.body_file
              end
            end
          end
        end
      end
    end
  end
end
