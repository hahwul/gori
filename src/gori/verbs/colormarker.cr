require "../verb"

module Gori
  module Verbs
    # The Colormarker tab's space-menu / palette actions. The body is two navigable lists (a
    # POLICY list and a CUSTOM COLORS list), so — like the Rewriter, and unlike its former
    # single-pane self — the verbs are partitioned into two `section:`s the controller's
    # `command_section` switches between, and the policy verbs' `available:` is focus-aware so a
    # chord (which has no section to hide behind) cannot fire the rule action while the colours
    # pane is up.
    #
    # The COLOURS verbs carry NO chords: both panes share `Verb::Scope::Colormarker` and the
    # keymap holds one verb per chord per scope, so `a`/`e`/`d` could not bind twice. Their keys
    # are handled in the controller (focus-routed); these entries drive only the space menu and
    # the palette, where the mnemonic partitions by section.
    def self.register_colormarker(r : Verb::Registry) : Nil
      in_cm = ->(ctx : Verb::ExecContext) { ctx.current_tab == :colormarker }
      # The policy list is the one the keyboard points at (not the colours pane) AND has a row.
      on_rule = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :colormarker && ctx.colormarker_rule_list_focused? && ctx.colormarker_rule_selected?
      end

      r.register Verb::Definition.new(
        "colormarker.add", "Add rule", "Open the editor to add a History row-colour rule",
        Verb::Scope::Colormarker, [Verb::Chord.new("a")], available: in_cm, mnemonic: 'a', section: :rules) { |ctx| ctx.colormarker_add; nil }
      r.register Verb::Definition.new(
        "colormarker.edit", "Edit rule", "Edit the selected rule in the popup editor",
        Verb::Scope::Colormarker, [Verb::Chord.new("enter"), Verb::Chord.new("e")], available: on_rule, mnemonic: 'e', section: :rules) { |ctx| ctx.colormarker_edit; nil }
      r.register Verb::Definition.new(
        "colormarker.toggle", "Enable/disable", "Toggle the selected rule on or off in THIS project",
        Verb::Scope::Colormarker, [Verb::Chord.new("x")], available: on_rule, mnemonic: 'x', section: :rules) { |ctx| ctx.colormarker_toggle; nil }
      r.register Verb::Definition.new(
        "colormarker.delete", "Delete rule", "Delete the selected rule (confirms first)",
        Verb::Scope::Colormarker, [Verb::Chord.new("d")], available: on_rule, mnemonic: 'd', section: :rules,
        group: :danger) { |ctx| ctx.colormarker_delete; nil }
      # "Move up/down" reads like cosmetics on the Rewriter, where rules compose and order is a
      # tiebreak. Here the FIRST enabled match paints the row and the rest are never consulted,
      # so a move changes which rule wins — the descriptions say so.
      r.register Verb::Definition.new(
        "colormarker.move-up", "Move up", "Give the selected rule higher precedence (first match wins)",
        Verb::Scope::Colormarker, [Verb::Chord.new("k", shift: true)], available: on_rule, mnemonic: 'u', section: :rules) { |ctx| ctx.colormarker_move(-1); nil }
      r.register Verb::Definition.new(
        "colormarker.move-down", "Move down", "Give the selected rule lower precedence (first match wins)",
        Verb::Scope::Colormarker, [Verb::Chord.new("j", shift: true)], available: on_rule, mnemonic: 'n', section: :rules) { |ctx| ctx.colormarker_move(1); nil }
      r.register Verb::Definition.new(
        "colormarker.duplicate", "Duplicate rule", "Copy the selected rule into a new one",
        Verb::Scope::Colormarker, available: on_rule, mnemonic: 'c', section: :rules) { |ctx| ctx.colormarker_duplicate; nil }
      r.register Verb::Definition.new(
        "colormarker.reload", "Reload rules", "Re-read rules from the project DB (pick up external edits)",
        Verb::Scope::Colormarker, available: in_cm, mnemonic: 'r', section: :rules) { |ctx| ctx.colormarker_reload; nil }

      # The scope half, the same shape the Rewriter's carries: a rule lives EITHER in this
      # project or in the global library every project reads. The default-flip is offered only
      # for a global rule, because a project rule has no default to flip — `x` IS its state.
      # Its ⇧X reads as "…everywhere": the shifted form of the `x` that flips the same rule in
      # THIS project (`colormarker.toggle`, above). In the clear-all scopes ⇧X is the wipe chord
      # instead — the registry's `:wipe` band (`history.clear`, `probe.clear`, `authorize.clear`,
      # `activity.clear`, `issues.clear`) —
      # deliberate cross-scope reuse, and invisible to `Conflicts.overlap?`, which is `a == b`
      # on the scope. This tab has no clear-all verb for it to be confused with.
      on_global_rule = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :colormarker && ctx.colormarker_rule_list_focused? && ctx.colormarker_global_rule_selected?
      end
      r.register Verb::Definition.new(
        "colormarker.scope", "Global/project", "Move the selected rule between this project and the global library",
        Verb::Scope::Colormarker, [Verb::Chord.new("s")], available: on_rule, mnemonic: 's', section: :rules) { |ctx| ctx.colormarker_scope_toggle; nil }
      r.register Verb::Definition.new(
        "colormarker.toggle-default", "Enable/disable everywhere",
        "Flip a GLOBAL rule's default — the state every project without an override follows",
        Verb::Scope::Colormarker, [] of Verb::Chord, # menu-only: ⇧X is the wipe chord on five tabs, and this one asked no confirm
        available: on_global_rule, mnemonic: 'X', section: :rules) { |ctx| ctx.colormarker_toggle_default; nil }

      # --- CUSTOM COLORS pane (section :colors) — no chords, see the header note. ---
      in_colors = ->(ctx : Verb::ExecContext) { ctx.current_tab == :colormarker && ctx.colormarker_colors_focused? }
      on_color = ->(ctx : Verb::ExecContext) { ctx.current_tab == :colormarker && ctx.colormarker_colors_focused? && ctx.colormarker_color_selected? }
      r.register Verb::Definition.new(
        "colormarker.color-add", "Add colour", "Define a new custom colour (name + hex) for the picker",
        Verb::Scope::Colormarker, available: in_colors, mnemonic: 'a', section: :colors) { |ctx| ctx.colormarker_color_add; nil }
      r.register Verb::Definition.new(
        "colormarker.color-edit", "Edit colour", "Edit the selected custom colour",
        Verb::Scope::Colormarker, available: on_color, mnemonic: 'e', section: :colors) { |ctx| ctx.colormarker_color_edit; nil }
      r.register Verb::Definition.new(
        "colormarker.color-delete", "Delete colour", "Delete the selected custom colour (confirms first)",
        Verb::Scope::Colormarker, available: on_color, mnemonic: 'd', section: :colors,
        group: :danger) { |ctx| ctx.colormarker_color_delete; nil }
    end
  end
end
