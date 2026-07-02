require "../verb"

module Gori
  module Verbs
    def self.register_history(r : Verb::Registry) : Nil
      in_history = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history }
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }

      # --- content pane (Body) navigation: arrow keys / hjkl ---
      r.register Verb::Definition.new(
        "body.down", "Select next flow", "Move selection down", Verb::Scope::Body,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.move_selection(1); nil }

      r.register Verb::Definition.new(
        "body.up", "Select previous flow", "Move selection up", Verb::Scope::Body,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.move_selection(-1); nil }

      # (No left/h → tab bar here: ← was an easy overshoot when walking back out of
      #  the detail's REQ/RES panes. esc (body.to-menu) / ↑-at-top go up instead.)

      r.register Verb::Definition.new(
        "body.open", "Open flow detail", "View the selected request/response", Verb::Scope::Body,
        [Verb::Chord.new("enter"), Verb::Chord.new("right"), Verb::Chord.new("l")],
        available: history_selected, mnemonic: 'o') { |ctx| ctx.open_detail; nil }

      r.register Verb::Definition.new(
        "history.query", "Filter (QL)", "Filter the list with a query (host: status:>=500 size:>10000 body~regex …)",
        Verb::Scope::Body, [Verb::Chord.new("/")], available: in_history) { |ctx| ctx.history_query; nil }

      r.register Verb::Definition.new(
        "history.toggle-follow", "Toggle follow", "Follow newest flows (tail) on/off",
        Verb::Scope::Body, [Verb::Chord.new("f")], available: in_history) { |ctx| ctx.toggle_follow; nil }

      r.register Verb::Definition.new(
        "history.copy", "Copy flow", "Copy the selected flow to the clipboard",
        Verb::Scope::Body, [Verb::Chord.new("y")],
        available: history_selected) { |ctx| ctx.copy_selection; nil }

      r.register Verb::Definition.new(
        "history.replay", "Replay flow", "Open the selected flow in the Replay tab",
        Verb::Scope::Body, [Verb::Chord.new("r", ctrl: true)],
        available: history_selected, mnemonic: 'r') { |ctx| ctx.replay_selected; nil }

      # Send the selected flow to the Comparer's next slot (A → B → A), then open the
      # Comparer tab to view the diff.
      r.register Verb::Definition.new(
        "history.compare", "Send to Comparer", "Send the selected flow to the Comparer (next slot A/B)",
        Verb::Scope::Body, available: history_selected, mnemonic: 'c') { |ctx| ctx.comparer_add_selected; nil }

      # --- replay workbench (request editing is inline; these power the palette
      # and show their key hints — actual keys are handled directly by the TUI) ---
      in_replay = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay }

      r.register Verb::Definition.new(
        "replay.send", "Send replay", "Resend the request byte-exact and diff the response",
        Verb::Scope::Replay, [Verb::Chord.new("r", ctrl: true)],
        available: in_replay, mnemonic: 'r') { |ctx| ctx.replay_send; nil }

      r.register Verb::Definition.new(
        "replay.new", "New replay request", "Open a blank request in Replay to author and send",
        Verb::Scope::Replay, [Verb::Chord.new("n", ctrl: true)],
        available: in_replay, mnemonic: 'n') { |ctx| ctx.replay_new; nil }

      # Search the open replay sub-tabs and jump to the chosen one — menu-only
      # (no chord), shown only when there are ≥2 sessions to pick between.
      r.register Verb::Definition.new(
        "replay.find-subtab", "Search sub-tabs", "Filter the open replay sessions and jump to one",
        Verb::Scope::Replay,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_subtab_count >= 2 },
        mnemonic: 's') { |ctx| ctx.replay_find_subtab; nil }

      # Request-pane toggles — keymap-driven (Replay scope) so they're rebindable. The
      # Runner delegators carry the pane-gating + status messages.
      r.register Verb::Definition.new(
        "replay.toggle-hex", "Toggle hex edit", "Edit the request as raw bytes — sends exactly what you type",
        Verb::Scope::Replay, [Verb::Chord.new("x", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_toggle_hex; nil }
      r.register Verb::Definition.new(
        "replay.toggle-decoded", "Switch envelope/decoded", "For a SAML/GraphQL flow: switch between the request envelope and the decoded payload",
        Verb::Scope::Replay, [Verb::Chord.new("t", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_toggle_decoded; nil }
      r.register Verb::Definition.new(
        "replay.toggle-sni", "Toggle SNI override", "Override the TLS SNI on the target pane (dialed host unchanged)",
        Verb::Scope::Replay, [Verb::Chord.new("s", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_toggle_sni; nil }
      r.register Verb::Definition.new(
        "replay.toggle-auto-content-length", "Toggle auto Content-Length", "Recompute Content-Length from the body on send",
        Verb::Scope::Replay, [Verb::Chord.new("l", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_toggle_auto_content_length; nil }

      # --- detail view ---
      # esc/q always leave. ← walks back through the panes (FRAMES→RES→REQ) and only
      # returns to the list once past REQUEST; → walks forward (REQ→RES→FRAMES).
      r.register Verb::Definition.new(
        "detail.close", "Close detail", "Return to the History list", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("q")],
        hidden: true) { |ctx| ctx.close_detail; nil }

      r.register Verb::Definition.new(
        "detail.next-pane", "Next pane →", "Move to the next detail pane (REQ → RES → FRAMES)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("right"), Verb::Chord.new("l")],
        hidden: true) { |ctx| ctx.move_detail_pane(1); nil }

      r.register Verb::Definition.new(
        "detail.prev-pane", "Previous pane ←", "Move to the previous detail pane (FRAMES → RES → REQ; past REQ returns to the list)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("left"), Verb::Chord.new("h")],
        hidden: true) { |ctx| ctx.move_detail_pane(-1); nil }

      r.register Verb::Definition.new(
        "detail.down", "Scroll detail down", "Scroll the detail view down", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("j"), Verb::Chord.new("down")], hidden: true) { |ctx| ctx.scroll_detail(1); nil }

      r.register Verb::Definition.new(
        "detail.up", "Scroll detail up", "Scroll the detail view up", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("k"), Verb::Chord.new("up")], hidden: true) { |ctx| ctx.scroll_detail(-1); nil }

      # Shift+←/→ scroll a long line sideways instead of walking panes (plain ←/→,
      # registered above as detail.next-pane/detail.prev-pane) — distinct chords
      # (shift: true), so they coexist without collision.
      r.register Verb::Definition.new(
        "detail.hscroll-right", "Scroll detail right", "Scroll a long line right", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("right", shift: true)], hidden: true) { |ctx| ctx.hscroll_detail(1); nil }

      r.register Verb::Definition.new(
        "detail.hscroll-left", "Scroll detail left", "Scroll a long line left", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("left", shift: true)], hidden: true) { |ctx| ctx.hscroll_detail(-1); nil }

      r.register Verb::Definition.new(
        "detail.toggle-pane", "Switch pane (cycle)", "Cycle REQ → RES → FRAMES",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("tab")], hidden: true) { |ctx| ctx.toggle_detail_pane; nil }

      # The view-toggles are NON-hidden so they front the detail's "space" action menu
      # (the palette stays Global-only, so un-hiding doesn't leak there). The shown
      # menu key derives from each plain chord — exactly the key you'd press directly.
      r.register Verb::Definition.new(
        "detail.toggle-hex", "Hex view", "Toggle a raw hex dump of the request/response bytes",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("x")]) { |ctx| ctx.toggle_detail_hex; nil }

      r.register Verb::Definition.new(
        "detail.toggle-ws", "Reveal whitespace", "Show whitespace/CR/LF as glyphs (·→␍␊)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("b")]) { |ctx| ctx.toggle_reveal; nil }

      r.register Verb::Definition.new(
        "detail.toggle-pretty", "Pretty bodies", "Pretty-print JSON/XML/form/… bodies (display only)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("p")]) { |ctx| ctx.toggle_pretty; nil }

      # The flow actions mirror the History list's "space" menu so the muscle memory
      # carries into the drill-in (the user's goal). Each keeps the list's exact chord
      # + mnemonic; replay/finding/fuzz close the detail first so it doesn't float over
      # the destination tab.
      r.register Verb::Definition.new(
        "detail.replay", "Replay flow", "Open this flow in the Replay tab",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("r", ctrl: true)],
        mnemonic: 'r') { |ctx| ctx.close_detail; ctx.replay_selected; nil }

      # Create a finding while reading the flow — the natural moment to file one.
      # Without this, ⇧F silently dead-ends in the detail (it's a Body-scope verb).
      r.register Verb::Definition.new(
        "detail.finding", "Add finding", "Create a finding from this flow",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("f", shift: true)],
        mnemonic: 'a') { |ctx| ctx.close_detail; ctx.finding_create; nil }

      # Send the open flow to the Comparer (mirrors history.compare from the list).
      r.register Verb::Definition.new(
        "detail.compare", "Send to Comparer", "Send this flow to the Comparer (next slot A/B)",
        Verb::Scope::HistoryDetail, mnemonic: 'c') { |ctx| ctx.comparer_add_selected; nil }

      # Copy the open flow (mirrors history.copy 'y' from the list) — stays in the detail.
      r.register Verb::Definition.new(
        "detail.copy", "Copy flow", "Copy this flow to the clipboard",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("y")]) { |ctx| ctx.copy_selection; nil }

      # Send the open flow to the Fuzzer (mirrors history.fuzz ⇧I/'z' from the list) —
      # close the detail first so it doesn't float over the Fuzzer tab.
      r.register Verb::Definition.new(
        "detail.fuzz", "Send to Fuzzer", "Open this flow in the Fuzzer tab",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("i", shift: true)],
        mnemonic: 'z') { |ctx| ctx.close_detail; ctx.fuzz_selected; nil }

      # Add the open flow's host to the scope lens (mirrors scope.add-host 'h' from the
      # list — also menu-only there; 'h' is the ← pane-nav chord in the detail).
      r.register Verb::Definition.new(
        "detail.add-host", "Add host to scope", "Add this flow's host to the scope lens",
        Verb::Scope::HistoryDetail, mnemonic: 'h') { |ctx| ctx.scope_add_host; nil }
    end

    # Fuzzer/Intruder verbs: the cross-tab "send to Fuzzer" (⇧I from History, palette
    # from Replay) + the Fuzzer-scope actions. run/stop/automark are keymap-driven
    # (rebindable); markword/point/clear/config stay inline in the controller for now.
    def self.register_fuzz(r : Verb::Registry) : Nil
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }
      in_fuzzer = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer }
      in_replay = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay }

      r.register Verb::Definition.new(
        "history.fuzz", "Send to Fuzzer", "Open the selected flow in the Fuzzer tab",
        Verb::Scope::Body, [Verb::Chord.new("i", shift: true)],
        available: history_selected, mnemonic: 'z') { |ctx| ctx.fuzz_selected; nil }
      r.register Verb::Definition.new(
        "replay.fuzz", "Send to Fuzzer", "Turn this replay request into a fuzz template",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'f') { |ctx| ctx.fuzz_from_replay; nil }

      r.register Verb::Definition.new(
        "fuzz.run", "Run fuzz", "Start the fuzz/intruder run", Verb::Scope::Fuzzer,
        [Verb::Chord.new("r", ctrl: true)], available: in_fuzzer, mnemonic: 'r') { |ctx| ctx.fuzz_run; nil }
      r.register Verb::Definition.new(
        "fuzz.stop", "Stop fuzz", "Stop the running fuzz", Verb::Scope::Fuzzer,
        [Verb::Chord.new("x", ctrl: true)], available: in_fuzzer, mnemonic: 's') { |ctx| ctx.fuzz_stop; nil }
      r.register Verb::Definition.new(
        "fuzz.new", "New fuzz session", "Open a blank fuzz template", Verb::Scope::Fuzzer,
        [Verb::Chord.new("n", ctrl: true)],
        available: in_fuzzer, mnemonic: 'n') { |ctx| ctx.fuzz_new; nil }
      r.register Verb::Definition.new(
        "fuzz.automark", "Auto-mark params", "Mark every request parameter value", Verb::Scope::Fuzzer,
        [Verb::Chord.new("a", ctrl: true)], available: in_fuzzer, mnemonic: 'm') { |ctx| ctx.fuzz_automark; nil }
    end

    # Param-miner verbs: the cross-tab "Mine parameters" entry (space menu in History,
    # History detail, and Replay) opens a small config popup, then mining runs in the
    # BACKGROUND (the UI stays put). run/stop act on the focused Miner session.
    def self.register_miner(r : Verb::Registry) : Nil
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }
      in_miner = ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner }
      in_replay = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay }

      r.register Verb::Definition.new(
        "history.mine", "Mine parameters", "Discover hidden parameters for the selected flow",
        Verb::Scope::Body, available: history_selected, mnemonic: 'm') { |ctx| ctx.mine_selected; nil }
      r.register Verb::Definition.new(
        "detail.mine", "Mine parameters", "Discover hidden parameters for this flow",
        Verb::Scope::HistoryDetail, mnemonic: 'm') { |ctx| ctx.close_detail; ctx.mine_selected; nil }
      r.register Verb::Definition.new(
        "replay.mine", "Mine parameters", "Discover hidden parameters for this replay request",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'm') { |ctx| ctx.mine_from_replay; nil }

      r.register Verb::Definition.new(
        "mine.run", "Run mining", "Re-run parameter mining for this session", Verb::Scope::Miner,
        [Verb::Chord.new("r", ctrl: true)], available: in_miner, mnemonic: 'r') { |ctx| ctx.mine_run; nil }
      r.register Verb::Definition.new(
        "mine.stop", "Stop mining", "Stop the running mine", Verb::Scope::Miner,
        [Verb::Chord.new("x", ctrl: true)], available: in_miner, mnemonic: 's') { |ctx| ctx.mine_stop; nil }
    end

    # Builds a registry with every built-in verb registered.
    def self.registry : Verb::Registry
      r = Verb::Registry.new
      register_core(r)
      register_import(r)
      register_history(r)
      register_sitemap(r)
      register_findings(r)
      register_prism(r)
      register_fuzz(r)
      register_miner(r)
      register_comparer(r)
      register_convert(r)
      register_notes(r)
      register_host_overrides(r)
      r
    end
  end
end
