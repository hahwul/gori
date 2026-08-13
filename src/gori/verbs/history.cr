require "../verb"
require "./links"
require "./read_edit"

module Gori
  module Verbs
    def self.register_history(r : Verb::Registry) : Nil
      in_history = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history }
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }
      # The BATCH gate (#442): "is there anything to act on", where anything = the marks if
      # any are set, else the cursor row. Equivalent to history_selected when nothing is
      # marked, so swapping it in changes no existing behaviour — it only lets a verb stay
      # available when every mark has scrolled out from under the cursor. Batch verbs use
      # this; genuinely single-target ones keep history_selected.
      history_targets = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_ids.empty? }

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
        available: history_selected, mnemonic: 'o', group: :view) { |ctx| ctx.open_detail; nil }

      r.register Verb::Definition.new(
        "history.query", "Filter (QL)", "Filter the list with a query (host: status:>=500 size:>10000 body~regex …)",
        Verb::Scope::Body, [Verb::Chord.new("/")], available: in_history, group: :view) { |ctx| ctx.history_query; nil }

      r.register Verb::Definition.new(
        "history.toggle-follow", "Toggle follow", "Follow newest flows (tail) on/off",
        Verb::Scope::Body, [Verb::Chord.new("f")], available: in_history, group: :view) { |ctx| ctx.toggle_follow; nil }

      # --- multi-select marks (#442) ---
      # Marks make the EXISTING space menu act on N flows — every batch verb below reads
      # ctx.selected_flow_ids ("marks if any, else the cursor row"), so there are no
      # `history.batch-*` twins and no second menu: one declaration, one call path (P1).
      #
      # `t` is a bare-key (L1) claim against the L3-by-default budget in docs/guide/hotkeys:
      # marking is a many-times-per-minute gesture during triage, the same argument that
      # earns `y` (copy) and `f` (follow) theirs. It is also mutt's tag key. NOT `x`/`v`:
      # `x` is already a Scope::Body chord (project.select-line) and `v` a Body menu key
      # (project.clear-selection) — both gated to other tabs at runtime, but
      # validate_menu_keys!/keymap_spec don't know that (see the project.copy note in
      # verbs/core.cr:124).
      r.register Verb::Definition.new(
        "history.mark-toggle", "Mark flow", "Mark/unmark this flow and step to the next older one — the space menu then acts on every marked flow",
        Verb::Scope::Body, [Verb::Chord.new("t")],
        available: history_selected, mnemonic: 't', group: :triage) { |ctx| ctx.history_mark_toggle; nil }

      # ⇧T, the list's Ctrl+A: mark everything the CURRENT filter shows, so `/ status:>=500`
      # then ⇧T marks exactly the errors. The chord is Chord.new("t", shift: true), NOT
      # Chord.new("T") — Keybind.from_event normalises a typed capital to shift+lowercase, so
      # a "T" chord would never fire; menu_key skips shift chords, hence the explicit mnemonic.
      r.register Verb::Definition.new(
        "history.mark-all", "Mark all (filtered)", "Mark every flow the current filter shows",
        Verb::Scope::Body, [Verb::Chord.new("t", shift: true)],
        available: in_history, mnemonic: 'T', group: :triage) { |ctx| ctx.history_mark_all; nil }

      # esc clears too (HistoryController#handle_body_key shadows body.to-menu only while
      # marks are set) — that's the reflex; this is the discoverable form. Menu-only: 'N' is
      # free across Body COMMON, and clearing is not worth a chord of its own.
      r.register Verb::Definition.new(
        "history.mark-clear", "Clear marks", "Drop every mark (esc does the same)",
        Verb::Scope::Body,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && ctx.marked_flow_count > 0 },
        mnemonic: 'N') { |ctx| ctx.history_mark_clear; nil }

      # ⇧↑/⇧↓ extend a contiguous range from the anchor — the keyboard form of a GUI
      # shift+click, and free in the list scope: HistoryController binds ⇧arrows only in the
      # detail drill-in (text selection), and Keymap#lookup matches a Chord record EXACTLY,
      # so Chord("up", shift: true) never collided with body.up's Chord("up") — it simply
      # fell through to a no-op. Hidden like the other nav primitives (body.up/body.down),
      # but hidden does NOT gate the tab and Scope::Body is shared with Project/Comparer, so
      # they still need in_history.
      r.register Verb::Definition.new(
        "history.mark-extend-down", "Extend marks down", "Extend the marked range one row down",
        Verb::Scope::Body, [Verb::Chord.new("down", shift: true)],
        hidden: true, available: in_history) { |ctx| ctx.history_mark_extend(1); nil }

      r.register Verb::Definition.new(
        "history.mark-extend-up", "Extend marks up", "Extend the marked range one row up",
        Verb::Scope::Body, [Verb::Chord.new("up", shift: true)],
        hidden: true, available: in_history) { |ctx| ctx.history_mark_extend(-1); nil }

      # One flow → its raw request. N marked → the URL list (concatenating N request dumps
      # is never the ask); the other multi-flow formats live behind history.copy-as.
      r.register Verb::Definition.new(
        "history.copy", "Copy flow", "Copy the selected flow — or every marked flow's URL — to the clipboard",
        Verb::Scope::Body, [Verb::Chord.new("y")],
        available: history_targets, group: :copy) { |ctx| ctx.copy_selection; nil }

      # "Copy as X" for the list, mirroring repeater.copy-as / detail.copy-as: a picker over
      # urls / host list / curl / raw requests / raw responses / req+res pairs, spanning the
      # whole marked set. Menu key 'Y' pairs with copy's 'y', the same way it does in the
      # Repeater and the detail drill-in. (It was 'F' while project.copy squatted Body's 'Y'
      # from the Project tab — that verb now lives in Verb::Scope::ProjectDesc.)
      r.register Verb::Definition.new(
        "history.copy-as", "Copy as…", "Pick a copy format for the selected/marked flows (urls/hosts/curl/raw)",
        Verb::Scope::Body, available: history_targets, mnemonic: 'Y', group: :copy) { |ctx| ctx.copy_as_open; nil }

      r.register Verb::Definition.new(
        "history.repeater", "Repeater flow", "Open the selected flow in the Repeater tab",
        Verb::Scope::Body, [Verb::Chord.new("r", ctrl: true)],
        available: history_targets, mnemonic: 'r', group: :send) { |ctx| ctx.repeater_selected; nil }

      # Spider + brute-force the selected flow's host (opens the Discover config popup; the
      # run streams into the Target → Discover sub-tab). Menu-only (no chord).
      r.register Verb::Definition.new(
        "history.discover", "Discover from flow", "Spider + brute-force the selected flow's host",
        Verb::Scope::Body, [] of Verb::Chord,
        available: history_targets, mnemonic: 'd', group: :send) { |ctx| ctx.history_discover; nil }

      # Send the selected flow to the Comparer's next slot (A → B → A), then open the
      # Comparer tab to view the diff.
      r.register Verb::Definition.new(
        "history.compare", "Send to Comparer", "Send the selected flow to the Comparer (next slot A/B)",
        Verb::Scope::Body, available: history_targets, mnemonic: 'c', group: :send) { |ctx| ctx.comparer_add_selected; nil }

      # Manually run the Probe ACTIVE checks (reflected params, CORS) against the selected flow,
      # regardless of the Probe mode — opens a confirm dialog with the expected request count.
      # Menu-only ('A'); mirrors detail.probe-active in the drill-in.
      r.register Verb::Definition.new(
        "history.probe-active", "Run active scan", "Run the Probe active checks against the selected flow (shows the request count first)",
        Verb::Scope::Body, available: history_targets, mnemonic: 'A', group: :send) { |ctx| ctx.probe_active_selected; nil }

      # Delete the selected flow (confirm-gated). Menu-only — L3 destructive; 'X' is free
      # across Body COMMON (lowercase 'x' is select-line). Mirrors probe.delete-selected.
      r.register Verb::Definition.new(
        "history.delete", "Delete flow", "Delete the selected flow from History (asks first)",
        Verb::Scope::Body, available: history_targets, mnemonic: 'D', group: :danger) { |ctx| ctx.history_delete; nil }

      # Wipe the project's entire History (confirm-gated). Menu-only; 'C' is free across
      # Body COMMON (lowercase 'c' is compare). Available whenever History has any rows.
      # `X` wipes THIS TAB, `D` deletes the selected row — the pairing `probe.clear` (X) and
      # `probe.delete-selected` (d) already had, and the one History inverted: it read `X` as
      # delete-one and `C` as clear-all, so `X` meant "one flow" here and "every issue" one
      # tab over, both in the danger group. `C` also collided with `Send to Comparer`, which
      # is `C` in the Repeater and the Fuzzer — the Repeater→History move being the most
      # travelled in the app, that letter went from "make a diff" to "wipe the capture".
      # `d` cannot take delete here: it is `history.discover`, which fires outbound traffic.
      r.register Verb::Definition.new(
        "history.clear", "Clear history", "Delete ALL History flows for this project (asks first)",
        Verb::Scope::Body, available: in_history, mnemonic: 'X', group: :danger) { |ctx| ctx.history_clear; nil }

      # --- repeater workbench (request editing is inline; these power the palette
      # and show their key hints — actual keys are handled directly by the TUI) ---
      in_repeater = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater }
      in_repeater_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater && ctx.repeater_read_mode? }
      # Copy is the one READ verb that must also work while TYPING: INS can build a
      # ⇧arrow selection but had no way to copy it, so the next printable replaced it
      # (TextArea#insert cuts the selection). READ keeps bare `y`; INS reaches the same
      # verb through the `^Y` chord, which the editor ladders defer to the keymap.
      in_repeater_copy = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :repeater && (ctx.repeater_read_mode? || ctx.editor_focused?)
      end

      r.register Verb::Definition.new(
        "repeater.send", "Send repeater", "Resend the request byte-exact and diff the response",
        Verb::Scope::Repeater, [Verb::Chord.new("r", ctrl: true)],
        available: in_repeater, mnemonic: 'r') { |ctx| ctx.repeater_send; nil }

      # The single smart Copy: selection if one is active, else the whole focused
      # pane (ctx.read_copy — routes per-tab, added in Round 1). copy-all is gone.
      # Ordered right after Send (Round 5 — COMMON is curated most-used-first: Send,
      # Copy, New, Fuzz, Mine, Link-issue, Link-note; registered here rather than
      # farther down so the physical registration order matches).
      r.register Verb::Definition.new(
        "repeater.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, to the clipboard",
        Verb::Scope::Repeater, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_repeater_copy, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # "Copy as X": a picker of focus-aware copy formats (REQUEST → url/headers/body/
      # cookies/curl/wscat-for-WS/raw · RESPONSE → status+headers/body/raw). Sits beside Copy in
      # COMMON so it's reachable from any Repeater pane; the picker's contents adapt to
      # the pane focused when it opens. Menu key 'Y' pairs with Copy's 'y' and is free
      # across COMMON ∪ every Repeater section (all-lowercase keys there).
      r.register Verb::Definition.new(
        "repeater.copy-as", "Copy as…", "Pick a copy format for the focused pane (url/headers/body/cookies/curl/wscat/raw)",
        Verb::Scope::Repeater, available: in_repeater_read, mnemonic: 'Y') { |ctx| ctx.copy_as_open; nil }

      r.register Verb::Definition.new(
        "repeater.new", "New repeater request", "Open a blank request in Repeater to author and send",
        Verb::Scope::Repeater, [Verb::Chord.new("n", ctrl: true)],
        available: in_repeater, mnemonic: 'n') { |ctx| ctx.repeater_new; nil }

      # "Minimize request" (Caido-"squash"-style): strip cosmetic headers, tracking-cookie
      # crumbs and unused query/body params, re-sending to verify the response is unchanged.
      # Runs in the BACKGROUND (bottom-bar spinner + notification) and writes the trimmed
      # request back when done. Menu-only (no chord); 'M' is free across COMMON ∪ every
      # Repeater section (all-lowercase keys there — pairs like Copy 'y' / Copy-as 'Y').
      r.register Verb::Definition.new(
        "repeater.minimize", "Minimize request", "Strip cosmetic headers, cookies and unused params while keeping the response unchanged (runs in the background)",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'M') { |ctx| ctx.repeater_minimize; nil }

      # Search the open repeater sub-tabs and jump to the chosen one — menu-only
      # (no chord), shown only when there are ≥2 sessions to pick between. Tagged
      # :tab (session-level) rather than :common: it's the one verb that seeds
      # has_section?(Repeater, :tab), so the tab-bar space menu shows a deliberate
      # TAB group (COMMON + this) instead of falling back to whatever body focus
      # section (request/response/target) happened to be active last.
      r.register Verb::Definition.new(
        "repeater.find-subtab", "Search sub-tabs", "Filter the open repeater sessions and jump to one",
        Verb::Scope::Repeater,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater && ctx.repeater_subtab_count >= 2 },
        mnemonic: 's', section: :tab) { |ctx| ctx.repeater_find_subtab; nil }

      # Sub-tab rename/close — today's raw key-dispatch on the strip (`r` rename, ^W
      # close) promoted to verbs so the :subtab space-menu group (reachable from the
      # strip) isn't empty. Reuse the SAME shell rename prompt + confirm-gated close
      # (no new logic); mnemonics 'e'/'w' are free within COMMON ∪ :subtab (COMMON's
      # keys are r/y/n/f/m/k/u — 'e' and 'w' only collide with OTHER sections,
      # which never render alongside :subtab).
      r.register Verb::Definition.new(
        "repeater.rename-subtab", "Rename subtab", "Rename the active repeater sub-tab's chip",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'e', section: :subtab) { |ctx| ctx.repeater_rename_subtab; nil }
      # Tag / filter the sub-tab strip (issue #121). `t` tags the active session, `/`
      # opens the tag-filter bar. 't' is free in COMMON ∪ :subtab (COMMON: r/y/n/f/m/k/u;
      # :subtab: e/w/d); the filter uses '/' (the shared filter idiom, unique here).
      r.register Verb::Definition.new(
        "repeater.tag-subtab", "Tag subtab", "Add/edit flat tags on the active repeater sub-tab",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 't', section: :subtab) { |ctx| ctx.repeater_tag_subtab; nil }
      r.register Verb::Definition.new(
        "repeater.filter-subtabs", "Filter sub-tabs", "Filter the sub-tab strip by tag / name / host / method",
        Verb::Scope::Repeater,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater && ctx.repeater_subtab_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.repeater_filter_subtabs; nil }
      r.register Verb::Definition.new(
        "repeater.close-subtab", "Close subtab", "Close the active repeater sub-tab",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'w', section: :subtab) { |ctx| ctx.repeater_close_subtab; nil }
      # Duplicate the active session into a new sibling (content only — no flow/links).
      # 'd' is free in COMMON ∪ :subtab (COMMON: r/y/n/f/m/k/u; :subtab already has e/w).
      r.register Verb::Definition.new(
        "repeater.duplicate-subtab", "Duplicate subtab", "Open a new sub-tab with the same request content",
        Verb::Scope::Repeater,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater && ctx.repeater_subtab_count >= 1 },
        mnemonic: 'd', section: :subtab) { |ctx| ctx.repeater_duplicate_subtab; nil }

      # --- REQUEST pane, §…§ markers (mark request values, attach Decoder chains applied
      # on send — always active, no mode). The marker actions the user reaches for most
      # (insert/mark/auto/clear/attach), THEN the view toggles (hex/decoded/pretty) below.
      r.register Verb::Definition.new(
        "repeater.insert-marker", "Insert marker", "Drop a single § at the cursor to bracket a region by hand",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'i', section: :request) { |ctx| ctx.repeater_insert_marker; nil }
      # ^K, matching the Fuzzer's. The two panes are the same editor over the same template
      # grammar, and this was the one marker action reachable in one and not the other —
      # the Repeater had it on the space menu alone while the Fuzzer had it on a chord.
      r.register Verb::Definition.new(
        "repeater.mark-word", "Mark word", "Toggle a §…§ marker around the token at the cursor",
        Verb::Scope::Repeater, [Verb::Chord.new("k", ctrl: true)],
        available: in_repeater, mnemonic: 'w', section: :request) { |ctx| ctx.repeater_mark_word; nil }
      r.register Verb::Definition.new(
        "repeater.auto-mark", "Auto-mark params", "Wrap every request parameter value in a §…§ marker",
        Verb::Scope::Repeater, [Verb::Chord.new("a", ctrl: true)],
        available: in_repeater, mnemonic: 'a', section: :request) { |ctx| ctx.repeater_auto_mark; nil }
      r.register Verb::Definition.new(
        "repeater.clear-marks", "Clear markers", "Strip every §…§ marker (and its attached chain)",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'c', section: :request) { |ctx| ctx.repeater_clear_marks; nil }
      # ^Q, not ^Y: `^Y` is now Copy in every text box (see `in_repeater_copy`), and Copy is
      # the far more frequent action of the two, so it takes the chord whose letter means
      # something. attach-chain keeps a CTRL chord rather than falling back to its space-menu
      # mnemonic because the space menu is unreachable from INS (`Runner#handle_key`: "text
      # editors swallow keys upstream, so space stays a literal char there") — and attaching a
      # chain to a `§` marker you have just typed is an INS-mode action. Both are rebindable.
      r.register Verb::Definition.new(
        "repeater.attach-chain", "Edit decoder chain", "Focus the CHAIN pane to edit the encode/decode chain of the marker at the cursor (applied on send)",
        Verb::Scope::Repeater, [Verb::Chord.new("q", ctrl: true)],
        available: in_repeater, mnemonic: 'e', section: :request) { |ctx| ctx.repeater_attach_chain; nil }

      # Request-pane VIEW toggles — keymap-driven (Repeater scope) so they're rebindable.
      # The Runner delegators carry the pane-gating + status messages. Hex-edit the
      # request bytes, switch its envelope/decoded split, pretty-print its body —
      # mnemonics added so they front the :request space-menu group (previously
      # ctrl-only, so menu_key was nil and they were invisible there).
      # 'x', matching its own ^X. It was 'b', and `b` is the app's WHITESPACE letter: the
      # global reveal is ^B (`view.reveal-ws`) and the History detail binds bare `b` to
      # `detail.toggle-ws`. So the Repeater's menu read `b` as hex while the drill-in one
      # keystroke away read it as whitespace. `x` was free in `common ∪ :request` — the
      # response pane's is not (`repeater.select-line` owns `x` there), which is why
      # `repeater.toggle-resp-hex` keeps 'h' and `detail.toggle-hex` keeps 'e'.
      r.register Verb::Definition.new(
        "repeater.toggle-hex", "Toggle hex edit", "Edit the request as raw bytes — sends exactly what you type",
        Verb::Scope::Repeater, [Verb::Chord.new("x", ctrl: true)],
        available: in_repeater, mnemonic: 'x', section: :request) { |ctx| ctx.repeater_toggle_hex; nil }
      r.register Verb::Definition.new(
        "repeater.toggle-decoded", "Switch envelope/decoded", "SAML/GraphQL/WS flow: switch envelope/decoded · otherwise: insert a § marker at the cursor",
        Verb::Scope::Repeater, [Verb::Chord.new("t", ctrl: true)],
        available: in_repeater, mnemonic: 'd', section: :request) { |ctx| ctx.repeater_toggle_decoded; nil }
      r.register Verb::Definition.new(
        "repeater.pretty-request", "Pretty-print request", "Format the request body in-place (JSON/XML/form-urlencoded)",
        Verb::Scope::Repeater, [Verb::Chord.new("u", ctrl: true)],
        available: in_repeater, mnemonic: 'p', section: :request) { |ctx| ctx.repeater_pretty_request; nil }

      # Target-pane toggle (SNI override) — tagged :target so it fronts the space menu
      # when the TARGET field has focus (previously ctrl-only ⇒ invisible there).
      r.register Verb::Definition.new(
        "repeater.toggle-sni", "Toggle SNI override", "Override the TLS SNI on the target pane (dialed host unchanged)",
        Verb::Scope::Repeater, [Verb::Chord.new("s", ctrl: true)],
        available: in_repeater, mnemonic: 's', section: :target) { |ctx| ctx.repeater_toggle_sni; nil }
      r.register Verb::Definition.new(
        "repeater.toggle-auto-content-length", "Toggle auto Content-Length", "Recompute Content-Length from the body on send",
        Verb::Scope::Repeater, [Verb::Chord.new("l", ctrl: true)],
        available: in_repeater, mnemonic: 'L', section: :request) { |ctx| ctx.repeater_toggle_auto_content_length; nil }
      r.register Verb::Definition.new(
        "repeater.toggle-http2", "Toggle HTTP/2 (h2)", "Send this request over HTTP/2 or HTTP/1.1, overriding the captured protocol",
        Verb::Scope::Repeater, [Verb::Chord.new("v", ctrl: true)],
        available: in_repeater, mnemonic: 'h', section: :request) { |ctx| ctx.repeater_toggle_http2; nil }
      # WebSocket handshake only. No chord: `Sec-WebSocket-Key` regeneration is a per-session
      # decision an operator makes once and then forgets, not a key they reach for mid-edit,
      # and the ctrl- space in Repeater is already dense. The HANDSHAKE REQUEST pane carries a
      # KEY badge either way, so the state is visible without opening the menu.
      r.register Verb::Definition.new(
        "repeater.toggle-ws-key", "Toggle Sec-WebSocket-Key reuse",
        "WebSocket: send the handshake's OWN Sec-WebSocket-Key instead of a fresh one — the only way to test an absent, short, duplicated or non-base64 key (off by default: a fresh key avoids a server's replay guard)",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'K', section: :request) { |ctx| ctx.repeater_toggle_ws_key; nil }
      r.register Verb::Definition.new(
        "repeater.send-group", "Send group (one connection)",
        "Pipeline every request (split on a lone %%% line) over ONE keep-alive connection — active request-smuggling / keep-alive reuse — and show each response",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'g', section: :request) { |ctx| ctx.repeater_send_group; nil }

      # --- RESPONSE pane (diff / pretty via keymap so rebind works; hex stays
      # controller-owned on the response pane because plain `x` is also select-line
      # on request/target READ — same letter, pane-local meaning). 'd'/'p' chords are
      # free in COMMON ∪ :response (:request's 'd'/'p' are a different section for the
      # space menu only; keymap last-wins is avoided because request toggles use
      # ctrl chords). Handlers no-op unless the response pane is focused.
      r.register Verb::Definition.new(
        "repeater.toggle-diff", "Toggle diff", "Switch the response pane between the raw response and a diff against the previous one",
        Verb::Scope::Repeater, [Verb::Chord.new("d")],
        available: in_repeater, mnemonic: 'd', section: :response) { |ctx| ctx.repeater_toggle_resp_diff; nil }
      r.register Verb::Definition.new(
        "repeater.toggle-resp-hex", "Hex dump", "Toggle a raw hex dump of the response bytes",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'h', section: :response) { |ctx| ctx.repeater_toggle_resp_hex; nil }
      r.register Verb::Definition.new(
        "repeater.toggle-pretty", "Pretty bodies", "Pretty-print JSON/XML/form/… response bodies (display only)",
        Verb::Scope::Repeater, [Verb::Chord.new("p")],
        available: in_repeater, mnemonic: 'p', section: :response) { |ctx| ctx.toggle_pretty; nil }

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
        "detail.prev-pane", "Previous pane ←", "Move to the previous detail pane (FRAMES → RES → REQ)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("left"), Verb::Chord.new("h")],
        hidden: true) { |ctx| ctx.move_detail_pane(-1); nil }

      r.register Verb::Definition.new(
        "detail.down", "Move detail down", "Move the detail caret down (scroll in hex mode)", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("j"), Verb::Chord.new("down")], hidden: true) { |ctx| ctx.scroll_detail(1); nil }

      r.register Verb::Definition.new(
        "detail.up", "Move detail up", "Move the detail caret up (scroll in hex mode)", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("k"), Verb::Chord.new("up")], hidden: true) { |ctx| ctx.scroll_detail(-1); nil }

      # Shift+←/→ extends a horizontal selection (handled inline in
      # HistoryController#handle_detail_body_key), and there is no h-scroll to bind
      # anywhere: the detail's req/res panes soft-wrap, so a long line is already on the
      # next drawn row rather than off the right edge.

      r.register Verb::Definition.new(
        "detail.toggle-pane", "Switch pane (cycle)", "Cycle REQ → RES → FRAMES",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("tab")], hidden: true) { |ctx| ctx.toggle_detail_pane; nil }

      # The view-toggles are NON-hidden so they front the detail's "space" action menu
      # (the palette stays Global-only, so un-hiding doesn't leak there). ws/pretty take
      # their menu key from their plain chord (b/p) — exactly the key you'd press. Hex is
      # ^X (plain `x` = select-line), so it carries an explicit 'e' mnemonic for the menu.
      r.register Verb::Definition.new(
        "detail.toggle-hex", "Hex view", "Toggle a raw hex dump of the request/response bytes",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("x", ctrl: true)], mnemonic: 'e', group: :view) { |ctx| ctx.toggle_detail_hex; nil }

      r.register Verb::Definition.new(
        "detail.toggle-ws", "Reveal whitespace", "Show whitespace/CR/LF as glyphs (·→␍␊)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("b")], group: :view) { |ctx| ctx.toggle_reveal; nil }

      r.register Verb::Definition.new(
        "detail.toggle-pretty", "Pretty bodies", "Pretty-print JSON/XML/form/… bodies (display only)",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("p")], group: :view) { |ctx| ctx.toggle_pretty; nil }

      # The flow actions mirror the History list's "space" menu so the muscle memory
      # carries into the drill-in (the user's goal). Each keeps the list's exact chord
      # + mnemonic; repeater/issue/fuzz close the detail first so it doesn't float over
      # the destination tab.
      r.register Verb::Definition.new(
        "detail.repeater", "Repeater flow", "Open this flow in the Repeater tab",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("r", ctrl: true)],
        mnemonic: 'r', group: :send) { |ctx| ctx.close_detail; ctx.repeater_selected; nil }

      # Create an issue while reading the flow — the natural moment to file one.
      # Without this, ⇧F silently dead-ends in the detail (it's a Body-scope verb).
      r.register Verb::Definition.new(
        "detail.issue", "Add issue", "Create an issue from this flow",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("f", shift: true)],
        mnemonic: 'a', group: :triage) { |ctx| ctx.close_detail; ctx.issue_create; nil }

      # Send the open flow to the Comparer (mirrors history.compare from the list).
      r.register Verb::Definition.new(
        "detail.compare", "Send to Comparer", "Send this flow to the Comparer (next slot A/B)",
        Verb::Scope::HistoryDetail, mnemonic: 'c', group: :send) { |ctx| ctx.comparer_add_selected; nil }

      # Copy the selection (or current line) from the navigable detail text — flow copy
      # lives in the space menu only (history.copy / detail.copy-flow).
      r.register Verb::Definition.new(
        "detail.copy", "Copy selection", "Copy the selected text (or current line) to the clipboard",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("y")],
        mnemonic: 'y', group: :copy) { |ctx| ctx.detail_copy_selection; nil }

      # "Copy as X" for the drill-in: same focus-aware format picker as Repeater, over the
      # REQUEST/RESPONSE pane bytes. Menu key 'Y' pairs with copy's 'y' (free in the
      # HistoryDetail menu, whose keys are y/O/r/a/c/z/h/x/b/p).
      r.register Verb::Definition.new(
        "detail.copy-as", "Copy as…", "Pick a copy format for this pane (url/headers/body/cookies/curl/raw)",
        Verb::Scope::HistoryDetail, mnemonic: 'Y', group: :copy) { |ctx| ctx.copy_as_open; nil }

      # 'F' for flow, not 'O': `O` is the OAST-payload letter in three scopes
      # (`history.oast-copy` in this very list, `repeater.oast-insert`, `fuzzer.oast-insert`),
      # and HistoryDetail carries no OAST verb — so one `↵` into the drill-in the same letter
      # silently stopped meaning "OAST payload" and started meaning "copy the whole flow".
      # `y` cannot take it here: in the detail that is `detail.copy`, the SELECTION copy.
      r.register Verb::Definition.new(
        "detail.copy-flow", "Copy flow", "Copy this flow's raw request to the clipboard",
        Verb::Scope::HistoryDetail, mnemonic: 'F', group: :copy) { |ctx| ctx.copy_selection; nil }

      # Send the open flow to the Fuzzer (mirrors history.fuzz ⇧I/'z' from the list) —
      # close the detail first so it doesn't float over the Fuzzer tab.
      r.register Verb::Definition.new(
        "detail.fuzz", "Send to Fuzzer", "Open this flow in the Fuzzer tab",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("i", shift: true)],
        mnemonic: 'z', group: :send) { |ctx| ctx.close_detail; ctx.fuzz_selected; nil }

      # Add the open flow's host to the scope lens (mirrors scope.add-host 'h' from the
      # list — also menu-only there; 'h' is the ← pane-nav chord in the detail).
      r.register Verb::Definition.new(
        "detail.add-host", "Add host to scope", "Add this flow's host to the scope lens",
        Verb::Scope::HistoryDetail, mnemonic: 'h', group: :scope) { |ctx| ctx.scope_add_host; nil }

      # Run the Probe active checks against the open flow (mirrors history.probe-active 'A' from
      # the list) — close the detail first so the confirm dialog isn't buried under it.
      r.register Verb::Definition.new(
        "detail.probe-active", "Run active scan", "Run the Probe active checks against this flow (shows the request count first)",
        Verb::Scope::HistoryDetail, mnemonic: 'A', group: :send) { |ctx| ctx.close_detail; ctx.probe_active_selected; nil }

      # Delete the open flow (mirrors history.delete, and its letter): menu-only 'D', so the
      # drill-in does not read `X` as "this one" while the list one keystroke away reads it as
      # "all of them". Confirm runs after the menu closes; the controller captures the id so a
      # live reload can't retarget the delete.
      r.register Verb::Definition.new(
        "detail.delete", "Delete flow", "Delete this flow from History (asks first)",
        Verb::Scope::HistoryDetail, mnemonic: 'D', group: :danger) { |ctx| ctx.history_delete; nil }
    end

    # Fuzzer/Intruder verbs: the cross-tab "send to Fuzzer" (⇧I from History, palette
    # from Repeater) + the Fuzzer-scope actions. run/stop/automark are keymap-driven
    # (rebindable); markword/point/clear/config stay inline in the controller for now.
    def self.register_fuzz(r : Verb::Registry) : Nil
      # The batch gate (#442) — see register_history above. history.fuzz is the only History
      # verb registered here, and it is batch-capable, so this local copy is the plural one.
      history_targets = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_ids.empty? }
      in_fuzzer = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer }
      in_repeater = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater }

      r.register Verb::Definition.new(
        "history.fuzz", "Send to Fuzzer", "Open the selected flow in the Fuzzer tab",
        Verb::Scope::Body, [Verb::Chord.new("i", shift: true)],
        available: history_targets, mnemonic: 'z', group: :send) { |ctx| ctx.fuzz_selected; nil }
      r.register Verb::Definition.new(
        "repeater.fuzz", "Send to Fuzzer", "Turn this repeater request into a fuzz template",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'f') { |ctx| ctx.fuzz_from_repeater; nil }

      r.register Verb::Definition.new(
        "fuzz.run", "Run fuzz", "Start the fuzz/intruder run", Verb::Scope::Fuzzer,
        [Verb::Chord.new("r", ctrl: true)], available: in_fuzzer, mnemonic: 'r') { |ctx| ctx.fuzz_run; nil }
      r.register Verb::Definition.new(
        "fuzz.stop", "Stop fuzz", "Stop the running fuzz", Verb::Scope::Fuzzer,
        [Verb::Chord.new("x", ctrl: true)], available: in_fuzzer, mnemonic: 's') { |ctx| ctx.fuzz_stop; nil }
      # Send the selected result row (the request that produced it) to Repeater — the
      # Miner's mine.repeater for a fuzz result; gated on a selected row so it hides
      # before the first run. COMMON like the Miner's, so it survives the detail
      # overlay (FuzzerView#focus goes to :detail, which a section :results entry
      # would not reach). 'p' is the sibling's key but is taken here by
      # fuzz.pretty-template (:template, and every section view includes COMMON), so
      # 'R' — the letter the other tabs use for Repeater, free in Fuzzer.
      r.register Verb::Definition.new(
        "fuzz.repeater", "Send to Repeater", "Open the selected result's request in Repeater (payload spliced in)",
        Verb::Scope::Fuzzer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_result_selected? },
        mnemonic: 'R') { |ctx| ctx.fuzz_repeater_selected; nil }
      # COMMON (Round 5), not :tab: New-session is a top action the user reaches for
      # from anywhere in the Fuzzer tab, not just the tab bar — mirrors repeater.new
      # (Repeater) and decoder.new (Decoder, Round 4a), both :common. Fuzzer's COMMON
      # is now curated most-used-first: Run, Stop, Send-to-Repeater, New, Copy,
      # Link-issue, Link-note.
      r.register Verb::Definition.new(
        "fuzz.new", "New fuzz session", "Open a blank fuzz template", Verb::Scope::Fuzzer,
        [Verb::Chord.new("n", ctrl: true)],
        available: in_fuzzer, mnemonic: 'n') { |ctx| ctx.fuzz_new; nil }

      # Search-and-jump across open fuzz sessions — the Repeater find-subtab picker,
      # generalised (section :tab so it shows in the tab-bar space menu, like repeater).
      # Gives Fuzzer a sub-tab jump that doesn't depend on Ctrl+digit. 'f' (find) since
      # 's' is taken by fuzz.stop in Fuzzer COMMON.
      r.register Verb::Definition.new(
        "fuzz.find-subtab", "Search sub-tabs", "Filter the open fuzz sessions and jump to one",
        Verb::Scope::Fuzzer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.subtab_search_count >= 2 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }

      # Inline `/` filter bar over the fuzz sub-tab strip (issue #121) — narrows chips by
      # name / host / method + free text. '/' is the shared filter idiom (unique in :tab).
      r.register Verb::Definition.new(
        "fuzz.filter-subtabs", "Filter sub-tabs", "Filter the fuzz sub-tab strip by name / host / method",
        Verb::Scope::Fuzzer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.subtab_search_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }

      # Sub-tab rename/close — mirrors repeater.rename-subtab/repeater.close-subtab above:
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
      # Space-menu letters follow the REPEATER's, which is where the muscle memory lives: this
      # section and `repeater.*`'s `:request` are the same five marker actions, and three of
      # them disagreed — auto-mark was 'a' there and 'm' here, and attach-chain / clear-marks
      # were 'c'/'e' there and 'e'/'c' here, i.e. SWAPPED, which is worse than merely different.
      r.register Verb::Definition.new(
        "fuzz.automark", "Auto-mark params", "Mark every request parameter value", Verb::Scope::Fuzzer,
        [Verb::Chord.new("a", ctrl: true)], available: in_fuzzer, mnemonic: 'a', section: :template) { |ctx| ctx.fuzz_automark; nil }
      # ^K / ^T, the Repeater's twins by name and by mnemonic. They used to live in
      # `FuzzerController#chord_action`, dispatched before the keymap ever saw them — which is
      # why the two marker actions an operator reaches for MOST were the two missing from the
      # Fuzzer's space menu, and the only ones in the family that could not be rebound.
      r.register Verb::Definition.new(
        "fuzz.mark-word", "Mark word", "Toggle a §…§ marker around the token at the cursor",
        Verb::Scope::Fuzzer, [Verb::Chord.new("k", ctrl: true)],
        available: in_fuzzer, mnemonic: 'w', section: :template) { |ctx| ctx.fuzz_mark_word; nil }
      r.register Verb::Definition.new(
        "fuzz.insert-marker", "Insert marker", "Drop a single § at the cursor to bracket a region by hand",
        Verb::Scope::Fuzzer, [Verb::Chord.new("t", ctrl: true)],
        available: in_fuzzer, mnemonic: 'i', section: :template) { |ctx| ctx.fuzz_insert_marker; nil }
      r.register Verb::Definition.new(
        "fuzz.attach-chain", "Edit decoder chain", "Focus the CHAIN pane to edit the encode/decode chain of the marker at the cursor (applied to each payload on send)",
        Verb::Scope::Fuzzer, [Verb::Chord.new("q", ctrl: true)], # ^Y → Copy; see repeater.attach-chain
        available: in_fuzzer, mnemonic: 'e', section: :template) { |ctx| ctx.fuzz_attach_chain; nil }
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
        Verb::Scope::Fuzzer, available: in_fuzzer, mnemonic: 'c', section: :template) { |ctx| ctx.fuzz_clear_marks; nil }
      # Target-pane toggle (SNI override), the twin of repeater.toggle-sni: same ^S, same
      # two-line editor, same focus rule. `FuzzerView` already carried @sni, persisted it
      # with the session and handed it to build_engine — a session seeded from History had
      # no way to REACH it, so an https vhost sweep always presented the dialed IP.
      # 'i' (from SNI), not 's': 's' is fuzz.stop in Fuzzer COMMON, and COMMON renders
      # alongside every section (see fuzz.find-subtab's 'f' for the same trade).
      r.register Verb::Definition.new(
        "fuzz.toggle-sni", "Toggle SNI override", "Override the TLS SNI the whole sweep presents (dialed host unchanged)",
        Verb::Scope::Fuzzer, [Verb::Chord.new("s", ctrl: true)],
        available: in_fuzzer, mnemonic: 'i', section: :target) { |ctx| ctx.fuzz_toggle_sni; nil }
      in_fuzzer_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_read_mode? }
      in_fuzzer_copy = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :fuzzer && (ctx.fuzzer_read_mode? || ctx.editor_focused?)
      end
      # The single smart Copy (see repeater.copy above) — copy-all is gone. `y` in READ,
      # `^Y` in INS, same verb.
      r.register Verb::Definition.new(
        "fuzzer.copy", "Copy", "Copy the selected text, or the whole focused pane if nothing is selected, to the clipboard",
        Verb::Scope::Fuzzer, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_fuzzer_copy, mnemonic: 'y') { |ctx| ctx.read_copy; nil }
    end

    # Param-miner verbs: the cross-tab "Mine parameters" entry (space menu in History,
    # History detail, and Repeater) opens a small config popup, then mining runs in the
    # BACKGROUND (the UI stays put). run/stop act on the focused Miner session.
    def self.register_miner(r : Verb::Registry) : Nil
      # The batch gate (#442) — see register_history above. history.mine is batch-capable.
      history_targets = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_ids.empty? }
      in_miner = ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner }
      in_repeater = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater }

      r.register Verb::Definition.new(
        "history.mine", "Mine parameters", "Discover hidden parameters for the selected flow",
        Verb::Scope::Body, available: history_targets, mnemonic: 'm', group: :send) { |ctx| ctx.mine_selected; nil }
      r.register Verb::Definition.new(
        "detail.mine", "Mine parameters", "Discover hidden parameters for this flow",
        Verb::Scope::HistoryDetail, mnemonic: 'm', group: :send) { |ctx| ctx.close_detail; ctx.mine_selected; nil }
      r.register Verb::Definition.new(
        "repeater.mine", "Mine parameters", "Discover hidden parameters for this repeater request",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'm') { |ctx| ctx.mine_from_repeater; nil }

      # Run the Probe active checks against the current Repeater request's last send (COMMON, so
      # it's reachable from any Repeater pane) — opens a confirm with the expected request count.
      r.register Verb::Definition.new(
        "repeater.probe-active", "Run active scan", "Run the Probe active checks against this Repeater request (needs a prior send)",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'A') { |ctx| ctx.probe_active_from_repeater; nil }

      r.register Verb::Definition.new(
        "mine.run", "Run mining", "Re-run parameter mining for this session", Verb::Scope::Miner,
        [Verb::Chord.new("r", ctrl: true)], available: in_miner, mnemonic: 'r') { |ctx| ctx.mine_run; nil }
      r.register Verb::Definition.new(
        "mine.stop", "Stop mining", "Stop the running mine", Verb::Scope::Miner,
        [Verb::Chord.new("x", ctrl: true)], available: in_miner, mnemonic: 's') { |ctx| ctx.mine_stop; nil }
      # Send the selected finding (injected into the session request) to Repeater. COMMON so
      # it's reachable from summary/results/detail; gated on a selected finding. 'R', not 'p':
      # `fuzz.repeater` had to move off `r` too and its comment names 'R' as "the letter the
      # other tabs use for Repeater" — the two tabs with the same problem picked different
      # answers. 'R' is free in COMMON ∪ :subtab here (COMMON: r/s/k/u; :subtab: d).
      r.register Verb::Definition.new(
        "mine.repeater", "Send to Repeater", "Open the selected finding as a request in Repeater (param injected)",
        Verb::Scope::Miner,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && ctx.miner_finding_selected? },
        mnemonic: 'R') { |ctx| ctx.mine_repeater_selected; nil }
      # Content-only clone of the active miner session (request + config; no findings).
      # 'd' is free in COMMON ∪ :subtab (COMMON: r/s/k/u/p).
      r.register Verb::Definition.new(
        "mine.duplicate-subtab", "Duplicate subtab", "Open a new miner session with the same request and config",
        Verb::Scope::Miner, available: in_miner, mnemonic: 'd', section: :subtab) { |ctx| ctx.miner_duplicate_subtab; nil }
      # The strip's `r` rename / ^W close, which `Runner#renameable_subtabs?` and
      # `#subtab_close` have supported for :miner all along with no verbs to show for it —
      # so this `:subtab` group held Duplicate alone while six other multi-session tabs
      # (Repeater, Fuzzer, Comparer, Decoder, JWT, Notes) list all three. 'e'/'w' are free
      # in COMMON ∪ :subtab here (COMMON: r/s/k/y/v/x/S/R; :subtab: d).
      r.register Verb::Definition.new(
        "mine.rename-subtab", "Rename subtab", "Rename the active miner session's sub-tab chip",
        Verb::Scope::Miner, available: in_miner, mnemonic: 'e', section: :subtab) { |ctx| ctx.miner_rename_subtab; nil }
      # `:common`, not `:subtab` — the space menu renders COMMON ∪ the FOCUSED PANE's section,
      # so a `:subtab` close is invisible from the body and reachable only after moving focus
      # to the strip. Decoder and JWT fixed that for themselves; this is the same fix.
      #
      # Repeater and Fuzzer deliberately do NOT follow: `repeater.mark-word` / `fuzz.mark-word`
      # own 'w' in their `:request` / `:template` sections, so a COMMON 'w' would collide there
      # and `Registry#validate_menu_keys!` would raise at boot. Their close stays in :subtab.
      r.register Verb::Definition.new(
        "mine.close-subtab", "Close subtab", "Close the active miner session",
        Verb::Scope::Miner, available: in_miner, mnemonic: 'w') { |ctx| ctx.miner_close_subtab; nil }

      # Sub-tab search + inline filter (issue #121), section :tab — brings Miner to full
      # sub-tab parity (it had neither). Both gate on ≥2 sessions. 'f'/'/' are free here.
      r.register Verb::Definition.new(
        "mine.find-subtab", "Search sub-tabs", "Filter the open mining sessions and jump to one",
        Verb::Scope::Miner,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && ctx.subtab_search_count >= 2 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }

      r.register Verb::Definition.new(
        "mine.filter-subtabs", "Filter sub-tabs", "Filter the mining sub-tab strip by name / host / method",
        Verb::Scope::Miner,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && ctx.subtab_search_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }

      # Repeater's/Fuzzer's "Link…" (Round 5 — relocated OUT of register_links, which
      # registers before register_fuzz/register_miner in Verbs.registry: leaving it
      # there put Link AHEAD of Fuzz/Mine in the Repeater/Fuzzer COMMON group, when
      # the curated order wants it LAST (COMMON = most-used-first: Send/Copy/New/
      # Fuzz/Mine/Link for Repeater; Run/Stop/New/Copy/Link for Fuzzer).
      # Registering it here — after repeater.mine above, and after register_fuzz
      # already ran — achieves that order for free (menu order == registration
      # order, per Registry#for_scope with an empty query). History's own
      # link.history.*/link.history-detail.* and Miner's link.miner.* stay in
      # register_links (their relative order wasn't in scope for this round), and
      # the same one-verb-per-scope shape applies to all five — see the comment there.
      repeater_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :repeater && !ctx.link_repeater_id.nil?
      }
      fuzz_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :fuzzer && !ctx.link_fuzz_id.nil?
      }
      r.register Verb::Definition.new(
        "link.repeater.attach", "Link…", "Attach this repeater session to an issue or note — or create one",
        Verb::Scope::Repeater, available: repeater_linkable, mnemonic: 'k') { |ctx| ctx.link_attach; nil }
      r.register Verb::Definition.new(
        "link.fuzzer.attach", "Link…", "Attach this fuzz session to an issue or note — or create one",
        Verb::Scope::Fuzzer, available: fuzz_linkable, mnemonic: 'k') { |ctx| ctx.link_attach; nil }
    end

    # Builds a registry with every built-in verb registered.
    def self.registry : Verb::Registry
      r = Verb::Registry.new
      register_core(r)
      register_import(r)
      register_history(r)
      register_sitemap(r)
      register_discover(r)
      register_oast(r)
      register_links(r)
      register_issues(r)
      register_probe(r)
      register_fuzz(r)
      register_miner(r)
      register_sequencer(r)
      register_comparer(r)
      register_decoder(r)
      register_jwt(r)
      register_rewriter(r)
      register_colormarker(r)
      register_notes(r)
      register_host_overrides(r)
      register_env(r)
      register_read_edit(r)
      r.validate_menu_keys! # fail fast if any scope has a colliding space-menu key
      r
    end
  end
end
