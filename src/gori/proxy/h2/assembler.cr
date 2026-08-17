require "./frame"
require "./hpack"
require "./head_codec"
require "./ws_capture"
require "../codec/body"
require "../upstream"
require "../sink"
require "../../flow_mapper"
require "../../store/models"

module Gori::Proxy::H2
  # Turns the raw frame stream of one h2 connection into the decoded projection:
  # it assembles HEADERS(+CONTINUATION) and DATA per stream, decodes headers via
  # HPACK, and emits a `flows` row per request/response exchange (so h2 traffic
  # lands in History/QL/Repeater next to h1). The raw frame log remains the truth
  # (P7); this is the derived, human-readable view.
  #
  # One Assembler per connection. Its two HPACK decoders are direction-scoped
  # (each endpoint keeps its own table). Both relay pump fibers call `feed`, so a
  # Mutex serializes the shared stream map — the latency-critical raw forwarding
  # already happened before we are called, so this never delays a peer.
  #
  # v1 scope: a flow is emitted when the REQUEST half-closes (END_STREAM). Long
  # client-streaming / bidi requests therefore surface only once the client ends
  # its half — acceptable for now (the raw frames are always captured live).
  class Assembler
    # A header block the CALLER already decoded. The rewrite path (`HeadRewrite`, #492
    # step 2) has to decode before it can forward, and the decoder that tracks the
    # SENDER's encoder is the one in here — a second decoder on the same direction is a
    # second dynamic table and is wrong the first time the peer uses an index. So it
    # decodes through `decode_head_block` and hands the RESULT back here.
    #
    # Passing this is MANDATORY for such a caller: a stateful HPACK decoder run twice over
    # one block is desynced from the sender for the rest of the connection. `fields` nil
    # means that decode FAILED, so the projection is dropped exactly as `feed`'s own rescue
    # does — and, again, without decoding the block a second time.
    record HeadBlock, fields : Array({String, String})?

    # Cap on one stream's accumulated HEADERS(+CONTINUATION) block, so a peer that
    # never sends END_HEADERS can't grow header_buf without bound.
    MAX_HEADER_BLOCK = 1 << 20 # 1 MiB

    # Ceiling on concurrently-tracked streams per connection. Streams are dropped on
    # RST or completion, but a never-END_STREAM (SSE/long-poll/bidi or a hostile
    # flood of fresh stream ids) would otherwise grow @streams unboundedly, each
    # holding up to two capped bodies. At the cap we refuse to track NEW streams
    # (the raw frame log stays the truth, P7) rather than evict in-flight ones.
    MAX_LIVE_STREAMS = 1024

    private class Side
      getter header_buf = IO::Memory.new
      # DATA frames accumulate here, capped (like h1) so a huge streamed body
      # can't grow per-connection memory without bound. Raw frames stay the truth.
      getter body = Codec::CaptureBuffer.new(Settings.capture_max)
      property headers : Array({String, String})? = nil
      # Cumulative decoded-header bytesize across all merged blocks on this side, so a
      # flood of repeated non-status HEADERS blocks (fake trailers, never END_STREAM)
      # can't grow `headers` without bound. Per-block caps (MAX_HEADER_BLOCK, HPACK
      # MAX_HEADER_LIST) only bound ONE block; this bounds the accumulation.
      property header_bytes = 0
      property ended = false
      # True between a HEADERS without END_HEADERS and the CONTINUATION that ends the block.
      # A CONTINUATION is only legal while this holds (RFC 9113 §6.10); one arriving otherwise
      # is a protocol violation a hostile peer uses to fabricate or erase a flow, so it is
      # dropped (#409).
      property awaiting_continuation = false
      # Names of the fields that arrived in a TRAILING HEADERS block. `finish_header_block`
      # merges trailers into `headers` (that merge is what makes grpc-status reachable), and
      # after it nothing distinguished a trailer from a real response header. Recorded here
      # so the stored head can say which is which — see HeadCodec::TRAILER_MARKER.
      getter trailer_names = [] of String
      # Membership index for `trailer_names`, which stays an ordered Array because
      # `HeadCodec::TRAILER_MARKER` joins the names in arrival order. Deduping with
      # `Array#includes?` is a linear scan, so one legal 1 MiB trailer block (~174k
      # distinct names still under the cumulative MAX_HEADER_LIST cap at
      # `finish_header_block`) cost O(N^2) String compares — ~40s of uninterruptible
      # CPU inside `@mutex`, which on Crystal's single-threaded scheduler freezes the
      # TUI, every other connection and the Store writer fiber (P6).
      getter trailer_seen = Set(String).new
    end

    private class Stream
      getter req = Side.new
      getter resp = Side.new
      property flow_id : Int64? = nil
      # Monotonic timing for the response's ttfb/duration. h1 records these in
      # client_conn; without them every h2 flow shows a null latency in History /
      # QL / `gori run` JSON (and most HTTPS traffic negotiates h2). `started_at`
      # is stamped when the stream is first seen; `resp_first_at` on the first
      # response HEADERS/DATA frame (time-to-first-byte).
      getter started_at : Time::Instant = Time.instant
      # Wall-clock capture time for THIS stream. A persistent h2 connection carries many
      # requests over its lifetime (the common case: gori advertises h2 to the client
      # whenever the origin offers it), so this must be stamped per-stream, not inherited
      # from the connection's own open time — the same mistake `started_at` above avoids.
      getter created_at : Int64 = (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
      property resp_first_at : Time::Instant? = nil
      # The stream whose PUSH_PROMISE invented this request, when the client never sent it.
      # A pushed flow was indistinguishable in History / QL / the Sitemap from one the client
      # made — the origin authoring rows in an operator's evidence — so the projection says so
      # (`HeadCodec::PUSHED_MARKER`, plus the `advisory` below, which is the half a reader who
      # is NOT looking at the head text can see).
      property pushed_by : UInt32? = nil
      # What gori has to say about this exchange that its bytes cannot — see
      # `Store::FlowRow#advisory`. Accumulated here rather than passed straight through
      # because the producers run at different moments (a request-direction advisory before
      # `emit_request`, a response-direction one before `emit_response`) and the stream is
      # the only thing that spans both.
      getter advisories = [] of String
      # The WebSocket transcript of an RFC 8441 extended CONNECT stream (#733), or nil for
      # every other stream — which is all of them on an ordinary connection.
      property ws : WsCapture? = nil
      # Whether this stream's frames WILL be read, decided the moment the request head is
      # recognised and before `emit_request` stores the advisory that says so. `ws` itself
      # cannot answer it there: it needs the flow id that `emit_request` is what produces.
      property ws_armed = false
    end

    # `connection_created_at` is kept as a positional argument for call-site compatibility
    # (the connection's own open time) but is deliberately NOT stored or used for a flow's
    # `created_at` — see `Stream#created_at`, which each request stamps for itself.
    def initialize(@sink : FlowSink, @host : String, @port : Int32, connection_created_at : Int64,
                   @conn_id : Int64 = 0_i64)
      @mutex = Mutex.new
      @streams = {} of UInt32 => Stream
      @req_decoder = HPACK::Decoder.new
      @resp_decoder = HPACK::Decoder.new
      # Extended CONNECT streams currently being read, against `WsCapture::MAX_STREAMS`.
      @ws_captures = 0
    end

    # Decode one COMPLETE header block with this connection's per-direction decoder,
    # advancing it exactly once. Only the rewrite path calls this — see `HeadBlock` for
    # why it must, and for the obligation it takes on by doing so. nil on malformed or
    # hostile HPACK, matching `feed`'s rescue.
    def decode_head_block(direction : String, block : Bytes) : Array(HPACK::Field)?
      @mutex.synchronize do
        (direction == "out" ? @req_decoder : @resp_decoder).decode_fields(block)
      end
    rescue Gori::Error | IndexError | OverflowError
      nil
    end

    # What the intercept gate needs to hold a RESPONSE: h1 scopes a response hold on the
    # REQUEST's method/target (`client_conn.cr:501`), and an h2 response head carries neither.
    # nil when this connection is not tracking the stream (past MAX_LIVE_STREAMS) — the gate
    # then declines to hold rather than inventing a URL to scope-test.
    record RequestRef, method : String, target : String, scheme : String, authority : String

    def request_ref(stream_id : UInt32) : RequestRef?
      @mutex.synchronize do
        headers = @streams[stream_id]?.try(&.req.headers)
        next nil unless headers
        RequestRef.new(pseudo(headers, ":method") || "GET", pseudo(headers, ":path") || "/",
          pseudo(headers, ":scheme") || "https", pseudo(headers, ":authority") || @host)
      end
    end

    # The flow row already projected for `stream_id`, if any. Nil is normal, not exceptional: a
    # request flow is emitted when the request half-closes, so an origin answering a still
    # streaming upload has no row yet — which is why `Interceptor#hold_response` takes an
    # `Int64?`.
    def flow_id_of(stream_id : UInt32) : Int64?
      @mutex.synchronize { @streams[stream_id]?.try(&.flow_id) }
    end

    # Record one advisory against `stream_id`'s flow — something gori DID to this message (or
    # structurally could not do to it) that neither the stored bytes nor `flows.error` can
    # show. See `Store::FlowRow#advisory`.
    #
    # Called from `HeadRewrite`, which runs BEFORE the frame reaches `feed`, so the stream may
    # not be tracked yet: this opens the entry the way `feed_locked` does, under the same
    # MAX_LIVE_STREAMS ceiling (past it nothing is tracked and the advisory is dropped along
    # with the projection it would have annotated — the raw frame log stays the truth, P7).
    # De-duplicated because a per-message fact must not repeat when a message's head block is
    # revisited, while it MUST still be recorded for every message — unlike the once-per-
    # connection `::Log.warn` beside it, which is why they are separate statements.
    def note_advisory(stream_id : UInt32, text : String) : Nil
      return if stream_id == 0 || text.empty?
      @mutex.synchronize do
        stream = @streams[stream_id]?
        if stream.nil?
          next if @streams.size >= MAX_LIVE_STREAMS
          stream = @streams[stream_id] = Stream.new
        end
        stream.advisories << text unless stream.advisories.includes?(text)
      end
    end

    # A stream the operator DROPPED at the intercept gate, or one abandoned while held. Its
    # head never went on the wire, so the gate fed it here for projection only; flush it with
    # the operator's reason and forget the stream. No-op when nothing was tracked.
    def drop_stream(stream_id : UInt32, reason : String) : Nil
      @mutex.synchronize do
        if stream = @streams.delete(stream_id)
          finalize_stream(stream_id, stream, reason)
        end
      end
    end

    # Feed one frame. `direction` is "out" (client→server) or "in". `pre` is set only by a
    # caller that already decoded this frame's header block (see `HeadBlock`).
    def feed(direction : String, frame : Frame::Header, pre : HeadBlock? = nil) : Nil
      return if frame.stream_id == 0 # connection-level (SETTINGS/PING/...) — not a stream
      @mutex.synchronize { feed_locked(direction, frame, pre) }
    rescue Gori::Error | IndexError | OverflowError
      # malformed/hostile HPACK or framing (bad pad length, overflowing integer,
      # oversized/truncated block): skip the decoded projection. The raw frame log
      # is the truth (P7) and the live relay already forwarded the bytes.
    end

    private def feed_locked(direction : String, frame : Frame::Header, pre : HeadBlock?) : Nil
      # PUSH_PROMISE opens the PROMISED stream itself (with its own cap check) and never touches
      # frame.stream_id's slot, so handle it before the lookup below — otherwise it would
      # allocate an unused Stream for the associated id.
      if frame.frame_type == Frame::Type::PushPromise
        handle_push_promise(direction, frame, direction == "out" ? @req_decoder : @resp_decoder, pre)
        return
      end

      stream = @streams[frame.stream_id]?
      if stream.nil?
        # Only HEADERS opens a stream. Every other frame for an UNKNOWN stream id — DATA,
        # PRIORITY, WINDOW_UPDATE, RST_STREAM, a bare CONTINUATION — must not allocate a
        # tracking slot, or a cheap flood of them exhausts MAX_LIVE_STREAMS and blinds capture
        # for the rest of the connection (#412). The raw frame log stays the truth (P7).
        return unless frame.frame_type == Frame::Type::Headers
        return if @streams.size >= MAX_LIVE_STREAMS # at cap — don't track new streams
        stream = @streams[frame.stream_id] = Stream.new
      end
      request = direction == "out"
      side = request ? stream.req : stream.resp
      decoder = request ? @req_decoder : @resp_decoder

      # First response byte (ttfb anchor): the first HEADERS/DATA in the response
      # direction. Guard to those frame types so a leading WINDOW_UPDATE/PRIORITY
      # doesn't pre-date ttfb (frame_type is nil for unknown frames).
      if !request && stream.resp_first_at.nil? && (ft = frame.frame_type) && (ft.headers? || ft.data?)
        stream.resp_first_at = Time.instant
      end

      case frame.frame_type
      when Frame::Type::RstStream
        # Stream cancelled (RFC 7540 §6.4): the exchange will never cleanly complete.
        # Flush whatever we captured so a cancelled-mid-stream call (client
        # context-cancel, timeout, LB idle-kill — the common way streaming RPCs end)
        # still lands in History instead of vanishing / sitting Pending forever, then
        # drop its buffers (a connection that cancels many streams must not leak).
        finalize_stream(frame.stream_id, stream, "stream reset (RST_STREAM)")
        @streams.delete(frame.stream_id)
        return
      when Frame::Type::Headers
        append_header_fragment(side, header_block(frame))
        if frame.end_headers?
          side.awaiting_continuation = false
          finish_header_block(side, decoder, pre)
          head_complete(frame.stream_id, stream, request)
        else
          side.awaiting_continuation = true # a CONTINUATION may now legally follow
        end
        side.ended = true if frame.end_stream?
      when Frame::Type::Continuation
        # A CONTINUATION with no open (un-terminated) header block is a protocol violation
        # (RFC 9113 §6.10) — a hostile peer uses one to complete a fabricated flow on a
        # never-opened stream, or to append to an already-finished one, spoofing gori's view
        # even though the raw frame log stays byte-exact. Drop it (#409).
        return unless side.awaiting_continuation
        append_header_fragment(side, frame.payload)
        if frame.end_headers?
          side.awaiting_continuation = false
          finish_header_block(side, decoder, pre)
          head_complete(frame.stream_id, stream, request)
        end
        # END_STREAM is illegal on CONTINUATION (RFC 7540 §6.10) but a hostile peer
        # can set it; mirror HEADERS/DATA so the request still emits and the stream
        # closes — otherwise it's silently dropped and the stream leaks (P7).
        side.ended = true if frame.end_stream?
      when Frame::Type::Data
        block = data_block(frame)
        # On a live RFC 8441 socket the DATA payload is WebSocket framing, not a body: it goes
        # to the reassembler, which turns it into `ws_messages` rows. Everything else — every
        # ordinary stream, and an extended CONNECT before the origin has accepted it or after
        # it has refused it — keeps the capped body buffer it has always had.
        if (ws = stream.ws) && ws.active?
          ws.push(direction, block)
        else
          side.body.write(block)
        end
        side.ended = true if frame.end_stream?
      else
        return
      end

      emit_ready(frame.stream_id, stream)
    end

    # After a frame updates a side, emit whichever halves are now ready: the request
    # once it half-closes (headers + END_STREAM), then the response once IT half-closes
    # AND the request has a flow_id to link to. The response can complete BEFORE the
    # request finishes its body (an early 4xx to a still-streaming upload); we must NOT
    # delete the stream in that case, or the later request END_STREAM would allocate a
    # fresh empty stream and lose both halves entirely.
    private def emit_ready(stream_id : UInt32, stream : Stream) : Nil
      emit_request(stream_id, stream) if stream.req.ended && stream.req.headers && stream.flow_id.nil?
      if stream.resp.ended && stream.resp.headers && stream.flow_id
        # `flow_id` used to imply the request half was closed, because that is the only thing
        # that produced one. An extended CONNECT's flow is projected at the request HEAD
        # (`open_ws_capture` says why it must be), so on a live WebSocket it no longer does —
        # and a WebSocket is precisely the exchange whose two halves close independently. An
        # origin that END_STREAMs first while the client's CLOSE frame is still in flight would
        # have had the stream deleted out from under it, dropping the client's last frames and
        # the §7.1.1 closing handshake with them. Wait for the client's half; if it never comes,
        # `finalize_all` flushes at connection close as it always has.
        return if stream.ws && !stream.req.ended
        close_ws(stream) # flush a message whose FIN never came, ahead of the flow's own row
        emit_response(stream)
        # The exchange is complete; a stream id is never reused on a connection
        # (RFC 7540 §5.1.1), so drop its buffers to bound per-connection memory.
        @streams.delete(stream_id)
      end
    end

    # Append a HEADERS/CONTINUATION fragment, enforcing the per-stream block cap.
    private def append_header_fragment(side : Side, chunk : Bytes) : Nil
      raise Gori::Error.new("h2 header block exceeds #{MAX_HEADER_BLOCK} bytes") if side.header_buf.size + chunk.size > MAX_HEADER_BLOCK
      side.header_buf.write(chunk)
    end

    # Decode one completed header block and merge it into the side's header list,
    # then reset the buffer. Merging (not replacing) is what makes h2 TRAILERS
    # work — the trailing HEADERS frame (e.g. gRPC's grpc-status) appends to the
    # initial headers rather than clobbering them.
    private def finish_header_block(side : Side, decoder : HPACK::Decoder, pre : HeadBlock?) : Nil
      # `pre` means the caller already ran (and owns) this block's decode — never decode it
      # a second time, that desyncs the decoder from the sender for the rest of the
      # connection. A nil `fields` inside it is a failed decode: raise into feed's rescue,
      # which drops the projection and (via the ensure below) clears the buffer.
      decoded = if pre
                  pre.fields || raise Gori::Error.new("h2 header block failed to decode")
                else
                  decoder.decode(side.header_buf.to_slice)
                end
      added = decoded.sum { |(n, v)| n.bytesize + v.bytesize + HPACK::Decoder::ENTRY_OVERHEAD }
      # A block is TRAILERS when a head already exists and either it carries no `:status`,
      # or the head it would replace is already FINAL. The `else` branch below exists for the
      # interim-1xx handover (100/103 then the real response), and that is the ONLY case a
      # status-bearing second block legitimately replaces a head — RFC 9113 8.1 forbids
      # pseudo-headers in trailers, so a `:status` arriving after a final head is a broken or
      # hostile origin. It used to take the replace branch, which overwrote the real response
      # head: `emit_response` then reported the TRAILER's status and the head's
      # content-type / content-encoding / Set-Cookie were gone from the flow row, with
      # `trailer_names.clear` erasing the marker that would have shown why.
      if (existing = side.headers) &&
         (!decoded.any? { |(n, _)| n == ":status" } || !interim_status?(existing))
        # Trailers (no :status) append to the existing header list — grpc-status et al.
        # Bound the CUMULATIVE list: the per-decode MAX_HEADER_LIST caps ONE block, but a
        # flood of repeated non-status HEADERS blocks (fake trailers on a stream held open
        # past END_STREAM) would otherwise grow `headers` without limit (memory DoS). The
        # raise unwinds into feed's rescue, which drops the projection and keeps the raw
        # frame log authoritative; the ensure below still clears header_buf.
        raise Gori::Error.new("h2 cumulative header list too large") if side.header_bytes + added > HPACK::Decoder::MAX_HEADER_LIST
        side.header_bytes += added
        # Remember WHICH names these are before they lose their identity in the merge —
        # after the concat a `grpc-status` that arrived in a trailer reads exactly like one
        # sent in the response head, and for gRPC the trailer is the call's real status.
        decoded.each { |(n, _)| side.trailer_names << n if side.trailer_seen.add?(n) }
        existing.concat(decoded)
      else
        # First block, OR a status-bearing response block. An interim 1xx (100/103)
        # response precedes the final one on the same stream; the final status block
        # REPLACES the interim rather than concatenating (which would leave the 1xx
        # :status first and mis-report the flow's status). This also bounds a stream's
        # header list against a flood of repeated interim HEADERS blocks.
        side.headers = decoded
        side.header_bytes = added
        # A final status block REPLACES an interim one, so anything recorded as a trailer
        # against the interim head belongs to a head that no longer exists.
        # Both halves, or the index would keep suppressing a name for a head that is gone.
        side.trailer_names.clear
        side.trailer_seen.clear
      end
    ensure
      # Always reset, even if decode raised (feed rescues HPACK/framing errors and
      # keeps processing the connection) — otherwise the next HEADERS/CONTINUATION
      # fragment would append to a stale block and decode garbage.
      side.header_buf.clear
    end

    # Server push (RFC 7540 §6.6): PUSH_PROMISE (server→client) carries a
    # promised stream id + the request headers the server will fulfil. We project
    # that promised request as its own flow; the pushed response then arrives as
    # HEADERS+DATA on the (even) promised stream. The header block shares the
    # server's HPACK context (the response decoder). v1 handles the END_HEADERS
    # case (no CONTINUATION across a PUSH_PROMISE).
    private def handle_push_promise(direction : String, frame : Frame::Header, decoder : HPACK::Decoder,
                                    pre : HeadBlock?) : Nil
      return unless direction == "in" # push is server-initiated only
      return unless frame.end_headers?
      promised_id, block = parse_push_promise(frame)
      # Server-pushed streams are server-initiated → MUST be even (RFC 7540
      # §5.1.1); reject 0 / odd ids so a forged PUSH_PROMISE can't fabricate or
      # collide with a real (odd, client) request stream.
      return if promised_id == 0 || promised_id.odd?
      promised = @streams[promised_id]?
      if promised.nil?
        return if @streams.size >= MAX_LIVE_STREAMS # at cap — don't track new streams
        promised = @streams[promised_id] = Stream.new
      end
      return if promised.req.headers # already promised
      # Same rule as finish_header_block: `pre` means the block is already decoded.
      promised.req.headers = pre ? (pre.fields || raise Gori::Error.new("h2 push block failed to decode")) : decoder.decode(block)
      promised.req.ended = true
      promised.pushed_by = frame.stream_id
      # As DATA on the flow row, not only as the `X-Gori-Pushed` line inside the projected
      # head: History, QL, the Sitemap and every JSON feed read the row, and a row the ORIGIN
      # authored must not be indistinguishable there from one the client sent.
      promised.advisories << "server push: this request was invented by the origin in a " \
                             "PUSH_PROMISE on stream #{frame.stream_id} — the client never sent it"
      emit_request(promised_id, promised)
    end

    # PUSH_PROMISE payload: optional pad length, 4-byte promised stream id
    # (R+31), the header block fragment, then padding.
    private def parse_push_promise(frame : Frame::Header) : {UInt32, Bytes}
      payload = frame.payload
      offset = 0
      pad = 0
      if frame.padded?
        return {0_u32, Bytes.empty} if payload.empty?
        pad = payload[0].to_i
        offset = 1
      end
      return {0_u32, Bytes.empty} if payload.size < offset + 4
      promised = ((payload[offset].to_u32 & 0x7f) << 24) | (payload[offset + 1].to_u32 << 16) |
                 (payload[offset + 2].to_u32 << 8) | payload[offset + 3].to_u32
      offset += 4
      validate_pad(pad, payload.size - offset)
      finish = payload.size - pad
      block = finish > offset ? payload[offset...finish] : Bytes.empty
      {promised, block}
    end

    # Strip optional PADDED / PRIORITY prefixes from a HEADERS payload to expose
    # the header block fragment (RFC 7540 §6.2).
    private def header_block(frame : Frame::Header) : Bytes
      payload = frame.payload
      offset = 0
      pad = 0
      if frame.padded?
        return Bytes.empty if payload.empty?
        pad = payload[0].to_i
        offset = 1
      end
      offset += 5 if frame.priority? # exclusive+dep(4) + weight(1)
      validate_pad(pad, payload.size - offset)
      finish = payload.size - pad
      return Bytes.empty if finish <= offset
      payload[offset...finish]
    end

    # Strip optional PADDED prefix/suffix from a DATA payload (RFC 7540 §6.1).
    private def data_block(frame : Frame::Header) : Bytes
      return frame.payload unless frame.padded?
      return Bytes.empty if frame.payload.empty?
      pad = frame.payload[0].to_i
      validate_pad(pad, frame.payload.size - 1)
      finish = frame.payload.size - pad
      return Bytes.empty if finish <= 1
      frame.payload[1...finish]
    end

    # RFC 7540: a PADDED frame's pad length must be LESS than the bytes remaining
    # for [block + padding]; pad >= that is a framing error. Raise so feed()'s rescue
    # skips the decoded projection (rather than feeding a wrongly-truncated/empty
    # block into the stateful HPACK decoder, which would desync later headers).
    private def validate_pad(pad : Int32, available : Int32) : Nil
      raise Gori::Error.new("h2 pad length exceeds frame payload") if pad > available
    end

    private def emit_request(stream_id : UInt32, stream : Stream) : Nil
      return if stream.flow_id # already emitted
      headers = stream.req.headers.not_nil!
      note_extended_connect(stream, headers)
      method = pseudo(headers, ":method") || "GET"
      path = pseudo(headers, ":path") || "/"
      scheme = pseudo(headers, ":scheme") || "https"
      authority = pseudo(headers, ":authority") || @host
      host, port = split_authority(authority)
      cap = stream.req.body
      body = cap.total == 0 ? nil : cap.to_slice

      head = synth_request_head(headers, authority, stream.req.trailer_names, stream.pushed_by,
        pseudo(headers, ":protocol"))
      captured = Store::CapturedRequest.new(
        created_at: stream.created_at, scheme: scheme, host: host, port: port,
        method: method, target: path, http_version: "HTTP/2", head: head, body: body,
        body_truncated: cap.truncated?, body_size: cap.total,
        h2_conn_id: @conn_id, h2_stream_id: stream_id.to_i64,
        advisory: advisory_of(stream))
      stream.flow_id = @sink.on_request(captured)
    end

    private def emit_response(stream : Stream, *, state : Store::FlowState = Store::FlowState::Complete,
                              error : String? = nil) : Nil
      flow_id = stream.flow_id
      return unless flow_id # request not yet projected (rare interleaving) — drop
      headers = stream.resp.headers.not_nil!
      status = (pseudo(headers, ":status") || "0").to_i? || 0
      cap = stream.resp.body
      body = cap.total == 0 ? nil : cap.to_slice
      content_type = header_value(headers, "content-type")
      content_encoding = header_value(headers, "content-encoding")
      head = synth_response_head(headers, stream.resp.trailer_names)
      now = Time.instant
      duration_us = (now - stream.started_at).total_microseconds.to_i64
      ttfb_us = stream.resp_first_at.try { |t| (t - stream.started_at).total_microseconds.to_i64 }
      @sink.on_response(Store::CapturedResponse.new(
        flow_id: flow_id, status: status, head: head, body: body,
        body_truncated: cap.truncated?, body_size: cap.total,
        content_type: content_type, content_encoding: content_encoding, state: state, error: error,
        ttfb_us: ttfb_us, duration_us: duration_us, advisory: advisory_of(stream)))
    end

    # The stream's advisories as one newline-joined column value, or nil when there are none.
    #
    # The FULL accumulated set every time, request-side entries included: `update_one` writes
    # the column outright (nil leaves it alone), so a response-direction advisory that carried
    # only its own line would erase what `emit_request` already stored.
    private def advisory_of(stream : Stream) : String?
      stream.advisories.empty? ? nil : stream.advisories.join('\n')
    end

    # Flush a stream that ended abnormally (RST_STREAM or the connection closed at a
    # frame boundary) rather than with a clean END_STREAM on both halves. Emits the
    # request if we have its headers, then the response (Complete if it actually
    # half-closed, else Aborted) or a bare Aborted marker — so a cancelled-mid-stream
    # exchange (very common for server-streaming/bidi gRPC) never vanishes or sits
    # Pending forever. The raw frame log remains the byte-exact truth (P7).
    private def finalize_stream(stream_id : UInt32, stream : Stream, reason : String) : Nil
      close_ws(stream) # whatever the socket was mid-message on, before the flow is written off
      emit_request(stream_id, stream) if stream.req.headers && stream.flow_id.nil?
      flow_id = stream.flow_id
      return unless flow_id # never saw request headers — nothing to project
      reason = extended_connect_note(stream, reason)
      if stream.resp.headers
        if stream.resp.ended
          emit_response(stream) # response fully received; only the request never cleanly closed
        else
          emit_response(stream, state: Store::FlowState::Aborted, error: reason)
        end
      else
        duration_us = (Time.instant - stream.started_at).total_microseconds.to_i64
        @sink.on_response(FlowMapper.aborted_response(flow_id, reason, duration_us: duration_us))
      end
    end

    # --- RFC 8441 extended CONNECT (a WebSocket over HTTP/2) -----------------------------

    # A header block just finished. Two things hang off that moment for an extended CONNECT,
    # and only for one: the request head is where the socket is RECOGNISED, and the response
    # head is where the origin's answer decides whether there is a socket at all.
    private def head_complete(stream_id : UInt32, stream : Stream, request : Bool) : Nil
      request ? open_ws_capture(stream_id, stream) : answer_ws_capture(stream)
    end

    # Arm the transcript for an extended CONNECT whose `:protocol` is `websocket`.
    #
    # The flow row has to be projected HERE, at the request head, and not where every other
    # stream's is. `emit_ready` emits a request when it HALF-CLOSES, and a CONNECT stream's
    # request half stays open for the whole life of the socket by definition — so waiting for
    # END_STREAM means no flow exists while the socket is live, and `ws_messages` rows have no
    # flow to hang on. It is the same moment the HTTP/1.1 path projects its 101 at.
    private def open_ws_capture(stream_id : UInt32, stream : Stream) : Nil
      return if stream.ws || stream.flow_id # already open, or this block is trailers
      headers = stream.req.headers
      return unless headers
      protocol = extended_connect_protocol(headers)
      return unless protocol && WsCapture.websocket?(protocol)
      # Decided BEFORE `emit_request`, because the advisory it stores has to say which of the
      # two dispositions this stream got.
      stream.ws_armed = @ws_captures < WsCapture::MAX_STREAMS
      return unless stream.ws_armed
      emit_request(stream_id, stream)
      flow_id = stream.flow_id
      return unless flow_id # the request insert failed — nothing to attach a transcript to
      @ws_captures += 1
      stream.ws = WsCapture.new(flow_id, @sink)
    end

    # The origin's answer to an armed extended CONNECT. A 2xx opens the socket (RFC 8441 §5.1);
    # anything else refuses it, and what follows on that stream is an ordinary error body — so
    # the codec is taken back off it rather than left to invent messages out of HTML.
    private def answer_ws_capture(stream : Stream) : Nil
      ws = stream.ws
      return if ws.nil? || ws.active?
      headers = stream.resp.headers
      return unless headers
      status = pseudo(headers, ":status").try(&.to_i?)
      return unless status
      return if status >= 100 && status < 200 # interim; the real answer is still coming
      unless status >= 200 && status < 300
        close_ws(stream)
        return
      end
      # DATA the client sent before the answer arrived. A conforming client sends none, but one
      # that does would otherwise hand the reassembler a stream that starts mid-frame — desynced
      # for the socket's whole life. Skipped when the capped buffer already dropped bytes, since
      # a hole is exactly the desync this avoids.
      cap = stream.req.body
      ws.activate(cap.total > 0 && !cap.truncated? ? cap.to_slice.dup : nil)
      # ... and project the exchange's HTTP half now, the way the h1 path records its 101 before
      # the tunnel starts. Otherwise the flow sits Pending for the socket's whole life while its
      # transcript fills in underneath it. `finalize_stream`/`emit_ready` write the row again
      # with the final state and the full duration; `update_response` is last-write-wins.
      emit_response(stream)
    end

    # Stop reading this stream's frames and surface whatever was mid-message. Idempotent, and
    # safe on every stream — nearly all of them have no transcript to close.
    private def close_ws(stream : Stream) : Nil
      ws = stream.ws
      return unless ws
      stream.ws = nil
      @ws_captures -= 1 if @ws_captures > 0
      ws.finish
    end

    # `:method CONNECT` plus a `:protocol` pseudo-header, which is how a WebSocket is opened
    # over HTTP/2.
    #
    # Deliberately an advisory and NOT a refusal. gori relays the ORIGIN's SETTINGS frame
    # verbatim (`StreamGate#write` / `Relay#emit` on stream 0), so a client facing an origin
    # that advertises SETTINGS_ENABLE_CONNECT_PROTOCOL sees that advertisement and is entitled
    # to use it — and the CONNECT stream's DATA frames then relay byte-for-byte like any
    # others. RST-ing it (RFC 9113 §8.5 would allow that for a setting gori itself never sent)
    # would break a path that works end to end.
    #
    # What gori adds is now SPLIT, and the sentence has to say which half this stream got:
    # `WsCapture` reads the frames, so the transcript is there (#733) — but the message gate,
    # per-message intercept and Match & Replace are not, because all three would have to
    # REWRITE a DATA frame to a different length, and a length-changing DATA rewrite is what
    # #492 step 5 was closed as decided-not-doing over (it deadlocks against the peer's
    # flow-control window). An extended CONNECT carrying some other `:protocol`, and one past
    # `WsCapture::MAX_STREAMS`, keep the opaque-DATA disposition and say so.
    #
    # ## Written when the stream is RECOGNISED, not when it aborts
    #
    # This sentence used to reach the flow only through `extended_connect_note` below, which
    # `finalize_stream` calls — so it existed only for a stream that ended as an ABORT. The
    # normal teardown of a conforming client (a WebSocket Close handshake, then END_STREAM)
    # completes through `emit_ready` → `emit_response` and never goes near `finalize_stream`,
    # so it landed in History as an ordinary `CONNECT → 200 complete` with `error` NULL and
    # `advisory` NULL. With `:protocol` also filtered out of the stored head by
    # `HeadCodec.synth_request`, NOTHING on disk — not History, not the QL, not `run show`,
    # not HAR, not MCP `get_flow` — could identify the flow as a WebSocket that ran with no
    # transcript, no message intercept and no Match&Replace. The recognition happens the
    # moment the request head is decoded, so that is where the advisory is recorded;
    # `advisory_of` joins the accumulated set onto BOTH halves, so it reaches every one of
    # those surfaces with no further change.
    private def note_extended_connect(stream : Stream, headers : Array({String, String})) : Nil
      protocol = extended_connect_protocol(headers)
      return unless protocol
      text = extended_connect_sentence(stream, protocol)
      stream.advisories << text unless stream.advisories.includes?(text)
    end

    # The same sentence as an ABORT reason's tail. An aborted 8441 stream's own reason
    # ("h2 connection closed", "stream reset") describes the SYMPTOM, and `flows.error` is
    # where an operator reads it — so it keeps carrying the explanation too, rather than
    # sending them to a second column for it.
    private def extended_connect_note(stream : Stream, reason : String) : String
      headers = stream.req.headers
      return reason unless headers
      protocol = extended_connect_protocol(headers)
      return reason unless protocol
      "#{reason} — #{extended_connect_sentence(stream, protocol)}"
    end

    # The `:protocol` pseudo-header's value, or nil when this is not an extended CONNECT.
    private def extended_connect_protocol(headers : Array({String, String})) : String?
      protocol = pseudo(headers, ":protocol")
      protocol.nil? || protocol.empty? ? nil : protocol
    end

    # The sentence for THIS stream's disposition. Three of them, because there are three:
    # a WebSocket gori is reading, a WebSocket past the concurrent-capture ceiling, and an
    # extended CONNECT carrying a protocol that is not WebSocket framing at all.
    private def extended_connect_sentence(stream : Stream, protocol : String) : String
      head = "this is an RFC 8441 extended CONNECT stream (:protocol #{protocol.inspect})"
      unless WsCapture.websocket?(protocol)
        return "#{head}. gori relayed it byte-for-byte but did not decode it — that protocol " \
               "is not WebSocket framing, so this stream has no message transcript"
      end
      unless stream.ws_armed
        return "#{head} — a WebSocket over HTTP/2. gori relayed it byte-for-byte but did not " \
               "decode it: more than #{WsCapture::MAX_STREAMS} such streams were already being " \
               "read on this connection, so this socket has no message transcript"
      end
      "#{head} — a WebSocket over HTTP/2. gori read its frames, so the message transcript " \
      "below is this socket's own. Per-message intercept and Match&Replace are NOT available " \
      "here: both would have to re-frame a DATA payload to a different length, which " \
      "deadlocks against the peer's flow-control window — they run on the HTTP/1.1 Upgrade " \
      "path only"
    end

    # Called by the relay when the connection closes, to flush any streams still in
    # flight (never got END_STREAM on both halves) so they don't sit Pending forever.
    def finalize_all(reason : String) : Nil
      @mutex.synchronize do
        @streams.each { |id, stream| finalize_stream(id, stream, reason) }
        @streams.clear
      end
    end

    # Whether a decoded head is an INTERIM (1xx) response — the one head a later
    # status-bearing block is allowed to replace. A request head has no `:status` at all and
    # is not interim, so a stray `:status` block on the request side is treated as trailers
    # too rather than replacing the request.
    private def interim_status?(headers : Array({String, String})) : Bool
      code = pseudo(headers, ":status").try(&.to_i?)
      !code.nil? && code >= 100 && code < 200
    end

    private def pseudo(headers : Array({String, String}), name : String) : String?
      headers.find { |(n, _)| n == name }.try(&.[1])
    end

    private def header_value(headers : Array({String, String}), name : String) : String?
      headers.find { |(n, _)| n == name }.try(&.[1])
    end

    # Reuse the one authority parser (bracketed-IPv6 aware) instead of a second
    # hand-rolled copy that mishandles "[::1]:8443".
    private def split_authority(authority : String) : {String, Int32}
      Upstream.split_host_port(authority, @port)
    end

    # A readable HTTP/2 request/response head (the bytes shown in the detail view). The
    # authoritative octets are the raw frames; this is the normalized view.
    #
    # The synthesis itself lives in `HeadCodec` because the Match&Replace path has to
    # produce the SAME bytes to run rules against — that is what makes the Rewriter tab's
    # preview (`rules.cr:331-345`, which reads exactly this head off a stored flow) agree
    # with what the live proxy does to an h2 head. Two copies would drift; there is one.
    #
    # `trailers` is the same CAPTURE-only extra `synth_response_head` passes, and it was
    # one-sided by omission: a request trailer block is merged into `headers` by
    # `finish_header_block` exactly as a response one is, so after the merge `x-req-trailer`
    # read like a header the client sent in its head. `Side#trailer_names` was already being
    # recorded for both sides.
    #
    # `protocol` is the third such capture-only extra, and it is here for the reason
    # `note_extended_connect` states: `regular(fields)` filters every pseudo-header, so an
    # RFC 8441 extended CONNECT's `:protocol` reached no stored byte at all and the head read
    # as an ordinary CONNECT tunnel.
    private def synth_request_head(headers : Array({String, String}), authority : String,
                                   trailers : Array(String)? = nil,
                                   pushed_by : UInt32? = nil,
                                   protocol : String? = nil) : Bytes
      HeadCodec.synth_request(headers, authority, trailers, pushed_by, protocol)
    end

    # `trailers` is the CAPTURE projection's extra: only the stored head names which fields
    # came from a trailing HEADERS block. The rewrite path builds its own head from the live
    # fields, so the marker never reaches a wire.
    private def synth_response_head(headers : Array({String, String}),
                                    trailers : Array(String)? = nil) : Bytes
      HeadCodec.synth_response(headers, trailers)
    end
  end
end
