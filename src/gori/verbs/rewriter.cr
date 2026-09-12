require "../verb"

module Gori
  module Verbs
    # The Rewriter tab's space-menu / palette actions. The body is a navigable list (not a
    # text editor), so these also bind as direct body keys in the controller; the mnemonics
    # here drive the space menu + palette.
    #
    # ALL of them are `section: :rules`, not :common, and `RewriterController#command_section`
    # answers `:rules` / `:preview` to match. Two reasons, one structural and one a defect:
    # the PREVIEW OUTPUT pane grew its own read verbs whose `x` means "select line" — the same
    # letter this list spends on "Enable/disable", which `Registry#validate_menu_keys!` refuses
    # inside one displayable view — and, before that, the menu offered every rule action while
    # the preview pane held focus, acting on a row the operator was not looking at. That is the
    # leak `Runner#rewriter_rule_selected?` documents, one axis over: it remembered `@sub` and
    # forgot `@focus`.
    def self.register_rewriter(r : Verb::Registry) : Nil
      # Both gates now ask about FOCUS, not just the sub-tab. They have to: these verbs carry
      # real chords, and the preview panes share this body — `d` with the preview focused
      # would delete the rule sitting behind it. The space menu was already safe by another
      # route (`command_section` answers :preview there, and every verb here is
      # `section: :rules`), but a chord has no section to hide behind.
      in_rw = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_rule_list_focused? }
      has_rule = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :rewriter && ctx.rewriter_rule_list_focused? && ctx.rewriter_rule_selected?
      end

      r.register Verb::Definition.new(
        "rewriter.add", "Add rule", "Open the editor to add a Match & Replace rule",
        Verb::Scope::Rewriter, [Verb::Chord.new("a")], available: in_rw, mnemonic: 'a', section: :rules) { |ctx| ctx.rewriter_add; nil }
      # Install a response-modification preset (#821) — unhide hidden fields, strip validation,
      # drop CSP, etc. — as ordinary editable rules. `p` is free in this scope (the preview
      # pane's read verbs spend x/v/S/y; the rule list spends a/e/d/c/r/s and the two moves).
      r.register Verb::Definition.new(
        "rewriter.preset", "Add from preset…", "Install a response-modification preset as ordinary rules",
        Verb::Scope::Rewriter, [Verb::Chord.new("p")], available: in_rw, mnemonic: 'p', section: :rules) { |ctx| ctx.rewriter_preset; nil }
      # `/`, the app's filter key. A LENS over the RULES list — it hides rows, never disables
      # one — and the only action it changes is reordering, which `rewriter_move` refuses while
      # a query is held (apply order is the WHOLE list's order).
      r.register Verb::Definition.new(
        "rewriter.filter", "Filter rules", "Filter the rule list by name, match, replacement, part or scope",
        Verb::Scope::Rewriter, [Verb::Chord.new("/")], available: in_rw,
        mnemonic: 'f', section: :rules) { |ctx| ctx.rewriter_filter; nil }
      r.register Verb::Definition.new(
        "rewriter.edit", "Edit rule", "Edit the selected rule in the popup editor",
        Verb::Scope::Rewriter, [Verb::Chord.new("enter"), Verb::Chord.new("e")], available: has_rule, mnemonic: 'e', section: :rules) { |ctx| ctx.rewriter_edit; nil }
      # A REAL chord since the key audit's F4, and the reason it could not be one before is
      # exactly what F4 dissolves: `rewriter.select-line` (read_edit.cr) binds bare `x` in this
      # SCOPE for the preview pane, `Keymap#lookup` is keyed by scope alone and returns ONE id,
      # so a second `x` here simply shadowed one of them — which is why this list hand-rolled
      # its toggle in the controller and `x` was not rebindable here at all.
      #
      # On `t` the two no longer meet: `t` is "flip this row's flag" (mark, in History, Issues,
      # the Sitemap and the Intercept queue), `x` is "select this line" in fourteen scopes, and
      # a rule list has no marks. The `available:` gate is the focus disambiguator the arm used
      # to be — `rewriter_rule_list_focused?` is true for exactly the pane that arm ran in.
      r.register Verb::Definition.new(
        "rewriter.toggle", "Enable/disable", "Toggle the selected rule on or off in THIS project",
        Verb::Scope::Rewriter, [Verb::Chord.new("t")], available: has_rule, mnemonic: 't', section: :rules) { |ctx| ctx.rewriter_toggle; nil }
      r.register Verb::Definition.new(
        "rewriter.delete", "Delete rule", "Delete the selected rule (confirms first)",
        Verb::Scope::Rewriter, [Verb::Chord.new("d")], available: has_rule, mnemonic: 'd', section: :rules,
        group: :danger) { |ctx| ctx.rewriter_delete; nil }
      r.register Verb::Definition.new(
        "rewriter.move-up", "Move up", "Move the selected rule earlier in apply order",
        Verb::Scope::Rewriter, [Verb::Chord.new("k", shift: true)], available: has_rule, mnemonic: 'u', section: :rules) { |ctx| ctx.rewriter_move(-1); nil }
      r.register Verb::Definition.new(
        "rewriter.move-down", "Move down", "Move the selected rule later in apply order",
        Verb::Scope::Rewriter, [Verb::Chord.new("j", shift: true)], available: has_rule, mnemonic: 'n', section: :rules) { |ctx| ctx.rewriter_move(1); nil }
      r.register Verb::Definition.new(
        "rewriter.duplicate", "Duplicate rule", "Copy the selected rule into a new one",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'c', section: :rules) { |ctx| ctx.rewriter_duplicate; nil }
      r.register Verb::Definition.new(
        "rewriter.reload", "Reload rules", "Re-read rules from the project DB (pick up external edits)",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'r', section: :rules) { |ctx| ctx.rewriter_reload; nil }

      # The scope half. A Match & Replace rule lives EITHER in this project or in the global
      # library that every project reads (`Store::RuleScope`) — this replaces the old s/o
      # preset library, whose recipes did nothing until you loaded a copy into each project.
      # `s` keeps the mnemonic the save half had, now meaning "which scope".
      #
      # The default-flip is offered only for a global rule, because a project rule has no
      # default to flip: `x` IS its state, and its ⇧X reads as "…everywhere". In the clear-all
      # scopes ⇧X is the wipe chord instead — every verb in the registry's `:wipe` band
      # (`history.clear`, `probe.clear`, `authorize.clear`, `activity.clear`, `issues.clear`) —
      # deliberate cross-scope reuse, and invisible to
      # `Conflicts.overlap?`, which is `a == b` on the scope. This tab has no clear-all verb
      # for it to be confused with.
      #
      # Both gate on a selected rule for the reason `rewriter_rule_selected?` documents — the
      # menu must not act on a row the operator cannot see from the `extract` / `bindings`
      # sub-tabs.
      global_rule = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :rewriter && ctx.rewriter_rule_list_focused? && ctx.rewriter_global_rule_selected?
      end
      # MENU-ONLY since the key audit's F7. `s` is the Global scope lens, and a scoped chord
      # always beats the Global fallback — so this rule list quietly cost an operator the lens
      # key for an action they use when they file a rule, not while they triage. The letter
      # stays in the menu, where it is reached after `space` and shadows nothing.
      r.register Verb::Definition.new(
        "rewriter.scope", "Global/project", "Move the selected rule between this project and the global library",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 's', section: :rules) { |ctx| ctx.rewriter_scope_toggle; nil }
      r.register Verb::Definition.new(
        "rewriter.toggle-default", "Enable/disable everywhere",
        "Flip a global rule's default — what every project that hasn't overridden it follows",
        Verb::Scope::Rewriter, [] of Verb::Chord, # menu-only: ⇧X is the wipe chord on five tabs, and this one asked no confirm
        available: global_rule, mnemonic: 'X', section: :rules) { |ctx| ctx.rewriter_toggle_default; nil }
    end
  end
end
