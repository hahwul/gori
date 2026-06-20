require "./frame"
require "./hpack"
require "../codec/body"
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
      property ended = false
    end

    private class Stream
      getter req = Side.new
      getter resp = Side.new
      property flow_id : Int64? = nil
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

      case frame.frame_type
      when Frame::Type::RstStream
        # Stream cancelled (RFC 7540 §6.4): the exchange will never complete, so it
        # would otherwise sit in @streams forever. Drop its buffers — a connection
        # that cancels many streams (common) must not leak memory unboundedly.
        @streams.delete(frame.stream_id)
        return
      when Frame::Type::Headers
        append_header_fragment(side, header_block(frame))
        finish_header_block(side, decoder) if frame.end_headers?
        side.ended = true if frame.end_stream?
      when Frame::Type::Continuation
        append_header_fragment(side, frame.payload)
        finish_header_block(side, decoder) if frame.end_headers?
      when Frame::Type::Data
        side.body.write(data_block(frame))
        side.ended = true if frame.end_stream?
      when Frame::Type::PushPromise
        handle_push_promise(direction, frame, decoder)
        return
      else
        return
      end

      emit_request(frame.stream_id, stream) if request && side.ended && side.headers
      if !request && side.ended && side.headers
        emit_response(stream)
        # The exchange is complete; a stream id is never reused on a connection
        # (RFC 7540 §5.1.1), so drop its buffers to bound per-connection memory.
        @streams.delete(frame.stream_id)
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
      if existing = side.headers
        existing.concat(decoded)
      else
        side.headers = decoded
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
      return if promised_id == 0
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
      finish = payload.size - pad
      return Bytes.empty if finish <= offset
      payload[offset...finish]
    end

    # Strip optional PADDED prefix/suffix from a DATA payload (RFC 7540 §6.1).
    private def data_block(frame : Frame::Header) : Bytes
      return frame.payload unless frame.padded?
      return Bytes.empty if frame.payload.empty?
      pad = frame.payload[0].to_i
      finish = frame.payload.size - pad
      return Bytes.empty if finish <= 1
      frame.payload[1...finish]
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

      head = synth_request_head(method, path, headers)
      captured = Store::CapturedRequest.new(
        created_at: @created_at, scheme: scheme, host: host, port: port,
        method: method, target: path, http_version: "HTTP/2", head: head, body: body,
        body_truncated: cap.truncated?, body_size: cap.total,
        h2_conn_id: @conn_id, h2_stream_id: stream_id.to_i64)
      stream.flow_id = @sink.on_request(captured)
    end

    private def emit_response(stream : Stream) : Nil
      flow_id = stream.flow_id
      return unless flow_id # request not yet projected (rare interleaving) — drop
      headers = stream.resp.headers.not_nil!
      status = (pseudo(headers, ":status") || "0").to_i? || 0
      cap = stream.resp.body
      body = cap.total == 0 ? nil : cap.to_slice
      content_type = header_value(headers, "content-type")
      head = synth_response_head(status, headers)
      @sink.on_response(Store::CapturedResponse.new(
        flow_id: flow_id, status: status, head: head, body: body,
        body_truncated: cap.truncated?, body_size: cap.total,
        content_type: content_type, state: Store::FlowState::Complete))
    end

    private def pseudo(headers : Array({String, String}), name : String) : String?
      headers.find { |(n, _)| n == name }.try(&.[1])
    end

    private def header_value(headers : Array({String, String}), name : String) : String?
      headers.find { |(n, _)| n == name }.try(&.[1])
    end

    private def split_authority(authority : String) : {String, Int32}
      idx = authority.rindex(':')
      return {authority, @port} unless idx
      host = authority[0...idx]
      return {authority, @port} if host.includes?(':') # unbracketed IPv6
      {host, authority[(idx + 1)..].to_i? || @port}
    end

    # A readable HTTP/2 request head (the bytes shown in the detail view). The
    # authoritative octets are the raw frames; this is a normalized view.
    private def synth_request_head(method : String, path : String, headers : Array({String, String})) : Bytes
      String.build do |io|
        io << method << ' ' << path << " HTTP/2\r\n"
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
