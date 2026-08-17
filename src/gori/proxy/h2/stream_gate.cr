require "./frame"
require "./head_codec"
require "./head_rewrite"
require "./assembler"
require "./extract"
require "../sink"
require "../upstream"
require "../../interceptor"
require "../../outbound"
# The class body continues in `stream_gate/` — one class-reopen file per slice, the same shape
# `repeater_view/` and `runner/` use. This file keeps the state (ivars + `initialize`), the pump
# and hold paths, and the lock invariant they are all bound by; the slices are the blocking
# sandbox gate (`sandbox.cr`) and the body buffer + DATA re-framer (`body.cr`).
require "./stream_gate/sandbox"
require "./stream_gate/body"

module Gori::Proxy::H2
  # One direction's writer, and the intercept + sandbox gates in front of it (#492 steps 3-4).
  #
  # ## The sandbox, per stream
  #
  # Intercept and Match&Replace are seams: if they cannot reach h2, a feature silently does
  # nothing. The sandbox is a BLOCKING gate — if it cannot reach h2, out-of-scope requests
  # reach the origin, which is a security defect and not a missing feature. It kept working
  # only because `Tls::Tunnel#h2_candidate?` forced every sandboxed connection down to
  # HTTP/1.1, where `ClientConn#handle_request` blocks per request (`client_conn.cr:249`).
  #
  # #492 step 4 makes it reachable here instead, so the gate could come out of the tunnel.
  # Three things about it are NOT the intercept hold's shape:
  #
  #   1. **The decision is gori's, not a human's**, so it is synchronous on the pump fiber:
  #      no Slot, no wait fiber, no §5.1.1 ordering problem. Skipping a stream id is legal
  #      (a client that cancels before sending does exactly that); only DEFERRING one is not.
  #   2. **It suppresses the head instead of delaying it**, which is a THIRD route into the
  #      §6.2.1 HPACK asymmetry — see `HeadRewrite#latch`, which every refusal engages.
  #   3. **It fails CLOSED.** Everywhere the hold fails open (toggle-off, `release_all`, the
  #      #123 reaper, `MAX_DEFERRED_BYTES`) a blocking gate must not: a refusal it cannot
  #      remember, or a head it cannot read, ends the connection instead of guessing.
  #
  # ## Why a gate rather than a `hold` call in the pump
  #
  # `Interceptor#hold` ends at `item.reply.receive` (`interceptor.cr:260`) and blocks its
  # caller until a human decides. On h1 that costs exactly the one request being held, because
  # a connection carries one request. `Relay#pump` runs ONE fiber per direction for every
  # stream on the connection, so holding there stops the whole connection — a browser tab
  # freezes, a PING goes unanswered, an unrelated download stalls.
  #
  # So the pump never blocks. It hands a held stream's frames to a `Slot` and moves on; a
  # separate fiber per held stream waits on the decision and writes the result through this
  # same object.
  #
  # ## What a held stream may and may not overtake
  #
  # Two rules constrain that, and neither is optional:
  #
  #   1. **RFC 9113 §5.1.1** — a new stream identifier must be greater than every one the
  #      initiator has already opened, and §5.1 implicitly closes the lower idle ones on first
  #      use of a higher. Forwarding stream 5's opening HEADERS while holding stream 3's makes
  #      the late HEADERS(3) a CONNECTION error, killing every other stream with it. So an
  #      opening HEADERS may not overtake a deferred one. Response HEADERS open nothing, so
  #      this binds the request direction only.
  #   2. **HPACK is one sequential per-direction state** (RFC 7541 §2.2). A passthrough block
  #      delivered ahead of a deferred one resolves its dynamic indices against a table missing
  #      the deferred block's insertions. `HeadRewrite#engage` is the answer and is called on
  #      every defer: a re-encoded block reads no index and inserts none, so its position stops
  #      mattering. Deferring therefore costs the direction its HPACK compression for the rest
  #      of the connection — that is the price of legal reordering, paid only by connections
  #      that actually hold something.
  #
  # Everything else keeps flowing: stream 0 frames always, already-open streams' DATA and
  # WINDOW_UPDATE and RST_STREAM, and the entire opposite direction. A held RESPONSE blocks
  # nothing at all.
  #
  # ## What a hold covers (PR #6)
  #
  # The frames behind a deferred head are parked here regardless — nothing may overtake the
  # head (rule 1) — so when the message declares a `content-length` this gate can hold
  # (`MAX_HOLD_BODY`) the hold covers head+BODY: the queue row carries the entity, an edit's
  # body is the operator's, and `release_locked` re-frames it into DATA. The queue row then
  # appears when the message FINISHES arriving, which is h1's own timing (`ClientConn` reads
  # the whole entity before `hold_request`).
  #
  # Every other shape keeps the head-only hold this gate has always had, and each for a reason
  # rather than by omission: no declared length (a streaming upload, SSE, a gRPC stream) means
  # waiting for an end gori cannot predict; over the ceiling means a per-stream buffer on a
  # multiplexed connection (P6); a PADDED DATA frame means showing an operator bytes only
  # `Assembler#data_block` knows how to strip. `Item#head_only?` carries the distinction to
  # every surface, so an edit that adds a body to one of those is refused before it is acked.
  #
  # And the wait for a body has a DEADLINE as well as a ceiling (`HOLD_WAIT_DEADLINE`, PR #11):
  # a declared length says how big the body is, not that it is coming, so a peer that opens
  # `POST` and then stalls would otherwise wait forever with no queue row and every later
  # stream parked behind it. Past the deadline the hold falls back to the same head-only shape.
  #
  # Match&Replace over a BODY is a different question and still forces the h1 downgrade
  # (`Tls::Tunnel#h2_candidate?`): a rule rewrites every matching message on the connection,
  # unbuffered and unattended, where a hold buffers one message a human is already waiting on.
  #
  # ## The lock invariant (deadlock guard)
  #
  # One Mutex per direction guards this gate's state AND its writes, so the order frames are
  # decided in is the order they are written in, with no window between.
  #
  # A drop has to RST the OTHER leg — a request drop crosses out→in, a response drop crosses
  # in→out — so two gates taking each other's locks would deadlock the connection. The shape
  # here makes that structurally impossible rather than accidentally absent:
  #
  #   * every method that mutates gate state is named `*_locked`, runs under `@mutex`, and
  #     RETURNS the opposite direction's work as data (a list of stream ids) instead of doing
  #     it. No `*_locked` method may touch `@peer`.
  #   * `run_cross` and `refund_swallowed` are the only places that touch `@peer`, and both run
  #     after `@mutex` has been released. `write_cross_rst` and `write_cross_window_update` take
  #     their own gate's lock and nothing else.
  #   * they are PAIRED: every path that can settle a slot must run both, or the cross-leg work
  #     it produced sits until something else happens to trigger them. `accept` and `wait_for`
  #     are the two such paths.
  #
  # `Interceptor#hold` is likewise never called under `@mutex` — that is the whole reason the
  # wait lives on its own fiber.
  class StreamGate
    include HeadRewrite::Deferrer

    # RFC 9113 §7. CANCEL (0x8), and the decisive argument is against the obvious alternative:
    # §8.7 makes REFUSED_STREAM a RETRY instruction ("Any request that was sent on the reset
    # stream can be safely retried"), and a request the operator DROPPED is the one request
    # that must never come back. INTERNAL_ERROR would claim gori malfunctioned. CANCEL carries
    # no retry semantics and gRPC maps it to CANCELLED, which is not retried by default.
    #
    # A SANDBOX refusal reuses it, and the retry argument is the reason rather than tidiness:
    # a refused request will be refused again for as long as the scope says so, so telling the
    # client to retry is telling it to loop. One code for both also keeps the wire honest —
    # which of gori's two refusals fired is an operator's business, and History says which
    # (`DROP_REQUEST_REASON` vs `SANDBOX_REASON`), not the client's.
    CANCEL = 0x8_u32

    # Ceiling on the frames parked behind one deferred stream. A sender is already throttled by
    # its own flow-control window — it gets no credit for bytes the far end never saw — so this
    # only bites against a peer that ignores that window. Past it the hold FAILS OPEN, the same
    # disposition as toggle-off (`interceptor.cr:147`), `release_all` and the #123 reaper.
    MAX_DEFERRED_BYTES = 1 << 20

    # Ceiling on a message body this gate will BUFFER so an intercept hold covers head+body
    # (PR #6). Under it the operator sees and edits the whole message and the DATA frames are
    # rebuilt from their bytes; over it — or with no declared length at all — the hold stays the
    # HEAD ONLY and DATA streams past untouched, which is the behaviour every h2 hold had.
    #
    # Deliberately BELOW h1's own hold ceiling (`ClientConn::MAX_REWRITE_BODY`, 16 MiB), and the
    # asymmetry is the protocol's: an h1 connection carries one request, so its ceiling is what
    # one held message can cost. h2 multiplexes — a browser opens ~100 concurrent streams on one
    # connection — so the same number here would be a per-connection ceiling 100x larger than
    # h1's on the single-threaded scheduler this proxy runs on (P6). 1 MiB is the size this file
    # already spends on ONE deferred stream (`MAX_DEFERRED_BYTES`), which is the honest budget.
    #
    # It is a ceiling on the DECLARED length, exactly as `MAX_REWRITE_BODY` is: a body with no
    # `content-length` is not gated here, it is simply not buffered, because "wait for a body
    # whose end gori cannot predict" is how a pump stalls.
    MAX_HOLD_BODY = 1 << 20

    # How long a hold may WAIT for a body it agreed to buffer before giving the wait up and
    # queueing HEAD-ONLY instead. A declared `content-length` is a promise about size, not about
    # arrival: `holdable_body` only proves gori can predict the END of the body, and a client
    # that opens `POST` with a length and then stalls never reaches that end, never trips
    # `check_ceiling` (no bytes arrive to count), and — in the request direction — holds every
    # later stream open behind it (rule 1, `@opens` order). Past this the hold falls back to the
    # head-only shape every unbuffered message already has: the operator gets a row to
    # forward or drop, and the DATA that eventually arrives streams past untouched (P6).
    #
    # Five seconds because the only thing being traded is how much of a slow-but-honest upload
    # the operator gets to see in the editor, against how long a later stream sits behind a peer
    # that has stopped sending. It is a WALL between the head and the end of the body, not a
    # per-frame idle timeout: a message still arriving when it fires is one gori has decided not
    # to keep waiting to show whole.
    HOLD_WAIT_DEADLINE = 5.seconds

    # h1 records exactly these strings (`client_conn.cr:1234`, `:840`, `:1249`), so History
    # reads the same on both protocols.
    DROP_REQUEST_REASON  = "dropped by intercept (request)"
    DROP_RESPONSE_REASON = "dropped by intercept"
    SANDBOX_REASON       = Gori::Outbound::SANDBOX_ERROR

    # One stream whose delivery is deferred. Created only when something is actually held or
    # queued; a connection that holds nothing never allocates one.
    private class Slot
      getter stream_id : UInt32
      # The head block as it arrived (already re-encoded — the latch engaged when this Slot was
      # created). Written as-is on a forward-unedited, re-parsed against on an edit.
      property pending : HeadRewrite::Block?
      # What to write instead, once an edit has been re-encoded.
      property decided : HeadRewrite::Block?
      # The queue entry, while a human still owns the decision.
      property item : Gori::Interceptor::Item?
      property? dropped = false
      property? ready = false
      # Frames that arrived for this stream after its head was deferred, in arrival order —
      # DATA, WINDOW_UPDATE, PRIORITY, trailers. Forwarding any of them ahead of the head is
      # not an option, which is why even a HEAD-ONLY hold parks a body it will not show anyone.
      # A head+body hold reads its entity out of exactly this list (`body_of`).
      getter frames = [] of {Frame::Header, Assembler::HeadBlock?}
      property bytes = 0
      # A hold this gate has DECIDED on but not queued yet: it is buffering the message's body
      # so the operator sees head+body, and a queue row for half a message is not a thing to
      # offer a human. nil once queued, and nil for every head-only hold.
      property waiting : Held?
      # When that wait started, monotonic. `check_waiting_locked` gives the wait up past
      # `HOLD_WAIT_DEADLINE` — the clock the declared length is not.
      property waiting_since : Time::Instant?
      # Extra `check_ceiling` allowance for the body this slot promised to buffer. The parked
      # frames still get their own `MAX_DEFERRED_BYTES` of unrelated traffic on top; without
      # this the buffer gori just agreed to hold would trip the ceiling meant for everything
      # else. 0 for a head-only hold, which is the ceiling exactly as it was.
      property body_budget = 0
      # The message ended — END_STREAM on a DATA frame, on trailers, or on the head itself.
      property? complete = false
      # A DATA frame arrived PADDED, so the buffer is abandoned (see `park`).
      property? padded_body = false
      # The queued hold covers head+body, so an edit's body is the operator's and goes out.
      property? holds_body = false
      # The body an edit replaced the buffered one with. nil = write the DATA that arrived.
      property rebuilt : Bytes?

      def initialize(@stream_id : UInt32)
      end
    end

    # A hold this gate has decided on, with everything `Interceptor#enqueue_*` needs — split out
    # from the enqueue because a head+body hold is decided when the HEAD arrives and queued when
    # the message finishes arriving, and those are different moments.
    private record Held,
      request : Bool,
      stream_id : UInt32,
      method : String,
      target : String,
      host : String,
      port : Int32,
      scheme : String,
      refusal : String?

    property peer : StreamGate?

    # `HOLD_WAIT_DEADLINE` on every gate this proxy builds; settable only so a spec can trip the
    # fallback without spending five real seconds inside it.
    property hold_wait_deadline : Time::Span = HOLD_WAIT_DEADLINE

    def initialize(@direction : String, @dst : IO, @conn_id : Int64, @sink : FlowSink,
                   @assembler : Assembler, @host : String, @port : Int32,
                   @interceptor : Gori::Interceptor, @heads : HeadRewrite,
                   @extract : Extract? = nil)
      @mutex = Mutex.new
      @slots = {} of UInt32 => Slot
      # Deferred stream-OPENING ids in arrival order (= increasing id order), request direction
      # only. Rule 1 above: releases follow this order, not decision order.
      @opens = [] of UInt32
      # Streams gori refused — by the sandbox, or by an operator drop. Their head never reached
      # the far leg, so every LATER frame on them has to be swallowed too: forwarding a refused
      # request's DATA would both hand over the body the gate just refused and be a connection
      # error there (RFC 9113 §5.1 — anything but HEADERS/PRIORITY on an idle stream). Bounded,
      # and the bound ends the connection rather than the guarantee (`MAX_REFUSED_STREAMS`).
      @refused = Set(UInt32).new
      # Cross-direction work produced by the two locked paths that cannot return it: `defer?`,
      # whose Bool is the `Deferrer` contract, and `fail_open`, which is reached from `park` on
      # the frame path. Drained by `accept_locked`, which both run under — `defer?` runs
      # synchronously inside `@heads.accept`, under the same already-held `@mutex`. The lock
      # invariant is intact: this is still "hand the peer's work back as data", not "touch
      # `@peer` under the lock".
      @deferred_cross = [] of UInt32
      @closed = false
      @warned_body = false
      @warned_length = false
      @warned_scope = false
      @warned_overflow = false
      # Connection-level flow-control credit owed back to the SENDER for DATA this gate
      # accepted and discarded. Flushed by `refund_swallowed` once `accept` is out of the lock.
      @swallowed = 0
      # The request direction is the one that opens streams, and the one whose deferred streams
      # the FAR leg has therefore never seen.
      @ordered = @direction == "out"
      @heads.deferrer = self
    end

    # Feed one frame off the wire. Never blocks on a human.
    def accept(frame : Frame::Header) : Nil
      run_cross(@mutex.synchronize { accept_locked(frame) })
      refund_swallowed
    end

    # The direction ended. Release the partial block the rewriter may be holding, hand every
    # still-held item back to the Interceptor so no ghost queue row survives the connection and
    # no wait fiber leaks, and project what was held as Aborted — those bytes never reached the
    # wire, but the ATTEMPT must stay visible, exactly as h1 records a dropped request.
    #
    # h1 cannot do this: its hold IS the connection fiber, so a dead client leaves the row in
    # the queue until a human acts.
    def close : Nil
      slots = @mutex.synchronize do
        # Discard a still-buffered (no-END_HEADERS) block on the REQUEST leg when the sandbox is
        # on: it was never scope-tested, so writing it to the peer is a bypass. `undecodable`'s
        # own gate (`@ordered && sandbox_enabled?`) is the condition. `drain` writes it verbatim
        # otherwise (P7). Discarding cannot raise, so the rest of `close` still runs.
        @heads.drain(discard: @ordered && @interceptor.sandbox_enabled?) { |f, pre| write(f, pre) rescue nil }
        @closed = true
        vals = @slots.values
        @slots.clear
        @opens.clear
        vals
      end
      slots.each do |slot|
        if b = slot.pending
          project(b)
          @assembler.drop_stream(slot.stream_id, "held at intercept when the h2 connection closed")
        end
        # Resolves the queue row, bumps the revision so the TUI redraws, and unblocks the wait
        # fiber — which then finds `@closed` and discards the decision. The Decision value is
        # irrelevant here, which is why this reuses `forward` instead of adding a synonym.
        slot.item.try { |it| @interceptor.forward(it.id) }
      end
    end

    # --- `HeadRewrite::Deferrer` ---------------------------------------------

    # Called with every complete header block, on the pump fiber, already under `@mutex` (we
    # are inside `accept_locked` → `@heads.accept`). Returning true takes ownership of the
    # block's frames.
    def defer?(block : HeadRewrite::Block) : Bool
      if slot = @slots[block.stream_id]?
        # A later block on a stream already deferred — h2 trailers behind a held response head.
        # Already re-encoded: the latch engaged when the Slot was created.
        park_block(slot, block)
        return true
      end
      # The blocking gate runs before the holding one, and before anything is written. A
      # refused stream is never held: there is no decision to offer a human about a request
      # that is not going anywhere.
      return true if sandbox_refuses_locked(block)
      return true if push_refuses_locked(block)
      held = plan_hold(block)
      queued = @ordered && !block.head.nil? && !@opens.empty?
      return false unless held || queued

      block = @heads.engage(block) # rule 2 — MUST precede any later block going out
      slot = Slot.new(block.stream_id)
      slot.pending = block
      @slots[block.stream_id] = slot
      @opens << block.stream_id if @ordered && !block.head.nil?
      if held
        start_hold_locked(slot, held, block)
      else
        slot.ready = true # queued for order only; nothing to decide
      end
      true
    end

    # Queue this hold now, or wait for the rest of the message first (PR #6).
    #
    # A body gori can BUFFER makes the hold cover head+body, and the queue row for it cannot
    # appear until the body has finished arriving — half a message is not a thing to offer a
    # human. That is not a new discipline: h1's hold has always read the whole entity BEFORE
    # `hold_request` (`ClientConn#handle_hold_request`), so "the row appears when the message
    # is complete" is the behaviour operators already have on the other protocol.
    #
    # What h2 adds is that the wait costs the REQUEST direction its later stream opens (rule 1
    # pins releases to `@opens` order), so a client that stalls mid-upload delays the streams
    # behind it. Three things bound it: the declared length gate (`holdable_body`, so gori only
    # ever waits for an end it can predict), `check_ceiling`, which fails the whole run of slots
    # open past the ceiling, and `HOLD_WAIT_DEADLINE` — the one that answers the peer sending
    # NOTHING, which the other two cannot see because they both measure bytes that arrived.
    private def start_hold_locked(slot : Slot, held : Held, block : HeadRewrite::Block) : Nil
      budget = holdable_body(block)
      unless budget
        queue_hold_locked(slot, held, nil)
        return
      end
      slot.body_budget = budget
      slot.waiting = held
      slot.waiting_since = Time.instant
      # A head carrying END_STREAM IS the whole message (a GET, a 204, a reply to HEAD), so
      # there is nothing to wait for and its buffered body is zero bytes long.
      slot.complete = true if block.first.end_stream?
      settle_waiting_locked(slot)
    end

    # Queue a decided hold and start its wait fiber. `body` nil = the hold covers the HEAD only.
    private def queue_hold_locked(slot : Slot, held : Held, body : Bytes?) : Nil
      slot.waiting = nil
      block = slot.pending
      head = block.try(&.head)
      item = block && head ? enqueue_hold(held, head, body) : nil
      if block && item
        slot.holds_body = !body.nil?
        slot.item = item
        wait_for(item, block)
        return
      end
      # Intercept was switched off between the gate check and the enqueue (or between the head
      # and the end of the body, which is a whole upload's worth of window on the buffering
      # path). Nothing will ever decide this slot, so it must not sit in `@slots` waiting for a
      # decision that cannot come — that is the freeze `fail_open`'s comment describes, reached
      # through a race instead of through the ceiling.
      slot.ready = true
      @deferred_cross.concat(drain_locked)
    end

    # Put the hold on the Interceptor's queue. `raw` is what the operator sees and edits: the h1
    # text form of the head, plus the buffered entity when there is one.
    private def enqueue_hold(held : Held, head : Bytes, body : Bytes?) : Gori::Interceptor::Item?
      raw = body ? join(head, body) : head
      if held.request
        @interceptor.enqueue_request(raw, method: held.method, target: held.target,
          host: held.host, port: held.port, scheme: held.scheme,
          edit_refusal: held.refusal, head_only: body.nil?)
      else
        @interceptor.enqueue_response(raw, flow_id: @assembler.flow_id_of(held.stream_id),
          method: held.method, target: held.target, host: held.host, port: held.port,
          scheme: held.scheme, edit_refusal: held.refusal, head_only: body.nil?)
      end
    end

    # --- pump side (locked) --------------------------------------------------

    private def accept_locked(frame : Frame::Header) : Array(UInt32)
      return NO_CROSS if @closed
      check_waiting_locked
      cross = NO_CROSS
      # Every header block goes through `@heads` even for a deferred stream: the per-direction
      # HPACK decoder must advance in ARRIVAL order, so a block cannot wait in a Slot undecoded
      # and be decoded later out of sequence. That holds for a REFUSED stream too — its later
      # blocks (trailers) still carry the peer's HPACK insertions, so they must be decoded even
      # though nothing is written.
      @heads.accept(frame) do |f, pre|
        if f.stream_id == 0
          # Connection-level frames are NEVER deferred (#492 step 3, D1 rule 1): parking a
          # SETTINGS ACK, a PING or the SHARED connection window behind a held stream kills the
          # connection or starves every stream on it. They now flow THROUGH `@heads.accept`
          # rather than being hoisted ahead of it, so one arriving inside a buffered header
          # block hits the §6.2/§6.10 intruder rule (ending the connection under the sandbox)
          # instead of being reordered past it and the block silently repaired. `HeadRewrite`'s
          # `opens` excludes stream 0, so a `HEADERS(0)` — itself a §6.2 connection error —
          # cannot open a buffered block here and mint a Slot keyed 0 that later PINGs park
          # behind. `Assembler#feed` already treats stream 0 as not-a-stream.
          write(f, nil)
          next
        end
        slot = @slots[f.stream_id]?
        if @refused.includes?(f.stream_id)
          # Swallowed, not written: the far leg never saw this stream open. Deliberately not
          # captured either — `write` is what logs a frame and P7 logs what gori actually wrote.
          # But the sender's CONNECTION window was still charged for these bytes and nothing
          # downstream will ever credit them back, so they are counted here and refunded once
          # `accept` is out of the lock. See `refund_swallowed`.
          @swallowed += f.payload.size if f.frame_type == Frame::Type::Data
        elsif slot.nil?
          write(f, pre)
        elsif f.frame_type == Frame::Type::RstStream
          cross = cross + abandon_locked(slot, f)
        else
          park(slot, f, pre)
          after_park(slot)
        end
      end
      take_deferred_cross(cross)
    end

    # The two ways a hold still WAITING for its body gives that wait up (PR #6, #11). Such a
    # slot has no queue row, so `Interceptor#toggle`'s release and `release_all` cannot reach
    # it — and in the request direction it sits at the head of `@opens`, holding every later
    # stream open.
    #
    #   * **Intercept switched off.** Nobody is holding the message any more, so the body gori
    #     was buffering is being buffered for no one. Toggle-off is one of this file's
    #     documented fail-open exits and has to stay one.
    #   * **The wait ran past `HOLD_WAIT_DEADLINE`,** intercept still on. A declared length
    #     bounds the SIZE of the wait, not its duration, so this is the only thing standing
    #     between a peer that stalls mid-upload and a connection whose later streams never move:
    #     no bytes arrive, so `check_ceiling` never fires, and there is no queue row for an
    #     operator to resolve either.
    #
    # Both take the same exit, and it is the pre-PR-#6 hold rather than a refusal: queue
    # HEAD-ONLY, and the DATA that does arrive streams past untouched. On toggle-off the enqueue
    # inside returns nil anyway (`Interceptor#enqueue` tests the same condition), so
    # `queue_hold_locked` takes its own not-held exit and drains the slot instead.
    #
    # Checked on frame arrival rather than on a timer, and that is sufficient rather than merely
    # cheap: a waiting slot with nothing behind it blocks nobody, and a stream blocked BEHIND
    # one only becomes blocked when its own frames arrive HERE — including the HEADERS that
    # opens it, since `accept_locked` runs this before it defers anything. A timer fiber would
    # buy only the case where the wait costs nothing, at the price of one more fiber per
    # buffering hold on the pump's own path (P6). Costs an empty-Hash test on every frame of a
    # connection holding nothing, which is the common case.
    private def check_waiting_locked : Nil
      return if @slots.empty?
      waiting = @slots.each_value.select(&.waiting).to_a
      return if waiting.empty?
      if @interceptor.holding?
        now = Time.instant
        waiting.select! do |slot|
          since = slot.waiting_since
          since && now - since >= hold_wait_deadline
        end
        return if waiting.empty?
      end
      waiting.each { |slot| slot.waiting.try { |held| queue_hold_locked(slot, held, nil) } }
    end

    # `defer?` cannot return cross-direction work, so it parks it here. Merged on the way out
    # of the lock, where `accept` hands the whole list to `run_cross`.
    private def take_deferred_cross(cross : Array(UInt32)) : Array(UInt32)
      return cross if @deferred_cross.empty?
      taken = cross + @deferred_cross
      @deferred_cross.clear
      taken
    end

    # The peer cancelled a stream we are holding, so the operator's decision is moot. Give the
    # queue row back, project the attempt, discard the buffers — and forward the RST only to a
    # leg that actually has the stream open: a deferred REQUEST never reached the origin, and
    # RST_STREAM on an idle stream is itself a connection error (RFC 9113 §6.4).
    private def abandon_locked(slot : Slot, frame : Frame::Header) : Array(UInt32)
      slot.item.try { |it| @interceptor.forward(it.id) }
      slot.item = nil
      if b = slot.pending
        project(b)
        @assembler.drop_stream(slot.stream_id, "stream reset by the peer while held at intercept")
      end
      # The parked frames are dropped on the floor here, and their DATA was charged to the
      # sender's connection window just as the refused-branch DATA was. See `refund_swallowed`.
      charge_swallowed(slot)
      remove(slot)
      write(frame, nil) unless @ordered
      drain_locked
    end

    # Buffer one frame behind a deferred head. The ceiling is `check_ceiling`'s, deliberately
    # separate: `fail_open` writes the slot out and takes it out of `@slots`, so anything parked
    # into it afterwards would never be written at all. One arrival is therefore parked WHOLE
    # and measured once — `park_block` hands over a multi-frame header block, and releasing
    # halfway through one would silently drop its remaining CONTINUATIONs.
    private def park(slot : Slot, frame : Frame::Header, pre : Assembler::HeadBlock?) : Nil
      slot.frames << {frame, pre}
      slot.bytes += frame.payload.size
      note_body_frame(slot, frame) if slot.waiting
    end

    # Track a buffering hold's progress. Nothing here writes or settles — `after_park` owns
    # that, so a frame is always parked WHOLE before anything can release the slot under it.
    #
    # A PADDED DATA frame gives the buffer up. Padding is a display concern the assembler
    # already answers (`Assembler#data_block` strips it, and raises on a pad length the frame
    # cannot hold), and re-deriving that here next to a second caller is the shape AGENTS.md
    # names as a trap — with the extra cost that this copy would raise on the pump fiber, where
    # a malformed pad would end the connection instead of being projected around. So a padded
    # body is simply one gori will not show an operator: the hold falls back to HEAD-ONLY,
    # which is where every other unbuffered shape already lands.
    private def note_body_frame(slot : Slot, frame : Frame::Header) : Nil
      if frame.frame_type == Frame::Type::Data
        slot.padded_body = true if frame.padded?
        slot.complete = true if frame.end_stream?
      elsif frame.frame_type == Frame::Type::Headers
        # Trailers end the message when they carry END_STREAM (RFC 9113 §8.1).
        slot.complete = true if frame.end_stream?
      end
    end

    private def park_block(slot : Slot, block : HeadRewrite::Block) : Nil
      last = block.frames.size - 1
      block.frames.each_with_index { |f, i| park(slot, f, i == last ? block.pre : nil) }
      after_park(slot)
    end

    # Everything that may release or settle a slot once one arrival has been parked whole.
    # Ceiling first: `fail_open` writes the slot out and takes it out of `@slots`, so a hold
    # queued after that would have no slot left to decide.
    private def after_park(slot : Slot) : Nil
      check_ceiling(slot)
      return unless @slots.has_key?(slot.stream_id)
      settle_waiting_locked(slot)
    end

    # Queue a hold that was waiting for the rest of its message, once the message is in hand —
    # or once the buffer has been given up, in which case it queues HEAD-ONLY and the parked
    # DATA goes out as it arrived.
    private def settle_waiting_locked(slot : Slot) : Nil
      held = slot.waiting
      return unless held
      return unless slot.complete? || slot.padded_body?
      queue_hold_locked(slot, held, slot.padded_body? ? nil : body_of(slot))
    end

    # `body_budget` is the entity this slot PROMISED to buffer (0 for a head-only hold), so the
    # ceiling still measures what it was written to measure: unrelated frames piling up behind a
    # deferred stream. Without the term, agreeing to hold a 1 MiB body would immediately trip the
    # 1 MiB ceiling meant for everything else and fail the hold open on its own buffer.
    private def check_ceiling(slot : Slot) : Nil
      fail_open(slot) if slot.bytes > MAX_DEFERRED_BYTES + slot.body_budget
    end

    # Past the buffer ceiling. The hold FAILS OPEN: the head goes out as it arrived, the parked
    # frames follow it, and the queue row is resolved — the disposition `MAX_DEFERRED_BYTES`
    # documents, and the same one toggle-off, `release_all` and the #123 reaper have.
    #
    # Two things this must not do, both of which it did before #516:
    #
    #   1. **Null `item` and stop.** `Interceptor#forward` only puts a Decision on the item's
    #      channel; the RELEASE is `resolve_locked`'s, on the wait fiber, and its first act is
    #      `slot.item == item`. Clearing the item first made that guard reject the decision, so
    #      the slot stayed in `@slots` with `ready? == false` and — in the request direction —
    #      its id stayed at the head of `@opens`, freezing every LATER stream open for the life
    #      of the connection. That is the "a held stream freezes the connection" failure this
    #      whole file exists to avoid, reached through the one exit that claimed to avoid it.
    #      So the settle happens HERE, under the lock, and `forward` is only how the queue row
    #      and the wait fiber are disposed of.
    #   2. **Release the overflowing slot alone.** Rule 1 pins releases to `@opens` order, so a
    #      slot with a deferred open still ahead of it moves nothing however it is settled.
    #      Every slot from the head of the queue up to this one fails open together, which is
    #      also the only thing that makes the warning below true.
    private def fail_open(slot : Slot) : Nil
      targets = blocking_slots(slot)
      return if targets.empty?
      warn_overflow(slot, targets.size - 1)
      targets.each { |target| fail_one_open(target) }
      @deferred_cross.concat(drain_locked)
    end

    # Make one slot releasable, with the head as it arrived: `decided` is deliberately left
    # alone, so `release_locked` writes `pending`. A slot the operator already decided keeps
    # that decision — this only makes it movable.
    private def fail_one_open(target : Slot) : Nil
      item = target.item
      # A decision is already on this item's channel (the operator acted, and its wait fiber has
      # not been scheduled yet). That fiber owns the settle and will run it in a moment; failing
      # the slot open here would DISCARD the decision, and forwarding a request the operator
      # dropped is the one outcome worse than holding it.
      return if item && @interceptor.get(item.id).nil?
      unless item
        # A hold still WAITING for its body has no item yet (PR #6) and never will: past the
        # ceiling gori has stopped buffering, so there is nothing left to offer a human.
        target.waiting = nil
        target.ready = true
        return
      end
      # The probe above is not a claim: an operator DROP landing between it and here would make
      # `forward` a no-op while this slot went ready with no item, and the wait fiber's
      # `slot.item == item` guard would then reject the real Drop — releasing a request the
      # operator dropped. `forward` reports whether it was the one that settled the item, so a
      # lost race leaves the slot exactly as it was and its wait fiber owns the outcome.
      return unless @interceptor.forward(item.id)
      target.item = nil
      target.ready = true
    end

    # Every slot that has to move for `slot` to be released, in release order. In the request
    # direction rule 1 makes that the run of deferred opens from the head of `@opens` up to and
    # including this one. In the response direction nothing opens streams, so a slot releases on
    # its own.
    private def blocking_slots(slot : Slot) : Array(Slot)
      return [slot] unless @ordered && @opens.includes?(slot.stream_id)
      ahead = [] of Slot
      @opens.each do |id|
        @slots[id]?.try { |s| ahead << s }
        break if id == slot.stream_id
      end
      ahead
    end

    # Once per direction per connection. It says what actually happens next, which is the other
    # half of #516: the old text claimed "forwarded it unedited" on a path that forwarded
    # nothing at all and left the connection dead.
    private def warn_overflow(slot : Slot, ahead : Int32) : Nil
      return if @warned_overflow
      @warned_overflow = true
      ::Log.warn do
        also = ahead > 0 ? " (releasing #{ahead} stream(s) deferred ahead of it too)" : ""
        "h2 #{@direction}: held stream #{slot.stream_id} buffered over " \
        "#{MAX_DEFERRED_BYTES + slot.body_budget} bytes — forwarding it unedited#{also}"
      end
    end

    # --- hold side -----------------------------------------------------------

    # Ask the Interceptor whether this head is held, and describe the hold if so. Returns nil
    # (forward normally) for a block that is not a message head, an interim 1xx, or anything the
    # precise per-request/per-response gates decline.
    #
    # DECIDING is separate from QUEUEING (PR #6). A hold that buffers the message's body is
    # decided here, when the head arrives, and queued later, when the body has finished
    # arriving — so the two halves cannot be one call any more.
    private def plan_hold(block : HeadRewrite::Block) : Held?
      head = block.head
      return nil unless head
      block.request ? plan_request(block, head) : plan_response(block, head)
    end

    private def plan_request(block : HeadRewrite::Block, head : Bytes) : Held?
      fields = block.fields
      authority = HeadCodec.pseudo_of(fields, ":authority") || @host
      host, port = Upstream.split_host_port(authority, @port)
      method = HeadCodec.pseudo_of(fields, ":method") || "GET"
      target = HeadCodec.pseudo_of(fields, ":path") || "/"
      scheme = HeadCodec.pseudo_of(fields, ":scheme") || "https"
      # `head` is the encoded h1-shaped head this block projects to, which is what the operator
      # sees when the message is held — so a `header:` term reads the same bytes on h2 as on h1.
      # The gate reads the HEAD even when the hold will carry a body: a `header:` term is a
      # question about the head on both protocols, and the body has not arrived yet anyway.
      return nil unless @interceptor.intercepts_request?(
                          method: method, host: host, target: target, scheme: scheme, head: head)
      Held.new(request: true, stream_id: block.stream_id, method: method, target: target,
        host: host, port: port, scheme: scheme, refusal: edit_refusal(block))
    end

    private def plan_response(block : HeadRewrite::Block, head : Bytes) : Held?
      status = (HeadCodec.pseudo_of(block.fields, ":status") || "0").to_i? || 0
      # h1 skips interim 1xx BEFORE the hold gate (`client_conn.cr:467` → `:501`), so an Early
      # Hints response never consumes the decision meant for the real one. Parity, not a gap.
      return nil if status < 200
      ref = @assembler.request_ref(block.stream_id)
      if ref.nil?
        # No request projected for this stream. h1 scopes a response hold on the REQUEST's
        # target (`client_conn.cr:501`); with no request target there is nothing to scope
        # against, and inventing one is how a hold escapes scope. Warn only when a hold could
        # actually have happened — this runs before `intercepts_response?`, so it used to fire
        # on connections with intercept switched off entirely.
        warn_unscopable(block.stream_id) if @interceptor.enabled?
        return nil
      end
      host, port = Upstream.split_host_port(ref.authority, @port)
      return nil unless @interceptor.intercepts_response?(
                          method: ref.method, host: host, target: ref.target,
                          scheme: ref.scheme, status: status, head: head)
      # h1's response Item carries "<status> <reason>"; h2 has no reason phrase (§8.3.2).
      Held.new(request: false, stream_id: block.stream_id, method: ref.method,
        target: status.to_s, host: host, port: port, scheme: ref.scheme,
        refusal: edit_refusal(block))
    end

    # Why an edit to this held head cannot be applied, or nil. Asked HERE — at hold time, on
    # the pump fiber — because `h1_faithful?` is a pure function of the block's decoded fields,
    # so the answer is already knowable and the surface can refuse before the operator writes
    # the edit. It used to be discovered on the wait fiber, inside `HeadRewrite#encode_edited`,
    # whose `|| block` fallback in `edited` silently threw the edit away long after the CLI /
    # MCP / TUI had reported it applied.
    private def edit_refusal(block : HeadRewrite::Block) : String?
      reason = HeadCodec.h1_unfaithful_reason(block.fields, block.request)
      return nil unless reason
      "gori will not apply an edit to this HTTP/2 message: #{reason}. The h1 text form shown " \
      "here is lossy for it, so an edit would be applied to a different message than the one " \
      "the peer sent (#517) — the fields go out exactly as they arrived"
    end

    private def wait_for(item : Gori::Interceptor::Item, block : HeadRewrite::Block) : Nil
      spawn do
        decision = item.reply.receive
        # The same PAIRING `accept` has, and it is not optional here: a DROP settles on THIS
        # fiber (`resolve_locked` -> `drain_locked` -> `release_locked` -> `drop_locked`), which
        # charges `@swallowed` for the parked DATA it discards. With only `accept` flushing, the
        # credit sat until the client happened to send another frame — and a client whose
        # remaining work is DATA has no window left to send one with, which is the wedge this
        # refund exists to prevent, reached through the intercept path instead of the sandbox.
        begin
          run_cross(@mutex.synchronize { resolve_locked(item, block, decision) })
        rescue
          # The held peer died between the hold and the operator's decision, so the write
          # inside `release_locked` raises. This is a SPAWNED fiber: an escape here has no
          # caller to unwind to and reaches Crystal's fiber handler, which prints
          # "Unhandled exception in spawn" plus a backtrace on STDERR — under `gori tui`
          # that lands on top of the rendered frame. Every other writer in this file is
          # already guarded (`close`, `write_cross_rst`, `write_cross_window_update`), as
          # is the WebSocket twin in `ws/message_gate.cr`; this one was the hole.
          #
          # Slots already ready behind the one that raised stay queued until `close`
          # drains them, which is the same place they would have gone had the leg died a
          # moment earlier.
          #
          # No spec: the only observable difference is Crystal's fiber handler printing,
          # which a spec cannot assert from in-process, and the `refund_swallowed` below is
          # a no-op on the path that raises (a FORWARD discards nothing, so nothing is
          # owed). This guard rests on symmetry with the three writers above rather than on
          # a reproduction — an attempt at one passed with and without it, so it was dropped
          # rather than kept as a spec that proves nothing.
        end
        # Runs either way: the refund is credit for DATA gori discarded, and the leg being
        # dead is exactly when a wedged client most needs it. Its own write is guarded.
        refund_swallowed
      end
    end

    private def resolve_locked(item : Gori::Interceptor::Item, block : HeadRewrite::Block,
                               decision : Gori::Interceptor::Decision) : Array(UInt32)
      return NO_CROSS if @closed
      slot = @slots[block.stream_id]?
      # Already abandoned (peer RST), failed open, or torn down: the decision arrived too late
      # and there is nothing left to apply it to.
      return NO_CROSS unless slot && slot.item == item
      slot.item = nil
      if decision.action.drop?
        slot.dropped = true
      else
        # `item.raw` rather than `block.head`: what the operator was SHOWN is the whole hold,
        # and on a head+body hold that is head + entity. The two are the same bytes on a
        # head-only hold, so this is one test for both shapes rather than a second one.
        slot.decided = decision.bytes == item.raw ? block : edited(slot, block, decision)
      end
      slot.ready = true
      drain_locked
    end

    # The operator's bytes, back through the same pipeline a rule takes.
    private def edited(slot : Slot, block : HeadRewrite::Block,
                       decision : Gori::Interceptor::Decision) : HeadRewrite::Block
      head, has_body = Gori::Interceptor.split_edit(decision.bytes)
      body = has_body ? decision.bytes[head.size..] : Bytes.empty
      return edited_with_body(slot, block, head, body) if slot.holds_body?
      # A HEAD-ONLY hold — the message's body was streaming, undeclared, or over
      # `MAX_HOLD_BODY`, so DATA goes past this gate untouched and a body typed into the editor
      # has nowhere to go. `Item#head_only?` lets the surface refuse the edit outright, so
      # reaching here means a caller that did not check; say it once anyway.
      if has_body && !@warned_body
        @warned_body = true
        ::Log.warn { "h2 #{@direction}: an intercept edit added a body (stream #{block.stream_id}) — this hold covers the head only (no declared content-length, or one over #{MAX_HOLD_BODY} bytes), so the body was ignored" }
      end
      restore = length_synced?(head, body.size)
      warn_length_restored(block.stream_id) if restore && declares_length?(head)
      @heads.encode_edited(block, head, restore) || block
    end

    # An edit to a hold that covered head+body (PR #6). The operator's bytes ARE the message, so
    # both halves go out as they wrote them and `release_locked` re-frames the body into DATA.
    #
    # `restore_length: false` is the whole of the difference, and it is the R3-F2 rule reaching
    # its own base case rather than an exception to it. `length_synced?` exists because a
    # head-only hold carries no body, so a `content-length` that AGREES with the edit's body
    # describes bytes gori was not going to send — an "update Content-Length" affordance
    # computing a value FOR the operator, which is why the peer's value went back. Here the
    # edit's body IS what gori sends, so a synced value is simply true and a mismatched one is
    # the RFC 9113 §8.1.1 probe the operator asked for. Both go out verbatim, which is exactly
    # what h1 does with the identical edit (P7).
    private def edited_with_body(slot : Slot, block : HeadRewrite::Block,
                                 head : Bytes, body : Bytes) : HeadRewrite::Block
      # Only a CHANGED body is re-framed. An operator who edited the head alone keeps the
      # peer's own DATA frames byte-for-byte, boundaries included.
      slot.rebuilt = body unless body == body_of(slot)
      @heads.encode_edited(block, head, false) || block
    end

    # The restore is a rewrite of the operator's own bytes, so it does not get to be silent —
    # the reasoning `warned_body` already had, applied to the other thing this path changes.
    private def warn_length_restored(stream_id : UInt32) : Nil
      return if @warned_length
      @warned_length = true
      ::Log.warn do
        "h2 #{@direction}: an intercept edit's content-length agreed with the body the edit " \
        "carried, which is what an \"update Content-Length\" affordance produces — the peer's " \
        "original value was put back (stream #{stream_id}), because h2 holds the head only and " \
        "the DATA frames are unchanged. To send a content-length that disagrees with the DATA " \
        "(the RFC 9113 §8.1.1 probe), declare it with the editor's Content-Length sync OFF"
      end
    end

    # --- release -------------------------------------------------------------

    # Release every slot that can now go out, in the only order that is legal.
    private def drain_locked : Array(UInt32)
      cross = NO_CROSS
      if @ordered
        # Request direction: releases follow stream-id order, because that is the order the
        # origin must see opens in (rule 1). A forwarded-but-still-queued stream waits here.
        while (id = @opens.first?) && (slot = @slots[id]?) && slot.ready?
          @opens.shift
          @slots.delete(id)
          cross = cross + release_locked(slot)
        end
      else
        # Response direction: nothing opens streams, so each slot releases on its own.
        @slots.values.select(&.ready?).each do |slot|
          @slots.delete(slot.stream_id)
          cross = cross + release_locked(slot)
        end
      end
      cross
    end

    private def release_locked(slot : Slot) : Array(UInt32)
      return drop_locked(slot) if slot.dropped?
      body = slot.rebuilt
      if b = slot.decided || slot.pending
        # An edit that gives a bodiless message a body has to take END_STREAM off the head:
        # DATA after a half-closed stream is a §5.1 protocol error, so the flag moves onto the
        # last rebuilt DATA frame instead.
        moved = !body.nil? && !body.empty? && b.first.end_stream?
        frames = moved ? b.frames.map { |f| without_end_stream(f) } : b.frames
        last = frames.size - 1
        frames.each_with_index { |f, i| write(f, i == last ? b.pre : nil) }
      end
      if body
        write_rebuilt(slot, body)
      else
        slot.frames.each { |(f, pre)| write(f, pre) }
      end
      NO_CROSS
    end

    # An operator drop. The head never went on the wire, so it is fed to the assembler for the
    # PROJECTION ONLY — `write` is what logs a frame, and P7 logs what gori actually wrote —
    # and the flow is finalized with h1's own reason string.
    #
    # Then RST_STREAM(CANCEL) on the legs that actually have the stream open. A dropped REQUEST
    # was held at its opening HEADERS, so the origin never saw the stream and must not be sent
    # an RST for it (RFC 9113 §6.4); only the client is told. A dropped RESPONSE is open on both
    # legs, so both are told: the client stops waiting and the origin stops sending a body we
    # are discarding.
    private def drop_locked(slot : Slot) : Array(UInt32)
      if b = slot.pending
        project(b)
        # A dropped REQUEST carries its buffered body into History the way h1's
        # `record_dropped_request` does. A dropped RESPONSE deliberately does not: feeding its
        # DATA would let the assembler emit the exchange COMPLETE and delete the stream, and
        # the abort marker below would then find nothing to mark.
        slot.frames.each { |(f, pre)| @assembler.feed(@direction, f, pre) } if @ordered
      end
      @assembler.drop_stream(slot.stream_id, @ordered ? DROP_REQUEST_REASON : DROP_RESPONSE_REASON)
      write(rst_frame(slot.stream_id), nil) unless @ordered
      # A drop is a refusal too, and it leaves the same opening: the slot is gone from `@slots`,
      # so a client that keeps sending on a dropped REQUEST would have its DATA written to an
      # origin that never saw the stream open. Sharing `@refused` with the sandbox closes it for
      # both. (`abandon_locked` deliberately does not: there the PEER reset the stream, so it is
      # the one that has stopped sending, and charging its cancellations to the ceiling below
      # would let an ordinary client cancel its way into a connection teardown.)
      # Its parked DATA is never written on either leg — see `charge_swallowed`.
      charge_swallowed(slot)
      remember_refused(slot.stream_id)
      [slot.stream_id]
    end

    # --- writing -------------------------------------------------------------

    # Forward one frame, then capture it, then project it — `Relay#emit`'s order, moved here so
    # a released hold and the pump write through the same lock and the same code.
    private def write(frame : Frame::Header, pre : Assembler::HeadBlock?) : Nil
      @dst.write(frame.wire_bytes)
      @dst.flush
      @sink.on_h2_frame(@conn_id, @direction, frame.type, frame.flags, frame.stream_id, frame.payload)
      # Session-binding extraction (#501 slice 2), on the frames that were actually WRITTEN.
      # A head the sandbox suppressed or the operator dropped goes to `project`, not here, so
      # "delivered, not arrived" holds structurally. Response direction only, and nil for every
      # frame that is not the end of a header block.
      #
      # BEFORE `feed`, and see `Relay#emit` for why: a bodiless response head completes the
      # exchange inside `feed`, which deletes the stream the extractor needs to scope on.
      @extract.try(&.observe(frame, pre))
      @assembler.feed(@direction, frame, pre)
    end

    # Feed a held head to the assembler for the DECODED projection only, without logging it as
    # a frame: these bytes never went on the wire.
    private def project(block : HeadRewrite::Block) : Nil
      last = block.frames.size - 1
      block.frames.each_with_index { |f, i| @assembler.feed(@direction, projected(f), i == last ? block.pre : nil) }
    end

    # The frame as the PROJECTION should see it. In the RESPONSE direction END_STREAM is
    # cleared, and that is the whole of this method.
    #
    # Every caller of `project` is a message the client did NOT receive — a sandbox refusal,
    # an operator drop, a peer RST while held, a teardown with the hold still out. A response
    # head carrying END_STREAM (a 204, a 304, a reply to HEAD, a bodiless 3xx — everyday
    # traffic) COMPLETES the exchange inside `feed_locked`, which then deletes the stream, so
    # the `drop_stream` abort marker on the very next line found nothing and History recorded
    # the exchange as Complete and delivered. The operator's drop was invisible in the record.
    #
    # `drop_locked` already makes exactly this call for the parked DATA and says why ("feeding
    # its DATA would let the assembler emit the exchange COMPLETE and delete the stream"); the
    # HEAD needed it for the same reason and did not have it. The raw frame log is untouched —
    # `write` is what logs a frame and nothing was written here — so P7 is not in question:
    # this is gori's model of an exchange that did not finish, and it did not finish.
    #
    # REQUEST direction is left alone. There END_STREAM ends the request, not the exchange,
    # so the stream stays open for `drop_stream` to mark, and clearing it would lose the fact
    # that the request had no body.
    private def projected(f : Frame::Header) : Frame::Header
      return f if @ordered || !f.end_stream?
      Frame::Header.new(f.type, f.flags & ~Frame::END_STREAM, f.stream_id, f.payload, nil)
    end

    private def rst_frame(stream_id : UInt32) : Frame::Header
      payload = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(CANCEL, payload)
      Frame::Header.new(Frame::Type::RstStream.value, 0_u8, stream_id, payload)
    end

    # Called by the OPPOSITE direction's gate. Takes this gate's lock and nothing else — the
    # caller has already released its own. See the lock invariant in the class comment.
    def write_cross_rst(stream_id : UInt32) : Nil
      @mutex.synchronize do
        return if @closed
        write(rst_frame(stream_id), nil)
      end
    rescue
      # this leg is already gone; the drop still happened on the leg that mattered
    end

    # The ONLY place `@peer` is touched, and it runs with `@mutex` released.
    private def run_cross(ids : Array(UInt32)) : Nil
      return if ids.empty?
      peer = @peer
      return unless peer
      ids.each { |id| peer.write_cross_rst(id) }
    end

    # Count a slot's parked DATA as owed credit. Called where those frames are DISCARDED
    # rather than written — `abandon_locked` and `drop_locked`. A released slot's frames go
    # through `write`, so the far end sees them and generates its own WINDOW_UPDATE; only the
    # discarded ones have nobody to credit them.
    private def charge_swallowed(slot : Slot) : Nil
      slot.frames.each do |(f, _)|
        @swallowed += f.payload.size if f.frame_type == Frame::Type::Data
      end
    end

    # Give the SENDER back the connection-level flow-control credit for DATA this gate
    # accepted and then threw away.
    #
    # RFC 9113 §6.9.1: the connection window is only ever reduced by DATA and only ever
    # restored by a WINDOW_UPDATE — RST_STREAM refunds nothing, and a receiver that discards
    # accepted DATA must still return the credit or the sender's window shrinks for good.
    # gori is normally transparent here (it forwards DATA and the far end's WINDOW_UPDATEs
    # flow back through it), but a SWALLOWED frame never reaches a far end, so no
    # WINDOW_UPDATE is ever generated for it by anyone. Measured against a real client:
    # 120 KiB pushed at a sandbox-refused stream, credit returned 0. Past the default 65535
    # the client can send DATA on NO stream — in-scope ones included.
    #
    # Connection level only (stream 0). The stream itself is refused or dropped and its own
    # window dies with it; it is the shared one that wedges the connection.
    #
    # Written on the PEER's leg, because that is the one facing the sender — the same
    # `@peer` seam `write_cross_rst` uses, and with `@mutex` released for the same reason.
    private def refund_swallowed : Nil
      n = @mutex.synchronize do
        v = @swallowed
        @swallowed = 0
        v
      end
      return if n <= 0
      @peer.try(&.write_cross_window_update(n))
    end

    # Called by the OPPOSITE direction's gate. Takes this gate's lock and nothing else — the
    # caller has already released its own, exactly as `write_cross_rst` requires.
    def write_cross_window_update(increment : Int32) : Nil
      @mutex.synchronize do
        return if @closed
        payload = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(increment.to_u32 & 0x7fff_ffff_u32, payload)
        # Through `write`, exactly as `write_cross_rst` does — so this frame lands in the raw
        # frame log like every other byte gori puts on the wire. Writing straight to `@dst`
        # left the operator reading that log during a stalled upload (which is when you read
        # it) seeing WINDOW_UPDATEs arrive from nowhere, with gori's own record disagreeing
        # with the wire. The `@refused` branch's "P7 logs what gori actually wrote" cuts both
        # ways: it justifies not logging a frame gori swallowed, and requires logging one gori
        # synthesized. Safe on this frame: `feed` returns immediately for stream 0 and
        # `@extract.observe` needs a `pre`, which a WINDOW_UPDATE never has.
        write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, 0_u32, payload), nil)
      end
    rescue
      # The leg is gone; there is nobody left to credit.
    end

    # --- small helpers -------------------------------------------------------

    private NO_CROSS = [] of UInt32

    private def remove(slot : Slot) : Nil
      @slots.delete(slot.stream_id)
      @opens.delete(slot.stream_id)
    end

    private def warn_unscopable(stream_id : UInt32) : Nil
      return if @warned_scope
      @warned_scope = true
      ::Log.warn do
        # Do NOT assert the cause. This message named the live-stream ceiling unconditionally,
        # and it fired on connections carrying a SINGLE stream — where the real reason was an
        # undecodable request head, so the assembler never tracked the stream in the first
        # place. An operator asking "why did my hold not fire / why did $SESSION not bind" was
        # sent to look at a limit they were nowhere near. Same shape as the #536 note about
        # this message.
        "h2 in: stream #{stream_id} has no projected request, so its response has no request " \
        "target to scope an intercept hold against — not held. Either the request head could " \
        "not be decoded, or the connection is past #{Assembler::MAX_LIVE_STREAMS} live streams"
      end
    end
  end
end
