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

      # Why a promotion did not produce a new Issue. Kept distinct because the two cases need
      # OPPOSITE responses from the operator: AlreadyPromoted is the desired end state and
      # needs no action; Failed means nothing was written and the call should be retried.
      enum Outcome
        Promoted
        AlreadyPromoted
        Failed
      end

      record Result, outcome : Outcome, issue_id : Int64? = nil do
        def promoted? : Bool
          outcome.promoted?
        end
      end

      # Promote a machine-found Probe issue to a human-confirmed Issue (the bridge to the
      # Issues report). Promotion marks the source Confirmed precisely so a second call cannot
      # mint a duplicate Issue for the same finding.
      def promote(store : Store, issue : Store::ProbeIssue) : Result
        return Result.new(Outcome::AlreadyPromoted) if issue.status.confirmed?
        issue_id = store.insert_issue(issue.title, issue.severity, issue.host, issue.sample_flow_id)
        # insert_issue returns 0 — NOT nil — when the write never committed (busy/locked/closing
        # store), and 0 is TRUTHY in Crystal. Without this guard a failed promotion would link
        # evidence to a nonexistent issue #0, mark the source Confirmed anyway, and report
        # success — permanently blocking any retry, since a Confirmed source never promotes again.
        return Result.new(Outcome::Failed) if issue_id == 0
        # Preserve Repeater-only evidence: with no source flow, link the Issue to the Repeater
        # tab that produced the finding so the evidence pointer survives promotion (insert_issue
        # only carries a flow id).
        if issue.sample_flow_id.nil? && (rid = issue.sample_repeater_id)
          store.add_link(Store::LinkOwnerKind::Issue, issue_id, Store::LinkRefKind::Repeater, rid)
        end
        # Mark the source confirmed (= "promoted to an Issue") so it leaves the default
        # open-only lens instead of lingering as unreviewed noise; still reachable via "show all".
        store.update_probe_issue_status(issue.id, Store::Status::Confirmed)
        Result.new(Outcome::Promoted, issue_id)
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
