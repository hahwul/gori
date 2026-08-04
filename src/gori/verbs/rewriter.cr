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
      in_rw = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter }
      has_rule = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_rule_selected? }

      r.register Verb::Definition.new(
        "rewriter.add", "Add rule", "Open the editor to add a Match & Replace rule",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'a', section: :rules) { |ctx| ctx.rewriter_add; nil }
      r.register Verb::Definition.new(
        "rewriter.edit", "Edit rule", "Edit the selected rule in the popup editor",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'e', section: :rules) { |ctx| ctx.rewriter_edit; nil }
      r.register Verb::Definition.new(
        "rewriter.toggle", "Enable/disable", "Toggle the selected rule on or off",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'x', section: :rules) { |ctx| ctx.rewriter_toggle; nil }
      r.register Verb::Definition.new(
        "rewriter.delete", "Delete rule", "Delete the selected rule (confirms first)",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'd', section: :rules) { |ctx| ctx.rewriter_delete; nil }
      r.register Verb::Definition.new(
        "rewriter.move-up", "Move up", "Move the selected rule earlier in apply order",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'u', section: :rules) { |ctx| ctx.rewriter_move(-1); nil }
      r.register Verb::Definition.new(
        "rewriter.move-down", "Move down", "Move the selected rule later in apply order",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'n', section: :rules) { |ctx| ctx.rewriter_move(1); nil }
      r.register Verb::Definition.new(
        "rewriter.duplicate", "Duplicate rule", "Copy the selected rule into a new one",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'c', section: :rules) { |ctx| ctx.rewriter_duplicate; nil }
      r.register Verb::Definition.new(
        "rewriter.reload", "Reload rules", "Re-read rules from the project DB (pick up external edits)",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'r', section: :rules) { |ctx| ctx.rewriter_reload; nil }

      # The global rule-preset library (settings.json `rewriter.presets`) — the Decoder's
      # named chains, one table over. A Match & Replace rule is a RECIPE ("strip CSP on
      # *.corp.internal"): reusable on the next engagement, while which rules are live in
      # THIS project stays in the project DB. Same 's'/'o' mnemonics the Decoder uses for
      # the same pair, so the gesture is one thing to learn.
      #
      # Save gates on has_rule (there must be a rule to save), load only on the RULES
      # sub-tab: loading appends to the Match&Replace list, so offering it while the
      # `extract`/`bindings` sub-tab is on screen would write to a table the operator is
      # not looking at — the leak `rewriter_rule_selected?` documents, one verb over.
      in_rules = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_rules_sub? }
      r.register Verb::Definition.new(
        "rewriter.save-preset", "Save rule to library", "Save the selected rule under a name, shared by every project",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 's', section: :rules) { |ctx| ctx.rewriter_save_preset; nil }
      r.register Verb::Definition.new(
        "rewriter.load-preset", "Load a saved rule", "Add a rule from the global library to this project (^X deletes one)",
        Verb::Scope::Rewriter, available: in_rules, mnemonic: 'o', section: :rules) { |ctx| ctx.rewriter_load_preset; nil }
    end
  end
end
