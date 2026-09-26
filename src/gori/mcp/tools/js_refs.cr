require "json"
require "../../js_refs"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Endpoints referenced in captured JavaScript (#1243) — one read instead of `get_flow` on
      # every bundle plus a regex of the agent's own. Only what a scan stored; reading sends
      # nothing and writes nothing.
      @[Tool("list_js_endpoints")]
      private def list_js_endpoints(h) : Result
        req_off = optional_int_arg(h, "offset")
        req_lim = optional_int_arg(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 200, 2000)
        scope = Scope.load(store)
        in_scope = bool_arg(h, "in_scope", false)
        scope_unconfigured = in_scope && !scope.configured?
        report = if scope_unconfigured
                   JsRefs::ListReport.new([] of JsRefs::Endpoint, 0, false, store.js_scanned_count(JsRefs::VERSION), false)
                 else
                   opts = JsRefs::ListOptions.new(host: str(h, "host"), path_prefix: str(h, "path_prefix"),
                     include_requested: bool_arg(h, "include_requested", false),
                     all_hosts: bool_arg(h, "all_hosts", false), in_scope: in_scope,
                     include_comments: bool_arg(h, "include_comments", true))
                   JsRefs.list(store, opts, scope)
                 end
        rows = report.endpoints
        page = rows[offset, limit]? || [] of JsRefs::Endpoint
        Result.new(JSON.build do |j|
          j.object do
            j.field("endpoints") { j.array { page.each { |e| js_endpoint_row(j, e) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total", rows.size
            j.field "has_more", offset + page.size < rows.size
            j.field "scanned_flows", report.scanned_flows
            j.field "hidden_hosts", report.hidden_hosts
            j.field "requested_unknown", report.requested_unknown
            j.field "truncated", report.capped
            if note = js_list_note(report, scope_unconfigured)
              j.field "note", note
            end
          end
        end)
      end

      private def js_list_note(report : JsRefs::ListReport, scope_unconfigured : Bool) : String?
        if scope_unconfigured
          "in_scope:true but no scope rules are configured — nothing is in scope"
        elsif report.scanned_flows == 0
          "no JavaScript has been scanned in this project yet — call scan_js_endpoints"
        elsif report.hidden_hosts > 0
          "#{report.hidden_hosts} reference(s) to hosts gori never captured are hidden — scope the host, or pass all_hosts:true"
        end
      end

      # Read the not-yet-scanned JS/HTML responses and store the endpoints they reference.
      # Gated because it WRITES (derived rows, deleted with their flows); it sends nothing.
      @[Tool("scan_js_endpoints", gated: true, agent_action: true, permission: "send")]
      private def scan_js_endpoints(h) : Result
        filter = ql_filter_or_error(h, str(h, "query"))
        return filter if filter.is_a?(Result)
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        if bool_arg(h, "in_scope", false)
          scope = Scope.load(store)
          return err("in_scope:true but no scope rules are configured — nothing is in scope",
            "INVALID_ARGUMENT", field: "in_scope") unless scope.configured?
          filter = QL.and(scope.filter(force: true), filter)
        end
        opts = JsRefs::ScanOptions.new(filter: filter,
          max_flows: clamp(optional_int_arg(h, "max_flows"), JsRefs::DEFAULT_MAX_FLOWS, 5000),
          rescan: bool_arg(h, "rescan", false))
        r = JsRefs.scan(store, opts)
        Result.new(JSON.build do |j|
          j.object do
            j.field "flows_scanned", r.flows_scanned
            j.field "references", r.refs
            j.field "new_endpoints", r.new_endpoints
            j.field "bodies_capped", r.bodies_capped
            j.field "refs_capped", r.refs_capped
            j.field "refused_unsafe", r.unsafe
            j.field "write_failures", r.write_failures
            j.field "truncated", r.truncated
            j.field "note", js_scan_note(r) if js_scan_note(r)
          end
        end)
      end

      private def js_scan_note(r : JsRefs::ScanReport) : String?
        if r.write_failures > 0
          "#{r.write_failures} flow(s) were NOT recorded (project busy) and stay unscanned — call again"
        elsif r.truncated
          "read the newest #{r.flows_scanned} responses (max_flows); unscanned ones remain — call again to continue"
        end
      end

      private def js_endpoint_row(j : JSON::Builder, e : JsRefs::Endpoint) : Nil
        j.object do
          j.field "scheme", e.scheme
          j.field "host", Serialize.text(e.host)
          j.field "port", e.port
          j.field "path", Serialize.text(e.path)
          j.field "target", Serialize.text(e.target)
          j.field "url", Serialize.text(e.url)
          j.field "requested", e.requested
          j.field "flows", e.flows
          j.field "in_comment", e.in_comment
          j.field "templated", e.templated
          j.field "base", e.base.label
          j.field "flow_id", e.flow_id
          j.field "offset", e.offset
          j.field "line", e.line
          j.field "literal", Serialize.text(e.literal)
          j.field "source_url", e.source_url.try { |u| Serialize.text(u) }
        end
      end

      # The `unrequested` block `list_sitemap` adds under `include_unrequested` — the same
      # listing `list_js_endpoints` pages, capped here because it rides beside a page of traffic.
      UNREQUESTED_MAX = 500

      private def emit_unrequested(j : JSON::Builder) : Nil
        report = JsRefs.list(store, JsRefs::ListOptions.new, Scope.load(store))
        rows = report.endpoints
        j.field "unrequested" do
          j.array do
            rows.first(UNREQUESTED_MAX).each do |e|
              j.object do
                j.field "scheme", e.scheme
                j.field "host", Serialize.text(e.host)
                j.field "port", e.port
                j.field "target", Serialize.text(e.target)
                j.field "flows", e.flows
                j.field "templated", e.templated
                j.field "in_comment", e.in_comment
                j.field "source_flow_id", e.flow_id
              end
            end
          end
        end
        j.field "unrequested_total", rows.size
        j.field "unrequested_truncated", rows.size > UNREQUESTED_MAX
      end

      private def list_js_refs_tools(j : JSON::Builder) : Nil
        tool j, "list_js_endpoints",
          "Endpoints REFERENCED in captured JavaScript (literals like fetch(\"/api/users\") in JS " \
          "responses and inline scripts), one row per host+path; by default only those no captured " \
          "request reached. Rows carry flow_id, byte offset, line and the literal; `templated` = " \
          "`{expr}` stands for a `${…}` (not sendable as-is); `base` = what a relative literal " \
          "resolved against (guessed: no Referer). Hosts never captured are hidden unless scoped " \
          "(`hidden_hosts`). Reads what scan_js_endpoints stored; sends nothing." do |s|
          s.field "host", strprop("only this host (exact)")
          s.field "path_prefix", strprop("only paths starting with this")
          s.field "include_requested", boolprop("also list references traffic reached (default false)")
          s.field "all_hosts", boolprop("also list never-captured, unscoped hosts (default false)")
          s.field "include_comments", boolprop("list references seen only in comments (default true)")
          s.field "in_scope", boolprop("only in-scope references (default false)")
          s.field "limit", intprop("rows per page (default 200, max 2000)")
          s.field "offset", intprop("rows to skip (default 0)")
        end

        return unless @allow_actions

        tool j, "scan_js_endpoints",
          "Read the captured JS responses and HTML pages not scanned yet (newest first) and store the " \
          "endpoints they reference, for list_js_endpoints and the Sitemap. Sends NOTHING. " \
          "Incremental; `truncated:true` = unscanned ones remain, call again." do |s|
          s.field "query", strprop("gori QL filter over the flows to read")
          s.field "in_scope", boolprop("only in-scope flows (default false)")
          s.field "max_flows", intprop("responses to read (default #{JsRefs::DEFAULT_MAX_FLOWS}, max 5000)")
          s.field "rescan", boolprop("re-read scanned responses (default false)")
          s.field "strict", boolprop("reject an unrecognized query term (default false)")
          s.field "lenient", boolprop("free-text an unknown `field:` (default false)")
        end
      end
    end
  end
end
