require "./frame"
require "../sink"
require "../../interceptor"

module Gori::Proxy::WS
  # One DIRECTION's release gate for held WebSocket messages (#500 step 2).
  #
  # ## Why the pump must not block — and it is NOT h2's reason
  #
  # This is `H2::StreamGate`'s shape reached from the opposite argument, and the difference
  # has to be understood or the design below reads as over-engineering.
  #
  # `StreamGate` exists because ONE `Relay#pump` fiber serves every stream on an h2
  # connection, so blocking it to wait for a human stops the whole connection — a browser tab
  # freezes, an unrelated download stalls. WebSocket has no second stream: `Relay.run` already
  # spawns one pump per direction, and a direction is exactly one ordering domain, so blocking
  # the pump would cost only what holding on an ordered stream must cost anyway. **The h2
  # payoff has no WebSocket analogue.**
  #
  # What blocking a WS pump costs instead is **control-frame relay**. A blocked
  # `pump(client → upstream)` never forwards the client's PONG, and real servers ping on a
  # 20-30 s timer and close after a missed reply (RFC 6455 §5.5.2/§5.5.3). Editing message 3
  # for two minutes would reliably kill the socket the operator is inspecting. So the pump
  # keeps reading, control frames overtake the queue the instant they arrive (§5.4 permits
  # them mid-message), and a fiber per held message waits on the decision and writes through
  # this object. Same mechanism, liveness rather than concurrency.
  #
  # ## What transfers from `StreamGate`, and what does not
  #
  #   * `@slots : Hash(UInt32, Slot)` collapses to **one FIFO**. A WS message has no id to
  #     key on, and the arrival order IS the release order.
  #   * `@ordered` **disappears**. It distinguished the h2 direction that opens streams;
  #     both WS directions are ordered, so `drain_locked`'s unordered branch is gone too.
  #   * `close` transfers verbatim: hand every still-held item back to the `Interceptor` so
  #     no ghost queue row survives the socket and no wait fiber leaks.
  #   * **The drop transfers not at all.** There is no RST_STREAM. Dropping a WS message
  #     means writing nothing, and a WS stream has no message identity for the peer to notice
  #     a hole in — so a drop is invisible to BOTH endpoints. That is a genuinely weaker
  #     guarantee than h1's canned 502 or h2's RST_STREAM(CANCEL), and it is in the docs.
  #   * `MAX_DEFERRED_BYTES` matters MORE here, not less: h2 could lean on the peer's stream
  #     window (a sender gets no credit for bytes the far end never saw), and WebSocket has
  #     no application-level flow control at all — only TCP, which the pump must keep
  #     draining. Past the ceiling the hold fails open, the disposition every other
  #     involuntary release in this codebase already has.
  #
  # ## Decisions are free; releases are ordered
  #
  # The operator may decide message 5 while 3 and 4 are still open — forbidding that would be
  # the "merely discouraged" answer. The gate parks the decision until 3 and 4 are decided,
  # then releases 3, 4, 5 in that order. Because that lives BELOW `Interceptor#forward`,
  # every decision surface inherits it without knowing WebSocket exists: the TUI, batch
  # verbs over marks, `forward_all`, `release_all`, the #123 reaper and MCP.
  #
  # ## The lock
  #
  # One Mutex guards the queue AND the writes, so the order messages are decided in is the
  # order they are written in with no window between. Every writer takes it — the pump
  # (control frames, bypasses), and each wait fiber's release. `Interceptor#enqueue_ws` and
  # `#forward` are called under it, which is safe because the Interceptor never calls back
  # into a gate; `item.reply.receive` is the one thing that must never happen under it, and
  # that is exactly why the wait lives on its own fiber.
  class MessageGate
    # Ceiling on the payload bytes queued BEHIND the head of the FIFO. The head itself is
    # exempt: it is already buffered by the pump that assembled it (up to `Relay::MAX_MESSAGE`),
    # so charging it here would make a single large message unholdable rather than bound
    # anything. Past the ceiling the hold FAILS OPEN — everything queued forwards unedited,
    # in order, with one warning — the same disposition as toggle-off (`interceptor.cr`),
    # `release_all`, the #123 reaper and `H2::StreamGate#fail_open`.
    MAX_DEFERRED_BYTES = 1 << 20

    # How many scheduler turns `bypass` will give a decision that is already on its channel
    # but whose wait fiber has not run yet. The fiber is runnable, so one turn is normally
    # enough; the bound only exists so an unbufferable frame can never wedge the pump.
    BYPASS_SETTLE_TURNS = 32

    # One message whose delivery is deferred. Created only when something is actually held or
    # queued behind a hold; a socket that holds nothing never allocates one.
    private class Slot
      getter opcode : UInt8
      # The payload as it would have gone on the wire (post-rewrite). Owned by the slot —
      # `submit` dups it, because the pump reuses its assembly buffer for the next message.
      getter payload : Bytes
      # The peer's OWN frame bytes, when the message arrived as a single frame and no rule
      # changed it. Reused verbatim on an unedited release, so a hold that ends in "forward"
      # preserves the sender's framing and mask key.
      getter raw : Bytes?
      # The operator's bytes, once a decision has arrived.
      property decided : Bytes?
      property? dropped = false
      property? ready = false
      # The queue entry, while a human still owns the decision.
      property item : Gori::Interceptor::Item?

      def initialize(@opcode : UInt8, @payload : Bytes, @raw : Bytes?)
      end
    end

    def initialize(@direction : String, @dst : IO, @flow_id : Int64, @sink : FlowSink,
                   @interceptor : Gori::Interceptor, @ctx : Context, @mask : Bool)
      @mutex = Mutex.new
      @queue = [] of Slot
      @closed = false
      @warned_overflow = false
      @dropped = 0
      @stranded = 0
    end

    # --- pump side (never blocks on a human) ---------------------------------

    # Offer one complete message to the gate. Writes it through immediately when nothing is
    # held and nothing is queued (the common case on an armed socket whose condition does not
    # match), otherwise queues it in arrival order.
    #
    # `raw` is the sender's own frame bytes when they are still usable; `payload` is what
    # would go out. The pump owns both only until this returns, so anything the gate keeps is
    # duplicated here.
    def submit(opcode : UInt8, payload : Bytes, raw : Bytes?) : Nil
      @mutex.synchronize do
        return if @closed
        held = holds?(payload)
        if !held && @queue.empty?
          write_message(opcode, payload, raw)
          return
        end
        kept = payload.dup
        slot = Slot.new(opcode, kept, raw)
        item = held ? start_hold(opcode, kept) : nil
        if item
          slot.item = item
          wait_for(item, slot)
        else
          # Queued for ORDER only — nothing to decide. Either the condition declined it, or
          # the interceptor was toggled off between the two calls above.
          slot.ready = true
        end
        @queue << slot
        check_ceiling
        # A slot born READY at the head of the queue has nobody to release it otherwise:
        # `drain_locked` is reachable only from `resolve_locked` (which needs an Item) and
        # from `fail_open_locked`. That is the `item.nil?` branch above — `holds?` said yes
        # and `enqueue_ws` then returned nil, which the comment there already names — and it
        # stalled the direction outright: nothing written, no capture row, every later
        # message queued behind it, and `close` discards an item-less slot without writing
        # it, so the bytes were lost for good.
        drain_locked
      end
    end

    # A control frame (PING / PONG / CLOSE) or any other write that must NOT be ordered
    # behind a hold. Takes the lock so it can never interleave with a release mid-frame, and
    # that is all — RFC 6455 §5.4 lets a control frame arrive between the fragments of a data
    # message, and a PONG parked behind a hold is how the peer's ping timer closes the socket.
    def write_control(bytes : Bytes) : Nil
      @mutex.synchronize do
        return if @closed
        @dst.write(bytes)
        @dst.flush
      end
    end

    # Force the queue out, in order, then run `block`'s direct write under the same lock.
    #
    # For the three things the gate cannot express as a queued message: a CLOSE frame (§5.5.1
    # forbids data frames after it, so it cannot be forwarded ahead of the queue — design D5
    # resolves the queue instead), a frame too large to buffer, and the leading fragments of a
    # message that has outgrown the assembly buffer. All three end with bytes going straight
    # to `@dst`, so the queue in front of them has to be gone first.
    #
    # A slot whose decision is already on its channel is NOT settled here — that would discard
    # the operator's choice, and forwarding a message they dropped is the one outcome worse
    # than delaying it. Its wait fiber owns the settle and is already runnable, so the loop
    # yields to it instead.
    def bypass(reason : String, & : -> Nil) : Nil
      BYPASS_SETTLE_TURNS.times do
        drained = @mutex.synchronize { fail_open_locked(reason); @queue.empty? || @closed }
        break if drained
        Fiber.yield
      end
      @mutex.synchronize { yield }
    end

    # The direction ended. Hand every still-held item back to the `Interceptor` — that
    # resolves the queue row, bumps the revision so the TUI redraws, and unblocks the wait
    # fiber, which then finds `@closed` and discards the decision. `H2::StreamGate#close`,
    # verbatim, and for the same reason: without it a dead socket leaves ghost rows in the
    # queue and leaked fibers parked on a channel nobody will ever send to.
    def close : Nil
      slots = @mutex.synchronize do
        @closed = true
        q = @queue
        @queue = [] of Slot
        q
      end
      stranded = slots.count(&.item)
      slots.each { |s| s.item.try { |it| @interceptor.forward(it.id) } }
      @stranded += stranded
      warn_teardown
    end

    # --- holding -------------------------------------------------------------

    private def holds?(payload : Bytes) : Bool
      @interceptor.intercepts_ws?(to_server: to_server?, method: @ctx.method, host: @ctx.host,
        target: @ctx.target, scheme: @ctx.scheme, payload: payload)
    end

    private def start_hold(opcode : UInt8, payload : Bytes) : Gori::Interceptor::Item?
      @interceptor.enqueue_ws(payload, to_server: to_server?, method: @ctx.method, target: @ctx.target,
        host: @ctx.host, port: @ctx.port, scheme: @ctx.scheme, flow_id: @flow_id,
        binary: opcode == OP_BIN)
    end

    # `out` is a Crystal keyword, hence the name. "out" is the direction string the sink and
    # the store already use for client -> server.
    private def to_server? : Bool
      @direction == "out"
    end

    # One fiber per held message, and the ONLY place `item.reply.receive` is reached — never
    # under `@mutex`, which is the whole reason the wait is not on the pump.
    private def wait_for(item : Gori::Interceptor::Item, slot : Slot) : Nil
      spawn do
        decision = item.reply.receive
        @mutex.synchronize { resolve_locked(item, slot, decision) }
      end
    end

    private def resolve_locked(item : Gori::Interceptor::Item, slot : Slot,
                               decision : Gori::Interceptor::Decision) : Nil
      return if @closed
      # Already failed open past the ceiling, or torn down: the decision arrived too late and
      # there is nothing left to apply it to.
      return unless slot.item == item
      slot.item = nil
      if decision.action.drop?
        slot.dropped = true
      else
        slot.decided = decision.bytes
      end
      slot.ready = true
      drain_locked
    end

    # --- release -------------------------------------------------------------

    # Release from the HEAD only. This one loop is what makes reordering structurally
    # impossible rather than policed by the view: a decision taken out of order sets its own
    # slot ready and moves nothing until everything ahead of it is decided too.
    private def drain_locked : Nil
      while (slot = @queue.first?) && slot.ready?
        @queue.shift
        release_locked(slot)
      end
    end

    private def release_locked(slot : Slot) : Nil
      if slot.dropped?
        # Nothing is written, and nothing CAN be: a WS stream has no message identity, so
        # neither endpoint can see that a message is missing. Counted for the teardown log —
        # the operator made the decision and watched the row leave, but nothing downstream
        # (History, the WS pane, an export) has a record of the attempt.
        @dropped += 1
        return
      end
      bytes = slot.decided || slot.payload
      # An unedited forward keeps the sender's own frame — byte-exact, mask key and all (P7).
      # An edit is re-framed as ONE frame: once the length changes the sender's fragmentation
      # cannot be reproduced, and a client → server frame is re-masked with a fresh key
      # (RFC 6455 §5.3), exactly as step 1's rewrite path already does.
      write_message(slot.opcode, bytes, bytes == slot.payload ? slot.raw : nil)
    end

    private def write_message(opcode : UInt8, payload : Bytes, raw : Bytes?) : Nil
      @dst.write(raw || WS.encode(opcode, payload, mask: @mask, fin: true))
      @dst.flush
      # Record what gori WROTE, not what arrived — the same way step 1's rewrite path keeps
      # P7. The capture has to be the bytes the peer actually sees.
      @sink.on_ws_message(@flow_id, @direction, opcode.to_i, payload.dup)
    rescue
      # The socket is gone. `close` reaps whatever is still queued; there is nothing useful
      # to do with a write error on a direction that has already ended.
    end

    # --- ceiling / fail-open --------------------------------------------------

    private def check_ceiling : Nil
      return if deferred_bytes <= MAX_DEFERRED_BYTES
      fail_open_locked("over #{MAX_DEFERRED_BYTES} bytes queued behind a held message")
    end

    # Everything after the head. See `MAX_DEFERRED_BYTES` for why the head is exempt.
    private def deferred_bytes : Int32
      total = 0
      @queue.each_with_index { |s, i| total += s.payload.size if i > 0 }
      total
    end

    # Release the whole queue, forwarding undecided messages unedited and IN ORDER. Reached
    # from the byte ceiling and from `bypass`; both are involuntary, so both fail open.
    private def fail_open_locked(reason : String) : Nil
      return if @queue.empty?
      warn_fail_open(reason)
      @queue.each do |slot|
        next if slot.ready?
        item = slot.item
        # A decision is already on this item's channel and its wait fiber has not been
        # scheduled yet. That fiber owns the settle; failing the slot open here would DISCARD
        # the decision, and forwarding a message the operator dropped is worse than waiting a
        # scheduler turn for it (`H2::StreamGate#fail_one_open`, same reasoning).
        next if item && @interceptor.get(item.id).nil?
        unless item
          slot.ready = true
          next
        end
        # `H2::StreamGate#fail_one_open`'s claim, and for the same reason: the probe above is
        # not atomic, so a decision landing in the window would otherwise be discarded by the
        # wait fiber's `slot.item == item` guard while this loop released the message anyway.
        next unless @interceptor.forward(item.id)
        slot.item = nil
        slot.ready = true
      end
      drain_locked
    end

    # --- warnings (once each, per gate) ---------------------------------------

    private def warn_fail_open(reason : String) : Nil
      return if @warned_overflow
      @warned_overflow = true
      ::Log.warn do
        "ws #{@direction}: #{reason} — forwarding #{@queue.size} held message(s) unedited, " \
        "in arrival order. WebSocket has no application-level flow control, so nothing " \
        "throttles the sender while a hold is out"
      end
    end

    private def warn_teardown : Nil
      return if @dropped == 0 && @stranded == 0
      ::Log.info do
        "ws #{@direction}: #{@dropped} held message(s) dropped and #{@stranded} released " \
        "unread when the socket closed. A dropped WebSocket message is written nowhere — " \
        "neither endpoint can see the gap, and gori keeps no ws_messages row for it"
      end
    end
  end
end
