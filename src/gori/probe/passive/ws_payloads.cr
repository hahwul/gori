require "./rule"
require "./secrets"

module Gori
  module Probe
    module Passive
      # WebSocket payload secrets (category "infoleak"). Scans captured post-101 messages (both
      # directions) with the same high-confidence credential shapes as BodyLeaks — evidence is the
      # TYPE label only, never the matched value.
      #
      # BINARY frames are scanned too, which reverses an earlier decision (a spec asserted "binary
      # frames are ignored" without recording why). protobuf / msgpack / CBOR over WebSocket is the
      # mainstream encoding for realtime APIs, and a token rides in such a frame as an ordinary
      # ASCII string field — so ignoring them was a straight false negative on the very transport
      # this rule exists for. No deframing is needed and none is done: every shape in
      # `Secrets::PATTERNS` is a literal ASCII vendor prefix plus a fixed-charset tail, which
      # survives the projection below intact.
      class WsPayloads < Rule
        def info : RuleInfo
          RuleInfo.new("ws_payloads", "WebSocket payload secrets",
            "Scans WebSocket text and binary frames for exposed secrets.",
            Category::INFOLEAK)
        end

        MSG_CAP = 64 * 1024 # per-message ceiling (mirrors Context::BODY_CAP)

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return if ctx.ws_messages.empty?
          seen = Set(String).new # distinct type labels per flow (avoid ×N from echo/repeater)
          jwt_seen = false
          ctx.ws_messages.each do |msg|
            # Control frames (ping/pong/close) carry no application payload, and a `notice?` row is
            # gori's own "[gori] …" advisory — scanning either would be scanning ourselves. Every
            # other opcode, text or binary, is application data.
            next if msg.control? || msg.notice?
            text = payload_text(msg.payload, msg.text?)
            next if text.nil? || text.empty?
            Secrets::PATTERNS.each do |(pat, label)|
              next if seen.includes?(label)
              next unless pat.matches?(text)
              seen << label
              acc << Detection.new("secret_in_ws", Category::INFOLEAK, ctx.host, ctx.url,
                "Credential/secret disclosed in WebSocket message", Store::Severity::High,
                label, ctx.fid)
            end
            # Reported apart from the High shapes above: a socket carrying the session token it
            # was authenticated with is the normal design, not a leak (see Secrets::JWT).
            if !jwt_seen && Secrets::JWT[0].matches?(text)
              jwt_seen = true
              acc << Detection.new("jwt_in_ws", Category::INFOLEAK, ctx.host, ctx.url,
                "JSON Web Token in a WebSocket message", Store::Severity::Info, nil, ctx.fid)
            end
          end
        end

        # Scannable text for one frame, capped at MSG_CAP.
        #
        # A TEXT frame is declared UTF-8, so `scrub` is the right repair and keeps the payload
        # readable. A BINARY frame is not, and scrub is the wrong tool for it twice over: it
        # EXPANDS each invalid byte to a 3-byte U+FFFD, so a 64 KiB frame would allocate ~192 KiB
        # per message on the fiber the passive scan shares with the proxy, and it would do that
        # for every frame of a chatty socket.
        #
        # The projection below is size-preserving, always valid UTF-8, and LOSSLESS for the shapes
        # this rule matches: every pattern is pure ASCII, and mapping a non-ASCII byte to a space
        # creates a `\b` boundary — which is correct, because no credential token spans one. Same
        # shape as `CustomRule#safe_evidence`.
        private def payload_text(payload : Bytes, text_frame : Bool) : String?
          return nil if payload.empty?
          bytes = payload[0, {payload.size, MSG_CAP}.min]
          return String.new(bytes).scrub if text_frame
          # Mapped over a byte slice rather than char-by-char into a String::Builder: the result is
          # ASCII by construction, so `String.new` on it is valid UTF-8 without a second pass, and
          # this skips one virtual IO dispatch per byte (a 64 KiB frame is 65_536 of them).
          projected = Bytes.new(bytes.size) do |i|
            b = bytes[i]
            0x20_u8 <= b <= 0x7e_u8 ? b : 0x20_u8
          end
          String.new(projected)
        end
      end
    end
  end
end
