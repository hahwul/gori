require "./frame"
require "../sink"
require "../../outbound"

module Gori::Proxy::WS
  # One direction's destination socket on a live h1 WebSocket relay, and the ONLY way bytes
  # reach it (#1630). Before injection the relay had one writer per direction (the pump, or
  # the gate under its own lock), so nothing serialized the socket itself. An injected frame
  # is a second writer, so every write takes `@lock`: the pump, `forward_oversized_frame` and
  # the gate's three writes. Lock order is gate → leg, never the reverse: the gate writes
  # through a leg while holding its own mutex, and nothing holding a leg ever takes a gate.
  #
  # `mid_message?` is the wire's state as the PEER reads it: a data frame with FIN=0 went out
  # and its final fragment has not. A data frame may not be injected there (RFC 6455 §5.4
  # forbids interleaving data messages); a control frame may.
  #
  # P6: per relayed frame this is one uncontended Mutex and two Bool writes. On the
  # single-threaded scheduler `@busy` is exact: it is set and cleared under the lock with no
  # yield between taking the lock and setting it, so "not busy" means `lock` will not block.
  class Leg
    getter direction : String
    getter? mid_message = false
    getter? closed = false

    def initialize(@direction : String, @io : IO, @mask : Bool)
      @lock = Mutex.new
      @busy = false
    end

    # Write `bytes` and flush. `fin` is the FIN bit of the data frame the bytes END with, and
    # nil when they end with a control frame (or carry no data frame), which leaves the
    # message state alone.
    def write(bytes : Bytes, fin : Bool? = nil) : Nil
      hold do |io|
        io.write(bytes)
        io.flush
        @mid_message = !fin unless fin.nil?
      end
    end

    # Run `block` with this socket held: for a write that is more than one `write` call
    # (`Relay.forward_oversized_frame` streams a frame's payload through). The block sets
    # the message state itself via `fin`.
    def hold(& : IO -> T) : T forall T
      @lock.synchronize do
        @busy = true
        begin
          yield @io
        ensure
          @busy = false
        end
      end
    end

    # Record the FIN bit of a data frame written inside `hold`.
    def fin=(fin : Bool) : Nil
      @mid_message = !fin
    end

    # The relay is tearing down: no inject may start after this.
    def close : Nil
      @closed = true
    end

    # Write one frame of gori's own: FIN=1, RSV=0, a fresh mask key client→server and none
    # server→client (§5.3). A data frame waits for a message boundary, up to `wait`; a
    # control frame waits only for a write already in progress. Answers nil once the frame is
    # on the wire, else why it is not.
    def inject(opcode : UInt8, payload : Bytes, wait : Time::Span) : String?
      frame = WS.encode(opcode, payload, mask: @mask, fin: true)
      control = opcode >= 0x8_u8
      deadline = Time.instant + wait
      loop do
        return Live::CLOSED if @closed
        if !@busy && (control || !@mid_message)
          write(frame, control ? nil : true)
          return nil
        end
        if Time.instant >= deadline
          return "the #{Live.side(@direction)} side stayed mid-message (a fragmented message " \
                 "has not sent its final frame) for #{wait.total_seconds.to_i}s, so a data " \
                 "frame cannot go in without splitting it; nothing was written. A ping, pong " \
                 "or close may be injected mid-message" if @mid_message
          return "a write on the #{Live.side(@direction)} side did not finish within " \
                 "#{wait.total_seconds.to_i}s; nothing was written"
        end
        sleep Live::POLL
      end
    rescue ex
      "the socket failed while writing the frame: #{ex.message}"
    end
  end

  # The live h1 WebSocket relays of this process, by sink and flow id (#1630). `Relay.run`
  # registers its two legs and the handshake's `Context` and removes them in `ensure`, so a
  # flow is here exactly while its socket is open. Keyed by the sink as well as the flow id
  # because flow ids are per project: two projects' relays never meet here.
  module Live
    record Entry, sink : FlowSink, flow_id : Int64, ctx : Context, out_leg : Leg, in_leg : Leg do
      def leg(direction : String) : Leg
        direction == "out" ? out_leg : in_leg
      end
    end

    CLOSED = "the WebSocket is no longer open (it closed, or this gori did not relay it); " \
             "nothing was written"

    # How long a data frame waits for the message in flight to end. The relay's own CLOSE
    # window: a peer that keeps a message open longer is not going to end it on cue.
    BOUNDARY_WAIT = 5.seconds

    # The boundary poll. A message boundary arrives with a peer's frame, never on a timer.
    POLL = 10.milliseconds

    # The frame kinds a surface may inject, by the name it takes them as.
    OPCODES = {"text" => OP_TEXT, "binary" => OP_BIN, "ping" => OP_PING, "pong" => OP_PONG,
               "close" => OP_CLOSE}

    @@entries = {} of {UInt64, Int64} => Entry

    def self.register(entry : Entry) : Nil
      @@entries[{entry.sink.object_id, entry.flow_id}] = entry
    end

    # Remove `entry`, and only it: a later relay that reused the key keeps its own.
    def self.unregister(entry : Entry) : Nil
      entry.out_leg.close
      entry.in_leg.close
      key = {entry.sink.object_id, entry.flow_id}
      @@entries.delete(key) if @@entries[key]?.try(&.out_leg).same?(entry.out_leg)
    end

    def self.find(sink : FlowSink, flow_id : Int64) : Entry?
      @@entries[{sink.object_id, flow_id}]?
    end

    # The sentence for a WebSocket this process cannot inject into, read off the flow's stored
    # handshake before any socket is consulted: an RFC 8441 h2 stream, or a flow that is not a
    # WebSocket at all. nil when the flow is an h1 WebSocket (open or not).
    def self.flow_refusal(request_head : String) : String?
      if WS.extended_connect_request?(request_head)
        return "this WebSocket runs over HTTP/2 (RFC 8441 extended CONNECT), and injecting into " \
               "an HTTP/2 stream is not supported yet (a follow-up to #1630); only HTTP/1.1 " \
               "Upgrade sockets take an injected frame"
      end
      return nil if WS.upgrade_request?(request_head)
      "this flow is not a WebSocket handshake"
    end

    # Inject one frame into the open socket of `flow_id`, in `direction` ("out" client→server,
    # "in" server→client), and record it with the origin set. Answers nil on success, else the
    # refusal. The bytes are the operator's (P7): no Match & Replace, no hold, and it goes out
    # ahead of any message Intercept is holding on that side, because it bypasses the gate.
    #
    # `outbound` is the CALLING surface's decision, and Layer 2 (`send_block`, Sandbox) is
    # asked here, against the handshake's own host: that is the host the socket dialled.
    def self.inject(sink : FlowSink, flow_id : Int64, direction : String, opcode : UInt8,
                    payload : Bytes, outbound : Outbound, wait : Time::Span = BOUNDARY_WAIT) : String?
      entry = find(sink, flow_id) || return CLOSED
      ctx = entry.ctx
      if block = outbound.send_block(ctx.scheme, ctx.host, ctx.target, ctx.port)
        return block
      end
      if refusal = outbound.admit
        return refusal
      end
      leg = entry.leg(direction)
      if refusal = leg.inject(opcode, payload, wait)
        outbound.refund(1)
        return refusal
      end
      begin
        sink.on_ws_injected(flow_id, direction, opcode.to_i, payload.dup,
          Shape.new(masked: direction == "out"))
      rescue
        # The frame is on the wire; a capture write that fails must not report it as unsent.
      end
      nil
    end

    # Apply one `Store::WS_INJECT_VERB` bridge command for the capturing instance that drains
    # them, and ack it. A refusal known up front (not open here, an h2 socket) is acked at once;
    # the inject itself, which can wait `BOUNDARY_WAIT` for a message boundary, runs on its own
    # fiber and acks from there, so the drain never stalls. `on_injected` gets the receipt, on
    # that fiber, once the frame is on the wire. Answers whether an inject was started.
    def self.apply_command(store : Store, sink : FlowSink, outbound : Outbound,
                           cmd : Store::CommandRow, &on_injected : String -> Nil) : Bool
      flow_id = cmd.item_id
      parsed = Store.parse_ws_inject_arg(cmd.arg)
      unless flow_id && parsed
        store.ack_intercept_command(cmd.id, "error", "ws_inject missing flow id, direction or opcode")
        return false
      end
      direction, opcode = parsed
      unless find(sink, flow_id)
        head = store.get_flow(flow_id).try { |f| String.new(f.request_head) }
        store.ack_intercept_command(cmd.id, "refused", head.try { |h| flow_refusal(h) } || CLOSED)
        return false
      end
      payload = cmd.bytes || Bytes.empty
      spawn(name: "gori-ws-inject") do
        if refusal = inject(sink, flow_id, direction, opcode, payload, outbound)
          store.ack_intercept_command(cmd.id, "refused", refusal)
        else
          kind = OPCODES.key_for?(opcode).try(&.upcase) || "opcode #{opcode}"
          receipt = "#{kind} #{payload.size}B #{side(direction)} on flow ##{flow_id}"
          store.ack_intercept_command(cmd.id, "injected", receipt)
          on_injected.call(receipt)
        end
      rescue ex
        store.ack_intercept_command(cmd.id, "error", "ws_inject failed: #{ex.message}") rescue nil
      end
      true
    end

    def self.side(direction : String) : String
      direction == "out" ? "client→server" : "server→client"
    end
  end
end
