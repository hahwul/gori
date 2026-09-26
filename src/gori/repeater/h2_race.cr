require "./h2_engine"

module Gori
  module Repeater
    # HTTP/2 SINGLE-PACKET ATTACK (#1236) — the h2 twin of `Engine.race_h1`.
    #
    # One connection, one stream per request, every request's FINAL frame withheld and then
    # flushed together in a single write, so the server dequeues them in one read and processes
    # the whole group inside the same narrow window. This is the h2 form of the multi-endpoint
    # race the Repeater exposes over marked sub-tabs; the h1 form (`Engine.race_h1`) races N
    # dedicated connections on the last byte.
    #
    # It is deliberately its OWN path and not a widening of `exchange`: `H2Engine::Conn` is a
    # serial one-request-at-a-time holder (`read_response` reads until the ONE stream it owns
    # ends), so putting N streams in flight on one connection needs a demultiplexing reader —
    # a different program, as the `H2Pool` doc block warns. The leaf helpers are shared,
    # though: `parse_request`, `write_header_block`, `header_block`/`data_block`, `merge_block`,
    # `synth_head`, `window_update`, the frame codec and `Reply` all come from `h2_engine.cr`.
    #
    # WITHHELD FRAME. For every member the withheld final frame is a 0-length `DATA(END_STREAM)`:
    # the HEADERS block (and any request body) is written with END_STREAM CLEARED during the
    # prepare phase, and the empty END_STREAM DATA — which needs no flow-control window — is what
    # lands in the single packet. Uniform across bodyless and bodied requests, and it is the
    # shape Burp's single-packet send uses.
    #
    # FLOW CONTROL / SCOPE (MVP). Same origin only (one connection = one host:port — the surface
    # enforces it before building the plan). Request bodies are written during prepare and so
    # draw down the connection's default 65535-byte send window; a group whose bodies exceed it
    # is refused up front (h1 is the path for large bodies), which keeps the prepare phase from
    # ever having to stall for a WINDOW_UPDATE (P6 — the release must not block mid-loop).
    module H2Engine
      # Per-stream response reassembly for the multiplexed read. Mirrors the HEADERS /
      # CONTINUATION / DATA arms of `read_response`, but one instance per in-flight stream so
      # the single frame loop can route each frame to its stream by id. The HPACK `decoder` is
      # the CONNECTION's single decoder (§2.3.2 dynamic table is connection-lifetime): frames
      # are fed in wire-arrival order, and HTTP/2 forbids interleaving one stream's header block
      # with another's, so decoding stays in the order the table was built.
      private class PacketStream
        getter id : UInt32
        getter? done : Bool = false
        getter? clean_eos : Bool = false
        getter duration_us : Int64 = 0_i64
        getter rst : String? = nil
        getter failure : String? = nil

        @header_buf = IO::Memory.new
        @body = IO::Memory.new
        @headers = [] of {String, String}
        @status = 0
        @final_seen = false
        @end_stream_pending = false
        @trailers : Array(String)? = nil
        @late_interim : Int32? = nil
        @trailer_pseudo : Array(String)? = nil

        def initialize(@id : UInt32)
        end

        # Feed one HEADERS/CONTINUATION/DATA frame belonging to this stream. Returns true when
        # this frame CLOSED the stream (END_STREAM), so the reader can drop it from the live set.
        # `flooded` is set when a header/body cap trips — the response is kept but flagged
        # incomplete, exactly as `read_response` does.
        def feed(frame : Frame::Header, decoder : HPACK::Decoder, started : Time::Instant) : Bool
          case frame.frame_type
          when Frame::Type::Headers
            chunk = H2Engine.header_block(frame)
            return finish(started) if @header_buf.bytesize + chunk.size > H2Engine::MAX_HEADER_BLOCK
            @header_buf.write(chunk)
            @end_stream_pending = frame.end_stream?
            merge(decoder, started) if frame.end_headers?
          when Frame::Type::Continuation
            return finish(started) if @header_buf.bytesize + frame.payload.size > H2Engine::MAX_HEADER_BLOCK
            @header_buf.write(frame.payload)
            merge(decoder, started) if frame.end_headers?
          when Frame::Type::Data
            @body.write(H2Engine.data_block(frame)) if @body.bytesize < H2Engine::MAX_BODY
            if frame.end_stream?
              @clean_eos = true
              return finish(started)
            end
            return finish(started) if @body.bytesize >= H2Engine::MAX_BODY # over-large — truncate
          when Frame::Type::RstStream
            @rst = H2Engine.rst_reason(frame)
            return finish(started)
          else
            # PRIORITY / PUSH_PROMISE / WINDOW_UPDATE for this stream — nothing to reassemble.
          end
          done?
        end

        # Whether a DATA frame just fed should be credited back (connection + stream windows), so
        # a body larger than the default window keeps flowing — the reader half of the same rule
        # `read_response` applies. The stream window is not credited once the stream is done.
        def data_payload(frame : Frame::Header) : Int32
          frame.payload.size
        end

        # Mark the stream closed by a connection-level event (GOAWAY, or the socket dropping)
        # without an END_STREAM of its own — kept incomplete.
        def close_incomplete(started : Time::Instant) : Nil
          finish(started)
        end

        # Fail a still-open stream with `message`. A stream already done keeps its result; the
        # caller decides whether the error is local here or makes the shared connection unusable.
        def fail(message : String, started : Time::Instant) : Nil
          return if @done
          @failure = message
          finish(started)
        end

        # The assembled response, or nil when no final header block ever arrived (the origin
        # RST'd or went away before answering this stream).
        def reply : Reply?
          return nil unless @final_seen
          Reply.new(@status, @headers, @body.size == 0 ? nil : @body.to_slice, clean_eos?,
            nil, @rst, @trailers, false, @final_seen, @late_interim, @trailer_pseudo)
        end

        # A block carrying END_STREAM (a body-less 204/304/HEAD answer, or trailers) closes the
        # stream through `finish`, like every other close, so it records its duration.
        private def merge(decoder : HPACK::Decoder, started : Time::Instant) : Nil
          @status, @final_seen, @trailers, @late_interim, @trailer_pseudo =
            H2Engine.merge_block(@header_buf, decoder, @headers, @status, @final_seen,
              @trailers, @late_interim, @trailer_pseudo, @end_stream_pending)
          if @end_stream_pending
            @clean_eos = true
            finish(started)
          end
        ensure
          # In particular, release a completed but over-limit block when its stream is rejected
          # locally and the reader continues with its siblings.
          @header_buf.clear
        end

        private def finish(started : Time::Instant) : Bool
          unless @done
            @done = true
            @duration_us = H2Engine.race_elapsed(started)
          end
          true
        end
      end

      # `elapsed` is private; the reassembly class above needs it. Named distinctly so it does
      # not shadow the private one inside the module.
      def self.race_elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end

      # Fire N DISTINCT requests as one HTTP/2 single-packet attack. `wires` are the already-
      # wired, already-gated per-member request bytes (the caller owns the send gate, one blocked
      # member having refused the whole group upstream). Same origin for every member.
      #
      # Refuses the whole release if fewer than 2 members survive assembly — racing one stream
      # proves nothing, matching `Engine.race_h1`.
      def self.single_packet(wires : Array(Bytes), *, scheme : String, host : String, port : Int32,
                             verify_upstream : Bool, sni : String? = nil,
                             timeout : Time::Span? = nil,
                             overrides : Gori::HostOverrides? = nil,
                             preserve_field_case : Bool = false,
                             reframe_grpc : Bool = false,
                             tls_preset : String? = nil) : Array(Result)
        return [] of Result if wires.empty?
        n = wires.size

        upstream, dial_failure = open(scheme, host, port, verify_upstream, sni, timeout, overrides, tls_preset)
        unless upstream
          msg = connect_error(scheme, host, port, verify_upstream, dial_failure)
          return Array(Result).new(n) { failure("race: dial failed — #{msg}", Time.instant) }
        end

        conn = begin
          Conn.new(upstream)
        rescue ex
          upstream.close rescue nil
          return Array(Result).new(n) { failure("race: h2 connect failed — #{ex.message}", Time.instant) }
        end

        begin
          results = Array(Result?).new(n) { nil }
          io = conn.io

          # ── prepare: write HEADERS (+ any body) with END_STREAM CLEARED, hold back the final frame ──
          prepared = prepare_streams(conn, io, wires, scheme, host, port, preserve_field_case, reframe_grpc, results)

          if msg = flush_or_error(io) # flush the prepared HEADERS/DATA; the final frames are still in hand
            prepared.each { |(i, _, _)| results[i] = failure("race: flush failed — #{msg}", Time.instant) }
            return finalize(results, n)
          end
          return finalize_underfilled(results, n, prepared.size) if prepared.size < 2

          # ── release: all withheld final frames in ONE write — the single packet (P6: no I/O between) ──
          started = Time.instant
          if msg = release_final_frames(io, prepared)
            prepared.each { |(i, _, _)| results[i] = failure("race: release write failed — #{msg}", started) }
            return finalize(results, n)
          end

          # ── read: demultiplex the N streams' responses off the one connection ──
          streams = {} of UInt32 => PacketStream
          prepared.each { |(_, st, _)| streams[st.id] = st }
          read_streams(io, conn, streams, started, timeout)
          collect_results(prepared, results, host, port, started)
          finalize(results, n)
        ensure
          upstream.close rescue nil
        end
      end

      # The prepare pass: write every member's HEADERS (and any body) with END_STREAM cleared, and
      # return the members that assembled as `{index, stream, withheld final frame}`. A member that
      # could not be framed/written has its error recorded in `results` and is left out. The
      # connection send window is drawn down by each body so the group stays within it.
      private def self.prepare_streams(conn : Conn, io : IO, wires : Array(Bytes), scheme : String,
                                       host : String, port : Int32, preserve_field_case : Bool,
                                       reframe_grpc : Bool,
                                       results : Array(Result?)) : Array({Int32, PacketStream, Bytes})
        prepared = [] of {Int32, PacketStream, Bytes}
        window = DEFAULT_WINDOW.to_i64
        wires.each_with_index do |wire, i|
          stream, final, error, used = prepare_packet_stream(conn, io, wire, scheme, host, port,
            preserve_field_case, reframe_grpc, window)
          if error
            results[i] = error
          elsif stream && final
            prepared << {i, stream, final}
            window -= used
          end
        end
        prepared
      end

      # Flush the prepared frames, or the error message if the socket failed.
      private def self.flush_or_error(io : IO) : String?
        io.flush
        nil
      rescue ex
        ex.message || "socket write failed"
      end

      # Write every withheld final frame in ONE `io.write` — the single packet — or the error
      # message if the socket failed. No I/O between the accumulation and the one write (P6).
      private def self.release_final_frames(io : IO, prepared : Array({Int32, PacketStream, Bytes})) : String?
        combined = IO::Memory.new
        prepared.each { |(_, _, final)| combined.write(final) }
        io.write(combined.to_slice)
        io.flush
        nil
      rescue ex
        ex.message || "socket write failed"
      end

      # Shape each prepared member's `PacketStream` into its `Result` (a stream the read left open
      # is closed incomplete first).
      private def self.collect_results(prepared : Array({Int32, PacketStream, Bytes}),
                                       results : Array(Result?), host : String, port : Int32,
                                       started : Time::Instant) : Nil
        prepared.each do |(i, st, _)|
          st.close_incomplete(started) unless st.done?
          results[i] = shape(st, host, port, started)
        end
      end

      # Prepare ONE member's stream: parse its wire, open a stream, and write its HEADERS (and any
      # body) with END_STREAM CLEARED — the withheld final frame (an empty `DATA(END_STREAM)`) is
      # returned to be released with the rest. `window` is the connection send window still free;
      # a body larger than it is refused (the withhold trick can't hold a frame the window won't
      # admit). Returns `{stream, final_frame, nil, body_bytes_used}` on success, or
      # `{nil, nil, error, 0}` for a member that could not be assembled.
      private def self.prepare_packet_stream(conn : Conn, io : IO, wire : Bytes, scheme : String,
                                             host : String, port : Int32, preserve_field_case : Bool,
                                             reframe_grpc : Bool,
                                             window : Int64) : {PacketStream?, Bytes?, Result?, Int64}
        headers, body = begin
          parse_request(wire, scheme, host, port, preserve_field_case, reframe_grpc)
        rescue ex
          return {nil, nil, failure("race: could not frame request — #{ex.message}", Time.instant), 0_i64}
        end
        body = nil if body && body.empty?
        if (b = body) && b.size > window
          return {nil, nil, failure("race: h2 single-packet body too large for the initial window " \
                                    "(#{b.size} B) — use the HTTP/1.1 race for large bodies", Time.instant), 0_i64}
        end
        sid = conn.take_stream
        block = HPACK::Encoder.new.encode(headers)
        used = 0_i64
        begin
          write_header_block(io, block, false, sid) # END_STREAM withheld → carried by the final frame
          if b = body
            off = 0
            while off < b.size
              m = Math.min(MAX_FRAME, b.size - off)
              io.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, sid, b[off, m]).to_bytes)
              off += m
            end
            used = b.size.to_i64
          end
        rescue ex
          return {nil, nil, failure("race: write failed — #{ex.message}", Time.instant), 0_i64}
        end
        # The withheld final frame: an empty DATA(END_STREAM). Needs no flow-control window.
        final = Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, sid, Bytes.empty).to_bytes
        {PacketStream.new(sid), final, nil, used}
      end

      # The multiplexed frame loop: read frames off the one connection and route each to its
      # stream, until every stream has closed or the budget runs out. Connection-level frames
      # (SETTINGS/PING/GOAWAY, stream-0 WINDOW_UPDATE) are handled once here; per-stream frames
      # are routed to their `PacketStream` by `route_stream_frame`.
      #
      # The caller's `timeout` bounds both the no-progress stall and the whole read, the same
      # shape `exchange` uses; without one, the global idle timeout and its budget multiple.
      private def self.read_streams(io : IO, conn : Conn, streams : Hash(UInt32, PacketStream),
                                    started : Time::Instant, timeout : Time::Span? = nil) : Nil
        remaining = streams.size
        patience = timeout || Settings.io_timeout
        hard = started + (timeout || Settings.io_timeout * DEFAULT_BUDGET_FACTOR)
        progress = Time.instant
        frames = 0

        while remaining > 0
          frame = read_next_frame(io, progress, patience, hard)
          break unless frame # idle / budget / socket drop — open streams left incomplete
          frames += 1
          break if frames > MAX_FRAMES

          case frame.frame_type
          when Frame::Type::Settings, Frame::Type::Ping, Frame::Type::Goaway
            break if handle_connection_frame(io, frame) # GOAWAY tears the connection down
          when Frame::Type::Headers, Frame::Type::Continuation, Frame::Type::Data, Frame::Type::RstStream
            break unless routed = route_or_fail(io, conn, streams, frame, started)
            advanced, closed = routed
            progress = Time.instant if advanced
            remaining -= 1 if closed
          else
            # WINDOW_UPDATE (moot — all request bytes are written), PRIORITY, PUSH_PROMISE.
          end
        end
      end

      # Read the next frame, or nil to end the read: on a no-progress stall past `patience`, past
      # the whole-read `hard` deadline, or on an idle timeout / socket drop. Keeps the timing and
      # the transport-error handling out of the dispatch loop.
      private def self.read_next_frame(io : IO, progress : Time::Instant, patience : Time::Span,
                                       hard : Time::Instant) : Frame::Header?
        now = Time.instant
        return nil if now - progress >= patience || now >= hard
        begin
          Frame.read(io)
        rescue IO::TimeoutError
          nil
        rescue IO::Error | Gori::Error | OpenSSL::Error
          nil # connection dropped — return what arrived, remaining flagged incomplete
        end
      end

      # A connection-level frame while reading responses: ACK a SETTINGS/PING, and report GOAWAY
      # (returns true) so the caller stops reading. Returns false otherwise.
      private def self.handle_connection_frame(io : IO, frame : Frame::Header) : Bool
        case frame.frame_type
        when Frame::Type::Settings then ack_soft(io, Frame::Type::Settings, Bytes.empty) unless frame.ack?
        when Frame::Type::Ping     then ack_soft(io, Frame::Type::Ping, frame.payload) unless frame.ack?
        when Frame::Type::Goaway   then return true
        end
        false
      end

      # Route one HEADERS/CONTINUATION/DATA/RST frame to its `PacketStream` and reassemble it.
      # Returns `{advanced, closed}`: `advanced` when the frame belonged to a live stream (so the
      # read's no-progress clock resets), `closed` when it just ended that stream (so the caller
      # drops it from the live count). A DATA frame is credited back to the connection window so a
      # body past the default keeps flowing — the reader half of `read_response`'s rule.
      private def self.route_stream_frame(io : IO, conn : Conn, streams : Hash(UInt32, PacketStream),
                                          frame : Frame::Header, started : Time::Instant) : {Bool, Bool}
        st = streams[frame.stream_id]?
        return {false, false} unless st # a frame for a stream we do not own
        return {false, false} if st.done?
        if frame.frame_type == Frame::Type::Data
          consumed = st.data_payload(frame)
          closed = st.feed(frame, conn.decoder, started)
          window_update(io, 0_u32, consumed) if consumed > 0
          window_update(io, frame.stream_id, consumed) if consumed > 0 && !closed
          {true, closed}
        else
          {true, st.feed(frame, conn.decoder, started)}
        end
      end

      # `route_stream_frame`, or nil once an HPACK/framing error leaves the connection's shared
      # decoder unusable. A cleanly decoded but over-limit header list is stream-local: the decoder
      # has consumed the whole block and applied its table updates, so only that stream is failed.
      private def self.route_or_fail(io : IO, conn : Conn, streams : Hash(UInt32, PacketStream),
                                     frame : Frame::Header, started : Time::Instant) : {Bool, Bool}?
        route_stream_frame(io, conn, streams, frame, started)
      rescue ex : HPACK::HeaderListTooLarge
        if st = streams[frame.stream_id]?
          st.fail(ex.message || "hpack: header list too large", started)
          {true, true}
        else
          msg = ex.message || "hpack: header list too large"
          streams.each_value(&.fail(msg, started))
          nil
        end
      rescue ex
        msg = ex.message || "h2 response decode failed"
        streams.each_value(&.fail(msg, started))
        nil
      end

      # One member's `PacketStream` as a `Result`, through the same `synth_head` projection the
      # capture path and `exchange` use.
      private def self.shape(st : PacketStream, host : String, port : Int32,
                             started : Time::Instant) : Result
        reply = st.reply
        if failure = st.failure
          # The origin answered, but its header state broke mid-read. A final head that already
          # decoded is kept, flagged incomplete, beside the reason.
          return Result.new(Bytes.new(0), nil, nil, st.duration_us, failure, delivered: true) unless reply
          head = synth_head(reply)
          return Result.new(head, reply.body, Proxy::Codec::Http1.parse_response_head(head),
            st.duration_us, error: failure, incomplete: true, delivered: true)
        end
        unless reply
          return Result.new(Bytes.new(0), nil, nil, st.duration_us,
            st.rst || "race: no response (h2 single-packet) from #{host}:#{port}",
            delivered: false)
        end
        head = synth_head(reply)
        resp = Proxy::Codec::Http1.parse_response_head(head)
        Result.new(head, reply.body, resp, st.duration_us,
          error: reply.rst,
          incomplete: !reply.clean_eos, delivered: true)
      end

      private def self.finalize(results : Array(Result?), n : Int32) : Array(Result)
        (0...n).map do |i|
          results[i]? || Result.new(Bytes.new(0), nil, nil, 0_i64, "race: no result")
        end
      end

      # Fewer than 2 members survived prepare — refuse the whole release.
      private def self.finalize_underfilled(results : Array(Result?), n : Int32, live : Int32) : Array(Result)
        (0...n).map do |i|
          results[i]? || Result.new(Bytes.new(0), nil, nil, 0_i64,
            "race: could not assemble enough live streams (#{live} of #{n})")
        end
      end
    end
  end
end
