require "../verb"

module Gori
  module Verbs
    def self.register_comparer(r : Verb::Registry) : Nil
      in_comparer = ->(ctx : Verb::ExecContext) { ctx.current_tab == :comparer }

      r.register Verb::Definition.new(
        "comparer.pick-a", "Pick flow A", "Choose the left flow (A) to compare",
        Verb::Scope::Comparer, [Verb::Chord.new("a")],
        available: in_comparer) { |ctx| ctx.comparer_pick(:a); nil }

      r.register Verb::Definition.new(
        "comparer.pick-b", "Pick flow B", "Choose the right flow (B) to compare",
        Verb::Scope::Comparer, [Verb::Chord.new("b")],
        available: in_comparer) { |ctx| ctx.comparer_pick(:b); nil }

      r.register Verb::Definition.new(
        "comparer.swap", "Swap A ⇄ B", "Swap the two flows being compared",
        Verb::Scope::Comparer, [Verb::Chord.new("s")],
        available: in_comparer) { |ctx| ctx.comparer_swap; nil }

      r.register Verb::Definition.new(
        "comparer.toggle-pane", "Compare requests/responses",
        "Toggle the diff between the two requests and the two responses",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 't') { |ctx| ctx.comparer_toggle_pane; nil }

      # Sub-tab strip / space menu (session multi-pair workspace).
      r.register Verb::Definition.new(
        "comparer.new", "New comparison", "Open a fresh blank comparison sub-tab",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'n',
        section: :common) { |ctx| ctx.comparer_new; nil }

      r.register Verb::Definition.new(
        "comparer.rename-subtab", "Rename comparison", "Rename the active comparison chip",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'e',
        section: :subtab) { |ctx| ctx.comparer_rename_subtab; nil }

      r.register Verb::Definition.new(
        "comparer.close-subtab", "Close comparison", "Close the active comparison sub-tab (keeps ≥1)",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'w',
        section: :subtab) { |ctx| ctx.comparer_close_subtab; nil }

      r.register Verb::Definition.new(
        "comparer.duplicate-subtab", "Duplicate comparison", "Clone the active A/B pair into a new sub-tab",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'd',
        section: :subtab) { |ctx| ctx.comparer_duplicate_subtab; nil }
    end
  end
end
