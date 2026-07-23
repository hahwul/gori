require "json"
require "../../store"
require "../../import"

module Gori
  module MCP
    class Tools
      # Bulk-import flows into the project's History from a HAR export, a URL list,
      # or an OpenAPI/Swagger spec — the MCP counterpart of `gori run import`. `path`
      # is resolved on the MCP SERVER's filesystem (same trust boundary as
      # send_request/repeater — this process runs locally alongside the agent).
      private def import_flows(h) : Result
        kind_s = str(h, "kind").try(&.strip.downcase)
        unless kind_s.in?("har", "urls", "oas")
          return err("invalid 'kind' (expected har|urls|oas)", "INVALID_ARGUMENT", field: "kind")
        end
        kind = case kind_s
               when "har"  then :har
               when "urls" then :urls
               else             :oas
               end
        path = str(h, "path").try(&.strip)
        return err("missing required 'path'", "INVALID_ARGUMENT", field: "path") if path.nil? || path.empty?
        result = Import.import_file(store, kind, path)
        Result.new(JSON.build do |j|
          j.object do
            j.field "kind", kind_s
            j.field "path", path
            j.field "count", result.count
            j.field "skipped", result.skipped
          end
        end)
      rescue ex : Gori::Error
        err(ex.message || "import failed", "INVALID_ARGUMENT")
      end
    end
  end
end
