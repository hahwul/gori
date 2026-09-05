require "json"
require "../../ql"
require "../../sitemap"
require "../serialize"

module Gori
  module MCP
    class Tools
      @[Tool("list_sitemap")]
      private def list_sitemap(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), 200, 5000)
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
        return filter if filter.is_a?(Result)
        # Same reason as list_history: a `body:` query reads the off-commit trigram index
        # (Store V4), and an agent can't distinguish "absent" from "not indexed yet".
        if fts_error = drain_fts_or_error(filter.uses_fts?)
          return fts_error
        end
        return collapsed_sitemap(filter, limit) if bool_arg(h, "collapse_transport", false)
        entries = store.sitemap_entries_detailed(filter, limit)
        # Folded by DEFAULT, matching `gori run sitemap` and the TUI tree: an agent mapping a
        # surface should not read one entry per fuzz payload. `fold_query:false` is the twin
        # of the CLI's --no-fold-query.
        entries = fold_query_entries(entries, bool_arg(h, "fold_query", true))
        tags = store.sitemap_tags
        Result.new(JSON.build do |j|
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
            if matched == false && !tag.empty?
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

      # A sitemap tag's key is the node path the tree stamps, which Sitemap.normalize_path
      # produces — and that KEEPS the query string ("/login?a=1" is a distinct node from
      # "/login"). Normalizing through the same function is what makes a tag set here the one
      # the TUI Sitemap tab shows; stripping the query would file it under a key no node has.
      private def sitemap_tag_path(target : String) : String
        path = Sitemap.normalize_path(target.strip)
        return "/" if path.empty?
        path.starts_with?('/') ? path : "/#{path}"
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
      private def collapsed_sitemap(filter : QL::Filter, limit : Int32) : Result
        entries = store.sitemap_entries(filter, limit)
        Result.new(JSON.build do |j|
          j.array do
            entries.each do |(host, method, target)|
              j.object do
                j.field "host", Serialize.text(host)
                j.field "method", Serialize.text(method)
                j.field "target", Serialize.text(target)
              end
            end
          end
        end)
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
          "for the legacy host/method/target-only view. Optional QL `query` filter." do |s|
          s.field "query", strprop("gori QL filter")
          s.field "limit", intprop("max entries (default 200, max 5000)")
          s.field "fold_query", boolprop("fold the query-string variants of one path into a single entry (default true); false lists one entry per query string")
          s.field "collapse_transport", boolprop("collapse to distinct host/method/target only (legacy shape), dropping scheme/port/version + counts (default false)")
          s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false)")
          s.field "lenient", boolprop("search a `field:` QL does not implement as literal TEXT instead of refusing the query (default false). A typo like `methd:GET` free-texts its whole token and therefore matches nothing, which is indistinguishable from an empty project — so it is refused by default, the way `gori run history --lenient` spells the same escape hatch. `strict` is the other half and covers dropped terms, not unknown fields")
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
