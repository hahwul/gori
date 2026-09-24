# `gori run sitemap export` — the captured API as an OpenAPI 3.0.3 document (#1241).
module Gori
  module CLI
    module Run
      private def self.cmd_sitemap_export(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        host : String? = nil
        path_prefix : String? = nil
        in_scope = false
        hide_static = false
        examples = false
        redact_profile : String? = nil
        defaults = Export::OpenApi::Options.new
        max_flows = defaults.max_flows
        max_samples = defaults.max_samples
        max_endpoints = defaults.max_endpoints
        yaml = false
        lenient = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap export [QL query] [options]\n\n" \
                     "Write the captured API as an OpenAPI 3.0.3 document on stdout: templated paths\n" \
                     "(/users/123 → /users/{userId}), query/header/cookie parameters, request bodies\n" \
                     "and responses per status with inferred JSON schemas, servers, and the security\n" \
                     "schemes credentials imply. What was left out and why goes to stderr.\n" \
                     "No example values unless --examples, and those pass the redaction profile;\n" \
                     "credential values (Authorization, API-key headers, session cookies) are never\n" \
                     "written. The same flow set always exports to the same bytes."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Only flows matching this QL query") { |v| query = v }
          p.on("--host=HOST", "Only this host (exact, case-insensitive) — one API per document") { |v| host = v }
          p.on("--path=PREFIX", "Only endpoints whose path starts with PREFIX") { |v| path_prefix = v }
          p.on("--in-scope", "Only flows in the project's configured scope") { in_scope = true }
          p.on("--hide-static", "Leave out static assets — images, fonts, media (the TUI's hide-static lens)") { hide_static = true }
          p.on("--format=FMT", "Output: openapi (JSON, default) | openapi-yaml") { |v| yaml = openapi_yaml_format?(v) }
          p.on("--examples", "Add example values from one sample each, redacted through the profile") { examples = true }
          p.on("--redact=PROFILE", "Redaction profile the examples pass through (default: the project's, else the global one, else `default`)") do |v|
            redact_profile = v
          end
          p.on("--max-samples=N", "Flows read per operation (default #{max_samples})") { |v| max_samples = parse_count(v, "--max-samples") }
          p.on("--max-flows=N", "Newest flows read in all (default #{max_flows})") { |v| max_flows = parse_count(v, "--max-flows") }
          p.on("--max-endpoints=N", "Operations in the document (default #{max_endpoints})") { |v| max_endpoints = parse_count(v, "--max-endpoints") }
          p.on("--lenient", "Don't refuse a query naming an unknown field — search that token as text") { lenient = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run sitemap export: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap export: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        query, dropped = Run.compose_history_query(query, positional, neg_terms)
        Run.warn_dropped_query_terms("sitemap export", dropped)
        Run.refuse_unknown_query_fields("sitemap export", query, lenient)
        # A profile only decides what an EXAMPLE shows; without examples there is nothing for it
        # to act on, and accepting it silently would read as "the document was sanitized".
        if redact_profile && !examples
          abort "gori run sitemap export: --redact names the profile --examples pass through — add --examples"
        end

        # Parse before the open: abort skips ensure, so a bad query must not leave a store open.
        filter = sitemap_filter(query)
        store = open_store(resolve_read_project(project_name, db_path), read_only: !filter.uses_fts?)
        filter = sitemap_export_filter(store, query, filter, in_scope, hide_static)
        choice = examples ? Redact::Policy.resolve(store, redact_profile, on: true) : nil
        if err = choice.try(&.error)
          store.close
          abort "gori run sitemap export: #{err}"
        end
        opts = Export::OpenApi::Options.new(filter: filter, host: host, path_prefix: path_prefix,
          max_flows: max_flows, max_samples: max_samples, max_endpoints: max_endpoints,
          examples: examples, redactor: choice.try(&.matcher))
        result = begin
          Export::OpenApi.build(store, opts)
        rescue ex
          abort "gori run sitemap export: query #{query.inspect} failed: #{ex.message}"
        ensure
          store.close
        end

        print yaml ? Export::OpenApi.to_yaml(result.doc) : Export::OpenApi.to_json(result.doc)
        sitemap_export_notes(result.report, choice)
      end

      private def self.openapi_yaml_format?(v : String) : Bool
        case v.downcase
        when "openapi", "json"      then false
        when "openapi-yaml", "yaml" then true
        else                             abort "gori run sitemap export: unknown --format '#{v}' (use openapi|openapi-yaml)"
        end
      end

      # The flow set against the open store: a `scope:` term recompiled under the project's lens,
      # the `body:` backlog refused, then the hide-static and per-FLOW scope lenses (as `sitemap
      # params`). Unconfigured scope is refused rather than exported: an empty document is not an
      # answer anyone redirects to a file on purpose. Closes the store before any abort, since
      # abort skips the caller's ensure.
      private def self.sitemap_export_filter(store : Store, query : String?, filter : QL::Filter,
                                             in_scope : Bool, hide_static : Bool) : QL::Filter
        if (q = query) && QL.uses_scope?(q)
          lens = Scope.ql_lens(store)
          filter = QL.parse(q, scope: lens)
          Run.scope_query_notes(q, lens, in_scope).each { |n| STDERR.puts "gori run sitemap export: #{n}" }
        end
        if err = fts_backlog_error(store, filter,
             "#{query.inspect} would leave endpoints out of the document with nothing saying so. " \
             "Nothing was printed;")
          store.close
          abort "gori run sitemap export: #{err}"
        end
        filter = QL.and(filter, QL.hide_static) if hide_static
        return filter unless in_scope
        scope = Scope.load(store)
        unless scope.configured?
          store.close
          abort "gori run sitemap export: --in-scope, but no scope rules are configured — nothing is " \
                "in scope (add rules with `gori run project scope add`, or drop --in-scope)"
        end
        QL.and(scope.filter(force: true), filter)
      end

      # The report on STDERR (STDOUT carries the document and nothing else).
      private def self.sitemap_export_notes(report : Export::OpenApi::Report,
                                            choice : Redact::Policy::Choice?) : Nil
        cmd = "gori run sitemap export"
        if report.operations == 0
          STDERR.puts "#{cmd}: no operations (#{report.flows_read} flows read — capture some traffic, or relax the query)"
        else
          STDERR.puts "#{cmd}: #{report.summary}"
        end
        if report.hosts.size > 1
          STDERR.puts "#{cmd}: the flows span #{report.hosts.size} hosts, so each path lists the servers " \
                      "that answered it — --host H gives one API per document"
        end
        report.notes.each { |n| STDERR.puts "#{cmd}: #{n}" }
        return unless c = choice
        if profile = c.matcher.try(&.profile)
          STDERR.puts "#{cmd}: examples sanitized with profile #{profile.name.inspect}; cookie values " \
                      "are always placeholders, and credential headers are never written"
        end
        c.matcher.try &.pattern_errors.each do |e|
          STDERR.puts "#{cmd}: redaction pattern skipped, it does not compile — #{e}"
        end
        unless c.salt_persisted
          STDERR.puts "#{cmd}: the placeholder salt could not be saved to #{Settings.path}, so these " \
                      "tags are consistent within this export and will NOT match another session's"
        end
      end
    end
  end
end
