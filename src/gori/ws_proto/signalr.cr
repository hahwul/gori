require "json"
require "../raw_json"
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

      RS = 0x1e_u8

      def hinted?(sub : String) : Bool
        sub == "signalr" || sub == "json.signalr" || sub == "messagepack.signalr"
      end

      def decode(payload : Bytes) : Array(Decoded)?
        return nil if payload.empty?
        return nil unless payload.unsafe_fetch(payload.size - 1) == RS # the prefilter AND the proof
        out = [] of Decoded
        pos = 0
        records = 0
        # A bounded scan rather than `split`: a 1 MiB frame of nothing but separators would
        # materialise a million substrings before any cap could look at them. BYTE offsets, as
        # in `Stomp.frames`: a char offset into a non-ASCII String walks from byte 0 on every
        # call, and an empty record is still a record against the cap — skipping it uncounted
        # let `"é" + RS * N` loop N times at O(N) each, an hour of a frozen scheduler at 1 MiB.
        while records < MAX_RECORDS
          idx = payload.index(RS, pos) || break
          start, pos = pos, idx + 1
          records += 1
          next if idx == start
          out << (hub_record(String.new(payload[start, idx - start]).scrub) || WsProto.unreadable)
        end
        out << WsProto.truncated if records == MAX_RECORDS && payload.index(RS, pos)
        # Every SignalR record is `strong` (the separator is proof), so a frame that yielded
        # only unreadable rows was never SignalR — it falls through to raw, as it must.
        out.any?(&.strong) ? out : nil
      rescue
        nil
      end

      # The record's members as RAW JSON text (the last of a duplicated key, as `JSON.parse`
      # reads it), since `item`/`result`/`arguments` are shown: `JSON.parse` refused a record
      # over one number past Int64, and re-emitting a tree respelled `[1.0e2]` as `[100.0]`.
      private def hub_record(raw : String) : Decoded?
        h = RawJson.members(RawJson.tolerant(raw)).try(&.to_h) || return nil
        handshake(h, raw) || typed(h)
      rescue JSON::ParseException
        nil
      end

      # The two records that carry no `type`: the client's protocol offer, and the server's
      # answer to it (`{}` on success, `{"error":"…"}` on failure).
      private def handshake(h : Hash(String, String), raw : String) : Decoded?
        if proto = RawJson.string?(h["protocol"]?)
          version = h["version"]?.try { |x| x.to_i64? || RawJson.string?(x) }
          return Decoded.new(kind: "handshake", note: "#{proto} v#{version}", payload: raw)
        end
        return nil if h.has_key?("type")
        err = RawJson.string?(h["error"]?)
        return nil unless h.empty? || err
        Decoded.new(kind: "handshake_response", note: err, payload: err ? raw : nil)
      end

      private def typed(h : Hash(String, String)) : Decoded?
        type = h["type"]?.try(&.to_i64?) || return nil
        id = h["invocationId"]?.try { |x| RawJson.string?(x) || x.to_i64?.try(&.to_s) }
        case type
        when 1, 4 then invocation(type, h, id)
        when 2    then Decoded.new(kind: "stream_item", id: id, payload: h["item"]?)
        when 3 then Decoded.new(kind: "completion", id: id, note: RawJson.string?(h["error"]?),
          payload: h["result"]?)
        when 5 then Decoded.new(kind: "cancel_invocation", id: id)
        when 6 then Decoded.new(kind: "ping")
        when 7 then Decoded.new(kind: "close", note: RawJson.string?(h["error"]?),
          payload: h["allowReconnect"]?)
        end
      end

      # `target` is the hub METHOD — the name an authorization gap hides behind, and the
      # reason this decoder exists. A record claiming to be an invocation without one is not
      # one, so it falls through to raw rather than being reported as a nameless call.
      private def invocation(type : Int64, h : Hash(String, String), id : String?) : Decoded?
        target = RawJson.string?(h["target"]?) || return nil
        Decoded.new(kind: type == 1 ? "invocation" : "stream_invocation", name: target,
          id: id, note: stream_ids(h), payload: h["arguments"]?)
      end

      # The client-to-server streams an invocation opens, if any.
      private def stream_ids(h : Hash(String, String)) : String?
        ids = h["streamIds"]?.try { |x| RawJson.elements(x) } || return nil
        return nil if ids.empty?
        "streams=#{ids.compact_map { |x| RawJson.string?(x) || x.to_i64?.try(&.to_s) }.join(",")}"
      end
    end
  end
end
