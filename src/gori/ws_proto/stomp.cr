require "./frame"

module Gori
  module WsProto
    # STOMP — the text framing behind every SockJS/WebSocket message broker (Spring's
    # `@MessageMapping`, ActiveMQ, RabbitMQ's Web-STOMP).
    #
    #   SEND\n
    #   destination:/app/chat\n
    #   content-type:application/json\n
    #   \n
    #   {"body":"hi"}\0
    #
    # A command line from a CLOSED set, `name:value` headers, a blank line, a body, and a NUL
    # terminator. Both halves are required to enable the decoder: an uppercase word at the
    # start of a text frame is common, a NUL byte at the end of one is not, and together they
    # are unmistakable. One WebSocket frame may carry several frames back to back.
    #
    # `destination` is the routing key — the subscribe/send target an authorization gap hides
    # behind — so it is what lands in `name`.
    module Stomp
      extend self

      NAME  = "stomp"
      LABEL = "STOMP"

      # RFC-defined commands, client and server. Anything else is not a STOMP frame; there is
      # deliberately no "looks like a word in caps" fallback.
      COMMANDS = {
        "SEND", "SUBSCRIBE", "UNSUBSCRIBE", "BEGIN", "COMMIT", "ABORT", "ACK", "NACK",
        "DISCONNECT", "CONNECT", "STOMP", "CONNECTED", "MESSAGE", "RECEIPT", "ERROR",
      }

      # STOMP 1.0 does not escape header values, and 1.1+ exempts CONNECT/CONNECTED/STOMP
      # from escaping for backward compatibility — unescaping those would corrupt a password
      # that legitimately contains a backslash.
      NO_ESCAPE = {"CONNECT", "CONNECTED", "STOMP"}

      # The negotiated subprotocol clients actually send (`v12.stomp`, `v11.stomp`, `v10.stomp`).
      def hinted?(sub : String) : Bool
        sub == "stomp" || sub.ends_with?(".stomp")
      end

      def decode(payload : Bytes) : Array(Decoded)?
        return nil if payload.empty?
        # Both prefilters run on BYTES, before any String is materialised. This decoder is
        # offered every frame of every transcript on every pane rebuild, and one that allocates
        # a copy of each frame only to find out it is not STOMP is exactly the cost
        # `GraphqlWs::QUERY_NEEDLE` exists to avoid — a live socket rebuilds as it grows.
        #
        # A heartbeat is a bare EOL: real STOMP traffic, but one that could be any protocol's
        # whitespace, so it never enables the decoder on its own.
        return [Decoded.new(kind: "heartbeat", strong: false)] if eol_only?(payload)
        return nil unless payload.index(0_u8) # no terminator, no STOMP
        s = String.new(payload).scrub
        last = s.rindex('\0') || return nil
        # Everything after the LAST NUL must be terminator slack (inter-frame EOL/heartbeats);
        # trailing bytes mean the frame was cut or this was never STOMP.
        return nil unless s[(last + 1)..].strip("\r\n").empty?
        frames(s, last)
      rescue
        nil
      end

      # The frames one WebSocket message packs, back to back. A bounded scan rather than
      # `split`, so a message of nothing but NULs cannot materialise a substring per byte
      # before the cap gets a look at it.
      private def frames(s : String, last : Int32) : Array(Decoded)?
        out = [] of Decoded
        pos = 0
        while out.size < MAX_RECORDS && pos <= last
          idx = s.index('\0', pos) || break
          chunk = s[pos, idx - pos].lstrip("\r\n") # heartbeats sent between frames
          pos = idx + 1
          next if chunk.empty?
          out << (frame(chunk) || return nil)
        end
        out << WsProto.truncated if out.size == MAX_RECORDS && pos <= last
        out.empty? ? nil : out
      end

      private def frame(chunk : String) : Decoded?
        nl = chunk.index('\n') || return nil
        command = chunk[0, nl].rstrip('\r')
        return nil unless COMMANDS.includes?(command)
        escaped = !NO_ESCAPE.includes?(command)
        headers = [] of {String, String}
        lines = chunk[(nl + 1)..].split('\n')
        body_at = lines.size
        lines.each_with_index do |raw, i|
          line = raw.rstrip('\r')
          if line.empty?
            body_at = i + 1
            break
          end
          ci = line.index(':') || return nil
          headers << {unescape(line[0, ci], escaped), unescape(line[(ci + 1)..], escaped)}
        end
        body = body_at < lines.size ? lines[body_at..].join('\n') : ""
        id, id_from = correlation(headers)
        Decoded.new(kind: command, name: header(headers, "destination"),
          id: id, note: id_from, payload: render(headers, body))
      end

      private def eol_only?(payload : Bytes) : Bool
        payload.each { |b| return false unless b == 0x0a_u8 || b == 0x0d_u8 }
        true
      end

      private def header(headers : Array({String, String}), name : String) : String?
        headers.each { |(k, v)| return v if k == name }
        nil
      end

      # Whichever id this command correlates on — the one an operator needs to tie a
      # SUBSCRIBE to the MESSAGEs it produced, or a SEND to its RECEIPT — plus WHICH header
      # carried it, because `id`, `receipt-id` and `message-id` are different claims and a bare
      # number in the pane would flatten them into one.
      private def correlation(headers : Array({String, String})) : {String?, String?}
        {"id", "receipt", "receipt-id", "message-id", "subscription", "transaction"}.each do |k|
          if v = header(headers, k)
            return {v, k == "id" ? nil : k}
          end
        end
        {nil, nil}
      end

      # Headers then a blank line then the body — the frame minus its command line and NUL,
      # which the header already names. Headers are shown because in STOMP they ARE the
      # request: `ack`, `receipt`, `content-type` and every broker-specific selector.
      private def render(headers : Array({String, String}), body : String) : String?
        return body.presence if headers.empty?
        rendered = headers.join('\n') { |(k, v)| "#{k}: #{v}" }
        body.empty? ? rendered : "#{rendered}\n\n#{body}"
      end

      # STOMP 1.2 header escaping. An UNDEFINED escape is a protocol error the spec says to
      # fail the connection on; a display-time lens has no connection to fail, so it keeps the
      # bytes verbatim rather than inventing a character the sender did not send.
      private def unescape(s : String, escaped : Bool) : String
        return s unless escaped && s.includes?('\\')
        String.build do |io|
          i = 0
          chars = s.chars
          while i < chars.size
            c = chars[i]
            if c == '\\' && i + 1 < chars.size
              case chars[i + 1]
              when 'n'  then io << '\n'
              when 'r'  then io << '\r'
              when 'c'  then io << ':'
              when '\\' then io << '\\'
              else           io << c << chars[i + 1]
              end
              i += 2
            else
              io << c
              i += 1
            end
          end
        end
      end
    end
  end
end
