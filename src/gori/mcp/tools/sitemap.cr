require "json"
require "../../ql"
require "../../sitemap"
require "../../param_inventory"
require "../../export/openapi"
require "../serialize"

module Gori
  module MCP
    class Tools
      @[Tool("list_sitemap")]
      private def list_sitemap(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), 200, 5000)
        offset = (optional_int_arg(h, "offset") || 0_i64).clamp(0_i64, Int32::MAX.to_i64).to_i
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
        return filter if filter.is_a?(Result)
        # Per-flow, like the TUI tree's lens: a host keeps its non-static endpoints.
        filter = QL.and(filter, QL.hide_static) if bool_arg(h, "hide_static", false)
        # Same reason as list_history: a `body:` query reads the off-commit trigram index
        # (Store V4), and an agent can't distinguish "absent" from "not indexed yet".
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        unrequested = bool_arg(h, "include_unrequested", false)
        if bool_arg(h, "collapse_transport", false)
          # Refused rather than dropped: an answer without the block reads as "no references".
          return err("include_unrequested is not available with collapse_transport — call without it, or use list_js_endpoints",
            "INVALID_ARGUMENT", field: "include_unrequested") if unrequested
          return collapsed_sitemap(filter, limit, offset)
        end
        # One row OVER the page, then dropped: `has_more` costs a row instead of a second
        # COUNT(*) over the same GROUP BY. Without it a full page and an exactly-full set are
        # the same answer, and this tool — unlike list_history — has no id cursor an agent
        # could probe with, so "200 endpoints" silently stood for a surface of any size.
        rows = store.sitemap_entries_detailed(filter, limit + 1, offset: offset)
        has_more = rows.size > limit
        rows = rows.first(limit) if has_more
        # Folded by DEFAULT, matching `gori run sitemap` and the TUI tree: an agent mapping a
        # surface should not read one entry per fuzz payload. `fold_query:false` is the twin
        # of the CLI's --no-fold-query.
        entries = fold_query_entries(rows, bool_arg(h, "fold_query", true))
        tags = store.sitemap_tags
        Result.new(JSON.build do |j|
          j.object do
            j.field "returned", entries.size
            j.field "scanned", rows.size
            j.field "offset", offset
            j.field "limit", limit
            j.field "has_more", has_more
            # Endpoints captured JavaScript references and no request reached (#1243). NOT
            # entries: an entry is a captured transport key with counts, and these have none —
            # mixing them in would also make `has_more`/`offset` page two different things.
            emit_unrequested(j) if unrequested
            j.field "entries" do
              j.array do
                entries.each do |e|
                  j.object do
                    j.field "scheme", Serialize.text(e.scheme)
                    j.field "host", Serialize.text(e.host)
                    j.field "port", e.port
                    j.field "http_version", Serialize.text(e.http_version)
                    j.field "method", Serialize.text(e.method)
                    j.field "target", Serialize.text(e.target)
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
                    j.field "first_seen_iso", Serialize.unix_micros_iso(e.first_seen)
                    j.field "last_seen", e.last_seen
                    j.field "last_seen_iso", Serialize.unix_micros_iso(e.last_seen)
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
                    if e.query_variants == 0 && (tag = tags[{e.host, sitemap_tag_path(e.target)}]?)
                      j.field "tag", Serialize.text(tag)
                    end
                  end
                end
              end
            end
          end
        end)
      end

      # Pin (or clear) a free-text memo on one sitemap endpoint — the TUI Sitemap tab's `t`.
      @[Tool("set_sitemap_tag", gated: true, agent_action: true)]
      private def set_sitemap_tag(h) : Result
        host = str(h, "host").try(&.strip).presence
        return err("missing required 'host'", "INVALID_ARGUMENT", field: "host") unless host
        path = str(h, "path").try(&.strip).presence
        return err("missing required 'path' (the path as list_sitemap shows it, e.g. /api/users or /login?a=1)",
          "INVALID_ARGUMENT", field: "path") unless path
        # Normalize exactly as the Sitemap tree stamps node paths (query string INCLUDED).
        path = sitemap_tag_path(path)
        tag = (str(h, "tag") || "").strip
        # A tag whose (host, path) names no captured endpoint is stored but unreachable — it
        # can never stamp onto a tree node or a list_sitemap entry. Report that rather than
        # answering a flat success: the common causes are a typo and a trailing slash
        # (Sitemap.add drops one, so /api/users/ is stamped as /api/users).
        matched = sitemap_node_exists?(host, path)
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
        Result.new(JSON.build do |j|
          j.array do
            tags.each do |(hst, path), tag|
              next if host && hst != host
              j.object do
                j.field "host", Serialize.text(hst)
                j.field "path", Serialize.text(path)
                j.field "tag", Serialize.text(tag)
              end
            end
          end
        end)
      end

      # Whether any captured endpoint on `host` normalizes to `path` — the same derivation
      # list_sitemap's tag stamping uses, so "matched" here means "will be visible there".
      #
      # `nil` means UNKNOWN, and the distinction is load-bearing: the scan is capped at
      # SITEMAP_MAX, and that cap is on the 6-column transport key, which multiplies past
      # 10k long before the collapsed host/method/target count suggests. Answering a flat
      # `false` off a truncated read made a positive claim about the capture that the query
      # could not support — and the warning built on it told the operator to go hunting for
      # a typo in a tag that was stored and does show.
      private def sitemap_node_exists?(host : String, path : String) : Bool?
        entries = store.sitemap_entries_detailed(QL::EMPTY, Store::SITEMAP_MAX)
        return true if entries.any? { |e| e.host == host && sitemap_tag_path(e.target) == path }
        entries.size >= Store::SITEMAP_MAX ? nil : false
      end

      # A sitemap tag's key is the exact node path the tree stamps. `node_path` shares its
      # segment reduction, including trailing-slash removal, query retention and depth cuts.
      private def sitemap_tag_path(target : String) : String
        Sitemap.node_path(target.strip)
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
          path = sitemap_tag_path(t)
          if tag = tags[{row.host, path}]?
            found << {path, tag}
          end
        end
        return if found.empty?
        j.field "variant_tags" do
          j.array do
            found.each do |(path, tag)|
              j.object do
                j.field "path", Serialize.text(path)
                j.field "tag", Serialize.text(tag)
              end
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
          full = sitemap_tag_path(e.target)
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

      # The legacy collapsed sitemap (distinct host/method/target only), for
      # collapse_transport:true.
      private def collapsed_sitemap(filter : QL::Filter, limit : Int32, offset : Int32) : Result
        entries = store.sitemap_entries(filter, limit + 1, offset: offset)
        has_more = entries.size > limit
        entries = entries.first(limit) if has_more
        Result.new(JSON.build do |j|
          j.object do
            j.field "returned", entries.size
            j.field "offset", offset
            j.field "limit", limit
            j.field "has_more", has_more
            j.field "entries" do
              j.array do
                entries.each do |(host, method, target)|
                  j.object do
                    j.field "host", Serialize.text(host)
                    j.field "method", Serialize.text(method)
                    j.field "target", Serialize.text(target)
                  end
                end
              end
            end
          end
        end)
      end

      # The parameter inventory (#1231) — one call instead of paging list_history + get_flow
      # to learn what inputs a target takes. Read-only and recomputed per call (P6); see
      # `ParamInventory` for what "reflected" does and does not claim.
      @[Tool("list_params")]
      private def list_params(h) : Result
        req_off = optional_int_arg(h, "offset")
        req_lim = optional_int_arg(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 200, 2000)
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
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
        report = if scope_unconfigured
                   ParamInventory::Report.new([] of ParamInventory::Row, 0, false)
                 else
                   opts = ParamInventory::Options.new(filter: filter, host: str(h, "host"),
                     path_prefix: str(h, "path_prefix"), locations: locations,
                     all_headers: bool_arg(h, "all_headers", false),
                     max_flows: clamp(optional_int_arg(h, "max_flows"), 2000, 20_000),
                     samples: clamp(optional_int_arg(h, "samples"), 5, 50))
                   ParamInventory.build(store, opts)
                 end
        rows = report.rows
        page = rows[offset, limit]? || [] of ParamInventory::Row
        Result.new(JSON.build do |j|
          j.object do
            j.field("params") { j.array { page.each { |r| param_row(j, r, include_sensitive) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total", rows.size
            j.field "has_more", offset + page.size < rows.size
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
      @[Tool("export_openapi")]
      private def export_openapi(h) : Result
        filter = openapi_filter(h)
        return filter if filter.is_a?(Result)
        yaml = openapi_yaml?(h)
        return yaml if yaml.is_a?(Result)
        examples = bool_arg(h, "examples", false)
        choice = openapi_redactor(h, examples)
        return choice if choice.is_a?(Result)
        opts = Export::OpenApi::Options.new(filter: filter, host: str(h, "host"),
          path_prefix: str(h, "path_prefix"),
          max_flows: clamp(optional_int_arg(h, "max_flows"), 5000, 20_000),
          max_samples: clamp(optional_int_arg(h, "max_samples"), 10, 50),
          max_endpoints: clamp(optional_int_arg(h, "max_endpoints"), 200, 2000),
          examples: examples, redactor: choice.try(&.matcher), include_gori: bool_arg(h, "include_gori", false))
        result = Export::OpenApi.build(store, opts)
        doc, dropped = Export::OpenApi.fit(result.doc, clamp(optional_int_arg(h, "max_bytes"), 256 * 1024, 2 * 1024 * 1024))
        result.report.paths_dropped = dropped
        Result.new(openapi_json(doc, result.report, yaml, choice))
      end

      # The flow set: the QL query, then the per-flow scope and hide-static lenses. Unconfigured
      # scope is refused rather than answered with an empty document.
      private def openapi_filter(h) : QL::Filter | Result
        filter = ql_filter_or_error(h, str(h, "query"))
        return filter if filter.is_a?(Result)
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        if bool_arg(h, "in_scope", false)
          scope = Scope.load(store)
          unless scope.configured?
            return err("in_scope:true but no scope rules are configured — nothing is in scope; " \
                       "add scope rules or drop in_scope", "INVALID_ARGUMENT", field: "in_scope")
          end
          filter = QL.and(scope.filter(force: true), filter)
        end
        bool_arg(h, "hide_static", false) ? QL.and(filter, QL.hide_static) : filter
      end

      private def openapi_yaml?(h) : Bool | Result
        case f = str(h, "format").try(&.strip.downcase)
        when nil, "", "json" then false
        when "yaml"          then true
        else                      err("unknown format #{f.inspect} (json|yaml)", "INVALID_ARGUMENT", field: "format")
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

      private def openapi_json(doc : JSON::Any, report : Export::OpenApi::Report, yaml : Bool,
                               choice : Redact::Policy::Choice?) : String
        paths = doc["paths"]?.try(&.as_h?) || {} of String => JSON::Any
        JSON.build do |j|
          j.object do
            j.field "format", yaml ? "yaml" : "json"
            j.field "document" do
              yaml ? j.string(Export::OpenApi.to_yaml(doc)) : doc.to_json(j)
            end
            j.field "paths", paths.size
            j.field "operations", paths.sum { |_, item| item.as_h.keys.count { |k| k != "servers" } }
            j.field "hosts", report.hosts.map { |x| Serialize.text(x) }
            j.field "flows_read", report.flows_read
            j.field "truncated", report.truncated?
            j.field("skipped") { j.object { report.skipped.each { |k, v| j.field k.key, v } } }
            j.field "notes", openapi_notes(report, choice)
            j.field "examples_redacted", report.redacted if choice
          end
        end
      end

      private def param_row(j : JSON::Builder, r : ParamInventory::Row, include_sensitive : Bool) : Nil
        j.object do
          j.field "host", Serialize.text(r.host)
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
          "Distinct endpoints discovered in capture, keyed by TRANSPORT " \
          "(scheme, host, port, http_version, method, target) so the same path over " \
          "http vs https vs HTTP/2 stays separate — each with its observed status set, " \
          "success/error counts, and first/last-seen. An entry also carries a `tag` field " \
          "when the operator pinned a memo on that path (see set_sitemap_tag). By DEFAULT " \
          "the query-string variants of one path fold into a single entry (/search?q=1 + " \
          "/search?q=2 -> /search), matching the TUI tree and `gori run sitemap`: `target` " \
          "is then the path only, `query_variants` says how many query strings it stands " \
          "for, and `query_targets` carries up to #{QUERY_SAMPLE_MAX} of the raw ones to " \
          "replay. Counts and the seen window are summed over the variants, and any memo " \
          "pinned on a variant is reported under `variant_tags`. Pass " \
          "fold_query:false for one entry per query string. Pass collapse_transport:true " \
          "for the legacy host/method/target-only view. Optional QL `query` filter. " \
          "Returns an object {entries, returned, scanned, offset, limit, has_more} — not a " \
          "bare array. `has_more:true` means the surface is LARGER than this page: advance " \
          "`offset` (or narrow `query`) until it is false, or you are mapping a fraction of " \
          "the capture and cannot tell. `limit`/`offset` page the raw endpoint rows BEFORE " \
          "query-folding — `scanned` is how many that was — so one folded entry can continue " \
          "onto the next page." do |s|
          s.field "query", strprop("gori QL filter")
          s.field "limit", intprop("max endpoint rows scanned per page, before query-folding (default 200, max 5000)")
          s.field "offset", intprop("skip this many endpoint rows — the page cursor (default 0). The ordering is total, so paging with it is deterministic and reaches every endpoint")
          s.field "fold_query", boolprop("fold the query-string variants of one path into a single entry (default true); false lists one entry per query string")
          s.field "collapse_transport", boolprop("collapse to distinct host/method/target only (legacy shape), dropping scheme/port/version + counts (default false)")
          s.field "hide_static", boolprop("leave out static assets — images, fonts, audio/video (not svg/css/js, never a status >= 400); the TUI's hide-static lens, same as `-static:true` in `query`. Default false")
          s.field "include_unrequested", boolprop("add `unrequested`: endpoints captured JavaScript references that no request reached (up to #{UNREQUESTED_MAX}; `unrequested_total` says how many), from what scan_js_endpoints stored. Not filtered by `query` — a reference is not a flow. Default false")
          s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false)")
          s.field "lenient", boolprop("search a `field:` QL does not implement as literal TEXT instead of refusing the query (default false). A typo like `methd:GET` free-texts its whole token and therefore matches nothing, which is indistinguishable from an empty project — so it is refused by default, the way `gori run history --lenient` spells the same escape hatch. `strict` is the other half and covers dropped terms, not unknown fields")
        end

        tool j, "list_params",
          "Per-endpoint PARAMETER INVENTORY from captured requests: one row per (host, method, " \
          "path, location, name), location = query|form|multipart|json|headers|cookies, with " \
          "`count` (flows), sample values, first/last flow id and `reflected` (a 4+ byte value " \
          "seen verbatim in the decoded response; a triage hint, not a finding). JSON names are " \
          "paths (items[].id; [] is not JsonPath). Standard browser headers are omitted unless " \
          "all_headers. Cookie, credential-header and credential-named values are [REDACTED] " \
          "unless include_sensitive. Reads the newest max_flows flows (truncated:true = older " \
          "ones unread). Names from a host's OTHER endpoints make good mine_start `names`." do |s|
          s.field "query", strprop("gori QL filter over the flows read (see ql_reference)")
          s.field "in_scope", boolprop("only flows in the project's configured scope (default false; empty with a note when no scope is configured)")
          s.field "hide_static", boolprop("leave out static assets — images, fonts, audio/video; the TUI's hide-static lens, same as `-static:true` in `query` (default false)")
          s.field "host", strprop("only this host (exact, case-insensitive)")
          s.field "path_prefix", strprop("only endpoints whose path starts with this, e.g. /api/v1")
          s.field "location", arr_or_str_prop("only these locations: query, form, multipart, json, headers, cookies (array or comma list; default all)")
          s.field "all_headers", boolprop("include standard browser headers (User-Agent, Accept*, Sec-*, …) (default false)")
          s.field "max_flows", intprop("newest matching flows to read (default 2000, max 20000)")
          s.field "samples", intprop("distinct sample values kept per parameter (default 5, max 50)")
          s.field "include_sensitive", boolprop("return cookie / credential / token sample values instead of [REDACTED] (default false)")
          s.field "limit", intprop("max rows per page (default 200, max 2000)")
          s.field "offset", intprop("skip this many rows (default 0)")
          s.field "strict", boolprop("reject a query with an unrecognized/invalid term (default false)")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing the query (default false)")
        end

        tool j, "export_openapi",
          "The captured API as an OpenAPI 3.0.3 document, returned inline (`document`: an object, " \
          "or a YAML string with format:yaml). Paths are templated (/users/123 -> " \
          "/users/{userId}); query/header/cookie parameters are `required` only when every sample " \
          "carried them; request bodies and responses per status carry JSON schemas inferred from " \
          "the samples; credentials become securitySchemes and their values are never included. " \
          "No example values unless examples:true, and those pass the redaction profile. WebSocket, " \
          "gRPC, SSE and incomplete flows are skipped and counted in `skipped`. Bounded by " \
          "max_endpoints and max_bytes: `truncated:true` means operations or paths were left out " \
          "(see `notes`) — narrow with host or path_prefix. Deterministic: the same flows give the " \
          "same document." do |s|
          s.field "query", strprop("gori QL filter over the flows read (see ql_reference)")
          s.field "in_scope", boolprop("only flows in the project's configured scope (default false; refused when no scope is configured)")
          s.field "hide_static", boolprop("leave out static assets — images, fonts, audio/video (default false)")
          s.field "host", strprop("only this host (exact, case-insensitive) — one API per document")
          s.field "path_prefix", strprop("only endpoints whose path starts with this, e.g. /api/v1")
          s.field "format", strprop("json (default) or yaml")
          s.field "include_gori", boolprop("keep the requests gori itself sent — Repeater, Fuzzer, Miner, Discover… (default false: a brute force or a fuzz run would describe gori's probing, not the API)")
          s.field "examples", boolprop("add example values from one sample each, redacted through the profile (default false)")
          s.field "redact", strprop("redaction profile the examples pass through (default: the project's, else the global one, else `default`); needs examples:true")
          s.field "max_endpoints", intprop("operations kept (default 200, max 2000)")
          s.field "max_samples", intprop("flows read per operation (default 10, max 50)")
          s.field "max_flows", intprop("newest flows read in all (default 5000, max 20000)")
          s.field "max_bytes", intprop("largest document, measured as compact JSON; whole paths past it are dropped (default 262144, max 2097152)")
          s.field "strict", boolprop("reject a query with an unrecognized/invalid term (default false)")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing the query (default false)")
        end

        tool j, "list_sitemap_tags",
          "List the free-text memos the operator pinned onto sitemap paths, as " \
          "[{host, path, tag}]. These are the same tags list_sitemap stamps onto its entries." do |s|
          s.field "host", strprop("only list tags on this host")
        end

        return unless @allow_actions

        tool j, "set_sitemap_tag",
          "Pin a free-text memo onto one sitemap endpoint, or clear it with an empty/absent " \
          "`tag`. Keyed by the node path exactly as the Sitemap tree stamps it — which " \
          "INCLUDES any query string, so /search?q=1 is a different node from /search. " \
          "Pass the `target` you saw in list_sitemap verbatim — but note that a FOLDED entry " \
          "(query_variants > 0) shows the path only, and that folded row is synthetic: like " \
          "a {uuid} fold it holds no tag of its own. Tag one of its `query_targets`, or call " \
          "list_sitemap with fold_query:false first. A tag filed under a path no node has is " \
          "silently invisible in both list_sitemap and the TUI." do |s|
          s.field "host", strprop("host the path belongs to"), required: true
          s.field "path", strprop("node path as list_sitemap shows it, e.g. /api/users or /search?q=1"), required: true
          s.field "tag", strprop("the memo; empty or absent CLEARS the tag")
        end
      end
    end
  end
end
