require "json"
require "base64"
require "../store"
require "../issues_export"
require "../repeater/engine"
require "../fuzz"
require "../proxy/codec/content_decode"
require "../proxy/h2/grpc"
require "../protobuf"

module Gori
  module MCP
    # Pure functions that render gori's store/repeater structs into the JSON the MCP
    # tools return. The codebase builds JSON by hand (no JSON::Serializable), so we
    # follow suit with JSON.build. Bodies are decoded for display (de-chunk +
    # gzip/deflate/br/zstd via ContentDecode) and SUMMARISED — text when valid
    # UTF-8 (capped), base64 otherwise (capped). Byte-exact bodies are gori's own
    # repeater/export job; MCP trades fidelity for a token budget the model can read.
    module Serialize
      MAX_TEXT = 64 * 1024 # cap on inlined decoded text
      MAX_B64  = 64 * 1024 # cap on raw bytes base64-encoded for binary bodies

      # Header names whose VALUES carry credentials/session material. Redacted to
      # [REDACTED] in read-tool output (get_flow, get_repeater_context content)
      # unless the caller opts in with include_sensitive:true. One canonical list
      # so Flow and Repeater views share a single policy (send_request reuses
      # `sensitive_header?` too).
      SENSITIVE_HEADERS = {"authorization", "proxy-authorization", "cookie", "set-cookie",
                           "x-api-key", "api-key", "x-auth-token"}

      def self.sensitive_header?(name : String) : Bool
        SENSITIVE_HEADERS.includes?(name.strip.downcase)
      end

      # Every string that ORIGINATED OUTSIDE gori — a captured request target/host, a
      # response header, a regex-extracted fuzz capture, a crawled URL — must pass through
      # here before it reaches JSON::Builder. The stdio JSON-RPC transport carries UTF-8
      # text, but `Codec::Http1.parse_request_head` builds `target`/`method` with a plain
      # `String.new` over raw wire bytes (no scrub), and SQLite round-trips those bytes
      # verbatim — so a request line like `GET /caf\xE9 HTTP/1.1` puts an invalid byte on
      # the wire and a strict client rejects the WHOLE response line, not just that field.
      # `scrub` returns self (zero allocation) for the overwhelmingly common valid case.
      def self.text(s : String) : String
        s.scrub
      end

      def self.text(s : Nil) : Nil
        nil
      end

      # Replace the value of any sensitive header line in a raw HTTP head/request
      # with [REDACTED], leaving names, the request/status line, and the body
      # untouched. Line endings are preserved. Returns `text` verbatim when
      # `include_sensitive` is set or the text has nothing header-shaped.
      def self.redact_head(text : String, include_sensitive : Bool) : String
        return text if include_sensitive || !text.includes?(':')
        headers_done = false
        text.split('\n').map_with_index do |line, i|
          next line if i.zero? || headers_done # request/status line, then body
          if line.chomp.empty?                 # blank line ends the header block
            headers_done = true
            next line
          end
          colon = line.index(':')
          next line unless colon
          name = line[0, colon]
          next line unless sensitive_header?(name)
          "#{name}: [REDACTED]#{"\r" if line.ends_with?('\r')}"
        end.join('\n')
      end

      # nil-tolerant redact_head, for the optional heads of a Pending/errored flow.
      def self.redact_head_opt(text : String?, include_sensitive : Bool) : String?
        text ? redact_head(text, include_sensitive) : nil
      end

      # --- list projection (History) ------------------------------------------
      def self.flow_row(j : JSON::Builder, row : Store::FlowRow) : Nil
        j.object do
          j.field "id", row.id
          j.field "created_at", row.created_at
          j.field "created_at_iso", unix_micros_iso(row.created_at)
          j.field "scheme", text(row.scheme)
          j.field "method", text(row.method)
          j.field "host", text(row.host)
          j.field "port", row.port
          j.field "target", text(row.target)
          j.field "status", row.status
          j.field "state", row.state.to_s.downcase
          j.field "size", row.size
          j.field "response_size", row.response_size
          j.field "duration_us", row.duration_us
          j.field "content_type", text(row.content_type)
          # gori answered this one itself from a short-circuit rule — no origin was involved
          # (#511). Emitted on EVERY row, not only the true ones, because a model reading this
          # feed has no other way to tell a fabricated response from a real one, and an absent
          # field reads as "not applicable" rather than "false".
          j.field "short_circuited", row.short_circuited?
          # What gori has to say about this flow that its bytes cannot — a rule it could not
          # apply, a request the ORIGIN invented in a PUSH_PROMISE (`FlowRow#advisory`). An
          # array, and only when non-empty: a model has no reason to reason about `null` on
          # every ordinary row, and the absent field reads as "nothing to report".
          advisories = row.advisories
          unless advisories.empty?
            j.field("advisory") { j.array { advisories.each { |a| j.string text(a) } } }
          end
        end
      end

      # --- event feed row (#124) — the light projection list_events returns -----
      def self.event_row(j : JSON::Builder, row : Store::EventRow) : Nil
        j.object do
          j.field "id", row.id
          j.field "created_at", row.created_at
          j.field "created_at_iso", unix_micros_iso(row.created_at)
          j.field "source", text(row.source)
          j.field "kind", text(row.kind)
          j.field "level", text(row.level)
          j.field "message", text(row.message)
          j.field "goto_tab", text(row.goto_tab)
          j.field "goto_session_id", row.goto_session_id
          j.field "flow_id", row.flow_id
          j.field "payload", text(row.payload)
        end
      end

      # --- #123 held intercept item projections --------------------------------

      # Offset of the CRLFCRLF head/body separator in a raw HTTP message, or nil.
      def self.head_body_split(raw : Bytes) : Int32?
        i = 0
        while i + 3 < raw.size
          return i if raw[i] == 13 && raw[i + 1] == 10 && raw[i + 2] == 13 && raw[i + 3] == 10
          i += 1
        end
        nil
      end

      # {scrubbed head text, body bytes} for a held raw message; whole message as head
      # (empty body) when there is no separator.
      def self.head_and_body(raw : Bytes) : {String, Bytes}
        if sep = head_body_split(raw)
          {String.new(raw[0, sep]).scrub, raw[(sep + 4)..]}
        else
          {String.new(raw).scrub, Bytes.empty}
        end
      end

      # List projection: metadata + a redacted, truncated head preview (no body). age_seconds
      # is derived from the wall-clock held_at_ms (stable across snapshot republishes).
      def self.intercept_item_row(j : JSON::Builder, row : Store::HeldRow, include_sensitive : Bool, now_ms : Int64) : Nil
        head, body = head_and_body(row.raw)
        preview = redact_head(head, include_sensitive)
        preview = "#{preview[0, 1024]}…" if preview.size > 1024
        j.object do
          j.field "item_id", row.item_id
          j.field "kind", text(row.kind)
          j.field "method", text(row.method)
          j.field "host", text(row.host)
          j.field "port", row.port
          j.field "scheme", text(row.scheme)
          j.field "target", text(row.target)
          j.field "flow_id", row.flow_id if row.flow_id
          j.field "held_at_ms", row.held_at_ms
          j.field "held_at_iso", unix_micros_iso(row.held_at_ms * 1000)
          j.field "age_seconds", ((now_ms - row.held_at_ms) // 1000)
          j.field "edited", row.edited
          emit_edit_warning(j, row)
          j.field "body_size", body.size
          j.field "head_preview", preview
        end
      end

      # Why an EDIT to this held message would be refused, and whether the hold covers the
      # head only — BEFORE the agent composes one. Both are decided when the message is held
      # (`HeadCodec.h1_unfaithful_reason` is a pure function of the h2 block's fields), and
      # without them here `intercept_get` described an ordinary editable message: the agent
      # wrote an edit, called `intercept_forward_edit`, and only then got the refusal. That is
      # the state a CRLF-injection probe INDUCES, so it is the normal case for the test an
      # agent is most likely to be running. Emitted only when there is something to say.
      # `edit_refusal` is the HARD one — gori will apply no edit to this message at all.
      # `head_only` is the caveat: it is true for EVERY h2 hold (the gate holds the head), a
      # head edit applies normally, and only a body has nowhere to go. Reporting the caveat as
      # a refusal would mark every held HTTP/2 message uneditable, so they stay separate
      # fields and an agent can act on each.
      def self.emit_edit_warning(j : JSON::Builder, row : Store::HeldRow) : Nil
        j.field "head_only", true if row.head_only?
        row.head_only_note.try { |n| j.field "head_only_note", text(n) }
        row.edit_refusal.try { |r| j.field "edit_refusal", text(r) }
        # A WebSocket BINARY frame (opcode 2): `raw` (a JSON string) cannot carry it byte-exact
        # — any byte above 0x7F re-encodes to multiple UTF-8 bytes on the way back out — so
        # `intercept_forward_edit` refuses `raw` for this item and `raw_base64` is the only
        # edit channel. Said here, before the agent writes one, same reasoning as `head_only`.
        if row.ws? && row.binary?
          j.field "binary", true
          j.field "binary_note", "this is a WebSocket BINARY message — 'raw' cannot edit it byte-exact (a JSON string re-encodes any byte over 0x7F); use 'raw_base64'"
        end
      end

      # Detail projection: full redacted head + body size. The FULL raw message base64 (for
      # byte-exact edit → intercept_forward_edit) is emitted ONLY when include_sensitive:true —
      # base64 is encoding, not redaction, so returning raw by default would leak Authorization/
      # Cookie header bytes the `head` field carefully redacts. Redacting inside raw is NOT an
      # option (it would corrupt the bytes the agent round-trips), so we gate instead.
      def self.intercept_item_detail(j : JSON::Builder, row : Store::HeldRow, include_sensitive : Bool, now_ms : Int64) : Nil
        head, body = head_and_body(row.raw)
        j.object do
          j.field "item_id", row.item_id
          j.field "kind", text(row.kind)
          j.field "method", text(row.method)
          j.field "host", text(row.host)
          j.field "port", row.port
          j.field "scheme", text(row.scheme)
          j.field "target", text(row.target)
          j.field "flow_id", row.flow_id if row.flow_id
          j.field "held_at_ms", row.held_at_ms
          j.field "age_seconds", ((now_ms - row.held_at_ms) // 1000)
          j.field "edited", row.edited
          emit_edit_warning(j, row)
          j.field "head", redact_head(head, include_sensitive)
          j.field "body_size", body.size
          j.field "raw_size", row.raw.size
          if include_sensitive
            raw_sample = row.raw.size > MAX_B64 ? row.raw[0, MAX_B64] : row.raw
            j.field "raw_base64", Base64.strict_encode(raw_sample)
            j.field "raw_truncated", row.raw.size > MAX_B64
          else
            # raw carries UNREDACTED header bytes — opt in with include_sensitive to fetch it.
            j.field "raw_redacted", true
          end
        end
      end

      # --- fuzz result (metrics only — no raw bodies; full detail stays behind
      # get_flow/send_request, shrinking the injected-content surface) -----------
      def self.fuzz_result(j : JSON::Builder, r : Fuzz::Result, flow_id : Int64? = nil) : Nil
        j.object do
          j.field "index", r.index
          # payloads can come from a caller-supplied wordlist FILE (arbitrary bytes) and
          # `extracted` is a regex capture out of the RESPONSE body — both are outside-origin.
          j.field("payloads") { j.array { r.payloads.each { |p| j.string text(p) } } }
          j.field "position", r.position
          j.field "status", r.status
          j.field "length", r.length
          j.field "words", r.words
          j.field "lines", r.lines
          j.field "duration_us", r.duration_us
          j.field "error", text(r.error)
          # A declared `¦chain` that could not run on this payload — it went out UNTRANSFORMED.
          # Emitted only when set, so an agent never reads a clean row for a request that sent a
          # different test than asked. `error` stays the network/send failure; this is distinct.
          j.field "chain_error", text(r.chain_error) if r.chain_error
          # The gRPC CALL's outcome, from the response's `grpc-status`/`grpc-message` trailers.
          # `status` above is 200 for EVERY gRPC response, so without these an agent fuzzing an
          # authz bypass read `200` on the granted and the denied calls alike — the result set
          # carried no bit that separated them, and the only recovery was record_history:"all"
          # plus a get_flow per row. Emitted only when the response carried them, so a
          # non-gRPC run's rows are unchanged. `text()`: grpc-message is origin-chosen bytes.
          if gs = r.grpc_status
            j.field "grpc_status", gs
            j.field "grpc_status_name", Proxy::H2::Grpc.status_name(gs)
          end
          j.field "grpc_message", text(r.grpc_message) if r.grpc_message
          j.field "extracted", text(r.extracted)
          # This variation's request reached the origin TWICE: the keep-alive pool found its
          # parked socket closed and re-sent (see `Fuzz::Result#retried?`). Emitted only when
          # true — it is an exception, and a `false` on every row would bury the one that is
          # not. This is where an agent reads it; before, a re-send appeared nowhere but the
          # CLI's own connections summary.
          j.field "retried", true if r.retried?
          # Present when record_history recorded this result as a History flow —
          # fetch its full request/response with get_flow (headers redacted).
          j.field "flow_id", flow_id if flow_id
        end
      end

      # --- full detail incl. heads + decoded bodies ---------------------------
      def self.flow_detail_json(detail : Store::FlowDetail,
                                ws_msgs : Array(Store::WsMessage) = [] of Store::WsMessage,
                                include_sensitive : Bool = false,
                                body_cap : Int32 = MAX_TEXT, body_omit : Bool = false) : String
        JSON.build { |j| flow_detail(j, detail, ws_msgs, include_sensitive, body_cap, body_omit) }
      end

      def self.flow_detail(j : JSON::Builder, detail : Store::FlowDetail,
                           ws_msgs : Array(Store::WsMessage) = [] of Store::WsMessage,
                           include_sensitive : Bool = false,
                           body_cap : Int32 = MAX_TEXT, body_omit : Bool = false) : Nil
        row = detail.row
        j.object do
          j.field "id", row.id
          j.field "created_at", row.created_at
          j.field "created_at_iso", unix_micros_iso(row.created_at)
          j.field "scheme", text(row.scheme)
          j.field "method", text(row.method)
          j.field "host", text(row.host)
          j.field "port", row.port
          j.field "target", text(row.target)
          j.field "http_version", text(detail.http_version)
          j.field "status", row.status
          j.field "state", row.state.to_s.downcase
          j.field "duration_us", row.duration_us
          j.field "content_type", text(row.content_type)
          # `flow_row`'s field, on the DETAIL projection too, and for a sharper reason: this
          # is the call an agent makes to read a flow's BYTES before writing an issue, and
          # without it there is no way to tell a response gori fabricated from a
          # short-circuit rule apart from origin traffic. QL's own `stub:` docs say
          # "`stub:false` is what you want before treating History as evidence"; the list
          # projection said so and the detail one dropped it.
          j.field "short_circuited", row.short_circuited?
          # See `flow_row`. On the detail projection this is the one the agent reading BYTES
          # as evidence needs: "Match&Replace was not applied to this head" and "the origin
          # invented this request" are both statements about how much the bytes below can be
          # trusted to be the operator's test case.
          detail_advisories = row.advisories
          unless detail_advisories.empty?
            j.field("advisory") { j.array { detail_advisories.each { |a| j.string text(a) } } }
          end
          j.field "error", text(detail.error)
          j.field "request_head", redact_head_opt(head_text(detail.request_head), include_sensitive)
          emit_head_base64(j, "request_head", detail.request_head, include_sensitive)
          emit_body(j, "request_body", detail.request_head, detail.request_body, detail.request_body_truncated?, body_cap, body_omit)
          j.field "response_head", redact_head_opt(head_text(detail.response_head), include_sensitive)
          emit_head_base64(j, "response_head", detail.response_head, include_sensitive)
          j.field "sensitive_headers_redacted", true unless include_sensitive
          emit_body(j, "response_body", detail.response_head, detail.response_body, detail.response_body_truncated?, body_cap, body_omit)
          emit_sse_events(j, detail)
          emit_ws_messages(j, ws_msgs)
          emit_grpc_messages(j, "request_grpc_messages", detail.request_head, detail.request_body)
          emit_grpc_messages(j, "response_grpc_messages", detail.response_head, detail.response_body)
          emit_decoded(j, detail)
        end
      end

      GRPC_MSGS_MAX  =  200 # cap gRPC messages serialised for an LLM client
      GRPC_BYTES_MAX = 8192 # cap the base64 of one compressed/opaque message

      # The gRPC framing view of a message body, mirroring `gori run show --format json`'s
      # `grpc_messages`. MCP had NO gRPC projection at all: an agent got the raw body and had
      # to reframe the 5-byte length prefixes itself, and a FRAMING FAILURE — a length prefix
      # claiming more than arrived, the standard gRPC parser test — was invisible on the one
      # surface that cannot look at the wire.
      #
      # `Grpc.scan`, not `Grpc.messages`: the residual is the whole point. `messages` throws
      # it away, so a deliberately-wrong prefix rendered as "no messages", which reads
      # identically to "this flow is not gRPC".
      def self.emit_grpc_messages(j : JSON::Builder, field_name : String,
                                  head : Bytes?, body : Bytes?) : Nil
        return if head.nil? || body.nil? || body.empty?
        return unless Proxy::H2::Grpc.grpc?(grpc_content_type(head))
        msgs, residual = Proxy::H2::Grpc.scan(body)
        return if msgs.empty? && residual == 0
        j.field field_name do
          j.object do
            j.field "count", msgs.size
            if residual > 0
              j.field "residual_bytes", residual
              j.field "framing_error",
                "the last #{residual} byte#{residual == 1 ? "" : "s"} are not a complete gRPC frame — " \
                "a length prefix claiming more than arrived, or a body cut short"
            end
            j.field "truncated", true if msgs.size > GRPC_MSGS_MAX
            j.field "messages" do
              j.array do
                msgs.first(GRPC_MSGS_MAX).each_with_index do |m, i|
                  j.object do
                    j.field "index", i
                    j.field "compressed", m.compressed
                    j.field "trailer", m.trailer
                    j.field "size", m.data.size
                    if m.trailer
                      # grpc-web TRAILER frame: ASCII headers, not protobuf — and for gRPC the
                      # trailer IS the call's real status.
                      j.field "headers" do
                        j.object do
                          Proxy::H2::Grpc.trailer_headers(m.data).each { |k, v| j.field k, text(v) }
                        end
                      end
                    elsif m.compressed
                      # Honour the 0x01 flag: compressed bytes are not a protobuf message until
                      # the caller inflates them (the encoding is named by grpc-encoding, not us).
                      j.field "note", "compressed payload — not decoded as protobuf"
                      emit_grpc_bytes(j, m.data)
                    else
                      j.field "protobuf" { Protobuf.decode(m.data).to_json(j) }
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def self.emit_grpc_bytes(j : JSON::Builder, data : Bytes) : Nil
        cut = data.size > GRPC_BYTES_MAX
        j.field "bytes", Base64.strict_encode(cut ? data[0, GRPC_BYTES_MAX] : data)
        j.field "bytes_truncated", true if cut
      end

      # Content-Type value from a message head (case-insensitive name, any spacing after the
      # colon), nil when there is none.
      private def self.grpc_content_type(head : Bytes) : String?
        String.new(head).scrub.each_line do |line|
          idx = line.index(':') || next
          next unless line[0, idx].strip.compare("content-type", case_insensitive: true) == 0
          return line[(idx + 1)..].strip
        end
        nil
      end

      WS_MSGS_MAX    =  500 # cap WS messages serialised for an LLM client
      WS_PAYLOAD_MAX = 4096 # cap each text frame's payload (chars)

      # RFC 6455 opcode → frame type name, so a caller reads text/binary/ping/pong/
      # close directly instead of decoding the numeric opcode.
      def self.ws_frame_type(opcode : Int32) : String
        case opcode
        when 0x0 then "continuation"
        when 0x1 then "text"
        when 0x2 then "binary"
        when 0x8 then "close"
        when 0x9 then "ping"
        when 0xA then "pong"
        else          "opcode-#{opcode}"
        end
      end

      # A WebSocket flow (status 101) carries a separate message log the heads/bodies
      # don't show. Mirror the `gori run show` WS pane, bounded for LLM use: text
      # frames inline their (clipped) payload, binary frames report a size only.
      # `count` is the true total; `messages` is the first WS_MSGS_MAX of them.
      def self.emit_ws_messages(j : JSON::Builder, msgs : Array(Store::WsMessage)) : Nil
        return if msgs.empty?
        j.field "ws_messages" do
          j.object do
            j.field "count", msgs.size
            j.field "truncated", msgs.size > WS_MSGS_MAX
            j.field "messages" do
              j.array do
                msgs.first(WS_MSGS_MAX).each do |m|
                  j.object do
                    j.field "direction", m.direction
                    j.field "opcode", m.opcode
                    j.field "type", ws_frame_type(m.opcode)
                    j.field "at", m.created_at
                    j.field "at_iso", unix_micros_iso(m.created_at)
                    # The V7 shape (FIN / RSV / masked / frame count) and a CLOSE's code and
                    # reason. `gori run show --format json` has emitted these since the shape
                    # existed; MCP did not, so the agent surface was the one place a captured
                    # RSV1 frame, an unmasked client frame, or a close code was invisible —
                    # and a close code is the most diagnostic thing a failed WebSocket test
                    # produces. Shared emitter, so the two projections cannot drift.
                    CLI::Output.emit_ws_shape_json(j, m)
                    if m.text?
                      raw = String.new(m.payload)
                      s = raw.scrub
                      cut = s.size > WS_PAYLOAD_MAX
                      j.field "text", cut ? s[0, WS_PAYLOAD_MAX] : s
                      j.field "text_truncated", true if cut
                      # RFC 6455 §8.1/§5.6 UTF-8 validation is a standard WebSocket test, so a
                      # TEXT frame carrying invalid UTF-8 is the PAYLOAD, not an accident — and
                      # `scrub` renders two different invalid bytes identically. A clip at
                      # WS_PAYLOAD_MAX loses the tail the same way, and `get_response_body_chunk`
                      # covers HTTP bodies, not `ws_messages`. `gori run show --format json` has
                      # emitted this companion all along; the AGENT surface, the one that cannot
                      # look at the wire itself, was the one place the bytes were unrecoverable.
                      if cut || !raw.valid_encoding?
                        j.field "text_lossy", true
                        b64cut = m.payload.size > MAX_B64
                        j.field "base64", Base64.strict_encode(b64cut ? m.payload[0, MAX_B64] : m.payload)
                        j.field "base64_truncated", true if b64cut
                      end
                    else
                      j.field "binary", true
                      j.field "size", m.payload.size
                      cut = m.payload.size > MAX_B64
                      slice = cut ? m.payload[0, MAX_B64] : m.payload
                      j.field "base64", Base64.strict_encode(slice)
                      j.field "base64_truncated", true if cut
                    end
                  end
                end
              end
            end
          end
        end
      end

      DECODE_TEXT_MAX = 16384 # cap each decoded text field serialised for an LLM client

      # Decoded-protocol projections (SAML / JWT / GraphQL / form params), bounded for
      # LLM use. Shares one emitter with `gori run show --format json` (DecodedView) so
      # the two surfaces never diverge; here every side is scanned and clipped.
      def self.emit_decoded(j : JSON::Builder, detail : Store::FlowDetail) : Nil
        DecodedView.emit_json(j, target: detail.row.target,
          req_head: detail.request_head, req_body: detail.request_body,
          resp_head: detail.response_head, resp_body: detail.response_body,
          clip: DECODE_TEXT_MAX)
      end

      SSE_EVENTS_MAX =  500 # cap events serialised for an LLM client
      SSE_DATA_MAX   = 4096 # cap each event's data (chars)

      # When the response is a text/event-stream, emit a parsed `sse_events` array
      # (a derived view over the decoded body — no table). Bounded for LLM use.
      def self.emit_sse_events(j : JSON::Builder, detail : Store::FlowDetail) : Nil
        events = Sse.from_response(detail.response_head, detail.response_body)
        return if events.empty?
        j.field "sse_events" do
          j.object do
            j.field "count", events.size
            j.field "truncated", events.size > SSE_EVENTS_MAX
            j.field "events" do
              j.array do
                events.first(SSE_EVENTS_MAX).each do |e|
                  j.object do
                    j.field "type", text(e.type)
                    j.field "id", text(e.id)
                    j.field "retry", e.retry
                    data = e.data.scrub
                    cut = data.size > SSE_DATA_MAX
                    j.field "data", cut ? data[0, SSE_DATA_MAX] : data
                    j.field "data_truncated", true if cut # signal the clip so the value isn't read as whole
                  end
                end
              end
            end
          end
        end
      end

      # --- issues -----------------------------------------------------------
      def self.issue(j : JSON::Builder, f : Store::Issue, store : Store? = nil) : Nil
        j.object do
          j.field "id", f.id
          j.field "created_at", f.created_at
          j.field "created_at_iso", unix_micros_iso(f.created_at)
          j.field "updated_at", f.updated_at
          j.field "updated_at_iso", unix_micros_iso(f.updated_at)
          # title/host/notes: same captured-data-can-be-invalid-UTF-8 gap `Issues::Export.json`
          # has (this IS that same JSON shape, just wrapped in a JSON-RPC tool response) — an
          # unscrubbed raw byte here breaks the whole response line's UTF-8 validity, a real
          # protocol violation an MCP client could choke on, not merely a display glitch.
          j.field "title", Issues::Export.one_line(f.title)
          j.field "severity", f.severity.label
          j.field "status", f.status.label
          j.field "host", f.host.try { |h| Issues::Export.one_line(h) }
          j.field "flow_id", f.flow_id
          # notes is multi-line by design — scrub only, don't collapse (mirrors Export.json).
          j.field "notes", Issues::Export.scrub_only(f.notes)
          j.field "links" do
            j.array { Issues::Export.append_links_json(j, f, store) if store }
          end
        end
      end

      # Heads are short and ASCII-ish; render as (lossy-on-display) text. nil head
      # (e.g. a Pending flow's response) becomes JSON null. `scrub` guards a
      # malformed/binary head from emitting invalid UTF-8 that would corrupt the
      # JSON-RPC line.
      def self.head_text(head : Bytes?) : String?
        head ? String.new(head).scrub : nil
      end

      # The head's exact octets, when `head_text` above had to scrub them away. Without this
      # an 8-bit byte in a captured header was unrecoverable through MCP: the body has a
      # base64 fallback and the head had none, so `X-Bin: \x80\xff` read as `X-Bin: ��` with
      # no way back and no signal that anything was lost.
      #
      # Gated on `include_sensitive` for `intercept_item_detail`'s reason: base64 is encoding,
      # not redaction, so emitting the raw head by default would hand back exactly the
      # Authorization/Cookie bytes the `*_head` field carefully redacts. Redacting INSIDE the
      # base64 is not an option — it would no longer be the bytes.
      def self.emit_head_base64(j : JSON::Builder, field_name : String, head : Bytes?,
                                include_sensitive : Bool) : Nil
        return if head.nil?
        return if String.new(head).valid_encoding?
        j.field "#{field_name}_lossy", true
        return unless include_sensitive
        j.field "#{field_name}_base64", Base64.strict_encode(head)
      end

      # RFC3339 UTC for store timestamps (unix microseconds). Helps LLM clients
      # that can't interpret raw microsecond integers.
      def self.unix_micros_iso(us : Int64) : String
        sec, micro = us.divmod(1_000_000)
        t = Time.utc(1970, 1, 1) + sec.seconds + micro.microseconds
        t.to_s("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      # Emits a `field_name` field carrying a decoded-body summary. nil/empty body
      # → JSON null. Otherwise an object: {encoding, size, truncated, wire_truncated?,
      # text|base64, note?}. `truncated` is true when the returned text/base64 was cut
      # (display cap OR capture cap); `wire_truncated` is emitted only when the stored
      # bytes themselves were cut at gori's capture cap (so the data is gone at source).
      # `cap` bounds the inlined text/base64 (default MAX_TEXT); `omit` returns
      # metadata only (encoding/size, omitted:true) with NO body bytes — for a
      # caller that wants just the shape and will page bytes via
      # get_response_body_chunk. Both default to today's behavior.
      def self.emit_body(j : JSON::Builder, field_name : String, head : Bytes?, body : Bytes?,
                         wire_truncated : Bool, cap : Int32 = MAX_TEXT, omit : Bool = false) : Nil
        if body.nil? || body.empty?
          j.field field_name, nil
          return
        end
        decoded, note = Proxy::Codec::ContentDecode.decode(head, body)
        bytes = decoded || body
        s = String.new(bytes)
        valid = s.valid_encoding?
        j.field field_name do
          j.object do
            j.field "encoding", valid ? "text" : "base64"
            j.field "binary", true unless valid
            j.field "size", bytes.size
            if omit
              # body_mode:none — the caller asked for shape only.
              j.field "omitted", true
              j.field "truncated", wire_truncated
            else
              emit_body_payload(j, s, bytes, valid, cap, wire_truncated)
            end
            # `truncated` (above) is true for either cause (back-compat); `wire_truncated`
            # disambiguates a capture-time cut (data gone at source, not just the display
            # cap) so the caller knows whether more is recoverable. Branch-independent.
            j.field "wire_truncated", true if wire_truncated
            j.field "note", note if note
            emit_trailers(j, head, body)
          end
        end
      end

      # The chunked message's TRAILER fields, beside the de-chunked body rather than folded
      # into `headers`. `note:"de-chunked"` used to be the only trace that a trailer section
      # could even exist: the head stops before the body and the de-chunk stops at the
      # 0-chunk, so `X-T: gotcha` after it appeared nowhere while the origin's `Trailer:`
      # announcement was echoed — which reads as "the origin sent none". Whether a target
      # treats a trailer as a header is itself a test, so they stay a separate list.
      def self.emit_trailers(j : JSON::Builder, head : Bytes?, body : Bytes?) : Nil
        trailers = Proxy::Codec::ContentDecode.trailers(head, body)
        return if trailers.empty?
        j.field "trailers" do
          j.array do
            trailers.each do |(name, value)|
              j.object do
                j.field "name", text(name)
                # A trailer value is remote bytes like any response header — same lossy
                # contract, same base64 escape hatch (see `emit_lossy_text`).
                emit_lossy_text(j, "value", value)
              end
            end
          end
        end
      end

      # A string that came off the wire, emitted so the caller can always recover the exact
      # octets. `text` (i.e. `scrub`) is mandatory for JSON-RPC UTF-8 validity, but it is
      # LOSSY and silently so: two different invalid bytes both render `�`, and the response
      # BODY had a base64 fallback while a header VALUE did not — leaving those bytes
      # unrecoverable through MCP entirely. Emit the raw bytes beside the scrubbed text
      # whenever scrubbing actually changed something, and say that it did.
      def self.emit_lossy_text(j : JSON::Builder, field_name : String, s : String) : Nil
        j.field field_name, text(s)
        return if s.valid_encoding?
        j.field "#{field_name}_base64", Base64.strict_encode(s.to_slice)
        j.field "#{field_name}_lossy", true
      end

      # Emit the (possibly capped) body bytes as text or base64. byte_slice can
      # sever a multi-byte codepoint at the cap → scrub the partial tail so the
      # JSON line stays valid UTF-8.
      private def self.emit_body_payload(j : JSON::Builder, s : String, bytes : Bytes,
                                         valid : Bool, cap : Int32, wire_truncated : Bool) : Nil
        cut = bytes.size > cap
        j.field "truncated", cut || wire_truncated
        if valid
          j.field "text", cut ? s.byte_slice(0, cap).scrub : s
        else
          j.field "base64", Base64.strict_encode(cut ? bytes[0, cap] : bytes)
        end
      end
    end
  end
end
