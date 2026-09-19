require "json"
require "log"
require "../store"
require "./protocol"
require "./tools"
require "./courier"
require "../settings"

module Gori
  module MCP
    # A Model Context Protocol server over stdio: JSON-RPC 2.0, one compact JSON
    # message per line on `input`, responses on `output`. STDOUT is the protocol
    # channel — callers MUST keep it pure (logs go to STDERR). IO is injectable so
    # the server is unit-testable with IO::Memory.
    #
    # TWO fibers, and the split is deliberate. The READER parses lines; a WORKER runs the
    # requests, one at a time, in arrival order — so the tools layer keeps the
    # single-call-at-a-time semantics every one of its handlers is written against, and
    # responses keep coming back in the order they were asked for. What the split buys is
    # that the reader is never parked inside a tool: `ping` and `notifications/cancelled`
    # used to queue behind a five-minute fuzz run, which is exactly when a client's
    # liveness probe fires and exactly when it must not time out — a client that decides
    # the server is dead kills it mid-call and loses the work it was waiting for.
    class Server
      Log = ::Log.for("mcp")

      # Requests waiting on the worker. A bound, not a target: the reader stops reading
      # while it is full, which is the backpressure a client that pipelines faster than the
      # tools can answer SHOULD feel. Deep enough that no ordinary burst reaches it.
      WORK_QUEUE = 64

      # WHICH revisions this server speaks lives in `mcp/protocol.cr`, one home for a set
      # that is now read from three places — the handshake, `server/discover`, and the
      # per-request gate below. Three copies would be three answers.

      EMPTY_ARGS = JSON::Any.new({} of String => JSON::Any)

      # The project arguments are handed STRAIGHT to `Tools` and not kept here. Tools owns the
      # binding — `switch_project` rewrites it — and a copy on this side is a copy that goes
      # stale on the first switch while still being read out as the server's configuration
      # (#1003). `instructions_text` asks `@tools` for the current one instead.
      def initialize(store : Store? = nil, *, allow_actions : Bool, verify_upstream : Bool,
                     project_name : String? = nil, project_slug : String? = nil,
                     db_path : String? = nil, selection_source : String? = nil,
                     workspace_root : String? = nil, project_id : String? = nil,
                     bind_error : String? = nil, tool_filter : ToolFilter? = nil,
                     @input : IO = STDIN, @output : IO = STDOUT)
        @allow_actions = allow_actions
        @tools = Tools.new(store, allow_actions, verify_upstream,
          project_name: project_name, project_slug: project_slug, db_path: db_path,
          selection_source: selection_source, workspace_root: workspace_root,
          project_id: project_id, bind_error: bind_error, tool_filter: tool_filter)
        @initialized = false
        # Set when the output pipe breaks (client vanished mid-write): the loop then
        # stops rather than thrashing on a dead stream or raising an unhandled error.
        @closed = false
        # Non-nil only while a batch is being dispatched: `send` collects into it instead of
        # writing, so the members' responses leave as the one array the batch is owed.
        # `@batch_fiber` is who owns that collection — the reader answering a `ping` while
        # the worker is mid-batch must write its own frame, not get swept into the array of
        # a batch it was never part of.
        @batch = nil.as(Array(String)?)
        @batch_fiber = nil.as(Fiber?)
        # Two fibers write to `@output`, and a large payload can yield mid-write on a pipe
        # whose buffer is full — without this, a `ping` answered by the reader could land
        # INSIDE a half-written tool response and break the frame for the rest of the session.
        @write_lock = Mutex.new
        # Ids the worker still owes an answer for, and the subset of those the client has
        # since cancelled. Only ids we are actually holding are remembered, so a client
        # cannot grow either set past the queue depth (see `handle_notification`).
        # Written by the reader, cleared by the worker, unlocked: gori never builds with
        # `-Dpreview_mt`, so the two fibers interleave only at yield points and neither a
        # `Set#add` nor a `Set#delete` contains one — the same single-threaded-scheduler
        # assumption `Tools::FuzzJob` documents for its own cross-fiber fields.
        @pending = Set(String).new
        @cancelled = Set(String).new
        # The operator-message courier (#1090), started when the client says `initialized`,
        # and whether THIS session's handshake declared the channel capability — the courier
        # keys off that, never off the live setting: a toggle after the handshake cannot
        # register a channel the client already did not take.
        @courier = nil.as(Courier?)
        @channel_declared = false
      end

      # Reads until EOF on `input` (client closed the pipe). Each line is parsed
      # and dispatched independently; a bad line never stops the loop. A broken
      # transport (the client process died) ends the session cleanly — a normal
      # shutdown, not a crash to surface as an unhandled backtrace.
      #
      # Returns only once the worker has drained: a response written after `run` returned
      # would be a response the caller (and every spec that reads `output` afterwards)
      # never sees.
      def run : Nil
        work = Channel(Proc(Nil)).new(WORK_QUEUE)
        drained = Channel(Nil).new(1)
        spawn(name: "mcp-worker") { work_loop(work, drained) }
        begin
          @input.each_line do |line|
            break if @closed
            line = line.strip
            next if line.empty?
            read_line(line, work)
            break if @closed
          end
        rescue ex : IO::Error
          Log.info { "mcp: input stream closed (#{ex.message})" }
        ensure
          @courier.try(&.stop)
          work.close
          drained.receive
          # After the worker has drained, so a still-running switch_project cannot re-announce
          # behind us. The store is closed by the caller (cli/mcp.cr); the marker is ours (#815).
          @tools.release_presence
        end
      end

      # Runs queued requests in arrival order until the reader closes the channel and the
      # backlog is empty. The rescue is the session's structural guarantee: ONE request can
      # never end it.
      #
      # `handle_message` already rescues per message, but the steps around it — the JSON
      # parse, the id recovery — were guarded only against `JSON::ParseException`, and
      # anything else escaped `run` (which catches IO::Error alone) as an unhandled
      # exception that killed the whole server. A single stdin line holding a byte that is
      # not valid UTF-8 did exactly that: `recover_id`'s regex made PCRE2 raise
      # `ArgumentError`, and the client lost the server mid-session over one malformed byte
      # it could not even see. A dropped line costs the client one answer; a dead process
      # costs it every answer after it.
      private def work_loop(work : Channel(Proc(Nil)), drained : Channel(Nil)) : Nil
        while job = work.receive?
          begin
            job.call
          rescue ex
            Log.error(exception: ex) { "mcp: request handler raised; keeping the session" }
          end
        end
      ensure
        drained.send(nil)
      end

      # The reader's whole job: parse, answer the two things that must not queue, and hand
      # everything else to the worker AS A CLOSURE — so ordering, batching and every error
      # path stay exactly the code they were, just running one fiber over.
      private def read_line(line : String, work : Channel(Proc(Nil))) : Nil
        root = begin
          JSON.parse(line)
        rescue ex : JSON::ParseException
          # Answer with the request's OWN id when the line still carries a readable one.
          # A perfectly legal JSON number outside Int64 range (`{"limit": 1e30}` spelled out,
          # which an LLM emits for "no limit") makes Crystal's parser reject the whole line —
          # so a request that is only an ARGUMENT mistake used to come back `id: null`, and a
          # strict client with a pending promise for that id never resolved it. The agent hung
          # instead of seeing the error. See `recover_id`.
          #
          # Queued rather than written here: a parse error that overtook the answers to the
          # requests before it would arrive out of order for no reason.
          id = (recover_id(line) rescue nil)
          message = "Parse error: #{ex.message}"
          return work.send(-> { write_error(id, -32700, message) })
        end

        if fast_path(root)
          return
        end

        if id = single_request_id(root)
          key = id.to_json
          @pending << key
          return work.send(-> do
            begin
              handle_document(root)
            ensure
              @pending.delete(key)
              @cancelled.delete(key)
            end
          end)
        end
        work.send(-> { handle_document(root) })
      rescue ex
        # Same guarantee as the worker's, for the reader's own half of the work.
        Log.error(exception: ex) { "mcp: reader raised on a line; keeping the session" }
        id = (recover_id(line) rescue nil)
        message = "Internal error: #{ex.message}"
        work.send(-> { write_error(id, -32603, message) })
      end

      # Messages the READER answers itself, ahead of a possibly long-running queue. Both are
      # the client asking about the session rather than asking for work, and both are useless
      # late: a `ping` answered after the five-minute call it was probing has already told the
      # client we were dead, and a cancellation that lands after its request finished cancels
      # nothing. Neither writes anything the ordering of a queued response depends on
      # (a notification writes nothing at all).
      private def fast_path(root : JSON::Any) : Bool
        return false unless obj = root.as_h?
        return false unless method = obj["method"]?.try(&.as_s?)
        id = obj["id"]?
        if id.nil?
          handle_notification(method, obj["params"]?)
          return true
        end
        return false unless method == "ping"
        # Through the same gate as every other request: a liveness probe that names a
        # revision we do not speak deserves the same answer a tool call would get, and the
        # `resultType` a modern client parses is owed here too. `ping` itself was REMOVED in
        # 2026-07-28 — we go on answering it, because a server that does is breaking nothing
        # and a dual-era client's legacy half still sends it.
        gate = era_of(id, method, obj["params"]?)
        return true if gate.refused
        # No `note_modern_client` here, deliberately: that writes the presence marker and
        # starts the courier, and the whole point of this path is that a liveness probe is
        # answered without the reader doing work. The worker's path takes the note.
        write_result(id, gate.version) { }
        true
      end

      # The outcome of reading one request's era: the revision it is speaking (nil for the
      # legacy era), and whether the gate has already ANSWERED the request and the caller
      # must stop.
      private record EraGate, version : String?, refused : Bool

      # Reads the era off one request's `_meta` and enforces it.
      #
      # `2026-07-28` moved version, identity and capabilities INTO every request, so this is
      # what the handshake used to do, done per call. Four outcomes:
      #
      #   - no `io.modelcontextprotocol/protocolVersion`: the LEGACY era — every client that
      #     opened with `initialize`, and every one that never negotiated at all. A dual-era
      #     server serves it exactly as it always did; there is nothing here to enforce.
      #   - a modern revision we implement: answered statelessly, with the modern envelope.
      #   - a LEGACY revision spelled in `_meta`: that revision defines no per-request
      #     metadata, so the field is decoration — but it names a version we do support, so
      #     it is not an error either. Served legacy.
      #   - anything else: `UnsupportedProtocolVersionError`, carrying what we DO support so
      #     the client can retry instead of guess. That error is also the signal a dual-era
      #     client probing us needs: a recognised modern error means "modern server, pick
      #     another version" and explicitly NOT "fall back to initialize".
      private def era_of(id : JSON::Any, method : String, params : JSON::Any?) : EraGate
        meta = obj_field(params, "_meta")
        requested = obj_field(meta, Protocol::META_PROTOCOL_VERSION).try(&.as_s?)
        return EraGate.new(nil, false) if requested.nil? || Protocol.legacy?(requested)
        unless Protocol.modern?(requested)
          write_error(id, Protocol::UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version",
            data: ->(j : JSON::Builder) do
              j.object do
                j.field("supported") { j.array { Protocol::SUPPORTED_VERSIONS.each { |v| j.string v } } }
                j.field "requested", requested
              end
            end)
          return EraGate.new(nil, true)
        end
        # Required on every modern request, and required of us to check. gori relies on no
        # client capability, so the absence costs it nothing to serve — but a server that
        # silently accepts a malformed request teaches the client its requests are fine, and
        # the next server it meets will not agree. The refusal names the key, which is the
        # only thing that makes it recoverable.
        #
        # `server/discover` is the exception, and for the same reason it is answered without
        # a version at all: it is the request a client sends to find out what to send, and a
        # bootstrap probe that has stamped its version but has no capabilities to declare yet
        # would be refused by the one RPC that exists to unblock it. The VERSION half above
        # still applies — a discovery naming a revision we do not speak is what tells a
        # dual-era client we are modern.
        unless method == "server/discover" || obj_field(meta, Protocol::META_CLIENT_CAPS).try(&.as_h?)
          write_error(id, -32602, "#{Protocol::META_CLIENT_CAPS} is required in _meta " \
                                  "on every #{requested} request")
          return EraGate.new(nil, true)
        end
        EraGate.new(requested, false)
      end

      # What the handshake used to do with `clientInfo`, done per request because that is
      # where the modern revision put it: the agent-presence marker (#815) is named from it,
      # and the courier that carries operator messages (#1090) has no `initialized` to start
      # on any more. `client_seen` is a no-op when nothing moved, so a busy session does not
      # rewrite the marker once per call.
      #
      # The channel capability is deliberately NOT read from here. It is the SERVER that
      # declares it, at the handshake or at `server/discover`, and a client that has been
      # handed no declaration must not be pushed to — see `emit_capabilities`.
      private def note_modern_client(meta : JSON::Any?) : Nil
        info = obj_field(meta, Protocol::META_CLIENT_INFO)
        @tools.client_seen(obj_field(info, "name").try(&.as_s?), obj_field(info, "version").try(&.as_s?))
        start_courier
      end

      # The id of a lone request (not a batch, not a notification) — what a client names in
      # `notifications/cancelled`. Batch members are deliberately not tracked: their
      # responses have to leave as one array, so dropping a member cannot be done by
      # suppressing a write.
      private def single_request_id(root : JSON::Any) : JSON::Any?
        root.as_h?.try(&.[]?("id"))
      end

      private def handle_document(root : JSON::Any) : Nil
        if batch = root.as_a?
          handle_batch(batch)
        else
          handle_message(root)
        end
      end

      # A JSON-RPC 2.0 batch: an ARRAY of messages, answered by ONE array of the responses
      # the member requests produced.
      #
      # SUPPORTED_VERSIONS advertises `2025-03-26`, the one MCP revision where receiving
      # batches is mandatory (2025-06-18 removed it again) — and we echo that version back
      # whenever a client asks for it. Without this, every batch fell through to
      # handle_message's object check and came back as a SINGLE `Invalid Request` at id
      # `null`: not one of the ids in the batch, so a client holding a promise per request
      # resolved none of them and the session hung on a revision we had just claimed.
      #
      # Members are dispatched in order through the same path a lone line takes, so a bad
      # member yields its own error object beside its siblings' results rather than voiding
      # the batch.
      private def handle_batch(items : Array(JSON::Any)) : Nil
        # An empty batch names no request to answer, so the single null-id error IS the
        # spec's answer here (unlike the case above, where ids existed and were thrown away).
        return write_error(nil, -32600, "Invalid Request: empty batch") if items.empty?

        collected = [] of String
        @batch = collected
        @batch_fiber = Fiber.current
        begin
          items.each { |item| handle_message(item) }
        ensure
          @batch = nil
          @batch_fiber = nil
        end

        # All-notification batches get no response at all — sending `[]` back is explicitly
        # forbidden, and a client that reads one as a malformed frame drops the connection.
        return if collected.empty?
        send("[#{collected.join(',')}]")
      end

      private def handle_message(root : JSON::Any) : Nil
        id = nil.as(JSON::Any?)
        obj = root.as_h?
        return write_error(nil, -32600, "Invalid Request") unless obj

        id = obj["id"]?
        method = obj["method"]?.try(&.as_s?)
        params = obj["params"]?

        unless method
          # No `method` at all is a MALFORMED message, not a notification — a notification is
          # one that omits `id` while still naming a method, and this one may omit both. It is
          # answered at whatever id it carried, or at null when it carried none. Staying silent
          # for the id-less case cost a batch one array element, and a client that correlates
          # responses to members BY POSITION then pairs every later response with the wrong
          # request — worse than the error it was trying not to send.
          return write_error(id, -32600, "Invalid Request: missing method")
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
        # The era gate runs BEFORE the method is looked at: a request naming a revision we
        # do not speak is refused whatever it was asking for, and the one naming a revision
        # we do decides the envelope every branch below writes.
        gate = era_of(id, method, params)
        return if gate.refused
        era = gate.version
        note_modern_client(obj_field(params, "_meta")) if era
        case method
        when "server/discover" then handle_discover(id)
        when "initialize"      then handle_initialize(id, params)
        when "ping"            then write_result(id, era) { }
        when "tools/list"      then handle_tools_list(id, era)
        when "tools/call"      then handle_tools_call(id, era, params)
        else                        write_error(id, -32601, "Method not found: #{method}")
        end
      rescue ex
        Log.error(exception: ex) { "request #{method} failed" }
        write_error(id, -32603, "Internal error: #{ex.message}")
      end

      private def handle_notification(method : String, params : JSON::Any?) : Nil
        case method
        when "notifications/initialized"
          @initialized = true
          start_courier
        when "notifications/cancelled"
          # The client has stopped waiting for a request we are still holding. A fiber
          # cannot be interrupted, so the work itself runs to completion — what this buys
          # is the spec's half of the contract: no response is sent for a cancelled id,
          # so a client that has already reused or retired it is not handed an answer it
          # has nowhere to put.
          #
          # Only ids still in `@pending` are remembered. One already answered has nothing
          # to suppress, and recording it would let a client grow this set for the life of
          # the session by cancelling ids it never sent.
          if req = obj_field(params, "requestId")
            key = req.to_json
            @cancelled << key if @pending.includes?(key)
          end
        end
        # All other notifications are accepted silently (no response, ever).
      end

      # The LEGACY opening. A client that sends `initialize` has chosen handshake semantics
      # for itself, so it is answered with a handshake revision even when it asked for a
      # modern one: naming `2026-07-28` here would promise per-request semantics to a
      # session that has already been opened as a session and cannot switch.
      private def handle_initialize(id : JSON::Any, params : JSON::Any?) : Nil
        client_ver = obj_field(params, "protocolVersion").try(&.as_s?)
        version = client_ver && Protocol.legacy?(client_ver) ? client_ver : Protocol::LEGACY_LATEST
        # The client's self-description feeds the agent-presence marker's name (#815). Same
        # arg-reader stance as everywhere else on this surface: a non-string slot is ABSENT,
        # never coerced — `as_s?` returns nil for a number/object/null, so a hostile
        # `clientInfo.name` cannot smuggle a container in.
        info = obj_field(params, "clientInfo")
        @tools.client_seen(obj_field(info, "name").try(&.as_s?), obj_field(info, "version").try(&.as_s?))
        write_result(id) do |j|
          j.field "protocolVersion", version
          j.field("capabilities") { emit_capabilities(j) }
          j.field("serverInfo") { emit_implementation(j) }
          j.field "instructions", instructions_text
        end
      end

      # `server/discover`: the one RPC the modern revision says a server MUST implement.
      # Everything the handshake used to hand over — supported versions, capabilities,
      # identity, instructions — as a RESULT a client can ask for whenever it likes, rather
      # than a state it has to open a session to obtain.
      #
      # Answered in both eras, and with or without modern `_meta`, because this is also the
      # probe a dual-era client sends before it knows what we are: refusing "tell me what to
      # say" for not having said it first would send that client back to `initialize` for no
      # reason. A version it names that we do not speak is still refused, by the gate above
      # — which is exactly how that client learns we are modern.
      private def handle_discover(id : JSON::Any) : Nil
        write_result(id, Protocol::LATEST) do |j|
          j.field("supportedVersions") { j.array { Protocol::SUPPORTED_VERSIONS.each { |v| j.string v } } }
          j.field("capabilities") { emit_capabilities(j) }
          j.field "instructions", instructions_text
          j.field "ttlMs", Protocol::DISCOVER_TTL_MS
          j.field "cacheScope", Protocol::CACHE_SCOPE
        end
        # A modern client has no `initialized` to send, so discovery is where this session
        # becomes one the operator can message.
        start_courier
      end

      # What this server offers, written once for the two places that advertise it — the
      # handshake and discovery — so the two can never describe different servers.
      private def emit_capabilities(j : JSON::Builder) : Nil
        j.object do
          j.field("tools") { j.object { } }
          # Claude Code's channel capability (#1090), declared only when the operator says
          # their Claude is launched with channels: a client that did not register it drops
          # every push silently, and the socket route would then carry the same line.
          # Latched HERE, on the declaration itself, so the courier pushes only to a client
          # that has actually been handed it.
          @channel_declared = Settings.mcp_channels?
          if @channel_declared
            j.field("experimental") { j.object { j.field("claude/channel") { j.object { } } } }
          end
        end
      end

      # `Implementation`: who this is. The handshake carries it as `serverInfo`, the modern
      # revision as `_meta["io.modelcontextprotocol/serverInfo"]` on every result.
      private def emit_implementation(j : JSON::Builder) : Nil
        j.object do
          j.field "name", "gori"
          j.field "version", Gori::VERSION
        end
      end

      # Surfaced at the handshake so the client/model knows up front what this server
      # exposes — in particular whether the (otherwise simply absent) action tools are
      # disabled by read-only mode, rather than discovering it only on a rejected call.
      #
      # The project half is read from `@tools` at the moment it is built, never from a copy
      # taken at construction: a client may re-handshake, and the binding it should be told
      # about is the one in force NOW.
      private def instructions_text : String
        # The bind failure comes FIRST when there is one: it is why the traffic tools are
        # refusing, and an agent that reads only the head of `instructions` still gets it.
        failure = @tools.bind_error.try { |reason| " The configured project could not be opened: #{reason}." }
        slug = @tools.project_slug
        name = @tools.project_name || slug
        root = @tools.workspace_root
        selected = if @tools.unbound?
                     " No project is bound yet. Call list_projects to see available projects, " \
                     "create_project to make one (auto-binds when unbound), or switch_project " \
                     "before using traffic tools (list_history, send_request, …). Pure tools " \
                     "(decode, jwt_*, ql_reference) work immediately."
                   elsif name
                     # "registered to", not "for": at start-up `workspace_root` is the git root
                     # that SELECTED the project and `bind_project` overwrites it with
                     # `ProjectRegistry#workspace_of` — the workspace the project belongs to.
                     # Those coincide only until a switch, and "for workspace X" would then have
                     # this server claiming to serve a directory it has never been run in. The
                     # project's registration is what both values actually are.
                     " As of this call the server is bound to project #{name}#{" [#{slug}]" if slug}" \
                     " via #{@tools.selection_source || "an explicit database"}#{", registered to workspace #{root}" if root}."
                   else
                     " Project selection source: #{@tools.selection_source || "unknown"}; call project_info before using data."
                   end
        # "as of this call", not "at this handshake": the same text answers `server/discover`,
        # which a stateless client may send at any point and more than once — there is no
        # handshake in that era to date the sentence from.
        #
        # …and that binding is a SNAPSHOT, not a pin. `switch_project` repoints the server for
        # every later call, MCP has no notification that refreshes `instructions`, and a client
        # caches this text for the whole session — so a sentence that reads as configuration
        # ("this server is pinned to X") went on naming X while writes landed in Y. Name the
        # authority instead: what a call actually touches is what project_info reports (#1003).
        #
        # "nothing pushes an update", NOT "never re-sent": a second `initialize` DOES rebuild
        # this text, which is the whole point of reading the binding live above. Overstating it
        # would be the same unkeepable claim one sentence further on.
        drift = " That is the binding as of this call and nothing pushes an update: " \
                "switch_project (and create_project when it auto-binds) repoints the server " \
                "mid-session without the client seeing new instructions. project_info — or the " \
                "switch's own result — is the live answer; re-check it before recording evidence."
        base = "gori MCP exposes the selected project's captured HTTP traffic " \
               "(history, flows, sitemap, scope, issues, notes, match&replace rules), plus a " \
               "pure `decoder` encode/decode/hash tool. Call ql_reference before " \
               "writing list_history/list_sitemap queries. Timestamps include unix " \
               "microseconds plus *_iso RFC3339 fields where available.#{failure}#{selected}#{drift}"
        text = if @allow_actions
                 "#{base} Action tools are enabled: send_request (supports flow_id/repeater_id), " \
                 "send_websocket (executes a persisted WS repeater), " \
                 "fuzz_*, mine_*, authorize_* (replay captured requests under several identities to " \
                 "find broken access control), create/update_issue, and create/delete_rule + set_rule_enabled " \
                 "make real outbound requests or mutate issues/rules. Active requests " \
                 "(send_request, send_websocket, fuzz, mine, authorize) are gated by the project scope: a target " \
                 "outside — or without — a configured scope is refused (SCOPE_BLOCKED) unless you pass " \
                 "allow_unscoped:true. Projects can be managed via list/create/switch/delete_project."
               else
                 "#{base} Read-only mode: action tools (send_request, send_websocket, fuzz_*, mine_*, authorize_*, " \
                 "create/update_issue, create/delete_rule) are disabled — restart without --read-only to enable them. " \
                 "switch_project (and create_project when unbound) remain available so you can still pick a project to inspect."
               end
        @tools.advertises?("operator_messages") ? text + OPERATOR_MESSAGES_NOTE : text
      end

      # #1090, the backstop route: every agent, whatever its client, can read what the operator
      # said. The live routes make it immediate where one exists — a peer note in Claude Code,
      # a queued turn in Codex, a channel event — and this sentence is what makes it reachable
      # for everyone else. Route-agnostic ON PURPOSE: the handshake instructions go out once
      # per session (#1003), so naming today's clients here would age into a wrong sentence
      # nothing can correct, and an agent told only about Claude's routes has no model of the
      # `[gori]` line that turns up in its own thread.
      OPERATOR_MESSAGES_NOTE = " The operator can message you from the gori TUI: such messages " \
                               "arrive in this session directly when gori has a live route to it " \
                               "(a `[gori]` line in your own turn, or beside the result of a gori " \
                               "tool you called), and are always readable with " \
                               "operator_messages — call it at the start of a " \
                               "turn, or whenever a note says gori has something for you, and act on it. " \
                               "Answer them with reply_to_operator (a one-line summary, optional detail): " \
                               "the operator is in gori, not in your terminal."

      # Start carrying operator messages once the client is initialized. `send` is this
      # server's frame writer (the lock, the UTF-8 guard); the store and client name are read
      # live from Tools on every tick, never copied (#1003's lesson).
      private def start_courier : Nil
        return if @courier
        courier = Courier.new(pid: Process.pid.to_i64,
          store: -> { @tools.current_store },
          client: -> { @tools.client_name },
          channels: -> { @channel_declared },
          emit: ->(frame : String) { send(frame) })
        courier.start
        @courier = courier
      end

      private def handle_tools_list(id : JSON::Any, era : String? = nil) : Nil
        write_result(id, era) do |j|
          j.field("tools") { @tools.list(j) }
          # Cache hints are REQUIRED on a modern `tools/list`.
          if era
            j.field "ttlMs", tool_list_ttl_ms
            j.field "cacheScope", Protocol::CACHE_SCOPE
          end
        end
      end

      # How long the catalogue may be treated as fresh — a promise about the catalogue, so it
      # is read OFF the catalogue rather than asserted beside it.
      #
      # It is fixed for the life of the process, a pure function of `--read-only` and
      # `--tools`, with one exception: a READ-ONLY server that is still unbound advertises
      # `create_project` (it is the one tool whose listing asks a live question,
      # `tools/projects.cr`), and loses it the moment a bind lands. While that is still
      # ahead of us the honest answer is zero — a client holding a five-minute copy would go
      # on offering the model a tool that now answers TOOL_DISABLED, and nothing invalidates
      # it: we advertise no `listChanged`, so the TTL is the only signal there is.
      private def tool_list_ttl_ms : Int32
        (@allow_actions || !@tools.unbound?) ? Protocol::TOOLS_LIST_TTL_MS : 0
      end

      private def handle_tools_call(id : JSON::Any, era : String?, params : JSON::Any?) : Nil
        name = obj_field(params, "name").try(&.as_s?)
        return write_error(id, -32602, "tools/call: missing 'name'") unless name
        args = tool_arguments(params)
        return write_error(id, -32602,
          "tools/call: 'arguments' must be an object (or a JSON-encoded one)") unless args
        result = @tools.call(name, args)
        # #1090: anything the operator said that no route has carried rides back HERE, beside
        # the tool's own answer — a second content block, never mixed into the first, so
        # `structuredContent` still parses and no tool's output is rewritten by a message that
        # has nothing to do with it. Asked after the call, so a message sent WHILE a long tool
        # ran goes out with that tool's result instead of waiting for the next one.
        #
        # Read here, RETIRED only once the frame is out. Reading and marking in one step meant
        # a cancelled request (`write_result` writes nothing for a cancelled id) or a client
        # that vanished mid-call left the message marked delivered and behind the cursor — the
        # ring saying "got it" for a line nothing ever carried. The side effect follows the
        # emit, as every guard in this codebase follows its refusal (#724).
        pending = @tools.pending_operator_note(name)
        emitted = write_result(id, era) do |j|
          j.field("content") do
            j.array do
              j.object { j.field "type", "text"; j.field "text", result.text }
              if p = pending
                j.object { j.field "type", "text"; j.field "text", p.text }
              end
            end
          end
          if result.is_error && (code = result.error_code)
            # Machine-processable error alongside the human `text` (the tools
            # layer guarantees a stable code on every plain-message error).
            j.field("structuredContent") { emit_error_object(j, result, code) }
          else
            emit_structured(j, result.text)
          end
          j.field "isError", result.is_error
        end
        @tools.commit_operator_note(pending) if pending && emitted
      end

      # `params.arguments` as the object the tools layer reads, or nil when it is a shape that
      # is not an argument list at all.
      #
      # An `as_h?`-only read answered nil for every other shape, and `Tools#call` substituted
      # an EMPTY hash for it — so a client that stringifies its arguments (which happens, and
      # which `RequestBuilder.header_pairs` already accepts one level down) had every argument
      # silently dropped and was told "missing required 'id'" for a call that named `id`. The
      # agent then "fixed" an argument it had sent correctly, in a loop. Parse the encoded
      # form; refuse anything else HERE, as a protocol error, rather than run a tool with none
      # of the arguments it was called with.
      #
      # Absent / null / blank all stay "no arguments" — a tool with only optional arguments is
      # legitimately called that way, and `""` is what an LLM emits for it.
      private def tool_arguments(params : JSON::Any?) : JSON::Any?
        raw = obj_field(params, "arguments")
        return EMPTY_ARGS if raw.nil? || raw.raw.nil?
        return raw if raw.as_h?
        if s = raw.as_s?
          return EMPTY_ARGS if s.strip.empty?
          parsed = (JSON.parse(s) rescue nil)
          return parsed if parsed && parsed.as_h?
        end
        nil
      end

      # The structured-error contract: {error_code, message, field?, retryable,
      # details?}. `message` mirrors content[0].text so a caller reading only
      # structuredContent still gets the human summary.
      private def emit_error_object(j : JSON::Builder, result : Tools::Result, code : String) : Nil
        j.object do
          j.field "error_code", code
          j.field "message", result.text
          j.field "field", result.field if result.field
          j.field "retryable", result.retryable
          if d = result.details
            j.field("details") { d.to_json(j) }
          end
        end
      end

      # MCP structuredContent is an object. Preserve the text block for older
      # clients, while giving newer clients parsed data directly so callers do
      # not have to JSON-decode content[0].text a second time. Array/scalar tool
      # payloads are wrapped to satisfy the object shape required by MCP.
      #
      # The tool's text is COPIED THROUGH rather than decoded and re-encoded. It is already
      # valid JSON text; `JSON.parse` built a whole JSON::Any tree of it only to serialise
      # that tree straight back out, which on a large list_history/fuzz_results answer is
      # megabytes of garbage per call — on a server that lives for the whole session and
      # whose peak memory is what an agent notices. `json_shape` validates the same thing a
      # parse did (nothing non-JSON may be emitted raw) without materialising any of it:
      # measured 1.7x faster with ~3x fewer bytes allocated on a 725 KB payload.
      private def emit_structured(j : JSON::Builder, text : String) : Nil
        case json_shape(text)
        in JsonShape::Object then j.field("structuredContent") { j.raw(text) }
        in JsonShape::Array  then j.field("structuredContent") { j.object { j.field("items") { j.raw(text) } } }
        in JsonShape::Scalar then j.field("structuredContent") { j.object { j.field("value") { j.raw(text) } } }
        in JsonShape::Invalid
          # A plain-message tool result (no error_code, so not the error branch above):
          # content[0].text carries it alone, exactly as before.
        end
      end

      private enum JsonShape
        Object
        Array
        Scalar
        Invalid
      end

      # The shape of `text` as one JSON document, or Invalid when it is not one. TRAILING
      # bytes make it Invalid too: `{"a":1} oops` parses a value and would otherwise be
      # copied through verbatim, breaking the frame for every client on the connection —
      # the one failure mode a raw copy has that a parse-and-rebuild did not.
      private def json_shape(text : String) : JsonShape
        pull = JSON::PullParser.new(text)
        shape = case pull.kind
                when .begin_object? then JsonShape::Object
                when .begin_array?  then JsonShape::Array
                else                     JsonShape::Scalar
                end
        pull.skip
        pull.kind.eof? ? shape : JsonShape::Invalid
      rescue JSON::ParseException
        JsonShape::Invalid
      end

      # Field of a JSON object that may be nil/non-object — never raises.
      private def obj_field(any : JSON::Any?, key : String) : JSON::Any?
        any.try(&.as_h?).try(&.[key]?)
      end

      # `true` when the frame actually went out — a cancelled request and a closed stream both
      # answer `false`. Every caller but one ignores it; `handle_tools_call` must not retire an
      # operator message onto a response that was never emitted.
      #
      # The block writes the result's FIELDS; the envelope is this method's, because the
      # envelope is where the two eras differ. `era` non-nil means the request named a
      # modern revision, and the result then carries `resultType` and the server's identity
      # — which a legacy result must NOT, and does not need to: the spec's own rule is that
      # a missing `resultType` reads as `complete`.
      private def write_result(id : JSON::Any?, era : String? = nil, &block : JSON::Builder ->) : Bool
        return false if cancelled?(id)
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            emit_id(j, id)
            j.field("result") do
              j.object do
                # First, because it is what a client reads to decide how to parse the rest.
                j.field "resultType", Protocol::RESULT_COMPLETE if era
                block.call(j)
                if era
                  j.field("_meta") { j.object { j.field(Protocol::META_SERVER_INFO) { emit_implementation(j) } } }
                end
              end
            end
          end
        end)
      end

      # `data` is the error's machine-readable half — what `UnsupportedProtocolVersionError`
      # carries its `supported` list in. A Proc rather than a block so the one method serves
      # both callers; JSON-RPC makes the member optional and most errors here have nothing
      # to put in it.
      private def write_error(id : JSON::Any?, code : Int32, message : String,
                              data : Proc(JSON::Builder, Nil)? = nil) : Nil
        return if cancelled?(id)
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            emit_id(j, id)
            j.field("error") do
              j.object do
                j.field "code", code
                j.field "message", message
                j.field("data") { data.call(j) } if data
              end
            end
          end
        end)
      end

      # Whether this response is owed to a request the client has since cancelled — checked
      # at the two write sites so every path that answers a request goes through it, not
      # just the tool one. Consuming the entry here (`delete`) keeps the set to what is
      # genuinely outstanding. The empty check is the ordinary case and costs nothing.
      private def cancelled?(id : JSON::Any?) : Bool
        return false if @cancelled.empty? || id.nil?
        return false unless @cancelled.delete(id.to_json)
        Log.info { "mcp: dropped the response to a cancelled request (id=#{id})" }
        true
      end

      # Echoes the request id verbatim (int stays int, string stays string); null
      # when we have none (e.g. a parse error before we could read it).
      private def emit_id(j : JSON::Builder, id : JSON::Any?) : Nil
        j.field("id") { id ? id.to_json(j) : j.null }
      end

      # A TOP-LEVEL `"id"` scraped out of a line the JSON parser refused, so a parse error can
      # still be correlated by the client that sent it. Deliberately textual and deliberately
      # narrow: the line is by definition not parseable, so there is no structure to walk. The
      # anchor is `{"jsonrpc":…,"id":…` — the id must appear before `"method"`/`"params"`,
      # which is where every client this speaks to puts it, and which keeps an `"id"` nested
      # inside a tool ARGUMENT (get_flow's own `id`, an issue id, …) from being mistaken for
      # the envelope's. Nil when nothing matches: a wrong id is worse than none.
      private def recover_id(line : String) : JSON::Any?
        # A line that OPENS as an array is a BATCH, and its first `"id"` belongs to the first
        # MEMBER — there is no envelope id to recover. Answering the whole unparseable batch
        # under that one id resolves exactly one of the client's pending promises and strands
        # every other member: the same hang batch support exists to prevent, arrived at from
        # the other side. A batch parse error is answered at id null, which is also what
        # JSON-RPC asks for when the request cannot be read.
        return nil if line.lstrip.starts_with?('[')
        # PCRE2 REFUSES a subject that is not valid UTF-8 — it raises `ArgumentError`, and
        # this method is reached from inside the JSON-parse rescue, which is precisely
        # where a line carrying a stray 0xFF arrives. That raise used to leave `run`
        # unhandled and take the server down. Scrub for the id scan only: the id is a
        # short ASCII token, so U+FFFD anywhere in the line cannot change which one we
        # find, and nothing here reaches the caller's payload.
        line = line.scrub unless line.valid_encoding?
        head = line[0, {line.index(%("method")) || line.size, line.index(%("params")) || line.size}.min]
        m = head.match(/"id"\s*:\s*(?:(-?\d{1,18})|"([^"\\]{0,128})")/)
        return nil unless m
        if n = m[1]?
          n.to_i64?.try { |i| JSON::Any.new(i) }
        else
          m[2]?.try { |s| JSON::Any.new(s) }
        end
      end

      # Last line of defence for the transport's UTF-8 contract. Every emit site that
      # touches outside-origin text already routes through `Serialize.text`; this catches
      # the one a future change forgets. A single invalid byte anywhere in the payload
      # makes a strict client reject the WHOLE line, so a lossy U+FFFD in one field beats
      # losing the response. `valid_encoding?` is ~13x cheaper than `scrub` and the
      # overwhelmingly common case, so the scrub only runs when something slipped through.
      private def wire_safe(payload : String) : String
        return payload if payload.valid_encoding?
        Log.warn { "mcp: response carried invalid UTF-8; scrubbed at the transport (an emit site is missing Serialize.text)" }
        payload.scrub
      end

      # `true` when the payload was written (or buffered into an open batch), `false` when the
      # stream is already closed or the write failed. Callers that only emit ignore it.
      private def send(payload : String) : Bool
        return false if @closed
        # Inside a batch this is one member's response, not a frame: buffer it for
        # handle_batch, which emits the array through this same method once. Deliberately
        # NOT wire_safe'd here — the joined array gets one pass below, and `[`, `,` and `]`
        # cannot introduce invalid UTF-8, so scanning each member too would walk a
        # multi-megabyte batch twice for the same answer.
        # …and only for the fiber that OPENED the batch: the reader answering a `ping` while
        # the worker is mid-batch would otherwise have its frame swept into that array, and
        # the client would get a ping reply it can only find by walking a batch it did not
        # send.
        if (batch = @batch) && @batch_fiber == Fiber.current
          batch << payload
          return true
        end
        # One writer at a time. A payload larger than the pipe buffer yields mid-write, and
        # a second fiber's line landing in that gap would corrupt both frames.
        @write_lock.synchronize do
          @output.puts(wire_safe(payload)) # newline framing
          @output.flush                    # or the client blocks on the unterminated line
        end
        true
      rescue ex : IO::Error
        # The client is gone (broken pipe). Stop writing and let the run loop end
        # cleanly instead of unwinding an unhandled exception out of a handler.
        @closed = true
        Log.info { "mcp: output stream closed (#{ex.message})" }
        false
      end
    end
  end
end
