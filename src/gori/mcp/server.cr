require "json"
require "log"
require "../store"
require "./tools"

module Gori
  module MCP
    # A Model Context Protocol server over stdio: JSON-RPC 2.0, one compact JSON
    # message per line on `input`, responses on `output`. STDOUT is the protocol
    # channel — callers MUST keep it pure (logs go to STDERR). IO is injectable so
    # the server is unit-testable with IO::Memory.
    class Server
      Log = ::Log.for("mcp")

      # Newest spec revision we implement. Our surface (initialize/tools.list/
      # tools.call/ping) is identical across recent revisions, so we echo the
      # client's requested version when it is one we recognise, and never
      # hard-fail on a mismatch.
      PROTOCOL_VERSION = "2025-06-18"

      # Revisions whose surface we're compatible with. Per the MCP lifecycle the
      # server MUST answer initialize with a version it actually supports: we
      # echo the client's version only when it's in this set, else fall back to
      # PROTOCOL_VERSION — so a client probing "1999-01-01" can't conclude we
      # speak a revision we don't.
      SUPPORTED_VERSIONS = {"2025-06-18", "2025-03-26", "2024-11-05"}

      EMPTY_ARGS = JSON::Any.new({} of String => JSON::Any)

      def initialize(@store : Store, *, allow_actions : Bool, verify_upstream : Bool,
                     @project_name : String? = nil, @project_slug : String? = nil,
                     @db_path : String? = nil, @selection_source : String? = nil,
                     @workspace_root : String? = nil,
                     @input : IO = STDIN, @output : IO = STDOUT)
        @allow_actions = allow_actions
        @tools = Tools.new(@store, allow_actions, verify_upstream,
          project_name: @project_name, project_slug: @project_slug, db_path: @db_path,
          selection_source: @selection_source, workspace_root: @workspace_root)
        @initialized = false
      end

      # Reads until EOF on `input` (client closed the pipe). Each line is parsed
      # and dispatched independently; a bad line never stops the loop.
      def run : Nil
        @input.each_line do |line|
          line = line.strip
          next if line.empty?
          handle_line(line)
        end
      end

      private def handle_line(line : String) : Nil
        id = nil.as(JSON::Any?)
        root = begin
          JSON.parse(line)
        rescue ex : JSON::ParseException
          return write_error(nil, -32700, "Parse error: #{ex.message}")
        end

        obj = root.as_h?
        return write_error(nil, -32600, "Invalid Request") unless obj

        id = obj["id"]?
        method = obj["method"]?.try(&.as_s?)
        params = obj["params"]?

        unless method
          write_error(id, -32600, "Invalid Request: missing method") if id
          return
        end

        if id
          handle_request(id, method, params)
        else
          handle_notification(method, params)
        end
      rescue ex
        Log.error(exception: ex) { "dispatch error" }
        # Never leave a request with an id hanging — the client would block forever.
        write_error(id, -32603, "Internal error: #{ex.message}") if id
      end

      private def handle_request(id : JSON::Any, method : String, params : JSON::Any?) : Nil
        case method
        when "initialize" then handle_initialize(id, params)
        when "ping"       then write_result(id) { |j| j.object { } }
        when "tools/list" then handle_tools_list(id)
        when "tools/call" then handle_tools_call(id, params)
        else                   write_error(id, -32601, "Method not found: #{method}")
        end
      rescue ex
        Log.error(exception: ex) { "request #{method} failed" }
        write_error(id, -32603, "Internal error: #{ex.message}")
      end

      private def handle_notification(method : String, params : JSON::Any?) : Nil
        @initialized = true if method == "notifications/initialized"
        # All other notifications are accepted silently (no response, ever).
      end

      private def handle_initialize(id : JSON::Any, params : JSON::Any?) : Nil
        client_ver = obj_field(params, "protocolVersion").try(&.as_s?)
        version = client_ver && SUPPORTED_VERSIONS.includes?(client_ver) ? client_ver : PROTOCOL_VERSION
        write_result(id) do |j|
          j.object do
            j.field "protocolVersion", version
            j.field("capabilities") { j.object { j.field("tools") { j.object { } } } }
            j.field "serverInfo" do
              j.object do
                j.field "name", "gori"
                j.field "version", Gori::VERSION
              end
            end
            j.field "instructions", instructions_text
          end
        end
      end

      # Surfaced at the handshake so the client/model knows up front what this server
      # exposes — in particular whether the (otherwise simply absent) action tools are
      # disabled by read-only mode, rather than discovering it only on a rejected call.
      private def instructions_text : String
        selected = if @project_name || @project_slug
                     " This server is pinned to project #{@project_name || @project_slug}#{" [#{@project_slug}]" if @project_slug}" \
                     " via #{@selection_source || "an explicit database"}#{" for workspace #{@workspace_root}" if @workspace_root}."
                   else
                     " Project selection source: #{@selection_source || "unknown"}; call project_info before using data."
                   end
        base = "gori MCP exposes the selected project's captured HTTP traffic " \
               "(history, flows, sitemap, scope, findings, notes, match&replace rules), plus a " \
               "pure `decoder` encode/decode/hash tool. Call ql_reference before " \
               "writing list_history/list_sitemap queries. Timestamps include unix " \
               "microseconds plus *_iso RFC3339 fields where available.#{selected}"
        if @allow_actions
          "#{base} Action tools are enabled: send_request (supports flow_id replay), " \
          "send_websocket (executes a persisted WS replay), " \
          "fuzz_*, mine_*, create/update_finding, and create/delete_rule + set_rule_enabled " \
          "make real outbound requests or mutate findings/rules."
        else
          "#{base} Read-only mode: action tools (send_request, send_websocket, fuzz_*, mine_*, " \
          "create/update_finding, create/delete_rule) are disabled — restart without --read-only to enable them."
        end
      end

      private def handle_tools_list(id : JSON::Any) : Nil
        write_result(id) do |j|
          j.object { j.field("tools") { @tools.list(j) } }
        end
      end

      private def handle_tools_call(id : JSON::Any, params : JSON::Any?) : Nil
        name = obj_field(params, "name").try(&.as_s?)
        return write_error(id, -32602, "tools/call: missing 'name'") unless name
        args = obj_field(params, "arguments") || EMPTY_ARGS
        result = @tools.call(name, args)
        write_result(id) do |j|
          j.object do
            j.field("content") do
              j.array do
                j.object { j.field "type", "text"; j.field "text", result.text }
              end
            end
            if structured = structured_content(result.text)
              j.field("structuredContent") { structured.to_json(j) }
            end
            j.field "isError", result.is_error
          end
        end
      end

      # MCP structuredContent is an object. Preserve the text block for older
      # clients, while giving newer clients parsed data directly so callers do
      # not have to JSON-decode content[0].text a second time. Array/scalar tool
      # payloads are wrapped to satisfy the object shape required by MCP.
      private def structured_content(text : String) : JSON::Any?
        parsed = JSON.parse(text)
        return parsed if parsed.as_h?
        if parsed.as_a?
          return JSON::Any.new({"items" => parsed})
        end
        JSON::Any.new({"value" => parsed})
      rescue JSON::ParseException
        nil
      end

      # Field of a JSON object that may be nil/non-object — never raises.
      private def obj_field(any : JSON::Any?, key : String) : JSON::Any?
        any.try(&.as_h?).try(&.[key]?)
      end

      private def write_result(id : JSON::Any?, &block : JSON::Builder ->) : Nil
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            emit_id(j, id)
            j.field("result") { block.call(j) }
          end
        end)
      end

      private def write_error(id : JSON::Any?, code : Int32, message : String) : Nil
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            emit_id(j, id)
            j.field("error") { j.object { j.field "code", code; j.field "message", message } }
          end
        end)
      end

      # Echoes the request id verbatim (int stays int, string stays string); null
      # when we have none (e.g. a parse error before we could read it).
      private def emit_id(j : JSON::Builder, id : JSON::Any?) : Nil
        j.field("id") { id ? id.to_json(j) : j.null }
      end

      private def send(payload : String) : Nil
        @output.puts(payload) # newline framing
        @output.flush         # or the client blocks on the unterminated line
      end
    end
  end
end
