require "json"
require "../store/models"

# COLORMARKER section: the GLOBAL half of the History row-colour rule set. See settings.cr for
# the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # A colour rule that lives in settings.json (`colormarker.rules`) instead of a project DB,
  # and therefore applies in EVERY project. The counterpart to a `color_rules` row; both fold
  # into the runtime `Store::ColorRule` list through `Colormarker.merged`, exactly the way
  # `Settings::RewriterRule` and `match_rules` fold into `Rules.merged`.
  #
  # The enum fields are stored as their `label` strings — the vocabulary `gori run colormarker`
  # and the MCP colour-rule tools already speak — so a hand-edited settings.json reads the way
  # the CLI prints.
  record ColormarkerRule,
    id : Int64,            # monotonic, from `colormarker_next_rule_id`; never reused
    enabled : Bool,        # the DEFAULT across projects; a project may override it
    name : String,         # the operator-facing label ("" = unnamed)
    match_filter : String, # an InterceptFilter source string
    color : String,        # a built-in MarkerColor label OR a custom colour's name (see colormarker_colors)
    style : String do      # Store::MarkerStyle label — "full" | "strip"
    # The rule as History sees it in one project: `enabled` is the EFFECTIVE state there (this
    # rule's default unless the project overrode it) and `overridden` says which of the two it
    # is, so the list row can mark it.
    #
    # Both `from_label`s are tolerant, so this is total for any string that reaches memory.
    def to_rule(enabled : Bool = @enabled, overridden : Bool = false) : Store::ColorRule
      Store::ColorRule.new(id, enabled, match_filter,
        color, Store::MarkerStyle.from_label(style),
        name, scope: Store::RuleScope::Global, overridden: overridden)
    end
  end

  # A user-defined colour that lives in settings.json (`colormarker.colors`) and so is offered
  # in EVERY project's colour picker. It is the counterpart to the six built-ins in
  # `Store::MarkerColor`, with one deliberate difference: a built-in resolves through the active
  # THEME (so a rule reads the same on a dark and a light palette) while a custom carries an
  # ABSOLUTE `hex` and does not track the theme. That is the trade an operator makes for a hue
  # the palette does not provide.
  #
  # `name` is the identity: it is what a rule's `color` field stores and what the picker shows,
  # lowercased and unique against both the built-in words and the other customs. `hex` is
  # normalised to "#rrggbb" on the way in (`normalize_hex`), so the render-side resolver
  # (`Tui::Theme.mark_color`) parses one known shape.
  record ColormarkerColor,
    name : String,
    hex : String

  class_property colormarker_colors : Array(ColormarkerColor) = [] of ColormarkerColor

  # Normalise a user-typed hex to "#rrggbb" lowercase, or nil if it is not a 3- or 6-digit hex
  # colour. Kept HERE rather than leaning on `Color.from_hex` so Settings stays free of the
  # Tui/Termisu layer — the resolver on the render side parses the same normalised form.
  def self.normalize_hex(s : String) : String?
    h = s.strip.lchop('#').downcase
    h = h.chars.join { |c| "#{c}#{c}" } if h.size == 3 && h.each_char.all?(&.hex?)
    return nil unless h.size == 6 && h.each_char.all?(&.hex?)
    "##{h}"
  end

  # Lowercase, whitespace-trimmed identity for a custom colour name. A blank name, or one that
  # collides with a built-in word, is not a legal custom name — the two would be ambiguous in a
  # rule's `color` field and in the picker.
  def self.normalize_color_name(s : String) : String?
    n = s.strip.downcase
    return nil if n.empty? || COLORMARKER_COLORS.includes?(n)
    n
  end

  class_property colormarker_rules : Array(ColormarkerRule) = [] of ColormarkerRule

  # The next global rule id, monotonic and NEVER reused — same reasoning as
  # `rewriter_next_rule_id`: handing a deleted rule's number to the next one created would
  # leave a project silently overriding a rule it never saw, because the override lives in a
  # different file this process may never open again.
  #
  # Counts from ONE, so 0 is free to mean "the write did not commit" in
  # `add_colormarker_rule`'s answer — the contract `Store#insert_color_rule` also has.
  class_property colormarker_next_rule_id : Int64 = 1_i64

  COLORMARKER_COLORS = %w[red orange yellow green blue purple]
  COLORMARKER_STYLES = %w[full strip]

  private def self.parse_colormarker(node : JSON::Any) : Nil
    self.colormarker_rules = parse_colormarker_rules(node["rules"]?)
    self.colormarker_colors = parse_colormarker_colors(node["colors"]?)
    stored = node["next_rule_id"]?.try(&.as_i64?) || 0_i64
    # Never go BACKWARDS from the ids actually present, whatever the file says. Saturating at
    # the top for the same reason the rewriter's counter is — see `next_id_after` there.
    self.colormarker_next_rule_id = {stored, next_id_after(colormarker_rules.max_of?(&.id) || 0_i64), 1_i64}.max
  end

  # Tolerant custom-colour parse, same spirit as the rule parser: a non-array (or absent) node
  # keeps the current value, and an entry with a blank/colliding name or an unparseable hex is
  # DROPPED rather than raised on — a typo in a hand-edited `colors` array cannot take the whole
  # file down through `load`'s blanket rescue, and the good entries still load. The first name
  # wins on a duplicate, so a hand-authored dupe is deterministic.
  private def self.parse_colormarker_colors(node : JSON::Any?) : Array(ColormarkerColor)
    arr = node.try(&.as_a?)
    return colormarker_colors unless arr
    list = [] of ColormarkerColor
    seen = Set(String).new
    arr.each do |e|
      next unless o = e.as_h?
      name = normalize_color_name(o["name"]?.try(&.as_s?) || "")
      next if name.nil? || seen.includes?(name)
      hex = normalize_hex(o["hex"]?.try(&.as_s?) || "")
      next unless hex
      seen << name
      list << ColormarkerColor.new(name, hex)
    end
    list
  end

  # Tolerant global-rule parse: a non-array (or absent) node keeps the current value; `style` is
  # clamped to its allowed set rather than parsed with `from_label`, so a typo in a hand-edited
  # settings.json cannot take the whole file down through `load`'s blanket rescue.
  #
  # `color` is NOT clamped — see `parse_color_label`.
  #
  # TWO deliberate departures from `parse_rewriter_rules`, both load-bearing:
  #
  # 1. An entry with an EMPTY `match_filter` is KEPT, where a rewriter entry with an empty
  #    `pattern` is dropped. The reasoning inverts: a rewrite rule with no pattern can never
  #    match, but `InterceptFilter::EMPTY` matches EVERYTHING — so this is a legal, if unwise,
  #    "paint every row" rule, and dropping it would delete a rule its author can see in their
  #    own file. `Colormarker#add` refuses to CREATE one; the parser only has to not lose it.
  #
  # 2. A missing `enabled` reads as TRUE, where a rewriter rule reads FALSE. That rule exists
  #    because a rewrite rule modifies live traffic in every project, so "on" is the one
  #    direction a malformed entry may not default to. Colormarker touches no traffic: its
  #    failure-on-false is a hand-written rule that silently never appears (and an operator who
  #    concludes the feature is broken), its failure-on-true is one coloured row. Pinned by a
  #    spec, because the two parsers side by side invite a "consistency" fix.
  private def self.parse_colormarker_rules(node : JSON::Any?) : Array(ColormarkerRule)
    arr = node.try(&.as_a?)
    return colormarker_rules unless arr
    list = [] of ColormarkerRule
    seen = Set(Int64).new
    arr.each do |e|
      next unless o = e.as_h?
      list << ColormarkerRule.new(
        claim_id(o["id"]?.try(&.as_i64?), seen),
        o["enabled"]?.try(&.as_bool?) != false,
        o["name"]?.try(&.as_s?) || "",
        o["when"]?.try(&.as_s?) || "",
        parse_color_label(o["color"]?.try(&.as_s?)),
        clamp_field(o["style"]?.try(&.as_s?), COLORMARKER_STYLES, "full"))
    end
    list
  end

  # A rule's `color`, normalised but NOT clamped to a known set — the one field here that must
  # survive a value this parser cannot vet.
  #
  # `style` can be clamped because `COLORMARKER_STYLES` is closed and always will be. A colour
  # is not: it is a built-in word OR the name of a custom colour from `colormarker.colors`, and
  # clamping to `COLORMARKER_COLORS` silently rewrote every custom reference to "yellow" on
  # load — then `save` wrote that back, so a global rule painted with a custom colour lost it
  # permanently at the next restart. Widening the clamp to include the custom names would only
  # move the bug: it makes this parser depend on `colors` having been read first, and it still
  # destroys a rule whose colour was deleted and is about to be re-added.
  #
  # Passing the label through costs nothing, because the RESOLVER is already total and already
  # tolerant: `Tui::Theme.mark_color` answers a custom name from the registry, a built-in word
  # (and its `cyan`/`magenta`/`violet` aliases) through the active palette, and anything else —
  # a typo, a dangling reference — with a visible yellow. Same forgiving outcome on screen, minus
  # the write-back that made it permanent. Blank/absent still reads as "yellow" so the field is
  # never empty.
  private def self.parse_color_label(s : String?) : String
    s.try(&.strip.downcase).presence || "yellow"
  end

  # --- global rule CRUD -----------------------------------------------------------------
  # Each mutation rewrites the array and persists via `save` (atomic + 3-way merge). The array
  # ORDER is the precedence order among global rules — the first enabled match paints the row —
  # which is why add appends and move swaps.

  # Returns the new rule's id, or 0 when the write did not reach disk.
  def self.add_colormarker_rule(match_filter : String, color : String, style : String,
                                name : String = "", enabled : Bool = true) : Int64
    id = colormarker_next_rule_id
    self.colormarker_next_rule_id = next_id_after(id) # saturating — see `next_id_after`
    self.colormarker_rules = colormarker_rules + [ColormarkerRule.new(id, enabled, name, match_filter, color, style)]
    save ? id : 0_i64
  end

  # Field update only — `enabled` is untouched, because it is the rule's default across
  # projects and an edit made in one of them is not a statement about the others.
  def self.update_colormarker_rule(id : Int64, match_filter : String, color : String,
                                   style : String, name : String = "") : Bool
    found = false
    self.colormarker_rules = colormarker_rules.map do |r|
      next r unless r.id == id
      found = true
      ColormarkerRule.new(id, r.enabled, name, match_filter, color, style)
    end
    found && save
  end

  # The rule's DEFAULT state, which every project without an override follows.
  def self.set_colormarker_rule_enabled(id : Int64, enabled : Bool) : Bool
    found = false
    self.colormarker_rules = colormarker_rules.map do |r|
      next r unless r.id == id
      found = true
      r.copy_with(enabled: enabled)
    end
    found && save
  end

  def self.delete_colormarker_rule(id : Int64) : Bool
    kept = colormarker_rules.reject { |r| r.id == id }
    return false if kept.size == colormarker_rules.size
    self.colormarker_rules = kept
    save
  end

  # Swap the rule one slot earlier (dir < 0) / later (dir > 0) among the GLOBAL rules. Never
  # across the scope boundary: "past the last global rule" is not a position, it is a scope
  # change, which is its own action.
  def self.move_colormarker_rule(id : Int64, dir : Int32) : Bool
    list = colormarker_rules.dup
    i = list.index { |r| r.id == id }
    return false unless i
    j = i + (dir < 0 ? -1 : 1)
    return false if j < 0 || j >= list.size
    list[i], list[j] = list[j], list[i]
    self.colormarker_rules = list
    save
  end

  # --- custom colour CRUD ----------------------------------------------------------------
  # The name is the identity (no numeric id): a rule references a colour by the same name the
  # picker shows, so a stable, human-typed key is what the wire format wants. Each mutation
  # persists via `save`; the boolean answer is "did the write reach disk", the contract every
  # mutator here shares.

  # The reason `name`/`hex` were rejected, or nil when the colour was written. A non-nil string
  # is a message a surface can show verbatim (the CLI aborts with it, MCP returns it, the TUI
  # overlay renders it). Refuses a blank/built-in/duplicate name and an unparseable hex — the
  # same three the tolerant parser silently drops, said out loud here because the caller just
  # typed the value.
  def self.add_colormarker_color(name : String, hex : String) : String?
    n = normalize_color_name(name)
    return "name can't be blank or a built-in colour (#{COLORMARKER_COLORS.join(", ")})" unless n
    return "a colour named “#{n}” already exists" if colormarker_colors.any? { |c| c.name == n }
    h = normalize_hex(hex)
    return "invalid hex — use #rrggbb" unless h
    self.colormarker_colors = colormarker_colors + [ColormarkerColor.new(n, h)]
    save ? nil : "settings not writable"
  end

  # Edit a custom colour in place, keyed by its OLD name (which may be unchanged). A rename to a
  # name another colour holds is refused; a rename leaves any rule still naming the old colour
  # dangling — the resolver falls back rather than the rename cascading, the same way a delete
  # does. Returns nil on success or a message on refusal.
  def self.update_colormarker_color(old_name : String, name : String, hex : String) : String?
    old = old_name.strip.downcase
    return "no colour named “#{old}”" unless colormarker_colors.any? { |c| c.name == old }
    n = normalize_color_name(name)
    return "name can't be blank or a built-in colour (#{COLORMARKER_COLORS.join(", ")})" unless n
    return "a colour named “#{n}” already exists" if n != old && colormarker_colors.any? { |c| c.name == n }
    h = normalize_hex(hex)
    return "invalid hex — use #rrggbb" unless h
    self.colormarker_colors = colormarker_colors.map { |c| c.name == old ? ColormarkerColor.new(n, h) : c }
    save ? nil : "settings not writable"
  end

  # Delete a custom colour by name. Returns whether the write committed; a rule that still names
  # it is left alone (the resolver falls back to a visible default), because this surface cannot
  # reach every project's DB to rewrite the rules that reference it.
  def self.delete_colormarker_color(name : String) : Bool
    n = name.strip.downcase
    kept = colormarker_colors.reject { |c| c.name == n }
    return false if kept.size == colormarker_colors.size
    self.colormarker_colors = kept
    save
  end

  # The name → hex map the render-side resolver consults (`Tui::Theme.set_custom_marks`). Built
  # here so the Tui layer never has to know the shape of a `ColormarkerColor`.
  def self.colormarker_color_map : Hash(String, String)
    colormarker_colors.to_h { |c| {c.name, c.hex} }
  end

  # Omit the whole block when there is nothing to say, so an untouched install never writes a
  # "colormarker" section. The counter is written even with an empty rule list — it is what keeps
  # a deleted rule's id from being handed out again after the last rule is removed. Custom
  # colours count as "something to say" too: a config with only custom colours (no rules) still
  # writes the section.
  private def self.serialize_colormarker(j : JSON::Builder) : Nil
    return if colormarker_rules.empty? && colormarker_colors.empty? && colormarker_next_rule_id <= 1
    j.field "colormarker" do
      j.object do
        j.field "next_rule_id", colormarker_next_rule_id
        j.field "rules" do
          j.array do
            colormarker_rules.each do |r|
              j.object do
                j.field "id", r.id
                j.field "enabled", r.enabled
                j.field "name", r.name
                # "when", not "match_filter": the same key `gori run colormarker --format=json`
                # prints and the MCP tools accept, so one vocabulary spans all three surfaces.
                j.field "when", r.match_filter
                j.field "color", r.color
                j.field "style", r.style
              end
            end
          end
        end
        # Only when there ARE custom colours — an install with rules but no customs should not
        # start writing an empty "colors" array it never had.
        unless colormarker_colors.empty?
          j.field "colors" do
            j.array do
              colormarker_colors.each do |c|
                j.object do
                  j.field "name", c.name
                  j.field "hex", c.hex
                end
              end
            end
          end
        end
      end
    end
  end
end
