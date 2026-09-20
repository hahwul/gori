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
        # ABSENT is the legacy era. PRESENT is a client speaking the modern one, whatever it
        # managed to put in the slot — so a non-string there is a malformed MODERN request,
        # not a legacy one, and reading it as legacy would serve a client its own
        # serialisation bug with a straight face (`20260728` unquoted, a `null` from an
        # absent config). The key is reserved by the spec; no handshake client writes it.
        slot = obj_field(meta, Protocol::META_PROTOCOL_VERSION)
        return EraGate.new(nil, false) if slot.nil?
        requested = slot.as_s?
        unless requested
          write_error(id, -32602, "#{Protocol::META_PROTOCOL_VERSION} must be a string " \
                                  "naming a protocol revision (got #{json_type_of(slot)})")
          return EraGate.new(nil, true)
        end
        return EraGate.new(nil, false) if Protocol.legacy?(requested)
        # JSON-RPC batching was removed in 2025-06-18 and the modern schema has no frame for
        # it: one message per line, and an array is not one. We still RECEIVE batches, because
        # 2025-03-26 made that mandatory and we advertise it — but answering a member that has
        # declared a revision where the array does not exist would put a frame on stdout that
        # the client which sent it cannot legally read.
        #
        # …but only for the fiber that is IN that batch, the same test `send` makes for the
        # same reason. `@batch` is a worker-fiber local in all but name, and this method also
        # runs on the READER, which answers `ping` ahead of the queue: a modern liveness probe
        # arriving while the worker happened to be mid-batch was refused for being inside an
        # array it was never in. That is the one message the reader/worker split exists to
        # keep answering — a client whose pings go unanswered concludes the server is dead and
        # kills it mid-call.
        if @batch && @batch_fiber == Fiber.current && Protocol.modern?(requested)
          write_error(id, -32600, "JSON-RPC batching does not exist in #{requested} " \
                                  "(removed in 2025-06-18) — send one message per line")
          return EraGate.new(nil, true)
        end
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
        # `server/discover` is NOT exempt from this, though it IS exempt from having to name
        # a version at all — a request carrying no `_meta` is served as the probe it is. The
        # line between those two is what a client can legitimately be missing: an era it has
        # not declared yet, versus a required field of an era it just did. `ClientCapabilities`
        # has no required member — `{}` is valid, and is what the spec's own examples send —
        # so there is nothing a bootstrap probe could fail to have here, and being lenient
        # would only teach one client that its malformed requests are fine everywhere.
        caps = obj_field(meta, Protocol::META_CLIENT_CAPS)
        unless caps.try(&.as_h?)
          # Two different mistakes, said differently: a client that never sent the field
          # needs to be told it is required, and one that sent the wrong shape needs to be
          # told which shape. "is required" for a field plainly present reads as a server
          # that cannot see it.
          write_error(id, -32602, caps.nil? ? "#{Protocol::META_CLIENT_CAPS} is required in _meta on every #{requested} request" : "#{Protocol::META_CLIENT_CAPS} must be a JSON object (got #{json_type_of(caps)})")
          return EraGate.new(nil, true)
        end
        EraGate.new(requested, false)
      end

      # What a `_meta` slot turned out to hold, for a refusal that has to name it. The
      # client cannot fix a shape it is not told, and "invalid params" alone has cost more
      # than one agent a retry loop against an argument it had spelled correctly.
      private def json_type_of(any : JSON::Any) : String
        case raw = any.raw
        when Nil                     then "null"
        when Bool                    then "a boolean"
        when Int64, Float64          then "a number"
        when String                  then "a string"
        when Array(JSON::Any)        then "an array"
        when Hash(String, JSON::Any) then "an object"
        else                              raw.class.to_s
        end
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
        when "server/discover"      then handle_discover(id)
        when "subscriptions/listen" then handle_subscriptions_listen(id)
        when "initialize"           then handle_initialize(id, params)
        when "ping"                 then write_result(id, era) { }
        when "tools/list"           then handle_tools_list(id, era, params)
        when "tools/call"           then handle_tools_call(id, era, params)
        else                             write_error(id, -32601, "Method not found: #{method}")
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
          # The client has stopped waiting for a request we are still holding. Two things
          # follow, and they are the spec's MUST and its SHOULD:
          #
          #   - no response is ever sent for a cancelled id (`cancelled?` at the write
          #     sites), so a client that has already reused or retired it is not handed an
          #     answer it has nowhere to put; and
          #   - the work STOPS, for the tools that can be stopped. A fiber cannot be
          #     interrupted, so this is cooperative: `cancel_probe` hands the tools layer a
          #     predicate, and a long tool polls it between sends. `probe_scan{active:true}`
          #     was the case that made this a defect rather than a nicety — a cancelled scan
          #     went on putting real attack traffic on a third party's server for up to
          #     `PROBE_ACTIVE_MAX_FLOWS` flows, and the resource we were failing to free was
          #     someone else's. Which tools honour it is listed on `Tools#call` (#1103).
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
        # The handshake IS the declaration, so the latch the courier reads is written HERE and
        # nowhere else. It used to be written inside `emit_capabilities`, which `server/discover`
        # also calls — with `channel: false`, because the stateless era forbids an unsolicited
        # frame — so one discovery probe from a dual-era client silently RETIRED the channel a
        # handshake had just handed it. The operator's `Settings.mcp_channels` is read once,
        # here: a toggle afterwards cannot register a channel with a client that already did not
        # take one, and cannot withdraw one it did.
        @channel_declared = Settings.mcp_channels?
        write_result(id) do |j|
          j.field "protocolVersion", version
          j.field("capabilities") { emit_capabilities(j, channel: @channel_declared) }
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
          j.field("capabilities") { emit_capabilities(j, channel: false) }
          j.field "instructions", instructions_text
          j.field "ttlMs", Protocol::DISCOVER_TTL_MS
          j.field "cacheScope", Protocol::CACHE_SCOPE
        end
        # A modern client has no `initialized` to send, so discovery is where this session
        # becomes one the operator can message.
        start_courier
      end

      # `subscriptions/listen` — the modern revision's one server-to-client push channel,
      # which replaced the HTTP GET endpoint and `resources/subscribe`. gori has nothing to
      # push: it declares no `listChanged`, serves no resources or prompts, and its one
      # vendor notification is now confined to the handshake era (`emit_capabilities`).
      #
      # So the conformant answer is the empty one, and it is a REAL answer rather than
      # `-32601`. The acknowledgement goes out first, as the spec requires, carrying the
      # subset the server agreed to honour — which is none, because "notification types the
      # server does not support are omitted" — and then the subscription is closed the way a
      # server closes one it is ending itself: with the successful response to the original
      # request. A client reads that as a clean end and falls back on the `ttlMs` it was
      # already given, instead of holding a promise nothing will resolve.
      #
      # Closing it immediately is not a shortcut, it is the only safe shape here. This
      # server runs ONE request at a time on a single worker fiber (see the class header), so
      # a `subscriptions/listen` left open would park that worker and starve every tool call
      # behind it — a stream that never delivers anything, blocking the ones that would.
      private def handle_subscriptions_listen(id : JSON::Any) : Nil
        return if cancelled?(id)
        write_notification("notifications/subscriptions/acknowledged") do |j|
          # Inside `_meta`, not beside it: the subscription id is protocol metadata, and a
          # client demultiplexing a stdio channel looks for it in exactly one place.
          j.field("_meta") { j.object { emit_subscription_id(j, id) } }
          j.field("notifications") { j.object { } }
        end
        write_result(id, Protocol::LATEST, meta: ->(j : JSON::Builder) { emit_subscription_id(j, id) }) { }
      end

      # Every message on a subscription carries the id of the request that opened it — on
      # stdio that is the only way a client can tell one stream's frames from another's.
      private def emit_subscription_id(j : JSON::Builder, id : JSON::Any) : Nil
        j.field(Protocol::META_SUBSCRIPTION_ID) { id.to_json(j) }
      end

      # What this server offers, written once for the two places that advertise it — the
      # handshake and discovery — so the two can never describe different servers.
      #
      # `channel` is the one thing they differ on, and it is not a difference in what gori
      # can do. The `claude/channel` push (#1090) is an unsolicited notification on stdout,
      # and `2026-07-28` closed that door: a stdio server may write responses, notifications
      # belonging to an IN-FLIGHT request, and notifications on an acknowledged
      # `subscriptions/listen` stream — and a free-running courier frame is none of the
      # three. So the capability is declared to the handshake era, which still allows it,
      # and never to a stateless client. Nothing is lost that the operator can see: the
      # channel was always the unconfirmable route, and the socket, the Codex queue and the
      # `operator_messages` poll all carry the same message off-stdout, for every client.
      #
      # A pure emitter: `channel` is DECIDED by the caller (`handle_initialize` reads the
      # operator's setting and latches it; `handle_discover` passes false), because a builder
      # that also writes session state is one that rewrites it every time something asks the
      # server to describe itself — which is how a discovery probe came to retire a channel
      # the handshake had declared.
      private def emit_capabilities(j : JSON::Builder, *, channel : Bool) : Nil
        j.object do
          j.field("tools") { j.object { } }
          # Declared only when the operator says their Claude is launched with channels: a
          # client that did not register it drops every push silently, and the socket route
          # would then carry the same line.
          if channel
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
        ql = @tools.advertises?("ql_reference") ? " Call ql_reference before writing " \
                                                  "#{advertised("list_history", "list_sitemap") || "filter"} queries." : ""
        decoder = @tools.advertises?("decode") ? ", plus a pure `decoder` encode/decode/hash tool" : ""
        base = "gori MCP exposes the selected project's captured HTTP traffic " \
               "(history, flows, sitemap, scope, issues, notes, match&replace rules)" \
               "#{decoder}.#{ql} Timestamps include unix " \
               "microseconds plus *_iso RFC3339 fields where available.#{failure}#{binding_note}"
        text = @allow_actions ? "#{base}#{actions_note}#{projects_note}" : "#{base}#{read_only_note}#{projects_note}"
        text += operator_messages_note
        # The backstop for every name above, and for any added later without this treatment:
        # when a filter is in force at all, say so and name the authority. A sentence that
        # survives a future edit while its tool does not is then at least contradicted.
        text + (filter_note || "")
      end

      # The operator-messages paragraph, one clause per tool it names — the rule every other
      # sentence in this text follows. Anchored on `operator_messages` because that is the
      # backstop an agent reads messages with; the reply clause is admitted separately.
      private def operator_messages_note : String
        return "" unless @tools.serves?("operator_messages")
        OPERATOR_MESSAGES_NOTE + (@tools.serves?("reply_to_operator") ? OPERATOR_REPLY_NOTE : "")
      end

      # Which project this server is on, and the warning that the answer moves. Split out of
      # `instructions_text`, and split again below, because both halves grew a conditional per
      # tool name once the text had to stop naming tools that are not there.
      private def binding_note : String
        "#{@tools.unbound? ? unbound_note : bound_note}#{drift_note}"
      end

      # No project yet. Each clause names a tool, so each clause goes when that tool does.
      private def unbound_note : String
        hints = [] of String
        hints << "list_projects to see available projects" if @tools.advertises?("list_projects")
        hints << "create_project to make one (auto-binds when unbound)" if @tools.advertises?("create_project")
        hints << "switch_project to pick an existing one" if @tools.advertises?("switch_project")
        pure = advertised("decode", "jwt_decode", "ql_reference")
        String.build do |b|
          b << " No project is bound yet."
          b << " Call " << hints.join(", or ") << " before using traffic tools." unless hints.empty?
          b << " Pure tools (" << pure << ") work immediately." if pure
        end
      end

      # "registered to", not "for": at start-up `workspace_root` is the git root that SELECTED
      # the project and `bind_project` overwrites it with `ProjectRegistry#workspace_of` — the
      # workspace the project belongs to. Those coincide only until a switch, and "for
      # workspace X" would then have this server claiming to serve a directory it has never
      # been run in. The project's registration is what both values actually are.
      private def bound_note : String
        slug = @tools.project_slug
        name = @tools.project_name || slug
        unless name
          return " Project selection source: #{@tools.selection_source || "unknown"}." +
            (@tools.advertises?("project_info") ? " Call project_info before using data." : "")
        end
        root = @tools.workspace_root
        " As of this call the server is bound to project #{name}#{" [#{slug}]" if slug}" \
        " via #{@tools.selection_source || "an explicit database"}#{", registered to workspace #{root}" if root}."
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
      #
      # The whole sentence is about the tools that move the binding and the tool that reports
      # it, so it is dropped when neither is reachable: warning a client about drift it cannot
      # cause, and pointing it at an authority it cannot call, is worse than silence.
      private def drift_note : String
        reporter = @tools.advertises?("project_info") ? " project_info — or the switch's own result — is the live answer; " \
                                                        "re-check it before recording evidence." : ""
        if movers = advertised("switch_project", "create_project")
          " That is the binding as of this call and nothing pushes an update: #{movers} " \
          "repoints the server mid-session without the client seeing new instructions." + reporter
        elsif @tools.advertises?("project_info")
          " Nothing pushes an update to this text; project_info is the live answer."
        else
          ""
        end
      end

      # Only the tools in `names` this server's `tools/list` actually carries, joined for
      # prose — or nil when every one of them is absent, so the sentence naming them can be
      # dropped whole.
      #
      # `instructions` is the first thing the model reads and it is read as FACT. A sentence
      # naming a tool `tools/list` does not carry sends the agent to call something that
      # answers "unknown tool", and this text used to do exactly that: under
      # `--tools='list_*'` it went on saying "Call ql_reference before writing queries" — the
      # very first instruction — while advertising neither ql_reference nor nine other names
      # it mentioned. The mechanism was already here; it reached one sentence (the
      # operator-messages note) and none of the rest.
      #
      # `serves?`, not `advertises?`: `--read-only` is the OTHER reason a name is missing
      # from tools/list, and this text used to offer `delete_project` — gated, so neither
      # listed nor runnable — to every read-only server. The one sentence that names an
      # absent tool ON PURPOSE asks `restorable` below instead.
      private def advertised(*names : String) : String?
        kept = names.to_a.select { |n| @tools.serves?(n) }
        kept.empty? ? nil : kept.join(", ")
      end

      # The read-only sentence's counterpart: the tools the `--tools` filter kept, whether or
      # not the gate is currently withholding them. It exists for exactly one clause — "action
      # tools (…) are disabled — restart without --read-only to enable them" — whose whole
      # point is naming what a restart would bring back. A tool the FILTER removed is not
      # coming back either way, so it is still not promised.
      private def restorable(*names : String) : String?
        kept = names.to_a.select { |n| @tools.advertises?(n) }
        kept.empty? ? nil : kept.join(", ")
      end

      # The action paragraph, naming only what is reachable. Each clause carries its own
      # tool, so a filtered server describes the workbench it actually has.
      private def actions_note : String
        clauses = [] of String
        clauses << "send_request (supports flow_id/repeater_id)" if @tools.advertises?("send_request")
        clauses << "send_websocket (executes a persisted WS repeater)" if @tools.advertises?("send_websocket")
        clauses << "fuzz_*" if @tools.advertises?("fuzz_start")
        clauses << "mine_*" if @tools.advertises?("mine_start")
        clauses << "authorize_* (replay captured requests under several identities to find " \
                   "broken access control)" if @tools.advertises?("authorize_start")
        clauses << "create/update_issue" if advertised("create_issue", "update_issue")
        clauses << "create/delete_rule + set_rule_enabled" if advertised("create_rule", "delete_rule", "set_rule_enabled")
        return "" if clauses.empty?
        gated = advertised("send_request", "send_websocket", "fuzz_start", "mine_start", "authorize_start")
        " Action tools are enabled: #{clauses.join(", ")} make real outbound requests or " \
        "mutate issues/rules." + (gated ? " Active requests are gated by the project scope: a target outside — or without — a " \
                                          "configured scope is refused (SCOPE_BLOCKED) unless you pass allow_unscoped:true." : "")
      end

      # …and its `--read-only` counterpart, where naming an ABSENT tool is the whole point:
      # the sentence exists to say what restarting would restore. The two reasons a tool is
      # missing are not the same, and `advertises?` is exactly the one that separates them —
      # it reads the `--tools` filter only, so it answers "would this be here if the gate
      # were lifted". A tool the FILTER removed is not coming back either way, so it is not
      # promised.
      private def read_only_note : String
        disabled = [] of String
        disabled << "send_request" if @tools.advertises?("send_request")
        disabled << "send_websocket" if @tools.advertises?("send_websocket")
        disabled << "fuzz_*" if @tools.advertises?("fuzz_start")
        disabled << "mine_*" if @tools.advertises?("mine_start")
        disabled << "authorize_*" if @tools.advertises?("authorize_start")
        disabled << "create/update_issue" if restorable("create_issue", "update_issue")
        disabled << "create/delete_rule" if restorable("create_rule", "delete_rule")
        head = if disabled.empty?
                 " Read-only mode: this server cannot write or send."
               else
                 " Read-only mode: action tools (#{disabled.join(", ")}) are disabled — " \
                 "restart without --read-only to enable them."
               end
        pickers = advertised("switch_project", "create_project")
        pickers ? "#{head} #{pickers} remain available so you can still pick a project to inspect." : head
      end

      private def projects_note : String
        picks = advertised("list_projects", "create_project", "switch_project", "delete_project")
        picks ? " Projects can be managed via #{picks}." : ""
      end

      # Said once, when `--tools` narrowed the catalogue: whatever the prose above named, the
      # list is the authority. Also the only place the agent learns the surface is deliberate
      # rather than broken.
      private def filter_note : String?
        f = @tools.tool_filter
        return nil unless f
        # `served_count`, not `f.size`: under `--read-only` the filter's own count is the set
        # it KEPT, and the gate then withholds some of it. One number here, and it is the one
        # the very next `tools/list` will return.
        " This server was started with --tools=#{f.spec.inspect} and advertises #{@tools.served_count} of " \
        "#{Tools::TOOL_NAMES.size} tools; tools/list is the authority on what it has."
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
                               "turn, or whenever a note says gori has something for you, and act on it."

      # …and the half that names the ANSWER, which is a second tool and so a second condition.
      # One sentence naming two tools is one sentence that is wrong whenever the filter keeps
      # only one of them — `--tools='list_*,operator_messages'` sent the agent to a
      # reply_to_operator that tools/list does not carry. A live route still carries
      # `OperatorNote::REPLY_HINT`, which names the tool at the moment it is needed.
      OPERATOR_REPLY_NOTE = " Answer them with reply_to_operator (a one-line summary, optional " \
                            "detail): the operator is in gori, not in your terminal."

      # Start carrying operator messages once the client is initialized. `send` is this
      # server's frame writer (the lock, the UTF-8 guard); the store and client name are read
      # live from Tools on every tick, never copied (#1003's lesson).
      private def start_courier : Nil
        return if @courier
        courier = Courier.new(pid: Process.pid.to_i64,
          store: -> { @tools.current_store },
          client: -> { @tools.client_name },
          channels: -> { @channel_declared },
          emit: ->(frame : String) { send(frame) },
          claim: ->(mid : Int64) { @tools.claim_message(mid) },
          release: ->(mid : Int64) { @tools.release_message(mid) })
        courier.start
        @courier = courier
      end

      private def handle_tools_list(id : JSON::Any, era : String? = nil, params : JSON::Any? = nil) : Nil
        # `tools/list` is paginated in the spec and NOT paginated here: the catalogue leaves
        # in one page and no result ever carries a `nextCursor`, so the only cursor a client
        # can hand us is one we never minted. Answering it with page one anyway is the shape
        # of a silent loop — a client resuming from a cursor it believes in gets the head of
        # the list back and no way to tell. "Invalid cursors SHOULD result in an error with
        # code -32602" is the spec's answer and it is also the honest one.
        if cursor = obj_field(params, "cursor")
          return write_error(id, -32602,
            "tools/list: unknown cursor #{cursor.to_json} — this server returns the whole " \
            "catalogue in one page and never issues a nextCursor")
        end
        write_result(id, era) do |j|
          j.field("tools") { @tools.list(j) }
          # Cache hints are REQUIRED on a modern `tools/list`. A flat constant is honest only
          # because the catalogue cannot move: it is a function of `--read-only` and `--tools`
          # and of nothing a call can reach, which the spec states as a MUST NOT ("the set …
          # MUST NOT vary per-connection or as a side effect of other requests on the
          # connection") and which `spec/mcp/protocol_spec.cr` asserts rather than claims.
          if era
            j.field "ttlMs", Protocol::TOOLS_LIST_TTL_MS
            j.field "cacheScope", Protocol::CACHE_SCOPE
          end
        end
      end

      private def handle_tools_call(id : JSON::Any, era : String?, params : JSON::Any?) : Nil
        name = obj_field(params, "name").try(&.as_s?)
        return write_error(id, -32602, "tools/call: missing 'name'") unless name
        args = tool_arguments(params)
        return write_error(id, -32602,
          "tools/call: 'arguments' must be an object (or a JSON-encoded one)") unless args
        result = @tools.call(name, args, cancelled: cancel_probe(id))
        # "Protocol Errors indicate issues with the request structure itself that models are
        # less likely to be able to fix: Unknown tool …" — the spec names this one and gives
        # the code. A name that is not in `tools/list` is not a tool that ran and failed, and
        # answering it with `isError` puts it in the bucket a client is told to hand back to
        # the model for a retry. The sentence survives as the error's `message`, which is what
        # `--tools`'s "everything available is in tools/list" was written to say; what it
        # stops being is a tool RESULT. Read before the operator note, so a message the
        # operator sent is not spent on a call that never reached a tool.
        if result.is_error && result.error_code == "UNKNOWN_TOOL"
          return write_error(id, -32602, result.text)
        end
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

      # Preserve the text block for older clients, while giving newer clients parsed data
      # directly so callers do not have to JSON-decode content[0].text a second time.
      #
      # Array/scalar tool payloads are WRAPPED (`{items: …}`, `{value: …}`) because through
      # `2025-11-25` `structuredContent` is typed as an object and nothing else may go there.
      # `2026-07-28` widened it to any JSON value, so the wrapper is no longer required —
      # but it is still emitted, for both eras, because the alternative is one tool with two
      # output shapes depending on which revision asked. A client that has learned
      # `list_history` answers `{items: […]}` is not helped by the same server answering a
      # bare array to the same call on a different day, and gori declares no `outputSchema`
      # that the wrapper could contradict. Revisit that the day it declares one.
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
      private def write_result(id : JSON::Any?, era : String? = nil,
                               meta : Proc(JSON::Builder, Nil)? = nil,
                               &block : JSON::Builder ->) : Bool
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
                # ONE `_meta`, whoever contributes to it: two `j.field("_meta")` calls would
                # emit a duplicate key, which is a frame some clients reject outright.
                if era || meta
                  j.field("_meta") do
                    j.object do
                      meta.try(&.call(j))
                      j.field(Protocol::META_SERVER_INFO) { emit_implementation(j) } if era
                    end
                  end
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
      # A one-way message: no id, and the receiver must not answer it.
      private def write_notification(method : String, &block : JSON::Builder ->) : Nil
        send(JSON.build do |j|
          j.object do
            j.field "jsonrpc", "2.0"
            j.field "method", method
            j.field("params") { j.object { block.call(j) } }
          end
        end)
      end

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

      # "Is the call you are serving cancelled?", as a predicate — the one seam between the
      # JSON-RPC id (which only this class knows) and a tool that wants to stop (which must
      # never learn the id, the set, or this server). A closure over the key rather than an
      # argument threaded through 179 tools, and it costs a running tool one `Set#empty?` per
      # poll in the case that is always the common one.
      #
      # NOT `cancelled?` below: that one DELETES the key, because it is the write site's
      # one-shot suppression. A tool polling it would clear the flag on its first read and
      # `write_result` would then answer a request the client had retired.
      #
      # A batch member always reads false, and correctly: `@pending` does not track member
      # ids (their responses have to leave as one array), so `@cancelled` never holds one.
      private def cancel_probe(id : JSON::Any) : Proc(Bool)
        key = id.to_json
        -> { !@cancelled.empty? && @cancelled.includes?(key) }
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
