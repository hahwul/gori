require "../store"

module Gori
  module Probe
    # Presentation-free triage actions over PERSISTED Probe issues (the `probe_issues` table
    # the live Analyzer fills), shared by the TUI Probe tab, `gori run probe`, and the MCP
    # probe_* tools. Every surface must reach the same verdicts, so the one non-trivial action
    # — promote — lives here rather than being re-derived per surface.
    #
    # Dismiss/delete/clear are single store calls and stay direct at the call sites; only the
    # multi-step promotion (insert Issue → carry Repeater-only evidence → mark the source
    # Confirmed) needs a shared home.
    module Triage
      extend self

      # Promote a machine-found Probe issue to a human-confirmed Issue (the bridge to the
      # Issues report). Returns the new Issue id, or nil when the source was ALREADY promoted
      # — promotion marks the source Confirmed precisely so a second call cannot mint a
      # duplicate Issue for the same finding.
      def promote(store : Store, issue : Store::ProbeIssue) : Int64?
        return nil if issue.status.confirmed?
        issue_id = store.insert_issue(issue.title, issue.severity, issue.host, issue.sample_flow_id)
        # Preserve Repeater-only evidence: with no source flow, link the Issue to the Repeater
        # tab that produced the finding so the evidence pointer survives promotion (insert_issue
        # only carries a flow id).
        if issue.sample_flow_id.nil? && (rid = issue.sample_repeater_id)
          store.add_link(Store::LinkOwnerKind::Issue, issue_id, Store::LinkRefKind::Repeater, rid)
        end
        # Mark the source confirmed (= "promoted to an Issue") so it leaves the default
        # open-only lens instead of lingering as unreviewed noise; still reachable via "show all".
        store.update_probe_issue_status(issue.id, Store::Status::Confirmed)
        issue_id
      end

      # Toggle a Probe issue between dismissed (false-positive) and open — the one-key triage
      # action. Returns the status it landed on. Note the asymmetry: only an OPEN issue is
      # dismissed; anything else (including a Confirmed/promoted one) re-opens, so this doubles
      # as "un-dismiss" and as "undo a promotion's status change" without a second verb.
      def toggle_dismiss(store : Store, issue : Store::ProbeIssue) : Store::Status
        landed = issue.status.open? ? Store::Status::FalsePositive : Store::Status::Open
        store.update_probe_issue_status(issue.id, landed)
        landed
      end
    end
  end
end
