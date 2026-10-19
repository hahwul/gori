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
  # P6: per relayed frame this is one uncontended Mutex, a byte compare and a few Bool
  # writes (the teardown bound below costs a Bool read until `teardown!`). On the
  # single-threaded scheduler `@busy` is exact: it is set and cleared under the lock with no
  # yield between taking the lock and setting it, so "not busy" means `lock` will not block.
  class Leg
    getter direction : String
    getter? mid_message = false
    getter? closed = false
    # A CLOSE frame has gone out on this side, after which RFC 6455 §5.5.1 allows no data frame.
    getter? close_sent = false
    # gori closed this socket itself, because an injected frame's write timed out: the relay's
    # teardown must not report the resulting end as the peer's RESET. A write that failed
    # for any other reason (EPIPE, a reset) failed because the PEER ended it, so it is not set.
    getter? killed = false

    def initialize(@direction : String, @io : IO, @mask : Bool)
      @lock = Mutex.new
      @busy = false
      @teardown = false
      @teardown_wait = Live::BOUNDARY_WAIT
      @waiting = false # a data inject is polling for a boundary; one at a time per side
    end

    # Write `bytes` and flush. `fin` is the FIN bit of the data frame the bytes END with, and
    # nil when they end with a control frame (or carry no data frame), which leaves the
    # message state alone. A CLOSE always goes out as a write of its own (both pumps forward
    # it alone, and an inject is one frame), so its first header byte is enough to see it.
    def write(bytes : Bytes, fin : Bool? = nil) : Nil
      hold { |io| emit(io, bytes, fin) }
    end

    # Run `block` with this socket held: for a write that is more than one `write` call
    # (`Relay.forward_oversized_frame` streams a frame's payload through). The block sets
    # the message state itself via `fin=` / `close_sent!`.
    #
    # Once `teardown!` has run, a writer waits at most `teardown!`'s bound for a write in
    # progress and then raises instead of queueing on the lock. The socket timeouts were
    # relaxed for the tunnel, and one armed after a fiber parked does not fire, so a writer
    # parked on a peer that stopped reading would otherwise keep `Relay.run`'s teardown
    # writes (and the two `close` calls after them) waiting forever.
    def hold(& : IO -> T) : T forall T
      wait_idle if @teardown
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

    # Record a CLOSE frame written inside `hold`.
    def close_sent! : Nil
      @close_sent = true
    end

    # `Relay.run` has reached its teardown writes: bound every later write's wait (`hold`).
    def teardown!(wait : Time::Span = Live::BOUNDARY_WAIT) : Nil
      @teardown_wait = wait
      @teardown = true
    end

    # The relay is tearing down: no inject may start after this.
    def close : Nil
      @closed = true
    end

    # Write one frame of gori's own: FIN=1, RSV=0, a fresh mask key client→server and none
    # server→client (§5.3). A data frame waits for a message boundary, up to `wait`; a
    # control frame waits only for a write already in progress. Answers the Shape of what
    # went out (the mask key included, so the capture is the bytes the peer saw, P7), else
    # why nothing did (a String), or why the write failed after it started (`Live::Spent`).
    # No write starts at or after `expires` (`Live.apply_command`'s sender deadline).
    def inject(opcode : UInt8, payload : Bytes, wait : Time::Span,
               expires : Time::Instant? = nil) : Shape | String | Live::Spent
      shape = Shape.new(masked: @mask, mask_key: @mask ? Random::Secure.random_bytes(4) : nil)
      frame = WS.encode(opcode, payload, shape, mask: @mask)
      control = opcode >= 0x8_u8
      if refusal = await_turn(control, wait, expires)
        return refusal
      end
      write_bounded(frame, control ? nil : true, wait) || shape
    rescue ex
      "the socket failed while writing the frame: #{ex.message}"
    end

    # Poll until a frame may go out: nil then, with no yield before the caller's write, else
    # why it may not. Only one data frame per side waits at a time.
    private def await_turn(control : Bool, wait : Time::Span, expires : Time::Instant?) : String?
      deadline = Time.instant + wait
      waiter = false
      loop do
        if refusal = refusal_now(control, expires)
          return refusal
        end
        return nil if !@busy && (control || !@mid_message)
        return wait_refusal(wait) if Time.instant >= deadline
        unless control || waiter
          return Live::ANOTHER_WAITING if @waiting
          @waiting = waiter = true
        end
        sleep Live::POLL
      end
    ensure
      @waiting = false if waiter
    end

    # Why no frame may go out at all, however long it waits; nil when one may.
    private def refusal_now(control : Bool, expires : Time::Instant?) : String?
      return Live::CLOSED if @closed
      return close_sent_refusal if @close_sent && !control
      Live::EXPIRED if expires.try { |e| Time.instant >= e }
    end

    # The bytes of one write, and the message state they leave behind. A CLOSE always goes
    # out as a write of its own (both pumps forward it alone, and an inject is one frame), so
    # its first header byte is enough to see it.
    private def emit(io : IO, bytes : Bytes, fin : Bool?) : Nil
      io.write(bytes)
      io.flush
      @mid_message = !fin unless fin.nil?
      @close_sent = true if fin.nil? && !bytes.empty? && bytes[0] & 0x0f_u8 == OP_CLOSE
    end

    # A write of gori's own carries its own deadline. The relay's sockets have none (an idle
    # WebSocket must not be reaped), so a peer that stopped reading would park this write, and
    # with it the leg, for good. `write_timeout` bounds each stall, not the whole frame: a peer
    # that keeps reading, however slowly, is not cut off. nil once the frame is on the wire, a
    # String when the write failed before a byte of it went out, else `Live::Spent`.
    private def write_bounded(frame : Bytes, fin : Bool?, limit : Time::Span) : (String | Live::Spent)?
      sock = SocketTuning.underlying_socket(@io)
      before = sock.try(&.write_timeout)
      sock.try(&.write_timeout = limit)
      started = false
      begin
        hold do |io|
          started = true
          emit(io, frame, fin)
        end
        nil
      rescue ex
        return "the socket failed before any of the frame was written: #{ex.message}" unless started
        # Part of the frame may be on the wire, and no byte after it on this side parses, so
        # the socket ends here. The RAW socket: closing a TLS layer would SSL_shutdown, writing
        # close_notify to the very peer that stopped reading.
        @closed = true
        @killed = ex.is_a?(IO::TimeoutError)
        (sock || @io).close rescue nil
        Live::Spent.new(spent_reason(ex, limit))
      ensure
        # Not once `Relay.run` re-armed the socket for its teardown writes (`arm` and
        # `teardown!` run back to back): putting `before` back would unbound them again.
        (sock.try(&.write_timeout = before) unless @teardown) rescue nil
      end
    end

    private def spent_reason(ex : Exception, limit : Time::Span) : String
      unless ex.is_a?(IO::TimeoutError)
        return "the socket failed while writing the frame (#{ex.message}), and gori closed it, " \
               "since part of the frame may already have gone out"
      end
      "the #{Live.side(@direction)} peer stopped reading: the frame's write made no progress for " \
      "#{Live.span(limit)}, and gori closed the socket, since a partly written frame " \
      "leaves the stream unreadable"
    end

    private def wait_idle : Nil
      deadline = Time.instant + @teardown_wait
      while @busy
        if Time.instant >= deadline
          raise IO::TimeoutError.new("a write on the #{Live.side(@direction)} side did not finish " \
                                     "within #{Live.span(@teardown_wait)}")
        end
        sleep Live::POLL
      end
    end

    private def close_sent_refusal : String
      "a CLOSE has already gone out #{Live.side(@direction)}, and no data frame may follow it " \
      "(RFC 6455 §5.5.1); nothing was written. A ping, pong or close may still be injected"
    end

    private def wait_refusal(wait : Time::Span) : String
      if @mid_message
        return "the #{Live.side(@direction)} side stayed mid-message (a fragmented message " \
               "has not sent its final frame) for #{Live.span(wait)}, so a data " \
               "frame cannot go in without splitting it; nothing was written. A ping, pong " \
               "or close may be injected mid-message"
      end
      "a write on the #{Live.side(@direction)} side did not finish within " \
      "#{Live.span(wait)}; nothing was written"
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

    # A refusal after the frame's write had started: part of it may have reached the peer, so
    # the request-budget slot it took stays spent.
    record Spent, reason : String

    EXPIRED = "the sender stopped waiting for this inject's ack before it could go out, so it " \
              "was not written: an inject is never written after its sender reported it unconfirmed"

    # How long before the sender stops polling (`Store.ws_inject_ack_budget_ms` after the
    # command row's `created_at`) the last write may start, so its ack is committed and read in
    # time. Kept well under the budget's slack over `BOUNDARY_WAIT`.
    ACK_MARGIN = 1.second

    ANOTHER_WAITING = "another injected data frame is already waiting for a message boundary on " \
                      "this side; nothing was written. Retry once it has gone out or been refused"

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
    #
    # `expires` is when a bridge sender stops waiting for the ack: past it nothing is written
    # (the budget's rate wait included), so an inject reported unconfirmed never goes out late
    # and a retry cannot land twice.
    def self.inject(sink : FlowSink, flow_id : Int64, direction : String, opcode : UInt8,
                    payload : Bytes, outbound : Outbound, wait : Time::Span = BOUNDARY_WAIT,
                    expires : Time::Instant? = nil) : String?
      entry = find(sink, flow_id) || return CLOSED
      ctx = entry.ctx
      if block = outbound.send_block(ctx.scheme, ctx.host, ctx.target, ctx.port)
        return block
      end
      run_halt = outbound.halt
      halt = expires.try { |e| -> { Time.instant >= e || run_halt.try(&.call) == true } } || run_halt
      if refusal = outbound.admit(halt: halt)
        return refusal
      end
      shape = entry.leg(direction).inject(opcode, payload, wait, expires)
      if shape.is_a?(String)
        outbound.refund(1)
        return shape
      end
      return shape.reason if shape.is_a?(Spent)
      begin
        sink.on_ws_injected(flow_id, direction, opcode.to_i, payload.dup, shape)
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
      expires = ack_deadline(cmd.created_at)
      spawn(name: "gori-ws-inject") do
        if refusal = inject(sink, flow_id, direction, opcode, payload, outbound, expires: expires)
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

    # The instant `cmd`'s sender stops polling for its ack, less `ACK_MARGIN`. `created_at` is
    # the sender's wall clock at enqueue (same host: both processes open the one SQLite file).
    # Never later than a whole budget from now: a wall clock stepped back since the enqueue
    # would otherwise run the inject after its sender reported it unconfirmed.
    def self.ack_deadline(created_at_us : Int64) : Time::Instant
      budget_us = Store.ws_inject_ack_budget_ms.to_i64 * 1000 - ACK_MARGIN.total_microseconds.to_i64
      left_us = created_at_us + budget_us - (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
      Time.instant + Math.min(left_us, budget_us).microseconds
    end

    # "5s", or "300ms" for a wait under a second, which would otherwise read as "0s".
    def self.span(t : Time::Span) : String
      t >= 1.second ? "#{t.total_seconds.to_i}s" : "#{t.total_milliseconds.to_i}ms"
    end

    def self.side(direction : String) : String
      direction == "out" ? "client→server" : "server→client"
    end
  end
end
