require "json"
require "./frame"

module Gori
  module WsProto
    # ASP.NET Core SignalR, JSON hub protocol.
    #
    # Every record is JSON *terminated* by a `0x1e` record separator, and one WebSocket frame
    # may carry several back to back. The terminator is what makes this decoder unambiguous:
    # `0x1e` does not occur in ordinary text, so a frame that ends with one and parses as hub
    # records is SignalR and nothing else — there is no weak case here.
    #
    #   {"protocol":"json","version":1}<RS>              the client handshake
    #   {}<RS>                                           the server's answer (or {"error":…})
    #   {"type":1,"invocationId":"0","target":"Send","arguments":["hi"]}<RS>
    #
    # `target` is the hub METHOD — the name an authorization gap hides behind, and the reason
    # this pane exists at all.
    #
    # The MessagePack hub protocol is binary and out of scope: this reads TEXT frames, like
    # every other decoder in the family.
    module SignalR
      extend self

      NAME  = "signalr"
      LABEL = "SignalR"

      RS      = 0x1e_u8
      RS_CHAR = '\u{1e}'

      def hinted?(sub : String) : Bool
        sub == "signalr" || sub == "json.signalr" || sub == "messagepack.signalr"
      end

      def decode(payload : Bytes) : Array(Decoded)?
        return nil if payload.empty?
        return nil unless payload.unsafe_fetch(payload.size - 1) == RS # the prefilter AND the proof
        s = String.new(payload).scrub
        out = [] of Decoded
        pos = 0
        # A bounded scan rather than `split`: a 1 MiB frame of nothing but separators would
        # materialise a million substrings before any cap could look at them.
        while out.size < MAX_RECORDS
          idx = s.index(RS_CHAR, pos) || break
          raw, pos = s[pos, idx - pos], idx + 1
          next if raw.empty?
          out << (hub_record(raw) || return nil)
        end
        out << WsProto.truncated if out.size == MAX_RECORDS && s.index(RS_CHAR, pos)
        out.empty? ? nil : out
      rescue
        nil
      end

      private def hub_record(raw : String) : Decoded?
        h = JSON.parse(raw).as_h? || return nil
        handshake(h, raw) || typed(h)
      rescue
        nil
      end

      # The two records that carry no `type`: the client's protocol offer, and the server's
      # answer to it (`{}` on success, `{"error":"…"}` on failure).
      private def handshake(h : Hash(String, JSON::Any), raw : String) : Decoded?
        if proto = h["protocol"]?.try(&.as_s?)
          version = h["version"]?.try { |x| x.as_i64? || x.as_s? }
          return Decoded.new(kind: "handshake", note: "#{proto} v#{version}", payload: raw)
        end
        return nil if h.has_key?("type")
        err = h["error"]?.try(&.as_s?)
        return nil unless h.empty? || err
        Decoded.new(kind: "handshake_response", note: err, payload: err ? raw : nil)
      end

      private def typed(h : Hash(String, JSON::Any)) : Decoded?
        type = h["type"]?.try(&.as_i64?) || return nil
        id = h["invocationId"]?.try { |x| x.as_s? || x.as_i64?.try(&.to_s) }
        case type
        when 1, 4 then invocation(type, h, id)
        when 2    then Decoded.new(kind: "stream_item", id: id, payload: h["item"]?.try(&.to_json))
        when 3 then Decoded.new(kind: "completion", id: id, note: h["error"]?.try(&.as_s?),
          payload: h["result"]?.try(&.to_json))
        when 5 then Decoded.new(kind: "cancel_invocation", id: id)
        when 6 then Decoded.new(kind: "ping")
        when 7 then Decoded.new(kind: "close", note: h["error"]?.try(&.as_s?),
          payload: h["allowReconnect"]?.try(&.to_json))
        end
      end

      # `target` is the hub METHOD — the name an authorization gap hides behind, and the
      # reason this decoder exists. A record claiming to be an invocation without one is not
      # one, so it falls through to raw rather than being reported as a nameless call.
      private def invocation(type : Int64, h : Hash(String, JSON::Any), id : String?) : Decoded?
        target = h["target"]?.try(&.as_s?) || return nil
        Decoded.new(kind: type == 1 ? "invocation" : "stream_invocation", name: target,
          id: id, note: stream_ids(h), payload: h["arguments"]?.try(&.to_json))
      end

      # The client-to-server streams an invocation opens, if any.
      private def stream_ids(h : Hash(String, JSON::Any)) : String?
        ids = h["streamIds"]?.try(&.as_a?) || return nil
        return nil if ids.empty?
        "streams=#{ids.compact_map { |x| x.as_s? || x.as_i64?.try(&.to_s) }.join(",")}"
      end
    end
  end
end
