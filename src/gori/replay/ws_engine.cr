require "base64"
require "digest/sha1"
require "../proxy/upstream"
require "../proxy/codec/http1"
require "../proxy/ws/frame"
require "./flow_request"

module Gori
  module Replay
    # Re-establishes a WebSocket session to an origin and replays recorded
    # client→server messages, capturing the server's responses. Unlike Engine /
    # H2Engine (one request → one buffered response), this does the HTTP/1.1
    # upgrade handshake, then a scripted exchange: send each outbound message as a
    # masked client frame, then drain inbound frames until the server sends Close
    # or goes idle. One-shot and sequential — it does NOT interleave per-message
    # request/response, and it strips permessage-deflate from the handshake (so a
    # session originally captured WITH compression replays its stored payloads
    # uncompressed; edit the messages, or expect garbage for compressed binaries).
    module WsEngine
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" # RFC 6455 §1.3 accept magic

      DEFAULT_IDLE      = 3.seconds           # gap of server silence that ends the drain
      HANDSHAKE_TIMEOUT = 15.seconds          # generous read bound for the connect + 101 upgrade
      MAX_RECV_MESSAGES = 1000                # cap captured server messages (anti-flood)
      MAX_RECV_BYTES    = 8_i64 * 1024 * 1024 # cap total captured server payload bytes
      MAX_DRAIN_FRAMES  = 100_000             # hard ceiling on frames processed (ping/empty-fragment flood)
      MAX_CONTROL_BYTES =     125             # RFC 6455 §5.5: control-frame payload limit (caps Pong echo)

      # An outbound message to replay (opcode 1=text, 2=binary).
      record OutMsg, opcode : Int32, payload : Bytes

      # One message in the replayed transcript. `direction` is "out" (we sent) or
      # "in" (server sent); opcode 1=text, 2=binary.
      record Message, direction : String, opcode : Int32, payload : Bytes

      struct Result
        getter handshake_head : Bytes # the server's upgrade response head (empty on connect failure)
        getter messages : Array(Message)
        getter duration_us : Int64
        getter error : String? # a real failure (no connection / no upgrade / IO error)
        getter note : String?  # a non-fatal advisory (e.g. handshake accept mismatch)
        getter close_code : Int32?
        getter? upgraded : Bool

        def initialize(@handshake_head, @messages, @duration_us, @error = nil,
                       @note = nil, @close_code = nil, @upgraded = false)
        end

        def ok? : Bool
          @error.nil?
        end
      end

      def self.send(upgrade_request : Bytes, out_messages : Array(OutMsg), *,
                    scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    idle : Time::Span = DEFAULT_IDLE) : Result
        started = Time.instant
        # The connect + handshake reads get a generous io_timeout so a slow-but-valid
        # upgrade (cold start / auth / slow proxy) isn't mistaken for a dead origin;
        # the read_timeout is narrowed to `idle` only once we enter the drain, where a
        # read that times out is the EXPECTED "server went quiet → stop" signal.
        ht = HANDSHAKE_TIMEOUT
        upstream = scheme == "https" ? Proxy::Upstream.dial_tls(host, port, verify: verify_upstream, sni: sni, io_timeout: ht) : Proxy::Upstream.dial(host, port, io_timeout: ht)
        return err("connect failed: #{host}:#{port}", started) unless upstream

        begin
          handshake, key = build_handshake(upgrade_request)
          upstream.write(handshake)
          upstream.flush
          head = Proxy::Codec::Http1.read_head(upstream)
          return err("no response from #{host}:#{port}", started) unless head

          resp = Proxy::Codec::Http1.parse_response_head(head)
          unless resp.status == 101
            return Result.new(head, [] of Message, elapsed(started),
              error: "server did not upgrade (status #{resp.status})", upgraded: false)
          end
          note = verify_accept(resp, key)

          messages = [] of Message
          # Send all recorded outbound messages first (masked client frames).
          out_messages.each do |m|
            op = m.opcode == 2 ? Proxy::WS::OP_BIN : Proxy::WS::OP_TEXT
            upstream.write(Proxy::WS.encode(op, m.payload, mask: true))
            messages << Message.new("out", op.to_i, m.payload)
          end
          upstream.flush

          # Narrow the read bound: a drain gap of `idle` now ends it. (Both socket
          # types respond; responds_to? keeps the union's IO type happy.)
          upstream.read_timeout = idle if upstream.responds_to?(:read_timeout=)
          close_code = drain(upstream, messages)
          send_close(upstream)
          Result.new(head, messages, elapsed(started), note: note,
            close_code: close_code, upgraded: true)
        rescue ex
          err(ex.message || "ws replay error", started)
        ensure
          upstream.close rescue nil
        end
      end

      # Read inbound frames until the server sends Close, goes idle (read timeout),
      # or a cap trips. Reassembles fragmented data messages; answers Ping with a
      # Pong. Returns the close status code if the server framed one.
      private def self.drain(io : IO, messages : Array(Message)) : Int32?
        assembling = IO::Memory.new
        msg_opcode = Proxy::WS::OP_TEXT
        recv_bytes = 0_i64
        recv_count = 0
        frames = 0
        loop do
          # Count EVERY frame, not just completed messages: an origin flooding pings or
          # empty/non-fin fragments faster than `idle` trips neither the data caps nor
          # the read timeout, so this frame ceiling is what guarantees termination.
          frame = begin
            Proxy::WS.read_frame(io)
          rescue IO::TimeoutError
            break # server idle for `idle` → done
          end
          break if frame.nil? # EOF / truncated
          frames += 1
          break if frames > MAX_DRAIN_FRAMES

          if frame.data?
            msg_opcode = frame.opcode if frame.opcode != Proxy::WS::OP_CONT
            assembling.write(frame.payload)
            break if assembling.bytesize > MAX_RECV_BYTES # runaway fragmented message
            if frame.fin?
              payload = assembling.to_slice.dup
              recv_bytes += payload.size
              recv_count += 1
              messages << Message.new("in", msg_opcode.to_i, payload)
              assembling = IO::Memory.new
              break if recv_count >= MAX_RECV_MESSAGES || recv_bytes >= MAX_RECV_BYTES
            end
          elsif frame.opcode == Proxy::WS::OP_PING
            send_pong(io, frame.payload)
          elsif frame.close?
            return close_status(frame.payload)
          end
        end
        nil
      end

      # Echo a Ping as a masked Pong, but never amplify: a control frame's payload is
      # ≤125 bytes (RFC 6455 §5.5), so clamp a hostile oversized ping before reflecting.
      private def self.send_pong(io : IO, ping_payload : Bytes) : Nil
        pong = ping_payload.size > MAX_CONTROL_BYTES ? ping_payload[0, MAX_CONTROL_BYTES] : ping_payload
        io.write(Proxy::WS.encode(Proxy::WS::OP_PONG, pong, mask: true))
        io.flush
      end

      # 2-byte big-endian status code at the start of a Close payload, if present.
      private def self.close_status(payload : Bytes) : Int32?
        return nil if payload.size < 2
        (payload[0].to_i << 8) | payload[1].to_i
      end

      # Best-effort Close (1000 Normal) so the server tears down cleanly.
      private def self.send_close(io : IO) : Nil
        io.write(Proxy::WS.encode(Proxy::WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: true)) # 1000
        io.flush
      rescue
        # socket already gone — nothing to close gracefully
      end

      # Rebuilds the upgrade request for replay: origin-form request line, a FRESH
      # Sec-WebSocket-Key (avoids any server replay-guard), and Sec-WebSocket-
      # Extensions stripped (no permessage-deflate → frames are plain). Everything
      # else (Host, Cookie, Authorization, Origin, …) is kept so the replay carries
      # the original session. Header VALUE bytes are copied verbatim (only the ASCII
      # request line + header NAMES are decoded) so a non-UTF-8-bearing cookie/auth
      # token survives byte-exact, mirroring FlowRequest.origin_form_bytes. Returns
      # {request bytes, the key we sent}.
      private def self.build_handshake(head : Bytes) : {Bytes, String}
        lines = head_lines(head)
        key = Base64.strict_encode(Random::Secure.random_bytes(16))

        io = IO::Memory.new(head.size + 64)
        req_line = lines.empty? ? "GET / HTTP/1.1" : String.new(lines[0])
        io << (Replay::FlowRequest.rewrite_request_line(req_line) || req_line) << "\r\n"
        lines[1..].each do |line|
          next if line.empty?
          name = header_name(line)
          next if name == "sec-websocket-key" || name == "sec-websocket-extensions"
          io.write(line) # value bytes verbatim (never round-tripped through String)
          io << "\r\n"
        end
        io << "Sec-WebSocket-Key: " << key << "\r\n"
        io << "\r\n"
        {io.to_slice, key}
      end

      # Splits a head into its lines (LF-delimited, trailing CR stripped per line) as
      # raw byte slices — no String round-trip — dropping the trailing blank line(s).
      private def self.head_lines(head : Bytes) : Array(Bytes)
        lines = [] of Bytes
        start = 0
        head.each_with_index do |b, i|
          next unless b == 0x0A_u8 # LF
          lines << strip_cr(head[start, i - start])
          start = i + 1
        end
        lines << strip_cr(head[start, head.size - start]) if start < head.size
        while !lines.empty? && lines.last.empty?
          lines.pop
        end
        lines
      end

      private def self.strip_cr(line : Bytes) : Bytes
        line.size > 0 && line[line.size - 1] == 0x0D_u8 ? line[0, line.size - 1] : line
      end

      # The (ASCII) header field name — the bytes before the first ':' — lower-cased
      # for the strip comparison. Only the NAME is decoded; the value stays bytes.
      private def self.header_name(line : Bytes) : String
        ci = line.index(0x3A_u8) # ':'
        String.new(ci ? line[0, ci] : line).strip.downcase
      end

      # The server's Sec-WebSocket-Accept must be base64(sha1(key + GUID)). A
      # mismatch is surfaced as a non-fatal note (the frames still relayed), since
      # a quirky/misbehaving origin shouldn't abort an otherwise-useful capture.
      private def self.verify_accept(resp : Proxy::Codec::RawResponse, key : String) : String?
        got = resp.headers.get?("Sec-WebSocket-Accept")
        return nil unless got
        want = Base64.strict_encode(Digest::SHA1.digest(key + GUID))
        got == want ? nil : "handshake accept mismatch (got #{got.inspect}, want #{want.inspect})"
      end

      private def self.err(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), [] of Message, elapsed(started), error: message)
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end
    end
  end
end
