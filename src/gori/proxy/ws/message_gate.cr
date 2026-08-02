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
      # The peer's OWN wire frames, when no rule changed the message. Reused verbatim on an
      # unedited release, so a hold that ends in "forward" preserves the sender's
      # fragmentation, FIN/RSV bits and mask keys. Released as `data_only`: any control frame
      # that sat between the fragments was written the moment this slot was created, because
      # it cannot wait for a human (see this class's header).
      getter raw : WS::RawFrames?
      # The operator's bytes, once a decision has arrived.
      property decided : Bytes?
      property? dropped = false
      property? ready = false
      # The queue entry, while a human still owns the decision.
      property item : Gori::Interceptor::Item?

      # The frame shape the message ARRIVED in (V7). Kept beside `raw` and released with it:
      # an unedited forward puts the sender's own frames back on the wire, so the capture row
      # must claim the sender's RSV bits and fragment count, and an edited one must not.
      getter shape : WS::Shape

      def initialize(@opcode : UInt8, @payload : Bytes, @raw : WS::RawFrames?,
                     @shape : WS::Shape = WS::Shape::DEFAULT)
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
      @lost = 0
      # The peer on the far side of `@dst` already ended this direction with no CLOSE frame,
      # so a write here can no longer be CLAIMED as a delivery. See `settle`.
      @dst_dead = false
    end

    # Is anything still parked in this direction's queue? Asked by `Relay.run` at the
    # CLOSE_TIMEOUT deadline, so an operator whose decision window just expired is TOLD.
    def pending? : Bool
      @mutex.synchronize { !@queue.empty? }
    end

    # --- pump side (never blocks on a human) ---------------------------------

    # Offer one complete message to the gate. Writes it through immediately when nothing is
    # held and nothing is queued (the common case on an armed socket whose condition does not
    # match), otherwise queues it in arrival order.
    #
    # `raw` is the sender's own frame bytes when they are still usable; `payload` is what
    # would go out. The pump owns both only until this returns, so anything the gate keeps is
    # duplicated here.
    def submit(opcode : UInt8, payload : Bytes, raw : WS::RawFrames?,
               shape : WS::Shape = WS::Shape::DEFAULT) : Nil
      @mutex.synchronize do
        return if @closed
        held = holds?(payload)
        if !held && @queue.empty?
          # Nothing is waiting, so this message goes out now and the peer's own interleave is
          # still reproducible — its fragments and any control frame that sat between them,
          # in arrival order. That is the case an armed-but-non-matching socket is in for
          # every message, and it must be indistinguishable from an unarmed one.
          write_message(opcode, payload, raw.try(&.interleaved), shape)
          return
        end
        # From here the message waits — for a human, or for the messages queued ahead of it.
        # A control frame that arrived between its fragments cannot wait with it: a PONG
        # parked behind a hold is how the peer's ping timer closes the socket (this class's
        # header). So THIS is where the interleave is given up, and the only place — the
        # controls go out now, the message's own frames follow on release. Deliberate, and
        # the STORE stays honest (`capture_control` records the TRUE arrival order, so History
        # shows it correctly) — only the LIVE wire reorders. Every other routine edge case in
        # this class gets a `note()`; this one didn't, so an operator watching live traffic saw
        # a PING ahead of the data it was actually interleaved with and no signal that gori
        # did that on purpose.
        raw.try(&.controls).try do |c|
          write_raw(c)
          note("a control frame interleaved with this message was sent ahead of it, because " \
               "the message itself has to wait (held, or queued behind an earlier hold) and a " \
               "control frame cannot wait with it. The true arrival order is preserved in " \
               "History; only the live wire is reordered")
        end
        kept = payload.dup
        slot = Slot.new(opcode, kept, raw, shape)
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
      settle(reason)
      @mutex.synchronize { yield }
    end

    # Force the queue out, in order, and wait (bounded) for any decision already in flight.
    # `bypass` minus the direct write — `Relay.run` calls it on both gates the moment it
    # decides to tear the tunnel down, while the sockets are still OPEN.
    #
    # That timing is the whole point. `close` runs from the pump's `ensure`, which is only
    # reached AFTER `run` has closed both sockets to unblock the pump's read — so anything
    # released there is written to a dead socket. A held message therefore had until
    # `Relay::CLOSE_TIMEOUT` and then simply ceased to exist: no bytes on either socket, no
    # `ws_messages` row, and a teardown line calling it "released".
    #
    # ## `destination_dead` — the write still happens, the CLAIM does not
    #
    # `write_message` decides whether the peer saw the bytes by whether `@dst.write` RAISED,
    # and that test is silently wrong on exactly this path: a local write to a socket whose
    # peer has already sent FIN succeeds into the kernel buffer. So a message the operator
    # was still holding when the peer vanished was written to a socket nobody was reading,
    # and gori then recorded a `ws_messages` row identical to the one it writes for a message
    # that really arrived — the transcript an operator writes a report from claiming the
    # server received bytes it never received, with `@lost` (the counter that exists for
    # precisely this) left at 0 so the teardown accounting had nothing to say either.
    #
    # `Relay.run` knows which destination is already past that point (`destination_dead?`),
    # and it is the only thing that does. The bytes are STILL written — a genuine half-close
    # (`shutdown(SHUT_WR)`) delivers them, and neither gori nor the operator can distinguish
    # that from a full close — but the row is not written and `@lost` counts it, which is
    # what `write_message`'s own doc-comment already intends: a `ws_messages` row is gori's
    # claim that the peer saw these bytes.
    def settle(reason : String, destination_dead : Bool = false) : Nil
      @mutex.synchronize { @dst_dead = true } if destination_dead
      BYPASS_SETTLE_TURNS.times do
        drained = @mutex.synchronize { fail_open_locked(reason); @queue.empty? || @closed }
        break if drained
        Fiber.yield
      end
    end

    # The direction ended. Fail whatever is left open, THEN shut the gate, then hand every
    # still-held item back to the `Interceptor` — that resolves the queue row, bumps the
    # revision so the TUI redraws, and unblocks the wait fiber, which then finds `@closed`
    # and discards the decision. `H2::StreamGate#close`'s reason for the last part holds
    # here too: without it a dead socket leaves ghost rows in the queue and leaked fibers
    # parked on a channel nobody will ever send to.
    #
    # The ORDER is the fix. `@closed = true` used to run first, so the wait fiber woken by
    # `forward` below reached `resolve_locked`'s `return if @closed` and the message was
    # written to neither socket and to no `ws_messages` row — while the line below called it
    # "released unread", the word for "forwarded without a decision". `fail_open_locked` is
    # the disposition every other involuntary release in this class already takes (the byte
    # ceiling, `bypass`, `release_all`, the #123 reaper, `H2::StreamGate#fail_open`), and a
    # teardown is involuntary. `Relay.run` calls `settle` while the sockets are still open,
    # so by the time this runs the queue is normally already empty; what reaches here is the
    # residue of a decision that raced the teardown.
    def close : Nil
      slots = @mutex.synchronize do
        fail_open_locked("the socket closed with the message still held")
        q = @queue
        @queue = [] of Slot
        @closed = true
        q
      end
      @stranded += slots.count(&.item)
      slots.each { |s| s.item.try { |it| @interceptor.forward(it.id) } }
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
      # An unedited forward keeps the sender's own frames — byte-exact, mask keys and all (P7).
      # An edit is re-framed as ONE frame: once the length changes the sender's fragmentation
      # cannot be reproduced, and a client → server frame is re-masked with a fresh key
      # (RFC 6455 §5.3), exactly as step 1's rewrite path already does.
      unedited = bytes == slot.payload
      @lost += 1 unless write_message(slot.opcode, bytes,
                          unedited ? slot.raw.try(&.data_only) : nil,
                          unedited ? slot.shape : WS::Shape.new(masked: @mask))
    end

    # A direct write with no capture row: the parked control frames of a message this gate is
    # about to hold. They were already recorded by the pump at their arrival position, and a
    # second row would claim gori saw them twice.
    private def write_raw(bytes : Bytes) : Nil
      @dst.write(bytes)
      @dst.flush
    rescue
      # The peer is gone. The pump's next read ends this direction, which is where a dead
      # socket is reported; inventing a failure for a keepalive frame here says nothing new.
    end

    # True iff the bytes can be CLAIMED to have reached the peer. A failed write leaves NO
    # capture row on purpose: a `ws_messages` row is gori's claim that the peer saw these
    # bytes, and inventing one for a write that raised would be the same class of lie as the
    # teardown line this replaced. The teardown log counts the loss instead.
    #
    # A raise was the only failure this tested, and it is not the only one. Once the far end
    # has ended this direction with no CLOSE frame (`@dst_dead`), the write below SUCCEEDS
    # into a kernel buffer and says nothing at all about delivery — which is how a message an
    # operator was still holding when the peer vanished came to be recorded byte-identically
    # to one that really arrived. So the write is still attempted (a genuine half-close does
    # deliver) and the claim is withheld. See `settle`.
    private def write_message(opcode : UInt8, payload : Bytes, raw : Bytes?,
                              shape : WS::Shape = WS::Shape::DEFAULT) : Bool
      @dst.write(raw || WS.encode(opcode, payload, mask: @mask, fin: true))
      @dst.flush
      return false if @dst_dead
      # Record what gori WROTE, not what arrived — the same way step 1's rewrite path keeps
      # P7. The capture has to be the bytes the peer actually sees, framing included.
      @sink.on_ws_message(@flow_id, @direction, opcode.to_i, payload.dup, shape)
      true
    rescue
      false
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

    # A statement about this gate, written where the operator will actually meet it.
    #
    # Both accountings below were `::Log.warn` / `::Log.info` only, and under `gori tui` a
    # `Log` line reaches neither the notification centre nor stderr — so `Relay`'s own
    # promise ("Nothing else tells the operator that their decision window closed — the queue
    # row simply vanishes from the TUI") was unmet for every teardown that is not a CLOSE
    # frame, and the `@dropped` case was equally silent. The row goes on the flow's own
    # `ws_messages` stream, which is the seam `AssemblingPump#warn_teardown_loss` and the
    # `Sec-WebSocket-Extensions` advisory already use: it sits exactly where the message the
    # operator is looking for would have been, and travels to History's WS pane, `gori run
    # show`, MCP `get_flow` and an export alike, instead of to a `gori.log` only an operator
    # who knew to tail it ever reads.
    #
    # On `Relay::NOTICE_DIRECTION` and behind `NOTICE_PREFIX` for the reasons stated there —
    # a diagnostic is not traffic, and a repeater seed must refuse to replay it. The row
    # therefore cannot say which side it is about, so the SENTENCE does. Best-effort: a
    # capture write that fails must never stop a socket from tearing down.
    private def note(text : String) : Nil
      ::Log.warn { "ws #{@direction}: #{text}" }
      @sink.on_ws_message(@flow_id, Relay::NOTICE_DIRECTION, OP_TEXT.to_i,
        "#{NOTICE_PREFIX}#{side}: #{text}".to_slice)
    rescue
      nil
    end

    # This direction in words — see `Relay::AssemblingPump#side`, same reason.
    private def side : String
      to_server? ? "client→server" : "server→client"
    end

    private def warn_fail_open(reason : String) : Nil
      return if @warned_overflow
      @warned_overflow = true
      if @dst_dead
        note("#{reason}, and the peer had already ended this direction without a CLOSE " \
             "frame — #{@queue.size} held message(s) are written out anyway, but gori " \
             "cannot claim they arrived, so no ws_messages row is recorded for them")
      else
        note("#{reason} — forwarding #{@queue.size} held message(s) unedited, in arrival " \
             "order. WebSocket has no application-level flow control, so nothing throttles " \
             "the sender while a hold is out")
      end
    end

    # Each count is a DIFFERENT fate and the operator has to be able to tell them apart —
    # the old line collapsed the last two into "released unread", which named a forward for
    # something that was destroyed.
    private def warn_teardown : Nil
      return if @dropped == 0 && @stranded == 0 && @lost == 0
      parts = [] of String
      parts << "#{@dropped} dropped by the operator" if @dropped > 0
      parts << "#{@lost} written after the peer had already ended this direction, so gori " \
               "cannot claim they arrived" if @lost > 0
      parts << "#{@stranded} discarded still undecided" if @stranded > 0
      note("held message(s) at teardown — #{parts.join(", ")}. None of these left a " \
           "ws_messages row and neither endpoint can see the gap: a WebSocket message has " \
           "no identity for a peer to miss")
    end
  end
end
