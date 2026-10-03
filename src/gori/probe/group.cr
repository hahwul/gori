require "json"
require "../store"
require "./issue"

module Gori
  module Probe
    # An in-memory grouping of raw Detections by (code, host) — the headless counterpart of a
    # persisted Store::ProbeIssue row. `gori run probe` scans flows passively and reports these
    # WITHOUT writing to the DB, so the folding that `Store#upsert_probe_issue` does in SQL is
    # mirrored here purely (severity rises to the max seen, hit_count counts every observation,
    # affected URLs are de-duplicated and capped, and the first-seen title/category/evidence/
    # flow win). The TUI/capture path still owns the DB rows; this is a read-only audit view.
    struct Group
      getter code : String
      getter category : String
      getter host : String
      getter title : String
      getter severity : Store::Severity
      getter hit_count : Int32           # every observation (may exceed affected.size once capped)
      getter affected : Array(String)    # distinct affected URLs, capped at Store::PROBE_AFFECTED_CAP
      getter evidence : String?          # first non-nil short snippet — NEVER a secret value
      getter sample_flow_id : Int64?     # the flow that first triggered this group
      getter sample_repeater_id : Int64? # Repeater tab that first triggered this group (when no flow)

      def initialize(@code, @category, @host, @title, @severity, @hit_count, @affected,
                     @evidence, @sample_flow_id, @sample_repeater_id = nil)
      end
    end

    # Fold raw Detections into grouped rows keyed by (code, host), matching
    # Store#upsert_probe_issue's merge exactly so a headless scan reads the same as the TUI tab:
    # severity = max, hit_count = count, affected de-duplicated + capped, evidence/title/category/
    # sample_flow = the first-seen non-nil value (COALESCE/INSERT semantics). Returned sorted by
    # severity (desc), then host, then code for a stable, scannable order.
    def self.group(detections : Array(Detection)) : Array(Group)
      cap = Store::PROBE_AFFECTED_CAP
      acc = {} of {String, String} => Group
      detections.each do |d|
        key = {d.code, d.host}
        if g = acc[key]?
          urls = g.affected
          # size check first so a full list short-circuits the O(n) includes? scan.
          urls << d.url if urls.size < cap && !urls.includes?(d.url)
          sev = g.severity.value >= d.severity.value ? g.severity : d.severity
          # Title tracks the highest-severity observation (mirrors Store#upsert_probe_issue):
          # adopt the incoming title only when it RAISES severity, so an escalated group never
          # shows a lower-severity title (reflected_param: non-HTML Low vs HTML Medium). A
          # fixed-title code is unaffected.
          title = d.severity.value > g.severity.value ? d.title : g.title
          # Type-labeled codes accumulate every distinct label seen (so a host leaking several
          # secret/error types, or shipping several unflagged cookies, surfaces them all);
          # others keep the first representative sample. Both the decision and the merge come
          # from Store so this in-memory fold and the SQL upsert CANNOT drift — they did once,
          # when missing_sri/jwt_sensitive_claims were added to Store's list and not to a copy
          # that used to live here, which made a headless scan report one third-party host.
          evidence = Store.accumulate_evidence?(d.code) ? Store.merge_evidence(g.evidence, d.evidence) : (g.evidence || d.evidence)
          acc[key] = Group.new(g.code, g.category, g.host, title, sev, g.hit_count + 1,
            urls, evidence, g.sample_flow_id, g.sample_repeater_id)
        else
          acc[key] = Group.new(d.code, d.category, d.host, d.title, d.severity, 1,
            [d.url], d.evidence, d.flow_id, d.repeater_id)
        end
      end
      finish_group_sort(acc)
    end

    private def self.finish_group_sort(acc : Hash({String, String}, Group)) : Array(Group)
      # Hash#values is insertion order, but the result is fully ordered by the sort below.
      acc.values.sort! do |a, b|
        by_sev = b.severity.value <=> a.severity.value
        next by_sev unless by_sev.zero?
        by_host = a.host <=> b.host
        by_host.zero? ? a.code <=> b.code : by_host
      end
    end

    # A PERSISTED probe issue (the `probe_issues` row the live Analyzer folds into), as opposed
    # to group_json's stateless scan result. Carries the fields only persistence has: the row id
    # triage acts on, the triage status, and the first/last-seen window.
    def self.issue_json(j : JSON::Builder, i : Store::ProbeIssue) : Nil
      j.object do
        j.field "id", i.id
        j.field "code", i.code
        j.field "category", i.category
        j.field "host", i.host
        j.field "title", i.title
        j.field "severity", i.severity.label
        j.field "status", i.status.label
        j.field "hit_count", i.hit_count
        j.field("affected") { j.array { i.affected.each { |u| j.string(u) } } }
        j.field "affected_count", i.affected.size
        j.field "evidence", i.evidence
        j.field "sample_flow_id", i.sample_flow_id
        j.field "sample_repeater_id", i.sample_repeater_id
        j.field "first_seen", i.first_seen
        j.field "last_seen", i.last_seen
        j.field "remediation", Probe.remediation(i.code)
        cwe_fields(j, i.code)
      end
    end

    # `cwe`/`cwe_name`, emitted only for a code that HAS a mapping. Absent rather than null:
    # tech fingerprints, the informational jwt_in_* notes, and custom rules are unmapped on
    # purpose (see Probe::CWE), and a null would read as "we tried and failed to classify it".
    private def self.cwe_fields(j : JSON::Builder, code : String) : Nil
      return unless entry = Probe.cwe(code)
      id, name = entry
      j.field "cwe", "CWE-#{id}"
      j.field "cwe_name", name
    end

    # The canonical JSON object for one grouped issue — the single source of the field shape
    # shared by `gori run probe --format json` (CLI::Output.probe_array_json builds on it)
    # and the MCP probe_scan tool, so both describe an issue identically.
    def self.group_json(j : JSON::Builder, g : Group) : Nil
      j.object do
        j.field "code", g.code
        j.field "category", g.category
        j.field "host", g.host
        j.field "title", g.title
        j.field "severity", g.severity.label
        j.field "hit_count", g.hit_count
        j.field("affected") { j.array { g.affected.each { |u| j.string(u) } } }
        j.field "affected_count", g.affected.size
        j.field "evidence", g.evidence
        j.field "sample_flow_id", g.sample_flow_id
        j.field "sample_repeater_id", g.sample_repeater_id
        j.field "remediation", Probe.remediation(g.code)
        cwe_fields(j, g.code)
      end
    end
  end
end
