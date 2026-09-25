# `gori run sitemap js` — endpoints referenced in captured JavaScript (#1243).
module Gori
  module CLI
    module Run
      # The parsed flags, so the parser block and the command body stay small enough for the
      # complexity bar (and so `abort` paths can be decided before the store opens).
      private class SitemapJsArgs
        property db_path : String? = nil
        property project_name : String? = nil
        property query : String? = nil
        property host : String? = nil
        property path_prefix : String? = nil
        property? scan = false
        property? rescan = false
        property max_flows = JsRefs::DEFAULT_MAX_FLOWS
        property? all = false
        property? all_hosts = false
        property? comments = true
        property? in_scope = false
        property format = :text
        property? lenient = false
        property positional = [] of String
      end

      private def self.cmd_sitemap_js(args : Array(String)) : Nil
        o = SitemapJsArgs.new
        parser = sitemap_js_parser(o)
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        query, dropped = Run.compose_history_query(o.query, o.positional, neg_terms)
        Run.warn_dropped_query_terms("sitemap js", dropped)
        Run.refuse_unknown_query_fields("sitemap js", query, o.lenient?)
        scanning = o.scan? || o.rescan?
        # The query picks the flows a scan READS. A listing is keyed by the reference, not by a
        # flow, so a query without a scan would silently filter nothing — refuse it by name.
        if query && !query.strip.empty? && !scanning
          abort "gori run sitemap js: a query narrows the flows --scan reads; pass --scan (or --host/--path to narrow the list)"
        end

        # Parse before the open: abort skips ensure, so a bad query must not leave a store open.
        filter = scanning ? sitemap_filter(query) : QL::EMPTY
        store = open_store(resolve_read_project(o.project_name, o.db_path),
          read_only: !scanning && !filter.uses_fts?, long_running: scanning)
        filter = sitemap_flow_filter(store, "sitemap js", query, filter, false, "flows out of the scan") if scanning
        report = begin
          sitemap_js_scan(store, filter, o) if scanning
          sitemap_js_list(store, o)
        rescue ex
          abort "gori run sitemap js: #{ex.message}"
        ensure
          store.close
        end
        emit_sitemap_js(report, o) if report
      end

      private def self.sitemap_js_parser(o : SitemapJsArgs) : OptionParser
        OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap js [--scan [QL query]] [options]\n\n" \
                     "List the endpoints captured JavaScript references — string literals in JS\n" \
                     "responses and inline <script> blocks, like fetch(\"/api/v1/users\") — that no\n" \
                     "captured request has reached. Nothing is sent: --scan reads bodies already in\n" \
                     "the project (the newest unscanned JS/HTML responses) and stores what they\n" \
                     "reference. A reference to a host gori never captured is listed only when a scope\n" \
                     "include names it (--all-hosts lists it anyway)."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| o.project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| o.db_path = v }
          p.on("--scan", "First scan the JS/HTML responses not scanned yet (writes derived rows, sends nothing)") { o.scan = true }
          p.on("--rescan", "Like --scan, but read already-scanned responses again") { o.rescan = true }
          p.on("-qQL", "--query=QL", "With --scan: only scan flows matching this QL query") { |v| o.query = v }
          p.on("--max-flows=N", "With --scan: newest responses to read (default #{JsRefs::DEFAULT_MAX_FLOWS})") { |v| o.max_flows = parse_count(v, "--max-flows") }
          p.on("--host=HOST", "Only references to this host (exact, case-insensitive)") { |v| o.host = v }
          p.on("--path=PREFIX", "Only references whose path starts with PREFIX") { |v| o.path_prefix = v }
          p.on("--all", "Also list references that captured traffic already reached") { o.all = true }
          p.on("--all-hosts", "Also list references to hosts gori never captured and no scope include names") { o.all_hosts = true }
          p.on("--no-comments", "Leave out references that only ever appeared inside a comment") { o.comments = false }
          p.on("--in-scope", "Only references the project scope includes") { o.in_scope = true }
          p.on("--lenient", "Don't refuse a query naming an unknown field — search that token as text") { o.lenient = true }
          p.on("--format=FMT", "Output: text (default) | json | urls (one URL per line, to pipe into other tools)") do |v|
            o.format = parse_format(v, [:text, :json, :urls])
          end
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| o.positional = before + after }
          p.invalid_option { |f| abort "gori run sitemap js: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap js: missing value for #{f}" }
        end
      end

      # Scan, then say what it did on STDERR (STDOUT carries only the listing). A rolled-back
      # write is reported, not swallowed: that flow stays unscanned and the next run retries it.
      private def self.sitemap_js_scan(store : Store, filter : QL::Filter, o : SitemapJsArgs) : Nil
        r = JsRefs.scan(store, JsRefs::ScanOptions.new(filter: filter, max_flows: o.max_flows, rescan: o.rescan?))
        STDERR.puts "gori run sitemap js: #{sitemap_js_scan_summary(r)}"
        if r.write_failures > 0
          STDERR.puts "gori run sitemap js: #{r.write_failures} flow(s) NOT recorded (project busy) — they stay unscanned; run again"
        end
        if r.truncated
          STDERR.puts "gori run sitemap js: read the newest #{r.flows_scanned} responses (--max-flows); " \
                      "unscanned ones remain — run --scan again"
        end
      end

      # One line: what was read and found, and every cap that cut the reading short.
      def self.sitemap_js_scan_summary(r : JsRefs::ScanReport) : String
        parts = ["scanned #{r.flows_scanned} response#{r.flows_scanned == 1 ? "" : "s"}",
                 "#{r.refs} reference#{r.refs == 1 ? "" : "s"}",
                 "#{r.new_endpoints} new endpoint#{r.new_endpoints == 1 ? "" : "s"}"]
        parts << "#{r.bodies_capped} bod#{r.bodies_capped == 1 ? "y" : "ies"} read only to #{JsRefs::MAX_SCAN // 1024 // 1024} MiB" if r.bodies_capped > 0
        parts << "#{r.refs_capped} stopped at #{JsRefs::MAX_REFS} literals" if r.refs_capped > 0
        parts << "#{r.unsafe} refused (CR/LF)" if r.unsafe > 0
        parts.join(", ")
      end

      # Per-reference scope, like `sitemap params --in-scope`: unconfigured scope is an empty
      # list with a note, never a silent read of everything.
      private def self.sitemap_js_list(store : Store, o : SitemapJsArgs) : JsRefs::ListReport?
        scope = Scope.load(store)
        if o.in_scope? && !scope.configured?
          STDERR.puts "gori run sitemap js: --in-scope, but no scope rules are configured — nothing is in scope"
          return nil
        end
        opts = JsRefs::ListOptions.new(host: o.host, path_prefix: o.path_prefix, include_requested: o.all?,
          all_hosts: o.all_hosts?, in_scope: o.in_scope?, include_comments: o.comments?)
        JsRefs.list(store, opts, scope)
      end

      # Data → STDOUT; notes → STDERR (STDOUT-purity), and json is always an array.
      private def self.emit_sitemap_js(report : JsRefs::ListReport, o : SitemapJsArgs) : Nil
        sitemap_js_notes(report).each { |n| STDERR.puts "gori run sitemap js: #{n}" }
        case o.format
        when :json
          puts sitemap_js_json(report.endpoints)
        when :urls
          templated = 0
          report.endpoints.each do |e|
            # A `{expr}` placeholder is not a URL anything should fetch.
            next templated += 1 if e.templated
            puts CLI::Output.term_safe(e.url)
          end
          STDERR.puts "gori run sitemap js: left out #{templated} templated reference(s) — see --format text" if templated > 0
        else
          if report.endpoints.empty?
            STDERR.puts "no #{o.all? ? "" : "unrequested "}references (#{report.scanned_flows} responses scanned — `--scan` reads new ones)"
          else
            print sitemap_js_text(report.endpoints)
          end
        end
      end

      def self.sitemap_js_notes(report : JsRefs::ListReport) : Array(String)
        notes = [] of String
        if report.scanned_flows == 0
          notes << "no JavaScript has been scanned in this project yet — pass --scan"
        end
        if report.hidden_hosts > 0
          notes << "#{report.hidden_hosts} reference(s) to hosts gori never captured are hidden — " \
                   "scope the host, or pass --all-hosts"
        end
        if report.requested_unknown
          notes << "more than #{Store::SITEMAP_MAX} captured endpoints: some references could not be " \
                   "checked against traffic and are listed as unrequested"
        end
        notes << "read the first #{Store::JS_REF_READ_MAX} stored references only" if report.capped
        notes
      end

      # Grouped by host; one line per referenced endpoint with where it was read.
      def self.sitemap_js_text(endpoints : Array(JsRefs::Endpoint)) : String
        path_w = endpoints.max_of? { |e| CLI::Output.cell_width(CLI::Output.term_safe(e.path)) }.try(&.clamp(8, 48)) || 8
        String.build do |io|
          host = nil
          endpoints.each do |e|
            if e.host != host
              io << '\n' if host
              host = e.host
              io << CLI::Output.term_safe(e.host) << '\n'
            end
            io << "  " << CLI::Output.pad_cell(CLI::Output.term_safe(e.path), path_w + 1)
            io << (e.requested == true ? "requested  " : "           ")
            io << (e.flows == 1 ? "1 flow " : "#{e.flows} flows") << "  "
            io << '#' << e.flow_id << ':' << e.line
            io << "  " << CLI::Output.term_safe(e.literal.inspect)
            flags = sitemap_js_flags(e)
            io << "  [" << flags.join(", ") << ']' unless flags.empty?
            io << '\n'
          end
        end
      end

      private def self.sitemap_js_flags(e : JsRefs::Endpoint) : Array(String)
        flags = [] of String
        flags << "comment" if e.in_comment
        flags << "templated" if e.templated
        flags << "base: #{e.base.label}" unless e.base.absolute? || e.base.page?
        flags
      end

      def self.sitemap_js_json(endpoints : Array(JsRefs::Endpoint)) : String
        JSON.build do |j|
          j.array do
            endpoints.each { |e| sitemap_js_row_json(j, e) }
          end
        end
      end

      def self.sitemap_js_row_json(j : JSON::Builder, e : JsRefs::Endpoint) : Nil
        j.object do
          j.field "scheme", e.scheme
          j.field "host", CLI::Output.term_safe(e.host)
          j.field "port", e.port
          j.field "path", CLI::Output.term_safe(e.path)
          j.field "target", CLI::Output.term_safe(e.target)
          j.field "url", CLI::Output.term_safe(e.url)
          j.field "requested", e.requested
          j.field "flows", e.flows
          j.field "in_comment", e.in_comment
          j.field "templated", e.templated
          j.field "base", e.base.label
          j.field "flow_id", e.flow_id
          j.field "offset", e.offset
          j.field "line", e.line
          j.field "literal", e.literal.scrub
          j.field "source_url", e.source_url.try { |u| CLI::Output.term_safe(u) }
        end
      end
    end
  end
end
