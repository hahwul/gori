# `gori run sitemap` — print the host → path endpoint tree (text, json, paths).
module Gori
  module CLI
    module Run
      private def self.cmd_sitemap(args : Array(String)) : Nil
        # `tag` is reserved as the first positional; a QL query starting with it goes
        # through --query (same convention as `gori run probe`'s subcommands).
        return cmd_sitemap_tag(args[1..]) if args.first? == "tag"
        cmd_sitemap_tree(args)
      end

      # Pin (or clear) a free-text memo on one path — the TUI Sitemap tab's `t`. The tree
      # already READ tags (stamp_tags! below); this is the write side.
      private def self.cmd_sitemap_tag(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        path : String? = nil
        tag : String? = nil
        clear = false
        list = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap tag --host=H --path=P --tag=TEXT\n" \
                     "       gori run sitemap tag --list [--host=H]\n\n" \
                     "Pin a free-text memo onto one sitemap path (the same tags the TUI Sitemap\n" \
                     "tab shows). --path is the node path AS THE TREE SHOWS IT, INCLUDING any\n" \
                     "query string — /search?q=1 is a different node from /search."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "Host the path belongs to") { |v| host = v }
          p.on("--path=PATH", "URL path, e.g. /api/users") { |v| path = v }
          p.on("--tag=TEXT", "The memo to pin") { |v| tag = v }
          p.on("--clear", "Remove the tag on --host/--path") { clear = true }
          p.on("--list", "List existing tags instead of setting one") { list = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run sitemap tag: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap tag: missing value for #{f}" }
        end
        parser.parse(args)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          if list
            rows = store.sitemap_tags.to_a.sort_by { |(k, _)| k }
            rows = rows.select { |(k, _)| k[0] == host } if host
            STDERR.puts "no tags" if rows.empty?
            rows.each { |(k, t)| puts "#{k[0]}#{k[1]}\t#{t}" }
            return
          end
          apply_sitemap_tag(store, host, path, tag, clear)
        ensure
          store.close
        end
      end

      # Validate the write-side flags and set (or clear) the tag. Split out of cmd_sitemap_tag
      # to keep it under the cyclomatic-complexity bar. Takes the parsed values as ARGUMENTS:
      # in place they are assigned inside OptionParser blocks, so Crystal keeps them nilable
      # and `x || abort` does not narrow them.
      private def self.apply_sitemap_tag(store : Store, host : String?, path : String?,
                                         tag : String?, clear : Bool) : Nil
        abort "gori run sitemap tag: --host is required" if host.nil?
        abort "gori run sitemap tag: --path is required" if path.nil?
        abort "gori run sitemap tag: pass --tag=TEXT or --clear" if tag.nil? && !clear
        abort "gori run sitemap tag: --tag and --clear are mutually exclusive" if tag && clear

        key = sitemap_tag_path(path)
        text = clear ? "" : tag.to_s
        matched = sitemap_node_exists?(store, host, key)
        abort "gori run sitemap tag: NOT applied (project busy) — the node is unchanged" unless store.set_sitemap_tag(host, key, text)
        puts text.empty? ? "Tag cleared on #{host}#{key}." : "Tagged #{host}#{key}: #{text}"
        unless matched || text.empty?
          STDERR.puts "gori run sitemap tag: warning: no captured endpoint at #{host}#{key} — this tag will not show in the tree until one exists (check for a typo or a trailing slash)"
        end
      end

      # Whether any captured endpoint on `host` normalizes to `path`. A tag whose (host, path)
      # names no endpoint is stored but unreachable — it can never stamp onto a tree node. The
      # common causes are a typo and a trailing slash (Sitemap.add drops one, so /api/users/ is
      # stamped as /api/users).
      private def self.sitemap_node_exists?(store : Store, host : String, path : String) : Bool
        store.sitemap_entries_detailed(QL::EMPTY, Store::SITEMAP_MAX).any? do |e|
          e.host == host && sitemap_tag_path(e.target) == path
        end
      end

      # A tag's key is the node path the tree stamps, which Sitemap.normalize_path produces —
      # and that KEEPS the query string ("/login?a=1" is a distinct node from "/login").
      # Normalizing through the same function is what makes a tag set here the one the TUI
      # Sitemap tab shows; stripping the query would file it under a key no node ever has.
      private def self.sitemap_tag_path(target : String) : String
        path = Sitemap.normalize_path(target.strip)
        return "/" if path.empty?
        path.starts_with?('/') || path.starts_with?("http") ? path : "/#{path}"
      end

      private def self.cmd_sitemap_tree(args : Array(String)) : Nil
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
          p.on("--no-group", "Don't fold path-param ids (/users/<uuid>, /users/1,2,3…)") { group = false }
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
        # `--query body:…` reads the off-commit trigram index (Store V4); drain it so a
        # one-shot tree can't be missing endpoints that simply weren't indexed yet.
        store.index_pending! if filter.uses_fts?
        hosts = Sitemap.build(store.sitemap_entries(filter, limit, raise_on_error: true))
        Sitemap.stamp_tags!(hosts, store.sitemap_tags)
        if in_scope
          scope = Scope.load(store)
          STDERR.puts "gori run sitemap: --in-scope, but no scope rules are configured — nothing is in scope" unless scope.configured?
          hosts.select! { |h| scope.host_in_scope?(h.label) }
        end
        if group
          # Opaque ids first, then numeric runs — mirrors SitemapView#reload.
          hosts.each { |h| Sitemap.fold_templates!(h) }
          hosts.each { |h| Sitemap.group_sequences!(h) }
        end
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
