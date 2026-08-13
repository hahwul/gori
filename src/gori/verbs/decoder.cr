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
        Verb::Scope::Decoder, [Verb::Chord.new("l", ctrl: true)], available: in_decoder, mnemonic: 'l', section: :input) { |ctx| ctx.decoder_clear; nil }

      # The single smart Copy (see repeater.copy in verbs/history.cr) — copy-all is gone.
      # `^Y` used to be a hardcoded copy-OUTPUT chord in DecoderController; it is folded in
      # here so INPUT's INS mode gets the same key, and so the chord is rebindable.
      in_decoder_copy = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :decoder && (ctx.decoder_read_mode? || ctx.editor_focused?)
      end
      r.register Verb::Definition.new(
        "decoder.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, from INPUT/OUTPUT",
        Verb::Scope::Decoder, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_decoder_copy, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # Cycles the OUTPUT pane's display mode — tagged :output.
      r.register Verb::Definition.new(
        "decoder.mode", "Cycle output mode", "Cycle the output display: text / hex / base64",
        Verb::Scope::Decoder, [Verb::Chord.new("x", ctrl: true)], available: in_decoder, mnemonic: 'm', section: :output) { |ctx| ctx.decoder_cycle_mode; nil }

      # Save/load a chain spec by name — COMMON, like New/Close above and for the same
      # reason. These were tagged :tab, which put them ONLY in the tab-bar space menu:
      # from the sub-tab strip (where a conversion is actually managed) and from inside
      # the CHAIN pane (where the spec being saved is on screen and under the caret) they
      # were invisible, and the operator had to walk focus back up to the tab bar to save
      # the thing they were looking at. COMMON renders in every context, so the chain
      # library is now reachable wherever the conversion is.
      r.register Verb::Definition.new(
        "decoder.save", "Save chain by name", "Save the current chain spec under a name",
        Verb::Scope::Decoder, [Verb::Chord.new("s", ctrl: true)], available: in_decoder, mnemonic: 's') { |ctx| ctx.decoder_save; nil }

      r.register Verb::Definition.new(
        "decoder.load", "Load a saved chain", "Pick from the saved chain specs (^X deletes one)",
        Verb::Scope::Decoder, [Verb::Chord.new("o", ctrl: true)], available: in_decoder, mnemonic: 'o') { |ctx| ctx.decoder_load; nil }

      # Search-and-jump across conversion sub-tabs (section :tab — like repeater.find-subtab)
      # so jumping never needs Ctrl+digit. 'f' (find) since 's'/'o' are taken by Save/Load,
      # which are COMMON and so render alongside every section including this one.
      # These two also keep has_section?(Decoder, :tab) alive now that Save/Load left it.
      r.register Verb::Definition.new(
        "decoder.find-subtab", "Search sub-tabs", "Filter the open conversions and jump to one",
        Verb::Scope::Decoder,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder && ctx.subtab_search_count >= 2 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }

      # Inline `/` filter bar over the conversion sub-tab strip (issue #121) — narrows
      # chips by name / free-text over the chain + input. '/' is the shared filter idiom.
      r.register Verb::Definition.new(
        "decoder.filter-subtabs", "Filter sub-tabs", "Filter the conversion sub-tab strip by name / text",
        Verb::Scope::Decoder,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder && ctx.subtab_search_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }
    end
  end
end
