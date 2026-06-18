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
    # PING answered, no flow control beyond the default 64 KiB window (large
    # request bodies could stall — fine for the manual workbench).
    module H2Engine
      MAX_FRAME = 16384

      private alias Frame = Proxy::H2::Frame
      private alias HPACK = Proxy::H2::HPACK

      # Request headers that are connection-specific and illegal in h2 (RFC 7540
      # §8.1.2.2); `host` is replaced by `:authority`.
      FORBIDDEN = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "host"}

      def self.send(request : Bytes, *, scheme : String, host : String, port : Int32,
                    verify_upstream : Bool) : Result
        started = Time.instant
        upstream = open(scheme, host, port, verify_upstream)
        return failure("h2 connect failed (no h2 negotiated): #{host}:#{port}", started) unless upstream
        begin
          headers, body = parse_request(request, scheme, host, port)
          write_request(upstream, headers, body)
          status, resp_headers, resp_body = read_response(upstream)
          return failure("no h2 response from #{host}:#{port}", started) if status == 0 && resp_headers.empty?
          head = synth_head(status, resp_headers)
          resp = Proxy::Codec::Http1.parse_response_head(head)
          Result.new(head, resp_body, resp, elapsed(started))
        rescue ex
          failure(ex.message || "h2 replay error", started)
        ensure
          upstream.close rescue nil
        end
      end

      private def self.open(scheme : String, host : String, port : Int32, verify : Bool) : IO?
        if scheme == "https"
          ssl = Proxy::Upstream.dial_tls(host, port, verify: verify, alpn: "h2")
          return nil unless ssl
          # Origin completed the handshake but won't speak h2 — close the live
          # socket before bailing, else it leaks (it's never returned to `ensure`).
          unless ssl.alpn_protocol == "h2"
            ssl.close rescue nil
            return nil
          end
          ssl
        else
          Proxy::Upstream.dial(host, port) # h2c prior-knowledge
        end
      end

      private def self.write_request(io : IO, headers : Array({String, String}), body : Bytes?) : Nil
        io.write(Frame::PREFACE)
        io.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
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

      # Reads frames until stream 1 closes; returns {status, headers, body}.
      private def self.read_response(io : IO) : {Int32, Array({String, String}), Bytes?}
        decoder = HPACK::Decoder.new
        header_buf = IO::Memory.new
        body = IO::Memory.new
        headers = [] of {String, String}
        status = 0
        done = false

        until done
          frame = Frame.read(io)
          break if frame.nil?
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
            header_buf.write(header_block(frame))
            status = absorb(header_buf, decoder, headers, status) if frame.end_headers?
            done = true if frame.end_stream?
          when Frame::Type::Continuation
            next unless frame.stream_id == 1
            header_buf.write(frame.payload)
            status = absorb(header_buf, decoder, headers, status) if frame.end_headers?
          when Frame::Type::Data
            next unless frame.stream_id == 1
            body.write(data_block(frame))
            done = true if frame.end_stream?
          else
            # WINDOW_UPDATE / PUSH_PROMISE / PRIORITY — ignored for a one-shot
          end
        end

        {status, headers, body.size == 0 ? nil : body.to_slice}
      end

      # Decode a completed header block, splitting :status from regular headers.
      private def self.absorb(buf : IO::Memory, decoder : HPACK::Decoder,
                              headers : Array({String, String}), status : Int32) : Int32
        decoder.decode(buf.to_slice).each do |(name, value)|
          if name == ":status"
            status = value.to_i? || status
          elsif !name.starts_with?(':')
            headers << {name, value}
          end
        end
        buf.clear
        status
      end

      private def self.ack(io : IO, type : Frame::Type, payload : Bytes) : Nil
        io.write(Frame::Header.new(type.value, Frame::ACK, 0_u32, payload).to_bytes)
        io.flush
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
        port == default ? host : "#{host}:#{port}"
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

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end
    end
  end
end
