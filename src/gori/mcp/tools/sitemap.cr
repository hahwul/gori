require "json"
require "../../ql"
require "../../sitemap"
require "../../param_inventory"
require "../../export/openapi"
require "../../import/oas"
require "../../durable_file"
require "../serialize"

module Gori
  module MCP
    class Tools
      # 50, not the 200 it was (#1394): a list_sitemap row carries its observations, and 200 of
      # them was ~90 KB of an agent's context on a call it makes to get its bearings. `has_more`
      # and `offset` page the rest.
      SITEMAP_LIMIT = PageLimit.new(50, 5000)

      @[Tool("list_sitemap")]
      private def list_sitemap(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), SITEMAP_LIMIT)
        offset = (optional_int_arg(h, "offset") || 0_i64).clamp(0_i64, Int32::MAX.to_i64).to_i
        # `tag:` is the sitemap's own field, not QL's (`Sitemap.split_tag_terms`, the cut the TUI
        # bar and `gori run sitemap` make): only the QL half is compiled, refused or reported.
        terms = Sitemap.split_tag_terms(str(h, "query") || "")
        dropped = [] of String
        filter = ql_filter_or_error(h, terms.ql, dropped)
        return filter if filter.is_a?(Result)
        # Per-flow, like the TUI tree's lens: a host keeps its non-static endpoints.
        filter = QL.and(filter, QL.hide_static) if bool_arg(h, "hide_static", false)
        # Same reason as list_history: a `body:` query reads the off-commit trigram index
        # (Store V4), and an agent can't distinguish "absent" from "not indexed yet".
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        unrequested = bool_arg(h, "include_unrequested", false)
        untested = bool_arg(h, "untested", false)
        if bool_arg(h, "collapse_transport", false)
          # Refused rather than dropped: an answer without the block reads as "no references".
          return err("include_unrequested is not available with collapse_transport — call without it, or use list_js_endpoints",
            "INVALID_ARGUMENT", field: "include_unrequested") if unrequested
          # Coverage is keyed by origin, which a collapsed row no longer carries.
          return err("untested is not available with collapse_transport — call without it",
            "INVALID_ARGUMENT", field: "untested") if untested
          return collapsed_sitemap(filter, limit, offset, dropped, terms)
        end
        tags = store.sitemap_tags
        coverage = Sitemap::Coverage.load(store)
        rows, has_more, tag_capped = sitemap_page(filter, limit, offset, terms, tags, untested ? coverage : nil)
        # Folded by DEFAULT, matching `gori run sitemap` and the TUI tree: an agent mapping a
        # surface should not read one entry per fuzz payload. `fold_query:false` is the twin
        # of the CLI's --no-fold-query.
        fold = bool_arg(h, "fold_query", true)
        entries = fold_query_entries(rows, fold)
        parts = fit_rows(entries) { |rj, e, _| sitemap_entry_json(rj, e, tags, coverage) }
        # Under REPLY_ROWS_BUDGET (#1649). The cut is made in RAW rows, because `offset` pages
        # raw rows and a folded entry stands for several: the page shrinks until its entries fit,
        # and `scanned` — what the caller advances `offset` by — shrinks with it. Each pass keeps
        # fewer rows, and one row always fits, so this ends.
        cut = false
        while parts.size < entries.size
          cut = has_more = true
          rows = rows.first((rows.size * parts.size // entries.size).clamp(1, rows.size - 1))
          entries = fold_query_entries(rows, fold)
          parts = fit_rows(entries) { |rj, e, _| sitemap_entry_json(rj, e, tags, coverage) }
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "returned", entries.size
            j.field "scanned", rows.size
            j.field "offset", offset
            j.field "limit", limit
            j.field "has_more", has_more
            emit_cut(j, cut)
            emit_ignored_terms(j, dropped)
            emit_tag_capped(j, tag_capped)
            # Endpoints captured JavaScript references and no request reached (#1243). NOT
            # entries: an entry is a captured transport key with counts, and these have none —
            # mixing them in would also make `has_more`/`offset` page two different things.
            emit_unrequested(j, parts.sum(&.bytesize)) if unrequested
            j.field("entries") { raw_rows(j, parts) }
          end
        end)
      end

      # One `list_sitemap` entry: the transport key, the fold's variants, counts, seen window
      # and the operator's memo.
      private def sitemap_entry_json(j : JSON::Builder, e : SitemapRow, tags : Hash({String, String}, String),
                                     coverage : Sitemap::Coverage) : Nil
        j.object do
          j.field "scheme", Serialize.text(e.scheme)
          j.field "host", Serialize.text(e.host)
          j.field "port", e.port
          j.field "http_version", Serialize.text(e.http_version)
          j.field "method", Serialize.text(e.method)
          j.field "target", Serialize.text(e.target)
          # Same builder as a flow's `url` and the TUI tree's copy (#1562).
          j.field "url", Serialize.text(Store::FlowRow.url_of(e.scheme, e.host, e.port, e.target))
          # Present only on a FOLDED row: how many distinct query strings it stands
          # for, and up to QUERY_SAMPLE_MAX of the raw targets, so a replay still has
          # a concrete one to send (`target` alone dropped the query).
          if e.query_variants > 0
            j.field "query_variants", e.query_variants
            j.field "query_targets" do
              j.array { e.query_targets.first(QUERY_SAMPLE_MAX).each { |t| j.string Serialize.text(t) } }
            end
            emit_variant_tags(j, e, tags)
          end
          j.field "statuses", e.statuses
          j.field "count", e.count
          j.field "success_count", e.ok
          j.field "error_count", e.errors
          j.field "first_seen", e.first_seen
          j.field "first_seen_iso", Gori.iso_micros(e.first_seen)
          j.field "last_seen", e.last_seen
          j.field "last_seen_iso", Gori.iso_micros(e.last_seen)
          # Active tool → count of recorded flows / saved fuzz results, keyed by the path
          # without its query (`Sitemap::Coverage`).
          if touched = coverage.touched_by(e.scheme, e.host, e.port, e.method, e.target)
            j.field "touched_by", touched
          end
          # The operator's free-text memo for this endpoint, when one is pinned. The key
          # is the tree's node path, which includes any query string.
          # NOT on a folded row, which is synthetic: `Sitemap.stamp_tags!` bars a tag on
          # a `grouped` node ("the tag key is the path WITH the query", fold_queries_node!),
          # so the TUI tree and `gori run sitemap` both leave it bare — and this stamped
          # one anyway, which made set_sitemap_tag's "will not show in list_sitemap or
          # the TUI" warning a lie about half of itself. The tags on a fold's variants
          # are keyed by the path WITH the query and ride `variant_tags` above, exactly
          # as a `{uuid}` fold's children keep their own; list_sitemap_tags (or
          # fold_query:false) is where the rest show.
          if e.query_variants == 0 && (tag = tags[{e.host, Sitemap.tag_path(e.target)}]?)
            j.field "tag", Serialize.text(tag)
          end
        end
      end

      # Pin (or clear) a free-text memo on one sitemap endpoint — the TUI Sitemap tab's `t`.
      @[Tool("set_sitemap_tag", gated: true, agent_action: true, permission: "write")]
      private def set_sitemap_tag(h) : Result
        host = required_str(h, "host")
        path = str(h, "path").try(&.strip).presence
        return err("missing required 'path' (the path as list_sitemap shows it, e.g. /api/users or /login?a=1)",
          "INVALID_ARGUMENT", field: "path") unless path
        # Normalize exactly as the Sitemap tree stamps node paths (query string INCLUDED).
        path = Sitemap.tag_path(path)
        tag = (str(h, "tag") || "").strip
        # A tag whose (host, path) names no captured endpoint is stored but unreachable — it
        # can never stamp onto a tree node or a list_sitemap entry. Report that rather than
        # answering a flat success: the common causes are a typo and a trailing slash
        # (Sitemap.add drops one, so /api/users/ is stamped as /api/users).
        matched = store.sitemap_node_exists?(host, path)
        return busy("tag NOT applied (store busy or unwritable); the node is unchanged") unless store.set_sitemap_tag(host, path, tag)
        Result.new(JSON.build do |j|
          j.object do
            j.field "host", host
            j.field "path", path
            j.field "tag", tag.presence
            j.field "cleared", tag.empty?
            j.field "matches_endpoint", matched
            if matched == false && !tag.empty? && JsRefs.unrequested_node?(store, host, path)
              j.field "warning", "no captured endpoint at #{host}#{path} — the tag shows on its JavaScript-referenced node (the TUI Sitemap, `gori run sitemap --js-refs`), not in list_sitemap entries"
            elsif matched == false && !tag.empty?
              j.field "warning", "no captured endpoint at #{host}#{path} — this tag will not show in list_sitemap or the TUI until one exists (check for a typo or a trailing slash)"
            elsif matched.nil? && !tag.empty?
              j.field "warning", "tag stored, but there are more than #{Store::SITEMAP_MAX} captured endpoints so it could not be confirmed against one — check with list_sitemap"
            end
          end
        end)
      end

      @[Tool("list_sitemap_tags")]
      private def list_sitemap_tags(h) : Result
        host = str(h, "host").try(&.strip).presence
        tags = store.sitemap_tags
        items_result(JSON.build do |j|
          j.array do
            tags.each do |(hst, path), tag|
              next if host && !hst.compare(host, case_insensitive: true).zero?
              {
                host: Serialize.text(hst),
                path: Serialize.text(path),
                tag:  Serialize.text(tag),
              }.to_json(j)
            end
          end
        end)
      end

      # At most this many raw targets are carried on a folded row. A folded /search can stand
      # for thousands of fuzz payloads; the sample exists so a replay has a concrete target to
      # send, not to reproduce the list the fold was asked to collapse (`fold_query:false`
      # does that).
      QUERY_SAMPLE_MAX = 5

      # One list_sitemap row: a Store::SitemapEntry plus what a QUERY fold merged onto it.
      # A mutable class rather than a `record` because folding accumulates across rows, and
      # one shape for both modes so the emitter has no union to branch on.
      class SitemapRow
        getter scheme : String
        getter host : String
        getter port : Int32
        getter http_version : String
        getter method : String
        getter target : String
        getter statuses : String?
        getter count : Int64
        getter ok : Int64
        getter errors : Int64
        getter first_seen : Int64
        getter last_seen : Int64
        # Every raw target whose query string this row stands for — empty when nothing was
        # folded onto it. Bounded by the caller's `limit`, since each one came from an entry
        # the query already returned. Only a SAMPLE is emitted (QUERY_SAMPLE_MAX), but the
        # whole list is what the operator's pinned tags are looked up against, so a memo on
        # /search?q=1 still surfaces on the folded row.
        getter query_targets : Array(String)

        def initialize(e : Store::SitemapEntry)
          @scheme = e.scheme
          @host = e.host
          @port = e.port
          @http_version = e.http_version
          @method = e.method
          @target = e.target
          @statuses = e.statuses
          @count = e.count
          @ok = e.ok
          @errors = e.errors
          @first_seen = e.first_seen
          @last_seen = e.last_seen
          @query_targets = [] of String
        end

        # Merge another transport-identical entry whose path matches, differing only by its
        # query string. Counts SUM, statuses union, the seen window widens — the row now
        # answers for every variant, which is what the fold claims.
        def fold!(e : Store::SitemapEntry, path : String) : Nil
          @target = path
          @statuses = SitemapRow.merge_statuses(@statuses, e.statuses)
          @count += e.count
          @ok += e.ok
          @errors += e.errors
          @first_seen = e.first_seen if e.first_seen < @first_seen
          @last_seen = e.last_seen if e.last_seen > @last_seen
          @query_targets << e.target
        end

        # This row itself carried the query (it was the first of its group seen).
        def claim_own_query!(path : String) : Nil
          @query_targets << @target
          @target = path
        end

        # How many distinct query strings this row stands for; 0 = nothing folded onto it.
        def query_variants : Int32
          @query_targets.size
        end

        # GROUP_CONCAT(DISTINCT status) from two groups → one deduplicated list, first-seen
        # order. NULL on either side is "no outcome recorded yet", not an empty set.
        def self.merge_statuses(a : String?, b : String?) : String?
          return b unless a
          return a unless b
          seen = a.split(',')
          b.split(',').each { |st| seen << st unless seen.includes?(st) }
          seen.join(',')
        end
      end

      # The operator's memos on the variants a folded row stands for, as [{path, tag}]. The
      # fold itself is synthetic and holds no tag (its `tag` field is the memo on the PATH,
      # if any) — but a tag pinned on /search?q=1 is high-signal, and dropping it from the
      # default view would mean folding LOST information rather than compacting it. Capped
      # like the target sample; `list_sitemap_tags` is the complete list.
      private def emit_variant_tags(j : JSON::Builder, row : SitemapRow,
                                    tags : Hash({String, String}, String)) : Nil
        found = [] of {String, String}
        row.query_targets.each do |t|
          break if found.size >= QUERY_SAMPLE_MAX
          path = Sitemap.tag_path(t)
          if tag = tags[{row.host, path}]?
            found << {path, tag}
          end
        end
        return if found.empty?
        j.field "variant_tags" do
          j.array do
            found.each do |(path, tag)|
              {path: Serialize.text(path), tag: Serialize.text(tag)}.to_json(j)
            end
          end
        end
      end

      # Fold the query-string variants of one endpoint onto its path — the flat-list twin of
      # `Sitemap.fold_queries!`, and the same default. Rows are keyed by the full TRANSPORT
      # tuple plus the path, so http vs https vs h2 stay separate exactly as they do unfolded.
      #
      # A row with no query keeps its target VERBATIM (an absolute-form target is not rewritten
      # when nothing folded onto it); a row that stands for ≥1 query string reports the
      # path-only target, with the raw ones in `query_targets`.
      private def fold_query_entries(entries : Array(Store::SitemapEntry), fold : Bool) : Array(SitemapRow)
        rows = [] of SitemapRow
        return entries.map { |e| SitemapRow.new(e) } unless fold
        index = {} of String => SitemapRow
        entries.each do |e|
          full = Sitemap.tag_path(e.target)
          qi = full.index('?')
          path = qi ? full[0...qi] : full
          path = "/" if path.empty?
          key = "#{e.scheme}\u0000#{e.host}\u0000#{e.port}\u0000#{e.http_version}\u0000#{e.method}\u0000#{path}"
          if row = index[key]?
            row.fold!(e, path)
            next
          end
          row = SitemapRow.new(e)
          row.claim_own_query!(path) if qi
          index[key] = row
          rows << row
        end
        rows
      end

      # One page of endpoint rows, whether it ran into `has_more`, and whether a tag filter's
      # read hit its cap (`tag_filtered_page`).
      private def sitemap_page(filter : QL::Filter, limit : Int32, offset : Int32, terms : Sitemap::TagTerms,
                               tags : Hash({String, String}, String),
                               untested : Sitemap::Coverage?) : {Array(Store::SitemapEntry), Bool, Bool}
        if terms.filtering? || untested
          # Before the query fold, as the tree prunes before it folds. `untested` drops on the
          # whole endpoint like `tag:`, so it pages the same way.
          all = store.sitemap_entries_detailed(filter, Store::SITEMAP_MAX)
          kept = Sitemap.select_by_tags(all, tags, terms) { |e| Store::SitemapOriginEntry.new(e.scheme, e.host, e.port, e.method, e.target) }
          kept = kept.reject { |e| untested.touched?(e.scheme, e.host, e.port, e.method, e.target) } if untested
          return tag_filtered_page(all, kept, limit, offset)
        end
        # One row OVER the page, then dropped: `has_more` costs a row instead of a second
        # COUNT(*) over the same GROUP BY. Without it a full page and an exactly-full set are
        # the same answer, and this tool — unlike list_history — has no id cursor an agent
        # could probe with, so "200 endpoints" silently stood for a surface of any size.
        rows = store.sitemap_entries_detailed(filter, limit + 1, offset: offset)
        has_more = rows.size > limit
        {has_more ? rows.first(limit) : rows, has_more, false}
      end

      # A `tag:` query's page. The tag filter cannot run on a page: whether an endpoint survives
      # depends on the rows around it (a tagged `/api` keeps `/api/users`, a tagged
      # `/api/users` keeps an `/api` endpoint above it), and pruning a page would also leave
      # `has_more` counting rows the filter then threw away. So the rows are read whole, up to
      # `Store::SITEMAP_MAX`, filtered, and paged here; the third value says the read hit that
      # cap.
      private def tag_filtered_page(all : Array(T), kept : Array(T), limit : Int32,
                                    offset : Int32) : {Array(T), Bool, Bool} forall T
        page = kept[offset, limit + 1]? || [] of T
        has_more = page.size > limit
        {has_more ? page.first(limit) : page, has_more, all.size >= Store::SITEMAP_MAX}
      end

      # Written only when the read hit the cap, as `emit_ignored_terms` is only when a term dropped.
      private def emit_tag_capped(j : JSON::Builder, capped : Bool) : Nil
        return unless capped
        j.field "tag_filter_capped", true
        j.field "tag_filter_note",
          "the tag:/untested filter read only the first #{Store::SITEMAP_MAX} endpoint keys, so matching " \
          "endpoints past them are missing — narrow the rest of the query (host:, path:) to reach them"
      end

      # The legacy collapsed sitemap (distinct host/method/target only), for
      # collapse_transport:true. Its `tag:` terms prune the HOST-level tree, the one these
      # host-keyed rows make.
      private def collapsed_sitemap(filter : QL::Filter, limit : Int32, offset : Int32,
                                    dropped : Array(String), terms : Sitemap::TagTerms) : Result
        tag_capped = false
        if terms.filtering?
          all = store.sitemap_entries(filter, Store::SITEMAP_MAX)
          kept = Sitemap.select_by_tags(all, store.sitemap_tags, terms) { |e| e }
          entries, has_more, tag_capped = tag_filtered_page(all, kept, limit, offset)
        else
          entries = store.sitemap_entries(filter, limit + 1, offset: offset)
          has_more = entries.size > limit
          entries = entries.first(limit) if has_more
        end
        parts = fit_rows(entries) do |rj, (host, method, target), _|
          {host: Serialize.text(host), method: Serialize.text(method), target: Serialize.text(target)}.to_json(rj)
        end
        cut = parts.size < entries.size
        has_more ||= cut
        Result.new(JSON.build do |j|
          j.object do
            j.field "returned", parts.size
            j.field "offset", offset
            j.field "limit", limit
            j.field "has_more", has_more
            emit_cut(j, cut)
            emit_ignored_terms(j, dropped)
            emit_tag_capped(j, tag_capped)
            j.field("entries") { raw_rows(j, parts) }
          end
        end)
      end

      # 50 for the reason `SITEMAP_LIMIT` is: each row carries its sample values.
      PARAMS_LIMIT = PageLimit.new(50, 2000)

      # The parameter inventory (#1231) — one call instead of paging list_history + get_flow
      # to learn what inputs a target takes. Read-only and recomputed per call (P6); see
      # `ParamInventory` for what "reflected" does and does not claim.
      @[Tool("list_params")]
      private def list_params(h) : Result
        pg = page_args(h, PARAMS_LIMIT)
        query = str(h, "query")
        dropped = [] of String
        filter = ql_filter_or_error(h, query, dropped)
        return filter if filter.is_a?(Result)
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        locations = begin
          params_locations(h)
        rescue ex : Gori::Error
          return err(ex.message || "invalid 'location'", "INVALID_ARGUMENT", field: "location")
        end
        # Per-flow scope, the lens list_history's `in_scope` applies; unconfigured = nothing is
        # in scope, said in a note rather than as an unexplained empty list.
        scope_unconfigured = false
        if bool_arg(h, "in_scope", false)
          scope = Scope.load(store)
          if scope.configured?
            filter = QL.and(scope.filter(force: true), filter)
          else
            scope_unconfigured = true
          end
        end
        # The TUI Params sub-tab follows the hide-static lens; this is it, asked for explicitly.
        filter = QL.and(filter, QL.hide_static) if bool_arg(h, "hide_static", false)
        include_sensitive = bool_arg(h, "include_sensitive", false)
        narrow = origin_arg(h)
        return narrow if narrow.is_a?(Result)
        host, scheme, port = narrow
        report = if scope_unconfigured
                   ParamInventory::Report.new([] of ParamInventory::Row, 0, false)
                 else
                   opts = ParamInventory::Options.new(filter: filter, host: host, scheme: scheme, port: port,
                     path_prefix: str(h, "path_prefix"), locations: locations,
                     all_headers: bool_arg(h, "all_headers", false),
                     max_flows: clamp(optional_int_arg(h, "max_flows"), 2000, 20_000),
                     samples: clamp(optional_int_arg(h, "samples"), 5, 50))
                   ParamInventory.build(store, opts)
                 end
        rows = report.rows
        page = rows[pg.offset, pg.limit]? || [] of ParamInventory::Row
        parts = fit_rows(page) { |rj, r, _| param_row(rj, r, include_sensitive) }
        cut = parts.size < page.size
        page = page.first(parts.size)
        Result.new(JSON.build do |j|
          j.object do
            j.field("params") { raw_rows(j, parts) }
            emit_page(j, pg, page.size, rows.size, cut: cut)
            emit_ignored_terms(j, dropped)
            j.field "flows_scanned", report.flows_scanned
            # The flow cap, not the page: parameters on OLDER flows are absent from `total`.
            j.field "truncated", report.truncated
            j.field "rows_capped", report.rows_capped
            j.field "sensitive_values_redacted", !include_sensitive
            if note = list_params_note(report, scope_unconfigured)
              j.field "note", note
            end
          end
        end)
      end

      private def list_params_note(report : ParamInventory::Report, scope_unconfigured : Bool) : String?
        if scope_unconfigured
          "in_scope:true but no scope rules are configured — nothing is in scope"
        elsif report.rows_capped
          "stopped at #{report.rows.size} parameter rows (the row cap) after " \
          "#{report.flows_scanned} flows — narrow the query, host or path_prefix"
        elsif report.truncated
          "read the newest #{report.flows_scanned} flows (max_flows); older flows " \
          "are not in this inventory — raise max_flows or narrow the query"
        end
      end

      # The captured API as an OpenAPI 3.0.3 document (#1241), inline — "summarize this API" in
      # one call instead of paging list_sitemap + get_flow. Read-only and recomputed per call
      # (P6). Bounded twice, because it lands in the agent's context: `max_endpoints` caps the
      # operations the engine keeps, `max_bytes` the serialized document (whole paths are
      # dropped from the end, `Export::OpenApi.fit`), and `truncated` says either happened.
      #
      # …unless `output_path` writes it to a file instead (#1394), and then it does NOT land in
      # the agent's context: the reply carries the path and the report, and `max_bytes` defaults
      # to its ceiling. That makes this read tool a writer for that call — refused under
      # --read-only, behind the `write` permission, and logged as an agent action
      # (`call_denied_permission`, `agent_action?`) — hence `read_only: false`.
      @[Tool("export_openapi", read_only: false)]
      private def export_openapi(h) : Result
        ignored = [] of String
        filter = openapi_filter(h, ignored)
        return filter if filter.is_a?(Result)
        destination = openapi_destination(h)
        return destination if destination.is_a?(Result)
        yaml = openapi_yaml?(h, destination)
        return yaml if yaml.is_a?(Result)
        examples = bool_arg(h, "examples", false)
        choice = openapi_redactor(h, examples)
        return choice if choice.is_a?(Result)
        narrow = origin_arg(h)
        return narrow if narrow.is_a?(Result)
        host, scheme, port = narrow
        opts = Export::OpenApi::Options.new(filter: filter, host: host, scheme: scheme, port: port,
          path_prefix: str(h, "path_prefix"),
          max_flows: clamp(optional_int_arg(h, "max_flows"), 5000, 20_000),
          max_samples: clamp(optional_int_arg(h, "max_samples"), 10, 50),
          max_endpoints: clamp(optional_int_arg(h, "max_endpoints"), 200, 2000),
          examples: examples, redactor: choice.try(&.matcher), include_gori: bool_arg(h, "include_gori", false))
        result = Export::OpenApi.build(store, opts)
        max_bytes = clamp(optional_int_arg(h, "max_bytes"), destination ? OPENAPI_MAX_BYTES : OPENAPI_INLINE_BYTES, OPENAPI_MAX_BYTES)
        doc, dropped = Export::OpenApi.fit(result.doc, max_bytes)
        result.report.paths_dropped = dropped
        return Result.new(openapi_json(doc, result.report, yaml, choice, ignored)) unless destination
        text = yaml ? Export::OpenApi.to_yaml(doc) : Export::OpenApi.to_json(doc)
        begin
          DurableFile.write(destination, text, perm: File::Permissions.new(0o644))
        rescue ex : File::Error | IO::Error
          return err("could not write the OpenAPI document: #{ex.message}", "INVALID_ARGUMENT", field: "output_path")
        end
        Result.new(openapi_json(doc, result.report, yaml, choice, ignored, written: {destination, text.bytesize}))
      end

      # The inline document's default size cap, and the ceiling either way. Inline is the reply
      # budget (#1659): `output_path` is where the rest of a larger document goes.
      OPENAPI_INLINE_BYTES = REPLY_ROWS_BUDGET
      OPENAPI_MAX_BYTES    = 2 * 1024 * 1024

      # Where `output_path` asks the document to go, resolved; nil when the call wants it
      # inline; or the refusal. The rules are `export_project`'s, the one other MCP tool that
      # writes a file an agent names: the parent directory must exist, a directory or an
      # existing file is refused unless `overwrite:true` (and a directory always), a symlink is
      # written THROUGH (`DurableFile`), and gori's home — every project's database and the
      # settings — is off limits.
      private def openapi_destination(h) : (String | Result)?
        # Blank is absent: a client that fills every property sends `output_path: ""` with the
        # inline document in mind (`describes?`).
        return nil unless describes?(h, "output_path")
        raw = str(h, "output_path").try(&.strip).presence
        return err("'output_path' is blank", "INVALID_ARGUMENT", field: "output_path") unless raw
        unless @allow_actions
          return err("output_path writes a file (disabled by gori mcp --read-only); drop it to get the document inline",
            "TOOL_DISABLED", field: "output_path")
        end
        overwrite = bool_arg(h, "overwrite", false)
        target = Path[raw].expand(home: true).to_s
        # A symlink is judged — and written — at what it points to (`DurableFile` writes
        # through it), so resolve it first; one that points nowhere cannot be judged at all.
        if File.symlink?(target)
          return err("output_path is a symlink to nothing: #{target}", "INVALID_ARGUMENT", field: "output_path") unless File.exists?(target)
          target = File.realpath(target)
        end
        return err("output_path is a directory: #{target}", "INVALID_ARGUMENT", field: "output_path") if File.directory?(target)
        parent = File.dirname(target)
        return err("no such directory: #{parent}", "INVALID_ARGUMENT", field: "output_path") unless Dir.exists?(parent)
        if Paths.within?(Paths.canonical_file(target), Paths.canonical_file(Paths.home_dir))
          return err("refusing to write inside gori's home (#{Paths.home_dir}): it holds every project's database " \
                     "and gori's settings — choose an output_path outside it", "INVALID_ARGUMENT", field: "output_path")
        end
        if File.exists?(target)
          unless overwrite
            return err("output_path already exists: #{target} — pass overwrite:true to replace it, or choose another path",
              "INVALID_ARGUMENT", field: "output_path")
          end
          if refusal = openapi_replace_refusal(target)
            return refusal
          end
        end
        target
      end

      # Why `overwrite:true` may not replace the existing *target*, or nil.
      private def openapi_replace_refusal(target : String) : Result?
        # A loose `--db` project lives anywhere; replacing one a gori has open would unlink a
        # live database. `export_project` refuses the same target.
        if OpenLock.in_use?(target)
          return err("output_path is a database open in a running gori instance: #{target}",
            "INVALID_ARGUMENT", field: "output_path")
        end
        # The agent named this path, so `overwrite` replaces only what this tool writes —
        # never `~/.ssh/id_ed25519` (export_project draws the same line for archives).
        return nil if Import::Oas.document?(target, OPENAPI_MAX_BYTES)
        err("output_path exists and is not an OpenAPI document: #{target} — overwrite:true " \
            "replaces only an earlier export; choose another path", "INVALID_ARGUMENT", field: "output_path")
      end

      # The flow set: the QL query, then the per-flow scope and hide-static lenses. Unconfigured
      # scope is refused rather than answered with an empty document.
      private def openapi_filter(h, ignored : Array(String)) : QL::Filter | Result
        filter = ql_filter_or_error(h, str(h, "query"), ignored)
        return filter if filter.is_a?(Result)
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        if bool_arg(h, "in_scope", false)
          scope = Scope.load(store)
          unless scope.configured?
            return err("in_scope:true but no scope rules are configured — nothing is in scope; " \
                       "#{add_scope_rule_hint} or drop in_scope", "INVALID_ARGUMENT", field: "in_scope")
          end
          filter = QL.and(scope.filter(force: true), filter)
        end
        bool_arg(h, "hide_static", false) ? QL.and(filter, QL.hide_static) : filter
      end

      # `format`, or — when it is not given and the document goes to a file — the file's
      # extension, the way the TUI's export picks it (`.yaml`/`.yml` → YAML).
      private def openapi_yaml?(h, destination : String? = nil) : Bool | Result
        case f = str(h, "format").try(&.strip.downcase)
        when nil, ""
          !!destination.try { |d| {".yaml", ".yml"}.includes?(File.extname(d).downcase) }
        when "json" then false
        when "yaml" then true
        else             err("unknown format #{f.inspect} (json|yaml)", "INVALID_ARGUMENT", field: "format")
        end
      end

      # The profile examples pass through, resolved the way every sanitized surface resolves
      # one; nil when examples are off. A profile named without examples is refused: it would
      # read as "the document was sanitized" while changing nothing.
      private def openapi_redactor(h, examples : Bool) : Redact::Policy::Choice? | Result
        profile = str(h, "redact")
        unless examples
          return nil unless profile
          return err("`redact` names the profile examples pass through — set examples:true",
            "INVALID_ARGUMENT", field: "redact")
        end
        choice = Redact::Policy.resolve(store, profile, on: true)
        if e = choice.error
          return err(e, "INVALID_ARGUMENT", field: "redact")
        end
        choice
      end

      # What the CLI says on stderr, said in `notes`: the report's sentences, plus the two facts
      # about the redaction itself — a profile pattern that did not compile (so a rule silently
      # did not run) and a salt that could not be saved (so placeholders do not correlate).
      private def openapi_notes(report : Export::OpenApi::Report, choice : Redact::Policy::Choice?) : Array(String)
        notes = report.notes
        return notes unless c = choice
        c.matcher.try &.pattern_errors.each { |e| notes << "redaction pattern skipped, it does not compile — #{e}" }
        notes << "the placeholder salt could not be saved, so these tags will NOT match another session's" unless c.salt_persisted
        notes
      end

      # `written` is {path, bytes} when the document went to a file instead of into the reply.
      private def openapi_json(doc : JSON::Any, report : Export::OpenApi::Report, yaml : Bool,
                               choice : Redact::Policy::Choice?, ignored : Array(String),
                               written : {String, Int32}? = nil) : String
        paths = doc["paths"]?.try(&.as_h?) || {} of String => JSON::Any
        JSON.build do |j|
          j.object do
            j.field "format", yaml ? "yaml" : "json"
            if w = written
              j.field "output_path", w[0]
              j.field "bytes_written", w[1]
            else
              j.field "document" do
                yaml ? j.string(Export::OpenApi.to_yaml(doc)) : doc.to_json(j)
              end
            end
            j.field "paths", paths.size
            j.field "operations", paths.sum { |_, item| item.as_h.keys.count { |k| k != "servers" } }
            j.field "hosts", report.hosts.map { |x| Serialize.text(x) }
            j.field "flows_read", report.flows_read
            j.field "truncated", report.truncated?
            j.field("skipped") { j.object { report.skipped.each { |k, v| j.field k.key, v } } }
            notes = openapi_notes(report, choice)
            if !written && report.paths_dropped > 0
              notes << "raise max_bytes (up to #{OPENAPI_MAX_BYTES}) or pass output_path for the whole document"
            end
            j.field "notes", notes
            j.field "examples_redacted", report.redacted if choice
            emit_ignored_terms(j, ignored)
          end
        end
      end

      # `origin` (list_params, export_openapi, #1371) → {host, scheme, port}: one Sitemap root, as
      # `list_sitemap` entries name it. The CLI's `--origin` twin, parsed by the same
      # `Settings.parse_origin`, and refused beside a `host` rather than choosing between them.
      private def origin_arg(h) : {String?, String?, Int32?} | Result
        host = str(h, "host")
        return {host, nil, nil} unless raw = str(h, "origin").try(&.strip).presence
        if host.try(&.strip).presence
          return err("pass host or origin, not both — origin names the host too", "INVALID_ARGUMENT", field: "origin")
        end
        unless parts = Settings.parse_origin(raw)
          return err("invalid origin #{raw.inspect} — expected http(s)://host[:port]", "INVALID_ARGUMENT", field: "origin")
        end
        scheme, origin_host, port = parts
        {origin_host.as(String?), scheme.as(String?), port.as(Int32?)}
      end

      private def param_row(j : JSON::Builder, r : ParamInventory::Row, include_sensitive : Bool) : Nil
        j.object do
          # The origin, not only the host (#1371): `list_sitemap` entries carry scheme/port,
          # and two services on one host keep separate parameter rows.
          j.field "scheme", Serialize.text(r.scheme)
          j.field "host", Serialize.text(r.host)
          j.field "port", r.port
          j.field "method", Serialize.text(r.method)
          j.field "path", Serialize.text(r.path)
          j.field "location", r.location.label
          j.field "name", Serialize.text(r.name)
          j.field "count", r.count
          j.field "samples", ParamInventory.masked(r, include_sensitive).map { |v| Serialize.text(v) }
          j.field "samples_truncated", r.samples_truncated
          j.field "sensitive", r.sensitive
          j.field "first_flow_id", r.first_flow_id
          j.field "last_flow_id", r.last_flow_id
          j.field "reflected", r.reflected
          j.field "reflected_flow_id", r.reflected_flow_id if r.reflected_flow_id
        end
      end

      # `location` as an array, a JSON-encoded array, a bare name or a comma list — every entry
      # a `Miner::Location` spelling. Absent/empty = all six. An unknown name raises (named),
      # never silently widens back to all.
      private def params_locations(h) : Array(Miner::Location)
        names = str_list(h, "location").flat_map(&.split(',')).map(&.strip).reject(&.empty?)
        return ParamInventory::ALL_LOCATIONS if names.empty?
        names.map do |n|
          Miner::Location.parse?(n) ||
            raise Gori::Error.new("unknown location #{n.inspect} (query|form|multipart|json|headers|cookies)")
        end.uniq!
      end

      # The tools/list schemas for the sitemap tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_sitemap_tools(j : JSON::Builder) : Nil
        tool j, "list_sitemap",
          "Distinct endpoints in capture, keyed by TRANSPORT (scheme, host, port, " \
          "http_version, method, target), with status set, success/error counts, " \
          "first/last-seen, `tag` for an operator memo (set_sitemap_tag), and `touched_by` " \
          "(active tool -> recorded flows or saved fuzz results, per path sans query). Query-string " \
          "variants fold by default: `target` = path, `query_variants` = count, " \
          "`query_targets` = up to #{QUERY_SAMPLE_MAX} raw ones, memos in `variant_tags`. " \
          "Returns {entries, returned, scanned, offset, limit, has_more}, not a bare array. " \
          "`has_more:true` = more endpoints: advance `offset` until false, or you map only a " \
          "fraction. Paging counts raw rows BEFORE folding (`scanned`), so a folded entry can " \
          "span pages." do |s|
          s.field "query", strprop("gori QL, plus sitemap-only `tag:x` (paths at/under/above a memo containing x) and `-tag:x` (drops that subtree)")
          s.field "limit", limitprop("max endpoint rows scanned per page, before folding", SITEMAP_LIMIT)
          s.field "offset", intprop("endpoint rows to skip (default 0); ordering is total, so paging reaches every endpoint")
          s.field "fold_query", boolprop("fold the query-string variants of a path into one entry (default true)")
          s.field "collapse_transport", boolprop("legacy shape: host/method/target only, no counts")
          s.field "hide_static", boolprop("omit static assets (images, fonts, audio/video; never svg/css/js or status >= 400); = `-static:true`")
          s.field "untested", boolprop("only endpoints with no recorded flow from #{FlowSource::Kind.active.join("/", &.token)} and no saved fuzz run; while testing, re-call from offset 0 instead of paging")
          s.field "include_unrequested", boolprop("add `unrequested`: JS-referenced endpoints no request reached, from scan_js_endpoints (≤#{UNREQUESTED_MAX} within budget; `unrequested_total` = all); not filtered by `query`")
          s.field "strict", boolprop("refuse a query with an invalid term (else it is dropped, BROADENING the result, and named in `ignored_terms`)")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing (a typo then matches nothing, like an empty project)")
        end

        tool j, "list_params",
          "Per-endpoint PARAMETER INVENTORY from captured requests: one row per (scheme, host, " \
          "port, method, path, location, name) with `count`, sample values, first/last flow id " \
          "and `reflected` (a 4+ byte value seen verbatim in the decoded response; a hint, not " \
          "a finding). JSON names are paths (items[].id; not JsonPath). Credential values are " \
          "[REDACTED] unless include_sensitive. truncated:true = flows older than max_flows " \
          "unread. Names from a host's OTHER endpoints suit mine_start `names`." do |s|
          s.field "query", strprop("gori QL filter over the flows read")
          s.field "in_scope", boolprop("only in-scope flows (empty, with a note, when no scope is configured)")
          s.field "hide_static", boolprop("omit static assets (images, fonts, audio/video)")
          s.field "host", strprop("only this host (exact, case-insensitive)")
          s.field "origin", strprop("only this origin (scheme://host:port), instead of host")
          s.field "path_prefix", strprop("only paths starting with this, e.g. /api/v1")
          s.field "location", arr_or_str_prop("only these: query, form, multipart, json, headers, cookies (array or comma list; default all)")
          s.field "all_headers", boolprop("include standard browser headers (User-Agent, Accept*, Sec-*…)")
          s.field "max_flows", intprop("newest matching flows to read (default 2000, max 20000)")
          s.field "samples", intprop("distinct samples per parameter (default 5, max 50)")
          s.field "include_sensitive", boolprop("unredact cookie / credential / token samples")
          s.field "limit", limitprop("max rows per page", PARAMS_LIMIT)
          s.field "offset", intprop("rows to skip (default 0)")
          s.field "strict", boolprop("refuse a query with an invalid term (else dropped, named in `ignored_terms`)")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing")
        end

        tool j, "export_openapi",
          "The captured API as an OpenAPI 3.0.3 document, inline (`document`; a YAML string " \
          "with format:yaml) or written to `output_path`. Paths templated (/users/123 -> " \
          "/users/{userId}); schemas inferred from samples; credentials become " \
          "securitySchemes, values never included. WebSocket, gRPC, SSE and incomplete flows " \
          "are counted in `skipped`. `truncated:true` = operations or paths left out by " \
          "max_endpoints/max_bytes (see `notes`): narrow with host or path_prefix." do |s|
          s.field "query", strprop("gori QL filter over the flows read")
          s.field "in_scope", boolprop("only in-scope flows (refused when no scope is configured)")
          s.field "hide_static", boolprop("omit static assets")
          s.field "host", strprop("only this host (exact, case-insensitive)")
          s.field "origin", strprop("only this origin (scheme://host:port), instead of host")
          s.field "path_prefix", strprop("only paths starting with this, e.g. /api/v1")
          s.field "format", strprop("json (default) or yaml; an output_path ending .yaml/.yml picks yaml")
          s.field "output_path", strprop("write to this server-side file instead of returning it (refused under --read-only; parent must exist; not in gori's home); max_bytes then defaults to its max")
          s.field "overwrite", boolprop("with output_path, replace an existing file if it is an OpenAPI document (otherwise refused)")
          s.field "include_gori", boolprop("keep gori's own requests (Repeater, Fuzzer, Miner…), which describe its probing, not the API")
          s.field "examples", boolprop("add example values (one sample each), redacted via the profile")
          s.field "redact", strprop("examples' redaction profile (default: project's, else global, else `default`)")
          s.field "max_endpoints", intprop("operations kept (default 200, max 2000)")
          s.field "max_samples", intprop("flows read per operation (default 10, max 50)")
          s.field "max_flows", intprop("newest flows read in all (default 5000, max 20000)")
          s.field "max_bytes", intprop("max compact-JSON size; whole paths past it are dropped (default #{OPENAPI_INLINE_BYTES} inline, #{OPENAPI_MAX_BYTES} with output_path; max #{OPENAPI_MAX_BYTES})")
          s.field "strict", boolprop("refuse a query with an invalid term (else dropped, named in `ignored_terms`)")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing")
        end

        tool j, "list_sitemap_tags",
          "List the operator's sitemap path memos as {items:[{host, path, tag}]}." do |s|
          s.field "host", strprop("only tags on this host")
        end

        return unless @allow_actions

        tool j, "set_sitemap_tag",
          "Pin a free-text memo on one sitemap node (empty/absent `tag` clears it). Keyed by " \
          "the exact node path, query string INCLUDED. A FOLDED list_sitemap entry " \
          "(query_variants > 0) holds no tag: tag one of its `query_targets` or list with " \
          "fold_query:false. A tag on a path no node has is silently invisible." do |s|
          s.field "host", strprop("host the path belongs to"), required: true
          s.field "path", strprop("node path as list_sitemap shows it, e.g. /api/users or /search?q=1"), required: true
          s.field "tag", strprop("the memo; empty or absent CLEARS the tag")
        end
      end
    end
  end
end
