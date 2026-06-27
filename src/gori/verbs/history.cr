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

      # Send the selected flow to the Comparer's next slot (A → B → A). The Comparer
      # tab is hidden by default; reach it with ^P → "Go to Comparer".
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

      # Request-pane toggles — keymap-driven (Replay scope) so they're rebindable. The
      # Runner delegators carry the pane-gating + status messages.
      r.register Verb::Definition.new(
        "replay.toggle-hex", "Toggle hex edit", "Edit the request as raw bytes — sends exactly what you type",
        Verb::Scope::Replay, [Verb::Chord.new("x", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_toggle_hex; nil }
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

      r.register Verb::Definition.new(
        "detail.toggle-pane", "Switch pane (cycle)", "Cycle REQ → RES → FRAMES",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("tab")], hidden: true) { |ctx| ctx.toggle_detail_pane; nil }

      r.register Verb::Definition.new(
        "detail.toggle-hex", "Hex view", "Toggle a raw hex dump of the request/response bytes",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("x")], hidden: true) { |ctx| ctx.toggle_detail_hex; nil }

      r.register Verb::Definition.new(
        "detail.toggle-ws", "Reveal whitespace", "Show whitespace/CR/LF as glyphs (·→␍␊)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("b")], hidden: true) { |ctx| ctx.toggle_reveal; nil }

      r.register Verb::Definition.new(
        "detail.toggle-pretty", "Pretty bodies", "Pretty-print JSON/XML/form/… bodies (display only)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("p")], hidden: true) { |ctx| ctx.toggle_pretty; nil }

      # ^R replays the open flow (mirrors history.replay from the list) — close the
      # detail first so it doesn't float over the Replay tab.
      r.register Verb::Definition.new(
        "detail.replay", "Replay flow", "Open this flow in the Replay tab",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("r", ctrl: true)],
        hidden: true) { |ctx| ctx.close_detail; ctx.replay_selected; nil }

      # Create a finding while reading the flow — the natural moment to file one.
      # Mirrors detail.replay (close the detail, then act on the still-selected flow);
      # without this, ⇧F silently dead-ends in the detail (it's a Body-scope verb).
      r.register Verb::Definition.new(
        "detail.finding", "Add finding", "Create a finding from this flow",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("f", shift: true)],
        hidden: true) { |ctx| ctx.close_detail; ctx.finding_create; nil }

      # Send the open flow to the Comparer (mirrors history.compare from the list).
      r.register Verb::Definition.new(
        "detail.compare", "Send to Comparer", "Send this flow to the Comparer (next slot A/B)",
        Verb::Scope::HistoryDetail) { |ctx| ctx.comparer_add_selected; nil }
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

    # Builds a registry with every built-in verb registered.
    def self.registry : Verb::Registry
      r = Verb::Registry.new
      register_core(r)
      register_history(r)
      register_sitemap(r)
      register_findings(r)
      register_fuzz(r)
      register_comparer(r)
      r
    end
  end
end
