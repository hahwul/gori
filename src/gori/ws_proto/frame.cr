module Gori
  # The real-time framings that ride *inside* a WebSocket, decoded at display time.
  #
  # gori decoded exactly one of them for a long while — GraphQL-over-WS (`Gori::GraphqlWs`) —
  # and every other framing rode raw: a Socket.IO event showed as `42["chat",{…}]`, a SignalR
  # hub invocation as a `0x1e`-terminated JSON blob, a STOMP frame as a text lump. Those
  # envelopes are where the interesting work lives (event-name enumeration, hub-method
  # authorization gaps, CSWSH against a named event), so the operator was reading the envelope
  # by eye on the one surface built to read framings for them.
  #
  # This is `GraphqlWs`'s pattern generalised, not a new subsystem: a pure display-time
  # projection over the `ws_messages` transcript, no new table, no new capture. Each
  # subprotocol is one module under `ws_proto/` exposing the same two entry points —
  #
  #   `.decode(payload : Bytes) : Array(Decoded)?`  nil ⇒ "not my framing"
  #   `.hinted?(subprotocol : String) : Bool`       does a negotiated subprotocol name me?
  #
  # — and the coordinator in `ws_proto.cr` runs them.
  #
  # ## P7: the frame bytes stay the truth
  #
  # A frame that does not parse as the sniffed protocol contributes NOTHING and stays visible
  # raw in the MESSAGES pane. The decoded pane is a lens, exactly as the GRAPHQL pane is —
  # never a guess, never a rewrite.
  module WsProto
    MAX_FRAME   = 1 * 1024 * 1024 # skip a pathological frame rather than parse it
    MAX_FRAMES  =  500            # cap the decoded frames one transcript contributes to a pane
    MAX_EXAMINE = 4000            # cap the frames sniffed before the enablement pass gives up
    MAX_RECORDS =   64            # cap the records ONE frame may carry (SignalR / SockJS batch)

    # What a per-protocol decoder says about one record inside a frame.
    #
    # `strong` is the whole reason detection does not guess. A Socket.IO `2` (ping) is one
    # ASCII digit and a SockJS `h` (heartbeat) is one ASCII letter — either could be an
    # ordinary text message in an unrelated protocol, so neither may ENABLE a decoder on its
    # own. Only an unmistakable envelope (`42["chat",…]`, an `0x1e`-terminated hub record, a
    # NUL-terminated STOMP frame) is `strong`, and a protocol with no strong frame and no
    # handshake hint decodes nothing at all.
    record Decoded,
      kind : String,        # the frame kind within its protocol ("event", "invocation", "SEND")
      name : String? = nil, # the event / hub method / destination — the thing worth enumerating
      id : String? = nil,   # the correlation id the protocol answers on
      note : String? = nil, # protocol-specific extra (a namespace, a close reason, an error)
      payload : String? = nil,
      strong : Bool = true

    # The record a decoder appends when ONE frame carried more than `MAX_RECORDS`. A cap that
    # just stops reads as "the frame ended here", which for a batching framing is the same
    # mistake as reporting a filtered list as an empty one — so the cap says so in the pane.
    # `strong: false`, because a truncation marker is not evidence of a protocol.
    def self.truncated : Decoded
      Decoded.new(kind: "truncated", strong: false,
        note: "more records in this frame than the #{MAX_RECORDS} cap decodes")
    end

    # One decoded record, placed back in the transcript. `index` is 1-based within the message
    # list the caller passed, so a pane can point at the frame in the transcript beside it —
    # and several records can share an index, because one WebSocket frame can carry several
    # (a SignalR frame holds `0x1e`-delimited records; a SockJS `a` frame holds an array).
    record Frame,
      index : Int32,
      direction : String, # "out" (client→server) | "in"
      protocol : String,  # the decoder that read this record
      kind : String,
      name : String?,
      id : String?,
      note : String?,
      payload : String?,
      via : String? = nil # the wrapper this record arrived inside ("sockjs")
  end
end
