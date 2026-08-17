require "../ws/frame"
require "../ws/relay"
require "../sink"

module Gori::Proxy::H2
  # The WebSocket transcript of an RFC 8441 extended CONNECT stream (#733).
  #
  # A WebSocket opened over HTTP/2 carries the SAME RFC 6455 frames the HTTP/1.1 Upgrade path
  # carries — §5.1 of RFC 8441 replaces the handshake and nothing else. What it does not carry
  # is a socket: the frames arrive as the payloads of that stream's DATA frames, and a DATA
  # boundary has nothing to do with a WebSocket frame boundary, so a frame straddles two DATA
  # frames as readily as ten frames share one. That is why this is a stream REASSEMBLER fed
  # bytes rather than a per-DATA-frame parser: the parser is `WS.read_header`/`WS.read_body`
  # (the same codec the h1 relay runs — there is no second one), driven over an
  # `IO::Memory` window that keeps whatever a frame still owes and rewinds when a frame is
  # incomplete.
  #
  # ## Capture only, and deliberately so
  #
  # This never writes to a socket and never resizes anything. It runs from `Assembler#feed`,
  # which the h2 relay reaches only AFTER the frame is already on the wire, over a COPY of a
  # payload that has been forwarded — so the h2 flow-control accounting is untouched and no
  # DATA frame changes length. #492 step 5 (a length-CHANGING DATA rewrite) was closed as
  # decided-not-doing precisely because resizing DATA deadlocks against the peer's flow-control
  # window; a per-message hold or a Match & Replace edit on this path would have to do exactly
  # that, so neither is offered here. The advisory on the flow says so rather than half-doing
  # it — see `Assembler#extended_connect_sentence`.
  class WsCapture
    # The `:protocol` token RFC 8441 registers for a WebSocket. An extended CONNECT can carry
    # other tokens (`connect-udp`, RFC 9298; `connect-ip`, RFC 9484; a private one), and those
    # are NOT RFC 6455 framing — pointing this codec at them would invent messages out of
    # somebody else's protocol. Recognition is by the token, and only by the token.
    PROTOCOL = "websocket"

    def self.websocket?(protocol : String) : Bool
      protocol.compare(PROTOCOL, case_insensitive: true) == 0
    end

    # How many extended CONNECT streams ONE h2 connection may capture concurrently.
    #
    # A reassembler holds up to `WS::MAX_FRAME` of a frame it has not finished receiving plus
    # up to `Relay::MAX_MESSAGE` of the message it is assembling, per direction — the same
    # ceilings the h1 relay has, where the connection count is what multiplies them. Here it is
    # the STREAM count, and h2 lets one connection open as many as `MAX_LIVE_STREAMS` allows.
    # A browser opens a handful of sockets to an origin; past this many, a stream keeps exactly
    # the pre-#733 behaviour (opaque DATA, no transcript) and the advisory says which it got.
    MAX_STREAMS = 8

    # Whether the origin has ACCEPTED the socket. A 2xx to the extended CONNECT is what opens
    # it (RFC 8441 §5.1); before that answer there is no WebSocket, and after a refusal what
    # arrives is an ordinary error body rather than frames.
    getter? active = false

    def initialize(@flow_id : Int64, @sink : FlowSink)
      @out = Reader.new("out", @flow_id, @sink)
      @in = Reader.new("in", @flow_id, @sink)
    end

    # The origin answered 2xx. `pending_out` is whatever request-direction DATA arrived BEFORE
    # that answer: a conforming client waits for it, but one that does not would otherwise have
    # its first frames parsed against a reader that starts mid-stream, and a reassembler that
    # starts mid-frame is desynced for the life of the socket.
    def activate(pending_out : Bytes? = nil) : Nil
      return if @active
      @active = true
      p = pending_out
      @out.push(p) if p && !p.empty?
    end

    def push(direction : String, chunk : Bytes) : Nil
      return unless @active
      (direction == "out" ? @out : @in).push(chunk)
    end

    # The stream ended. Surface a message whose FIN never arrived, exactly as the h1 pump's own
    # `ensure` does — gori saw those fragments, so dropping them would make the transcript
    # disagree with the raw frame log it was derived from (P7).
    def finish : Nil
      return unless @active
      @out.finish
      @in.finish
    end

    # One direction's reassembler. Not a fiber and not an `IO` pipe: a pipe would need
    # backpressure, and backpressure on this path means the h2 pump waiting on a capture
    # buffer — a slow writer delaying a peer, which is the one thing the relay's forward-first
    # discipline exists to prevent (P6).
    private class Reader
      # Bytes received on this direction that no complete frame has consumed yet. `pos` is the
      # parse cursor and `size` the append point; `compact` drops the consumed prefix once the
      # parse loop stops. It is bounded by construction: the loop only leaves bytes here while
      # ONE frame is short of its advertised length, and a length past `WS::MAX_FRAME` takes
      # the skip path below instead of being buffered.
      @pending = IO::Memory.new
      @assembling = IO::Memory.new
      @opcode = WS::OP_TEXT
      @shape = WS::MessageShape.new
      @controls = 0
      # Payload bytes of an oversized frame still to be discarded. A frame past `WS::MAX_FRAME`
      # cannot be buffered, and the bytes cannot simply be left in `@pending` either — the next
      # header starts after them, so the reassembler has to count them off to stay in sync.
      @skip = 0_u64
      @finished = false

      def initialize(@direction : String, @flow_id : Int64, @sink : FlowSink)
      end

      def push(chunk : Bytes) : Nil
        return if @finished || chunk.empty?
        at = @pending.pos
        @pending.pos = @pending.size # append without disturbing the parse cursor
        @pending.write(chunk)
        @pending.pos = at
        drain
        compact
      rescue
        # A capture that raises must never take the connection down with it: the frame is
        # already on the wire and the raw frame log is the truth (P7).
        nil
      end

      def finish : Nil
        return if @finished
        @finished = true
        @assembling = WS::Relay.emit_pending(@assembling, @direction, @flow_id, @sink,
          @opcode, @shape)
      rescue
        nil
      end

      # Parse as many complete frames as `@pending` holds, then stop. Every exit that is not a
      # complete frame rewinds to `mark`: `WS.read_header` CONSUMES what it read before it
      # discovers the header is short, so leaving the cursor where it stopped would eat the
      # first bytes of a header the next DATA frame completes.
      private def drain : Nil
        loop do
          if @skip > 0
            @skip -= consume(@skip)
            break if @skip > 0 # still swallowing an oversized frame — nothing to parse yet
          end
          mark = @pending.pos
          h = WS.read_header(@pending)
          if h.nil?
            @pending.pos = mark
            break
          end
          if h.len > WS::MAX_FRAME
            oversized(h)
            @skip = h.len
            next
          end
          if left < h.len
            @pending.pos = mark
            break
          end
          frame = WS.read_body(@pending, h)
          if frame.nil?
            @pending.pos = mark
            break
          end
          handle(frame)
        end
      end

      # Unparsed bytes still in the window.
      private def left : UInt64
        (@pending.size - @pending.pos).to_u64
      end

      # Discard up to `want` bytes, answering how many there were.
      private def consume(want : UInt64) : UInt64
        take = want < left ? want : left
        @pending.pos += take.to_i
        take
      end

      # One frame, recorded exactly as `WS::Relay.pump` records it — the shared helpers are
      # what make the h1 and h2 transcripts of identical bytes identical rows, rather than two
      # reassemblers that agree until they do not.
      private def handle(frame : WS::Frame) : Nil
        unless frame.data?
          @controls = WS::Relay.capture_control(frame, @direction, @flow_id, @sink, @controls)
          return
        end
        if frame.opcode != WS::OP_CONT
          # A new data message while the previous one never sent its FIN is an RFC 6455 §5.4
          # violation; emitting the buffered half keeps the two from merging into one row.
          @assembling = WS::Relay.emit_pending(@assembling, @direction, @flow_id, @sink,
            @opcode, @shape)
          @opcode = frame.opcode
        end
        @shape.note(frame)
        @assembling = WS::Relay.capture_frame(frame, @assembling, @direction, @flow_id, @sink,
          @opcode, @shape)
      end

      # A frame too large to buffer. The h2 relay already forwarded its DATA, so the loss is in
      # the projection only; it gets the same marker row (and the same sentence) the h1 path's
      # `forward_oversized_frame` writes, after whatever prefix was buffered ahead of it.
      private def oversized(h : WS::Header) : Nil
        return unless h.data?
        @assembling = WS::Relay.emit_pending(@assembling, @direction, @flow_id, @sink,
          @opcode, @shape)
        marker = "#{WS::NOTICE_PREFIX}#{h.len}-byte WebSocket frame forwarded; " \
                 "too large to capture".to_slice
        @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, marker, h.shape)
      end

      # Drop the consumed prefix, releasing the backing buffer after a large frame rather than
      # pinning it for the life of the socket (`RESET_THRESHOLD`, the h1 relay's own rule).
      private def compact : Nil
        pos = @pending.pos
        return if pos == 0
        n = @pending.size - pos
        rest = n > 0 ? @pending.to_slice[pos, n].dup : nil
        @pending = @pending.size > WS::Relay::RESET_THRESHOLD ? IO::Memory.new : @pending.tap(&.clear)
        if r = rest
          @pending.write(r)
          @pending.pos = 0
        end
      end
    end
  end
end
