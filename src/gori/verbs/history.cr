require "../verb"
require "./links"
require "./read_edit"

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
      in_replay_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_read_mode? }

      r.register Verb::Definition.new(
        "replay.send", "Send replay", "Resend the request byte-exact and diff the response",
        Verb::Scope::Replay, [Verb::Chord.new("r", ctrl: true)],
        available: in_replay, mnemonic: 'r') { |ctx| ctx.replay_send; nil }

      # The single smart Copy: selection if one is active, else the whole focused
      # pane (ctx.read_copy — routes per-tab, added in Round 1). copy-all is gone.
      # Ordered right after Send (Round 5 — COMMON is curated most-used-first: Send,
      # Copy, New, Fuzz, Mine, Link-finding, Link-note; registered here rather than
      # farther down so the physical registration order matches).
      r.register Verb::Definition.new(
        "replay.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, to the clipboard",
        Verb::Scope::Replay, [Verb::Chord.new("y")],
        available: in_replay_read, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # "Copy as X": a picker of focus-aware copy formats (REQUEST → url/headers/body/
      # cookies/curl/raw · RESPONSE → status+headers/body/raw). Sits beside Copy in
      # COMMON so it's reachable from any Replay pane; the picker's contents adapt to
      # the pane focused when it opens. Menu key 'Y' pairs with Copy's 'y' and is free
      # across COMMON ∪ every Replay section (all-lowercase keys there).
      r.register Verb::Definition.new(
        "replay.copy-as", "Copy as…", "Pick a copy format for the focused pane (url/headers/body/cookies/curl/raw)",
        Verb::Scope::Replay, available: in_replay_read, mnemonic: 'Y') { |ctx| ctx.copy_as_open; nil }

      r.register Verb::Definition.new(
        "replay.new", "New replay request", "Open a blank request in Replay to author and send",
        Verb::Scope::Replay, [Verb::Chord.new("n", ctrl: true)],
        available: in_replay, mnemonic: 'n') { |ctx| ctx.replay_new; nil }

      # Search the open replay sub-tabs and jump to the chosen one — menu-only
      # (no chord), shown only when there are ≥2 sessions to pick between. Tagged
      # :tab (session-level) rather than :common: it's the one verb that seeds
      # has_section?(Replay, :tab), so the tab-bar space menu shows a deliberate
      # TAB group (COMMON + this) instead of falling back to whatever body focus
      # section (request/response/target) happened to be active last.
      r.register Verb::Definition.new(
        "replay.find-subtab", "Search sub-tabs", "Filter the open replay sessions and jump to one",
        Verb::Scope::Replay,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_subtab_count >= 2 },
        mnemonic: 's', section: :tab) { |ctx| ctx.replay_find_subtab; nil }

      # Sub-tab rename/close — today's raw key-dispatch on the strip (`r` rename, ^W
      # close) promoted to verbs so the :subtab space-menu group (reachable from the
      # strip) isn't empty. Reuse the SAME shell rename prompt + confirm-gated close
      # (no new logic); mnemonics 'e'/'w' are free within COMMON ∪ :subtab (COMMON's
      # keys are r/y/n/f/m/k/u — 'e' and 'w' only collide with OTHER sections,
      # which never render alongside :subtab).
      r.register Verb::Definition.new(
        "replay.rename-subtab", "Rename subtab", "Rename the active replay sub-tab's chip",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'e', section: :subtab) { |ctx| ctx.replay_rename_subtab; nil }
      # Tag / filter the sub-tab strip (issue #121). `t` tags the active session, `/`
      # opens the tag-filter bar. 't' is free in COMMON ∪ :subtab (COMMON: r/y/n/f/m/k/u;
      # :subtab: e/w/d); the filter uses '/' (the shared filter idiom, unique here).
      r.register Verb::Definition.new(
        "replay.tag-subtab", "Tag subtab", "Add/edit flat tags on the active replay sub-tab",
        Verb::Scope::Replay, available: in_replay, mnemonic: 't', section: :subtab) { |ctx| ctx.replay_tag_subtab; nil }
      r.register Verb::Definition.new(
        "replay.filter-subtabs", "Filter sub-tabs", "Filter the sub-tab strip by tag / name / host",
        Verb::Scope::Replay,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_subtab_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.replay_filter_subtabs; nil }
      r.register Verb::Definition.new(
        "replay.close-subtab", "Close subtab", "Close the active replay sub-tab",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'w', section: :subtab) { |ctx| ctx.replay_close_subtab; nil }
      # Duplicate the active session into a new sibling (content only — no flow/links).
      # 'd' is free in COMMON ∪ :subtab (COMMON: r/y/n/f/m/k/u; :subtab already has e/w).
      r.register Verb::Definition.new(
        "replay.duplicate-subtab", "Duplicate subtab", "Open a new sub-tab with the same request content",
        Verb::Scope::Replay,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_subtab_count >= 1 },
        mnemonic: 'd', section: :subtab) { |ctx| ctx.replay_duplicate_subtab; nil }

      # --- REQUEST pane, mark-transform (mark request values, attach Convert chains
      # applied on send) — Round 5 order: the marker actions the user reaches for
      # most (toggle the mode, then insert/mark/auto/clear/attach), THEN the view
      # toggles (hex/decoded/pretty) below.
      r.register Verb::Definition.new(
        "replay.toggle-mark-transform", "Toggle MARK transform", "Mark request values (§…§) and apply Convert chains on send",
        Verb::Scope::Replay, [Verb::Chord.new("k", ctrl: true)],
        available: in_replay, mnemonic: 't', section: :request) { |ctx| ctx.replay_toggle_mark_transform; nil }
      r.register Verb::Definition.new(
        "replay.insert-marker", "Insert marker", "Drop a single § at the cursor to bracket a region by hand",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'i', section: :request) { |ctx| ctx.replay_insert_marker; nil }
      r.register Verb::Definition.new(
        "replay.mark-word", "Mark word", "Toggle a §…§ marker around the token at the cursor",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'w', section: :request) { |ctx| ctx.replay_mark_word; nil }
      r.register Verb::Definition.new(
        "replay.auto-mark", "Auto-mark params", "Wrap every request parameter value in a §…§ marker",
        Verb::Scope::Replay, [Verb::Chord.new("a", ctrl: true)],
        available: in_replay, mnemonic: 'a', section: :request) { |ctx| ctx.replay_auto_mark; nil }
      r.register Verb::Definition.new(
        "replay.clear-marks", "Clear markers", "Strip every §…§ marker (and its attached chain)",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'c', section: :request) { |ctx| ctx.replay_clear_marks; nil }
      r.register Verb::Definition.new(
        "replay.attach-chain", "Edit convert chain", "Focus the CHAIN pane to edit the encode/decode chain of the marker at the cursor (applied on send)",
        Verb::Scope::Replay, [Verb::Chord.new("y", ctrl: true)],
        available: in_replay, mnemonic: 'e', section: :request) { |ctx| ctx.replay_attach_chain; nil }

      # Request-pane VIEW toggles — keymap-driven (Replay scope) so they're rebindable.
      # The Runner delegators carry the pane-gating + status messages. Hex-edit the
      # request bytes, switch its envelope/decoded split, pretty-print its body —
      # mnemonics added so they front the :request space-menu group (previously
      # ctrl-only, so menu_key was nil and they were invisible there).
      r.register Verb::Definition.new(
        "replay.toggle-hex", "Toggle hex edit", "Edit the request as raw bytes — sends exactly what you type",
        Verb::Scope::Replay, [Verb::Chord.new("x", ctrl: true)],
        available: in_replay, mnemonic: 'x', section: :request) { |ctx| ctx.replay_toggle_hex; nil }
      r.register Verb::Definition.new(
        "replay.toggle-decoded", "Switch envelope/decoded", "SAML/GraphQL flow: switch envelope/decoded · in MARK mode: insert a § at the cursor",
        Verb::Scope::Replay, [Verb::Chord.new("t", ctrl: true)],
        available: in_replay, mnemonic: 'd', section: :request) { |ctx| ctx.replay_toggle_decoded; nil }
      r.register Verb::Definition.new(
        "replay.pretty-request", "Pretty-print request", "Format the request body in-place (JSON/XML/form-urlencoded)",
        Verb::Scope::Replay, [Verb::Chord.new("u", ctrl: true)],
        available: in_replay, mnemonic: 'p', section: :request) { |ctx| ctx.replay_pretty_request; nil }

      # Target-pane toggle (SNI override) — tagged :target so it fronts the space menu
      # when the TARGET field has focus (previously ctrl-only ⇒ invisible there).
      r.register Verb::Definition.new(
        "replay.toggle-sni", "Toggle SNI override", "Override the TLS SNI on the target pane (dialed host unchanged)",
        Verb::Scope::Replay, [Verb::Chord.new("s", ctrl: true)],
        available: in_replay, mnemonic: 's', section: :target) { |ctx| ctx.replay_toggle_sni; nil }
      r.register Verb::Definition.new(
        "replay.toggle-auto-content-length", "Toggle auto Content-Length", "Recompute Content-Length from the body on send",
        Verb::Scope::Replay, [Verb::Chord.new("l", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_toggle_auto_content_length; nil }
      r.register Verb::Definition.new(
        "replay.toggle-http2", "Toggle HTTP/2 (h2)", "Send this request over HTTP/2 or HTTP/1.1, overriding the captured protocol",
        Verb::Scope::Replay, [Verb::Chord.new("v", ctrl: true)],
        available: in_replay, mnemonic: 'h', section: :request) { |ctx| ctx.replay_toggle_http2; nil }
      r.register Verb::Definition.new(
        "replay.send-group", "Send group (one connection)",
        "Pipeline every request (split on a lone %%% line) over ONE keep-alive connection — active request-smuggling / keep-alive reuse — and show each response",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'g', section: :request) { |ctx| ctx.replay_send_group; nil }

      # --- RESPONSE pane (Round 5 order: diff, hex, pretty) — today's plain `d`/`x`/`p`
      # keys, handled inline by ReplayController#handle_replay_response; promoted to
      # verbs purely so the :response space-menu group has something to show. 'd'/'x'/'p'
      # are free in COMMON ∪ :response (COMMON has none of these; :request's own
      # 'd'/'x'/'p' — toggle-decoded/toggle-hex/pretty-request — are a DIFFERENT
      # section, so no bleed). toggle-pretty has no chord (the direct 'p' key in the
      # response pane is handled inline by the controller) and reuses the SAME shared
      # @pretty flag as History detail's `p` toggle.
      r.register Verb::Definition.new(
        "replay.toggle-diff", "Toggle diff", "Switch the response pane between the raw response and a diff against the previous one",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'd', section: :response) { |ctx| ctx.replay_toggle_resp_diff; nil }
      r.register Verb::Definition.new(
        "replay.toggle-resp-hex", "Hex dump", "Toggle a raw hex dump of the response bytes",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'x', section: :response) { |ctx| ctx.replay_toggle_resp_hex; nil }
      r.register Verb::Definition.new(
        "replay.toggle-pretty", "Pretty bodies", "Pretty-print JSON/XML/form/… response bodies (display only)",
        Verb::Scope::Replay, available: in_replay, mnemonic: 'p', section: :response) { |ctx| ctx.toggle_pretty; nil }

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
        "detail.down", "Move detail down", "Move the detail caret down (scroll in hex mode)", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("j"), Verb::Chord.new("down")], hidden: true) { |ctx| ctx.scroll_detail(1); nil }

      r.register Verb::Definition.new(
        "detail.up", "Move detail up", "Move the detail caret up (scroll in hex mode)", Verb::Scope::HistoryDetail,
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

      # Copy the selection (or current line) from the navigable detail text — flow copy
      # lives in the space menu only (history.copy / detail.copy-flow).
      r.register Verb::Definition.new(
        "detail.copy", "Copy selection", "Copy the selected text (or current line) to the clipboard",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("y")],
        mnemonic: 'y') { |ctx| ctx.detail_copy_selection; nil }

      # "Copy as X" for the drill-in: same focus-aware format picker as Replay, over the
      # REQUEST/RESPONSE pane bytes. Menu key 'Y' pairs with copy's 'y' (free in the
      # HistoryDetail menu, whose keys are y/O/r/a/c/z/h/x/b/p).
      r.register Verb::Definition.new(
        "detail.copy-as", "Copy as…", "Pick a copy format for this pane (url/headers/body/cookies/curl/raw)",
        Verb::Scope::HistoryDetail, mnemonic: 'Y') { |ctx| ctx.copy_as_open; nil }

      r.register Verb::Definition.new(
        "detail.copy-flow", "Copy flow", "Copy this flow's raw request to the clipboard",
        Verb::Scope::HistoryDetail, mnemonic: 'O') { |ctx| ctx.copy_selection; nil }

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
      # COMMON (Round 5), not :tab: New-session is a top action the user reaches for
      # from anywhere in the Fuzzer tab, not just the tab bar — mirrors replay.new
      # (Replay) and convert.new (Convert, Round 4a), both :common. Fuzzer's COMMON
      # is now curated most-used-first: Run, Stop, New, Copy, Link-finding, Link-note.
      r.register Verb::Definition.new(
        "fuzz.new", "New fuzz session", "Open a blank fuzz template", Verb::Scope::Fuzzer,
        [Verb::Chord.new("n", ctrl: true)],
        available: in_fuzzer, mnemonic: 'n') { |ctx| ctx.fuzz_new; nil }

      # Search-and-jump across open fuzz sessions — the Replay find-subtab picker,
      # generalised (section :tab so it shows in the tab-bar space menu, like replay).
      # Gives Fuzzer a sub-tab jump that doesn't depend on Ctrl+digit. 'f' (find) since
      # 's' is taken by fuzz.stop in Fuzzer COMMON.
      r.register Verb::Definition.new(
        "fuzz.find-subtab", "Search sub-tabs", "Filter the open fuzz sessions and jump to one",
        Verb::Scope::Fuzzer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.subtab_search_count >= 2 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }

      # Sub-tab rename/close — mirrors replay.rename-subtab/replay.close-subtab above:
      # the strip's raw `r` rename / ^W close, promoted to verbs so :subtab isn't
      # empty. 'e'/'w' are free in COMMON ∪ :subtab (Fuzzer COMMON keys: r/s/y/k/u/S/v).
      r.register Verb::Definition.new(
        "fuzz.rename-subtab", "Rename subtab", "Rename the active fuzz session's sub-tab chip",
        Verb::Scope::Fuzzer, available: in_fuzzer, mnemonic: 'e', section: :subtab) { |ctx| ctx.fuzzer_rename_subtab; nil }
      r.register Verb::Definition.new(
        "fuzz.close-subtab", "Close subtab", "Close the active fuzz session",
        Verb::Scope::Fuzzer, available: in_fuzzer, mnemonic: 'w', section: :subtab) { |ctx| ctx.fuzzer_close_subtab; nil }
      # Content-only clone of the active fuzz session (no run results / flow / links).
      # 'd' is free in COMMON ∪ :subtab.
      r.register Verb::Definition.new(
        "fuzz.duplicate-subtab", "Duplicate subtab", "Open a new fuzz session with the same template and config",
        Verb::Scope::Fuzzer, available: in_fuzzer, mnemonic: 'd', section: :subtab) { |ctx| ctx.fuzzer_duplicate_subtab; nil }
      r.register Verb::Definition.new(
        "fuzz.automark", "Auto-mark params", "Mark every request parameter value", Verb::Scope::Fuzzer,
        [Verb::Chord.new("a", ctrl: true)], available: in_fuzzer, mnemonic: 'm', section: :template) { |ctx| ctx.fuzz_automark; nil }
      r.register Verb::Definition.new(
        "fuzz.attach-chain", "Edit convert chain", "Focus the CHAIN pane to edit the encode/decode chain of the marker at the cursor (applied to each payload on send)",
        Verb::Scope::Fuzzer, [Verb::Chord.new("y", ctrl: true)],
        available: in_fuzzer, mnemonic: 'c', section: :template) { |ctx| ctx.fuzz_attach_chain; nil }
      r.register Verb::Definition.new(
        "fuzz.list-paste", "Add List payload set", "Open the payload-set editor pre-seeded to a List — a multi-line editor, one value per line (paste splits automatically)",
        Verb::Scope::Fuzzer, [Verb::Chord.new("l", ctrl: true)],
        available: in_fuzzer, mnemonic: 'l', section: :template) { |ctx| ctx.fuzz_list_paste; nil }
      r.register Verb::Definition.new(
        "fuzz.pretty-template", "Pretty-print template", "Format the request template body in-place (JSON/XML/form-urlencoded)",
        Verb::Scope::Fuzzer, [Verb::Chord.new("u", ctrl: true)],
        available: in_fuzzer, mnemonic: 'p', section: :template) { |ctx| ctx.fuzz_pretty_template; nil }
      r.register Verb::Definition.new(
        "fuzz.toggle-http2", "Toggle HTTP/2 (h2)", "Run the fuzz over HTTP/2 or HTTP/1.1, overriding the seed flow's protocol",
        Verb::Scope::Fuzzer, [Verb::Chord.new("v", ctrl: true)],
        available: in_fuzzer, mnemonic: 'h', section: :template) { |ctx| ctx.fuzz_toggle_http2; nil }
      r.register Verb::Definition.new(
        "fuzz.clear-marks", "Clear markers", "Strip every §…§ marker (and its attached chain) from the template",
        Verb::Scope::Fuzzer, available: in_fuzzer, mnemonic: 'x', section: :template) { |ctx| ctx.fuzz_clear_marks; nil }
      in_fuzzer_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_read_mode? }
      # The single smart Copy (see replay.copy above) — copy-all is gone.
      r.register Verb::Definition.new(
        "fuzzer.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, to the clipboard",
        Verb::Scope::Fuzzer, [Verb::Chord.new("y")],
        available: in_fuzzer_read, mnemonic: 'y') { |ctx| ctx.read_copy; nil }
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
      # Send the selected finding (injected into the session request) to Replay. COMMON so
      # it's reachable from summary/results/detail; gated on a selected finding. 'p' is free
      # in COMMON ∪ :subtab (COMMON: r/s/k/u; :subtab: d).
      r.register Verb::Definition.new(
        "mine.replay", "Send to Replay", "Open the selected finding as a request in Replay (param injected)",
        Verb::Scope::Miner,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && ctx.miner_finding_selected? },
        mnemonic: 'p') { |ctx| ctx.mine_replay_selected; nil }
      # Content-only clone of the active miner session (request + config; no findings).
      # 'd' is free in COMMON ∪ :subtab (COMMON: r/s/k/u/p).
      r.register Verb::Definition.new(
        "mine.duplicate-subtab", "Duplicate subtab", "Open a new miner session with the same request and config",
        Verb::Scope::Miner, available: in_miner, mnemonic: 'd', section: :subtab) { |ctx| ctx.miner_duplicate_subtab; nil }

      # Replay's/Fuzzer's "Link to finding/note" (Round 5 — relocated OUT of
      # register_links, which registers before register_fuzz/register_miner in
      # Verbs.registry: leaving them there put Link-finding/Link-note AHEAD of
      # Fuzz/Mine in the Replay/Fuzzer COMMON group, when the curated order wants
      # them LAST (COMMON = most-used-first: Send/Copy/New/Fuzz/Mine/Link-finding/
      # Link-note for Replay; Run/Stop/New/Copy/Link-finding/Link-note for Fuzzer).
      # Registering them here — after replay.mine above, and after register_fuzz
      # already ran — achieves that order for free (menu order == registration
      # order, per Registry#for_scope with an empty query). Same ids/titles/
      # handlers as before; only the registration SITE moved. History's own
      # link.history.*/link.history-detail.* and Miner's link.miner.* stay in
      # register_links (their relative order wasn't in scope for this round).
      replay_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :replay && !ctx.link_replay_id.nil?
      }
      fuzz_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :fuzzer && !ctx.link_fuzz_id.nil?
      }
      r.register Verb::Definition.new(
        "link.replay.to-finding", "Link to finding", "Attach this replay session to a finding",
        Verb::Scope::Replay, available: replay_linkable, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }
      r.register Verb::Definition.new(
        "link.replay.to-note", "Link to note", "Attach this replay session to a note",
        Verb::Scope::Replay, available: replay_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }
      r.register Verb::Definition.new(
        "link.fuzzer.to-finding", "Link to finding", "Attach this fuzz session to a finding",
        Verb::Scope::Fuzzer, available: fuzz_linkable, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }
      r.register Verb::Definition.new(
        "link.fuzzer.to-note", "Link to note", "Attach this fuzz session to a note",
        Verb::Scope::Fuzzer, available: fuzz_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }
    end

    # Builds a registry with every built-in verb registered.
    def self.registry : Verb::Registry
      r = Verb::Registry.new
      register_core(r)
      register_import(r)
      register_history(r)
      register_sitemap(r)
      register_links(r)
      register_findings(r)
      register_prism(r)
      register_fuzz(r)
      register_miner(r)
      register_comparer(r)
      register_convert(r)
      register_notes(r)
      register_host_overrides(r)
      register_env(r)
      register_read_edit(r)
      r.validate_menu_keys! # fail fast if any scope has a colliding space-menu key
      r
    end
  end
end
