require "base64"
require "digest/sha1"
require "../proxy/upstream"
require "../proxy/codec/http1"
require "../proxy/ws/frame"
require "./flow_request"

module Gori
  module Repeater
    # Re-establishes a WebSocket session to an origin and repeaters recorded
    # client→server messages, capturing the server's responses. Unlike Engine /
    # H2Engine (one request → one buffered response), this does the HTTP/1.1
    # upgrade handshake, then a scripted exchange: send each outbound message as a
    # masked client frame, then drain inbound frames until the server sends Close
    # or goes idle.
    #
    # Two deliberate limitations of this simplified repeater:
    #  - Sequential, not interleaved: ALL recorded client→server messages are sent
    #    first, then the server's responses are drained. A protocol that depends on
    #    per-message request/response interleaving will not repeater faithfully.
    #  - No permessage-deflate: the handshake omits the extension, AND the live
    #    capture relay stores frame payloads verbatim without decompressing them. So
    #    a session captured over a compressed connection holds COMPRESSED bytes;
    #    replaying them to a server that isn't negotiating deflate sends undecodable
    #    input (and compressed server frames likewise can't be read). To repeater such
    #    a session, capture it with compression disabled in the browser.
    module WsEngine
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" # RFC 6455 §1.3 accept magic

      DEFAULT_IDLE      = 3.seconds           # gap of server silence that ends the drain
      HANDSHAKE_TIMEOUT = 15.seconds          # generous read bound for the connect + 101 upgrade
      MAX_RECV_MESSAGES = 1000                # cap captured server messages (anti-flood)
      MAX_RECV_BYTES    = 8_i64 * 1024 * 1024 # cap total captured server payload bytes
      MAX_DRAIN_FRAMES  = 100_000             # hard ceiling on frames processed (ping/empty-fragment flood)
      DRAIN_DEADLINE    = 60.seconds          # wall-clock ceiling: a sub-idle ping/fragment cadence can't pin a tab for hours
      MAX_CONTROL_BYTES = 125                 # RFC 6455 §5.5: control-frame payload limit (caps Pong echo)
      # Ping/pong rows kept in the transcript. A server's control frames were dropped
      # entirely, which is why a CLOSE reason and a PING payload never reached the operator —
      # but `recv_count` bounds DATA messages only, so an origin pinging under the idle
      # timeout would grow the transcript to MAX_DRAIN_FRAMES rows of keepalive. A CLOSE is
      # exempt from this: there is at most one, and it is the row that matters.
      MAX_CONTROL_MESSAGES = 64

      # A request head declares a WebSocket upgrade. Matches the `Upgrade: websocket`
      # header case-insensitively (RFC 6455: the token is case-insensitive; browsers
      # send lowercase, but `Upgrade: WebSocket` and no-space forms are equally valid),
      # tolerating flexible whitespace after the colon. The single source of truth for
      # "is this repeater a WebSocket flow?" across the TUI restore paths and MCP tools.
      UPGRADE_HEADER = /(?:^|\n)upgrade:[ \t]*websocket/i

      def self.upgrade_request?(request : String) : Bool
        # scrub: `request` is a captured request head+body kept byte-exact (never scrubbed, P7);
        # an obs-text byte in a header value would make PCRE matches? raise. This is a read-only
        # classification (the request is never re-sent from it), so scrub is lossless and fixes
        # all callers (cli/run.cr's `gori run` path is otherwise unrescued).
        request.scrub.matches?(UPGRADE_HEADER)
      end

      # An outbound message to resend. `opcode` is the RFC 6455 opcode as-is — 0 CONT,
      # 1 TEXT, 2 BIN, 8 CLOSE, 9 PING, 10 PONG, and anything else the operator names — and
      # `shape` carries FIN, the RSV nibble, the masking decision and a declared length that
      # may disagree with the payload.
      #
      # The engine used to fold every message to `opcode == 2 ? OP_BIN : OP_TEXT`, FIN=1,
      # RSV=0, masked with a fresh key. That is one frame shape out of the dozen a WebSocket
      # test needs, so a captured session of twelve distinct shapes replayed as seven
      # identical ones and the difference was never reported.
      #
      # `evidence` is PROVENANCE, the same axis `Repeater::PlanOptions#evidence?` carries for
      # the HTTP half: true when these bytes were CAPTURED (a session seeded from a flow),
      # false when the operator typed them here and now (`--message`, MCP `messages`, a line
      # added to the pane). It is per-message and not per-send because the two populations mix
      # in one list — `--message` overrides a seed, and the TUI pane is a splice over one.
      #
      # A captured frame is replayed as recorded or not at all. `{"$where":"this.a==1"}` is a
      # MongoDB injection test, `{"$ref":…}` is a JSON-Schema document and `$filter` is OData;
      # with the draft policy on, the capture was unreplayable without project env vars, and
      # taking the refusal's own advice sent `{"WHEREVAL":"this.a==1"}` — a JSON object with a
      # key nobody wrote, in place of the payload the whole test was about.
      record OutMsg, opcode : Int32, payload : Bytes,
        shape : Proxy::WS::Shape = Proxy::WS::Shape::DEFAULT,
        evidence : Bool = false

      # One message in the replayed transcript. `direction` is "out" (we sent) or
      # "in" (server sent); `opcode` is the RFC 6455 opcode, no longer folded to 1 or 2.
      #
      # `shape` says how the frame was FRAMED. On an "out" row that is what gori put on the
      # wire — including a FIN the operator cleared, RSV bits they set, a mask key they
      # pinned, and a declared length that disagrees with the payload — so the transcript can
      # be read as evidence instead of being taken on trust. On an "in" row it is the first
      # frame's header as it arrived.
      record Message, direction : String, opcode : Int32, payload : Bytes,
        shape : Proxy::WS::Shape = Proxy::WS::Shape::DEFAULT

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
                    idle : Time::Span = DEFAULT_IDLE,
                    overrides : Gori::HostOverrides? = nil,
                    keep_key : Bool = false) : Result
        started = Time.instant
        # The connect + handshake reads get a generous io_timeout so a slow-but-valid
        # upgrade (cold start / auth / slow proxy) isn't mistaken for a dead origin;
        # the read_timeout is narrowed to `idle` only once we enter the drain, where a
        # read that times out is the EXPECTED "server went quiet → stop" signal.
        ht = HANDSHAKE_TIMEOUT
        tls = scheme == "https" || scheme == "wss"
        # `*_result` rather than the socket-only dial: a WebSocket target fails to come up for
        # exactly the reasons every other send path fails, and `Engine.connect_error` is where
        # those sentences live. Dropping the `DialError` here left this one surface saying
        # "connect failed: host:port" for an untrusted certificate, a plaintext port and an
        # origin that accepts the connection and then goes silent.
        upstream, dial_error = if tls
                                 Proxy::Upstream.dial_tls_result(host, port, verify: verify_upstream, sni: sni, io_timeout: ht, overrides: overrides)
                               else
                                 Proxy::Upstream.dial_result(host, port, io_timeout: ht, overrides: overrides)
                               end
        return err(Engine.connect_error(scheme, host, port, verify_upstream, dial_error), started) unless upstream

        begin
          handshake, keys = build_handshake(upgrade_request, keep_key)
          upstream.write(handshake)
          upstream.flush
          head = Proxy::Codec::Http1.read_head(upstream)
          # `Engine.no_response_error`, not a local copy of the sentence: a plain `ws://` target
          # behind a proxy that answers the CONNECT and then closes without relaying anything is
          # the same shape as the h1 repeater's clean-EOF case, and a hand-duplicated string here
          # would silently miss the proxy-tunnel clause that builder now carries.
          return err(Engine.no_response_error(host, port), started) unless head

          resp = Proxy::Codec::Http1.parse_response_head(head)
          unless resp.status == 101
            return Result.new(head, [] of Message, elapsed(started),
              error: "server did not upgrade (status #{resp.status})", upgraded: false)
          end
          note = verify_accept(resp, keys)

          messages = [] of Message
          # Send all recorded outbound messages first. The opcode goes out AS GIVEN — the
          # `m.opcode == 2 ? OP_BIN : OP_TEXT` fold that used to live here is why a PING, a
          # PONG, a CLOSE with a chosen code and a lone CONT were inexpressible from every
          # surface at once. `mask: true` is still the DEFAULT (§5.3 requires it of a client),
          # but it is now only a default: `shape.masked == false` sends the unmasked client
          # frame that §5.1 says the server must reject, which is the most common WebSocket
          # hardening probe there is.
          out_messages.each do |m|
            op = (m.opcode & 0x0f).to_u8
            upstream.write(Proxy::WS.encode(op, m.payload, m.shape, mask: true))
            messages << Message.new("out", op.to_i, m.payload, m.shape)
          end
          upstream.flush

          # The FIRST inbound read keeps the generous handshake bound (a slow first
          # reply isn't a dead server); drain narrows to `idle` once frames flow.
          sent_count = messages.size
          close_code = drain(upstream, messages, idle)
          # Only when the operator did not send one themselves. §5.5.1 allows exactly one
          # CLOSE per direction, so appending gori's after theirs would put a second one on
          # the wire that they did not ask for — and the second frame, not the first, is what
          # the server would be answering.
          send_close(upstream) unless out_messages.last?.try(&.opcode) == Proxy::WS::OP_CLOSE.to_i
          # The "out" rows above are appended before the flush and with no delivery evidence —
          # WebSocket has no ack, so a transcript row means "gori wrote this", never "the peer
          # got it". When the origin closes right after the 101 the drain breaks at EOF and
          # `send_close` is rescued, so the run reported `upgraded: true`, `error: null` and
          # listed messages the origin never received (verified at the origin: handshake only,
          # no frame). Say so instead. A NOTE and not an error: a one-way protocol that never
          # answers is legitimate, and in both cases the honest statement is the same —
          # delivery is unconfirmed.
          note = with_delivery_note(note, sent_count, messages.size, close_code)
          Result.new(head, messages, elapsed(started), note: note,
            close_code: close_code, upgraded: true)
        rescue ex
          # A failure BEFORE/at the upgrade is a real error; once upgraded, drain swallows
          # mid-exchange IO errors itself, so reaching here means the handshake failed.
          err(ex.message || "ws repeater error", started)
        ensure
          upstream.close rescue nil
        end
      end

      # Append the unconfirmed-delivery advisory to whatever `note` already says. Kept out of
      # `send` so that method's branch count stays where it was.
      private def self.with_delivery_note(note : String?, sent : Int32, total : Int32,
                                          close_code : Int32?) : String?
        return note unless sent > 0 && total == sent && close_code.nil?
        unreplied = "sent #{sent} message(s) but the peer sent no frame and no close — delivery unconfirmed"
        note ? "#{note}; #{unreplied}" : unreplied
      end

      # Read inbound frames until the server sends Close, goes idle (read timeout),
      # or a cap trips. Reassembles fragmented data messages; answers Ping with a
      # Pong. Returns the close status code if the server framed one.
      #
      # Reassembly has THREE moments, not one, and this method used to have only the last:
      #
      #   1. a new data frame arriving while the previous message never sent its FIN — an
      #      RFC 6455 §5.4 violation, and the whole point of pointing a repeater at a server;
      #   2. FIN, the ordinary end of a message;
      #   3. the drain ending with a fragment still unterminated (CLOSE / EOF / idle / a cap).
      #
      # Without 1 the two messages were concatenated, so `TEXT fin=0 "AAA"` then
      # `TEXT fin=1 "BBB"` was reported as one well-formed `AAABBB` that never existed; without
      # 3 an origin that died mid-message left the bytes it did send nowhere at all. The
      # capture relay has had all three since #552 and reported the same origin bytes
      # correctly, so the two surfaces disagreed about the same protocol. `emit_pending` is
      # 1 and 3, `Proxy::WS::MessageShape` is the accumulator both now share, and the flushed
      # fragment carries `fin: false` — gori reports the violation rather than repairing it.
      private def self.drain(io : IO, messages : Array(Message), idle : Time::Span) : Int32?
        assembling = IO::Memory.new
        msg_opcode = Proxy::WS::OP_TEXT
        shape = Proxy::WS::MessageShape.new
        ctl_count = 0
        recv_bytes = 0_i64
        recv_count = 0
        frames = 0
        close_code = nil.as(Int32?)
        started = Time.instant
        loop do
          # Count EVERY frame, not just completed messages: an origin flooding pings or
          # empty/non-fin fragments faster than `idle` trips neither the data caps nor
          # the read timeout, so this frame ceiling is what guarantees termination.
          # A wall-clock deadline also caps total drain time: a steady sub-idle ping cadence
          # stays under MAX_DRAIN_FRAMES yet could otherwise pin the tab "inflight" for hours.
          break if Time.instant - started > DRAIN_DEADLINE
          frame = begin
            Proxy::WS.read_frame(io)
          rescue IO::Error
            break # idle timeout, RST, or broken pipe — end the drain, keep what we have
          end
          break if frame.nil? # EOF / truncated
          frames += 1
          break if frames > MAX_DRAIN_FRAMES
          # After the first frame, narrow the per-read bound to `idle` so a silent gap
          # ends the drain promptly (the first read kept the generous handshake bound).
          narrow_read_timeout(io, idle) if frames == 1

          if frame.data?
            if frame.opcode != Proxy::WS::OP_CONT
              if shape.frames > 0
                # Moment 1: the previous message never FIN'd. Its bytes are the finding, so
                # they get their own row instead of being merged into this one's — and that
                # row counts against the same caps a completed message does. Without the
                # count, an origin that simply never sends a FIN would buy an unbounded
                # transcript: the byte cap lives on `assembling`, which this flush empties.
                recv_count += 1
                recv_bytes += assembling.bytesize
                assembling = emit_pending(messages, assembling, msg_opcode, shape)
                break if recv_caps_hit?(recv_count, recv_bytes)
              end
              msg_opcode = frame.opcode
            end
            shape.note(frame)
            assembling.write(frame.payload)
            break if assembling.bytesize > MAX_RECV_BYTES # runaway fragmented message
            if frame.fin?
              payload = assembling.to_slice.dup
              recv_bytes += payload.size
              recv_count += 1
              # First frame's RSV/mask (§5.2 puts an extension's flags there), last frame's
              # FIN, and how many frames it took — the same accounting the capture relay does,
              # so the two agree about identical bytes.
              messages << Message.new("in", msg_opcode.to_i, payload, shape.take)
              assembling = IO::Memory.new
              break if recv_caps_hit?(recv_count, recv_bytes)
            end
          elsif frame.close?
            # The CLOSE frame itself joins the transcript, not just its status code. The code
            # was already reported; the REASON — the free-text half of §5.5.1, and where a
            # server actually explains itself — was dropped on the floor, and a PING payload
            # (a real covert channel, and a real length-check bug site) with it.
            #
            # A half-assembled message ahead of it is flushed by the post-loop `emit_pending`,
            # so the CLOSE row lands AFTER the fragment the origin sent before it — arrival
            # order, which is the order the relay records the same bytes in. Hence `break`
            # and not `return`: an early return skipped that flush, which is exactly how
            # `TEXT fin=0 "UNTERMINATED"` followed by a CLOSE left the 12 bytes nowhere.
            close_code = close_status(frame.payload)
            assembling = emit_pending(messages, assembling, msg_opcode, shape)
            messages << Message.new("in", frame.opcode.to_i, frame.payload.dup, frame.shape)
            break
          else
            # PING/PONG, bounded: `recv_count` only counts DATA messages, so an origin
            # pinging under the idle timeout would otherwise grow this array until
            # MAX_DRAIN_FRAMES — 100k transcript rows for a keepalive. A CLOSE is exempt
            # above; there is at most one, and it is the row that matters.
            if ctl_count < MAX_CONTROL_MESSAGES
              ctl_count += 1
              messages << Message.new("in", frame.opcode.to_i, frame.payload.dup, frame.shape)
            end
            send_pong(io, frame.payload) if frame.opcode == Proxy::WS::OP_PING
          end
        end
        # Moment 3. Every exit above is a `break`, so this is reached on the idle timeout, on
        # EOF, on a truncated frame, on a cap and on the CLOSE path alike — the same reason
        # `Relay.pump` puts its own flush in an `ensure` rather than at the tail.
        emit_pending(messages, assembling, msg_opcode, shape)
        close_code
      end

      # Whatever fragments are buffered, as ONE message, and a fresh buffer. A no-op when
      # nothing is being reassembled. `fin: false` is the point: the origin never sent the
      # FIN, so gori does not invent one — the row says the message ended unterminated, which
      # is the finding. `shape.frames` and not `assembling.bytesize` decides, because a
      # leading fragment with an empty payload is still a fragment that never ended.
      private def self.emit_pending(messages : Array(Message), assembling : IO::Memory,
                                    opcode : UInt8, shape : Proxy::WS::MessageShape) : IO::Memory
        return assembling if shape.frames == 0
        messages << Message.new("in", opcode.to_i, assembling.to_slice.dup, shape.take)
        IO::Memory.new
      end

      private def self.recv_caps_hit?(count : Int32, bytes : Int64) : Bool
        count >= MAX_RECV_MESSAGES || bytes >= MAX_RECV_BYTES
      end

      # Both socket types respond; responds_to? keeps the union's IO type happy.
      private def self.narrow_read_timeout(io : IO, idle : Time::Span) : Nil
        io.read_timeout = idle if io.responds_to?(:read_timeout=)
      end

      # Echo a Ping as a masked Pong, but never amplify: a control frame's payload is
      # ≤125 bytes (RFC 6455 §5.5), so clamp a hostile oversized ping before reflecting.
      private def self.send_pong(io : IO, ping_payload : Bytes) : Nil
        pong = ping_payload.size > MAX_CONTROL_BYTES ? ping_payload[0, MAX_CONTROL_BYTES] : ping_payload
        io.write(Proxy::WS.encode(Proxy::WS::OP_PONG, pong, mask: true))
        io.flush
      rescue
        # peer gone mid-drain — ignore; the next read ends the drain gracefully
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

      # Rebuilds the upgrade request for repeater: origin-form request line, Sec-WebSocket-
      # Extensions stripped (no permessage-deflate → frames are plain), and — unless
      # `keep_key` — a FRESH Sec-WebSocket-Key. Everything else (Host, Cookie,
      # Authorization, Origin, …) is kept so the repeater carries the original session.
      # Header VALUE bytes are copied verbatim (only the ASCII request line + header NAMES
      # are decoded) so a non-UTF-8-bearing cookie/auth token survives byte-exact, mirroring
      # FlowRequest.origin_form_bytes.
      #
      # Regenerating the key is the DEFAULT and stays the default: a replayed handshake that
      # reuses a captured key looks to a server like a replay, which is what a repeater guard
      # is watching for, and every session that does not ask keeps exactly today's bytes.
      #
      # But the key line was also DELETED and re-appended at the end of the block, so the
      # operator could not send an absent key, a short one, a non-base64 one, two of them, or
      # the same one twice — all handshake tests — and could not control header ORDER either,
      # because their line moved. `keep_key` is the opt-in: their block goes out as written,
      # untouched, key line and position included. It is opt-in rather than the new default
      # because honouring the typed key also means `Sec-WebSocket-Accept` can no longer be
      # asserted (see `verify_accept`), and losing that check silently on every session would
      # trade one blind spot for another.
      #
      # Returns {request bytes, the Sec-WebSocket-Key VALUES actually on the wire}. That is a
      # list and not a String because zero and two are both shapes an operator can now send,
      # and the accept check has to be able to say which it saw.
      private def self.build_handshake(head : Bytes, keep_key : Bool = false) : {Bytes, Array(String)}
        lines = head_lines(head)
        keys = [] of String

        io = IO::Memory.new(head.size + 64)
        req_line = lines.empty? ? "GET / HTTP/1.1" : String.new(lines[0])
        io << (Repeater::FlowRequest.rewrite_request_line(req_line) || req_line) << "\r\n"
        lines[1..].each do |line|
          next if line.empty?
          name = header_name(line)
          next if name == "sec-websocket-extensions"
          if name == "sec-websocket-key"
            next unless keep_key
            keys << header_value(line)
          end
          io.write(line) # value bytes verbatim (never round-tripped through String)
          io << "\r\n"
        end
        unless keep_key
          key = Base64.strict_encode(Random::Secure.random_bytes(16))
          keys << key
          io << "Sec-WebSocket-Key: " << key << "\r\n"
        end
        io << "\r\n"
        {io.to_slice, keys}
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

      # The header field VALUE as the operator wrote it, minus the OWS after the colon.
      # Decoded — this feeds the SHA-1 accept computation, which is defined over the key's
      # characters — but never re-sent: `build_handshake` copies the whole line's bytes.
      private def self.header_value(line : Bytes) : String
        ci = line.index(0x3A_u8) # ':'
        return "" unless ci
        String.new(line[ci + 1, line.size - ci - 1]).strip
      end

      # The server's Sec-WebSocket-Accept must be base64(sha1(key + GUID)) (RFC 6455 §4.2.2).
      # A mismatch is surfaced as a non-fatal note (the frames still relayed), since a
      # quirky/misbehaving origin shouldn't abort an otherwise-useful capture.
      #
      # Every branch here says something. The old body opened `return nil unless got` — a
      # server that upgraded with NO accept header at all produced the same silence as a
      # server that answered correctly, which is precisely backwards: the missing header is
      # the finding. And with `keep_key` an operator can now send zero keys or two, at which
      # point there is no single key to derive an expected accept from — so that case reports
      # that it cannot check, rather than quietly not checking.
      private def self.verify_accept(resp : Proxy::Codec::RawResponse, keys : Array(String)) : String?
        got = resp.headers.get?("Sec-WebSocket-Accept")
        if keys.size != 1
          sent = keys.empty? ? "no Sec-WebSocket-Key" : "#{keys.size} Sec-WebSocket-Key headers"
          return "handshake accept NOT verified: the request carried #{sent}, so there is no " \
                 "single key to derive one from (the server answered #{got ? got.inspect : "none"})"
        end
        want = Base64.strict_encode(Digest::SHA1.digest(keys[0] + GUID))
        unless got
          return "handshake accept MISSING: the server sent 101 with no Sec-WebSocket-Accept " \
                 "header (RFC 6455 §4.2.2 requires #{want.inspect})"
        end
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
