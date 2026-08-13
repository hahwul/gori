require "json"
require "../../store"
require "../../import"

module Gori
  module MCP
    class Tools
      # Bulk-import flows into the project's History from a HAR export, a URL list, an
      # OpenAPI/Swagger spec, a Postman or Insomnia collection, or a Burp item export —
      # the MCP counterpart of `gori run import`. `path` is resolved on the MCP SERVER's
      # filesystem (same trust boundary as send_request/repeater — this process runs
      # locally alongside the agent).
      KINDS = {
        "har"      => :har,
        "urls"     => :urls,
        "oas"      => :oas,
        "postman"  => :postman,
        "insomnia" => :insomnia,
        "burp"     => :burp,
      }

      private def import_flows(h) : Result
        kind_s = str(h, "kind").try(&.strip.downcase)
        kind = kind_s.try { |k| KINDS[k]? }
        unless kind_s && kind
          return err("invalid 'kind' (expected #{KINDS.keys.join("|")})", "INVALID_ARGUMENT", field: "kind")
        end
        path = str(h, "path").try(&.strip)
        return err("missing required 'path'", "INVALID_ARGUMENT", field: "path") if path.nil? || path.empty?
        result = Import.import_file(store, kind, path)
        # import_file RAISES when the parse yields zero flows, so it only returns here with
        # ≥1 flow to insert. A count of 0 therefore means the batch write was rolled back
        # (store busy/locked) — NOT an empty import — so surface it as retryable rather than
        # reporting a silent "imported 0".
        return busy("import parsed flows but persisted none (store busy or unwritable); retry") if result.count == 0
        Result.new(JSON.build do |j|
          j.object do
            j.field "kind", kind_s
            j.field "path", path
            j.field "count", result.count
            j.field "attempted", result.attempted
            j.field "skipped", result.skipped
            # The import writes in chunks, so a roll-back part-way leaves the earlier ones
            # committed. Named rather than implied, so an agent does not read a short count as
            # a complete import of a smaller file.
            result.shortfall_note.try { |note| j.field "partial", note }
          end
        end)
      rescue ex : Gori::Error
        err(ex.message || "import failed", "INVALID_ARGUMENT")
      end

      # The tools/list schemas for the import tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_import_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "import_flows",
          "Bulk-import flows into the project's History from a HAR export, a URL list, an " \
          "OpenAPI/Swagger spec, a Postman Collection v2 or Insomnia v4 export, or a Burp Suite " \
          "item export — the MCP equivalent of `gori run import`. `path` is read from " \
          "the MCP SERVER's local filesystem (this process runs locally, same trust boundary as " \
          "send_request). Only `har` and `burp` carry responses; the rest import request " \
          "templates with no response." do |s|
          s.field "kind", strprop("har | urls | oas | postman | insomnia | burp"), required: true
          s.field "path", strprop("filesystem path to the source file"), required: true
        end
      end
    end
  end
end
