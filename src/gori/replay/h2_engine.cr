require "../proxy/upstream"
require "../proxy/h2/frame"
require "../proxy/h2/hpack"
require "../proxy/codec/http1"
require "./engine"

module Gori
  module Replay
    # Replays an h2 flow as real HTTP/2: opens a connection (TLS+ALPN "h2" for
    # https, or h2c prior-knowledge for http), HPACK-encodes the edited request,
    # exchanges frames on stream 1, and reassembles the response into the same
    # `Replay::Result` the h1 engine produces (so the diff/view path is shared).
    #
    # One-shot and intentionally minimal: empty client SETTINGS (ACK on receipt),
    # PING answered. The RESPONSE side is flow-controlled — each DATA frame is
    # credited straight back with a WINDOW_UPDATE on the connection + stream, so
    # responses past the 65535-byte default window stream fine. The REQUEST side is
    # not flow-controlled (a >64 KiB request body could stall — fine for the
    # workbench; replay bodies are typically small).
    module H2Engine
      MAX_FRAME = 16384
      # Caps for the one-shot response read, mirroring the live assembler. Without
      # them a hostile/large origin could OOM the workbench: HEADERS/CONTINUATION
      # are NOT flow-controlled, so a CONTINUATION flood grows the header block
      # unboundedly, and a streaming/over-large body has no aggregate ceiling.
      MAX_HEADER_BLOCK = 1 << 20         # 1 MiB
      MAX_BODY         = 8 * 1024 * 1024 # 8 MiB (replay response read ceiling; independent of the proxy-capture cap)
      # Hard ceiling on frames processed for one response. HEADERS/DATA are byte-capped
      # above, but non-terminal frames (PING/PRIORITY/WINDOW_UPDATE/SETTINGS on any stream)
      # are neither — a hostile origin can stream them forever without END_STREAM, and the
      # per-op io_timeout only fires on IDLE, so bytes-always-arriving pins the fiber. This
      # bounds the loop the way the h1 engine's MAX_INTERIM does (RFC-hostile-origin guard).
      MAX_FRAMES = 100_000

      private alias Frame = Proxy::H2::Frame
      private alias HPACK = Proxy::H2::HPACK

      # Request headers that are connection-specific and illegal in h2 (RFC 7540
      # §8.1.2.2); `host` is replaced by `:authority`.
      FORBIDDEN = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "host"}

      def self.send(request : Bytes, *, scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    timeout : Time::Span? = nil) : Result
        started = Time.instant
        upstream = open(scheme, host, port, verify_upstream, sni, timeout)
        return failure(connect_error(scheme, host, port, verify_upstream), started) unless upstream
        begin
          headers, body = parse_request(request, scheme, host, port)
          write_request(upstream, headers, body)
          status, resp_headers, resp_body, complete = read_response(upstream)
          return failure("no h2 response from #{host}:#{port}", started) if status == 0 && resp_headers.empty?
          head = synth_head(status, resp_headers)
          resp = Proxy::Codec::Http1.parse_response_head(head)
          Result.new(head, resp_body, resp, elapsed(started), incomplete: !complete)
        rescue ex
          failure(ex.message || "h2 replay error", started)
        ensure
          upstream.close rescue nil
        end
      end

      private def self.open(scheme : String, host : String, port : Int32, verify : Bool,
                            sni : String? = nil, timeout : Time::Span? = nil) : IO?
        ct = timeout || Proxy::Upstream::CONNECT_TIMEOUT
        it = timeout || Proxy::Upstream::IO_TIMEOUT
        if scheme == "https"
          ssl = Proxy::Upstream.dial_tls(host, port, verify: verify, alpn: "h2", sni: sni, connect_timeout: ct, io_timeout: it)
          return nil unless ssl
          # Origin completed the handshake but won't speak h2 — close the live
          # socket before bailing, else it leaks (it's never returned to `ensure`).
          unless ssl.alpn_protocol == "h2"
            ssl.close rescue nil
            return nil
          end
          ssl
        else
          Proxy::Upstream.dial(host, port, connect_timeout: ct, io_timeout: it) # h2c prior-knowledge
        end
      end

      private def self.write_request(io : IO, headers : Array({String, String}), body : Bytes?) : Nil
        io.write(Frame::PREFACE)
        # SETTINGS_ENABLE_PUSH=0 (id 0x2): a one-shot replay never wants server push, and
        # pushed DATA on a non-1 stream would consume the connection flow-control window
        # without being credited back (the DATA loop only credits stream 1), stalling a
        # large response. Disabling push at the source avoids the whole class.
        no_push = Bytes[0x00_u8, 0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
        io.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, no_push).to_bytes)
        block = HPACK::Encoder.new.encode(headers)
        end_stream = body.nil? || body.empty?
        flags = Frame::END_HEADERS | (end_stream ? Frame::END_STREAM : 0_u8)
        io.write(Frame::Header.new(Frame::Type::Headers.value, flags, 1_u32, block).to_bytes)
        write_data(io, body) if body && !body.empty?
        io.flush
      end

      private def self.write_data(io : IO, body : Bytes) : Nil
        offset = 0
        while offset < body.size
          n = Math.min(MAX_FRAME, body.size - offset)
          last = offset + n >= body.size
          flags = last ? Frame::END_STREAM : 0_u8
          io.write(Frame::Header.new(Frame::Type::Data.value, flags, 1_u32, body[offset, n]).to_bytes)
          offset += n
        end
      end

      # Reads frames until stream 1 closes; returns {status, headers, body,
      # clean_eos}. clean_eos is true only when the stream ended on a real
      # END_STREAM — false when it was cut by GOAWAY/RST_STREAM, a mid-stream
      # connection drop, or a MAX_BODY truncation, so the caller can flag the
      # response as incomplete (mirrors the h1 engine's premature-EOF signal).
      private def self.read_response(io : IO) : {Int32, Array({String, String}), Bytes?, Bool}
        decoder = HPACK::Decoder.new
        header_buf = IO::Memory.new
        body = IO::Memory.new
        headers = [] of {String, String}
        status = 0
        done = false
        clean_eos = false          # a genuine END_STREAM closed the stream
        end_stream_pending = false # END_STREAM seen on a HEADERS frame whose block isn't closed yet
        frames = 0                 # every frame counted (incl. ping/priority) — bounds a junk-frame flood

        until done
          # An IO error mid-response (connection reset — e.g. an origin that closed
          # right after a non-END_STREAM DATA) is end-of-data, not a hard failure:
          # treat it like a clean EOF and return what arrived, flagged incomplete
          # (mirrors the h1 engine). A Gori::Error from Frame.read (oversized/corrupt
          # frame — a real protocol violation) is NOT swallowed: it propagates to the
          # outer rescue and surfaces as a failed replay, since the workbench exists to
          # reveal exactly that.
          frame = begin
            Frame.read(io)
          rescue IO::Error
            nil
          end
          break if frame.nil?
          # Count EVERY frame, not just data/headers: an origin flooding PING/PRIORITY/
          # WINDOW_UPDATE without ever sending END_STREAM trips no byte cap and no idle
          # timeout, so this ceiling is what guarantees the loop terminates. On trip the
          # stream is left un-closed → the response is flagged incomplete.
          frames += 1
          break if frames > MAX_FRAMES
          case frame.frame_type
          when Frame::Type::Settings
            ack(io, Frame::Type::Settings, Bytes.empty) unless frame.ack?
          when Frame::Type::Ping
            ack(io, Frame::Type::Ping, frame.payload) unless frame.ack?
          when Frame::Type::Goaway
            done = true
          when Frame::Type::RstStream
            done = true if frame.stream_id == 1
          when Frame::Type::Headers
            next unless frame.stream_id == 1
            chunk = header_block(frame)
            break if header_buf.bytesize + chunk.size > MAX_HEADER_BLOCK # flood — abort
            header_buf.write(chunk)
            # END_STREAM only completes the stream once the header block is fully
            # absorbed — a HEADERS with END_STREAM but not END_HEADERS is continued
            # by CONTINUATION frames; finishing early would drop them (and decode no
            # status). Defer completion until END_HEADERS.
            end_stream_pending = frame.end_stream?
            if frame.end_headers?
              status = absorb(header_buf, decoder, headers, status)
              done = clean_eos = true if end_stream_pending
              headers.clear if !end_stream_pending && interim?(status)
            end
          when Frame::Type::Continuation
            next unless frame.stream_id == 1
            break if header_buf.bytesize + frame.payload.size > MAX_HEADER_BLOCK # flood — abort
            header_buf.write(frame.payload)
            if frame.end_headers?
              status = absorb(header_buf, decoder, headers, status)
              done = clean_eos = true if end_stream_pending
              headers.clear if !end_stream_pending && interim?(status)
            end
          when Frame::Type::Data
            next unless frame.stream_id == 1
            consumed = frame.payload.size # flow control counts the WHOLE DATA payload (incl. padding)
            body.write(data_block(frame)) if body.bytesize < MAX_BODY
            done = clean_eos = true if frame.end_stream?
            break if body.bytesize >= MAX_BODY # over-large/streaming body — truncate
            # Replenish the connection (stream 0) AND stream flow-control windows by
            # what we just consumed, so the origin keeps sending past the 65535-byte
            # default window. Without this, any response body > 64 KiB stalls until
            # the IO timeout (no WINDOW_UPDATE was ever sent).
            if !done && consumed > 0
              window_update(io, 0_u32, consumed)
              window_update(io, 1_u32, consumed)
            end
          else
            # WINDOW_UPDATE / PUSH_PROMISE / PRIORITY — ignored for a one-shot
          end
        end

        {status, headers, body.size == 0 ? nil : body.to_slice, clean_eos}
      end

      # Decode a completed header block, splitting :status from regular headers.
      private def self.absorb(buf : IO::Memory, decoder : HPACK::Decoder,
                              headers : Array({String, String}), status : Int32) : Int32
        decoder.decode(buf.to_slice).each do |(name, value)|
          if name == ":status"
            status = value.to_i? || status
          elsif !name.starts_with?(':')
            headers << {visualize_field(name), visualize_field(value)}
          end
        end
        buf.clear
        status
      end

      # An interim (informational) response: its header fields precede — and are not part
      # of — the final response (RFC 9110 §15.2), so they're dropped, not merged.
      private def self.interim?(status : Int32) : Bool
        100 <= status < 200
      end

      # RFC 9113 §8.2.1 forbids CR/LF in an h2 field name/value. If a non-compliant origin
      # smuggles one in, ESCAPE it (don't drop the header) so it can't fold into a phantom
      # line of the synthesized HTTP/1 head while STILL SHOWING the tester the injection
      # attempt — a malformed response header is a security finding, not noise to hide. gori
      # is a security-testing proxy: it must surface bad bytes, not silently swallow them.
      private def self.visualize_field(s : String) : String
        return s unless s.includes?('\r') || s.includes?('\n')
        s.gsub('\r', "\\r").gsub('\n', "\\n")
      end

      private def self.ack(io : IO, type : Frame::Type, payload : Bytes) : Nil
        io.write(Frame::Header.new(type.value, Frame::ACK, 0_u32, payload).to_bytes)
        io.flush
      end

      # WINDOW_UPDATE crediting `increment` bytes back to `stream_id` (0 = connection-
      # level). The reserved high bit stays clear (increment is a small frame size).
      private def self.window_update(io : IO, stream_id : UInt32, increment : Int32) : Nil
        return if increment <= 0
        payload = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(increment.to_u32, payload)
        io.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, stream_id, payload).to_bytes)
        io.flush
      rescue
        # The origin may have already closed (e.g. a truncated response) — crediting a
        # window we no longer need is moot; the next Frame.read sees the EOF and ends
        # the loop. Don't let a dead-socket write fail an otherwise-usable response.
      end

      private def self.parse_request(request : Bytes, scheme : String, host : String,
                                     port : Int32) : {Array({String, String}), Bytes?}
        head_bytes, body = split_head_body(request)
        lines = String.new(head_bytes).split('\n').map(&.rstrip('\r'))
        parts = (lines[0]? || "GET / HTTP/2").split(' ')
        method = parts[0]? || "GET"
        path = parts[1]? || "/"

        headers = [{":method", method}, {":path", path}, {":scheme", scheme},
                   {":authority", authority(host, port, scheme)}]
        lines[1..]?.try &.each do |line|
          next if line.empty?
          colon = line.index(':')
          next unless colon && colon > 0
          name = line[0...colon].strip.downcase
          next if FORBIDDEN.includes?(name)
          headers << {name, line[(colon + 1)..].strip}
        end
        {headers, body}
      end

      private def self.authority(host : String, port : Int32, scheme : String) : String
        default = scheme == "https" ? 443 : 80
        # An IPv6 literal host must be bracketed in the :authority pseudo-header, else the
        # colons collide with the port separator and a strict server rejects the stream
        # (mirrors FlowRequest.build_target's h1 bracketing).
        h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        port == default ? h : "#{h}:#{port}"
      end

      # Split at the first CRLFCRLF (head/body boundary); the editor always joins
      # lines with CRLF, so the blank line is exact.
      private def self.split_head_body(bytes : Bytes) : {Bytes, Bytes?}
        i = 0
        while i + 3 < bytes.size
          if bytes[i] == 0x0d && bytes[i + 1] == 0x0a && bytes[i + 2] == 0x0d && bytes[i + 3] == 0x0a
            body = i + 4 < bytes.size ? bytes[(i + 4)..] : nil
            return {bytes[0...i], body}
          end
          i += 1
        end
        {bytes, nil}
      end

      private def self.header_block(frame : Frame::Header) : Bytes
        payload = frame.payload
        offset = 0
        pad = 0
        if frame.padded?
          return Bytes.empty if payload.empty?
          pad = payload[0].to_i
          offset = 1
        end
        offset += 5 if frame.priority?
        finish = payload.size - pad
        finish <= offset ? Bytes.empty : payload[offset...finish]
      end

      private def self.data_block(frame : Frame::Header) : Bytes
        return frame.payload unless frame.padded?
        return Bytes.empty if frame.payload.empty?
        pad = frame.payload[0].to_i
        finish = frame.payload.size - pad
        finish <= 1 ? Bytes.empty : frame.payload[1...finish]
      end

      private def self.synth_head(status : Int32, headers : Array({String, String})) : Bytes
        String.build do |io|
          io << "HTTP/2 " << status << "\r\n"
          headers.each { |(n, v)| io << n << ": " << v << "\r\n" }
          io << "\r\n"
        end.to_slice
      end

      private def self.failure(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), nil, nil, elapsed(started), message)
      end

      # A nil socket here means no usable HTTP/2 connection — could be unreachable,
      # an origin that doesn't offer h2 over ALPN, or (for verified https) a cert that
      # failed verification. Spell that out instead of a bare "connect failed".
      private def self.connect_error(scheme : String, host : String, port : Int32, verify : Bool) : String
        base = "h2 connect failed (no h2 negotiated): #{host}:#{port}"
        if scheme == "https" && verify
          "#{base} — host unreachable, the origin doesn't offer HTTP/2 via ALPN, or its TLS certificate failed verification"
        else
          "#{base} — host unreachable or the origin doesn't offer HTTP/2 (h2c) here"
        end
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end
    end
  end
end
