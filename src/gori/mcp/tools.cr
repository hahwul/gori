require "json"
require "log"
require "../store"
require "../ql"
require "../replay/engine"
require "../replay/h2_engine"
require "./serialize"
require "./request_builder"

module Gori
  module MCP
    # Maps MCP tool calls to gori's store reads, the replay engines, and (gated)
    # store writes. Read tools are always exposed; the action tool (`send_request`)
    # and write tools (`create_finding`/`update_finding`) are gated behind
    # `allow_actions` — off when the user runs `gori mcp --read-only`. A gated tool
    # is omitted from `tools/list` AND rejected by `call`.
    class Tools
      Log = ::Log.for("mcp.tools")

      # One tool outcome. `is_error` maps to the MCP `isError` flag — a tool-level
      # failure the model is meant to see and recover from, distinct from a
      # JSON-RPC protocol error.
      record Result, text : String, is_error : Bool = false

      EMPTY_HASH = {} of String => JSON::Any

      def initialize(@store : Store, @allow_actions : Bool, @verify_upstream : Bool)
      end

      getter? allow_actions : Bool

      # Emits the tools/list array, honouring the action gate.
      def list(j : JSON::Builder) : Nil
        j.array do
          tool j, "list_history",
            "List captured HTTP flows, newest first. Optional gori QL `query` " \
            "filters (e.g. 'host:example.com status:>=500 size:>10000 dur:>500', " \
            "'header:set-cookie', 'body~secret\\d+' — `~` is regex, dur is ms); " \
            "empty query returns the most recent. Returns light rows (no bodies); " \
            "use get_flow for full detail." do |s|
            s.field "query", strprop("gori QL filter; empty = most recent")
            s.field "limit", intprop("max rows (default 50, max 500)")
            s.field "before_id", intprop("cursor: only flows with id < this (pagination; ignored when query is set)")
          end

          tool j, "get_flow",
            "Full request+response for one flow id (heads + decoded bodies). " \
            "Bodies are de-chunked/decompressed and summarised: inline text when " \
            "UTF-8 (capped 64KB), else a base64 sample." do |s|
            s.field "id", intprop("flow id from list_history"), required: true
          end

          tool j, "list_sitemap",
            "Distinct endpoints (host, method, target) discovered in capture. " \
            "Optional QL `query` filter." do |s|
            s.field "query", strprop("gori QL filter")
            s.field "limit", intprop("max entries (default 200, max 5000)")
          end

          tool j, "list_findings", "List triage findings (severity + status), newest/most-severe first." { }

          tool j, "get_finding", "Get one finding by id." do |s|
            s.field "id", intprop("finding id"), required: true
          end

          tool j, "list_scope", "List the project's scope include/exclude rules." { }

          tool j, "project_info", "Project totals: flow count, finding count, captured bytes, earliest capture time." { }

          if @allow_actions
            tool j, "send_request",
              "Send/replay an HTTP request to its origin and return the response. " \
              "ACTIVE: makes a real outbound request from this host. Give an " \
              "absolute `url`; optionally method/headers/body, or a verbatim `raw` " \
              "request. Host + Content-Length are auto-added when omitted." do |s|
              s.field "url", strprop("absolute URL incl. scheme+host, e.g. https://api.example.com/v1/x"), required: true
              s.field "method", strprop("HTTP method (default GET)")
              s.field "headers", objprop("header name->value map")
              s.field "body", strprop("request body, sent as-is")
              s.field "raw", strprop("verbatim raw HTTP/1.1 request; overrides method/headers/body (scheme/host/port still come from url)")
              s.field "http2", boolprop("use real HTTP/2 (default false)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
            end

            tool j, "create_finding", "Record a new finding in the project." do |s|
              s.field "title", strprop("finding title"), required: true
              s.field "severity", strprop("info|low|medium|high|critical (default info)")
              s.field "host", strprop("optional host the finding concerns")
              s.field "flow_id", intprop("optional flow id this finding links to")
            end

            tool j, "update_finding", "Update an existing finding's fields." do |s|
              s.field "id", intprop("finding id"), required: true
              s.field "title", strprop("new title")
              s.field "severity", strprop("info|low|medium|high|critical")
              s.field "notes", strprop("free-form notes (replaces existing)")
              s.field "status", strprop("open|confirmed|false-positive|resolved")
            end
          end
        end
      end

      # Dispatches a tools/call by name. Any store/replay exception is converted to
      # an is_error Result so one bad call never tears down the server loop.
      def call(name : String, args : JSON::Any) : Result
        h = args.as_h? || EMPTY_HASH
        read_tool(name, h) || action_tool(name, h) ||
          Result.new("unknown tool: #{name}", is_error: true)
      rescue ex
        Log.warn(exception: ex) { "tool #{name} failed" }
        Result.new("tool error: #{ex.message}", is_error: true)
      end

      # Read-only tools (always exposed). nil when `name` isn't one of them.
      private def read_tool(name : String, h) : Result?
        case name
        when "list_history"  then list_history(h)
        when "get_flow"      then get_flow(h)
        when "list_sitemap"  then list_sitemap(h)
        when "list_findings" then list_findings
        when "get_finding"   then get_finding(h)
        when "list_scope"    then list_scope
        when "project_info"  then project_info
        end
      end

      # Action + write tools, each gated behind allow_actions. nil when `name`
      # isn't one of them.
      private def action_tool(name : String, h) : Result?
        case name
        when "send_request"   then gated { send_request(h) }
        when "create_finding" then gated { create_finding(h) }
        when "update_finding" then gated { update_finding(h) }
        end
      end

      # --- read tools ---------------------------------------------------------

      private def list_history(h) : Result
        limit = clamp(int(h, "limit"), 50, 500)
        query = str(h, "query")
        rows =
          if query && !query.strip.empty?
            @store.search(QL.parse(query), limit)
          else
            @store.recent_flows(limit, int(h, "before_id"))
          end
        Result.new(JSON.build { |j| j.array { rows.each { |r| Serialize.flow_row(j, r) } } })
      end

      private def get_flow(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        detail = @store.get_flow(id)
        return Result.new("no flow with id #{id}", is_error: true) unless detail
        Result.new(Serialize.flow_detail_json(detail))
      end

      private def list_sitemap(h) : Result
        limit = clamp(int(h, "limit"), 200, 5000)
        query = str(h, "query")
        filter = query && !query.strip.empty? ? QL.parse(query) : QL::EMPTY
        entries = @store.sitemap_entries(filter, limit)
        Result.new(JSON.build do |j|
          j.array do
            entries.each do |(host, method, target)|
              j.object { j.field "host", host; j.field "method", method; j.field "target", target }
            end
          end
        end)
      end

      private def list_findings : Result
        Result.new(JSON.build { |j| j.array { @store.findings.each { |f| Serialize.finding(j, f) } } })
      end

      private def get_finding(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        f = @store.get_finding(id)
        return Result.new("no finding with id #{id}", is_error: true) unless f
        Result.new(JSON.build { |j| Serialize.finding(j, f) })
      end

      private def list_scope : Result
        Result.new(JSON.build do |j|
          j.array do
            @store.scope_rules.each do |(id, kind, match_type, pattern)|
              j.object do
                j.field "id", id
                j.field "kind", kind
                j.field "match_type", match_type
                j.field "pattern", pattern
              end
            end
          end
        end)
      end

      private def project_info : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "flows", @store.count
            j.field "findings", @store.count_findings
            j.field "total_bytes", @store.total_size
            j.field "earliest_created_at", @store.earliest_created_at
          end
        end)
      end

      # --- action / write tools (gated) ---------------------------------------

      private def send_request(h) : Result
        built = RequestBuilder.build(h)
        http2 = bool(h, "http2") || false
        verify = @verify_upstream && !(bool(h, "insecure") || false)
        result =
          if http2
            Replay::H2Engine.send(built.bytes, scheme: built.scheme, host: built.host, port: built.port, verify_upstream: verify)
          else
            Replay::Engine.send(built.bytes, scheme: built.scheme, host: built.host, port: built.port, verify_upstream: verify)
          end
        # Audit trail on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "send_request #{built.scheme}://#{built.host}:#{built.port} http2=#{http2} -> #{result.ok? ? "ok" : result.error}" }
        return Result.new("send failed: #{result.error}", is_error: true) unless result.ok?
        Result.new(Serialize.replay_result_json(result))
      end

      private def create_finding(h) : Result
        title = str(h, "title")
        return Result.new("missing required 'title'", is_error: true) if title.nil? || title.empty?
        # An unrecognised severity is rejected, not silently coerced to Info —
        # matching update_finding (a typo'd 'severity' shouldn't quietly become
        # an info finding). An absent/blank severity still defaults to Info.
        sev_s = str(h, "severity")
        if err = bad_severity(sev_s)
          return err
        end
        severity = severity_from(sev_s) || Store::Severity::Info
        # A present-but-invalid flow_id (1.9 / "oops") would otherwise be
        # silently nulled, creating an UNLINKED finding while reporting success —
        # reject it, consistent with how get_flow rejects a non-integer id.
        flow_id = int(h, "flow_id")
        return Result.new("invalid 'flow_id' (expected an integer)", is_error: true) if flow_id.nil? && present?(h, "flow_id")
        id = @store.insert_finding(title, severity, str(h, "host"), flow_id)
        # insert_finding returns 0 (never raises) when the write batch fails — e.g.
        # the cross-process SQLite lock couldn't be acquired (a TUI capturing into
        # the same project) or the disk is full. Don't report a phantom success.
        return Result.new("failed to persist finding (store busy or unwritable)", is_error: true) if id == 0
        Result.new(JSON.build { |j| j.object { j.field "id", id } })
      end

      private def update_finding(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return Result.new("no finding with id #{id}", is_error: true) unless @store.get_finding(id)
        # A blank severity/status means "leave unchanged"; only a present,
        # non-blank, unrecognised value is an error.
        sev_s = str(h, "severity")
        if err = bad_severity(sev_s)
          return err
        end
        stat_s = str(h, "status")
        if err = bad_status(stat_s)
          return err
        end

        title = str(h, "title")
        return Result.new("title must not be empty", is_error: true) if title && title.empty?
        notes = str(h, "notes")
        severity = severity_from(sev_s)
        status = status_from(stat_s)

        # Don't claim updated:true on a no-op. With no resolvable field the store
        # write is a silent no-op, so returning success would mislead the caller
        # (e.g. it'd think a typo'd field name took effect).
        if title.nil? && severity.nil? && notes.nil? && status.nil?
          return Result.new("no fields to update (provide at least one of title/severity/notes/status)", is_error: true)
        end

        @store.update_finding(id, title: title, severity: severity, notes: notes, status: status)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "updated", true } })
      end

      # An error Result when `s` is a present, non-blank, UNRECOGNISED severity;
      # nil when it's absent/blank (caller's default) or a valid label. Shared by
      # create + update so both reject the same typos.
      private def bad_severity(s : String?) : Result?
        return nil if s.nil? || s.strip.empty?
        return nil if severity_from(s)
        Result.new("invalid severity: #{s} (info|low|medium|high|critical)", is_error: true)
      end

      private def bad_status(s : String?) : Result?
        return nil if s.nil? || s.strip.empty?
        return nil if status_from(s)
        Result.new("invalid status: #{s} (open|confirmed|false-positive|resolved)", is_error: true)
      end

      # --- helpers ------------------------------------------------------------

      private def gated(& : -> Result) : Result
        return Result.new("tool disabled (gori mcp --read-only)", is_error: true) unless @allow_actions
        yield
      end

      private def str(h, key : String) : String?
        h[key]?.try(&.as_s?)
      end

      # Whether `key` is present with a non-null value (a JSON null reads as
      # "absent" for our purposes). Lets a caller tell a missing arg from one that
      # was supplied but couldn't be coerced.
      private def present?(h, key : String) : Bool
        v = h[key]?
        return false unless v
        !v.raw.nil?
      end

      # Error text for a REQUIRED integer id that didn't coerce: distinguishes a
      # genuinely absent arg from one that was supplied but isn't an integer (e.g.
      # 1.9 or "oops"), so the caller isn't told "missing" for a value it did send.
      private def id_error(h, key : String) : String
        present?(h, key) ? "invalid '#{key}' (expected an integer)" : "missing required '#{key}'"
      end

      # Coerce a JSON arg to Int64. Accepts a JSON integer, an INTEGRAL float
      # (100.0 → 100; many encoders emit ints as floats), and a numeric STRING
      # ("5" → 5) — clients/LLMs often serialize tool args as strings and the
      # schema's "integer" type is advisory, not enforced. A fractional float
      # (5.9) is rejected rather than silently truncated, so the number and
      # string encodings of the same value agree; an out-of-Int64-range float
      # returns nil rather than raising OverflowError — for a limit that falls
      # back to the default, for an id it reads as no-such-id, never a crash.
      private def int(h, key : String) : Int64?
        v = h[key]?
        return nil unless v
        if i = v.as_i64?
          return i
        end
        if f = v.as_f?
          return nil unless f.finite? && f == f.trunc
          return f.to_i64
        end
        v.as_s?.try(&.to_i64?)
      rescue OverflowError
        nil
      end

      private def bool(h, key : String) : Bool?
        h[key]?.try(&.as_bool?)
      end

      private def clamp(n : Int64?, default : Int32, max : Int32) : Int32
        return default unless n
        n.clamp(1_i64, max.to_i64).to_i
      end

      private def severity_from(s : String?) : Store::Severity?
        return nil unless s
        Store::Severity.parse?(s.strip)
      end

      private def status_from(s : String?) : Store::Status?
        return nil unless s
        case s.strip.downcase
        when "open"                                              then Store::Status::Open
        when "confirmed"                                         then Store::Status::Confirmed
        when "false-positive", "false_positive", "falsepositive" then Store::Status::FalsePositive
        when "resolved"                                          then Store::Status::Resolved
        else                                                          nil
        end
      end

      # --- tools/list schema builders -----------------------------------------

      # Emits one {name, description, inputSchema} object. The block declares
      # properties on a builder; `required` names are tracked and emitted.
      private def tool(j : JSON::Builder, name : String, description : String, & : SchemaBuilder ->) : Nil
        sb = SchemaBuilder.new
        yield sb
        j.object do
          j.field "name", name
          j.field "description", description
          j.field "inputSchema" do
            j.object do
              j.field "type", "object"
              j.field "properties" do
                j.object { sb.properties.each { |pname, schema| j.field(pname) { schema.to_json(j) } } }
              end
              j.field "required" do
                j.array { sb.required.each { |r| j.string r } }
              end
            end
          end
        end
      end

      private def strprop(desc : String) : JSON::Any
        prop("string", desc)
      end

      private def intprop(desc : String) : JSON::Any
        prop("integer", desc)
      end

      private def boolprop(desc : String) : JSON::Any
        prop("boolean", desc)
      end

      private def objprop(desc : String) : JSON::Any
        JSON.parse(%({"type":"object","description":#{desc.to_json},"additionalProperties":{"type":"string"}}))
      end

      private def prop(type : String, desc : String) : JSON::Any
        JSON.parse(%({"type":#{type.to_json},"description":#{desc.to_json}}))
      end

      # Collects a tool's input-schema properties + required list.
      class SchemaBuilder
        getter properties = [] of {String, JSON::Any}
        getter required = [] of String

        def field(name : String, schema : JSON::Any, required : Bool = false) : Nil
          @properties << {name, schema}
          @required << name if required
        end
      end
    end
  end
end
