require "../store"
require "./compare"
require "./keys"
require "./snapshot"

module Gori::Diff
  # What one side of the diff actually looked at. Printed BESIDE every count, because a
  # count alone cannot separate "this endpoint is gone" from "we did not go there this
  # time" — and a retest report that presents the second as the first is worse than no
  # report (`memory: absence-of-finding-reads-as-clean`).
  record Coverage,
    label : String,
    db_path : String,
    flows : Int64,
    endpoints : Int32,
    hosts : Int32,
    first_seen : Int64?,
    last_seen : Int64?,
    scope_enabled : Bool,
    scope_rules : Array(String),
    truncated : Bool do
    def self.of(snap : Snapshot, endpoints : Int32) : Coverage
      new(snap.label, snap.db_path, snap.flows, endpoints, snap.hosts,
        snap.first_seen, snap.last_seen, snap.scope_enabled?, snap.scope_rules, snap.truncated?)
    end
  end

  # A previously-filed issue, re-asked against side B — WITHOUT sending anything. The
  # answer is "does the endpoint this issue was filed against still exist, and does it
  # still answer the same way", not "does the bug still reproduce": confirming a
  # vulnerability needs a request, and that is the operator's call through Repeater.
  record IssueRetest,
    id : Int64,
    title : String,
    severity : Store::Severity,
    status : Store::Status,
    key : Key?,
    verdict : Verdict?,
    changes : Array(Change),
    note : String

  # The finished comparison: both sides' coverage, the endpoint rows, and the issue
  # retest. Rendering lives in `Diff::Render`.
  class Report
    getter a : Coverage
    getter b : Coverage
    getter rows : Array(Row)
    getter issues : Array(IssueRetest)
    # Live issues the retest walk did NOT reach, because it hit `ISSUE_RETEST_MAX`. Zero
    # whenever the walk was complete (and whenever the retest was switched off entirely).
    # Reported, never silent: the endpoint read says when its own cut happened, and an
    # issue axis that quietly dropped its tail would be the same lie on the other half of
    # the report.
    getter issues_dropped : Int32

    def initialize(@a, @b, @rows, @issues, @issues_dropped = 0)
    end

    def counts : Hash(Verdict, Int32)
      out = {} of Verdict => Int32
      Verdict.values.each { |v| out[v] = 0 }
      @rows.each { |r| out[r.verdict] += 1 }
      out
    end

    def rows_of(verdict : Verdict) : Array(Row)
      @rows.select { |r| r.verdict == verdict }
    end

    # The two projects recorded under different scope settings, so an endpoint may be
    # missing from one side simply because that side's proxy was not recording it.
    #
    # The ENABLED flag is half the setting and was the half that mattered: identical rules
    # with the lens ON on one side and OFF on the other is exactly the "that side captured
    # everything, this one captured a subset" case the caveat exists for, and comparing the
    # rule text alone called that a match. The rule list is compared SORTED because it comes
    # straight off `Scope.load` in row order — two projects holding the same rules entered in
    # a different order are not a mismatch.
    def scope_mismatch? : Bool
      @a.scope_enabled != @b.scope_enabled || @a.scope_rules.sort != @b.scope_rules.sort
    end

    # The one sentence the counts must never be read without.
    def coverage_note : String
      "'removed' means B captured no request to the endpoint at all — that is a coverage " \
      "gap, not evidence of removal; 'gone' is the confirmed case (B asked and got 404/410)."
    end

    # Everything about this run that qualifies the numbers, in the order it should be read.
    def caveats : Array(String)
      out = [] of String
      out << coverage_note
      if @a.truncated || @b.truncated
        sides = [] of String
        sides << @a.label if @a.truncated
        sides << @b.label if @b.truncated
        subject = sides.size == 1 ? "that side's endpoint set is a PREFIX" : "those sides' endpoint sets are PREFIXES"
        out << "endpoint read hit its cap on #{sides.join(" and ")} — #{subject} of the " \
               "project, so every verdict below is partial."
      end
      out << "scope rules differ between the two projects (#{scope_line(@a)} vs #{scope_line(@b)}) " \
             "— an endpoint may be absent because that side never recorded it." if scope_mismatch?
      if @issues_dropped > 0
        out << "issue retest stopped at #{@issues.size} issues — #{@issues_dropped} more live " \
               "#{@issues_dropped == 1 ? "issue was" : "issues were"} not re-asked."
      end
      out
    end

    private def scope_line(c : Coverage) : String
      return "no scope rules" if c.scope_rules.empty?
      state = c.scope_enabled ? "on" : "off"
      "#{c.scope_rules.size} rule#{c.scope_rules.size == 1 ? "" : "s"} (#{state})"
    end
  end

  # Run the whole comparison over two OPEN stores. Neither store is closed here — the
  # caller owns both, and the read is one grouped query per side plus the issue walk.
  #
  # `issue_limit` caps the issue retest (0 disables it).
  def self.run(store_a : Store, store_b : Store, *,
               label_a : String, label_b : String,
               path_a : String, path_b : String,
               filter : QL::Filter = QL::EMPTY,
               limit : Int32 = Store::ENDPOINT_OBSERVATION_MAX,
               in_scope : Bool = false,
               issue_limit : Int32 = ISSUE_RETEST_MAX,
               raise_on_error : Bool = false) : Report
    snap_a = Snapshot.read(store_a, label_a, path_a, filter: filter, limit: limit,
      in_scope: in_scope, raise_on_error: raise_on_error)
    snap_b = Snapshot.read(store_b, label_b, path_b, filter: filter, limit: limit,
      in_scope: in_scope, raise_on_error: raise_on_error)
    compare(store_a, snap_a, snap_b, issue_limit: issue_limit)
  end

  # The pure half of `run` — two already-read snapshots in, a report out. `store_a` is
  # still needed for the issue walk (an issue's linked flow lives on the A side).
  def self.compare(store_a : Store?, snap_a : Snapshot, snap_b : Snapshot, *,
                   issue_limit : Int32 = ISSUE_RETEST_MAX) : Report
    # ONE fold tree over both sides — see `Templates`, which explains why folding each
    # side alone would manufacture added/removed pairs out of the fold thresholds.
    templates = Templates.new(snap_a.entries + snap_b.entries)
    a_facts = snap_a.facts(templates)
    b_facts = snap_b.facts(templates)
    rows = Compare.rows(a_facts, b_facts)
    issues, dropped =
      if (store = store_a) && issue_limit > 0
        retest_issues(store, templates, rows, issue_limit)
      else
        {[] of IssueRetest, 0}
      end
    Report.new(Coverage.of(snap_a, a_facts.size), Coverage.of(snap_b, b_facts.size), rows, issues, dropped)
  end

  # How many issues the retest walk will RESOLVE. Each one costs a `list_links` plus one
  # `flow_row` per linked flow, so the cap bounds the round trips a diff spends on the issue
  # axis — not the table read, which `Store#issues` does in full either way. What the cap
  # leaves out is counted and reported (`Report#issues_dropped`).
  ISSUE_RETEST_MAX = 500

  # Re-ask each of A's issues against the diff, plus how many live issues the cap left
  # unasked. Only issues that are still LIVE (open or confirmed) are worth retesting — a
  # resolved or false-positive issue is not a question about this engagement.
  private def self.retest_issues(store : Store, templates : Templates, rows : Array(Row),
                                 limit : Int32) : {Array(IssueRetest), Int32}
    by_key = {} of Key => Row
    rows.each { |r| by_key[r.key] = r }
    out = [] of IssueRetest
    dropped = 0
    store.issues.each do |issue|
      next unless issue.status.open? || issue.status.confirmed?
      if out.size >= limit
        dropped += 1
        next
      end
      out << retest_issue(store, templates, by_key, issue)
    end
    {out, dropped}
  end

  private def self.retest_issue(store : Store, templates : Templates, by_key : Hash(Key, Row),
                                issue : Store::Issue) : IssueRetest
    none = [] of Change
    key, row = issue_row(store, templates, by_key, issue)
    return IssueRetest.new(issue.id, issue.title, issue.severity, issue.status,
      key, row.verdict, row.changes, issue_note(row)) if row
    # A key with no row is a DIFFERENT fact from no key at all, and reporting them alike is
    # the mistake this feature exists to avoid: the evidence pointer is intact, the endpoint
    # simply fell outside what this run compared (a `--query`/`--in-scope` narrowing, or past
    # the endpoint cap). Saying "no linked capture" there tells the operator their link is
    # broken when it is not.
    note = key ? "linked capture is outside this diff — widen the query, or drop --in-scope" \
                  : "no linked capture — nothing to key this issue on"
    IssueRetest.new(issue.id, issue.title, issue.severity, issue.status, key, nil, none, note)
  end

  # {the endpoint key the issue's linked capture lands on, the diff row for it}. Either may
  # be nil, and they mean different things: no KEY = no resolvable linked flow (never
  # attached, or the flow was deleted); a key with no ROW = the endpoint exists but this
  # diff did not cover it.
  private def self.issue_row(store : Store, templates : Templates, by_key : Hash(Key, Row),
                             issue : Store::Issue) : {Key?, Row?}
    ids = [] of Int64
    if primary = issue.flow_id
      ids << primary
    end
    store.list_links(Store::LinkOwnerKind::Issue, issue.id).each do |l|
      ids << l.ref_id if l.ref_kind.flow? && !ids.includes?(l.ref_id)
    end
    first_key = nil.as(Key?)
    ids.each do |fid|
      flow = store.flow_row(fid) || next
      key = templates.key(flow.host, flow.method, flow.target)
      first_key ||= key
      if row = by_key[key]?
        return {key, row}
      end
    end
    {first_key, nil}
  end

  private def self.issue_note(row : Row) : String
    case row.verdict
    in .added?     then "the endpoint appears only in the newer capture"
    in .removed?   then "the endpoint was not requested in the newer capture — retest it before closing"
    in .gone?      then "the endpoint answers 404/410 now"
    in .changed?   then "the endpoint answers differently: #{row.changes.join("; ")}"
    in .unchanged? then "the endpoint still answers the same way — the finding likely still stands"
    end
  end
end
