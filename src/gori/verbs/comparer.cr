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

      # Navigating BY CHANGE and hiding what didn't change. Both gate on a shown diff —
      # there is nothing to jump between, or fold around, on a half-filled comparison.
      # `⇧N`, spelled Chord.new("n", shift: true): Chord.new("N") never fires.
      in_diff = ->(ctx : Verb::ExecContext) { ctx.current_tab == :comparer && ctx.comparer_diff_shown? }

      # Explicit menu mnemonics: the derived ones would be 'n' / 'p' / 'f', and 'n' is
      # comparer.new's — the KEYS here are n / ⇧N / f, so the menu letters carry no meaning
      # worth defending and just have to be free.
      r.register Verb::Definition.new(
        "comparer.next-change", "Next change", "Jump the row cursor to the next changed row",
        Verb::Scope::Comparer, [Verb::Chord.new("n")],
        available: in_diff, mnemonic: 'g') { |ctx| ctx.comparer_jump_change(1); nil }

      r.register Verb::Definition.new(
        "comparer.prev-change", "Previous change", "Jump the row cursor to the previous changed row",
        Verb::Scope::Comparer, [Verb::Chord.new("n", shift: true)],
        available: in_diff, mnemonic: 'G') { |ctx| ctx.comparer_jump_change(-1); nil }

      r.register Verb::Definition.new(
        "comparer.toggle-fold", "Fold unchanged",
        "Collapse the runs of identical lines, keeping context around each change",
        Verb::Scope::Comparer, [Verb::Chord.new("f")],
        available: in_diff, mnemonic: 'z') { |ctx| ctx.comparer_toggle_fold; nil }

      # Sub-tab strip / space menu (session multi-pair workspace).
      r.register Verb::Definition.new(
        "comparer.new", "New comparison", "Open a fresh blank comparison sub-tab",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'n',
        section: :common) { |ctx| ctx.comparer_new; nil }

      r.register Verb::Definition.new(
        "comparer.rename-subtab", "Rename comparison", "Rename the active comparison chip",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'e',
        section: :subtab) { |ctx| ctx.comparer_rename_subtab; nil }

      # `:common`, not `:subtab` — the space menu renders COMMON ∪ the FOCUSED PANE's section,
      # so a `:subtab` close is invisible from the body and reachable only after moving focus
      # to the strip. Decoder and JWT fixed that for themselves; this is the same fix.
      #
      # Repeater and Fuzzer deliberately do NOT follow: `repeater.mark-word` / `fuzz.mark-word`
      # own 'w' in their `:request` / `:template` sections, so a COMMON 'w' would collide there
      # and `Registry#validate_menu_keys!` would raise at boot. Their close stays in :subtab.
      r.register Verb::Definition.new(
        "comparer.close-subtab", "Close comparison", "Close the active comparison sub-tab (keeps ≥1)",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'w') { |ctx| ctx.comparer_close_subtab; nil }

      r.register Verb::Definition.new(
        "comparer.duplicate-subtab", "Duplicate comparison", "Clone the active A/B pair into a new sub-tab",
        Verb::Scope::Comparer, available: in_comparer, mnemonic: 'd',
        section: :subtab) { |ctx| ctx.comparer_duplicate_subtab; nil }

      # Sub-tab search + inline filter (issue #121), section :tab — like the other
      # workbench tabs. Both gate on ≥2 open comparisons. 'f'/'/' are free in this scope.
      r.register Verb::Definition.new(
        "comparer.find-subtab", "Search sub-tabs", "Filter the open comparisons and jump to one",
        Verb::Scope::Comparer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :comparer && ctx.subtab_search_count >= 1 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }

      r.register Verb::Definition.new(
        "comparer.filter-subtabs", "Filter sub-tabs", "Filter the comparison sub-tab strip by name / host / method",
        Verb::Scope::Comparer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :comparer && ctx.subtab_search_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }

      register_send_to_comparer(r)
    end

    # The verbs that FILL a slot, registered here rather than in the tab each fires from:
    # they are one feature with one rule (fill the next slot in the A → B → A ring), and
    # splitting them across four files is how History's stayed the only one for so long.
    #
    # History's own `history.compare` / `detail.compare` stay where they are — they carry the
    # "exactly 2 marked" pairing rule, which is a History concept, not a Comparer one.
    def self.register_send_to_comparer(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "repeater.compare", "Send to Comparer",
        "Send this tab's last send (request + response) to the Comparer's next slot",
        Verb::Scope::Repeater,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater },
        mnemonic: 'C', group: :send) { |ctx| ctx.comparer_add_repeater; nil }

      r.register Verb::Definition.new(
        "sitemap.compare", "Send to Comparer",
        "Send the selected endpoint's captured flow to the Comparer's next slot",
        Verb::Scope::Sitemap, mnemonic: 'c', group: :send) { |ctx| ctx.comparer_add_sitemap; nil }

      r.register Verb::Definition.new(
        "fuzz.compare", "Send to Comparer",
        "Send the selected result (request + response) to the Comparer's next slot",
        Verb::Scope::Fuzzer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_result_selected? },
        mnemonic: 'C') { |ctx| ctx.comparer_add_fuzz; nil }
    end
  end
end
