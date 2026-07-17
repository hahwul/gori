require "json"
require "../../ql"
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
        entries = @store.sitemap_entries_detailed(filter, limit)
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
              end
            end
          end
        end)
      end

      # The legacy collapsed sitemap (distinct host/method/target only), for
      # collapse_transport:true.
      private def collapsed_sitemap(filter : QL::Filter, limit : Int32) : Result
        entries = @store.sitemap_entries(filter, limit)
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
