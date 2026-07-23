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
        query = str(h, "query").try(&.strip).presence
        filter = nil.as(QL::Filter?)
        if query
          f = ql_filter_or_error(h, query)
          return f if f.is_a?(Result)
          filter = f
        end

        if e = bad_severity(str(h, "severity"))
          return e
        end
        min_sev = severity_from(str(h, "severity"))

        category = str(h, "category").try(&.strip.downcase).presence
        if category && !Probe::SCAN_CATEGORIES.includes?(category)
          return err("invalid category '#{category}' (#{Probe::SCAN_CATEGORIES.join("|")})", "INVALID_ARGUMENT", field: "category")
        end

        active = bool(h, "active") || false
        allow_unscoped = bool(h, "allow_unscoped") || false
        scope = nil.as(Scope?)
        scope_configured = false
        if active
          return err("active probe scan is disabled (gori mcp --read-only); pass active:false for a passive scan", "TOOL_DISABLED") unless @allow_actions
          scope = Scope.load(store)
          scope_configured = scope.configured?
          # An unconfigured scope means every captured host would be probed — refuse the whole
          # active run unless allow_unscoped, mirroring fuzz/mine's SCOPE_BLOCKED default.
          if !scope_configured && !allow_unscoped
            return err("active probe scan needs a configured scope (or allow_unscoped:true); no scope is configured, so outbound probe requests are refused by default",
              "SCOPE_BLOCKED", field: "active", details: JSON.parse({"scope_decision" => "unscoped"}.to_json))
          end
        end

        ids = Probe::Scan.flow_ids(store, filter)
        active_flows_capped = false
        if active && ids.size > PROBE_ACTIVE_MAX_FLOWS
          ids = ids[0, PROBE_ACTIVE_MAX_FLOWS]
          active_flows_capped = true
        end
        dets, repeater_n = Probe::Scan.scan_all(store, ids, active: active, verify_upstream: @verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped)

        groups = Probe.group(dets)
        groups = groups.select { |g| g.severity.value >= min_sev.value } if min_sev
        if cat = category
          groups = groups.select { |g| g.category == cat }
        end
        limit = clamp(int(h, "limit"), 200, 2000)

        Result.new(JSON.build do |j|
          j.object do
            j.field "flows_scanned", ids.size
            j.field "repeaters_scanned", repeater_n
            j.field "active", active
            if active
              j.field "scope_configured", scope_configured
              j.field "active_scope_gated", !allow_unscoped # per-flow include-filter applied unless bypassed
              j.field "active_flows_capped", true if active_flows_capped
            end
            j.field "issue_count", groups.size
            j.field("issues") { j.array { groups.first(limit).each { |g| Probe.group_json(j, g) } } }
            j.field "truncated", true if groups.size > limit
          end
        end)
      end
    end
  end
end
