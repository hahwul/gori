require "json"
require "../ascii_bytes"
require "../url"
require "../token_extract"
require "../proxy/ws/frame"

module Gori
  class Store
    # Lifecycle of a captured flow. Stored as the enum value (INTEGER).
    enum FlowState
      Pending  # request captured, response not yet received
      Complete # response captured
      Error    # upstream/parse/tls failure (captured anyway, P7)
      Aborted  # connection died mid-flow
    end

    # Persist-time DTO produced by a proxy fiber for the request side.
    # `head`/`body` are the byte-exact wire octets (truth, P7); the rest are
    # projections the History list/QL need. Built only by `Gori::FlowMapper`.
    struct CapturedRequest
      getter created_at : Int64 # unix micros
      getter scheme : String
      getter host : String
      getter port : Int32
      getter method : String
      getter target : String
      getter http_version : String
      getter sni : String?
      getter alpn : String?
      getter tls_version : String?
      getter head : Bytes
      getter body : Bytes? # captured body, possibly truncated to the capture cap
      getter? body_truncated : Bool
      getter body_size : Int64? # TRUE wire body size (nil → derive from `body`); ≥ body.size when truncated
      # When this flow is a decoded HTTP/2 stream, links back to its raw frame log.
      getter h2_conn_id : Int64?
      getter h2_stream_id : Int64?
      # gori ANSWERED this request itself — a short-circuit rule matched and no origin was
      # dialed (#511). Carried on the request DTO because the proxy decides it before the
      # response exists; `Store#insert_one` persists it to `flows.short_circuited`.
      getter? short_circuited : Bool
      # What gori has to SAY about this flow that its bytes cannot — see `FlowRow#advisory`.
      getter advisory : String?

      def initialize(@created_at, @scheme, @host, @port, @method, @target,
                     @http_version, @head, @body = nil,
                     @sni = nil, @alpn = nil, @tls_version = nil,
                     @body_truncated = false, @body_size = nil,
                     @h2_conn_id = nil, @h2_stream_id = nil, @short_circuited = false,
                     @advisory = nil)
      end
    end

    # Persist-time DTO for the response side, keyed to an existing flow id.
    struct CapturedResponse
      getter flow_id : Int64
      getter status : Int32
      getter reason : String?
      getter content_type : String?
      # Content-Encoding header value (nil = none/identity). Extracted once by the proxy
      # where the response headers are already parsed, so the store writer can decide FTS
      # skipping without re-parsing the raw head per flow.
      getter content_encoding : String?
      getter head : Bytes
      getter body : Bytes? # captured body, possibly truncated to the capture cap
      getter? body_truncated : Bool
      getter body_size : Int64? # TRUE wire body size (nil → derive from `body`)
      getter ttfb_us : Int64?
      getter duration_us : Int64?
      getter state : FlowState
      getter error : String?
      # See `FlowRow#advisory`. nil means "nothing new to say", which is NOT the same as ""
      # — a response-side advisory has to be able to leave the request side's alone, so
      # `Store#update_one` only writes the column when this is non-nil.
      getter advisory : String?

      def initialize(@flow_id, @status, @head, @body = nil, @reason = nil,
                     @content_type = nil, @ttfb_us = nil, @duration_us = nil,
                     @state = FlowState::Complete, @error = nil,
                     @body_truncated = false, @body_size = nil, @content_encoding = nil,
                     @advisory = nil)
      end
    end

    # Read model for the History list — projections only, NO blobs (rows stay
    # light for fast scrolling). `status` is nil while Pending.
    struct FlowRow
      getter id : Int64
      getter created_at : Int64
      getter scheme : String
      getter method : String
      getter host : String
      getter port : Int32
      getter target : String
      getter status : Int32?
      getter size : Int64 # total bytes (request + response) — used by the clipboard copy
      getter state : FlowState
      getter response_size : Int64? # response bytes alone (nil until the response lands)
      getter duration_us : Int64?   # request→response latency in µs (nil until complete)
      getter content_type : String? # response Content-Type header (nil until the response lands)
      # gori answered this flow itself — a short-circuit rule matched and no origin was
      # dialed (#511). In the LIST projection, not just the detail, because the whole point
      # is that a fabricated response must not look like an ordinary row while scrolling.
      getter? short_circuited : Bool
      # What gori has to say about this flow that neither its bytes nor its `error` can.
      #
      # A WebSocket flow has had this since #518: `WS::Relay` writes `[gori] …` rows into
      # `ws_messages`, so "the handshake's `Sec-WebSocket-Extensions` was stripped" or "the
      # §5.4 interleave was given up" travels with the flow into History, `gori run show`,
      # MCP `get_flow` and an export. An HTTP flow had nowhere to put the same kind of
      # statement, so two facts gori KNOWS ended up as a `gori.log`/STDERR line correlated
      # with nothing (a Match&Replace rule that structurally could not run on this message)
      # or as a header synthesized into the stored request head (a server PUSH_PROMISE).
      #
      # A COLUMN and not a rows table, unlike the WebSocket case, because the two differ in
      # what the record is about: a `ws_messages` advisory is positioned IN a stream of
      # messages and its position names the frames it applies to, while an HTTP advisory is
      # a property of the exchange as a whole. A join on every History page for a value that
      # is NULL on all but a handful of rows buys nothing; `error` is the same shape and the
      # surfaces already know how to read a nullable flow-level string.
      #
      # Newline-separated when more than one applies (request- and response-direction
      # advisories can land on one flow). NULL — not "" — when there is nothing to say.
      getter advisory : String?
      # The REQUEST's declared Content-Type. NULL means "not recorded" — a row captured before
      # the column existed — NOT "the request declared none"; `Proto.classify` treats it as
      # unknown and falls back to what it always read. See the V14 migration.
      getter request_content_type : String?

      def initialize(@id, @created_at, @scheme, @method, @host, @port, @target,
                     @status, @size, @state, @response_size = nil, @duration_us = nil,
                     @content_type = nil, @short_circuited = false, @advisory = nil,
                     @request_content_type = nil)
      end

      # The advisory as a list of statements, empty when there is none.
      def advisories : Array(String)
        @advisory.try { |a| a.split('\n').reject(&.empty?) } || [] of String
      end

      # True when `target` already carries its own scheme+authority — an ABSOLUTE-FORM
      # request line, the wire shape a plain-HTTP forward-proxy request arrives in (curl -x,
      # a browser proxying a non-TLS site, a hand-written `raw` template, …). Case-insensitive
      # (RFC 3986 §3.1: URI schemes are case-insensitive), so `HTTP://host/x` is caught too —
      # a naive case-sensitive check would let it double into `http://hostHTTP://host/x`.
      # Shared by #url below and Scope.request_url (scope.cr) so this check only lives once.
      #
      # Byte-level, NOT a Regex: `target` is the request line an operator or a peer put on
      # the wire, so it is not guaranteed to be valid UTF-8 — and PCRE2 RAISES
      # (`ArgumentError: UTF-8 error`) rather than simply not matching. On the fuzz path that
      # raise reached `Outbound.scope_url` inside a worker fiber and killed the whole sweep,
      # unhandled, the first time a payload carried a high byte. A URI scheme is ASCII by
      # definition, so nothing about the check needed a Regex.
      # The rule itself moved to core `Gori::Url` (three other surfaces spell it out and one
      # of them, `Interceptor::Item`, cannot require the store); this stays as the name its
      # existing callers — `Scope.request_url`, `Outbound`, `CLI::Output` — already use.
      def self.absolute_form?(target : String) : Bool
        Gori::Url.absolute_form?(target)
      end

      HTTP_PREFIX  = Gori::Url::HTTP_PREFIX
      HTTPS_PREFIX = Gori::Url::HTTPS_PREFIX

      # The full absolute URL of the request. Plaintext forward-proxy requests are captured
      # ABSOLUTE-form (`http://host:port/path` — the wire truth, P7), so `target` already
      # carries the scheme+authority; return it verbatim. Origin-form targets (the HTTPS /
      # CONNECT case — a bare "/path") get scheme+host[:port] prefixed, keeping a non-default
      # port and bracketing an IPv6 literal (mirrors FlowRequest.build_target). Prevents the
      # doubled "http://hosthttp://host/path" a naive "#{scheme}://#{host}#{target}" produced.
      def url : String
        FlowRow.url_of(scheme, host, port, target)
      end

      # `#url` from the four addressing columns alone, for a caller that has them without a
      # row to hand. `Store#flow_id_for_url` is the reason: it resolves a URL STRING back to
      # the flow it came from and has to compare against exactly what `#url` produces, so the
      # rule stays in one place rather than being spelled a second time in SQL — where the
      # default-port and IPv6-bracket cases are precisely what a re-derivation gets wrong.
      def self.url_of(scheme : String, host : String, port : Int32, target : String) : String
        return target if absolute_form?(target)
        h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        default = scheme == "https" ? 443 : 80
        port == default ? "#{scheme}://#{h}#{target}" : "#{scheme}://#{h}:#{port}#{target}"
      end
    end

    # Full detail incl. truth bytes — loaded lazily when a row is selected.
    struct FlowDetail
      getter row : FlowRow
      getter http_version : String
      getter request_head : Bytes
      getter request_body : Bytes?
      getter response_head : Bytes?
      getter response_body : Bytes?
      getter? request_body_truncated : Bool
      getter? response_body_truncated : Bool
      getter h2_conn_id : Int64?
      getter h2_stream_id : Int64?
      getter error : String? # upstream/parse/tls failure message for Error/Aborted flows (response side is empty)
      getter sni : String?

      def initialize(@row, @http_version, @request_head, @request_body,
                     @response_head, @response_body, @h2_conn_id = nil, @h2_stream_id = nil,
                     @request_body_truncated = false, @response_body_truncated = false, @error = nil, @sni = nil)
      end

      # The TRUE wire request body size (recovered by subtracting head size from request total).
      def request_wire_body_size : Int64
        stored = request_body.try(&.size.to_i64) || 0_i64
        req_total = row.size - (row.response_size || 0_i64)
        n = req_total - request_head.size
        n > stored ? n : stored
      end

      # The TRUE wire response body size (recovered by subtracting head size from response total).
      def response_wire_body_size : Int64
        stored = response_body.try(&.size.to_i64) || 0_i64
        return stored unless resp_total = row.response_size
        head_size = (response_head.try(&.size) || 0).to_i64
        n = resp_total - head_size
        n > stored ? n : stored
      end
    end

    # The frame-shape columns V7 added, shared with the proxy that fills them in. Aliased
    # rather than redeclared: capture, persistence and the send path have to mean the same
    # thing by "fin", or the round trip this whole feature is about silently stops being one.
    alias WsShape = Gori::Proxy::WS::Shape

    # A captured WebSocket message belonging to a (101) flow. `direction` is
    # "out" (client→server) or "in" (server→client); opcode 1=text, 2=binary, and since V7
    # also 8=close, 9=ping, 10=pong — control frames the relay used to forward without ever
    # telling anyone, which is how the close code and reason existed nowhere on the proxy
    # path while the repeater engine reported them.
    struct WsMessage
      getter id : Int64
      getter flow_id : Int64
      getter repeater_id : Int64?
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes
      getter shape : WsShape

      def initialize(@id, @flow_id, @repeater_id, @created_at, @direction, @opcode, @payload,
                     @shape : WsShape = WsShape::DEFAULT)
      end

      def text? : Bool
        @opcode == 1
      end

      # RFC 6455 §5.5: opcodes 8..15 are control frames. Until V7 the relay never captured
      # one, so no reader had to ask.
      def control? : Bool
        @opcode >= 8
      end

      # A row gori wrote ABOUT this socket rather than a frame a peer sent — the handshake
      # advisory, the §5.4 parking-ceiling advisory, the teardown-loss notice, the ping-flood
      # marker, the oversized-frame marker.
      #
      # **A diagnostic is not traffic.** Every surface that seeds a WebSocket repeater from a
      # captured flow — `run repeater create --flow`, MCP `create_repeater`, the TUI — takes
      # each `direction == "out"` row's opcode and BYTES straight across, deliberately and
      # with no interpretation, because a binary frame and an invalid-UTF-8 text frame both
      # have to round-trip. A notice row taken that way is replayed to the application under
      # test as a message the operator never authored: a masked 242-byte TEXT frame of gori's
      # own prose, or a PING carrying the flood marker. For anything that parses its inbound
      # text — JSON-RPC, STOMP, a game protocol — that is a fabricated malformed message
      # injected into the operator's own test case, and the send count says one more message
      # than the client ever sent. **Every seed reader must reject these rows.**
      #
      # `Relay::NOTICE_DIRECTION` keeps new advisories off the direction a seed reads, so this
      # is the second guard rather than the only one — but it is the one that covers a flow
      # captured by an OLDER build, and the two markers that legitimately keep the frame's own
      # opcode and direction because they stand in for a real frame at its own position.
      #
      # A prefix test and not a column: it is what makes an already-stored row readable, and
      # the prefix has been the convention for these rows since they existed. The cost is a
      # genuine peer message that happens to open with `[gori] ` — a seed reader that drops
      # one should say which row it dropped rather than go quiet.
      def notice? : Bool
        Gori::Proxy::WS.notice?(@payload)
      end

      # A CLOSE frame's status code (§5.5.1: 2 bytes, network order), or nil when the frame
      # is not a CLOSE or carries no code. The single most diagnostic thing a failed
      # WebSocket test produces, and it existed nowhere on the proxy path.
      def close_code : Int32?
        return nil unless @opcode == 8 && @payload.size >= 2
        (@payload[0].to_i << 8) | @payload[1].to_i
      end

      # A CLOSE frame's reason (§5.5.1: UTF-8 after the code). Bytes, not String — the
      # reason is where a server echoes something back, so it is exactly where invalid
      # UTF-8 turns up.
      def close_reason : Bytes?
        return nil unless @opcode == 8 && @payload.size > 2
        @payload[2, @payload.size - 2]
      end

      # This message's frame SHAPE as JSON fields, emitted into an open object. Only what
      # departs from the default is written, so an ordinary message's object is exactly the
      # shape it was before V7 — a script keying off field presence is not broken by a feature
      # it did not ask for. The JSON sibling of `WsOutMessage#shape_label` / `ws_shape_note`.
      #
      # Lives on the MODEL, the way `Probe.group_json` and `Jwt.decode_json` do, because two
      # surfaces render it and neither owns it: `gori run show --format json` and MCP's
      # `emit_ws_messages`. It used to live in `CLI::Output`, which `MCP::Serialize` then called
      # — and since `cli/run/{intercept,history}.cr` already call `MCP::Serialize.*`, that made
      # the two surfaces MUTUALLY dependent, with none of the files declaring the require (it
      # links only because `src/gori.cr` happens to pull in both). DESIGN.md §2.1 documents the
      # CLI→MCP direction and prescribes exactly this move.
      #
      # This removes the `CLI::Output` edge, NOT the whole cycle: `MCP::Serialize` and
      # `mcp/tools/{send,repeater}.cr` still reach into `CLI::Run` for `incomplete_reason`,
      # `ws_seed_rows`, `seed_shape` and `ws_notice_dropped_note` — four more pure functions
      # over `Repeater::Result` / `Store::WsMessage` that belong under `Repeater::` by the same
      # argument. Moving them is the rest of this job.
      def emit_shape_json(j : JSON::Builder) : Nil
        s = shape
        j.field "fin", false unless s.fin
        j.field "rsv", s.rsv if s.rsv != 0
        s.masked.try { |mk| j.field "masked", mk unless mk }
        j.field "frames", s.frames if s.frames > 1
        close_code.try { |c| j.field "close_code", c }
        close_reason.try { |r| j.field "close_reason", String.new(r).scrub }
      end
    end

    # One captured WebSocket message being RESTORED onto a flow — the import counterpart of
    # `WsMessage`, which is what a read hands back.
    #
    # It carries its own `created_at` and that is the whole reason it exists: `insert_ws_message`
    # stamps `now_us` at enqueue, which is right for a frame gori is watching go past and wrong
    # for one it is reading out of a file. A HAR gori wrote records each message's time, so
    # re-stamping them at import collapsed a whole transcript onto the import instant and broke
    # export→import→export as a fixed point (`Export::Har` derives `_webSocketMessages[].time`
    # from this column).
    #
    # No `shape`: HAR's `_webSocketMessages` is Chrome's `{type, time, opcode, data}` and has no
    # field for FIN/RSV/mask, so an imported message takes `WsShape::DEFAULT` rather than a
    # fabricated one. `direction` is the stored "out"/"in", not HAR's send/receive — the
    # translation belongs to the format reader, so every store row means one thing.
    record ImportedWsMessage, created_at : Int64, direction : String, opcode : Int32,
      payload : Bytes

    # One outbound message to persist on a repeater SESSION. Carries the OPCODE and raw
    # BYTES, because `update_repeater_ws_messages` used to take `Array(String)` and write a
    # hardcoded `opcode 1`: a captured BINARY frame could not round-trip a session at all
    # (`gori run repeater create` warned on stderr and dropped it; MCP and the TUI dropped it
    # silently), and every TEXT frame went through `String#scrub`, which rewrote an
    # invalid-UTF-8 payload — `696e76616c6964fffe`, 9 bytes — to U+FFFD, 13 bytes, and then
    # SENT that. RFC 6455 §8.1/§5.6 UTF-8 validation is a standard WebSocket test, so those
    # bytes ARE the payload.
    #
    # A record rather than a bare tuple so the frame-shape fields could be added with
    # defaults without touching a caller — which is what `shape` now is (V7). Nothing here
    # validates the opcode or the shape: a store is not the place to decide which frame
    # shapes an operator may keep, and the illegal ones are the interesting ones.
    record WsOutMessage, opcode : Int32, payload : Bytes, shape : WsShape = WsShape::DEFAULT do
      # The common case: a line the operator typed into an editor or a JSON string.
      def self.text(s : String) : WsOutMessage
        new(1, s.to_slice)
      end

      def text? : Bool
        @opcode == 1
      end

      def control? : Bool
        @opcode >= 8
      end

      # As `Store::WsMessage#notice?`, for the surfaces that hold an already-converted seed —
      # the TUI takes its `Array(WsOutMessage)` from a caller — so the guard is reachable on
      # whichever side of the conversion a reader sits.
      def notice? : Bool
        Gori::Proxy::WS.notice?(@payload)
      end

      # The frame this message asks for, in the notation the CLI's `--message-frame` and the
      # TUI's seed notice use. Only the departures from the default are named, so an ordinary
      # TEXT frame reads as just its opcode.
      #
      # `to_server` names which side sent it. §5.1 fixes masking per direction — a
      # client→server frame MUST be masked, a server→client frame MUST NOT be — so only the
      # violation is worth a word. Labelling every inbound server frame "unmasked", as this
      # did, fires the §5.1 marker on the ordinary case and buries the anomaly it exists for.
      # `CLI::Output.ws_shape_note` already draws the distinction on the capture side.
      def shape_label(to_server : Bool = true) : String
        parts = [OPCODE_NAMES[@opcode]? || "op#{@opcode}"]
        parts << "fin=0" unless shape.fin
        parts << "rsv=#{shape.rsv}" if shape.rsv != 0
        if to_server
          parts << "unmasked" if shape.masked == false
        else
          parts << "masked" if shape.masked == true
        end
        shape.mask_key.try { |k| parts << "mask=#{k.hexstring}" }
        shape.declared_len.try { |l| parts << "len=#{l}" }
        parts.join(' ')
      end

      OPCODE_NAMES = {0 => "CONT", 1 => "TEXT", 2 => "BIN", 8 => "CLOSE", 9 => "PING", 10 => "PONG"}
    end

    # Severity of an issue (stored as the enum value).
    enum Severity
      Info
      Low
      Medium
      High
      Critical

      def label : String
        to_s.downcase
      end
    end

    # Triage state of an issue, independent of severity (stored as the enum
    # value; V12). Open is the default for a freshly captured issue.
    enum Status
      Open
      Confirmed
      FalsePositive
      Resolved

      def label : String
        case self
        in .open?           then "open"
        in .confirmed?      then "confirmed"
        in .false_positive? then "false-positive"
        in .resolved?       then "resolved"
        end
      end
    end

    # Owner of a row in `entity_links`.
    enum LinkOwnerKind
      Issue
      Note

      def label : String
        to_s.downcase
      end

      def self.parse(s : String) : LinkOwnerKind?
        case s
        when "issue" then Issue
        when "note"  then Note
        else              nil
        end
      end
    end

    # Target workbench entity referenced by an `entity_links` row.
    enum LinkRefKind
      Flow
      Repeater
      Fuzz
      Miner

      def label : String
        to_s.downcase
      end

      def self.parse(s : String) : LinkRefKind?
        case s
        when "flow"     then Flow
        when "repeater" then Repeater
        when "fuzz"     then Fuzz
        when "miner"    then Miner
        else                 nil
        end
      end

      # Short tag for the TUI list (e.g. "[hist]").
      def tag : String
        return "hist" if flow?
        return "repeater" if repeater?
        return "fuzz" if fuzz?
        "miner"
      end
    end

    # A link from an Issue or Note to a workbench entity (flow/repeater/fuzz/miner).
    struct EntityLink
      getter id : Int64
      getter owner_kind : LinkOwnerKind
      getter owner_id : Int64
      getter ref_kind : LinkRefKind
      getter ref_id : Int64
      getter created_at : Int64

      def initialize(@id, @owner_kind, @owner_id, @ref_kind, @ref_id, @created_at)
      end
    end

    # A human-confirmed issue (DESIGN.md §6: the final output). Optionally linked
    # to a captured flow. One per project DB.
    struct Issue
      getter id : Int64
      getter created_at : Int64
      getter updated_at : Int64
      getter title : String
      getter severity : Severity
      getter host : String?
      getter flow_id : Int64?
      getter notes : String
      getter status : Status

      def initialize(@id, @created_at, @updated_at, @title, @severity, @host, @flow_id, @notes,
                     @status = Status::Open)
      end
    end

    # A grouped Probe scan issue (V20): one row per distinct (code, host). Machine-found
    # (by the passive/active analyzer), as opposed to the human-confirmed `Issue`. The
    # affected URLs accumulate in `affected` (capped) while `hit_count` counts every
    # observation; `severity` rises to the max seen. Reuses the shared Severity/Status
    # enums; `status` lets a group be triaged (confirmed / false-positive / resolved) or
    # promoted to an Issue. `category` drives the filter lens and the project tech summary.
    struct ProbeIssue
      getter id : Int64
      getter code : String
      getter category : String
      getter host : String
      getter title : String
      getter severity : Severity
      getter status : Status
      getter hit_count : Int64
      getter affected : Array(String) # distinct affected URLs (parsed from JSON, capped)
      getter sample_flow_id : Int64?  # a representative source flow (may be pruned → nil)
      getter evidence : String?       # short snippet/header value/param name — NEVER a secret value
      getter first_seen : Int64       # unix micros
      getter last_seen : Int64
      getter sample_repeater_id : Int64? # representative Repeater tab when the hit came from Repeater

      def initialize(@id, @code, @category, @host, @title, @severity, @status, @hit_count,
                     @affected, @sample_flow_id, @evidence, @first_seen, @last_seen,
                     @sample_repeater_id = nil)
      end
    end

    # Which side of a flow a Match&Replace rule rewrites. Stored as the lowercase
    # member name ("request"/"response").
    enum RuleTarget
      Request
      Response

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : RuleTarget
        parse(s)
      end
    end

    # Which PART of a message a Match&Replace rule rewrites: the HEAD (request/
    # status line + headers), the BODY (the entity — de-chunked, but not
    # decompressed), or `Ws` — a WebSocket MESSAGE carried by an upgraded (101) flow,
    # reassembled to FIN. Stored as the lowercase member name ("head"/"body"/"ws");
    # pre-body rules migrate to `head` (V30 default), so old rows keep their exact meaning.
    #
    # `Ws` is deliberately its OWN member rather than a reuse of `Body` (#500): a WS
    # message is neither a head nor an entity body, and folding it into `Body` would make
    # every existing `reqbody:` rule start rewriting WebSocket frames — a silent behaviour
    # change on live operator config. Direction comes from `RuleTarget` the same way it
    # does for the other parts: Request ⇒ client→server ("out"), Response ⇒ server→client
    # ("in").
    enum RulePart
      Head
      Body
      Ws

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : RulePart
        parse(s)
      end

      # One-letter tag for a rule row (the TUI Rewriter list and `gori run rewriter`).
      # Exhaustive on purpose — a future member must not silently render as an existing
      # one, which is exactly how the two-way `part.body? ? 'B' : 'H'` ternary this
      # replaced would have shown a WS rule as a head rule.
      def badge : Char
        case self
        in Head then 'H'
        in Body then 'B'
        in Ws   then 'W'
        end
      end
    end

    # What a Match&Replace rule DOES. `Replace` is the classic find/replace over the
    # selected PART (head or body). The three header ops act on the HEAD by header NAME
    # (case-insensitive), so a user never has to hand-craft a substring that spans the
    # exact header text: `AddHeader` appends a `Name: value` line, `SetHeader` replaces
    # an existing header's value (or appends when absent), `RemoveHeader` drops every
    # matching header line. Header ops carry the header NAME in `pattern` and the value
    # in `replacement` (empty for `RemoveHeader`). Stored lowercase; default `replace`
    # so every pre-op rule keeps its exact meaning.
    #
    # `ShortCircuit` (#511) is the odd one out and deliberately so: the other four REWRITE a
    # message that already exists, this one ANSWERS the request and `Upstream.dial` is never
    # reached. It carries the request match in `pattern` (literal or regex, like `Replace`)
    # and the canned response in `replacement` — a raw response head, optionally a blank line
    # and an inline body — with `body_file` as the alternative body source. It is always
    # request-side and head-matched; `Rules`/the surfaces force that, the way header ops are
    # forced head-only.
    enum RuleOp
      Replace
      AddHeader
      SetHeader
      RemoveHeader
      ShortCircuit

      def label : String
        case self
        in RuleOp::Replace      then "replace"
        in RuleOp::AddHeader    then "add_header"
        in RuleOp::SetHeader    then "set_header"
        in RuleOp::RemoveHeader then "remove_header"
        in RuleOp::ShortCircuit then "short_circuit"
        end
      end

      def self.from_label(s : String) : RuleOp
        case s
        when "add_header"    then AddHeader
        when "set_header"    then SetHeader
        when "remove_header" then RemoveHeader
        when "short_circuit" then ShortCircuit
        else                      Replace
        end
      end

      # A header-name-keyed op (mutates the HEAD by name, not a substring gsub). Header
      # ops are head-only regardless of a rule's `part`.
      def header? : Bool
        !replace? && !short_circuit?
      end

      # Does this op REWRITE bytes in flight? False only for `ShortCircuit`, which produces
      # a response instead. The rewrite hot path counts and selects on this, so a stub rule
      # never costs a head/body rewrite its mutex + select — and, more importantly, its
      # `replacement` (a whole HTTP response) is never gsub'd into live traffic.
      def rewrite? : Bool
        !short_circuit?
      end
    end

    # How a `Replace` rule matches: a `Literal` substring or a `Regex` (with $1/\1
    # capture-group interpolation in the replacement). Stored lowercase; default
    # `literal` so pre-regex rules keep their exact meaning. Ignored by header ops.
    enum MatchKind
      Literal
      Regex

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : MatchKind
        s == "regex" ? Regex : Literal
      end
    end

    # WHERE a Match & Replace rule lives, which is also WHO it applies to. A `Project` rule is a
    # row in this project's `match_rules` table; a `Global` rule lives in settings.json
    # (`rewriter.rules`) and applies in EVERY project, so a standing policy ("strip CSP on
    # *.corp.internal") outlives the engagement it was written during. The same global-base /
    # project-layer split `Probe.custom_rules` and `Env.effective_vars` already rest on.
    #
    # The scope is part of a rule's IDENTITY, not just a property of it: the two stores number
    # their rules independently (SQLite rowids on one side, a settings counter on the other), so
    # `id` alone does not name a rule. Every mutator on `Rules` takes the PAIR, and every surface
    # that addresses a rule by id (`gori run rewriter`, the MCP rule tools) carries a `scope`
    # alongside it.
    enum RuleScope
      Project
      Global

      def label : String
        to_s.downcase
      end

      # Unknown → Project. Same tolerant shape `MatchKind.from_label` has, and the safe
      # direction: a mistyped scope addresses THIS project rather than every future one.
      def self.from_label(s : String) : RuleScope
        s.downcase == "global" ? Global : Project
      end

      # The one-letter column the Rewriter list and `gori run rewriter` print.
      def badge : String
        global? ? "G" : "P"
      end
    end

    # A Match&Replace rule (the "Rewriter" tab): rewrites a request/response HEAD
    # (request line + headers) or BODY (the entity body) in flight. Human-authored (P4),
    # persisted per project. `op` selects the action (replace / add-set-remove header);
    # for `Replace`, `match_kind` picks literal vs regex and `part` picks head vs body.
    # `replacement` may be empty (delete `pattern` / remove header). `name` is an optional
    # label; `host` is an optional glob that scopes the rule to matching hosts ("" = all).
    # A body rule buffers + re-frames the message in flight (Content-Length synced); a
    # head rule streams the body untouched (P6). See `Rules` / `ClientConn`.
    #
    # `body_file` belongs to `ShortCircuit` alone: a path whose bytes become the stub body,
    # instead of the inline body in `replacement`. Empty = inline (and every other op ignores
    # it entirely).
    #
    # `scope` says which store the rule came out of (see `RuleScope`) and `enabled` is always
    # the EFFECTIVE state in THIS project — for a global rule that is its own default unless
    # this project overrides it, which is what `overridden?` reports. The proxy path reads
    # `enabled?` and nothing else, so a per-project override needs no second gate anywhere
    # below `Rules.merged`.
    struct MatchRule
      getter id : Int64
      getter? enabled : Bool
      getter target : RuleTarget
      getter part : RulePart
      getter pattern : String
      getter replacement : String
      getter op : RuleOp
      getter match_kind : MatchKind
      getter name : String
      getter host : String
      getter body_file : String
      getter scope : RuleScope
      # Whether THIS project overrides the global default of `enabled`. Always false for a
      # project rule — there is no default to disagree with. See `Store#rewriter_overrides`.
      getter? overridden : Bool

      def initialize(@id, @enabled, @target, @part, @pattern, @replacement,
                     @op = RuleOp::Replace, @match_kind = MatchKind::Literal,
                     @name = "", @host = "", @body_file = "",
                     @scope = RuleScope::Project, @overridden = false)
      end

      def global? : Bool
        @scope.global?
      end
    end

    # An extract rule (#501): the READ half of a session binding. It observes a response
    # and writes ONE named value into the in-memory binding table; the WRITE half is an
    # ordinary `MatchRule` whose `replacement` says `$NAME`.
    #
    # The RULE persists here. The VALUE never does — not in this table, not in settings.json,
    # not anywhere on disk. A restored token is stale by construction (minutes to days old on
    # reopen) and would produce exactly the 401s this feature exists to remove; re-extracting
    # costs one request, so there is nothing to save.
    #
    # No `position` column, unlike `match_rules`: ordering is only meaningful among
    # transformations that compose on the same bytes, and an extract rule produces no bytes.
    # Two extract rules can never contend either — `name` is UNIQUE, which is the
    # one-name-one-writer invariant the design rests on, enforced by the storage layer as
    # well as by `Bindings#validate`.
    #
    # `match_filter` is an `InterceptFilter` source string (the same boolean grammar the
    # conditional-intercept bar uses, evaluated against a live in-flight message), NOT a
    # sixth dialect. `host` is the same glob dialect `match_rules.host` uses.
    struct ExtractRule
      getter id : Int64
      getter? enabled : Bool
      # The binding name, WITHOUT the `$` prefix. Always a valid `Env` key.
      getter name : String
      getter match_filter : String
      getter kind : Gori::ExtractKind
      getter selector : String
      getter pos_start : Int32
      getter pos_end : Int32
      getter host : String

      def initialize(@id, @enabled, @name, @match_filter, @kind,
                     @selector = "", @pos_start = 0, @pos_end = 0, @host = "")
      end

      def token_loc : Gori::TokenLoc
        Gori::TokenLoc.new(@kind, @selector, @pos_start, @pos_end)
      end

      # Body-scoped kinds need the response entity; head-scoped ones read parsed headers
      # alone. Slice 1 extracts only from `Repeater::Sender` results, which always carry a
      # full body, so nothing gates on this yet — it is what Slice 2's proxy-side observer
      # will count to decide whether a response has to be buffered at all.
      def body_scoped? : Bool
        !(@kind.cookie? || @kind.header?)
      end
    end

    # The six BUILT-IN colours a Colormarker rule can name — a VOCABULARY, and nothing else.
    #
    # It is not the type of `ColorRule#color` (that is a plain label string, so a user-defined
    # custom colour's name can flow through it too) and it PARSES nothing: `Tui::Theme.mark_color`
    # takes the label directly and is the one resolver. What this enum still supplies is the list
    # of words — the ones the pickers offer and the CLI/MCP validate an argument against, via
    # `Settings::COLORMARKER_COLORS`.
    #
    # NOT an arbitrary set: they are exactly the ones `Tui::Theme.marker_hue` already vets as
    # "maximally separated and present in every palette" (built-in and custom themes, which
    # inherit a base), so a built-in rule reads the same on a dark theme and a light one without
    # storing a single hex value. A CUSTOM colour, by contrast, carries an absolute hex
    # (`Settings::ColormarkerColor`) and does not track the theme — that is the trade an operator
    # makes by defining their own.
    #
    # No grey: a `Theme.muted` block on the canvas reads as chrome, not as a mark.
    enum MarkerColor
      Red
      Orange
      Yellow
      Green
      Blue
      Purple

      def label : String
        to_s.downcase
      end
    end

    # HOW a Colormarker rule paints its row. `Full` tints the whole row's background; `Strip`
    # paints one saturated cell in a narrow column History reserves ahead of TIME.
    #
    # The two defaults are deliberately different and that asymmetry is the point: parsing an
    # unknown label yields `Strip`, while every surface that CREATES a rule offers `Full`. A
    # mis-parsed strip rule paints one cell and cannot hide the cursor band; a mis-parsed full
    # rule repaints an entire row. But an operator typing `colormarker add --color=red` means
    # "make the row red", so the ask, not the fallback, is what creation follows.
    enum MarkerStyle
      Full
      Strip

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : MarkerStyle
        s.downcase == "full" ? Full : Strip
      end

      # The one-letter column the Colormarker list and `gori run colormarker` print.
      # Exhaustive `case` on purpose (like `RulePart#badge`): a third style must not silently
      # render as an existing one.
      def badge : Char
        case self
        in .full?  then 'F'
        in .strip? then 'S'
        end
      end
    end

    # A Colormarker rule: paint the History rows whose flow matches `match_filter` in `color`,
    # using `style`. DISPLAY ONLY — nothing here reaches the proxy. A rule paints a row that
    # has already been captured, so unlike a `MatchRule` an over-broad one costs an operator a
    # misleading list, never a modified message.
    #
    # `match_filter` is a HISTORY QL string — the same grammar, the same field set and the same
    # answers as the filter bar above the list it paints. It is still the grammar `ExtractRule`
    # uses and the conditional-intercept bar speaks (they share `FilterAst`, and `InterceptFilter`
    # is a subset of QL's vocabulary, not a dialect of it).
    #
    # This used to say "NOT QL: QL compiles to SQL against the flows table, and there is no query
    # to run when the row is already in hand on the render path". That is still true of every
    # field a `FlowRow` can answer, and `Colormarker` still answers those in memory with no query
    # at all. It was wrong about the rest: for `body:`/`header:`/`size:`/`dur:` there IS a query
    # to run, it is bounded by the screenful of ids being painted, and the price of not running
    # it was `body:` parsing fine and painting nothing. See `Colormarker`'s class header for the
    # tier split.
    #
    # No `host` field, unlike `MatchRule` and `ExtractRule`: `host:` inside the filter is the
    # same statement, and a second host axis would make "which one wins" a question with no
    # good answer. The cost is that the filter's `host:` is a plain lowercase SUBSTRING rather
    # than the DNS-label-boundary glob `Rules.host_matches?` implements — so `host:alpha.test`
    # also paints `xalpha.test`. Every surface that accepts a condition says so in those words.
    #
    # Colour rules RESOLVE where rewrite rules COMPOSE: the first enabled match wins and the
    # rest are never consulted. Order is therefore the operator's precedence statement ("red
    # 5xx above yellow 4xx"), which is why every surface that can create a rule can reorder one.
    #
    # `scope` says which store the rule came out of (see `RuleScope`) and `enabled` is always
    # the EFFECTIVE state in THIS project, exactly as on `MatchRule`.
    struct ColorRule
      getter id : Int64
      getter? enabled : Bool
      getter name : String
      getter match_filter : String
      # The colour LABEL, not the `MarkerColor` enum: it is one of the six built-in words
      # (which resolve through the active theme, `Tui::Theme.mark_color`) OR the name of a
      # user-defined custom colour (which carries an absolute hex in `Settings::ColormarkerColor`).
      # Stored as a string on both sides of the scope boundary already — settings.json `color`
      # and the `color_rules.color` TEXT column — so the in-memory type now matches the wire type,
      # and a name the built-in enum could not hold (a custom's) survives a round trip.
      getter color : String
      getter style : MarkerStyle
      getter scope : RuleScope
      # Whether THIS project overrides the global default of `enabled`. Always false for a
      # project rule. See `Store#colormarker_overrides`.
      getter? overridden : Bool

      def initialize(@id, @enabled, @match_filter, @color = "yellow",
                     @style = MarkerStyle::Full, @name = "",
                     @scope = RuleScope::Project, @overridden = false)
      end

      def global? : Bool
        @scope.global?
      end
    end

    # A per-project user-defined Probe match rule (probe_custom_rules, V38). String/regex match
    # over one region of a captured flow (side × region); `severity` stamps the emitted finding.
    # The global-scope counterpart lives in settings.json (Settings::ScanRule); both fold into the
    # runtime Probe::CustomRule via Probe.custom_rules.
    struct ProbeCustomRule
      getter id : Int64
      getter title : String
      getter description : String
      getter side : String   # "request" | "response"
      getter region : String # "whole" | "header" | "body"
      getter kind : String   # "string" | "regex"
      getter pattern : String
      getter severity : Severity
      getter? enabled : Bool

      def initialize(@id, @title, @description, @side, @region, @kind, @pattern, @severity, @enabled)
      end
    end

    # A persisted Repeater workbench tab: the editable request plus the LAST send
    # response (V11 — head/body/error/duration; all nil until the first send).
    # Shared across sessions on the same project — the TUI reconciles local tabs
    # against these rows by `id` on the data_version poll.
    struct RepeaterRecord
      getter id : Int64
      getter target : String
      getter request : Bytes
      getter? http2 : Bool
      getter? auto_content_length : Bool
      getter flow_id : Int64?
      getter position : Int32
      getter response_head : Bytes?
      getter response_body : Bytes?
      getter response_error : String?
      getter response_duration_us : Int64?
      getter name : String? # custom sub-tab label (nil = derive from the request)
      getter sni : String?  # custom TLS SNI host (nil = present the target host)
      getter tags : String? # V31: space-joined flat tags (nil = untagged)
      # Send the operator's own `Sec-WebSocket-Key` instead of a fresh one (Schema V7).
      # Off by default — regeneration stays what every existing session does. See
      # `WsEngine.build_handshake` for why this is opt-in and not simply fixed.
      getter? ws_keep_key : Bool
      # The operator overrode WebSocket auto-detection: send this handshake as a plain HTTP
      # request and read the response as a response (Schema V11). Off by default — auto-detect
      # stays what every existing session does. The request bytes are untouched either way, and
      # the tab's `ws_messages` rows survive the override, so it is reversible without loss.
      getter? ws_http_only : Bool

      def initialize(@id, @target, @request, @http2, @auto_content_length, @flow_id, @position,
                     @response_head = nil, @response_body = nil, @response_error = nil,
                     @response_duration_us = nil, @name = nil, @sni = nil,
                     @tags = nil, @ws_keep_key = false, @ws_http_only = false)
      end
    end

    # A persisted Fuzzer/Intruder session: the marked template (with §…§ positions)
    # plus an opaque `config` JSON the TUI owns (mode / payload sets / matchers /
    # engine opts). Mirrors RepeaterRecord — survives reopen and syncs across sessions.
    struct FuzzSessionRecord
      getter id : Int64
      getter target : String
      getter template : String
      getter? http2 : Bool
      getter sni : String?
      getter config : String # opaque JSON managed by the frontend
      getter flow_id : Int64?
      getter position : Int32
      getter name : String? # custom sub-tab label (nil = derive from the request line)

      def initialize(@id, @target, @template, @http2, @sni, @config, @flow_id, @position, @name = nil)
      end
    end

    # One persisted parameter-mining session (a sub-tab under the Miner tab). Stores the
    # byte-exact `request` to re-run, plus opaque `config` JSON (locations, bucket sizes,
    # concurrency) managed by the frontend. Results are NOT persisted (in-memory per
    # session, like Repeater responses before V11).
    struct MinerSessionRecord
      getter id : Int64
      getter target : String
      getter request : Bytes
      getter? http2 : Bool
      getter sni : String?
      getter config : String # opaque JSON managed by the frontend
      getter flow_id : Int64?
      getter position : Int32
      getter name : String? # custom sub-tab label (nil = derive from the request line)

      def initialize(@id, @target, @request, @http2, @sni, @config, @flow_id, @position, @name = nil)
      end
    end

    # A configured OAST provider (the Providers sub-tab). `kind` is the ProviderKind label.
    struct OastProviderRecord
      getter id : Int64
      getter name : String
      getter kind : String
      getter host : String
      getter token : String?
      getter? enabled : Bool
      getter position : Int32

      def initialize(@id, @name, @kind, @host, @token, @enabled, @position)
      end
    end

    # A listening session: the secrets to poll + decrypt. `private_key_pem` is the
    # interactsh RSA private key (nil for other providers).
    struct OastSessionRecord
      getter id : Int64
      # Microseconds, the column the table has always written and nothing ever read back.
      # The resume picker is the first reader: "which listener is this" is answered by WHEN
      # it was started far better than by its correlation id.
      getter created_at : Int64
      getter provider_id : Int64?
      getter kind : String
      getter server_url : String
      getter correlation_id : String
      getter secret : String
      getter private_key_pem : String?
      getter token : String?
      getter last_poll_at : Int64?

      def initialize(@id, @created_at, @provider_id, @kind, @server_url, @correlation_id,
                     @secret, @private_key_pem, @token, @last_poll_at)
      end
    end

    # One received callback (immutable). `provider_uid` is the dedup key.
    struct OastCallbackRecord
      getter id : Int64
      getter session_id : Int64
      getter created_at : Int64
      getter provider_uid : String
      getter protocol : String
      getter method : String?
      getter source_ip : String?
      getter full_id : String
      getter raw_request : Bytes
      getter raw_response : Bytes?

      def initialize(@id, @session_id, @created_at, @provider_uid, @protocol, @method,
                     @source_ip, @full_id, @raw_request, @raw_response)
      end
    end

    # One persisted token-randomness session (a sub-tab under the Sequencer tab). Stores
    # the byte-exact `request` to re-collect, plus opaque `config` JSON (mode, token
    # location, goal, pacing) managed by the frontend. Collected tokens are NEVER
    # persisted (live secrets, in-memory per session).
    struct SequencerSessionRecord
      getter id : Int64
      getter target : String
      getter request : Bytes
      getter? http2 : Bool
      getter sni : String?
      getter config : String # opaque JSON managed by the frontend
      getter flow_id : Int64?
      getter position : Int32
      getter name : String? # custom sub-tab label (nil = derive from the request line)

      def initialize(@id, @target, @request, @http2, @sni, @config, @flow_id, @position, @name = nil)
      end
    end

    # One fuzz sweep's metadata. Live counters are updated as the run streams; `status`
    # is running | done | stopped | error.
    struct FuzzRunRecord
      getter id : Int64
      getter session_id : Int64?
      getter created_at : Int64
      getter finished_at : Int64?
      getter target : String
      getter mode : String
      getter total : Int64?
      getter sent : Int64
      getter matched : Int64
      getter errors : Int64
      getter status : String

      def initialize(@id, @session_id, @created_at, @finished_at, @target, @mode,
                     @total, @sent, @matched, @errors, @status)
      end
    end

    # One persisted fuzz result row. `payloads` is a JSON array; the captured bytes are
    # present only for the matched/kept results (per keep_bodies).
    struct FuzzResultRecord
      getter id : Int64
      getter run_id : Int64
      getter idx : Int64
      getter payloads : String
      getter status : Int32?
      getter length : Int64
      getter words : Int32
      getter lines : Int32
      getter duration_us : Int64
      getter error : String?
      getter? matched : Bool
      getter extracted : String?
      getter request : Bytes?
      getter response_head : Bytes?
      getter response_body : Bytes?

      def initialize(@id, @run_id, @idx, @payloads, @status, @length, @words, @lines,
                     @duration_us, @error, @matched, @extracted,
                     @request = nil, @response_head = nil, @response_body = nil)
      end
    end

    # An intercepted HTTP/2 connection (one per CONNECT→TLS h2 session). Its raw
    # frames are the truth (P7); decoded streams project into `flows` separately.
    struct H2Connection
      getter id : Int64
      getter created_at : Int64
      getter host : String
      getter port : Int32
      getter alpn : String

      def initialize(@id, @created_at, @host, @port, @alpn)
      end
    end

    # One raw HTTP/2 frame as it crossed the wire. `direction` is "out"
    # (client→server) or "in" (server→client); `payload` excludes the 9-octet
    # frame header (kept byte-exact).
    struct H2Frame
      getter id : Int64
      getter conn_id : Int64
      getter created_at : Int64
      getter direction : String
      getter stream_id : Int64
      getter type : Int32
      getter flags : Int32
      getter length : Int32
      getter payload : Bytes

      def initialize(@id, @conn_id, @created_at, @direction, @stream_id, @type, @flags, @length, @payload)
      end
    end

    # Best-effort notification that a flow row changed. Published AFTER commit.
    record FlowEvent, id : Int64, kind : Symbol # :inserted | :updated

    # One row of the #124 append-only event feed (the AI firehose the MCP process tails).
    # `id` is the forward cursor key (monotonic AUTOINCREMENT); `created_at` is unix micros
    # for display. `goto_tab`/`goto_session_id` mirror Jobs::Goto so a promoted event can
    # jump to its result; `flow_id` is an optional cross-ref to a captured flow.
    struct EventRow
      getter id : Int64
      getter created_at : Int64
      getter source : String
      getter kind : String
      getter level : String
      getter message : String
      getter goto_tab : String?
      getter goto_session_id : Int64?
      getter flow_id : Int64?
      getter payload : String?

      def initialize(@id, @created_at, @source, @kind, @level, @message,
                     @goto_tab = nil, @goto_session_id = nil, @flow_id = nil, @payload = nil)
      end
    end

    # One currently-held intercept item, MIRRORED into intercept_held by the capturing
    # process so the MCP process can list/get it (#123). `item_id` is the Interceptor's
    # per-session id; `held_at_ms` is a WALL-CLOCK stamp captured once at hold time (the
    # in-memory Item.held_at is a monotonic Instant, meaningless across processes).
    struct HeldRow
      getter session_token : String
      getter item_id : Int64
      getter kind : String
      getter method : String
      getter host : String
      getter port : Int32
      getter scheme : String
      getter target : String
      getter flow_id : Int64?
      getter raw : Bytes
      getter held_at_ms : Int64
      getter edited : Bool
      # Wall-clock of the last MCP intercept_list/get that returned this item — the agent's
      # "I'm still watching" signal for the auto-forward reaper (0 = never viewed by an agent).
      getter viewed_ms : Int64
      # Mirrors `Interceptor::Item#edit_refusal` / `#head_only?` across the process boundary.
      #
      # Both are known the moment the message is HELD (on HTTP/2 the answer is
      # `HeadCodec.h1_unfaithful_reason`, a pure function of the block's decoded fields), and
      # without them on this row `gori run intercept get`/`list` and MCP `intercept_get`
      # showed an ordinary editable message. An operator — or an agent — then composed an
      # edit, submitted it, and only THEN learned it could never be applied. That is the
      # state a CRLF-injection probe INDUCES: reflect `%0d%0a` into one header value and
      # every later message on that stream is in it.
      getter edit_refusal : String?
      getter? head_only : Bool
      # Mirrors `Interceptor::Item#binary?` (opcode == OP_BIN) across the bridge — the same
      # fact the TUI's editor gates its hex-vs-text choice on. Without it here, MCP
      # `intercept_forward_edit`/CLI `intercept edit` had no way to tell a text WS message from
      # a binary one before choosing whether the `raw` (JSON-string / argv-string) channel can
      # carry it byte-exact at all.
      getter? binary : Bool

      def initialize(@session_token, @item_id, @kind, @method, @host, @port, @scheme,
                     @target, @raw, @held_at_ms, @flow_id = nil, @edited = false, @viewed_ms = 0_i64,
                     @edit_refusal = nil, @head_only = false, @binary = false)
      end

      # This row is a WebSocket message (either direction) — no start line, no headers, no
      # head/body split. The kind-check `intercept_forward_edit`/`cmd_intercept_edit` need
      # before deciding whether an HTTP-head-shaped CRLF-normalize even applies.
      def ws? : Bool
        kind == "wsout" || kind == "wsin"
      end

      # The head-only CAVEAT, and deliberately NOT folded into `edit_refusal`.
      #
      # Treating it as a refusal would mark the message uneditable — and head edits DO apply.
      # Only a body has nowhere to go. Two different statements, so two accessors: a surface
      # that chips "cannot be edited" must key on `edit_refusal` alone. nil when the hold covers
      # head+body — every h1 hold, and since PR #6 the h2 holds whose body `H2::StreamGate`
      # could buffer — where an edit is forwarded with its body.
      def head_only_note : String?
        return nil unless @head_only
        "this HTTP/2 hold covers the HEAD only — an edit that ADDS A BODY will be refused. " \
        "gori buffers a held h2 body only when the message declares a content-length it can " \
        "hold; this one does not, so its DATA frames stream past the intercept gate untouched " \
        "and a head edit is the only one that applies"
      end
    end

    # One row of the intercept_commands queue (MCP -> TUI). Drained forward-cursored and
    # applied by the lock-holding TUI (#123).
    struct CommandRow
      getter id : Int64
      getter session_token : String?
      getter verb : String
      getter item_id : Int64?
      getter bytes : Bytes?
      getter arg : String?

      def initialize(@id, @session_token, @verb, @item_id = nil, @bytes = nil, @arg = nil)
      end
    end
  end
end
