require "json"
require "./frame"

module Gori
  module WsProto
    # Socket.IO over Engine.IO — the framing behind `42["chat",{…}]`.
    #
    # Two envelopes stacked, both spelled as leading ASCII digits:
    #
    #   <engine.io type><socket.io type>[<attachments>-][<namespace>,][<ack id>]<json>
    #        4                 2                                                ["chat",{…}]
    #
    # Engine.IO carries the transport (open / close / ping / pong / message / upgrade / noop);
    # only its `4` (message) frames carry a Socket.IO packet. The namespace is present only
    # when it is not `/`, and the ack id only when the sender wants one back — so the parse is
    # a strict left-to-right consume, and anything left over that is not the packet's JSON
    # means this was never a Socket.IO frame.
    #
    # ## What may ENABLE the decoder
    #
    # A bare `2` (ping) or `40` (connect, default namespace, no auth) is one or two ASCII
    # digits. In a chat protocol that sends numeric ids as text those are ordinary messages,
    # so they decode `strong: false` and cannot switch this decoder on by themselves — see
    # `WsProto::Decoded`. An `42[…]` event, a `0{"sid":…}` handshake or a namespaced connect
    # is unmistakable and does.
    module SocketIo
      extend self

      NAME  = "socketio"
      LABEL = "Socket.IO"

      # Engine.IO packet types that carry no Socket.IO packet and no payload.
      ENGINE_BARE = {'1' => "close", '5' => "upgrade", '6' => "noop"}

      # Socket.IO is negotiated on the URL (`/socket.io/?EIO=4&transport=websocket`), not by
      # subprotocol — but a gateway that fronts it sometimes names it, so the hint is honoured
      # when it is there and never needed when it is not.
      def hinted?(sub : String) : Bool
        sub == "socket.io" || sub.starts_with?("socket.io")
      end

      def decode(payload : Bytes) : Array(Decoded)?
        return nil if payload.empty?
        b = payload.unsafe_fetch(0)
        return nil unless b >= '0'.ord && b <= '6'.ord # the cheap prefilter: every frame leads with the Engine.IO type
        s = String.new(payload).scrub
        d = engine(s[0], s[1..]) || return nil
        [d]
      rescue
        nil
      end

      # The Engine.IO layer. Only its `4` carries a Socket.IO packet; the rest is transport.
      private def engine(type : Char, rest : String) : Decoded?
        case type
        when '4'      then packet(rest)
        when '0'      then engine_open(rest)
        when '2', '3' then heartbeat(type, rest)
        else               engine_bare(type, rest)
        end
      end

      # The Engine.IO handshake. `sid` + `pingInterval` is a shape nothing else sends, so this
      # alone is enough to enable the decoder for a transcript.
      private def engine_open(rest : String) : Decoded?
        h = json_object(rest) || return nil
        sid = h["sid"]?.try(&.as_s?)
        Decoded.new(kind: "open", id: sid, payload: rest, strong: !sid.nil?)
      end

      # `2probe` / `3probe` is the upgrade handshake; a bare `2`/`3` is the heartbeat.
      private def heartbeat(type : Char, rest : String) : Decoded?
        return nil unless rest.empty? || rest == "probe"
        Decoded.new(kind: type == '2' ? "ping" : "pong", note: rest.presence, strong: false)
      end

      private def engine_bare(type : Char, rest : String) : Decoded?
        kind = ENGINE_BARE[type]? || return nil
        return nil unless rest.empty?
        Decoded.new(kind: kind, strong: false)
      end

      # The optional run in front of a Socket.IO packet's JSON, all three parts running
      # together with no separator of their own: `[<attachments>-][<namespace>,][<ack id>]`.
      private record Prefix, attachments : String?, nsp : String?, ack : String?, body : String

      private def prefix(type : Char, body : String) : Prefix?
        attachments = nil
        if m = body.match(/\A(\d+)-/)
          return nil unless type == '5' || type == '6' # only BINARY_EVENT / BINARY_ACK count them
          attachments = m[1]
          body = body[m[0].size..]
        end
        # The namespace is present only when it is not the default `/`. The reference decoder
        # reads to the `,` and takes the remainder when there is none, so a trailing-comma-less
        # `40/admin` still names its namespace.
        nsp = nil
        if body.starts_with?('/')
          i = body.index(',')
          nsp, body = i ? {body[0, i], body[(i + 1)..]} : {body, ""}
        end
        ack = nil
        if m = body.match(/\A\d+/)
          ack = m[0]
          body = body[ack.size..]
        end
        Prefix.new(attachments, nsp, ack, body)
      end

      # One Socket.IO packet — everything after the Engine.IO `4`.
      private def packet(rest : String) : Decoded?
        return nil if rest.empty?
        type = rest[0]
        p = prefix(type, rest[1..]) || return nil
        note = note(p.nsp, p.attachments)
        case type
        when '2', '5' then event(type, p, note)
        when '3', '6' then ack(type, p, note)
        when '0'      then connect(p, note)
        when '1'      then disconnect(p, note)
        when '4'      then connect_error(p, note)
        end
      end

      # An EVENT's first element IS the event name; without one this is not an event.
      private def event(type : Char, p : Prefix, note : String?) : Decoded?
        arr = json_array(p.body) || return nil
        name = arr[0]?.try(&.as_s?) || return nil
        Decoded.new(kind: type == '2' ? "event" : "binary_event", name: name, id: p.ack,
          note: note, payload: arr[1..].to_json)
      end

      private def ack(type : Char, p : Prefix, note : String?) : Decoded?
        arr = json_array(p.body) || return nil
        Decoded.new(kind: type == '3' ? "ack" : "binary_ack", id: p.ack, note: note,
          payload: arr.to_json)
      end

      # CONNECT carries an optional auth payload. Bare `40` is two digits and stays weak.
      private def connect(p : Prefix, note : String?) : Decoded?
        return nil unless p.body.empty? || json_object(p.body)
        Decoded.new(kind: "connect", note: note, payload: p.body.presence,
          strong: !(p.body.empty? && p.nsp.nil?))
      end

      private def disconnect(p : Prefix, note : String?) : Decoded?
        return nil unless p.body.empty?
        Decoded.new(kind: "disconnect", note: note, strong: !p.nsp.nil?)
      end

      # CONNECT_ERROR carries an object (`{"message":"Not authorized"}`) — the one shape the
      # protocol defines for it, and the one a reader can tell from an unrelated digit-led
      # text frame.
      private def connect_error(p : Prefix, note : String?) : Decoded?
        return nil unless json_object(p.body)
        Decoded.new(kind: "connect_error", note: note, payload: p.body)
      end

      private def note(nsp : String?, attachments : String?) : String?
        parts = [] of String
        parts << "ns=#{nsp}" if nsp
        parts << "attachments=#{attachments}" if attachments
        parts.empty? ? nil : parts.join(" ")
      end

      # Both readers check their opening byte first. The Engine.IO type digits let plenty of
      # ordinary numeric text through (`42abc` reaches here as an EVENT with body `abc`), and a
      # raised parse costs ~10µs against the ~1ns the prefilter above spends.
      private def json_array(s : String) : Array(JSON::Any)?
        return nil unless s.starts_with?('[')
        JSON.parse(s).as_a?
      rescue
        nil
      end

      private def json_object(s : String) : Hash(String, JSON::Any)?
        return nil unless s.starts_with?('{')
        JSON.parse(s).as_h?
      rescue
        nil
      end
    end
  end
end
