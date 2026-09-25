module Gori
  module Verb
    # The space menu's intent lexicon (#1274): one menu letter per RECURRING intent, looked up
    # here instead of spelled per verb. A verb that declares `intent:` gets its letter from this
    # table (`Definition#menu_key`), and `Registry#validate_intents!` refuses one that also
    # spells a `mnemonic:`, so two tabs cannot drift apart on "filter" or "export" by review
    # oversight: neither of them names the letter.
    #
    # It is the menu half of the 2026-09-12 bare-key table (DESIGN.md §7): the rows marked R2
    # below are that table's letters carried into the menu. An intent that exists on one tab
    # only is not an entry; its letter stays a per-scope `mnemonic:` or chord.
    #
    # Two tiers:
    #   • :reserved  — in a scope that has the intent, no other verb spends the letter, in any
    #     section (`spec/verb/lexicon_spec.cr`). The R2 letters, the copy/send pickers, the mark
    #     trio, ⇧X, and the sub-tab strip's own actions.
    #   • :preferred — the letter is this intent's wherever the intent exists, and free for a
    #     local meaning where it does not. Reserving every entry app-wide would leave a dozen
    #     letters for the per-scope rows.
    module Lexicon
      record Entry, letter : Char, tier : Symbol

      ENTRIES = {
        # R2 (the 2026-09-12 bare-key table)
        :filter         => Entry.new('/', :reserved),
        :delete         => Entry.new('d', :reserved),
        :select_line    => Entry.new('x', :reserved),
        :copy           => Entry.new('y', :reserved),
        :mark           => Entry.new('t', :reserved),
        :wipe           => Entry.new('X', :reserved), # ⇧X, and only for group :wipe
        :open           => Entry.new('o', :preferred),
        :add            => Entry.new('a', :preferred),
        :edit           => Entry.new('e', :preferred),
        :toggle_enabled => Entry.new('t', :preferred), # rule lists; R2's "flip this row's flag"
        :swap           => Entry.new('s', :preferred), # the body key is `w`; the menu keeps `s`
        :scope_lens     => Entry.new('s', :preferred), # the menu echo of Global `s`
        # the pickers and the mark trio
        :copy_as        => Entry.new('Y', :reserved),
        :send_selection => Entry.new('S', :reserved),
        :mark_all       => Entry.new('T', :reserved),
        :mark_clear     => Entry.new('N', :reserved),
        # the sub-tab strip's own actions (STRIP_INTENTS)
        :new         => Entry.new('n', :reserved),
        :close       => Entry.new('w', :reserved),
        :duplicate   => Entry.new('d', :reserved),
        :rename      => Entry.new('e', :reserved),
        :find_subtab => Entry.new('f', :reserved),
        # the rest of the grammar most rows already follow
        :clear_selection => Entry.new('v', :preferred),
        :file_issue      => Entry.new('a', :preferred), # never `i`: a dropped space holds all traffic
        :run             => Entry.new('r', :preferred), # the menu echo of ^R: run, send, re-run, reload
        :stop            => Entry.new('s', :preferred),
        :export          => Entry.new('E', :preferred),
        :clear_input     => Entry.new('K', :preferred), # the workbench clears, which ask first
        :duplicate_rule  => Entry.new('c', :preferred),
        :move_up         => Entry.new('u', :preferred),
        :move_down       => Entry.new('n', :preferred),
        :oast_payload    => Entry.new('O', :preferred),
        :open_browser    => Entry.new('B', :preferred),
        :mark_word       => Entry.new('W', :preferred),
        :decoder_chain   => Entry.new('D', :preferred),
        :mock            => Entry.new('M', :preferred),
        :set_severity    => Entry.new('s', :preferred),
        :set_status      => Entry.new('c', :preferred),
        :set_cvss        => Entry.new('V', :preferred),
      } of Symbol => Entry

      # The strip's nine: the SUB-TABS bucket rides along with every view of a tab that has a
      # strip (`Registry::SUBTAB_SECTIONS`), and the strip answers some of these raw (`t`
      # marks a chip), so on those tabs a pane verb may not wear one of these letters, even
      # where that tab's own strip lacks the action. `Registry#validate_intents!` raises on it.
      STRIP_INTENTS = {:new, :close, :duplicate, :rename, :mark, :mark_all, :mark_clear, :find_subtab, :filter}

      STRIP_LETTERS = STRIP_INTENTS.map { |i| ENTRIES[i].letter }.to_set

      def self.letter(intent : Symbol) : Char?
        ENTRIES[intent]?.try(&.letter)
      end

      def self.reserved?(intent : Symbol) : Bool
        ENTRIES[intent]?.try(&.tier) == :reserved
      end
    end
  end
end
