require "json"
require "../../js_refs"
require "../../sourcemap"
require "../../host_overrides"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Endpoints referenced in captured JavaScript (#1243) — one read instead of `get_flow` on
      # every bundle plus a regex of the agent's own. Only what a scan stored; reading sends
      # nothing and writes nothing.
      JS_ENDPOINTS_LIMIT = PageLimit.new(200, 2000)

      @[Tool("list_js_endpoints", feature: "target")]
      private def list_js_endpoints(h) : Result
        pg = page_args(h, JS_ENDPOINTS_LIMIT)
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
        page = rows[pg.offset, pg.limit]? || [] of JsRefs::Endpoint
        parts = fit_rows(page) { |rj, e, _| js_endpoint_row(rj, e) }
        cut = parts.size < page.size
        page = page.first(parts.size)
        Result.new(JSON.build do |j|
          j.object do
            j.field("endpoints") { raw_rows(j, parts) }
            emit_page(j, pg, page.size, rows.size, cut: cut)
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
      # Gated because it WRITES (derived rows, deleted with their flows); it sends nothing — so
      # its permission group is "Edit project data", not "Send traffic".
      @[Tool("scan_js_endpoints", gated: true, agent_action: true, permission: "write", open_world: false, feature: "target")]
      private def scan_js_endpoints(h) : Result
        dropped = [] of String
        filter = ql_filter_or_error(h, str(h, "query"), dropped)
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
            emit_ignored_terms(j, dropped)
          end
        end)
      end

      # Fetch (or inline-parse) the source map a captured JS response points at and feed its
      # recovered ORIGINAL sources through the same extractor `scan_js_endpoints` uses, so the
      # endpoints a minified bundle hid surface. ACTIVE: unless the map is an inline `data:` URI,
      # it makes ONE real outbound request, gated by scope (refused unless allow_unscoped). The
      # recovered references are stored against the flow, so `list_js_endpoints` then lists them.
      @[Tool("unpack_sourcemap", gated: true, agent_action: true, permission: "send", feature: "target")]
      private def unpack_sourcemap(h) : Result
        return err("request cancelled", "CANCELLED") if cancelled?
        id = required_id(h, "flow_id")
        detail = store.get_flow(id)
        return not_found("no flow with id #{id}") unless detail
        ob = agent_outbound(Scope.load(store), bool_arg(h, "allow_unscoped", false))
        report = Sourcemap.unpack(store, detail, ob,
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          overrides: HostOverrides.load(store))
        if err = report.error
          if err.starts_with?(Repeater::Sender::SCOPE_REFUSAL_PREFIX)
            return err(err, "SCOPE_BLOCKED", field: "allow_unscoped")
          end
          # A missing reference / unreachable map / malformed JSON is a clean outcome, not a
          # tool failure: the call succeeded, there was just nothing to recover.
          if report.origin.nil? || report.refs.empty?
            return Result.new(JSON.build do |j|
              j.object do
                j.field "flow_id", id
                j.field "references", 0
                j.field "note", err
              end
            end)
          end
        end
        rows = report.refs.first(JS_ENDPOINTS_LIMIT.max)
        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id", id
            j.field "reference", report.reference.try { |r| Serialize.text(r) }
            j.field "origin", report.origin.try(&.to_s.downcase)
            j.field "sources", report.sources
            j.field "references", report.refs.size
            j.field "stored", report.stored
            j.field "sources_capped", report.sources_capped
            j.field "refs_capped", report.refs_capped
            j.field("endpoints") do
              j.array do
                rows.each { |r| sourcemap_endpoint_row(j, r) }
              end
            end
            j.field "endpoints_truncated", report.refs.size > rows.size
            if note = unpack_note(report)
              j.field "note", note
            end
          end
        end)
      end

      private def unpack_note(r : Sourcemap::Report) : String?
        if r.refs.empty?
          "the source map held no endpoint references"
        elsif !r.stored
          "recovered #{r.refs.size} reference(s) but could not store them (project busy) — they are not in list_js_endpoints; call again"
        elsif r.sources_capped || r.refs_capped
          "stopped early at a safety bound (sources_capped/refs_capped) — some sources were not read"
        end
      end

      private def sourcemap_endpoint_row(j : JSON::Builder, r : Store::JsRef) : Nil
        {
          scheme:     r.scheme,
          host:       Serialize.text(r.host),
          port:       r.port,
          path:       Serialize.text(r.path),
          url:        Serialize.text(Store::FlowRow.url_of(r.scheme, r.host, r.port, r.target)),
          line:       r.line,
          literal:    Serialize.text(r.literal),
          templated:  r.flags & JsRefs::FLAG_TEMPLATED != 0,
          in_comment: r.flags & JsRefs::FLAG_COMMENT != 0,
        }.to_json(j)
      end

      private def js_scan_note(r : JsRefs::ScanReport) : String?
        if r.write_failures > 0
          "#{r.write_failures} flow(s) were NOT recorded (project busy) and stay unscanned — call again"
        elsif r.truncated
          "read the newest #{r.flows_scanned} responses (max_flows); unscanned ones remain — call again to continue"
        end
      end

      private def js_endpoint_row(j : JSON::Builder, e : JsRefs::Endpoint) : Nil
        {
          scheme:     e.scheme,
          host:       Serialize.text(e.host),
          port:       e.port,
          path:       Serialize.text(e.path),
          target:     Serialize.text(e.target),
          url:        Serialize.text(e.url),
          requested:  e.requested,
          flows:      e.flows,
          in_comment: e.in_comment,
          templated:  e.templated,
          base:       e.base.label,
          flow_id:    e.flow_id,
          offset:     e.offset,
          line:       e.line,
          literal:    Serialize.text(e.literal),
          source_url: e.source_url.try { |u| Serialize.text(u) },
        }.to_json(j)
      end

      # The `unrequested` block `list_sitemap` adds under `include_unrequested` — the same
      # listing `list_js_endpoints` pages, capped here because it rides beside a page of traffic:
      # by count, and by what is left of the reply budget after the page's entries (`used`).
      UNREQUESTED_MAX = 500

      private def emit_unrequested(j : JSON::Builder, used : Int32) : Nil
        report = JsRefs.list(store, JsRefs::ListOptions.new, Scope.load(store))
        rows = report.endpoints
        parts = fit_rows(rows.first(UNREQUESTED_MAX), used) do |rj, e, _|
          {
            scheme:         e.scheme,
            host:           Serialize.text(e.host),
            port:           e.port,
            target:         Serialize.text(e.target),
            flows:          e.flows,
            templated:      e.templated,
            in_comment:     e.in_comment,
            source_flow_id: e.flow_id,
          }.to_json(rj)
        end
        j.field("unrequested") { raw_rows(j, parts) }
        j.field "unrequested_total", rows.size
        j.field "unrequested_truncated", rows.size > parts.size
      end

      private def list_js_refs_tools(j : JSON::Builder) : Nil
        tool j, "list_js_endpoints",
          "Endpoints REFERENCED in captured JavaScript (e.g. fetch(\"/api/users\")), one row per " \
          "origin+path, by default only those no request reached. Rows carry flow_id, offset, " \
          "line, literal; `templated` = has a `{expr}` placeholder (not sendable as-is); `base` " \
          "= guessed base of a relative literal. Unscoped never-captured hosts are hidden " \
          "(`hidden_hosts`). Reads scan_js_endpoints' results; sends nothing." do |s|
          s.field "host", strprop("only this host (exact)")
          s.field "path_prefix", strprop("only paths starting with this")
          s.field "include_requested", boolprop("also references traffic reached")
          s.field "all_hosts", boolprop("also never-captured, unscoped hosts")
          s.field "include_comments", boolprop("include references seen only in comments (default true)")
          s.field "in_scope", boolprop("only in-scope references")
          s.field "limit", limitprop("rows per page", JS_ENDPOINTS_LIMIT)
          s.field "offset", intprop("rows to skip (default 0)")
        end

        return unless @allow_actions

        tool j, "scan_js_endpoints",
          "Scan captured JS and HTML responses not yet scanned (newest first) and store the " \
          "endpoints they reference. Sends NOTHING. Incremental: `truncated:true` = more " \
          "remain, call again." do |s|
          s.field "query", strprop("gori QL filter over the flows to read")
          s.field "in_scope", boolprop("only in-scope flows")
          s.field "max_flows", intprop("responses to read (default #{JsRefs::DEFAULT_MAX_FLOWS}, max 5000)")
          s.field "rescan", boolprop("re-read scanned responses")
          s.field "strict", boolprop("refuse an unrecognized query term (otherwise dropped and named in `ignored_terms`)")
          s.field "lenient", boolprop("free-text an unknown `field:`")
        end

        tool j, "unpack_sourcemap",
          "Fetch (or inline-parse) the source map a captured JS response points at " \
          "(//# sourceMappingURL / SourceMap header) and recover the endpoints hidden in its " \
          "original sources, feeding them through the same extractor scan_js_endpoints uses. " \
          "ACTIVE: a real outbound request unless the map is an inline data: URI; gated by scope " \
          "(refused unless allow_unscoped). The recovered references are stored against the flow, " \
          "so list_js_endpoints then lists them." do |s|
          s.field "flow_id", intprop("the captured JS flow whose source map to unpack (required)")
          s.field "allow_unscoped", boolprop("fetch even when the map's host is outside (or without) a configured scope (default false)")
          s.field "insecure", boolprop("skip upstream TLS verification when fetching the map (default false)")
        end
      end
    end
  end
end
