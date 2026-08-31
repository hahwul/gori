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
                     "tab shows). --path is the node path INCLUDING any query string —\n" \
                     "/search?q=1 is a different node from /search. The default tree FOLDS the\n" \
                     "query variants of a path into one row, and that row is synthetic: like a\n" \
                     "{uuid} fold it carries no tag of its own. Pass --no-fold-query (or expand\n" \
                     "the row in the TUI) to see the variant a tag is pinned to.\n" \
                     "A tag is keyed by host+path, not by a flow, so it OUTLIVES 'history clear'\n" \
                     "and re-attaches if that path is captured again; --list finds one whose\n" \
                     "node is not currently in the tree."
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
        # Both forms this parser serves, because a stray word is as likely on the read as on
        # the write: naming only the write flags told a `--list acme.test` operator to pass
        # --path and --tag, neither of which --list even reads.
        parse_no_positionals(parser, args, "gori run sitemap tag",
          "pass the node as --host H --path P and the memo as --tag TEXT (quote a memo with " \
          "spaces); --list narrows with --host H")

        store = open_store(resolve_read_project(project_name, db_path), read_only: list)
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

      # One tag as one TSV line. The memo is folded the way the TREE view already folds it
      # (`term_safe`, which is why a multi-line tag reads there as `# multi·line`): a tag is
      # free text — typed here, or set from the TUI or MCP — and printed raw, a newline in it
      # split one tag across two physical lines while a tab invented a fourth column, either
      # of which desyncs host+path from the memo for anything reading this output. There is no
      # `--format json` on --list to fall back to.
      private def self.sitemap_tag_row(host : String, path : String, tag : String) : String
        "#{CLI::Output.term_safe(host)}#{CLI::Output.term_safe(path)}\t#{CLI::Output.term_safe(tag)}"
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
        if warning = tag_match_warning(matched, host, key, text)
          STDERR.puts "gori run sitemap tag: warning: #{warning}"
        end
      end

      # Whether any captured endpoint on `host` normalizes to `path`. A tag whose (host, path)
      # names no endpoint is stored but unreachable — it can never stamp onto a tree node. The
      # common causes are a typo and a trailing slash (Sitemap.add drops one, so /api/users/ is
      # stamped as /api/users).
      # The sentence for a tag that could not be confirmed against a captured endpoint, or nil
      # when there is nothing to say. Pure and separate so the three-way answer from
      # `sitemap_node_exists?` reads as three cases rather than as branches inside the
      # command body (which is also what kept its complexity in budget).
      private def self.tag_match_warning(matched : Bool?, host : String, key : String,
                                         text : String) : String?
        return nil if text.empty? || matched
        if matched.nil?
          "tag stored, but there are more than #{Store::SITEMAP_MAX} captured endpoints so " \
          "it could not be confirmed against one — check with `gori run sitemap`"
        else
          "no captured endpoint at #{host}#{key} — this tag will not show in the tree until " \
          "one exists (check for a typo or a trailing slash)"
        end
      end

      # `nil` means UNKNOWN, matching the MCP twin: the scan is capped at SITEMAP_MAX, and
      # that cap counts 6-column transport keys, which multiply past 10k long before the
      # collapsed host/method/target count suggests. Answering a flat `false` off a truncated
      # read made a positive claim about the capture that the query cannot support, and the
      # warning built on it sent the operator hunting for a typo in a tag that was stored and
      # does show.
      private def self.sitemap_node_exists?(store : Store, host : String, path : String) : Bool?
        entries = store.sitemap_entries_detailed(QL::EMPTY, Store::SITEMAP_MAX)
        return true if entries.any? { |e| e.host == host && sitemap_tag_path(e.target) == path }
        entries.size >= Store::SITEMAP_MAX ? nil : false
      end

      # A tag's key is the node path the tree stamps, which Sitemap.normalize_path produces —
      # and that KEEPS the query string ("/login?a=1" is a distinct node from "/login").
      # Normalizing through the same function is what makes a tag set here the one the TUI
      # Sitemap tab shows; stripping the query would file it under a key no node ever has.
      private def self.sitemap_tag_path(target : String) : String
        path = Sitemap.normalize_path(target.strip)
        return "/" if path.empty?
        path.starts_with?('/') ? path : "/#{path}"
      end

      private def self.cmd_sitemap_tree(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        limit = Store::SITEMAP_MAX
        in_scope = false
        group = true
        fold_query = true
        format = :text
        lenient = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap [QL query] [options]\n\n" \
                     "Print the deduplicated host → path endpoint tree built from the captured flows.\n" \
                     "By default the query-string variants of one path fold into a single row\n" \
                     "(/search?q=1 + /search?q=2 → /search); --no-fold-query lists them separately."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter endpoints with a QL query (host: method: path: status: scheme: …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max distinct endpoints to scan (default #{Store::SITEMAP_MAX})") { |v| limit = parse_count(v, "--limit") }
          p.on("--in-scope", "Only hosts in the project's configured scope") { in_scope = true }
          p.on("--no-group", "Don't fold path-param ids (/users/<uuid>, /users/1,2,3…)") { group = false }
          p.on("--lenient", "Don't refuse a query naming an unknown field — search that token as text (old behaviour)") { lenient = true }
          # A SEPARATE axis from --no-group: query folding is about one endpoint requested
          # many ways, id folding about many endpoints sharing a route. Overloading --no-group
          # to mean both would make "show me every literal id" also dump every fuzz payload.
          p.on("--no-fold-query", "Don't fold query-string variants (/search?q=1, /search?q=2) onto their path") { fold_query = false }
          p.on("--format=FMT", "Output: text (default tree) | json | paths") { |v| format = parse_format(v, [:text, :json, :paths]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run sitemap: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # Accept a positional QL too ("gori run sitemap host:api" / "-status:404"), mirroring
        # history's `/` bar. Shared with history through `compose_history_query` rather than
        # re-spelled: the local `query ||= (positional + neg_terms).join` this replaces threw both
        # halves away whenever --query was given, so `sitemap --query='host:x' '-path:/drop'`
        # printed the /drop endpoint the term excluded — a silently BROADER tree, with nothing on
        # STDERR to say a term had gone.
        query, dropped = Run.compose_history_query(query, positional, neg_terms)
        Run.warn_dropped_query_terms("sitemap", dropped)
        if err = Run.reserved_query_verb_error(positional, "sitemap", ["tag"], "tag")
          abort err
        end
        Run.refuse_unknown_query_fields("sitemap", query, lenient)

        # Parse/validate the QL BEFORE opening the store: abort skips ensure blocks, so a
        # bad query must not leave a store handle open.
        filter = sitemap_filter(query)

        store = open_store(resolve_read_project(project_name, db_path),
          read_only: !filter.uses_fts?)
        # A `scope:` term needs the project's scope rules, which are in the store that just
        # opened — so the one term this command cannot compile before the open is recompiled
        # after it. Only when the query actually names the field: nothing else about the filter
        # depends on the lens, so a query without it must not pay a read or a second parse. The
        # validation above already refused everything a query can be refused for, under
        # `QL::SCOPE_SHAPE_ONLY`, which classifies `scope:` terms identically.
        if (q = query) && QL.uses_scope?(q)
          lens = Scope.ql_lens(store)
          filter = QL.parse(q, scope: lens)
          # `--in-scope` on THIS command is host-level and the term is per-flow, so the second
          # note is about two different questions composing rather than one repeated — which is
          # exactly what an operator looking at an empty tree needs to hear.
          Run.scope_query_notes(q, lens, in_scope).each { |n| STDERR.puts "gori run sitemap: #{n}" }
        end
        # The `--query body:…` drain (see `fts_backlog_error`), and it lives HERE rather than in
        # `collect_sitemap` for the wording: the rescue just below frames everything it catches
        # as `query … failed`, and a busy writer is not a bad query — it is a tree with endpoints
        # missing from it, which is the one thing a sitemap must not be silent about.
        if err = fts_backlog_error(store, filter,
             "#{query.inspect} would leave endpoints out of the tree with nothing saying so. " \
             "Nothing was printed;")
          store.close
          abort "gori run sitemap: #{err}"
        end
        hosts, truncated = begin
          collect_sitemap(store, filter, limit, in_scope, group, fold_query)
        rescue ex
          abort "gori run sitemap: query #{query.inspect} failed: #{ex.message}"
        ensure
          store.close
        end

        emit_sitemap(hosts, format, truncated, limit)
      end

      # QL.parse + the same un-compilable-query rejection as history (a non-blank query
      # collapsing to EMPTY would silently dump every endpoint).
      private def self.sitemap_filter(query : String?) : QL::Filter
        return QL::EMPTY unless q = query
        # Shape-only: this runs before the store is open (see the caller), and a `scope:` term
        # compiles to a real clause under either lens. `scope:` on this command is per-FLOW,
        # which is NOT what `--in-scope` asks here (whole hosts, via `host_in_scope?` — see
        # `collect_sitemap`); both are available and they are different questions.
        filter = QL.parse(q, scope: QL::SCOPE_SHAPE_ONLY)
        # Both halves — an unrecognized field is dropped and BROADENS the tree. See
        # Run.warn_query_terms.
        Run.warn_query_terms("sitemap", q)
        if !q.strip.empty? && filter == QL::EMPTY
          abort "gori run sitemap: query #{q.inspect} did not match any field (check syntax, e.g. host:example.com method:POST path:/api status:>=500)"
        end
        filter
      end

      # Build + post-process the tree from the open store in the SAME ORDER as
      # SitemapView#reload (build → tags → scope → id folds → query fold → counts). The scope step
      # differs by design: --in-scope filters whole hosts via Scope#host_in_scope?,
      # which evaluates the rules regardless of the TUI's persisted ⇧S enabled flag
      # (an explicit --in-scope is the opt-in). That host-level gate is coarser than
      # the TUI lens's per-flow SQL filter and conservative on url-level includes.
      private def self.collect_sitemap(store : Store, filter : QL::Filter, limit : Int32,
                                       in_scope : Bool, group : Bool,
                                       fold_query : Bool) : {Array(Sitemap::Node), Bool}
        # A `--query body:…` filter arrives here already drained and CHECKED — see
        # `cmd_sitemap_tree`, which refuses outright when the off-commit trigram index (Store V4)
        # is still behind.
        # The drain used to sit on this line, where a leftover backlog had no way to be reported.
        entries = store.sitemap_entries(filter, limit, raise_on_error: true)
        # Measured HERE, on the raw read, and not after the folds: every step below collapses
        # rows, so by the time the tree exists the cut is invisible. Same test as
        # `Diff::Snapshot` (`rows.size >= limit`) — the read is capped, not cursored, so a
        # group that lost the cut is not on a later page, it is simply absent.
        truncated = entries.size >= limit
        hosts = Sitemap.build(entries)
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
        # Queries LAST and on their own switch, so the id passes above see the literal
        # children they always did (/items/7?ref=home still joins the /items/7 numeric run).
        hosts.each { |h| Sitemap.fold_queries!(h) } if fold_query
        hosts.each { |h| h.endpoints = Sitemap.endpoint_count(h) }
        {hosts, truncated}
      end

      # The sentence for a tree built off a capped read, or nil when the read was complete.
      # Pure and separate for the same reason `tag_match_warning` is: a capped read is the one
      # thing this tree must not be silent about, because the per-host `(N paths)` header is
      # counted off whatever survived the cut — so a truncated run makes a POSITIVE and wrong
      # claim about the project's endpoints. The cap counts 6-column transport keys (see
      # `sitemap_node_exists?`), which multiply past the default long before the collapsed row
      # count suggests, so this fires on real engagements rather than on a pathological one.
      private def self.sitemap_truncation_notice(truncated : Bool, limit : Int32) : String?
        return nil unless truncated
        "TRUNCATED — the scan stopped at the --limit of #{limit} endpoint keys, so hosts are " \
        "missing and every '(N paths)' count is a count of the partial read, not of the " \
        "project. Raise -n/--limit or narrow the query."
      end

      # Results → STDOUT; the empty-state and truncation notes → STDERR (STDOUT-purity). JSON
      # always emits a (possibly empty) array so scripts get valid JSON either way.
      private def self.emit_sitemap(hosts : Array(Sitemap::Node), format : Symbol,
                                    truncated : Bool, limit : Int32) : Nil
        if note = sitemap_truncation_notice(truncated, limit)
          STDERR.puts "gori run sitemap: #{note}"
        end
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
