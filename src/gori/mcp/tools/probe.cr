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
        # --aggressive implies unsafe (it also raises caps + widens bypass sets).
        aggressive = bool(h, "aggressive") || false
        unsafe = (bool(h, "unsafe") || false) || aggressive
        gate = probe_active_gate(active, allow_unscoped)
        return gate if gate.is_a?(Result)
        scope, scope_configured = gate

        opts = Probe::Active::Options.new(allow_unsafe: unsafe, aggressive: aggressive)
        ids = Probe::Scan.flow_ids(store, filter)
        # Cap only the ACTIVE sends (network volume); the request-free PASSIVE scan always
        # covers every flow. (An earlier version truncated `ids`, which silently dropped
        # passive coverage of the newest flows under active:true.)
        capped = active && ids.size > PROBE_ACTIVE_MAX_FLOWS
        dets, repeater_n = Probe::Scan.scan_all(store, ids, active: active, verify_upstream: @verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, opts: opts, active_limit: active ? PROBE_ACTIVE_MAX_FLOWS : nil)

        groups = probe_filter_groups(Probe.group(dets), severity_from(str(h, "severity")), category.as(String?))
        Result.new(probe_scan_json(groups, ids.size, repeater_n, active, allow_unscoped,
          scope_configured, capped, unsafe, aggressive, clamp(int(h, "limit"), 200, 2000)))
      end

      # --- persisted probe issues + triage (parity with the TUI Probe tab) -------------------
      #
      # probe_scan is a STATELESS rescan; these read and mutate the `probe_issues` table the
      # live Analyzer fills — the same rows a human triages in the TUI. Without them an agent
      # could produce findings (probe_scan, send_request) but never dismiss or promote one.

      # probe_issues — list persisted findings. Defaults to OPEN only, mirroring the TUI's
      # default open-only lens; include_closed:true is the `a` toggle.
      private def probe_issues(h) : Result
        if e = bad_severity(str(h, "severity"))
          return e
        end
        category = probe_scan_category(h)
        return category if category.is_a?(Result)

        include_closed = bool(h, "include_closed") || false
        all = store.probe_issues(category.as(String?), str(h, "host").try(&.strip).presence,
          severity_from(str(h, "severity")))
        all = all.select(&.status.open?) unless include_closed

        req_off = int(h, "offset")
        req_lim = int(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 100, 500)
        page = all[offset, limit]? || [] of Store::ProbeIssue
        Result.new(JSON.build do |j|
          j.object do
            j.field("issues") { j.array { page.each { |i| Probe.issue_json(j, i) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total", all.size
            j.field "has_more", offset + page.size < all.size
            j.field "include_closed", include_closed
          end
        end)
      end

      # probe_dismiss — mute a finding. Either one `id` (toggles dismissed ⇄ open, same rule as
      # the TUI's `c`), or a bulk `code`/`host` mute of every OPEN issue sharing it.
      private def probe_dismiss(h) : Result
        code = str(h, "code").try(&.strip).presence
        host = str(h, "host").try(&.strip).presence
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if id.nil? && present?(h, "id")

        selectors = [id, code, host].count { |v| !v.nil? }
        if selectors != 1
          return err("pass exactly one of 'id' (single issue), 'code' (bulk by check code), or 'host' (bulk by host)",
            "INVALID_ARGUMENT", field: "id")
        end

        if code
          n = store.probe_issues.count { |i| i.code == code && i.status.open? }
          store.dismiss_probe_by_code(code)
          return Result.new({"dismissed" => n, "code" => code}.to_json)
        end
        if host
          n = store.probe_issues.count { |i| i.host == host && i.status.open? }
          store.dismiss_probe_by_host(host)
          return Result.new({"dismissed" => n, "host" => host}.to_json)
        end

        # The selector count above guarantees `id` is the one that was given.
        return err("pass exactly one of 'id', 'code', or 'host'", "INVALID_ARGUMENT", field: "id") unless id
        issue = store.get_probe_issue(id)
        return not_found("no probe issue with id #{id}") unless issue
        landed = Probe::Triage.toggle_dismiss(store, issue)
        Result.new({"id" => issue.id, "status" => landed.label}.to_json)
      end

      # probe_promote — turn a machine finding into a human-confirmed Issue (the Issues report).
      private def probe_promote(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        issue = store.get_probe_issue(id)
        return not_found("no probe issue with id #{id}") unless issue
        issue_id = Probe::Triage.promote(store, issue)
        unless issue_id
          # Already Confirmed = already promoted. Not an error (the desired end state holds),
          # but say so rather than reporting a promotion that did not happen.
          return Result.new({"id" => issue.id, "promoted" => false,
                             "reason" => "already promoted to an issue"}.to_json)
        end
        Result.new({"id" => issue.id, "promoted" => true, "issue_id" => issue_id}.to_json)
      end

      # probe_delete — hard-delete one finding, or clear them all. A delete also SUPPRESSES the
      # (code, host) pair so the next scan does not immediately re-add it (Store's own rule).
      private def probe_delete(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if id.nil? && present?(h, "id")
        if bool(h, "all")
          n = store.count_probe_issues
          store.clear_probe_issues
          return Result.new({"deleted" => n, "all" => true}.to_json)
        end
        return err("pass 'id' (one finding) or all:true (clear every finding)", "INVALID_ARGUMENT", field: "id") unless id
        issue = store.get_probe_issue(id)
        return not_found("no probe issue with id #{id}") unless issue
        store.delete_probe_issue(id)
        Result.new({"deleted" => 1, "id" => id}.to_json)
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
        # Layer-1 (matches_url?) sends an active probe only to a scope-INCLUDED flow, so with
        # zero include rules every flow is gated out and active mode would run nothing. Refuse
        # up front (mirrors `gori run probe`'s include-count check) — an excludes-only scope
        # counts as "no includes" here, not as a configured allowlist.
        if scope.include_count == 0 && !allow_unscoped
          return err("active probe scan needs a scope INCLUDE rule (or allow_unscoped:true); with no include rule every active probe is gated out, so outbound requests are refused by default",
            "SCOPE_BLOCKED", field: "active", details: JSON.parse({"scope_decision" => "unscoped"}.to_json))
        end
        {scope, scope.configured?}
      end

      private def probe_filter_groups(groups : Array(Probe::Group), min_sev : Store::Severity?,
                                      category : String?) : Array(Probe::Group)
        groups = groups.select { |g| g.severity.value >= min_sev.value } if min_sev
        groups = groups.select { |g| g.category == category } if category
        groups
      end

      private def probe_scan_json(groups : Array(Probe::Group), flows_scanned : Int32, repeater_n : Int32,
                                  active : Bool, allow_unscoped : Bool, scope_configured : Bool,
                                  capped : Bool, unsafe : Bool, aggressive : Bool, limit : Int32) : String
        JSON.build do |j|
          j.object do
            j.field "flows_scanned", flows_scanned
            j.field "repeaters_scanned", repeater_n
            j.field "active", active
            if active
              j.field "scope_configured", scope_configured
              j.field "active_scope_gated", !allow_unscoped # per-flow include-filter applied unless bypassed
              j.field "active_flows_capped", true if capped
              j.field "active_unsafe_methods", true if unsafe # POST/PUT/PATCH/DELETE re-sent
              j.field "active_aggressive", true if aggressive # raised caps + wider bypass sets
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
