require "json"
require "../../ql"
require "../../sitemap"
require "../serialize"

module Gori
  module MCP
    class Tools
      private def list_sitemap(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), 200, 5000)
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
        return filter if filter.is_a?(Result)
        # Same reason as list_history: a `body:` query reads the off-commit trigram index
        # (Store V4), and an agent can't distinguish "absent" from "not indexed yet".
        store.index_pending! if filter.uses_fts?
        return collapsed_sitemap(filter, limit) if bool_arg(h, "collapse_transport", false)
        entries = store.sitemap_entries_detailed(filter, limit)
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
                if tag = tags[{e.host, sitemap_tag_path(e.target)}]?
                  j.field "tag", Serialize.text(tag)
                end
              end
            end
          end
        end)
      end

      # Pin (or clear) a free-text memo on one sitemap endpoint — the TUI Sitemap tab's `t`.
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
          "when the operator pinned a memo on that path (see set_sitemap_tag). Pass " \
          "collapse_transport:true for the legacy host/method/target-only view. " \
          "Optional QL `query` filter." do |s|
          s.field "query", strprop("gori QL filter")
          s.field "limit", intprop("max entries (default 200, max 5000)")
          s.field "collapse_transport", boolprop("collapse to distinct host/method/target only (legacy shape), dropping scheme/port/version + counts (default false)")
          s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false)")
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
          "Pass the `target` you saw in list_sitemap verbatim; a tag filed under a path no " \
          "node has is silently invisible in both list_sitemap and the TUI." do |s|
          s.field "host", strprop("host the path belongs to"), required: true
          s.field "path", strprop("node path as list_sitemap shows it, e.g. /api/users or /search?q=1"), required: true
          s.field "tag", strprop("the memo; empty or absent CLEARS the tag")
        end
      end
    end
  end
end
