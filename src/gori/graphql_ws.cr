require "json"
require "./graphql"
require "./ascii_bytes"
require "./store/models"

module Gori
  # GraphQL carried over a WebSocket — how every real GraphQL SUBSCRIPTION runs.
  #
  # The document does not travel in a request body here; it travels inside a frame, wrapped in
  # the subprotocol's own envelope:
  #
  #   graphql-transport-ws  {"id":"1","type":"subscribe","payload":{"query":"subscription …"}}
  #   subscriptions-transport-ws (legacy Apollo)   {"id":"1","type":"start","payload":{…}}
  #
  # Every decode pane gori has is keyed on a request or response BODY, and a 101 flow has
  # neither — its bytes live in the `ws_messages` table. So a subscription showed up as raw
  # JSON, one line per frame, with no GRAPHQL pane offered: the same "gori did not notice this
  # is GraphQL" the HTTP side had, one transport over.
  #
  # ## What counts as an operation
  #
  # NOT the `type` name. The two subprotocols spell the same frame `subscribe` and `start`, a
  # third might spell it something else again, and gori has no reason to hold a table of
  # protocol versions to answer a question the payload answers by itself: a frame carries an
  # operation when its `payload` parses as a GraphQL envelope. That is the same
  # selection-set-bearing `"query"` test `Gori::Graphql` applies everywhere else — the one
  # detector — so `{"type":"ping"}`, `{"type":"next","payload":{"data":…}}` (a RESULT, not a
  # document) and an unrelated JSON protocol all correctly carry nothing.
  #
  # A bare envelope sent with no wrapper (`{"query":"{ me }"}`, which some servers accept over
  # a socket) is recognised too, with a nil `type`.
  module GraphqlWs
    extend self

    MAX_FRAME   = 1 * 1024 * 1024 # skip a pathological frame rather than parse it
    MAX_FRAMES  =  500            # cap the ops one transcript contributes to a pane
    MAX_EXAMINE = 4000            # cap the frames JSON-PARSED before giving up (see from_messages)

    # The ASCII substring every GraphQL frame carries, case-folded: a `"query":` document, or
    # a persisted query (`persistedQuery` — its `Query` matches case-insensitively). A frame
    # without it cannot be an operation, so the byte scan below skips its `JSON.parse` — which
    # matters because this runs on the WHOLE transcript, every refresh poll, for an open 101
    # detail (a busy socket's frame log grows without bound). `next`/`data` result frames,
    # `ping`, `connection_ack` and an unrelated JSON protocol all lack it and cost only the scan.
    QUERY_NEEDLE = "query".to_slice

    # One frame that carries an operation. `index` is 1-based within the message list the
    # caller passed, so a pane can point at the frame in the transcript beside it.
    record Frame,
      index : Int32,
      direction : String, # "out" (client→server) | "in"
      type : String?,     # the envelope's `type`, nil for a bare (unwrapped) envelope
      id : String?,       # the subscription id both subprotocols correlate on
      op : Graphql::Op

    # The operations a 101 flow's transcript carries, in order. Empty ⇒ the flow is not
    # GraphQL-over-WebSocket and no pane is offered.
    #
    # TEXT frames only, and never a `notice?` row: those are gori's own prose ABOUT the socket
    # (the handshake advisory, the ping-flood marker), not a frame a peer sent — decoding one
    # would report gori's diagnostics as the application's traffic.
    def from_messages(msgs : Array(Store::WsMessage)) : Array(Frame)
      frames = [] of Frame
      examined = 0 # frames actually JSON-parsed — the cost this backstops
      msgs.each_with_index do |m, i|
        break if frames.size >= MAX_FRAMES || examined >= MAX_EXAMINE
        next unless m.text? && !m.notice?
        next if m.payload.empty? || m.payload.size > MAX_FRAME
        # The byte prefilter FIRST, so a transcript of thousands of non-GraphQL frames costs a
        # cheap scan each and no parse. A frame full of `"query"` that never parses as an op
        # (a chat message carrying a `query` field) is bounded by the examine counter, so a
        # hostile / dense transcript cannot pin the render loop reparsing on every poll.
        next unless AsciiBytes.contains_ci?(m.payload, QUERY_NEEDLE)
        examined += 1
        parsed = from_frame(m.payload) || next
        frames << Frame.new(i + 1, m.direction, parsed[0], parsed[1], parsed[2])
      end
      frames
    end

    # {type, id, op} for a frame that carries an operation, else nil.
    def from_frame(payload : Bytes) : {String?, String?, Graphql::Op}?
      json = JSON.parse(String.new(payload).scrub)
      h = json.as_h? || return nil
      if inner = h["payload"]?
        op = Graphql.from_json_any(inner) || return nil
        return {h["type"]?.try(&.as_s?), frame_id(h), op}
      end
      # No wrapper: the frame IS the envelope. `from_json_any` still requires a selection set,
      # so an ordinary JSON message cannot fall in here.
      op = Graphql.from_json_any(json) || return nil
      {nil, frame_id(h), op}
    rescue
      nil
    end

    # The correlation id, which both subprotocols allow to be a string OR a number.
    private def frame_id(h : Hash(String, JSON::Any)) : String?
      v = h["id"]? || return nil
      v.as_s? || v.as_i64?.try(&.to_s)
    end

    # The pane text: every operation in transcript order under a header naming its frame,
    # direction and correlation id. `Graphql.display` renders each one, so an operation reads
    # identically whether it arrived in a POST body or in a frame.
    def display(frames : Array(Frame)) : String
      String.build do |io|
        frames.each_with_index do |f, i|
          io << "\n\n" if i > 0
          io << "# --- " << (f.direction == "out" ? "→" : "←") << " frame #" << f.index
          f.type.try { |t| io << ' ' << t }
          f.id.try { |id| io << " id=" << id }
          io << " ---\n"
          io << Graphql.display(f.op)
        end
      end
    end

    # A one-line summary for a pane header / CLI section title.
    def summary(frames : Array(Frame)) : String
      names = frames.compact_map(&.op.operation).uniq!
      s = "#{frames.size} operation#{frames.size == 1 ? "" : "s"} over websocket"
      names.empty? ? s : "#{s} · #{names.first(4).join(", ")}#{names.size > 4 ? ", …" : ""}"
    end
  end
end
