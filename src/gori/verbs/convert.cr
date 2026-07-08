require "../verb"

module Gori
  module Verbs
    # The Convert tab's space-menu / palette actions. The body itself captures every
    # printable key (literal text), so these single-letter mnemonics never collide —
    # they fire only from the bottom-right space menu (reachable from the sub-tab
    # strip) and the command palette. Mnemonics are unique within the Convert scope.
    def self.register_convert(r : Verb::Registry) : Nil
      in_convert = ->(ctx : Verb::ExecContext) { ctx.current_tab == :convert }

      # New/Close are COMMON (Round 4), not TAB/SUBTAB: tagging them to the tab-bar/
      # strip tiers meant they were invisible from inside the body panes (INPUT/
      # CHAIN/OUTPUT) — COMMON renders in every context, so session management is
      # now reachable from anywhere in Convert, same as Copy.
      r.register Verb::Definition.new(
        "convert.new", "New conversion", "Open a fresh blank conversion sub-tab",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'n') { |ctx| ctx.convert_new; nil }

      r.register Verb::Definition.new(
        "convert.close", "Close conversion", "Close the active conversion sub-tab (keeps at least one)",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'w') { |ctx| ctx.convert_close; nil }

      # Rename the active sub-tab's chip — mirrors replay.rename-subtab/fuzz.rename-subtab
      # (verbs/history.cr): Convert is also in renameable_subtabs? (runner.cr), but had no
      # :subtab verb of its own, so its sub-tab-strip space menu was flat COMMON with no
      # way to rename. 'e' is free within COMMON ∪ :subtab (COMMON keys: n/w/y).
      r.register Verb::Definition.new(
        "convert.rename-subtab", "Rename subtab", "Rename the active conversion's sub-tab chip",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'e', section: :subtab) { |ctx| ctx.convert_rename_subtab; nil }

      # Clears the INPUT text (and its chain spec) — the INPUT pane's own action.
      r.register Verb::Definition.new(
        "convert.clear", "Clear input + chain", "Clear the current input and chain spec",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'l', section: :input) { |ctx| ctx.convert_clear; nil }

      in_convert_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :convert && ctx.convert_read_mode? }
      # The single smart Copy (see replay.copy in verbs/history.cr) — copy-all is gone.
      r.register Verb::Definition.new(
        "convert.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, from INPUT/OUTPUT",
        Verb::Scope::Convert, [Verb::Chord.new("y")],
        available: in_convert_read, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # Cycles the OUTPUT pane's display mode — tagged :output.
      r.register Verb::Definition.new(
        "convert.mode", "Cycle output mode", "Cycle the output display: text / hex / base64",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'm', section: :output) { |ctx| ctx.convert_cycle_mode; nil }

      # Save/load a chain spec by name — tagged :tab (session-level), not :chain:
      # naming and recalling a saved chain is closer to session management (like
      # Replay's find-subtab / Fuzzer's new-session) than a per-keystroke CHAIN-pane
      # action, and it keeps that pane from carrying its own near-empty group. This
      # also seeds has_section?(Convert, :tab), so the tab-bar space menu shows a
      # deliberate TAB group (COMMON + Save/Load) instead of falling back to
      # whichever body pane was last focused.
      r.register Verb::Definition.new(
        "convert.save", "Save chain by name", "Save the current chain spec under a name",
        Verb::Scope::Convert, available: in_convert, mnemonic: 's', section: :tab) { |ctx| ctx.convert_save; nil }

      r.register Verb::Definition.new(
        "convert.load", "Load a saved chain", "Load a previously saved chain spec by name",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'o', section: :tab) { |ctx| ctx.convert_load; nil }
    end
  end
end
