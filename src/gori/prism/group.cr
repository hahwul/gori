require "../store"
require "./issue"

module Gori
  module Prism
    # An in-memory grouping of raw Detections by (code, host) — the headless counterpart of a
    # persisted Store::PrismIssue row. `gori run prism` scans flows passively and reports these
    # WITHOUT writing to the DB, so the folding that `Store#upsert_prism_issue` does in SQL is
    # mirrored here purely (severity rises to the max seen, hit_count counts every observation,
    # affected URLs are de-duplicated and capped, and the first-seen title/category/evidence/
    # flow win). The TUI/capture path still owns the DB rows; this is a read-only audit view.
    struct Group
      getter code : String
      getter category : String
      getter host : String
      getter title : String
      getter severity : Store::Severity
      getter hit_count : Int32        # every observation (may exceed affected.size once capped)
      getter affected : Array(String) # distinct affected URLs, capped at Store::PRISM_AFFECTED_CAP
      getter evidence : String?       # first non-nil short snippet — NEVER a secret value
      getter sample_flow_id : Int64?  # the flow that first triggered this group

      def initialize(@code, @category, @host, @title, @severity, @hit_count, @affected,
                     @evidence, @sample_flow_id)
      end
    end

    # Fold raw Detections into grouped rows keyed by (code, host), matching
    # Store#upsert_prism_issue's merge exactly so a headless scan reads the same as the TUI tab:
    # severity = max, hit_count = count, affected de-duplicated + capped, evidence/title/category/
    # sample_flow = the first-seen non-nil value (COALESCE/INSERT semantics). Returned sorted by
    # severity (desc), then host, then code for a stable, scannable order.
    def self.group(detections : Array(Detection)) : Array(Group)
      cap = Store::PRISM_AFFECTED_CAP
      acc = {} of {String, String} => Group
      detections.each do |d|
        key = {d.code, d.host}
        if g = acc[key]?
          urls = g.affected
          # size check first so a full list short-circuits the O(n) includes? scan.
          urls << d.url if urls.size < cap && !urls.includes?(d.url)
          sev = g.severity.value >= d.severity.value ? g.severity : d.severity
          acc[key] = Group.new(g.code, g.category, g.host, g.title, sev, g.hit_count + 1,
            urls, g.evidence || d.evidence, g.sample_flow_id)
        else
          acc[key] = Group.new(d.code, d.category, d.host, d.title, d.severity, 1,
            [d.url], d.evidence, d.flow_id)
        end
      end
      # Hash#values is insertion order, but the result is fully ordered by the sort below.
      acc.values.sort! do |a, b|
        by_sev = b.severity.value <=> a.severity.value
        next by_sev unless by_sev.zero?
        by_host = a.host <=> b.host
        by_host.zero? ? a.code <=> b.code : by_host
      end
    end
  end
end
