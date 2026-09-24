require "json"
require "../../store"
require "../../import"

module Gori
  module MCP
    class Tools
      # Bulk-import flows into the project's History from a HAR export, a URL list, an
      # OpenAPI/Swagger spec, a Postman or Insomnia collection, a Burp item export, or a
      # WSDL 1.1 service description, or curl commands — the MCP counterpart of `gori run import`. `path` is
      # resolved on the MCP SERVER's filesystem (same trust boundary as send_request/repeater
      # — this process runs locally alongside the agent).
      KINDS = {
        "har"      => :har,
        "urls"     => :urls,
        "oas"      => :oas,
        "postman"  => :postman,
        "insomnia" => :insomnia,
        "burp"     => :burp,
        "wsdl"     => :wsdl,
        "curl"     => :curl,
      }

      @[Tool("import_flows", gated: true, agent_action: true)]
      private def import_flows(h) : Result
        kind_s = str(h, "kind").try(&.strip.downcase).presence
        # ABSENT and WRONG are two different mistakes, and only one of them is a value to
        # look at again. "invalid 'kind'" for an argument that was never sent reads as a
        # rejected value, which is the sentence an agent answers by re-spelling the one it
        # did send — `path` one line below has always said this correctly.
        unless kind_s
          return err("missing required 'kind' (expected #{KINDS.keys.join("|")})",
            "INVALID_ARGUMENT", field: "kind")
        end
        unless kind = KINDS[kind_s]?
          return err("invalid 'kind' #{kind_s.inspect} (expected #{KINDS.keys.join("|")})",
            "INVALID_ARGUMENT", field: "kind")
        end
        result = import_source(h, kind, kind_s)
        return result if result.is_a?(Result)
        # import_file RAISES when the parse yields zero flows, so it only returns here with
        # ≥1 flow to insert. A count of 0 therefore means the batch write was rolled back
        # (store busy/locked) — NOT an empty import — so surface it as retryable rather than
        # reporting a silent "imported 0".
        return busy("import parsed flows but persisted none (store busy or unwritable); retry") if result.count == 0
        Result.new(JSON.build do |j|
          j.object do
            j.field "kind", kind_s
            str(h, "path").try(&.strip).presence.try { |path| j.field "path", path }
            j.field "count", result.count
            j.field "attempted", result.attempted
            j.field "skipped", result.skipped
            # The import writes in chunks, so a roll-back part-way leaves the earlier ones
            # committed. Named rather than implied, so an agent does not read a short count as
            # a complete import of a smaller file.
            result.shortfall_note.try { |note| j.field "partial", note }
            # A curl command's flags the import could not carry (transport options, a path curl
            # would have collapsed) — named, so an agent does not assume they took effect.
            j.field "notes", result.notes unless result.notes.empty?
          end
        end)
      rescue ex : Gori::Error
        err(ex.message || "import failed", "INVALID_ARGUMENT")
      end

      # Run the import from whichever source the call named — a `path` for every kind, or, for
      # `curl` only, the command itself as `text`: an agent holds a copied command as a string,
      # and writing it to a file first only to name that file would be a detour. A refused
      # combination comes back as the error `Result`.
      private def import_source(h, kind : Symbol, kind_s : String) : Import::Result | Result
        path = str(h, "path").try(&.strip).presence
        text = str(h, "text")
        if text && kind != :curl
          return err("'text' is accepted for kind \"curl\" only — pass 'path' for #{kind_s}",
            "INVALID_ARGUMENT", field: "text")
        end
        return err("pass 'path' or 'text', not both", "INVALID_ARGUMENT", field: "text") if text && path
        return Import.import_curl_text(store, text, Gori::FlowSource::Surface::Mcp) if text
        return Import.import_file(store, kind, path, Gori::FlowSource::Surface::Mcp) if path
        err(kind == :curl ? "missing required 'path' or 'text'" : "missing required 'path'",
          "INVALID_ARGUMENT", field: "path")
      end

      # The tools/list schemas for the import tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_import_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "import_flows",
          "Bulk-import flows into the project's History from a HAR export, a URL list, an " \
          "OpenAPI 3.x or Swagger 2.0 spec (local refs only), a Postman Collection v2 or Insomnia v4 export, a Burp Suite " \
          "item export, a WSDL 1.1 service description (SOAP 1.1/1.2), or curl commands — the MCP " \
          "equivalent of `gori run import`. `path` is read from the MCP SERVER's local filesystem (this " \
          "process runs locally, same trust boundary as send_request); kind `curl` also takes the " \
          "command itself as `text` (one flow per request; transport flags such as -k/-x/-L are " \
          "ignored and listed in `notes`). Only `har` and `burp` carry responses; the rest import " \
          "request templates with no response." do |s|
          s.field "kind", enumprop("the source format to read", KINDS.keys), required: true
          s.field "path", strprop("filesystem path to the source file (required unless kind is curl and 'text' is given)")
          s.field "text", strprop("kind curl only: the curl command(s) as text, instead of a file")
        end
      end
    end
  end
end
