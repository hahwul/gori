# `gori run sitemap params` — the per-endpoint parameter inventory (#1231).
module Gori
  module CLI
    module Run
      private def self.cmd_sitemap_params(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        host : String? = nil
        path_prefix : String? = nil
        locations : Array(Miner::Location)? = nil
        all_headers = false
        in_scope = false
        hide_static = false
        max_flows = ParamInventory::Options.new.max_flows
        samples = ParamInventory::Options.new.samples
        include_sensitive = false
        format = :text
        lenient = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap params [QL query] [options]\n\n" \
                     "List every parameter name the captured requests carry, per endpoint: where it\n" \
                     "appears (query/form/multipart/json/headers/cookies), how many flows carried it,\n" \
                     "sample values, and whether a value came back in the response body (\"reflected\",\n" \
                     "an observation, not a finding). Values of credential-shaped inputs are masked\n" \
                     "unless --include-sensitive. JSON names are paths (user.email, items[].id); the\n" \
                     "`[]` is display-only, not JsonPath syntax."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Only flows matching this QL query") { |v| query = v }
          p.on("--host=HOST", "Only this host (exact, case-insensitive)") { |v| host = v }
          p.on("--path=PREFIX", "Only endpoints whose path starts with PREFIX") { |v| path_prefix = v }
          p.on("--location=LIST", "Only these locations: query,form,multipart,json,headers,cookies (default: all)") do |v|
            locations = parse_mine_locations(v, "gori run sitemap params")
          end
          p.on("--all-headers", "Include standard browser headers (User-Agent, Accept*, Sec-*, …)") { all_headers = true }
          p.on("--in-scope", "Only flows in the project's configured scope") { in_scope = true }
          p.on("--hide-static", "Leave out static assets — images, fonts, media (the TUI's hide-static lens)") { hide_static = true }
          p.on("--max-flows=N", "Newest flows to read (default #{max_flows})") { |v| max_flows = parse_count(v, "--max-flows") }
          p.on("--samples=N", "Distinct sample values kept per parameter (default #{samples})") { |v| samples = parse_count(v, "--samples") }
          p.on("--include-sensitive", "Print cookie / credential / token values instead of [REDACTED]") { include_sensitive = true }
          p.on("--lenient", "Don't refuse a query naming an unknown field — search that token as text") { lenient = true }
          p.on("--format=FMT", "Output: text (default) | json | names (one name per line — a Miner wordlist)") do |v|
            format = parse_format(v, [:text, :json, :names])
          end
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run sitemap params: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap params: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        query, dropped = Run.compose_history_query(query, positional, neg_terms)
        Run.warn_dropped_query_terms("sitemap params", dropped)
        Run.refuse_unknown_query_fields("sitemap params", query, lenient)
        if (loc = locations) && loc.empty?
          abort "gori run sitemap params: --location was empty — name at least one of query|form|multipart|json|headers|cookies"
        end

        # Parse before the open: abort skips ensure, so a bad query must not leave a store open.
        filter = sitemap_filter(query)
        store = open_store(resolve_read_project(project_name, db_path), read_only: !filter.uses_fts?)
        if (q = query) && QL.uses_scope?(q)
          lens = Scope.ql_lens(store)
          filter = QL.parse(q, scope: lens)
          Run.scope_query_notes(q, lens, in_scope).each { |n| STDERR.puts "gori run sitemap params: #{n}" }
        end
        if err = fts_backlog_error(store, filter,
             "#{query.inspect} would leave parameters out of the inventory with nothing saying so. " \
             "Nothing was printed;")
          store.close
          abort "gori run sitemap params: #{err}"
        end
        wanted = ParamInventory::ALL_LOCATIONS
        if picked = locations
          wanted = picked
        end
        # The TUI's Params sub-tab reads the tree's flow set, hide-static lens included; this is
        # that lens asked for explicitly (never read from the TUI's persisted toggle).
        filter = QL.and(filter, QL.hide_static) if hide_static
        opts = ParamInventory::Options.new(filter: filter, host: host, path_prefix: path_prefix,
          locations: wanted, all_headers: all_headers, max_flows: max_flows, samples: samples)
        report = begin
          sitemap_params_report(store, opts, in_scope)
        rescue ex
          abort "gori run sitemap params: query #{query.inspect} failed: #{ex.message}"
        ensure
          store.close
        end

        emit_sitemap_params(report, format, include_sensitive,
          headers: !!locations.try(&.includes?(Miner::Location::Headers)))
      end

      # Data → STDOUT; the truncation and empty-state notes → STDERR (STDOUT-purity), and json
      # is always an array so a script gets valid JSON either way.
      private def self.emit_sitemap_params(report : ParamInventory::Report, format : Symbol,
                                           include_sensitive : Bool, *, headers : Bool) : Nil
        if report.rows_capped
          STDERR.puts "gori run sitemap params: stopped at #{report.rows.size} parameter rows (the row cap) " \
                      "after #{report.flows_scanned} flows — narrow the query, --host or --path"
        elsif report.truncated
          STDERR.puts "gori run sitemap params: read the newest #{report.flows_scanned} flows " \
                      "(--max-flows); older flows are not in this inventory — raise it or narrow the query"
        end
        case format
        when :json
          puts params_json(report, include_sensitive)
        when :names
          ParamInventory.wordlist(report.rows, headers: headers).each { |n| puts CLI::Output.term_safe(n) }
        else
          if report.rows.empty?
            STDERR.puts "no parameters (#{report.flows_scanned} flows read — capture some traffic, or relax the query)"
          else
            print params_text(report.rows, include_sensitive)
          end
        end
      end

      # Per-FLOW scope, as `history --in-scope` — not the tree's host-level gate: the inventory
      # reads flows, and a url-level include is exactly the narrowing asked for. Unconfigured
      # scope is an empty inventory with a note, never a silent read of everything.
      private def self.sitemap_params_report(store : Store, opts : ParamInventory::Options,
                                             in_scope : Bool) : ParamInventory::Report
        if in_scope
          scope = Scope.load(store)
          unless scope.configured?
            STDERR.puts "gori run sitemap params: --in-scope, but no scope rules are configured — nothing is in scope"
            return ParamInventory::Report.new([] of ParamInventory::Row, 0, false)
          end
          opts = opts.copy_with(filter: QL.and(scope.filter(force: true), opts.filter))
        end
        ParamInventory.build(store, opts)
      end

      # Grouped by host, then endpoint; one line per parameter. Every captured string goes
      # through `term_safe` — a name or value is bytes off the wire and may carry an escape.
      def self.params_text(rows : Array(ParamInventory::Row), include_sensitive : Bool) : String
        name_w = rows.max_of? { |r| CLI::Output.cell_width(CLI::Output.term_safe(r.name)) }.try(&.clamp(4, 40)) || 4
        count_w = rows.max_of?(&.count.to_s.size) || 1
        String.build do |io|
          host = nil
          endpoint = nil
          rows.each do |r|
            if r.host != host
              io << '\n' if host
              host = r.host
              endpoint = nil
              io << CLI::Output.term_safe(r.host) << '\n'
            end
            if {r.method, r.path} != endpoint
              endpoint = {r.method, r.path}
              io << "  " << CLI::Output.term_safe(r.method) << ' ' << CLI::Output.term_safe(r.path) << '\n'
            end
            io << "    " << CLI::Output.pad_cell(r.location.label, 10)
            io << CLI::Output.pad_cell(CLI::Output.term_safe(r.name), name_w + 1)
            io << r.count.to_s.rjust(count_w) << "  "
            io << (r.reflected ? "reflected  " : "           ")
            shown = ParamInventory.masked(r, include_sensitive).map { |s| CLI::Output.term_safe(s) }
            io << shown.join(", ")
            io << ", …" if r.samples_truncated && !(r.sensitive && !include_sensitive)
            io << '\n'
          end
        end
      end

      def self.params_json(report : ParamInventory::Report, include_sensitive : Bool) : String
        JSON.build do |j|
          j.array do
            report.rows.each { |r| param_row_json(j, r, include_sensitive) }
          end
        end
      end

      def self.param_row_json(j : JSON::Builder, r : ParamInventory::Row, include_sensitive : Bool) : Nil
        redacted = r.sensitive && !include_sensitive
        j.object do
          j.field "host", CLI::Output.term_safe(r.host)
          j.field "method", CLI::Output.term_safe(r.method)
          j.field "path", CLI::Output.term_safe(r.path)
          j.field "location", r.location.label
          j.field "name", r.name.scrub
          j.field "count", r.count
          j.field "samples", ParamInventory.masked(r, include_sensitive).map(&.scrub)
          j.field "samples_truncated", r.samples_truncated
          j.field "sensitive", r.sensitive
          j.field "samples_redacted", redacted
          j.field "first_flow_id", r.first_flow_id
          j.field "last_flow_id", r.last_flow_id
          j.field "reflected", r.reflected
          j.field "reflected_flow_id", r.reflected_flow_id
        end
      end
    end
  end
end
