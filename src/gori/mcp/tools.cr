require "json"
require "base64"
require "log"
require "../store"
require "../ql"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/flow_request"
require "../flow_mapper"
require "../proxy/codec/http1"
require "../fuzz"
require "../decoder"
require "../env"
require "../miner"
require "../notes"
require "../prism"
require "./serialize"
require "./request_builder"

module Gori
  module MCP
    # Maps MCP tool calls to gori's store reads, the repeater engines, and (gated)
    # store writes. Read tools are always exposed; network action tools
    # (`send_request`/`send_websocket`) and write tools
    # (`create_finding`/`update_finding`) are gated behind
    # `allow_actions` — off when the user runs `gori mcp --read-only`. A gated tool
    # is omitted from `tools/list` AND rejected by `call`.
    class Tools
      Log = ::Log.for("mcp.tools")

      # One tool outcome. `is_error` maps to the MCP `isError` flag — a tool-level
      # failure the model is meant to see and recover from, distinct from a
      # JSON-RPC protocol error.
      record Result, text : String, is_error : Bool = false
      record BodyChunkOptions, flow_id : Int64?, repeater_id : Int64?, offset : Int64,
        limit : Int32, raw : Bool

      EMPTY_HASH = {} of String => JSON::Any

      # Fuzz-run safety rails (a single tool call must never launch an unbounded
      # flood, and the in-memory result buffer can't grow without bound).
      FUZZ_MAX_REQUESTS    = 100_000_i64
      FUZZ_MAX_CONCURRENCY =         100
      FUZZ_MAX_STORED      =      10_000

      # Param-miner safety rails (same intent as the fuzz caps).
      MINE_MAX_REQUESTS    = 100_000_i64
      MINE_MAX_CONCURRENCY =         100
      MINE_MAX_STORED      =      10_000

      MCP_REPEATER_REQUEST_MAX = 16 * 1024

      # Ceiling on the `decoder` tool's returned output string. A Decoder step can
      # produce up to 32 MiB (Decoder::MAX_OUT); returning that inline would swamp
      # the JSON-RPC channel, so truncate the display string and flag it.
      DECODER_MAX_OUTPUT = 256 * 1024

      def initialize(@store : Store, @allow_actions : Bool, @verify_upstream : Bool,
                     @project_name : String? = nil, @project_slug : String? = nil,
                     @db_path : String? = nil, @selection_source : String? = nil,
                     @workspace_root : String? = nil)
        Env.load_project(@store)
        @jobs = {} of String => FuzzJob
        @mine_jobs = {} of String => MineJob
        @job_seq = 0
      end

      getter? allow_actions : Bool

      # Raised by the fuzz arg-builders; converted to an is_error Result with a clean
      # message instead of a generic "tool error".
      class FuzzArgError < Exception
      end

      # A background fuzz run, polled by fuzz_status / fuzz_results. The runner fiber
      # only mutates these fields (single-threaded scheduler → no lock needed); the
      # stored results are matched-only and capped at FUZZ_MAX_STORED.
      class FuzzJob
        getter id : String
        getter total : Int64?
        property status : Symbol = :running # :running | :done | :stopped | :error
        property sent = 0_i64
        property matched = 0_i64
        property errors = 0_i64
        property error_msg : String? = nil
        getter results = [] of Fuzz::Result
        property? truncated = false

        def initialize(@id : String, @total : Int64?, @engine : Fuzz::Engine)
        end

        def stop : Nil
          @engine.stop
        end
      end

      # A background param-mining run, polled by mine_status / mine_results. Like FuzzJob,
      # only the runner fiber mutates these (single-threaded → no lock). `total` is the
      # name count (the stable denominator); findings are capped at MINE_MAX_STORED.
      class MineJob
        getter id : String
        getter total : Int64
        property status : Symbol = :running # :running | :done | :stopped | :error
        property names_done = 0_i64
        property sent = 0_i64
        property found = 0
        property errors = 0_i64
        property? baseline_stable = true
        property error_msg : String? = nil
        getter results = [] of Miner::Finding
        property? truncated = false

        def initialize(@id : String, @total : Int64, @engine : Miner::Engine)
        end

        def stop : Nil
          @engine.stop
        end
      end

      # Emits the tools/list array, honouring the action gate.
      def list(j : JSON::Builder) : Nil
        j.array do
          tool j, "list_history",
            "List captured HTTP flows, newest first. Optional gori QL `query` " \
            "filters (e.g. 'host:example.com status:>=500 size:>10000 dur:>500', " \
            "'header:set-cookie', 'body~secret\\d+' — `~` is regex, dur is ms); " \
            "empty query returns the most recent. Returns light rows (no bodies); " \
            "use get_flow for full detail. Paginate by passing the oldest id seen as " \
            "`before_id` (rows are newest-first); a page shorter than `limit` means no older rows. " \
            "Call ql_reference for full QL syntax." do |s|
            s.field "query", strprop("gori QL filter; empty = most recent")
            s.field "limit", intprop("max rows (default 50, max 500)")
            s.field "before_id", intprop("cursor: only flows with id < this (pagination; works with query too)")
          end

          tool j, "ql_reference",
            "Return the gori QL (query language) syntax reference for filtering flows " \
            "(list_history, list_sitemap). Call this before writing complex queries." { }

          tool j, "get_flow",
            "Full request+response for one flow id (heads + decoded bodies). " \
            "Bodies are de-chunked/decompressed and summarised: inline text when " \
            "UTF-8 (capped 64KB), else a base64 sample. Use get_response_body_chunk " \
            "with the same flow id to retrieve exact continuation bytes." do |s|
            s.field "id", intprop("flow id from list_history"), required: true
          end

          tool j, "get_response_body_chunk",
            "Read a byte range from a response body when get_flow/send_request reports truncation. " \
            "Pass exactly one of flow_id or repeater_id. Content encoding is decoded by default so " \
            "offsets continue the inline view; raw=true pages stored wire bytes. Returns UTF-8 text " \
            "or base64 plus next_offset/complete." do |s|
            s.field "flow_id", intprop("History flow id")
            s.field "repeater_id", intprop("Repeater workbench database id")
            s.field "offset", intprop("zero-based byte offset (default 0)")
            s.field "limit", intprop("bytes to return (default 65536, max 262144)")
            s.field "raw", boolprop("page stored response bytes without content decoding (default false)")
          end

          tool j, "list_sitemap",
            "Distinct endpoints (host, method, target) discovered in capture. " \
            "Optional QL `query` filter." do |s|
            s.field "query", strprop("gori QL filter")
            s.field "limit", intprop("max entries (default 200, max 5000)")
          end

          tool j, "list_findings",
            "List triage findings (severity + status), newest/most-severe first. " \
            "Returns an object {findings, returned, offset, total} — not a bare array." do |s|
            s.field "limit", intprop("max rows (default 100, max 500)")
            s.field "offset", intprop("start row (default 0)")
          end

          tool j, "get_finding", "Get one finding by id." do |s|
            s.field "id", intprop("finding id"), required: true
          end

          tool j, "list_scope", "List the project's scope include/exclude rules." { }

          tool j, "project_info",
            "Project totals: flow count, finding count, captured bytes, earliest capture time, " \
            "plus which project/db is being served and how it was selected. Always verify this " \
            "before reading or mutating security-test data." { }

          tool j, "get_current_context",
            "What the user is currently viewing in the gori TUI: active tab, focused pane, the " \
            "History-selected flow id (only when on the History tab), and sub-tab index — so you " \
            "can act on \"what I'm looking at right now\" without the user pasting ids. Reflects an " \
            "open (or last-open) gori TUI for THIS project. `age_seconds` shows how long since the " \
            "TUI last recorded focus (there is no live-TUI heartbeat) — use it to judge freshness; " \
            "`available:false` means the TUI never ran against this project." { }

          tool j, "get_repeater_context",
            "The Repeater workbench state. Defaults to metadata only so request headers, WebSocket " \
            "payloads, response headers, and the live TUI editor snapshot are not copied into the " \
            "model context. Set include_content=true only when those bytes are necessary. Supports " \
            "single-id lookup, pagination, and query filtering." do |s|
            s.field "id", intprop("return one repeater database id")
            s.field "limit", intprop("max rows to return (default 50, max 500)")
            s.field "offset", intprop("start row (default 0)")
            s.field "query", strprop("filter repeaters by name or target URL (case-insensitive substring match)")
            s.field "include_content", boolprop("include request text, WebSocket payloads, response head, and live TUI repeater snapshot (default false; may expose secrets)")
          end

          tool j, "list_notes", "List all project notes (markdown/text documents) with metadata like title and line count." { }

          tool j, "get_note", "Get the full text and metadata of a specific note by its database ID." do |s|
            s.field "id", intprop("database note ID"), required: true
          end

          tool j, "decode",
            "Run a gori Decoder chain (encode/decode/hash/compress) over `input` and return the " \
            "result — the same engine as the TUI Decoder tab. Pure transform: no network, no state. " \
            "`spec` is converter tokens separated by '>', '|' or ',' applied left-to-right, e.g. " \
            "'base64-decode > gunzip', 'url-encode', 'sha256'. Common converters: base64, " \
            "base64-decode, url-encode, url-decode, hex, hex-decode, gzip, gunzip, deflate, inflate, " \
            "jwt-decode, html-encode, md5, sha1, sha256. An unknown token returns the full list." do |s|
            s.field "input", strprop("the value to transform (UTF-8 text unless input_base64 is set)"), required: true
            s.field "spec", strprop("converter chain, e.g. 'base64-decode > gunzip'"), required: true
            s.field "input_base64", boolprop("treat `input` as base64 and decode it to raw bytes first (for binary input)")
          end

          tool j, "list_rules",
            "List the project's Match & Replace rules (literal substring rewrites applied to " \
            "in-flight request/response HEAD or BODY), in apply order." { }

          if @allow_actions
            tool j, "create_rule",
              "Add a Match & Replace rule (a literal substring rewrite applied to in-flight traffic). " \
              "Persisted to the project. Note: a gori TUI already running applies it only after its " \
              "rules reload (reopen the rules editor or restart); `gori run` and newly opened TUIs " \
              "pick it up immediately." do |s|
              s.field "pattern", strprop("literal substring to match"), required: true
              s.field "replacement", strprop("literal replacement (empty = delete the pattern; default empty)")
              s.field "target", strprop("request|response (default request)")
              s.field "part", strprop("head|body — head = request/status line + headers, body = entity body (default head)")
            end

            tool j, "set_rule_enabled", "Enable or disable a Match & Replace rule by id." do |s|
              s.field "id", intprop("rule id from list_rules"), required: true
              s.field "enabled", boolprop("true to enable, false to disable"), required: true
            end

            tool j, "delete_rule", "Delete a Match & Replace rule by id." do |s|
              s.field "id", intprop("rule id from list_rules"), required: true
            end

            tool j, "create_note", "Create a new note with optional text content." do |s|
              s.field "text", strprop("initial text content for the new note")
            end

            tool j, "update_note", "Update the text content of an existing note by its database ID." do |s|
              s.field "id", intprop("database note ID to update"), required: true
              s.field "text", strprop("new text content for the note"), required: true
            end

            tool j, "delete_note", "Delete a note by its database ID." do |s|
              s.field "id", intprop("database note ID to delete"), required: true
            end

            tool j, "send_request",
              "Send/repeater an HTTP request to its origin and return the response. " \
              "ACTIVE: makes a real outbound request from this host. Either pass " \
              "`flow_id` to repeater a captured flow byte-exact, OR give an absolute " \
              "`url` with optional method/headers/body, or a verbatim `raw` request. " \
              "When `flow_id` is set, url/method/headers/body/raw are ignored. " \
              "Host + Content-Length are auto-added when omitted on the url path." do |s|
              s.field "flow_id", intprop("repeater a captured flow by id (no url needed; like TUI repeater)")
              s.field "url", strprop("absolute URL incl. scheme+host, e.g. https://api.example.com/v1/x (required unless flow_id is given)")
              s.field "method", strprop("HTTP method (default GET)")
              s.field "headers", objprop("header name->value map")
              s.field "body", strprop("request body, sent as-is")
              s.field "raw", strprop("verbatim raw HTTP/1.1 request; overrides method/headers/body (scheme/host/port still come from url)")
              s.field "http2", boolprop("use real HTTP/2; defaults to the flow's version when flow_id is set)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "record_history", boolprop("record the outbound request and response in History for audit/evidence (default true)")
              s.field "save_as_repeater", boolprop("save this request and its response to the Repeater workbench (default false)")
              s.field "include_sensitive_headers", boolprop("return Cookie/Set-Cookie/Authorization/API-key response values instead of [REDACTED] (default false)")
              s.field "name", strprop("optional custom name for the saved repeater tab (only when save_as_repeater=true)")
              s.field "finding_id", intprop("optional finding to link to the saved repeater; requires save_as_repeater=true")
            end

            tool j, "send_websocket",
              "Execute a persisted WebSocket repeater: perform a fresh RFC 6455 handshake, send the " \
              "repeater's outbound messages (or a supplied override), and return inbound frames. " \
              "ACTIVE: makes a real outbound connection. The handshake response is persisted on " \
              "the repeater, while the outbound message template is left unchanged." do |s|
              s.field "repeater_id", intprop("WebSocket repeater database id"), required: true
              s.field "messages", strarrprop("optional outbound text-message override; stored repeater messages are used when absent")
              s.field "idle_ms", intprop("server-silence timeout after the first inbound frame (100-60000 ms; default 3000)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "finding_id", intprop("optional finding to link to this repeater before sending")
            end

            tool j, "create_repeater", "Create a new repeater tab/session in the database. Provide either ('target' and 'request') OR ('flow_id') OR ('finding_id')." do |s|
              s.field "target", strprop("absolute target URL (scheme+host+optional port), e.g. https://api.example.com")
              s.field "request", strprop("verbatim raw HTTP request bytes/text")
              s.field "http2", boolprop("use HTTP/2 (default false)")
              s.field "auto_content_length", boolprop("auto-calculate Content-Length header (default true)")
              s.field "flow_id", intprop("optional original flow id this repeater stems from")
              s.field "finding_id", intprop("optional finding id to populate target/request/messages from")
              s.field "position", intprop("tab position order index (optional, defaults to appending at end)")
              s.field "sni", strprop("optional TLS Server Name Indication override")
              s.field "mark_transform", boolprop("optional boolean indicating token substitution replacement is active (default false)")
              s.field "name", strprop("optional custom name for the repeater tab")
              s.field "ws_out_messages", arr_or_str_prop("optional array of strings (or a newline-separated string) representing outbound WebSocket messages")
            end

            tool j, "update_repeater", "Update an existing repeater tab's properties by database id." do |s|
              s.field "id", intprop("repeater database id"), required: true
              s.field "target", strprop("absolute target URL")
              s.field "request", strprop("verbatim raw HTTP request")
              s.field "http2", boolprop("use HTTP/2")
              s.field "auto_content_length", boolprop("auto-calculate Content-Length")
              s.field "sni", strprop("TLS SNI override")
              s.field "mark_transform", boolprop("token substitution replacement active")
              s.field "name", strprop("custom name for the repeater tab")
              s.field "ws_out_messages", arr_or_str_prop("optional array of strings (or a newline-separated string) representing outbound WebSocket messages")
            end

            tool j, "delete_repeater", "Delete a repeater tab by database id." do |s|
              s.field "id", intprop("repeater database id"), required: true
            end

            tool j, "create_finding", "Record a new finding in the project." do |s|
              s.field "title", strprop("finding title"), required: true
              s.field "severity", strprop("info|low|medium|high|critical (default info)")
              s.field "host", strprop("optional host the finding concerns")
              s.field "flow_id", intprop("optional flow id this finding links to")
              s.field "repeater_id", intprop("optional repeater id this finding links to")
            end

            tool j, "update_finding", "Update an existing finding's fields." do |s|
              s.field "id", intprop("finding id"), required: true
              s.field "title", strprop("new title")
              s.field "severity", strprop("info|low|medium|high|critical")
              s.field "notes", strprop("free-form notes (replaces existing)")
              s.field "status", strprop("open|confirmed|false-positive|resolved")
              s.field "repeater_id", intprop("optional repeater id to link to the finding")
            end

            tool j, "fuzz_start",
              "Start a fuzz/intruder run against an origin and return a job_id " \
              "immediately (poll with fuzz_status / fuzz_results; end with fuzz_stop). " \
              "ACTIVE: sends many real outbound requests from this host. Mark payload " \
              "positions with §…§ in `template`, via `marks` (literal token wrap, like " \
              "CLI --mark), or pass `flow_id` + auto:true, then provide payload sets via " \
              "`payloads`. Capped " \
              "at #{FUZZ_MAX_REQUESTS} requests / #{FUZZ_MAX_CONCURRENCY} concurrency." do |s|
              s.field "template", strprop("raw HTTP request with §…§ position markers")
              s.field "flow_id", intprop("seed the template from a captured flow id (instead of template)")
              s.field "url", strprop("absolute target URL (scheme+host); required unless flow_id carries one")
              s.field "auto", boolprop("auto-mark every query/cookie/body param when the template has no § markers")
              s.field "marks", strarrprop("literal tokens to mark as §…§ positions (each occurrence, mirrors CLI --mark); alternative to embedding §…§ in template")
              s.field "mode", strprop("sniper (default) | batteringram | pitchfork | clusterbomb")
              s.field "payloads", arrprop(%(array of payload sets, e.g. [{"list":["a","b"]},{"numbers":"1-100"},{"wordlist":"/p.txt"},{"null":5},{"brute":"abc:1-3"}] — JSON array, NOT a string))
              s.field "match", jsonprop(%(keep only responses matching, e.g. {"status":"200,500-599","size":">1000","regex":"err"} — object or JSON string))
              s.field "filter", jsonprop(%(drop responses matching, same shape as match — object or JSON string))
              s.field "extract", strprop("regex; grep a value (capture group 1) from each response")
              s.field "concurrency", intprop("parallel requests (default 20, max #{FUZZ_MAX_CONCURRENCY})")
              s.field "rate", intprop("requests/sec cap (0 = unlimited)")
              s.field "timeout_ms", intprop("per-request connect + idle (read/write) timeout in milliseconds")
              s.field "retries", intprop("retries per request on a network error")
              s.field "http2", boolprop("use real HTTP/2 (default false)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "max_requests", intprop("caller cap on total requests")
            end

            tool j, "fuzz_status", "Counts + state of a fuzz job (running|done|stopped|error)." do |s|
              s.field "job_id", strprop("id from fuzz_start"), required: true
            end

            tool j, "fuzz_results",
              "Paged matched results for a fuzz job (metrics only — status/length/words/" \
              "extracted; no raw bodies and no per-result flow id). To inspect a hit, " \
              "re-issue it with send_request, substituting the payload into your template." do |s|
              s.field "job_id", strprop("id from fuzz_start"), required: true
              s.field "offset", intprop("start row (default 0)")
              s.field "limit", intprop("max rows (default 100, max 1000)")
              s.field "matched_only", boolprop("no-op: fuzz results are stored matched-only, so this never changes the page")
            end

            tool j, "fuzz_stop", "Stop a running fuzz job (in-flight requests finish)." do |s|
              s.field "job_id", strprop("id from fuzz_start"), required: true
            end

            tool j, "mine_start",
              "Discover hidden/unlinked parameters a server accepts (Burp \"Param Miner\"). " \
              "Stuffs a built-in wordlist of names into the request and bisects to isolate " \
              "the ones that change the response. Returns a job_id immediately (poll with " \
              "mine_status / mine_results; end with mine_stop). ACTIVE: sends many real " \
              "outbound requests. Capped at #{MINE_MAX_REQUESTS} requests / #{MINE_MAX_CONCURRENCY} concurrency." do |s|
              s.field "template", strprop("raw HTTP request to mine")
              s.field "flow_id", intprop("seed the request from a captured flow id (instead of template)")
              s.field "url", strprop("absolute target URL (scheme+host); required unless flow_id carries one")
              s.field "locations", strprop("comma list of where to mine: query,form,json,headers,cookies (default: auto-detect)")
              s.field "wordlist", strprop("path to an extra param-name wordlist (merged with the built-in list)")
              s.field "bucket", intprop("names stuffed per request before bisection (per location)")
              s.field "concurrency", intprop("parallel requests (default 10, max #{MINE_MAX_CONCURRENCY})")
              s.field "rate", intprop("requests/sec cap (0 = unlimited)")
              s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds")
              s.field "retries", intprop("retries per request on a network error")
              s.field "http2", boolprop("use real HTTP/2 (default false)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "max_requests", intprop("caller cap on total requests")
            end

            tool j, "mine_status", "Counts + state of a mine job (running|done|stopped|error)." do |s|
              s.field "job_id", strprop("id from mine_start"), required: true
            end

            tool j, "mine_results",
              "Paged discovered parameters for a mine job (name, location, evidence, confidence, canary, status, delta)." do |s|
              s.field "job_id", strprop("id from mine_start"), required: true
              s.field "offset", intprop("start row (default 0)")
              s.field "limit", intprop("max rows (default 100, max 1000)")
            end

            tool j, "mine_stop", "Stop a running mine job (in-flight requests finish)." do |s|
              s.field "job_id", strprop("id from mine_start"), required: true
            end
          end
        end
      end

      # Dispatches a tools/call by name. Any store/repeater exception is converted to
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
        when "list_history"            then list_history(h)
        when "get_flow"                then get_flow(h)
        when "get_response_body_chunk" then get_response_body_chunk(h)
        when "list_sitemap"            then list_sitemap(h)
        when "list_findings"           then list_findings(h)
        when "get_finding"             then get_finding(h)
        when "list_scope"              then list_scope
        when "project_info"            then project_info
        when "get_current_context"     then get_current_context
        when "get_repeater_context"      then get_repeater_context(h)
        when "ql_reference"            then ql_reference
        when "list_notes"              then list_notes
        when "get_note"                then get_note(h)
        when "decode"                  then decoder(h)
        when "list_rules"              then list_rules
        end
      end

      # Action + write tools, each gated behind allow_actions. nil when `name`
      # isn't one of them.
      private def action_tool(name : String, h) : Result?
        case name
        when "send_request"     then gated { send_request(h) }
        when "send_websocket"   then gated { send_websocket(h) }
        when "create_repeater"    then gated { create_repeater(h) }
        when "update_repeater"    then gated { update_repeater(h) }
        when "delete_repeater"    then gated { delete_repeater(h) }
        when "create_finding"   then gated { create_finding(h) }
        when "update_finding"   then gated { update_finding(h) }
        when "fuzz_start"       then gated { fuzz_start(h) }
        when "fuzz_status"      then gated { fuzz_status(h) }
        when "fuzz_results"     then gated { fuzz_results(h) }
        when "fuzz_stop"        then gated { fuzz_stop(h) }
        when "mine_start"       then gated { mine_start(h) }
        when "mine_status"      then gated { mine_status(h) }
        when "mine_results"     then gated { mine_results(h) }
        when "mine_stop"        then gated { mine_stop(h) }
        when "create_note"      then gated { create_note(h) }
        when "update_note"      then gated { update_note(h) }
        when "delete_note"      then gated { delete_note(h) }
        when "create_rule"      then gated { create_rule(h) }
        when "set_rule_enabled" then gated { set_rule_enabled(h) }
        when "delete_rule"      then gated { delete_rule(h) }
        end
      end

      # --- read tools ---------------------------------------------------------

      private def list_history(h) : Result
        limit = clamp(int(h, "limit"), 50, 500)
        before_id = int(h, "before_id")
        query = str(h, "query")
        rows =
          if query && !query.strip.empty?
            filter = QL.parse(query)
            return ql_error(query) if QL.reject_empty?(query, filter)
            @store.search(filter, limit, before_id)
          else
            @store.recent_flows(limit, before_id)
          end
        Result.new(JSON.build { |j| j.array { rows.each { |r| Serialize.flow_row(j, r) } } })
      end

      private def get_flow(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        detail = @store.get_flow(id)
        return Result.new("no flow with id #{id}", is_error: true) unless detail
        # A WebSocket flow (101) carries a separate message log; fetch it so get_flow
        # surfaces the frames (parity with `gori run show`). Non-WS flows skip the query.
        ws_msgs = detail.row.status == 101 ? @store.ws_messages(id) : [] of Store::WsMessage
        Result.new(Serialize.flow_detail_json(detail, ws_msgs))
      end

      private def get_response_body_chunk(h) : Result
        options = body_chunk_options(h)

        loaded = load_response_body(options.flow_id, options.repeater_id)
        return loaded if loaded.is_a?(Result)
        head, body = loaded
        stored = body || Bytes.new(0)
        decoded, decode_note = options.raw ? {nil, nil} : Proxy::Codec::ContentDecode.decode(head, stored)
        bytes = decoded || stored
        total = bytes.size.to_i64
        start = Math.min(options.offset, total).to_i
        count = Math.min(options.limit, bytes.size - start)
        chunk = count.zero? ? Bytes.new(0) : bytes[start, count]
        next_offset = start.to_i64 + count
        text = String.new(chunk)

        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id", options.flow_id
            j.field "repeater_id", options.repeater_id
            j.field "offset", start
            j.field "returned_bytes", count
            j.field "total_bytes", total
            j.field "representation", decoded ? "decoded" : "raw"
            j.field "decode_note", decode_note if decode_note
            j.field "complete", next_offset >= total
            j.field "next_offset", next_offset < total ? next_offset : nil
            if text.valid_encoding?
              j.field "encoding", "text"
              j.field "text", text
            else
              j.field "encoding", "base64"
              j.field "base64", Base64.strict_encode(chunk)
            end
          end
        end)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid response-body arguments", is_error: true)
      end

      private def body_chunk_options(h) : BodyChunkOptions
        flow_id = optional_int_arg(h, "flow_id")
        repeater_id = optional_int_arg(h, "repeater_id")
        if flow_id.nil? == repeater_id.nil?
          raise Gori::Error.new("pass exactly one of flow_id or repeater_id")
        end
        offset = bounded_int_arg(h, "offset", 0_i64, min: 0_i64)
        limit = bounded_int_arg(h, "limit", 65_536_i64, min: 1_i64, max: 262_144_i64).to_i
        BodyChunkOptions.new(flow_id, repeater_id, offset, limit, bool_arg(h, "raw", false))
      end

      private def load_response_body(flow_id : Int64?, repeater_id : Int64?) : {Bytes?, Bytes?} | Result
        if id = flow_id
          detail = @store.get_flow(id)
          return Result.new("no flow with id #{id}", is_error: true) unless detail
          {detail.response_head, detail.response_body}
        elsif id = repeater_id
          repeater = @store.get_repeater_full(id)
          return Result.new("no repeater with id #{id}", is_error: true) unless repeater
          {repeater.response_head, repeater.response_body}
        else
          Result.new("pass exactly one of flow_id or repeater_id", is_error: true)
        end
      end

      private def list_sitemap(h) : Result
        limit = clamp(int(h, "limit"), 200, 5000)
        query = str(h, "query")
        filter =
          if query && !query.strip.empty?
            parsed = QL.parse(query)
            return ql_error(query) if QL.reject_empty?(query, parsed)
            parsed
          else
            QL::EMPTY
          end
        entries = @store.sitemap_entries(filter, limit)
        Result.new(JSON.build do |j|
          j.array do
            entries.each do |(host, method, target)|
              j.object { j.field "host", host; j.field "method", method; j.field "target", target }
            end
          end
        end)
      end

      private def list_findings(h) : Result
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 500)
        all = @store.findings
        page = all[offset, limit]? || [] of Store::Finding
        Result.new(JSON.build do |j|
          j.object do
            j.field("findings") { j.array { page.each { |f| Serialize.finding(j, f, @store) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "total", all.size
          end
        end)
      end

      private def get_finding(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        f = @store.get_finding(id)
        return Result.new("no finding with id #{id}", is_error: true) unless f
        Result.new(JSON.build { |j| Serialize.finding(j, f, @store) })
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
            j.field "project", @project_name
            j.field "project_slug", @project_slug
            j.field "db_path", @db_path
            j.field "selection_source", @selection_source
            j.field "workspace_root", @workspace_root
            j.field "workspace_bound", !@workspace_root.nil?
            j.field "read_only", !@allow_actions
            j.field "flows", @store.count
            j.field "findings", @store.count_findings
            j.field "total_bytes", @store.total_size
            j.field "earliest_created_at", @store.earliest_created_at
            if ea = @store.earliest_created_at
              j.field "earliest_created_at_iso", Serialize.unix_micros_iso(ea)
            end
          end
        end)
      end

      # What the user is currently viewing in the gori TUI, recorded cross-process to the
      # project store (Store::UI_STATE_KEY) by the running TUI. Read-only. The ui-state lives in
      # THIS project's db, so it always describes this project — freshness is reported via
      # age_seconds (there is no live-TUI heartbeat), not a name comparison that would skew on
      # display-name-vs-slug.
      private def get_current_context : Result
        raw = @store.setting(Store::UI_STATE_KEY)
        parsed = raw.try do |r|
          begin
            obj = JSON.parse(r)
            # Must decode to a JSON OBJECT: valid-but-wrong-shape JSON (an array,
            # scalar, or null) would make `parsed["active_tab"]?` below raise a raw
            # "Expected Hash for #[]?" cast error — treat it as unreadable instead.
            obj if obj.as_h?
          rescue
            nil
          end
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "project", @project_name # the project/db this server serves
            if parsed.nil?
              j.field "available", false
              j.field "note", raw.nil? ? "No UI state recorded for this project — the gori TUI may not have run against it." : "Recorded UI state was unreadable."
            else
              j.field "available", true
              j.field "project", @project_name
              j.field "project_slug", @project_slug
              j.field "active_tab", parsed["active_tab"]?.try(&.as_s?)
              j.field "focus_pane", parsed["focus_pane"]?.try(&.as_s?)
              if fid = parsed["selected_flow_id"]?.try(&.as_i64?)
                j.field "selected_flow_id", fid
              end
              if st = parsed["subtab"]?.try(&.as_i64?)
                j.field "subtab", st
              end
              if rec = parsed["recorded_at"]?.try(&.as_i64?)
                j.field "recorded_at", rec
                # A corrupt/out-of-range recorded_at must not sink the whole tool: Time.unix_ms
                # raises on out-of-range, so guard it — keep the raw value, drop derived fields.
                iso = begin
                  Time.unix_ms(rec).to_rfc3339
                rescue
                  nil
                end
                if iso
                  j.field "recorded_at_iso", iso
                  j.field "age_seconds", (Time.utc.to_unix_ms - rec) // 1000
                end
              end
            end
          end
        end)
      end

      private def get_repeater_context(h) : Result
        ui = parse_ui_state
        repeater_id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if repeater_id.nil? && present?(h, "id")
        include_content = bool(h, "include_content")
        if include_content.nil? && present?(h, "include_content")
          return Result.new("invalid 'include_content' (expected true or false)", is_error: true)
        end
        include_content = include_content || false
        limit = clamp(int(h, "limit"), 50, 500)
        offset = clamp_nonneg(int(h, "offset"))
        query_str = str(h, "query").try(&.strip)
        query_rx = query_str.try { |q| q.empty? ? nil : Regex.new(Regex.escape(q), Regex::Options::IGNORE_CASE) }

        all_repeaters = @store.repeaters_mcp
        if repeater_id && !all_repeaters.any? { |r| r.id == repeater_id }
          return Result.new("no repeater with id #{repeater_id}", is_error: true)
        end
        all_repeaters = all_repeaters.select { |r| r.id == repeater_id } if repeater_id

        filtered_repeaters = if rx = query_rx
                             all_repeaters.select do |r|
                               r.target.matches?(rx) ||
                                 r.name.try(&.matches?(rx)) ||
                                 r.request.matches?(rx)
                             end
                           else
                             all_repeaters
                           end

        total_count = filtered_repeaters.size
        paginated_repeaters = if offset >= filtered_repeaters.size
                              [] of Store::RepeaterRecord
                            else
                              filtered_repeaters[offset, Math.min(limit, filtered_repeaters.size - offset)]
                            end

        Result.new(JSON.build do |j|
          j.object do
            j.field "project", @project_name
            j.field "project_slug", @project_slug
            j.field "db_path", @db_path
            on_repeater = ui.try { |u| u["active_tab"]?.try(&.as_s?) == "repeater" } || false
            j.field "tui_on_repeater_tab", on_repeater
            if ui
              if rec = ui["recorded_at"]?.try(&.as_i64?)
                j.field "ui_recorded_at", rec
                iso = begin
                  Time.unix_ms(rec).to_rfc3339
                rescue
                  nil
                end
                if iso
                  j.field "ui_recorded_at_iso", iso
                  j.field "ui_age_seconds", (Time.utc.to_unix_ms - rec) // 1000
                end
              end
              if include_content && (repeater = ui["repeater"]?)
                j.field "tui_repeater", repeater
              elsif ui["repeater"]?
                j.field "tui_repeater_available", true
              end
            end
            j.field "content_included", include_content
            j.field "total_count", total_count
            j.field "offset", offset
            j.field "limit", limit
            j.field "sessions" do
              j.array do
                paginated_repeaters.each do |r|
                  emit_repeater_session(j, r, include_content)
                end
              end
            end
            unless on_repeater
              j.field "note", "TUI is not on the Repeater tab — `tui_repeater` may be stale; use `sessions` for persisted tabs."
            end
          end
        end)
      end

      private def emit_repeater_sessions(j : JSON::Builder, include_content : Bool = false) : Nil
        @store.repeaters_mcp.each do |r|
          emit_repeater_session(j, r, include_content)
        end
      end

      private def emit_repeater_session(j : JSON::Builder, r : Store::RepeaterRecord,
                                      include_content : Bool = false) : Nil
        j.object do
          j.field "db_id", r.id
          j.field "position", r.position
          j.field "target", r.target
          j.field "http2", r.http2?
          j.field "auto_content_length", r.auto_content_length?
          j.field "mark_transform", r.mark_transform?
          j.field "flow_id", r.flow_id if r.flow_id
          j.field "name", r.name if r.name
          j.field "sni", r.sni if r.sni
          emit_capped_text(j, "request", r.request) if include_content

          if Repeater::WsEngine.upgrade_request?(r.request)
            ws_msgs = @store.ws_messages_for_repeater(r.id)
            j.field "ws_mode", true
            j.field "ws_message_count", ws_msgs.size
            j.field "ws_messages" do
              j.array do
                ws_msgs.each do |m|
                  j.object do
                    j.field "direction", m.direction
                    j.field "opcode", m.opcode
                    if m.text?
                      j.field "payload", String.new(m.payload).scrub
                    else
                      # A binary frame carries arbitrary octets; emitting them as a raw
                      # string would put invalid UTF-8 on the stdio JSON-RPC stream (which
                      # must be well-formed UTF-8). Base64 it, like Serialize.emit_ws_messages.
                      j.field "binary", true
                      j.field "payload_base64", Base64.strict_encode(m.payload)
                    end
                  end
                end
              end
            end if include_content
          end

          if err = r.response_error
            j.field "last_error", err
          end
          if d = r.response_duration_us
            j.field "last_duration_us", d
          end
          if head = r.response_head
            resp = begin
              Proxy::Codec::Http1.parse_response_head(head)
            rescue
              nil
            end
            if resp
              j.field "last_status", resp.status
              j.field "last_reason", resp.reason
            end
            j.field "last_response_head", Serialize.head_text(head) if include_content
          end
        end
      end

      private def emit_capped_text(j : JSON::Builder, field : String, text : String) : Nil
        if text.bytesize > MCP_REPEATER_REQUEST_MAX
          # Compare and cut by BYTES (the cap is a byte budget), then scrub — a slice
          # through a multi-byte UTF-8 sequence would otherwise emit invalid UTF-8 into
          # the JSON-RPC stream, which must be well-formed UTF-8 over the stdio transport.
          j.field field, text.byte_slice(0, MCP_REPEATER_REQUEST_MAX).scrub
          j.field "#{field}_truncated", true
        else
          # Scrub here too: a repeater request built from a binary/non-UTF-8 body round-trips
          # invalid UTF-8 through the store, and JSON::Builder emits it verbatim — which
          # corrupts the stdio JSON-RPC stream (must be well-formed UTF-8).
          j.field field, text.scrub
        end
      end

      private def parse_ui_state : JSON::Any?
        @store.setting(Store::UI_STATE_KEY).try do |r|
          begin
            obj = JSON.parse(r)
            obj if obj.as_h?
          rescue
            nil
          end
        end
      end

      private def ql_reference : Result
        Result.new(JSON.build { |j| j.object { j.field "reference", QL::REFERENCE } })
      end

      private def ql_error(query : String) : Result
        Result.new(
          "invalid query #{query.inspect}: did not match any field " \
          "(call ql_reference; e.g. host:example.com status:>=500 method:POST)",
          is_error: true)
      end

      private def list_notes : Result
        doc = Notes.load(@store)
        Result.new(JSON.build do |j|
          j.object do
            j.field "cur", doc.cur
            j.field "notes" do
              j.array do
                doc.notes.each_with_index do |entry, idx|
                  j.object do
                    j.field "id", entry.id
                    j.field "title", Notes.title(entry.text) || "Untitled"
                    j.field "line_count", Notes.line_count(entry.text)
                    j.field "current", doc.cur == idx
                  end
                end
              end
            end
          end
        end)
      end

      private def get_note(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        doc = Notes.load(@store)
        entry = doc.notes.find { |n| n.id == id }
        return Result.new("no note with id #{id}", is_error: true) unless entry
        idx = doc.notes.index(entry).not_nil!
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", entry.id
            j.field "text", entry.text
            j.field "title", Notes.title(entry.text) || "Untitled"
            j.field "current", doc.cur == idx
          end
        end)
      end

      # --- action / write tools (gated) ---------------------------------------

      private def send_request(h) : Result
        save = bool_arg(h, "save_as_repeater", false)
        record_history = bool_arg(h, "record_history", true)
        include_sensitive_headers = bool_arg(h, "include_sensitive_headers", false)
        finding_id = int(h, "finding_id")
        return Result.new(id_error(h, "finding_id"), is_error: true) if finding_id.nil? && present?(h, "finding_id")
        if finding_id
          return Result.new("finding_id requires save_as_repeater=true", is_error: true) unless save
          return Result.new("no finding with id #{finding_id}", is_error: true) unless @store.get_finding(finding_id)
        end

        built, http2, sni = build_send_request(h)
        recorded_flow_id = record_history ? record_outbound_request(built, http2) : nil
        verify = @verify_upstream && !(bool(h, "insecure") || false)
        result = send_built_request(built, http2, verify, sni)
        record_outbound_response(recorded_flow_id, result) if recorded_flow_id
        # Audit trail on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "send_request #{built.scheme}://#{built.host}:#{built.port} http2=#{http2} flow_id=#{recorded_flow_id || "none"} -> #{result.ok? ? "ok" : result.error}" }

        repeater_id = persist_send_repeater(h, save, built, http2, result,
          finding_id, recorded_flow_id)

        Result.new(send_result_json(result, recorded_flow_id, repeater_id,
          include_sensitive_headers), is_error: !result.ok?)
      rescue ex : Gori::Error
        # Bad input (missing/invalid url, illegal header, …) — return a clean
        # actionable message instead of letting call()'s generic "tool error:"
        # wrapper swallow it, matching fuzz_start's FuzzArgError handling.
        Result.new(ex.message || "invalid request arguments", is_error: true)
      end

      private def send_built_request(built : RequestBuilder::Built, http2 : Bool,
                                     verify_upstream : Bool, sni : String? = nil) : Repeater::Result
        if http2
          Repeater::H2Engine.send(built.bytes, scheme: built.scheme, host: built.host,
            port: built.port, verify_upstream: verify_upstream, sni: sni)
        else
          Repeater::Engine.send(built.bytes, scheme: built.scheme, host: built.host,
            port: built.port, verify_upstream: verify_upstream, sni: sni)
        end
      end

      private def persist_send_repeater(h, save : Bool, built : RequestBuilder::Built,
                                      http2 : Bool, result : Repeater::Result,
                                      finding_id : Int64?, recorded_flow_id : Int64?) : Int64?
        return nil unless save
        port_suffix = ((built.scheme == "https" && built.port == 443) ||
                       (built.scheme == "http" && built.port == 80)) ? "" : ":#{built.port}"
        target_url = "#{built.scheme}://#{built.host}#{port_suffix}"
        # Preserve the original source flow for a flow repeater; otherwise link
        # the Repeater tab to the newly recorded History evidence.
        flow_id = int(h, "flow_id") || recorded_flow_id
        masked_target = Env.mask_secrets(target_url)
        masked_req = Env.mask_secrets(String.new(built.bytes))
        repeater_id = @store.insert_repeater(
          target: masked_target,
          request: masked_req,
          http2: http2,
          auto_cl: true,
          flow_id: flow_id,
          position: @store.repeaters_meta.size.to_i32,
          sni: nil,
          mark_transform: false
        )
        return nil unless repeater_id > 0

        @store.add_link(Store::LinkOwnerKind::Finding, finding_id,
          Store::LinkRefKind::Repeater, repeater_id) if finding_id
        if (name = str(h, "name")) && !name.empty?
          @store.set_repeater_name(repeater_id, Env.mask_secrets(name))
        end

        # Persist whatever was received even when framing failed after the
        # response head. This keeps partial evidence and enables paged reads.
        @store.update_repeater_response(repeater_id, result.head, result.body,
          result.error, result.duration_us)
        if result.response
          prism_scan_saved_repeater(repeater_id, masked_target, masked_req, http2, flow_id,
            result.head, result.body, result.duration_us)
        end
        repeater_id
      end

      private def record_outbound_request(built : RequestBuilder::Built, http2 : Bool) : Int64
        head, body = split_wire_request(built.bytes)
        parsed = Proxy::Codec::Http1.parse_request_head(head)
        captured = Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: built.scheme,
          host: built.host,
          port: built.port,
          method: parsed.method,
          target: parsed.target,
          http_version: http2 ? "HTTP/2" : parsed.version,
          head: head,
          body: body,
          body_size: body.try(&.size.to_i64),
        )
        id = @store.insert_flow(captured)
        if id <= 0
          raise Gori::Error.new("could not record outbound request in History; pass record_history=false only if an unaudited send is intentional")
        end
        id
      end

      private def record_outbound_response(flow_id : Int64, result : Repeater::Result) : Nil
        if response = result.response
          error = result.error
          error ||= "upstream response body was incomplete" if result.incomplete?
          state = error ? Store::FlowState::Error : Store::FlowState::Complete
          @store.update_response(FlowMapper.response(response,
            flow_id: flow_id,
            body: result.body,
            duration_us: result.duration_us,
            state: state,
            error: error,
            body_size: result.body.try(&.size.to_i64)))
        else
          @store.update_response(FlowMapper.error_response(flow_id,
            result.error || "request failed before a response was received"))
        end
      rescue ex
        # The request already left the host. Keep its result usable, but surface
        # a failed evidence update on STDERR (never the JSON-RPC channel).
        Log.error(exception: ex) { "send_request: failed to finalize History flow #{flow_id}" }
      end

      private def split_wire_request(bytes : Bytes) : {Bytes, Bytes?}
        boundary = nil.as(Int32?)
        i = 0
        while i + 3 < bytes.size
          if bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8 &&
             bytes[i + 2] == 0x0d_u8 && bytes[i + 3] == 0x0a_u8
            boundary = i + 4
            break
          end
          i += 1
        end
        raise Gori::Error.new("request has no CRLF header terminator; cannot record it in History") unless boundary
        head = bytes[0, boundary]
        body_size = bytes.size - boundary
        body = body_size > 0 ? bytes[boundary, body_size] : nil
        {head, body}
      end

      private def send_result_json(result : Repeater::Result, recorded_flow_id : Int64?,
                                   repeater_id : Int64?, include_sensitive_headers : Bool) : String
        JSON.build do |j|
          j.object do
            j.field "recorded_flow_id", recorded_flow_id
            j.field "saved_repeater_id", repeater_id if repeater_id && repeater_id > 0
            j.field "error", result.error unless result.ok?
            if response = result.response
              j.field "status", response.status
              j.field "reason", response.reason
              j.field "http_version", response.version
              redacted = false
              j.field "headers" do
                j.array do
                  response.headers.each do |header|
                    sensitive = sensitive_header?(header.name) && !include_sensitive_headers
                    redacted ||= sensitive
                    j.object do
                      j.field "name", header.name
                      j.field "value", sensitive ? "[REDACTED]" : header.value
                    end
                  end
                end
              end
              j.field "sensitive_headers_redacted", redacted
            end
            j.field "duration_us", result.duration_us
            j.field "incomplete", true if result.incomplete?
            Serialize.emit_body(j, "body", result.head, result.body, false)
          end
        end
      end

      private def sensitive_header?(name : String) : Bool
        name.downcase.in?("authorization", "proxy-authorization", "cookie", "set-cookie",
          "x-api-key", "api-key", "x-auth-token")
      end

      # Execute a stored WebSocket repeater from MCP. Unlike send_request, this uses
      # WsEngine's fresh Sec-WebSocket-Key + framed message exchange and therefore
      # returns the inbound transcript instead of stopping at the 101 response.
      private def send_websocket(h) : Result
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) unless repeater_id
        repeater = @store.get_repeater(repeater_id)
        return Result.new("no repeater with id #{repeater_id}", is_error: true) unless repeater
        unless Repeater::WsEngine.upgrade_request?(repeater.request)
          return Result.new("repeater #{repeater_id} is not a WebSocket upgrade request", is_error: true)
        end

        finding_id = int(h, "finding_id")
        return Result.new(id_error(h, "finding_id"), is_error: true) if finding_id.nil? && present?(h, "finding_id")
        if finding_id
          return Result.new("no finding with id #{finding_id}", is_error: true) unless @store.get_finding(finding_id)
          @store.add_link(Store::LinkOwnerKind::Finding, finding_id,
            Store::LinkRefKind::Repeater, repeater_id)
        end

        idle_ms = int(h, "idle_ms")
        return Result.new(id_error(h, "idle_ms"), is_error: true) if idle_ms.nil? && present?(h, "idle_ms")
        idle = (idle_ms || 3000_i64).clamp(100_i64, 60_000_i64).milliseconds

        out_messages = if present?(h, "messages")
                         arr = h["messages"]?.try(&.as_a?)
                         return Result.new("invalid 'messages' (expected an array of strings)", is_error: true) unless arr
                         parsed = [] of Repeater::WsEngine::OutMsg
                         arr.each do |item|
                           text = item.as_s?
                           return Result.new("invalid 'messages' (expected an array of strings)", is_error: true) unless text
                           parsed << Repeater::WsEngine::OutMsg.new(1, Env.expand(text).to_slice)
                         end
                         parsed
                       else
                         @store.ws_messages_for_repeater(repeater_id).compact_map do |m|
                           next unless m.direction == "out"
                           payload = m.text? ? Env.expand(String.new(m.payload).scrub).to_slice : m.payload
                           Repeater::WsEngine::OutMsg.new(m.opcode, payload)
                         end
                       end

        target = Env.expand(repeater.target)
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        return Result.new("could not parse target for repeater #{repeater_id}", is_error: true) if host.empty? || port <= 0
        verify = @verify_upstream && !(bool(h, "insecure") || false)
        request = Env.expand_wire(repeater.request)
        sni = repeater.sni.try { |value| Env.expand(value) }
        result = Repeater::WsEngine.send(request, out_messages,
          scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni, idle: idle)

        @store.update_repeater_response(repeater_id, result.handshake_head, Bytes.empty,
          result.error, result.duration_us)
        Log.info { "send_websocket #{scheme}://#{host}:#{port} repeater_id=#{repeater_id} -> #{result.ok? ? "ok" : result.error}" }

        payload = JSON.build do |j|
          j.object do
            j.field "repeater_id", repeater_id
            j.field "upgraded", result.upgraded?
            j.field "duration_us", result.duration_us
            j.field "close_code", result.close_code if result.close_code
            j.field "note", Env.mask_secrets(result.note.not_nil!) if result.note
            j.field "error", Env.mask_secrets(result.error.not_nil!) if result.error
            unless result.handshake_head.empty?
              response = begin
                Proxy::Codec::Http1.parse_response_head(result.handshake_head)
              rescue
                nil
              end
              j.field "handshake_status", response.status if response
            end
            j.field "messages" do
              j.array do
                result.messages.each do |message|
                  j.object do
                    j.field "direction", message.direction
                    j.field "opcode", message.opcode
                    if message.opcode == 1
                      j.field "payload", Env.mask_secrets(String.new(message.payload).scrub)
                    else
                      j.field "binary", true
                      j.field "payload_base64", Base64.strict_encode(message.payload)
                    end
                  end
                end
              end
            end
          end
        end
        Result.new(payload, is_error: !result.ok?)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid WebSocket request arguments", is_error: true)
      end

      # Either repeaters a captured flow (flow_id) or builds from url/raw/method args.
      # Returns {request bytes + target, use-h2, captured TLS SNI (flow path only)}.
      private def build_send_request(h) : {RequestBuilder::Built, Bool, String?}
        if present?(h, "flow_id")
          id = int(h, "flow_id")
          raise Gori::Error.new(id_error(h, "flow_id")) unless id
          detail = @store.get_flow(id)
          raise Gori::Error.new("no flow with id #{id}") unless detail
          flow = Repeater::FlowRequest.build(detail)
          # Re-sync Content-Length after expansion (a body `$KEY` changes its length).
          bytes = Repeater::FlowRequest.resync_content_length(Env.expand_wire(String.new(flow.bytes)))
          target = Env.expand(flow.target)
          scheme, host, port = Repeater::FlowRequest.parse_target(target)
          raise Gori::Error.new("could not parse target from flow #{id}") if host.empty?
          # Default to how the flow was captured, but honor an EXPLICIT http2 either way —
          # `bool_arg` returns `flow.http2` only when the arg is absent, so `http2:false`
          # can now downgrade an h2 capture to h1 (it used to be silently ignored because
          # `false || flow.http2` kept h2). Carry the captured SNI so an origin where
          # SNI ≠ Host (domain fronting / multi-cert vhost) presents the right certificate,
          # matching `gori run repeater`.
          http2 = bool_arg(h, "http2", flow.http2)
          {RequestBuilder::Built.new(bytes, scheme, host, port), http2, flow.sni}
        else
          built = RequestBuilder.build(h)
          {built, bool_arg(h, "http2", false), nil}
        end
      end

      private def create_finding(h) : Result
        title = str(h, "title")
        return Result.new("missing required 'title'", is_error: true) if title.nil? || title.empty?
        # Mask secrets in finding title
        masked_title = Env.mask_secrets(title)

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
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) if repeater_id.nil? && present?(h, "repeater_id")
        if repeater_id && !@store.get_repeater(repeater_id)
          return Result.new("no repeater with id #{repeater_id}", is_error: true)
        end

        host = str(h, "host").try { |hst| Env.mask_secrets(hst) }
        id = @store.insert_finding(masked_title, severity, host, flow_id)
        # insert_finding returns 0 (never raises) when the write batch fails — e.g.
        # the cross-process SQLite lock couldn't be acquired (a TUI capturing into
        # the same project) or the disk is full. Don't report a phantom success.
        return Result.new("failed to persist finding (store busy or unwritable)", is_error: true) if id == 0
        if repeater_id
          @store.add_link(Store::LinkOwnerKind::Finding, id,
            Store::LinkRefKind::Repeater, repeater_id)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "repeater_id", repeater_id if repeater_id
          end
        end)
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

        title = str(h, "title").try { |t| Env.mask_secrets(t) }
        return Result.new("title must not be empty", is_error: true) if title && title.empty?
        notes = str(h, "notes").try { |n| Env.mask_secrets(n) }
        severity = severity_from(sev_s)
        status = status_from(stat_s)
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) if repeater_id.nil? && present?(h, "repeater_id")
        if repeater_id && !@store.get_repeater(repeater_id)
          return Result.new("no repeater with id #{repeater_id}", is_error: true)
        end

        # Don't claim updated:true on a no-op. With no resolvable field the store
        # write is a silent no-op, so returning success would mislead the caller
        # (e.g. it'd think a typo'd field name took effect).
        if title.nil? && severity.nil? && notes.nil? && status.nil? && repeater_id.nil?
          return Result.new("no fields to update (provide at least one of title/severity/notes/status)", is_error: true)
        end

        unless title.nil? && severity.nil? && notes.nil? && status.nil?
          @store.update_finding(id, title: title, severity: severity, notes: notes, status: status)
        end
        if repeater_id
          @store.add_link(Store::LinkOwnerKind::Finding, id,
            Store::LinkRefKind::Repeater, repeater_id)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "updated", true
            j.field "repeater_id", repeater_id if repeater_id
          end
        end)
      end

      private def create_note(h) : Result
        text = str(h, "text") || ""
        doc = Notes.load(@store)
        new_id = doc.next_id
        new_entry = Notes::NoteEntry.new(new_id, text)
        new_notes = doc.notes + [new_entry]
        new_cur = new_notes.size - 1
        new_next_id = new_id + 1

        serialized = Notes.serialize(new_cur, new_notes, new_next_id)
        @store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", new_id
            j.field "message", "Note created successfully"
          end
        end)
      end

      private def update_note(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        text = str(h, "text")
        return Result.new("missing 'text' parameter", is_error: true) unless text

        doc = Notes.load(@store)
        entry_idx = doc.notes.index { |n| n.id == id }
        return Result.new("no note with id #{id}", is_error: true) unless entry_idx

        updated_entry = Notes::NoteEntry.new(id, text)
        new_notes = doc.notes.dup
        new_notes[entry_idx] = updated_entry

        serialized = Notes.serialize(doc.cur, new_notes, doc.next_id)
        @store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "message", "Note updated successfully"
          end
        end)
      end

      private def delete_note(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id

        doc = Notes.load(@store)
        entry_idx = doc.notes.index { |n| n.id == id }
        return Result.new("no note with id #{id}", is_error: true) unless entry_idx

        new_notes = doc.notes.dup
        new_notes.delete_at(entry_idx)
        new_cur = doc.cur.clamp(0, {new_notes.size - 1, 0}.max)

        serialized = Notes.serialize(new_cur, new_notes, doc.next_id)
        @store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "message", "Note deleted successfully"
          end
        end)
      end

      # Run a Decoder chain over caller-supplied bytes. Pure: no store, no network,
      # so it's a read tool (always exposed). A failed/unknown step is a tool-level
      # error; an unknown token also enumerates the registry so the model can retry.
      private def decoder(h) : Result
        spec = str(h, "spec")
        return Result.new("missing required 'spec'", is_error: true) if spec.nil? || spec.strip.empty?
        # A spec that is only separators (">", ",", "|") parses to zero tokens, which
        # Chain.run treats as identity — reject it rather than reporting a phantom
        # "success" that echoes the input back unchanged.
        return Result.new("'spec' has no converter tokens (e.g. 'base64-decode > gunzip')", is_error: true) if Decoder.parse_spec(spec).empty?
        raw = str(h, "input")
        return Result.new("missing required 'input'", is_error: true) if raw.nil?

        input =
          if bool(h, "input_base64")
            begin
              Base64.decode(raw)
            rescue
              return Result.new("invalid 'input': input_base64 is set but the value is not valid base64", is_error: true)
            end
          else
            raw.to_slice
          end

        reg = Decoder.shared_registry
        result = Decoder.run(reg, input, spec)

        if (idx = result.failed_at)
          step = result.steps[idx]
          msg = "decoder failed at step #{idx + 1} '#{step.token}': #{step.error || "failed"}"
          msg += " — available converters: #{reg.names.join(", ")}" if step.state.unknown?
          return Result.new(msg, is_error: true)
        end

        out_bytes = result.output || Bytes.empty
        text, mode = Decoder.display(out_bytes)
        # Bound the channel: Chain.run caps a step at 32 MiB, far too large to return
        # inline. Truncate on a byte budget and scrub so a split multibyte char can't
        # emit invalid UTF-8 into the JSON string; `output_bytes` keeps the true size.
        truncated = text.bytesize > DECODER_MAX_OUTPUT
        text = text.byte_slice(0, DECODER_MAX_OUTPUT).scrub if truncated

        Result.new(JSON.build do |j|
          j.object do
            j.field "spec", spec
            j.field "output", text
            j.field "output_encoding", mode.to_s.downcase
            j.field "output_bytes", out_bytes.size
            j.field("output_truncated", true) if truncated
            j.field "steps" do
              j.array do
                result.steps.each do |s|
                  j.object do
                    j.field "converter", s.name
                    j.field "state", s.state.to_s.downcase
                  end
                end
              end
            end
          end
        end)
      end

      private def list_rules : Result
        rules = @store.match_rules
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", rules.size
            j.field "rules" do
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "enabled", r.enabled?
                    j.field "target", r.target.label
                    j.field "part", r.part.label
                    j.field "pattern", r.pattern
                    j.field "replacement", r.replacement
                  end
                end
              end
            end
          end
        end)
      end

      private def create_rule(h) : Result
        pattern = str(h, "pattern")
        return Result.new("missing required 'pattern'", is_error: true) if pattern.nil? || pattern.empty?

        tgt_s = str(h, "target").try(&.strip)
        target = tgt_s.nil? || tgt_s.empty? ? Store::RuleTarget::Request : Store::RuleTarget.parse?(tgt_s)
        return Result.new("invalid 'target' (expected request|response)", is_error: true) unless target

        part_s = str(h, "part").try(&.strip)
        part = part_s.nil? || part_s.empty? ? Store::RulePart::Head : Store::RulePart.parse?(part_s)
        return Result.new("invalid 'part' (expected head|body)", is_error: true) unless part

        replacement = str(h, "replacement") || ""
        id = @store.insert_rule(target, part, pattern, replacement)
        return Result.new("failed to persist rule (store busy or unwritable)", is_error: true) if id == 0
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "target", target.label
            j.field "part", part.label
          end
        end)
      end

      private def set_rule_enabled(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        enabled = bool(h, "enabled")
        return Result.new("missing required 'enabled' (true|false)", is_error: true) if enabled.nil?
        return Result.new("no rule with id #{id}", is_error: true) unless rule_exists?(id)
        @store.set_rule_enabled(id, enabled)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "enabled", enabled } })
      end

      private def delete_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return Result.new("no rule with id #{id}", is_error: true) unless rule_exists?(id)
        @store.delete_rule(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end

      # Whether a Match&Replace rule id exists. A full read (the store has no
      # single-row rule fetch), but the rule set is tiny and enable/disable/delete
      # are low-frequency actions.
      private def rule_exists?(id : Int64) : Bool
        @store.match_rules.any? { |r| r.id == id }
      end

      private def create_repeater(h) : Result
        finding_id = int(h, "finding_id")
        return Result.new(id_error(h, "finding_id"), is_error: true) if finding_id.nil? && present?(h, "finding_id")
        flow_id = int(h, "flow_id")
        return Result.new(id_error(h, "flow_id"), is_error: true) if flow_id.nil? && present?(h, "flow_id")

        target = str(h, "target")
        request = str(h, "request")

        if finding_id
          finding = @store.get_finding(finding_id)
          return Result.new("no finding with id #{finding_id}", is_error: true) unless finding
          if fid = finding.flow_id
            flow_id = fid
          elsif target.nil? || target.empty? || request.nil? || request.empty?
            return Result.new("finding #{finding_id} has no associated flow_id", is_error: true)
          end
        end

        http2_val = bool(h, "http2")
        http2 = http2_val || false
        auto_cl_val = bool(h, "auto_content_length")
        auto_cl = (auto_cl_val.nil? && !present?(h, "auto_content_length")) ? true : !!auto_cl_val
        ws_messages_override = nil.as(Array(String)?)

        if flow_id
          flow = @store.get_flow(flow_id)
          return Result.new("no flow with id #{flow_id}", is_error: true) unless flow

          if target.nil? || target.empty?
            scheme = flow.row.scheme
            host = flow.row.host
            port = flow.row.port
            default_port = (scheme == "https" ? 443 : 80)
            target = port == default_port ? "#{scheme}://#{host}" : "#{scheme}://#{host}:#{port}"
          end

          if request.nil? || request.empty?
            req_str = String.new(flow.request_head)
            if body = flow.request_body
              req_str += String.new(body)
            end
            request = req_str
          end

          if http2_val.nil?
            http2 = (flow.http_version == "HTTP/2")
          end

          if flow.row.status == 101 && !present?(h, "ws_out_messages")
            ws_messages_override = @store.ws_messages(flow_id).select { |m| m.direction == "out" && m.text? }.map { |m| String.new(m.payload).scrub }
          end
        end

        return Result.new("missing required 'target'", is_error: true) if target.nil? || target.empty?
        return Result.new("missing required 'request'", is_error: true) if request.nil? || request.empty?

        sni = str(h, "sni")
        mark_transform = bool(h, "mark_transform") || false

        position = int(h, "position")
        if position.nil?
          return Result.new(id_error(h, "position"), is_error: true) if present?(h, "position") # present but non-integer
          position = @store.repeaters_meta.size.to_i64
        elsif position < Int32::MIN || position > Int32::MAX
          return Result.new("'position' out of range", is_error: true)
        end

        # Apply Env.mask_secrets
        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        masked_sni = sni.try { |s| Env.mask_secrets(s) }
        name = str(h, "name").try { |n| Env.mask_secrets(n) }

        # WebSocket mode check
        is_ws = Repeater::WsEngine.upgrade_request?(masked_request)

        id = @store.insert_repeater(
          target: masked_target,
          request: masked_request,
          http2: http2,
          auto_cl: auto_cl,
          flow_id: flow_id,
          position: position.to_i32,
          sni: masked_sni,
          mark_transform: mark_transform
        )

        return Result.new("failed to persist repeater (store busy or unwritable)", is_error: true) if id == 0

        if finding_id
          @store.add_link(Store::LinkOwnerKind::Finding, finding_id,
            Store::LinkRefKind::Repeater, id)
        end

        if name && !name.empty?
          @store.set_repeater_name(id, name)
        end

        # WebSocket messages handling
        if is_ws
          messages = [] of String
          if present?(h, "ws_out_messages")
            if arr = h["ws_out_messages"]?.try(&.as_a?)
              messages = arr.compact_map(&.as_s?)
            elsif str_val = str(h, "ws_out_messages")
              messages = str_val.split('\n').compact_map { |l| l.strip.empty? ? nil : l }
            end
          elsif ws_messages_override
            messages = ws_messages_override
          end

          unless messages.empty?
            @store.update_repeater_ws_messages(id, messages)
          end
        end

        # Derive summary from the MASKED request — the raw request may carry a secret
        # in the request-target (e.g. ?token=…), and this field is returned to the LLM.
        line = masked_request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", position
          end
        })
      end

      private def update_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = @store.get_repeater(id)
        return Result.new("no repeater with id #{id}", is_error: true) unless existing

        target = str(h, "target") || existing.target
        request = str(h, "request") || existing.request
        # An explicitly-passed empty string is truthy in Crystal, so guard it here to
        # mirror create_repeater's invariant — a blank target/request can't be sent.
        return Result.new("target must not be empty", is_error: true) if target.empty?
        return Result.new("request must not be empty", is_error: true) if request.empty?

        http2 = if present?(h, "http2")
                  bool(h, "http2") || false
                else
                  existing.http2?
                end

        auto_cl = if present?(h, "auto_content_length")
                    bool(h, "auto_content_length") || false
                  else
                    existing.auto_content_length?
                  end

        sni = present?(h, "sni") ? str(h, "sni") : existing.sni

        mark_transform = if present?(h, "mark_transform")
                           bool(h, "mark_transform") || false
                         else
                           existing.mark_transform?
                         end

        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        masked_sni = sni.try { |s| Env.mask_secrets(s) }
        name = present?(h, "name") ? str(h, "name").try { |n| Env.mask_secrets(n) } : existing.name

        @store.update_repeater(
          id: id,
          target: masked_target,
          request: masked_request,
          http2: http2,
          auto_cl: auto_cl,
          sni: masked_sni,
          mark_transform: mark_transform
        )

        if present?(h, "name")
          @store.set_repeater_name(id, name)
        end

        # WebSocket messages handling
        if present?(h, "ws_out_messages")
          messages = [] of String
          if arr = h["ws_out_messages"]?.try(&.as_a?)
            messages = arr.compact_map(&.as_s?)
          elsif str_val = str(h, "ws_out_messages")
            messages = str_val.split('\n').compact_map { |l| l.strip.empty? ? nil : l }
          end

          @store.update_repeater_ws_messages(id, messages)
        end

        # Derive summary
        line = request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", existing.position
          end
        })
      end

      private def delete_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = @store.get_repeater(id)
        return Result.new("no repeater with id #{id}", is_error: true) unless existing

        @store.delete_repeater(id)
        Result.new(JSON.build { |j| j.object { j.field "success", true } })
      end

      # --- fuzz tools (gated, async job model) --------------------------------

      private def fuzz_start(h) : Result
        engine, origin, total = build_fuzz_job(h)
        if total && total > FUZZ_MAX_REQUESTS
          return Result.new("too many requests (#{total} > #{FUZZ_MAX_REQUESTS}); narrow positions/payloads", is_error: true)
        end
        @job_seq += 1
        id = "fz_#{@job_seq}"
        fjob = FuzzJob.new(id, total, engine)
        @jobs[id] = fjob
        # Audit on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "fuzz_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} total=#{total || "?"}" }
        spawn(name: "mcp-fuzz-#{id}") { run_fuzz_job(fjob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "total", total; j.field "status", "running" } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid fuzz arguments", is_error: true)
      end

      # Background drain (runs during the stdio loop's blocking read). Stores
      # matched results only, capped, never touches STDOUT.
      private def run_fuzz_job(fjob : FuzzJob, engine : Fuzz::Engine) : Nil
        engine.run do |ev|
          case ev
          when Fuzz::ProgressEvent then apply_fuzz_progress(fjob, ev.progress)
          when Fuzz::ResultEvent   then store_fuzz_result(fjob, ev.result)
          when Fuzz::DoneEvent
            apply_fuzz_progress(fjob, ev.progress)
            fjob.status = ev.stopped ? :stopped : :done
          when Fuzz::ErrorEvent
            fjob.status = :error
            fjob.error_msg = ev.message
          end
        end
      end

      private def apply_fuzz_progress(fjob : FuzzJob, p : Fuzz::Progress) : Nil
        fjob.sent = p.sent
        fjob.matched = p.matched
        fjob.errors = p.errors
      end

      private def store_fuzz_result(fjob : FuzzJob, r : Fuzz::Result) : Nil
        return unless r.matched?
        if fjob.results.size < FUZZ_MAX_STORED
          fjob.results << r
        else
          fjob.truncated = true
        end
      end

      private def fuzz_status(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", fjob.id
            j.field "status", fjob.status.to_s
            j.field "total", fjob.total
            j.field "sent", fjob.sent
            j.field "matched", fjob.matched
            j.field "errors", fjob.errors
            j.field "stored_results", fjob.results.size
            j.field "results_truncated", fjob.truncated?
            j.field "error", fjob.error_msg
          end
        end)
      end

      private def fuzz_results(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        rows = (bool(h, "matched_only") || false) ? fjob.results.select(&.matched?) : fjob.results
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 1000)
        page = rows[offset, limit]? || [] of Fuzz::Result
        Result.new(JSON.build do |j|
          j.object do
            j.field("results") { j.array { page.each { |r| Serialize.fuzz_result(j, r) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "total_available", rows.size
            j.field "complete", fjob.status != :running
            j.field "results_truncated", fjob.truncated?
          end
        end)
      end

      private def fuzz_stop(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        fjob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", fjob.id; j.field "status", "stopping" } })
      end

      # The job for `job_id`, or an error Result the caller returns as-is.
      private def lookup_fuzz_job(h) : FuzzJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        @jobs[id]? || Result.new("no fuzz job #{id}", is_error: true)
      end

      # --- mine tools (gated, async job model) --------------------------------

      private def mine_start(h) : Result
        engine, origin, total = build_mine_job(h)
        @job_seq += 1
        id = "mn_#{@job_seq}"
        mjob = MineJob.new(id, total, engine)
        @mine_jobs[id] = mjob
        Log.info { "mine_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} names=#{total}" }
        spawn(name: "mcp-mine-#{id}") { run_mine_job(mjob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "names", total; j.field "status", "running" } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid mine arguments", is_error: true)
      end

      private def run_mine_job(mjob : MineJob, engine : Miner::Engine) : Nil
        engine.run do |ev|
          case ev
          when Miner::BaselineEvent then mjob.baseline_stable = ev.stable
          when Miner::ProgressEvent then apply_mine_progress(mjob, ev.progress)
          when Miner::FindingEvent  then store_mine_finding(mjob, ev.finding)
          when Miner::DoneEvent
            apply_mine_progress(mjob, ev.progress)
            mjob.status = ev.stopped ? :stopped : :done
          when Miner::ErrorEvent
            mjob.status = :error
            mjob.error_msg = ev.message
          end
        end
      end

      private def apply_mine_progress(mjob : MineJob, p : Miner::Progress) : Nil
        mjob.names_done = p.names_done
        mjob.sent = p.sent
        mjob.found = p.found
        mjob.errors = p.errors
      end

      private def store_mine_finding(mjob : MineJob, f : Miner::Finding) : Nil
        if mjob.results.size < MINE_MAX_STORED
          mjob.results << f
        else
          mjob.truncated = true
        end
      end

      private def mine_status(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", mjob.id
            j.field "status", mjob.status.to_s
            j.field "names_total", mjob.total
            j.field "names_done", mjob.names_done
            j.field "sent", mjob.sent
            j.field "found", mjob.found
            j.field "errors", mjob.errors
            j.field "baseline_stable", mjob.baseline_stable?
            j.field "results_truncated", mjob.truncated?
            j.field "error", mjob.error_msg
          end
        end)
      end

      private def mine_results(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 1000)
        page = mjob.results[offset, limit]? || [] of Miner::Finding
        Result.new(JSON.build do |j|
          j.object do
            j.field("findings") { j.array { page.each { |f| mine_finding_json(j, f) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "total_available", mjob.results.size
            j.field "complete", mjob.status != :running
            j.field "results_truncated", mjob.truncated?
          end
        end)
      end

      private def mine_stop(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        mjob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", mjob.id; j.field "status", "stopping" } })
      end

      private def lookup_mine_job(h) : MineJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        @mine_jobs[id]? || Result.new("no mine job #{id}", is_error: true)
      end

      private def mine_finding_json(j : JSON::Builder, f : Miner::Finding) : Nil
        j.object do
          j.field "name", f.name
          j.field "location", f.location.label
          j.field "evidence", f.evidence.label
          j.field "confidence", f.confidence.label
          j.field "canary", f.canary
          j.field "status", f.status
          j.field "delta", f.delta
        end
      end

      # Build a ready-to-run mining engine + its origin + name count. Raises FuzzArgError
      # (clean message) on malformed input. Reuses the fuzz origin/timeout helpers.
      private def build_mine_job(h) : {Miner::Engine, Fuzz::Origin, Int64}
        bytes, default_target, src_h2 = mine_request_source(h)
        use_h2 = (bool(h, "http2") || false) || src_h2
        origin = fuzz_origin(h, default_target)
        sender = Fuzz::Sender.new(origin, http2: use_h2,
          verify: @verify_upstream && !(bool(h, "insecure") || false), timeout: fuzz_timeout(h))
        config = Miner::Config.new
        config.locations = mine_locations(h, bytes)
        raise FuzzArgError.new("no applicable locations for this request") if config.locations.empty?
        config.concurrency = clamp(int(h, "concurrency"), 10, MINE_MAX_CONCURRENCY)
        config.rps = int(h, "rate").try(&.to_f64)
        config.timeout = fuzz_timeout(h)
        config.retries = (int(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i # clamp before .to_i (Int32) so a huge value can't OverflowError past the clean-error handler
        cap = int(h, "max_requests")
        config.max_requests = cap ? {cap, MINE_MAX_REQUESTS}.min : MINE_MAX_REQUESTS
        config.user_wordlist = str(h, "wordlist").presence
        if b = int(h, "bucket")
          bucket = b.clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i # avoid Int64->Int32 overflow
          config.locations.each { |loc| config.bucket_size[loc] = bucket }
        end
        names = Miner::Wordlist.load(config.user_wordlist)
        engine = Miner::Engine.new(bytes, use_h2, names, sender, config)
        {engine, origin, engine.total_names}
      rescue ex : File::Error
        raise FuzzArgError.new("wordlist error: #{ex.message}")
      end

      private def mine_request_source(h) : {Bytes, String?, Bool}
        if t = str(h, "template")
          return {Env.expand_wire(t), nil, false} unless t.strip.empty?
        end
        if id = int(h, "flow_id")
          detail = @store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {Env.expand_wire(String.new(built.bytes)), Env.expand(built.target), built.http2}
        end
        raise FuzzArgError.new("provide a 'template' (raw request) or a 'flow_id'")
      end

      private def mine_locations(h, bytes : Bytes) : Array(Miner::Location)
        raw = str(h, "locations")
        if raw && !raw.strip.empty?
          raw.split(',').compact_map do |tok|
            next if tok.strip.empty?
            Miner::Location.parse?(tok) || raise FuzzArgError.new("unknown location '#{tok}' (query|form|json|headers|cookies)")
          end
        else
          Miner::Detect.detect(bytes).default
        end
      end

      # Build a ready-to-run engine + its origin + total from the tool args. Raises
      # FuzzArgError (clean message) on any malformed input.
      private def build_fuzz_job(h) : {Fuzz::Engine, Fuzz::Origin, Int64?}
        text, default_target, src_h2 = fuzz_template_source(h)
        text = Env.expand(text)
        default_target = default_target.try { |t| Env.expand(t) }
        use_h2 = (bool(h, "http2") || false) || src_h2
        text = Fuzz::Template.auto_mark(text) if bool(h, "auto") || false
        m = Fuzz::Template::MARKER
        fuzz_marks(h).each { |tok| text = text.gsub(tok, "#{m}#{tok}#{m}") }
        template = Fuzz::Template.parse(text, use_h2)
        raise FuzzArgError.new("template has no §…§ positions (add markers, or pass auto:true with a flow_id)") if template.position_count == 0
        origin = fuzz_origin(h, default_target)
        mode = fuzz_mode(h)
        sets = fuzz_sets(h)
        raise FuzzArgError.new(%(no payloads — pass 'payloads' as a JSON array of sets, e.g. [{"list":["a","b"]}])) if sets.empty?
        matcher = fuzz_matcher(h)
        config = fuzz_config(h, mode)
        gen_sets = mode.per_position? ? sets : [sets.first]
        generator = Fuzz::Generator.new(template, gen_sets, config, registry: Decoder.shared_registry)
        sender = Fuzz::Sender.new(origin, http2: use_h2,
          verify: @verify_upstream && !(bool(h, "insecure") || false), timeout: fuzz_timeout(h))
        engine = Fuzz::Engine.new(generator, matcher, sender, config)
        {engine, origin, engine.total}
      rescue ex : File::Error
        raise FuzzArgError.new("wordlist error: #{ex.message}")
      end

      private def fuzz_template_source(h) : {String, String?, Bool}
        if t = str(h, "template")
          return {t, nil, false} unless t.strip.empty?
        end
        if id = int(h, "flow_id")
          detail = @store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {String.new(built.bytes).scrub, built.target, built.http2}
        end
        raise FuzzArgError.new("provide a 'template' (raw request with §…§) or a 'flow_id'")
      end

      private def fuzz_origin(h, default_target : String?) : Fuzz::Origin
        url_raw = str(h, "url").presence || default_target
        raise FuzzArgError.new("provide a 'url' target (scheme://host) or a flow_id that carries one") unless url_raw
        url = Env.expand(url_raw)
        scheme, host, port = Repeater::FlowRequest.parse_target(url)
        raise FuzzArgError.new("could not parse a host from '#{url}'") if host.empty?
        Fuzz::Origin.new(scheme, host, port)
      end

      private def fuzz_mode(h) : Fuzz::Mode
        s = str(h, "mode")
        return Fuzz::Mode::Sniper if s.nil? || s.strip.empty?
        Fuzz::Mode.parse?(s) || raise FuzzArgError.new("invalid mode '#{s}' (sniper|batteringram|pitchfork|clusterbomb)")
      end

      # Mirrors `fuzz_sets`'s array-pulling pattern (bare array, or a JSON-encoded
      # string — LLM clients vary), but for plain string tokens.
      private def fuzz_marks(h) : Array(String)
        raw = h["marks"]?
        return [] of String unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of String if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'marks' must be a JSON array of strings")
            parsed.as_a? || raise FuzzArgError.new("'marks' must be a JSON array")
          else
            raise FuzzArgError.new("'marks' must be a JSON array of strings (not a bare string/scalar)")
          end
        arr.map { |v| v.as_s? || raise FuzzArgError.new("each 'marks' entry must be a string") }
      end

      private def fuzz_sets(h) : Array(Fuzz::PayloadSet)
        raw = h["payloads"]?
        return [] of Fuzz::PayloadSet unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of Fuzz::PayloadSet if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'payloads' must be a JSON array of sets")
            parsed.as_a? || raise FuzzArgError.new("'payloads' must be a JSON array")
          else
            raise FuzzArgError.new("'payloads' must be a JSON array of sets (not a bare string/scalar)")
          end
        arr.map { |spec| fuzz_set_from(spec) }
      end

      private def fuzz_set_from(spec : JSON::Any) : Fuzz::PayloadSet
        obj = spec.as_h? || raise FuzzArgError.new("each payload set must be a JSON object")
        Fuzz::PayloadSet.new(fuzz_source_from(obj, spec))
      end

      private def fuzz_source_from(obj : Hash(String, JSON::Any), spec : JSON::Any) : Fuzz::PayloadSource
        if list = obj["list"]?.try(&.as_a?)
          Fuzz::InlineList.new(list.map { |x| x.as_s? || x.to_s })
        elsif wl = obj["wordlist"]?.try(&.as_s?)
          Fuzz::WordlistFile.new(wl)
        elsif nums = obj["numbers"]?.try(&.as_s?)
          fuzz_numbers(nums)
        elsif (nul = obj["null"]?) && (n = (nul.as_i64? || nul.as_s?.try(&.to_i64?)))
          Fuzz::NullPayloads.new(n.clamp(0_i64, FUZZ_MAX_REQUESTS).to_i) # clamp before .to_i so a huge count can't OverflowError past the clean-error handler
        elsif br = obj["brute"]?.try(&.as_s?)
          fuzz_brute(br)
        else
          raise FuzzArgError.new("unknown payload set #{spec} (use list/wordlist/numbers/null/brute)")
        end
      end

      private def fuzz_numbers(v : String) : Fuzz::NumberRange
        range_part, _, step_part = v.partition(':')
        if md = range_part.match(/^(-?\d+)-(-?\d+)$/)
          from = md[1].to_i64?
          to = md[2].to_i64?
        else
          from = nil
          to = nil
        end
        raise FuzzArgError.new("invalid numbers '#{v}' (use FROM-TO[:STEP])") unless from && to
        step = step_part.empty? ? 1_i64 : (step_part.to_i64? || raise FuzzArgError.new("invalid numbers step '#{step_part}'"))
        Fuzz::NumberRange.new(from, to, step)
      end

      private def fuzz_brute(v : String) : Fuzz::BruteForce
        charset, _, lens = v.rpartition(':')
        raise FuzzArgError.new("invalid brute '#{v}' (use CHARSET:MIN-MAX)") if charset.empty? || lens.empty?
        min_s, _, max_s = lens.partition('-')
        min = min_s.to_i?
        max = max_s.empty? ? min : max_s.to_i?
        raise FuzzArgError.new("invalid brute lengths '#{lens}'") unless min && max
        Fuzz::BruteForce.new(charset, min, max)
      end

      private def fuzz_matcher(h) : Fuzz::Matcher
        m = Fuzz::Matcher.new(keep_bodies: :none)
        if c = fuzz_conditions(h["match"]?, "match")
          m.match_status = c[:status]
          m.match_size = c[:size]
          m.match_words = c[:words]
          m.match_lines = c[:lines]
          m.match_regex = fuzz_regex(c[:regex], "match")
        end
        if c = fuzz_conditions(h["filter"]?, "filter")
          m.filter_status = c[:status]
          m.filter_size = c[:size]
          m.filter_words = c[:words]
          m.filter_lines = c[:lines]
          m.filter_regex = fuzz_regex(c[:regex], "filter")
        end
        m.extract = fuzz_regex(str(h, "extract"), "extract")
        m
      end

      private alias FuzzConds = NamedTuple(status: String?, size: String?, words: String?, lines: String?, regex: String?)

      private def fuzz_conditions(raw : JSON::Any?, which : String) : FuzzConds?
        return nil unless raw
        obj =
          if h = raw.as_h?
            h
          elsif s = raw.as_s?
            return nil if s.strip.empty?
            (JSON.parse(s).as_h? rescue nil) || raise FuzzArgError.new("'#{which}' must be a JSON object")
          else
            raise FuzzArgError.new("'#{which}' must be a JSON object (not a bare string/scalar)")
          end
        {status: jstr(obj, "status"), size: jstr(obj, "size"), words: jstr(obj, "words"),
         lines: jstr(obj, "lines"), regex: obj["regex"]?.try(&.as_s?)}
      end

      private def jstr(obj : Hash(String, JSON::Any), key : String) : String?
        obj[key]?.try { |v| v.as_s? || v.to_s }
      end

      private def fuzz_regex(s : String?, which : String) : Regex?
        return nil if s.nil? || s.empty?
        Regex.new(s)
      rescue ex
        raise FuzzArgError.new("invalid #{which} regex '#{s}': #{ex.message}")
      end

      private def fuzz_config(h, mode : Fuzz::Mode) : Fuzz::Config
        rate = int(h, "rate").try(&.to_f64)
        # Ignore a non-positive caller cap (it would otherwise become a negative cap
        # that halts the dispatcher at request 0); fall back to the hard ceiling.
        caller_cap = int(h, "max_requests").try { |m| m > 0 ? m : nil }
        cap = [caller_cap, FUZZ_MAX_REQUESTS].compact.min
        Fuzz::Config.new(mode: mode,
          concurrency: clamp(int(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          rps: (rate && rate > 0 ? rate : nil),
          retries: (int(h, "retries") || 0_i64).clamp(0_i64, 1000_i64).to_i,
          timeout: fuzz_timeout(h),
          keep_bodies: :none,
          max_requests: cap)
      end

      private def fuzz_timeout(h) : Time::Span?
        int(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds)
      end

      private def clamp_nonneg(n : Int64?) : Int32
        return 0 unless n
        n.clamp(0_i64, Int32::MAX.to_i64).to_i
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

      private def optional_int_arg(h, key : String) : Int64?
        value = int(h, key)
        if present?(h, key) && value.nil?
          raise Gori::Error.new("invalid '#{key}' (expected an integer)")
        end
        value
      end

      private def bounded_int_arg(h, key : String, default : Int64, *, min : Int64,
                                  max : Int64 = Int64::MAX) : Int64
        value = optional_int_arg(h, key) || default
        if value < min
          raise Gori::Error.new("invalid '#{key}' (expected an integer >= #{min})")
        end
        value.clamp(min, max)
      end

      private def bool(h, key : String) : Bool?
        v = h[key]?
        return nil unless v
        return v.as_bool? unless v.as_bool?.nil?
        # Clients/LLMs often serialize tool args as strings (the schema's "boolean" is
        # advisory, not enforced) — accept "true"/"false" so a stringified flag isn't
        # silently coerced to false, mirroring int()'s leniency.
        case v.as_s?.try(&.downcase)
        when "true"  then true
        when "false" then false
        else              nil
        end
      end

      private def bool_arg(h, key : String, default : Bool) : Bool
        value = bool(h, key)
        if present?(h, key) && value.nil?
          raise Gori::Error.new("invalid '#{key}' (expected true or false)")
        end
        value.nil? ? default : value
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

      private def arrprop(desc : String) : JSON::Any
        JSON.parse(%({"type":"array","description":#{desc.to_json},"items":{"type":"object"}}))
      end

      private def strarrprop(desc : String) : JSON::Any
        JSON.parse(%({"type":"array","description":#{desc.to_json},"items":{"type":"string"}}))
      end

      # Passive-scan a just-saved Repeater send into prism_issues when mode is Passive/Active.
      private def prism_scan_saved_repeater(repeater_id : Int64, target : String, request : String,
                                          http2 : Bool, flow_id : Int64?, head : Bytes, body : Bytes?,
                                          duration_us : Int64) : Nil
        return unless @store.prism_mode.scanning?
        return if head.empty?
        rec = Store::RepeaterRecord.new(
          repeater_id, target, request, http2, true, flow_id, 0,
          head, body, nil, duration_us, nil, nil, false)
        return unless detail = Prism.detail_from_repeater(rec)
        Prism::Passive.analyze(detail).each do |d|
          @store.upsert_prism_issue(Prism.with_source(d, flow_id: flow_id, repeater_id: repeater_id))
        end
      rescue
        # Prism must never break send_request
      end

      # Accepts a JSON array directly or a JSON-encoded string, or a string.
      private def arr_or_str_prop(desc : String) : JSON::Any
        JSON.parse(%({"description":#{desc.to_json},"oneOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]}))
      end

      # Accepts a JSON object directly or a JSON-encoded string (LLM clients vary).
      private def jsonprop(desc : String) : JSON::Any
        JSON.parse(%({"description":#{desc.to_json},"oneOf":[{"type":"object"},{"type":"string"}]}))
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
