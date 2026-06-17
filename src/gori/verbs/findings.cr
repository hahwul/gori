require "../verb"

module Gori
  module Verbs
    def self.register_findings(r : Verb::Registry) : Nil
      # create from History (selected flow)
      r.register Verb::Definition.new(
        "finding.create", "Add finding", "Create a finding from the selected flow", Verb::Scope::Body,
        [Verb::Chord.new("f", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }) { |ctx| ctx.finding_create; nil }

      # findings list
      r.register Verb::Definition.new(
        "findings.down", "Select next finding", "Move down", Verb::Scope::Findings,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.findings_move(1); nil }

      r.register Verb::Definition.new(
        "findings.up", "Select previous finding", "Move up", Verb::Scope::Findings,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.findings_move(-1); nil }

      r.register Verb::Definition.new(
        "findings.open", "Open finding", "View/edit the selected finding", Verb::Scope::Findings,
        [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")], hidden: true) { |ctx| ctx.findings_open; nil }

      r.register Verb::Definition.new(
        "findings.new", "New finding", "Create a blank finding", Verb::Scope::Findings,
        [Verb::Chord.new("n")]) { |ctx| ctx.findings_new; nil }

      r.register Verb::Definition.new(
        "findings.delete", "Delete finding", "Delete the selected finding", Verb::Scope::Findings,
        [Verb::Chord.new("d")], hidden: true) { |ctx| ctx.findings_delete; nil }

      r.register Verb::Definition.new(
        "findings.leave", "Back to menu", "Return focus to the tab menu", Verb::Scope::Findings,
        [Verb::Chord.new("left"), Verb::Chord.new("h"), Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }

      # finding detail
      r.register Verb::Definition.new(
        "finding.close", "Back to list", "Return to the findings list", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.finding_close; nil }

      r.register Verb::Definition.new(
        "finding.severity-up", "Raise severity", "Increase severity", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("]"), Verb::Chord.new("right")], hidden: true) { |ctx| ctx.finding_severity(1); nil }

      r.register Verb::Definition.new(
        "finding.severity-down", "Lower severity", "Decrease severity", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("["), Verb::Chord.new("left")], hidden: true) { |ctx| ctx.finding_severity(-1); nil }

      r.register Verb::Definition.new(
        "finding.edit-notes", "Edit notes", "Edit the finding notes inline", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("e"), Verb::Chord.new("enter")], hidden: true) { |ctx| ctx.finding_edit_notes; nil }

      r.register Verb::Definition.new(
        "finding.delete", "Delete finding", "Delete this finding", Verb::Scope::FindingsDetail,
        [Verb::Chord.new("d")], hidden: true) { |ctx| ctx.findings_delete; nil }
    end
  end
end
