require "./frame"
require "./hpack"
require "../codec/body"
require "../upstream"
require "../sink"
require "../../flow_mapper"
require "../../store/models"

module Gori::Proxy::H2
  # Turns the raw frame stream of one h2 connection into the decoded projection:
  # it assembles HEADERS(+CONTINUATION) and DATA per stream, decodes headers via
  # HPACK, and emits a `flows` row per request/response exchange (so h2 traffic
  # lands in History/QL/Replay next to h1). The raw frame log remains the truth
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
      getter body = Codec::CaptureBuffer.new(Codec::Body::CAPTURE_MAX)
      property headers : Array({String, String})? = nil
      # Cumulative decoded-header bytesize across all merged blocks on this side, so a
      # flood of repeated non-status HEADERS blocks (fake trailers, never END_STREAM)
      # can't grow `headers` without bound. Per-block caps (MAX_HEADER_BLOCK, HPACK
      # MAX_HEADER_LIST) only bound ONE block; this bounds the accumulation.
      property header_bytes = 0
      property ended = false
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
      property resp_first_at : Time::Instant? = nil
    end

    def initialize(@sink : FlowSink, @host : String, @port : Int32, @created_at : Int64,
                   @conn_id : Int64 = 0_i64)
      @mutex = Mutex.new
      @streams = {} of UInt32 => Stream
      @req_decoder = HPACK::Decoder.new
      @resp_decoder = HPACK::Decoder.new
    end

    # Feed one frame. `direction` is "out" (client→server) or "in".
    def feed(direction : String, frame : Frame::Header) : Nil
      return if frame.stream_id == 0 # connection-level (SETTINGS/PING/...) — not a stream
      @mutex.synchronize { feed_locked(direction, frame) }
    rescue Gori::Error | IndexError | OverflowError
      # malformed/hostile HPACK or framing (bad pad length, overflowing integer,
      # oversized/truncated block): skip the decoded projection. The raw frame log
      # is the truth (P7) and the live relay already forwarded the bytes.
    end

    private def feed_locked(direction : String, frame : Frame::Header) : Nil
      stream = @streams[frame.stream_id]?
      if stream.nil?
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
        finish_header_block(side, decoder) if frame.end_headers?
        side.ended = true if frame.end_stream?
      when Frame::Type::Continuation
        append_header_fragment(side, frame.payload)
        finish_header_block(side, decoder) if frame.end_headers?
        # END_STREAM is illegal on CONTINUATION (RFC 7540 §6.10) but a hostile peer
        # can set it; mirror HEADERS/DATA so the request still emits and the stream
        # closes — otherwise it's silently dropped and the stream leaks (P7).
        side.ended = true if frame.end_stream?
      when Frame::Type::Data
        side.body.write(data_block(frame))
        side.ended = true if frame.end_stream?
      when Frame::Type::PushPromise
        handle_push_promise(direction, frame, decoder)
        return
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
    private def finish_header_block(side : Side, decoder : HPACK::Decoder) : Nil
      decoded = decoder.decode(side.header_buf.to_slice)
      added = decoded.sum { |(n, v)| n.bytesize + v.bytesize + HPACK::Decoder::ENTRY_OVERHEAD }
      if (existing = side.headers) && !decoded.any? { |(n, _)| n == ":status" }
        # Trailers (no :status) append to the existing header list — grpc-status et al.
        # Bound the CUMULATIVE list: the per-decode MAX_HEADER_LIST caps ONE block, but a
        # flood of repeated non-status HEADERS blocks (fake trailers on a stream held open
        # past END_STREAM) would otherwise grow `headers` without limit (memory DoS). The
        # raise unwinds into feed's rescue, which drops the projection and keeps the raw
        # frame log authoritative; the ensure below still clears header_buf.
        raise Gori::Error.new("h2 cumulative header list too large") if side.header_bytes + added > HPACK::Decoder::MAX_HEADER_LIST
        side.header_bytes += added
        existing.concat(decoded)
      else
        # First block, OR a status-bearing response block. An interim 1xx (100/103)
        # response precedes the final one on the same stream; the final status block
        # REPLACES the interim rather than concatenating (which would leave the 1xx
        # :status first and mis-report the flow's status). This also bounds a stream's
        # header list against a flood of repeated interim HEADERS blocks.
        side.headers = decoded
        side.header_bytes = added
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
    private def handle_push_promise(direction : String, frame : Frame::Header, decoder : HPACK::Decoder) : Nil
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
      promised.req.headers = decoder.decode(block)
      promised.req.ended = true
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
      method = pseudo(headers, ":method") || "GET"
      path = pseudo(headers, ":path") || "/"
      scheme = pseudo(headers, ":scheme") || "https"
      authority = pseudo(headers, ":authority") || @host
      host, port = split_authority(authority)
      cap = stream.req.body
      body = cap.total == 0 ? nil : cap.to_slice

      head = synth_request_head(method, path, headers, authority)
      captured = Store::CapturedRequest.new(
        created_at: @created_at, scheme: scheme, host: host, port: port,
        method: method, target: path, http_version: "HTTP/2", head: head, body: body,
        body_truncated: cap.truncated?, body_size: cap.total,
        h2_conn_id: @conn_id, h2_stream_id: stream_id.to_i64)
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
      head = synth_response_head(status, headers)
      now = Time.instant
      duration_us = (now - stream.started_at).total_microseconds.to_i64
      ttfb_us = stream.resp_first_at.try { |t| (t - stream.started_at).total_microseconds.to_i64 }
      @sink.on_response(Store::CapturedResponse.new(
        flow_id: flow_id, status: status, head: head, body: body,
        body_truncated: cap.truncated?, body_size: cap.total,
        content_type: content_type, content_encoding: content_encoding, state: state, error: error,
        ttfb_us: ttfb_us, duration_us: duration_us))
    end

    # Flush a stream that ended abnormally (RST_STREAM or the connection closed at a
    # frame boundary) rather than with a clean END_STREAM on both halves. Emits the
    # request if we have its headers, then the response (Complete if it actually
    # half-closed, else Aborted) or a bare Aborted marker — so a cancelled-mid-stream
    # exchange (very common for server-streaming/bidi gRPC) never vanishes or sits
    # Pending forever. The raw frame log remains the byte-exact truth (P7).
    private def finalize_stream(stream_id : UInt32, stream : Stream, reason : String) : Nil
      emit_request(stream_id, stream) if stream.req.headers && stream.flow_id.nil?
      flow_id = stream.flow_id
      return unless flow_id # never saw request headers — nothing to project
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

    # Called by the relay when the connection closes, to flush any streams still in
    # flight (never got END_STREAM on both halves) so they don't sit Pending forever.
    def finalize_all(reason : String) : Nil
      @mutex.synchronize do
        @streams.each { |id, stream| finalize_stream(id, stream, reason) }
        @streams.clear
      end
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

    # A readable HTTP/2 request head (the bytes shown in the detail view). The
    # authoritative octets are the raw frames; this is a normalized view.
    #
    # HTTP/2 carries the request's host in the `:authority` pseudo-header
    # (RFC 7540 §8.1.2.3) rather than a `Host:` field, and the loop below skips
    # ALL pseudo-headers — so without this, the synthesized head has no host at
    # all, breaking `gori run show` / MCP get_flow / QL `header:host` for every
    # h2 flow. Emit `Host: <authority>` first (authority is the caller's
    # already-resolved `:authority` pseudo value, falling back to @host),
    # unless the headers already carry an explicit (non-pseudo) `host` field.
    private def synth_request_head(method : String, path : String, headers : Array({String, String}), authority : String) : Bytes
      String.build do |io|
        io << method << ' ' << path << " HTTP/2\r\n"
        has_host = headers.any? { |(n, _)| n.compare("host", case_insensitive: true) == 0 }
        io << "Host: " << authority << "\r\n" if !authority.empty? && !has_host
        headers.each { |(n, v)| io << n << ": " << v << "\r\n" unless n.starts_with?(':') }
        io << "\r\n"
      end.to_slice
    end

    private def synth_response_head(status : Int32, headers : Array({String, String})) : Bytes
      String.build do |io|
        io << "HTTP/2 " << status << "\r\n"
        headers.each { |(n, v)| io << n << ": " << v << "\r\n" unless n.starts_with?(':') }
        io << "\r\n"
      end.to_slice
    end
  end
end
