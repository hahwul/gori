require "../store"

module Gori
  module Probe
    # Presentation-free triage actions over PERSISTED Probe issues (the `probe_issues` table
    # the live Analyzer fills), shared by the TUI Probe tab, `gori run probe`, and the MCP
    # probe_* tools. Every surface must reach the same verdicts, so the one non-trivial action
    # — promote — lives here rather than being re-derived per surface.
    #
    # Dismiss/delete/clear are single store calls and stay direct at the call sites; only the
    # multi-step promotion (insert Issue with report notes → link the affected flows / the
    # Repeater-only evidence → mark the source Confirmed) needs a shared home.
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
        issue_id = store.insert_issue(issue.title, issue.severity, issue.host, issue.sample_flow_id,
          notes: report_notes(issue, description_for(store, issue.code)))
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
        # Every other affected URL's captured flow joins the issue as evidence, so the report
        # names each exchange the finding fired on, not only the one sample (#1377). Best
        # effort: the notes already list every URL, so a URL with no captured flow (a Repeater
        # send, a pruned row) or a failed link write costs a pointer, never the promotion.
        refs = affected_flow_ids(store, issue).map { |fid| {Store::LinkRefKind::Flow, fid} }
        store.add_links(Store::LinkOwnerKind::Issue, issue_id, refs)
        # Mark the source confirmed (= "promoted to an Issue") so it leaves the default
        # open-only lens instead of lingering as unreviewed noise; still reachable via "show all".
        store.update_probe_issue_status(issue.id, Store::Status::Confirmed)
        Result.new(Outcome::Promoted, issue_id)
      end

      # The promoted issue's NOTES body: everything the finding knew that the Issue's own
      # columns cannot hold — the rule's text, CWE, detail and every affected URL — so the
      # issue is report-ready without reopening the finding (#1377). Plain text: notes are
      # edited in place and copied verbatim into the Markdown report. `description` is the
      # built-in remediation, or a custom rule's own description (`description_for`).
      def report_notes(issue : Store::ProbeIssue, description : String) : String
        String.build do |io|
          io << "Promoted from Probe finding #" << issue.id << " (" << issue.code << ", "
          io << issue.category << "), seen " << issue.hit_count << "×.\n"
          if id = Probe.cwe_id(issue.code)
            io << '\n' << id
            Probe.cwe_name(issue.code).try { |name| io << ": " << name }
            io << '\n'
          end
          if ev = issue.evidence.presence
            io << "\nDetail: " << ev << '\n'
          end
          unless description.empty?
            io << '\n' << (issue.code.starts_with?("custom_") ? "Description" : "Remediation") << ":\n"
            io << description << '\n'
          end
          unless issue.affected.empty?
            io << "\nAffected URLs (" << issue.affected.size << "):\n"
            issue.affected.each { |url| io << "- " << url << '\n' }
          end
        end.chomp
      end

      # The rule's own words for a finding code: the built-in remediation sentence, or — for a
      # custom rule, which has none — the rule's description (empty once the rule is deleted).
      def description_for(store : Store, code : String) : String
        return Probe.remediation(code) unless code.starts_with?("custom_")
        Probe.custom_rules(store).find(&.code.==(code)).try(&.description) || ""
      end

      # The captured flow behind each affected URL, resolved the way the Probe tab's ↵ resolves
      # one (`Store#flow_id_for_url`, ranked on the sample flow's method), minus the sample flow
      # `insert_issue` already links. Distinct, in the list's order.
      private def affected_flow_ids(store : Store, issue : Store::ProbeIssue) : Array(Int64)
        method = issue.sample_flow_id.try { |fid| store.flow_row(fid).try(&.method) }
        ids = issue.affected.compact_map { |url| store.flow_id_for_url(url, issue.host, method) }.uniq!
        issue.sample_flow_id.try { |fid| ids.delete(fid) }
        ids
      end

      # Toggle a Probe issue between dismissed (false-positive) and open — the one-key triage
      # action. Returns the status it landed on. Note the asymmetry: only an OPEN issue is
      # dismissed; anything else (including a Confirmed/promoted one) re-opens, so this doubles
      # as "un-dismiss" and as "undo a promotion's status change" without a second verb.
      # The status the row is ACTUALLY in afterwards — the issue's own when the write did not
      # commit, not the one that was intended. `promote` right above already takes this care
      # (its comment: "0 is TRUTHY … would report success — permanently blocking any retry");
      # this one returned the intent unconditionally, so MCP `probe_dismiss` and
      # `gori run probe dismiss` told the operator a security finding was muted while it was
      # still Open.
      def toggle_dismiss(store : Store, issue : Store::ProbeIssue) : Store::Status
        landed = issue.status.open? ? Store::Status::FalsePositive : Store::Status::Open
        store.update_probe_issue_status(issue.id, landed) ? landed : issue.status
      end
    end
  end
end
