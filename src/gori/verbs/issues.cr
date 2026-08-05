require "../verb"

module Gori
  module Verbs
    def self.register_issues(r : Verb::Registry) : Nil
      # create from History (selected flow, or ONE issue carrying every marked flow as
      # evidence — #442). Gates on the effective target set, which also aligns the gate with
      # what the handler already acted on (history_target_flow_id: the open detail's flow).
      r.register Verb::Definition.new(
        "issue.create", "Add issue", "Create an issue from the selected flow (every marked flow is attached as evidence)", Verb::Scope::Body,
        [Verb::Chord.new("f", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_ids.empty? }, mnemonic: 'a', group: :triage) { |ctx| ctx.issue_create; nil }

      # issues list
      r.register Verb::Definition.new(
        "issues.down", "Select next issue", "Move down", Verb::Scope::Issues,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.issues_move(1); nil }

      r.register Verb::Definition.new(
        "issues.up", "Select previous issue", "Move up", Verb::Scope::Issues,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.issues_move(-1); nil }

      # open/delete are NON-hidden so they join New in the Issues list's "space" menu
      # (the palette stays Global-only, so this doesn't leak there). open carries an
      # explicit 'o' mnemonic — its primary chord is enter/l, which would otherwise
      # front the menu with the unintuitive 'l'.
      r.register Verb::Definition.new(
        "issues.open", "Open issue", "View/edit the selected issue", Verb::Scope::Issues,
        [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")], mnemonic: 'o') { |ctx| ctx.issues_open; nil }

      r.register Verb::Definition.new(
        "issues.filter", "Filter issues", "Filter the list (severity:/status:/host:/free text)",
        Verb::Scope::Issues, [Verb::Chord.new("/")]) { |ctx| ctx.issues_query; nil }

      r.register Verb::Definition.new(
        "issues.new", "New issue", "Create a blank issue", Verb::Scope::Issues,
        [Verb::Chord.new("n")]) { |ctx| ctx.issues_new; nil }

      # The BATCH gate: "is there anything to act on", where anything = the marks if any are
      # set, else the cursor row. Equivalent to "a row is selected" when nothing is marked, so
      # it only adds the case where every mark has scrolled out from under the cursor.
      issues_targets = ->(ctx : Verb::ExecContext) { !ctx.selected_issue_ids.empty? }

      r.register Verb::Definition.new(
        "issues.delete", "Delete issue", "Delete the selected issue (or every marked one)",
        Verb::Scope::Issues, [Verb::Chord.new("d")],
        available: issues_targets) { |ctx| ctx.issues_delete; nil }

      # Severity/status from the LIST, so re-triaging a set is one pass: mark five, pick
      # "False positive" once. Same ExecContext methods as the detail-scope pair below —
      # they resolve through selected_issue_ids, so there is one implementation and no
      # `issues.batch-*` twin. Menu keys match the detail's ('s'/'c'); a different scope, so
      # validate_menu_keys! sees no collision.
      r.register Verb::Definition.new(
        "issues.set-severity", "Set severity", "Pick the severity for the selected/marked issues",
        Verb::Scope::Issues, [] of Verb::Chord,
        available: issues_targets, mnemonic: 's') { |ctx| ctx.issue_set_severity; nil }

      r.register Verb::Definition.new(
        "issues.set-status", "Set status", "Pick the triage status for the selected/marked issues",
        Verb::Scope::Issues, [] of Verb::Chord,
        available: issues_targets, mnemonic: 'c') { |ctx| ctx.issue_set_status; nil }

      # --- multi-select marks (the History list's gestures, #442) ---
      # Marks make the EXISTING space menu act on N issues — every batch verb above reads
      # ctx.selected_issue_ids ("marks if any, else the cursor row"). Scope::Issues belongs to
      # this tab alone (unlike Scope::Body, which History shares with Project/Comparer), so no
      # per-verb tab gate is needed here.
      #
      # `t` is the same mark key History uses, deliberately: it is the one gesture that has to
      # feel identical across every list, and marking is a many-times-per-minute triage
      # action (the L1 claim in docs/guide/hotkeys). It DOES pair with `t` = Edit title one
      # ↵ away in Scope::IssuesDetail — the two never resolve together (Keymap#lookup is
      # per-scope) and the detail is a modal drill-in, so the cross-tab consistency wins.
      r.register Verb::Definition.new(
        "issues.mark-toggle", "Mark issue", "Mark/unmark this issue and step down — the space menu then acts on every marked issue",
        Verb::Scope::Issues, [Verb::Chord.new("t")],
        available: ->(ctx : Verb::ExecContext) { !ctx.selected_issue_id.nil? },
        mnemonic: 't') { |ctx| ctx.issues_mark_toggle; nil }

      # ⇧T, the list's Ctrl+A: mark everything the CURRENT filter shows, so `/ severity:high`
      # then ⇧T marks exactly those. The chord is Chord.new("t", shift: true), NOT
      # Chord.new("T") — Keybind.from_event normalises a typed capital to shift+lowercase, so
      # a "T" chord would never fire; menu_key skips shift chords, hence the explicit mnemonic.
      r.register Verb::Definition.new(
        "issues.mark-all", "Mark all (filtered)", "Mark every issue the current filter shows",
        Verb::Scope::Issues, [Verb::Chord.new("t", shift: true)],
        mnemonic: 'T') { |ctx| ctx.issues_mark_all; nil }

      # esc clears too (IssuesController#handle_body_key shadows issues.leave only while marks
      # are set) — that's the reflex; this is the discoverable form. Menu-only: 'N' is free in
      # this scope, and clearing is not worth a chord of its own.
      r.register Verb::Definition.new(
        "issues.mark-clear", "Clear marks", "Drop every mark (esc does the same)",
        Verb::Scope::Issues,
        available: ->(ctx : Verb::ExecContext) { ctx.marked_issue_count > 0 },
        mnemonic: 'N') { |ctx| ctx.issues_mark_clear; nil }

      # ⇧↑/⇧↓ extend a contiguous range from the anchor — the keyboard form of a GUI
      # shift+click, and free here: Keymap#lookup matches a Chord record EXACTLY, so
      # Chord("up", shift: true) never collided with issues.up's Chord("up"); it simply fell
      # through to a no-op. Hidden, like the other nav primitives.
      r.register Verb::Definition.new(
        "issues.mark-extend-down", "Extend marks down", "Extend the marked range one row down",
        Verb::Scope::Issues, [Verb::Chord.new("down", shift: true)],
        hidden: true) { |ctx| ctx.issues_mark_extend(1); nil }

      r.register Verb::Definition.new(
        "issues.mark-extend-up", "Extend marks up", "Extend the marked range one row up",
        Verb::Scope::Issues, [Verb::Chord.new("up", shift: true)],
        hidden: true) { |ctx| ctx.issues_mark_extend(-1); nil }

      r.register Verb::Definition.new(
        "issues.leave", "Back to menu", "Return focus to the tab menu", Verb::Scope::Issues,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil } # esc only; ← was a tab-bar overshoot

      # issue detail
      r.register Verb::Definition.new(
        "issue.close", "Back to list", "Return to the issues list", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.issue_close; nil }

      # Severity/status edits live on the Space menu (a colour picker) so arrows
      # never change them by accident. The bracket/brace chords stay as hidden
      # power-shortcuts (one-step cycling); the pickers are the discoverable path.
      r.register Verb::Definition.new(
        "issue.set-severity", "Set severity", "Pick this issue's severity",
        Verb::Scope::IssuesDetail, [] of Verb::Chord, mnemonic: 's') { |ctx| ctx.issue_set_severity; nil }

      r.register Verb::Definition.new(
        "issue.set-status", "Set status", "Pick this issue's triage status",
        Verb::Scope::IssuesDetail, [] of Verb::Chord, mnemonic: 'c') { |ctx| ctx.issue_set_status; nil }

      r.register Verb::Definition.new(
        "issue.severity-up", "Raise severity", "Increase severity", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("]")], hidden: true) { |ctx| ctx.issue_severity(1); nil }

      r.register Verb::Definition.new(
        "issue.severity-down", "Lower severity", "Decrease severity", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("[")], hidden: true) { |ctx| ctx.issue_severity(-1); nil }

      # edit-notes/edit-title/open-flow/repeater-flow/delete are NON-hidden so they front
      # the issue-detail "space" action menu (parity with the History detail; the
      # palette stays Global-only, so this doesn't leak there). Each menu key derives
      # from its plain chord — the key you'd press directly. severity/status keep their
      # bracket chords ([ ] { }) hidden (awkward as menu mnemonics; discoverable in Help).
      # The single smart Copy (see repeater.copy in verbs/history.cr) — copy-all is gone.
      in_issues_notes_read = ->(ctx : Verb::ExecContext) { ctx.issues_notes_read_mode? }

      r.register Verb::Definition.new(
        "issue.copy", "Copy", "Copy the selected notes text, or the whole notes if nothing is selected, to the clipboard",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("y")],
        available: in_issues_notes_read, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      r.register Verb::Definition.new(
        "issue.edit-notes", "Edit notes", "Edit the issue notes inline (i/↵/e)", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("e")]) { |ctx| ctx.issue_edit_notes; nil }

      # There is no ⇧←/→ h-scroll pair here any more: the notes pane soft-wraps, so nothing
      # sits off to the side to scroll to, and `IssuesController#handle_notes_read_key` had
      # already taken the chord back for the character selection every other text pane gives it.

      r.register Verb::Definition.new(
        "issue.delete", "Delete issue", "Delete this issue", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("d")]) { |ctx| ctx.issues_delete; nil }

      r.register Verb::Definition.new(
        "issue.status-up", "Advance status", "Cycle triage status forward (open→confirmed→fp→resolved)",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("}")], hidden: true) { |ctx| ctx.issue_status(1); nil }

      r.register Verb::Definition.new(
        "issue.status-down", "Revert status", "Cycle triage status backward", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("{")], hidden: true) { |ctx| ctx.issue_status(-1); nil }

      r.register Verb::Definition.new(
        "issue.edit-title", "Edit title/severity", "Rename the issue and set its severity",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("t")]) { |ctx| ctx.issue_edit_title; nil }

      r.register Verb::Definition.new(
        "issue.open-flow", "Open evidence", "Open the linked flow's request/response in History",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("o")]) { |ctx| ctx.issue_open_flow; nil }

      r.register Verb::Definition.new(
        "issue.repeater-flow", "Repeater evidence", "Send the linked flow to the Repeater tab",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("r")]) { |ctx| ctx.issue_repeater_flow; nil }

      r.register Verb::Definition.new(
        "issue.links", "Manage links", "View/add/remove related History/Repeater/Fuzzer/Miner URLs",
        Verb::Scope::IssuesDetail, mnemonic: 'l') { |ctx| ctx.issue_links; nil }

      r.register Verb::Definition.new(
        "issue.open-link", "Open linked item", "Open the selected related URL in its tab",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("enter")], hidden: true) { |ctx| ctx.issue_open_link; nil }

      r.register Verb::Definition.new(
        "issue.link-down", "Next related link", "Select the next related item",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.issue_link_move(1); nil }

      r.register Verb::Definition.new(
        "issue.link-up", "Previous related link", "Select the previous related item",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.issue_link_move(-1); nil }

      # Export (palette/Global — the issues' way out): ask for a destination path, then
      # write the report there. All three entries below open the same popup, prefilled with
      # <cwd>/issues.{md,json}; the path used to be hardcoded to the project dir.
      r.register Verb::Definition.new(
        "issues.export-md", "Export issues (Markdown)…", "Write all issues to a Markdown file (asks for the path)",
        Verb::Scope::Global, [] of Verb::Chord) { |ctx| ctx.issues_export(:markdown); nil }

      r.register Verb::Definition.new(
        "issues.export-json", "Export issues (JSON)…", "Write all issues to a JSON file (asks for the path)",
        Verb::Scope::Global, [] of Verb::Chord) { |ctx| ctx.issues_export(:json); nil }

      # The discoverable export key on the Issues tab (the verbs above are the palette
      # entries / both formats); defaults to the human-readable Markdown report. NON-hidden
      # so it joins the Issues list's "space" menu.
      #
      # ⇧E, not 'x', and it MATCHES notes.export's mnemonic on purpose. 'x' means "Select
      # line" everywhere else in the app — all nine read-mode scopes in read_edit.cr, the
      # Issues DETAIL one ↵ away included. So the list's 'x' was the odd one out, and it
      # collided with its own tab's detail view. Sharing 'E' with Notes makes export one key
      # across tabs and leaves x = Select line exception-free.
      #
      # The chord is Chord.new("e", shift: true), NOT Chord.new("E"): Keybind.from_event
      # normalises a typed capital to shift + lowercase, so an "E" chord would never fire.
      # menu_key skips shift chords, hence the explicit mnemonic — the same pairing
      # notes.send-to uses for 'S'.
      r.register Verb::Definition.new(
        "issues.export-key", "Export issues (Markdown)…", "Write the Markdown report to a file (asks for the path)",
        Verb::Scope::Issues, [Verb::Chord.new("e", shift: true)],
        mnemonic: 'E') { |ctx| ctx.issues_export(:markdown); nil }
    end
  end
end
