require "json"
require "../ascii_bytes"
require "./frame"

module Gori
  module WsProto
    # Rails Action Cable.
    #
    #   {"command":"subscribe","identifier":"{\"channel\":\"ChatChannel\",\"room\":\"1\"}"}
    #   {"command":"message","identifier":"…","data":"{\"action\":\"speak\",\"message\":\"hi\"}"}
    #   {"type":"welcome"} / {"type":"ping","message":1699…} / {"type":"confirm_subscription",…}
    #   {"identifier":"…","message":{…}}                       a broadcast
    #
    # The channel and the action are the two names worth enumerating, and both are buried a
    # layer down: `identifier` and `data` are JSON *strings* holding JSON. Unwrapping them is
    # the whole value here — `ChatChannel#speak` is the thing an operator tests authorization
    # on, and the raw frame spells it with escaped quotes.
    #
    # `{"type":"ping"}` with no `message` is the one weak shape: graphql-transport-ws spells
    # its keepalive exactly the same way, so it may not enable this decoder — only a
    # `command`, a subscription lifecycle `type`, or a real Action Cable ping (which always
    # carries its timestamp in `message`) can.
    module ActionCable
      extend self

      NAME  = "action_cable"
      LABEL = "Action Cable"

      CLIENT_COMMANDS = {"subscribe", "unsubscribe", "message"}
      SERVER_TYPES    = {"welcome", "ping", "confirm_subscription", "reject_subscription", "disconnect"}

      # Every frame that carries traffic names its subscription with `identifier` — a key
      # nothing else in the family uses.
      IDENTIFIER_NEEDLE = "identifier".to_slice

      # …and the three that do NOT are the lifecycle frames carrying only a `type`, whose
      # values are a closed set. Between the two tests, every frame the protocol defines is
      # admitted and almost nothing else is.
      LIFECYCLE_NEEDLES = {"\"welcome\"".to_slice, "\"ping\"".to_slice, "\"disconnect\"".to_slice}

      # A lifecycle frame is tiny — the longest Rails sends is
      # `{"type":"disconnect","reason":"unauthorized","reconnect":false}` at 62 bytes — so the
      # extra needles are only ever run over a short frame. Anything larger has to name its
      # subscription, which is one scan.
      SMALL_FRAME = 256

      # Rails sets `Sec-WebSocket-Protocol: actioncable-v1-json` and answers with it.
      def hinted?(sub : String) : Bool
        sub.starts_with?("actioncable-")
      end

      # The gate below is this decoder's whole cost, and it is the only one in the family that
      # can reach a parser: the other four are answered by a leading byte or a trailing one.
      # Every frame Action Cable sends either names its subscription — `identifier`, a key
      # nothing else here uses — or is one of the three short lifecycle frames carrying only a
      # `type`. So: name `identifier`, or be small enough that parsing costs about what
      # scanning would.
      #
      # A `"type"` needle was the first spelling, and it let through EVERY `{`-leading frame
      # that happened to have a type field — a 4 KiB chat message paid a full String copy and
      # a JSON parse, per frame, on every pane rebuild. 42µs a frame against 1-90ns for every
      # other decoder, and 180ms to rebuild one busy socket's pane; nothing else in the family
      # was even measurable next to it.
      def decode(payload : Bytes) : Array(Decoded)?
        return nil if payload.empty?
        return nil unless payload.unsafe_fetch(0) == '{'.ord
        # …and CLOSES as one. A frame that merely opens with `{` reaches the parser and raises,
        # and a raise costs ~10µs — 10,000× the byte checks around it. This is what a
        # `0x1e`-terminated SignalR record or a NUL-terminated STOMP frame carrying JSON looks
        # like from here, so without it a SignalR transcript paid an exception per frame.
        return nil unless payload.unsafe_fetch(payload.size - 1) == '}'.ord
        return nil unless AsciiBytes.contains_ci?(payload, IDENTIFIER_NEEDLE) ||
                          (payload.size <= SMALL_FRAME && lifecycle?(payload))
        h = JSON.parse(String.new(payload).scrub).as_h? || return nil
        d = client(h) || server(h) || return nil
        [d]
      rescue
        nil
      end

      private def lifecycle?(payload : Bytes) : Bool
        LIFECYCLE_NEEDLES.any? { |n| AsciiBytes.contains_ci?(payload, n) }
      end

      private def client(h : Hash(String, JSON::Any)) : Decoded?
        command = h["command"]?.try(&.as_s?) || return nil
        return nil unless CLIENT_COMMANDS.includes?(command)
        identifier = h["identifier"]?.try(&.as_s?) || return nil
        channel = inner(identifier, "channel")
        data = h["data"]?.try(&.as_s?)
        Decoded.new(kind: command, name: qualified(channel, data.try { |x| inner(x, "action") }),
          note: channel ? nil : identifier.presence,
          payload: render({"identifier", identifier}, {"data", data}))
      end

      private def server(h : Hash(String, JSON::Any)) : Decoded?
        if type = h["type"]?.try(&.as_s?)
          return nil unless SERVER_TYPES.includes?(type)
          identifier = h["identifier"]?.try(&.as_s?)
          return Decoded.new(kind: type, name: identifier.try { |i| inner(i, "channel") },
            note: h["reason"]?.try(&.as_s?),
            payload: render({"identifier", identifier}, {"message", h["message"]?.try(&.to_json)}),
            strong: type != "ping" || h.has_key?("message"))
        end
        # A broadcast: no `type`, just the subscription it belongs to and the payload.
        identifier = h["identifier"]?.try(&.as_s?) || return nil
        message = h["message"]? || return nil
        # `identifier` + `message` is a GENERIC pair — unlike `command` + `identifier`, which
        # only this protocol spells that way. So a broadcast is evidence of Action Cable only
        # when the identifier really is the stringified JSON naming a channel; otherwise it is
        # decoded (the pane is already open) but may not be what OPENS the pane, or a chat
        # protocol sending `{"identifier":"abc","message":"hi"}` would label the socket
        # ACTION CABLE. See `Decoded#strong`.
        channel = inner(identifier, "channel")
        Decoded.new(kind: "broadcast", name: channel, note: channel ? nil : identifier.presence,
          payload: render({"identifier", identifier}, {"message", message.to_json}),
          strong: !channel.nil?)
      end

      # One key out of a JSON document that travelled as a JSON STRING. nil when the string is
      # not an object (some apps pass a bare name), which the caller reports verbatim instead.
      private def inner(json : String, key : String) : String?
        return nil unless json.starts_with?('{') # some apps pass a bare name; do not raise over it
        JSON.parse(json).as_h?.try(&.[key]?).try(&.as_s?)
      rescue
        nil
      end

      # The `identifier` is the subscription's WHOLE parameter set — `{"channel":"ChatChannel",
      # "room":"1"}` — and the room id in it is exactly what an IDOR test moves, so it is shown
      # even when the channel name has already been lifted out of it into `name`. One value
      # renders bare; two get labelled, because unlabelled they read as one document.
      private def render(*parts : {String, String?}) : String?
        present = parts.to_a.select { |(_, v)| v && !v.empty? }
        return nil if present.empty?
        return present[0][1] if present.size == 1
        present.join('\n') { |(k, v)| "#{k}: #{v}" }
      end

      # `ChatChannel#speak` — the pair an operator enumerates, spelled the way Rails routes it.
      private def qualified(channel : String?, action : String?) : String?
        return channel unless action
        channel ? "#{channel}##{action}" : action
      end
    end
  end
end
