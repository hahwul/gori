# `gori run sitemap` — print the host → path endpoint tree (text, json, paths).
module Gori
  module CLI
    module Run
      private def self.cmd_sitemap(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        limit = Store::SITEMAP_MAX
        in_scope = false
        group = true
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap [QL query] [options]\n\nPrint the deduplicated host → path endpoint tree built from the captured flows."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter endpoints with a QL query (host: method: path: status: scheme: …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max distinct endpoints to scan (default #{Store::SITEMAP_MAX})") { |v| limit = parse_count(v, "--limit") }
          p.on("--in-scope", "Only hosts in the project's configured scope") { in_scope = true }
          p.on("--no-group", "Don't fold long numeric path-segment runs (/users/1,2,3…)") { group = false }
          p.on("--format=FMT", "Output: text (default tree) | json | paths") { |v| format = parse_format(v, [:text, :json, :paths]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run sitemap: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # Accept a positional QL too ("gori run sitemap host:api" / "-status:404"), mirroring
        # history's `/` bar; an explicit --query wins. Terms join with spaces (QL ANDs).
        positional_query = (positional + neg_terms).join(' ')
        query ||= positional_query unless positional_query.empty?

        # Parse/validate the QL BEFORE opening the store: abort skips ensure blocks, so a
        # bad query must not leave a store handle open.
        filter = sitemap_filter(query)

        store = open_store(resolve_read_project(project_name, db_path))
        hosts = begin
          collect_sitemap(store, filter, limit, in_scope, group)
        rescue ex
          abort "gori run sitemap: query #{query.inspect} failed: #{ex.message}"
        ensure
          store.close
        end

        emit_sitemap(hosts, format)
      end

      # QL.parse + the same un-compilable-query rejection as history (a non-blank query
      # collapsing to EMPTY would silently dump every endpoint).
      private def self.sitemap_filter(query : String?) : QL::Filter
        return QL::EMPTY unless q = query
        filter = QL.parse(q)
        QL.invalid_regex_terms(q).each do |t|
          STDERR.puts "gori run sitemap: warning: invalid regex in #{t.inspect} — that term matches nothing"
        end
        if !q.strip.empty? && filter == QL::EMPTY
          abort "gori run sitemap: query #{q.inspect} did not match any field (check syntax, e.g. host:example.com method:POST path:/api status:>=500)"
        end
        filter
      end

      # Build + post-process the tree from the open store in the SAME ORDER as
      # SitemapView#reload (build → tags → scope → fold → counts). The scope step
      # differs by design: --in-scope filters whole hosts via Scope#host_in_scope?,
      # which evaluates the rules regardless of the TUI's persisted ⇧S enabled flag
      # (an explicit --in-scope is the opt-in). That host-level gate is coarser than
      # the TUI lens's per-flow SQL filter and conservative on url-level includes.
      private def self.collect_sitemap(store : Store, filter : QL::Filter, limit : Int32,
                                       in_scope : Bool, group : Bool) : Array(Sitemap::Node)
        hosts = Sitemap.build(store.sitemap_entries(filter, limit, raise_on_error: true))
        Sitemap.stamp_tags!(hosts, store.sitemap_tags)
        if in_scope
          scope = Scope.load(store)
          STDERR.puts "gori run sitemap: --in-scope, but no scope rules are configured — nothing is in scope" unless scope.configured?
          hosts.select! { |h| scope.host_in_scope?(h.label) }
        end
        hosts.each { |h| Sitemap.group_sequences!(h) } if group
        hosts.each { |h| h.endpoints = Sitemap.endpoint_count(h) }
        hosts
      end

      # Results → STDOUT; the empty-state note → STDERR (STDOUT-purity). JSON always
      # emits a (possibly empty) array so scripts get valid JSON either way.
      private def self.emit_sitemap(hosts : Array(Sitemap::Node), format : Symbol) : Nil
        if format == :json
          puts CLI::Output.sitemap_json(hosts)
        elsif hosts.empty?
          STDERR.puts "no endpoints (capture some traffic, or relax --in-scope / the query)"
        elsif format == :paths
          print CLI::Output.sitemap_paths(hosts)
        else
          print CLI::Output.sitemap_text(hosts)
        end
      end
    end
  end
end
