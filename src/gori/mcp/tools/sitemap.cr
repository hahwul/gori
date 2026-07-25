require "json"
require "../../ql"
require "../../sitemap"
require "../serialize"

module Gori
  module MCP
    class Tools
      private def list_sitemap(h) : Result
        limit = clamp(int(h, "limit"), 200, 5000)
        query = str(h, "query")
        filter = ql_filter_or_error(h, query)
        return filter if filter.is_a?(Result)
        return collapsed_sitemap(filter, limit) if bool(h, "collapse_transport") || false
        entries = store.sitemap_entries_detailed(filter, limit)
        tags = store.sitemap_tags
        Result.new(JSON.build do |j|
          j.array do
            entries.each do |e|
              j.object do
                j.field "scheme", e.scheme
                j.field "host", e.host
                j.field "port", e.port
                j.field "http_version", e.http_version
                j.field "method", e.method
                j.field "target", e.target
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
                  j.field "tag", tag
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
        store.set_sitemap_tag(host, path, tag)
        Result.new({"host" => host, "path" => path, "tag" => tag.presence,
                    "cleared" => tag.empty?}.to_json)
      end

      private def list_sitemap_tags(h) : Result
        host = str(h, "host").try(&.strip).presence
        tags = store.sitemap_tags
        Result.new(JSON.build do |j|
          j.array do
            tags.each do |(hst, path), tag|
              next if host && hst != host
              j.object do
                j.field "host", hst
                j.field "path", path
                j.field "tag", tag
              end
            end
          end
        end)
      end

      # A sitemap tag's key is the node path the tree stamps, which Sitemap.normalize_path
      # produces — and that KEEPS the query string ("/login?a=1" is a distinct node from
      # "/login"). Normalizing through the same function is what makes a tag set here the one
      # the TUI Sitemap tab shows; stripping the query would file it under a key no node has.
      private def sitemap_tag_path(target : String) : String
        path = Sitemap.normalize_path(target.strip)
        return "/" if path.empty?
        path.starts_with?('/') || path.starts_with?("http") ? path : "/#{path}"
      end

      # The legacy collapsed sitemap (distinct host/method/target only), for
      # collapse_transport:true.
      private def collapsed_sitemap(filter : QL::Filter, limit : Int32) : Result
        entries = store.sitemap_entries(filter, limit)
        Result.new(JSON.build do |j|
          j.array do
            entries.each do |(host, method, target)|
              j.object { j.field "host", host; j.field "method", method; j.field "target", target }
            end
          end
        end)
      end
    end
  end
end
