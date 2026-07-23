require "json"
require "../../ql"
require "../../scope"
require "../../probe"

module Gori
  module MCP
    class Tools
      # Active mode sends real requests per flow inline (unlike the async fuzz/mine jobs),
      # so cap how many flows an active scan touches. Passive mode is request-free and uncapped.
      PROBE_ACTIVE_MAX_FLOWS = 500

      # probe_scan — the MCP surface for the Prism scanner (parity with `gori run probe`).
      # PASSIVE by default (zero outbound requests): scans captured History flows (optional
      # QL filter) + Repeater tabs and returns grouped issues. active:true also runs the
      # light-touch active checks that SEND requests — gated on write access AND project scope
      # (same two-layer model as the CLI/TUI: an include-filter per flow + Fuzz::ScopedBackend).
      private def probe_scan(h) : Result
        filter = probe_scan_filter(h)
        return filter if filter.is_a?(Result)

        if e = bad_severity(str(h, "severity"))
          return e
        end
        category = probe_scan_category(h)
        return category if category.is_a?(Result)

        active = bool(h, "active") || false
        allow_unscoped = bool(h, "allow_unscoped") || false
        gate = probe_active_gate(active, allow_unscoped)
        return gate if gate.is_a?(Result)
        scope, scope_configured = gate

        ids = Probe::Scan.flow_ids(store, filter)
        capped = active && ids.size > PROBE_ACTIVE_MAX_FLOWS
        ids = ids[0, PROBE_ACTIVE_MAX_FLOWS] if capped
        dets, repeater_n = Probe::Scan.scan_all(store, ids, active: active, verify_upstream: @verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped)

        groups = probe_filter_groups(Probe.group(dets), severity_from(str(h, "severity")), category.as(String?))
        Result.new(probe_scan_json(groups, ids.size, repeater_n, active, allow_unscoped,
          scope_configured, capped, clamp(int(h, "limit"), 200, 2000)))
      end

      # The QL filter (History only; blank/absent → nil = scan all), or a QUERY_SYNTAX Result.
      private def probe_scan_filter(h) : QL::Filter? | Result
        query = str(h, "query").try(&.strip).presence
        return nil unless query
        ql_filter_or_error(h, query)
      end

      # The validated category slug (or nil), or an INVALID_ARGUMENT Result.
      private def probe_scan_category(h) : String? | Result
        category = str(h, "category").try(&.strip.downcase).presence
        return nil unless category
        return category if Probe::SCAN_CATEGORIES.includes?(category)
        err("invalid category '#{category}' (#{Probe::SCAN_CATEGORIES.join("|")})", "INVALID_ARGUMENT", field: "category")
      end

      # Resolve the scope for an active scan: {scope, scope_configured}. Passive → {nil, false}.
      # Refuses (Result) an active run without write access, or with no configured scope unless
      # allow_unscoped — every captured host would otherwise be probed.
      private def probe_active_gate(active : Bool, allow_unscoped : Bool) : {Scope?, Bool} | Result
        return {nil, false} unless active
        return err("active probe scan is disabled (gori mcp --read-only); pass active:false for a passive scan", "TOOL_DISABLED") unless @allow_actions
        scope = Scope.load(store)
        configured = scope.configured?
        if !configured && !allow_unscoped
          return err("active probe scan needs a configured scope (or allow_unscoped:true); no scope is configured, so outbound probe requests are refused by default",
            "SCOPE_BLOCKED", field: "active", details: JSON.parse({"scope_decision" => "unscoped"}.to_json))
        end
        {scope, configured}
      end

      private def probe_filter_groups(groups : Array(Probe::Group), min_sev : Store::Severity?,
                                      category : String?) : Array(Probe::Group)
        groups = groups.select { |g| g.severity.value >= min_sev.value } if min_sev
        groups = groups.select { |g| g.category == category } if category
        groups
      end

      private def probe_scan_json(groups : Array(Probe::Group), flows_scanned : Int32, repeater_n : Int32,
                                  active : Bool, allow_unscoped : Bool, scope_configured : Bool,
                                  capped : Bool, limit : Int32) : String
        JSON.build do |j|
          j.object do
            j.field "flows_scanned", flows_scanned
            j.field "repeaters_scanned", repeater_n
            j.field "active", active
            if active
              j.field "scope_configured", scope_configured
              j.field "active_scope_gated", !allow_unscoped # per-flow include-filter applied unless bypassed
              j.field "active_flows_capped", true if capped
            end
            j.field "issue_count", groups.size
            j.field("issues") { j.array { groups.first(limit).each { |g| Probe.group_json(j, g) } } }
            j.field "truncated", true if groups.size > limit
          end
        end
      end
    end
  end
end
