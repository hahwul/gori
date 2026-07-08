require "../verb"

module Gori
  module Verbs
    def self.register_findings(r : Verb::Registry) : Nil
      # create from History (selected flow)
      r.register Verb::Definition.new(
        "finding.create", "Add finding", "Create a finding from the selected flow", Verb::Scope::Body,
        [Verb::Chord.new("f", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }, mnemonic: 'a') { |ctx| ctx.finding_create; nil }

      # findings list
      r.register Verb::Definition.new(
        "findings.down", "Select next finding", "Move down", Verb::Scope::Findings,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.findings_move(1); nil }

      r.register Verb::Definition.new(
        "findings.up", "Select previous finding", "Move up", Verb::Scope::Findings,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.findings_move(-1); nil }

      # open/delete are NON-hidden so they join New in the Findings list's "space" menu
      # (the palette stays Global-only, so this doesn't leak there). open carries an
      # explicit 'o' mnemonic — its primary chord is enter/l, which would otherwise
      # front the menu with the unintuitive 'l'.
      r.register Verb::Definition.new(
        "findings.open", "Open finding", "View/edit the selected finding", Verb::Scope::Findings,
        [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")], mnemonic: 'o') { |ctx| ctx.findings_open; nil }

      r.register Verb::Definition.new(
        "findings.filter", "Filter findings", "Filter the list (severity:/status:/host:/free text)",
        Verb::Scope::Findings, [Verb::Chord.new("/")]) { |ctx| ctx.findings_query; nil }

      r.register Verb::Definition.new(
        "findings.new", "New finding", "Create a blank finding", Verb::Scope::Findings,
        [Verb::Chord.new("n")]) { |ctx| ctx.findings_new; nil }

      r.register Verb::Definition.new(
        "findings.delete", "Delete finding", "Delete the selected finding", Verb::Scope::Findings,
        [Verb::Chord.new("d")]) { |ctx| ctx.findings_delete; nil }

      r.register Verb::Definition.new(
        "findings.leave", "Back to menu", "Return focus to the tab menu", Verb::Scope::Findings,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil } # esc only; ← was a tab-bar overshoot

      # finding detail
      r.register Verb::Definition.new(
        "finding.close", "Back to list", "Return to the findings list", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.finding_close; nil }

      # Severity/status edits live on the Space menu (a colour picker) so arrows
      # never change them by accident. The bracket/brace chords stay as hidden
      # power-shortcuts (one-step cycling); the pickers are the discoverable path.
      r.register Verb::Definition.new(
        "finding.set-severity", "Set severity", "Pick this finding's severity",
        Verb::Scope::FindingsDetail, [] of Verb::Chord, mnemonic: 's') { |ctx| ctx.finding_set_severity; nil }

      r.register Verb::Definition.new(
        "finding.set-status", "Set status", "Pick this finding's triage status",
        Verb::Scope::FindingsDetail, [] of Verb::Chord, mnemonic: 'c') { |ctx| ctx.finding_set_status; nil }

      r.register Verb::Definition.new(
        "finding.severity-up", "Raise severity", "Increase severity", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("]")], hidden: true) { |ctx| ctx.finding_severity(1); nil }

      r.register Verb::Definition.new(
        "finding.severity-down", "Lower severity", "Decrease severity", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("[")], hidden: true) { |ctx| ctx.finding_severity(-1); nil }

      # edit-notes/edit-title/open-flow/replay-flow/delete are NON-hidden so they front
      # the finding-detail "space" action menu (parity with the History detail; the
      # palette stays Global-only, so this doesn't leak there). Each menu key derives
      # from its plain chord — the key you'd press directly. severity/status keep their
      # bracket chords ([ ] { }) hidden (awkward as menu mnemonics; discoverable in Help).
      # The single smart Copy (see replay.copy in verbs/history.cr) — copy-all is gone.
      in_findings_notes_read = ->(ctx : Verb::ExecContext) { ctx.findings_notes_read_mode? }

      r.register Verb::Definition.new(
        "finding.copy", "Copy", "Copy the selected notes text, or the whole notes if nothing is selected, to the clipboard",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("y")],
        available: in_findings_notes_read, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      r.register Verb::Definition.new(
        "finding.edit-notes", "Edit notes", "Edit the finding notes inline (i/↵/e)", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("e")]) { |ctx| ctx.finding_edit_notes; nil }

      # Shift+←/→ scroll a long notes line sideways. `finding.close` (registered
      # above) owns plain ← — a distinct chord (shift: true), so no collision.
      r.register Verb::Definition.new(
        "finding.hscroll-right", "Scroll notes right", "Scroll a long notes line right", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("right", shift: true)], hidden: true) { |ctx| ctx.finding_hscroll(1); nil }

      r.register Verb::Definition.new(
        "finding.hscroll-left", "Scroll notes left", "Scroll a long notes line left", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("left", shift: true)], hidden: true) { |ctx| ctx.finding_hscroll(-1); nil }

      r.register Verb::Definition.new(
        "finding.delete", "Delete finding", "Delete this finding", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("d")]) { |ctx| ctx.findings_delete; nil }

      r.register Verb::Definition.new(
        "finding.status-up", "Advance status", "Cycle triage status forward (open→confirmed→fp→resolved)",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("}")], hidden: true) { |ctx| ctx.finding_status(1); nil }

      r.register Verb::Definition.new(
        "finding.status-down", "Revert status", "Cycle triage status backward", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("{")], hidden: true) { |ctx| ctx.finding_status(-1); nil }

      r.register Verb::Definition.new(
        "finding.edit-title", "Edit title/severity", "Rename the finding and set its severity",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("t")]) { |ctx| ctx.finding_edit_title; nil }

      r.register Verb::Definition.new(
        "finding.open-flow", "Open evidence", "Open the linked flow's request/response in History",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("o")]) { |ctx| ctx.finding_open_flow; nil }

      r.register Verb::Definition.new(
        "finding.replay-flow", "Replay evidence", "Send the linked flow to the Replay tab",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("r")]) { |ctx| ctx.finding_replay_flow; nil }

      r.register Verb::Definition.new(
        "finding.links", "Manage links", "View/add/remove related History/Replay/Fuzzer/Miner URLs",
        Verb::Scope::FindingsDetail, mnemonic: 'l') { |ctx| ctx.finding_links; nil }

      r.register Verb::Definition.new(
        "finding.open-link", "Open linked item", "Open the selected related URL in its tab",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("enter")], hidden: true) { |ctx| ctx.finding_open_link; nil }

      r.register Verb::Definition.new(
        "finding.link-down", "Next related link", "Select the next related item",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.finding_link_move(1); nil }

      r.register Verb::Definition.new(
        "finding.link-up", "Previous related link", "Select the previous related item",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.finding_link_move(-1); nil }

      # Export (palette/Global — the findings' way out): write a report to the project dir.
      r.register Verb::Definition.new(
        "findings.export-md", "Export findings (Markdown)", "Write all findings to findings.md in the project dir",
        Verb::Scope::Global, [] of Verb::Chord) { |ctx| ctx.findings_export(:markdown); nil }

      r.register Verb::Definition.new(
        "findings.export-json", "Export findings (JSON)", "Write all findings to findings.json in the project dir",
        Verb::Scope::Global, [] of Verb::Chord) { |ctx| ctx.findings_export(:json); nil }

      # The discoverable 'x' export chord on the Findings tab (the verbs above are the
      # palette entries / both formats). Findings-scoped so 'x' doesn't collide with
      # the hex toggles elsewhere; defaults to the human-readable Markdown report.
      # NON-hidden so it joins the Findings list's "space" menu (key derives from 'x').
      r.register Verb::Definition.new(
        "findings.export-key", "Export findings (Markdown)", "Write the Markdown report to the project dir",
        Verb::Scope::Findings, [Verb::Chord.new("x")]) { |ctx| ctx.findings_export(:markdown); nil }
    end
  end
end
