require "json"
require "./frame"

module Gori
  module WsProto
    # SockJS — the fallback-transport shim that WRAPS another protocol.
    #
    #   o                      the session opened
    #   h                      heartbeat
    #   a["<msg>","<msg>"]     an ARRAY of messages, each JSON-encoded as a string
    #   m"<msg>"               a single message
    #   c[3000,"Go away!"]     the session closed
    #
    # The `a` array is the point: a SockJS transcript's real traffic is a STOMP frame or a
    # Socket.IO event JSON-encoded inside a JSON string, so reading the outer envelope alone
    # tells the operator nothing they could not already see. The coordinator therefore hands
    # each unwrapped message back to the other decoders and records the winner with
    # `via: "sockjs"` — the same one-layer-down recursion `GraphqlWs` does when it looks past
    # a frame's `payload` wrapper.
    #
    # `o` and `h` are ONE ASCII letter each and can never enable the decoder; the JSON-bearing
    # frames can.
    module SockJs
      extend self

      NAME  = "sockjs"
      LABEL = "SockJS"

      # SockJS negotiates on the URL (`/<prefix>/<server>/<session>/websocket`), never by
      # subprotocol — there is no spelling to hint on, so this is always false and the
      # decoder relies entirely on a strong frame.
      def hinted?(sub : String) : Bool
        false
      end

      # The frame letters, as bytes — the prefilter, so a transcript of some other framing does
      # not allocate a String copy of every frame just to be told `{` is not one of these.
      FRAME_BYTES = {'o'.ord.to_u8, 'h'.ord.to_u8, 'a'.ord.to_u8, 'm'.ord.to_u8, 'c'.ord.to_u8}

      # A frame letter is ONE byte, and `a`, `c`, `h`, `m` and `o` open plenty of ordinary
      # words. Each branch below therefore checks the byte that must follow its letter before
      # anything reaches a parser: a raise costs ~10µs, and this decoder is offered every frame
      # of every transcript.
      def decode(payload : Bytes) : Array(Decoded)?
        return nil if payload.empty?
        return nil unless FRAME_BYTES.includes?(payload.unsafe_fetch(0))
        s = String.new(payload).scrub
        rest = s[1..]
        case s[0]
        when 'o', 'h' then lifecycle(s[0], rest)
        when 'a'      then batch(rest)
        when 'm'      then single(rest)
        when 'c'      then closed(rest)
        end
      rescue
        nil
      end

      # `o` and `h` are ONE ASCII letter each, so they can never enable the decoder.
      private def lifecycle(type : Char, rest : String) : Array(Decoded)?
        return nil unless rest.empty?
        [Decoded.new(kind: type == 'o' ? "open" : "heartbeat", strong: false)]
      end

      # `a[…]` — an array of messages, each JSON-encoded as a string. The coordinator hands
      # each `payload` back to the other decoders; see the module header.
      private def batch(rest : String) : Array(Decoded)?
        return nil unless rest.starts_with?('[') # a word beginning with `a` is not a batch
        arr = JSON.parse(rest).as_a? || return nil
        out = [] of Decoded
        arr.each do |v|
          break if out.size >= MAX_RECORDS
          out << Decoded.new(kind: "message", payload: v.as_s? || return nil)
        end
        out << WsProto.truncated if arr.size > MAX_RECORDS
        out.empty? ? nil : out
      end

      private def single(rest : String) : Array(Decoded)?
        return nil unless rest.starts_with?('"')
        [Decoded.new(kind: "message", payload: JSON.parse(rest).as_s? || return nil)]
      end

      private def closed(rest : String) : Array(Decoded)?
        return nil unless rest.starts_with?('[')
        arr = JSON.parse(rest).as_a? || return nil
        code = arr[0]?.try(&.as_i64?) || return nil
        [Decoded.new(kind: "close", id: code.to_s, note: arr[1]?.try(&.as_s?))]
      end
    end
  end
end
