require "../verb"

module Gori
  module Verbs
    # The Rewriter tab's space-menu / palette actions. The body is a navigable list (not a
    # text editor), so these also bind as direct body keys in the controller; the mnemonics
    # here drive the space menu + palette. Unique within COMMON ∪ this scope.
    def self.register_rewriter(r : Verb::Registry) : Nil
      in_rw = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter }
      has_rule = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_rule_selected? }

      r.register Verb::Definition.new(
        "rewriter.add", "Add rule", "Open the editor to add a Match & Replace rule",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'a') { |ctx| ctx.rewriter_add; nil }
      r.register Verb::Definition.new(
        "rewriter.edit", "Edit rule", "Edit the selected rule in the popup editor",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'e') { |ctx| ctx.rewriter_edit; nil }
      r.register Verb::Definition.new(
        "rewriter.toggle", "Enable/disable", "Toggle the selected rule on or off",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'x') { |ctx| ctx.rewriter_toggle; nil }
      r.register Verb::Definition.new(
        "rewriter.delete", "Delete rule", "Delete the selected rule (confirms first)",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'd') { |ctx| ctx.rewriter_delete; nil }
      r.register Verb::Definition.new(
        "rewriter.move-up", "Move up", "Move the selected rule earlier in apply order",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'u') { |ctx| ctx.rewriter_move(-1); nil }
      r.register Verb::Definition.new(
        "rewriter.move-down", "Move down", "Move the selected rule later in apply order",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'n') { |ctx| ctx.rewriter_move(1); nil }
      r.register Verb::Definition.new(
        "rewriter.duplicate", "Duplicate rule", "Copy the selected rule into a new one",
        Verb::Scope::Rewriter, available: has_rule, mnemonic: 'c') { |ctx| ctx.rewriter_duplicate; nil }
      r.register Verb::Definition.new(
        "rewriter.reload", "Reload rules", "Re-read rules from the project DB (pick up external edits)",
        Verb::Scope::Rewriter, available: in_rw, mnemonic: 'r') { |ctx| ctx.rewriter_reload; nil }
    end
  end
end
