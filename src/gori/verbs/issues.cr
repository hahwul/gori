require "../verb"

module Gori
  module Verbs
    def self.register_issues(r : Verb::Registry) : Nil
      # create from History (selected flow)
      r.register Verb::Definition.new(
        "issue.create", "Add issue", "Create an issue from the selected flow", Verb::Scope::Body,
        [Verb::Chord.new("f", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }, mnemonic: 'a') { |ctx| ctx.issue_create; nil }

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

      r.register Verb::Definition.new(
        "issues.delete", "Delete issue", "Delete the selected issue", Verb::Scope::Issues,
        [Verb::Chord.new("d")]) { |ctx| ctx.issues_delete; nil }

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

      # Shift+←/→ scroll a long notes line sideways. `issue.close` (registered
      # above) owns plain ← — a distinct chord (shift: true), so no collision.
      r.register Verb::Definition.new(
        "issue.hscroll-right", "Scroll notes right", "Scroll a long notes line right", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("right", shift: true)], hidden: true) { |ctx| ctx.issue_hscroll(1); nil }

      r.register Verb::Definition.new(
        "issue.hscroll-left", "Scroll notes left", "Scroll a long notes line left", Verb::Scope::IssuesDetail,
        [Verb::Chord.new("left", shift: true)], hidden: true) { |ctx| ctx.issue_hscroll(-1); nil }

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

      # Export (palette/Global — the issues' way out): write a report to the project dir.
      r.register Verb::Definition.new(
        "issues.export-md", "Export issues (Markdown)", "Write all issues to issues.md in the project dir",
        Verb::Scope::Global, [] of Verb::Chord) { |ctx| ctx.issues_export(:markdown); nil }

      r.register Verb::Definition.new(
        "issues.export-json", "Export issues (JSON)", "Write all issues to issues.json in the project dir",
        Verb::Scope::Global, [] of Verb::Chord) { |ctx| ctx.issues_export(:json); nil }

      # The discoverable 'x' export chord on the Issues tab (the verbs above are the
      # palette entries / both formats). Issues-scoped so 'x' doesn't collide with
      # the hex toggles elsewhere; defaults to the human-readable Markdown report.
      # NON-hidden so it joins the Issues list's "space" menu (key derives from 'x').
      r.register Verb::Definition.new(
        "issues.export-key", "Export issues (Markdown)", "Write the Markdown report to the project dir",
        Verb::Scope::Issues, [Verb::Chord.new("x")]) { |ctx| ctx.issues_export(:markdown); nil }
    end
  end
end
