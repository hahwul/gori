require "../verb"

module Gori
  module Verbs
    # The Decoder tab's space-menu / palette actions. The body itself captures every
    # printable key (literal text), so these single-letter mnemonics never collide —
    # they fire only from the bottom-right space menu (reachable from the sub-tab
    # strip) and the command palette. Mnemonics are unique within the Decoder scope.
    def self.register_decoder(r : Verb::Registry) : Nil
      in_decoder = ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder }

      # New/Close are COMMON (Round 4), not TAB/SUBTAB: tagging them to the tab-bar/
      # strip tiers meant they were invisible from inside the body panes (INPUT/
      # CHAIN/OUTPUT) — COMMON renders in every context, so session management is
      # now reachable from anywhere in Decoder, same as Copy.
      r.register Verb::Definition.new(
        "decoder.new", "New conversion", "Open a fresh blank conversion sub-tab",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'n') { |ctx| ctx.decoder_new; nil }

      r.register Verb::Definition.new(
        "decoder.close", "Close conversion", "Close the active conversion sub-tab (keeps at least one)",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'w') { |ctx| ctx.decoder_close; nil }

      # Rename the active sub-tab's chip — mirrors repeater.rename-subtab/fuzz.rename-subtab
      # (verbs/history.cr): Decoder is also in renameable_subtabs? (runner.cr), but had no
      # :subtab verb of its own, so its sub-tab-strip space menu was flat COMMON with no
      # way to rename. 'e' is free within COMMON ∪ :subtab (COMMON keys: n/w/y).
      r.register Verb::Definition.new(
        "decoder.rename-subtab", "Rename subtab", "Rename the active conversion's sub-tab chip",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'e', section: :subtab) { |ctx| ctx.decoder_rename_subtab; nil }
      # Content-only clone (input + chain + chip name). 'd' is free in COMMON ∪ :subtab
      # (COMMON keys: n/w/y; :subtab has e).
      r.register Verb::Definition.new(
        "decoder.duplicate-subtab", "Duplicate subtab", "Open a new conversion with the same input and chain",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'd', section: :subtab) { |ctx| ctx.decoder_duplicate_subtab; nil }

      # Clears the INPUT text (and its chain spec) — the INPUT pane's own action.
      r.register Verb::Definition.new(
        "decoder.clear", "Clear input + chain", "Clear the current input and chain spec",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'l', section: :input) { |ctx| ctx.decoder_clear; nil }

      in_decoder_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder && ctx.decoder_read_mode? }
      # The single smart Copy (see repeater.copy in verbs/history.cr) — copy-all is gone.
      r.register Verb::Definition.new(
        "decoder.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, from INPUT/OUTPUT",
        Verb::Scope::Decoder, [Verb::Chord.new("y")],
        available: in_decoder_read, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # Cycles the OUTPUT pane's display mode — tagged :output.
      r.register Verb::Definition.new(
        "decoder.mode", "Cycle output mode", "Cycle the output display: text / hex / base64",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'm', section: :output) { |ctx| ctx.decoder_cycle_mode; nil }

      # Save/load a chain spec by name — tagged :tab (session-level), not :chain:
      # naming and recalling a saved chain is closer to session management (like
      # Repeater's find-subtab / Fuzzer's new-session) than a per-keystroke CHAIN-pane
      # action, and it keeps that pane from carrying its own near-empty group. This
      # also seeds has_section?(Decoder, :tab), so the tab-bar space menu shows a
      # deliberate TAB group (COMMON + Save/Load) instead of falling back to
      # whichever body pane was last focused.
      r.register Verb::Definition.new(
        "decoder.save", "Save chain by name", "Save the current chain spec under a name",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 's', section: :tab) { |ctx| ctx.decoder_save; nil }

      r.register Verb::Definition.new(
        "decoder.load", "Load a saved chain", "Load a previously saved chain spec by name",
        Verb::Scope::Decoder, available: in_decoder, mnemonic: 'o', section: :tab) { |ctx| ctx.decoder_load; nil }

      # Search-and-jump across conversion sub-tabs (section :tab — like repeater.find-subtab)
      # so jumping never needs Ctrl+digit. 'f' (find) since 's'/'o' are taken here by
      # Save/Load in the same :tab group.
      r.register Verb::Definition.new(
        "decoder.find-subtab", "Search sub-tabs", "Filter the open conversions and jump to one",
        Verb::Scope::Decoder,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder && ctx.subtab_search_count >= 2 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }
    end
  end
end
