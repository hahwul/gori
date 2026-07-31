require "./frame"
require "./head_codec"
require "./head_rewrite"
require "./assembler"
require "./extract"
require "../sink"
require "../upstream"
require "../../interceptor"
require "../../outbound"

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
  #   * `run_cross` is the only place that touches `@peer`, and it runs after `@mutex` has been
  #     released. `write_cross_rst` takes its own gate's lock and nothing else.
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

    # h1 records exactly these strings (`client_conn.cr:1234`, `:840`, `:1249`), so History
    # reads the same on both protocols.
    DROP_REQUEST_REASON  = "dropped by intercept (request)"
    DROP_RESPONSE_REASON = "dropped by intercept"
    SANDBOX_REASON       = Gori::Outbound::SANDBOX_ERROR

    # Ceiling on the refused-stream set (see `@refused`). The set is the only thing standing
    # between a refused request's later DATA and the origin, so past the ceiling the CONNECTION
    # goes — not the memory bound, and not the guarantee. Generous on purpose: it is per
    # connection and only refusals count, so reaching it means thousands of refused streams on
    # one connection, i.e. a client that has ignored thousands of RST_STREAMs.
    MAX_REFUSED_STREAMS = 4096

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
      # not an option, which is why a head-only hold still buffers a body (#492 step 3, D2).
      getter frames = [] of {Frame::Header, Assembler::HeadBlock?}
      property bytes = 0

      def initialize(@stream_id : UInt32)
      end
    end

    property peer : StreamGate?

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
      @warned_scope = false
      @warned_overflow = false
      # The request direction is the one that opens streams, and the one whose deferred streams
      # the FAR leg has therefore never seen.
      @ordered = @direction == "out"
      @heads.deferrer = self
    end

    # Feed one frame off the wire. Never blocks on a human.
    def accept(frame : Frame::Header) : Nil
      run_cross(@mutex.synchronize { accept_locked(frame) })
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
        @heads.drain { |f, pre| write(f, pre) rescue nil }
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
      item = start_hold(block)
      queued = @ordered && !block.head.nil? && !@opens.empty?
      return false unless item || queued

      block = @heads.engage(block) # rule 2 — MUST precede any later block going out
      slot = Slot.new(block.stream_id)
      slot.pending = block
      @slots[block.stream_id] = slot
      @opens << block.stream_id if @ordered && !block.head.nil?
      if item
        slot.item = item
        wait_for(item, block)
      else
        slot.ready = true # queued for order only; nothing to decide
      end
      true
    end

    # --- pump side (locked) --------------------------------------------------

    private def accept_locked(frame : Frame::Header) : Array(UInt32)
      return NO_CROSS if @closed
      # Connection-level frames are NEVER deferred (#492 step 3, D1 rule 1): parking a SETTINGS
      # ACK, a PING or the SHARED connection window behind a held stream kills the connection
      # or starves every stream on it. `Assembler#feed` already treats stream 0 as not-a-stream.
      if frame.stream_id == 0
        write(frame, nil)
        return NO_CROSS
      end
      cross = NO_CROSS
      # Every header block goes through `@heads` even for a deferred stream: the per-direction
      # HPACK decoder must advance in ARRIVAL order, so a block cannot wait in a Slot undecoded
      # and be decoded later out of sequence. That holds for a REFUSED stream too — its later
      # blocks (trailers) still carry the peer's HPACK insertions, so they must be decoded even
      # though nothing is written.
      @heads.accept(frame) do |f, pre|
        slot = @slots[f.stream_id]?
        if @refused.includes?(f.stream_id)
          # Swallowed, not written: the far leg never saw this stream open. Deliberately not
          # captured either — `write` is what logs a frame and P7 logs what gori actually wrote.
        elsif slot.nil?
          write(f, pre)
        elsif f.frame_type == Frame::Type::RstStream
          cross = cross + abandon_locked(slot, f)
        else
          park(slot, f, pre)
          check_ceiling(slot)
        end
      end
      take_deferred_cross(cross)
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
    end

    private def park_block(slot : Slot, block : HeadRewrite::Block) : Nil
      last = block.frames.size - 1
      block.frames.each_with_index { |f, i| park(slot, f, i == last ? block.pre : nil) }
      check_ceiling(slot)
    end

    private def check_ceiling(slot : Slot) : Nil
      fail_open(slot) if slot.bytes > MAX_DEFERRED_BYTES
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
      target.ready = true
      return unless item
      target.item = nil
      @interceptor.forward(item.id)
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
        "h2 #{@direction}: held stream #{slot.stream_id} buffered over #{MAX_DEFERRED_BYTES} " \
        "bytes — forwarding it unedited#{also}"
      end
    end

    # --- sandbox side --------------------------------------------------------

    # The hard containment gate, per stream (#492 step 4). True when this head was REFUSED —
    # its frames are then accounted for and nothing is ever written for the stream again.
    #
    # ## Why two URLs are tested, not one
    #
    # h1 inside a tunnel tests `scheme://<CONNECT host><target>`: `resolve_forward`
    # short-circuits on the pinned host, so the name in the request and the socket's
    # destination cannot disagree. On h2 they can. RFC 9113 §9.1.1 lets a client REUSE one
    # connection for any origin the certificate covers, so a single relay carries streams whose
    # `:authority` is not the CONNECT host — which is exactly why the head pipeline already
    # scopes rules and holds on the stream's own authority (`head_rewrite.cr`).
    #
    # For a blocking gate, choosing one of the two names is choosing which half to leak. Take a
    # scope of `https://acme.test/*` — a URL rule, so `sandbox_blocks_host?` lets EVERY host
    # past the CONNECT gate and every per-request decision is this one:
    #
    #   * authority only would pass a stream claiming `:authority: acme.test` on a connection
    #     to `evil.test`, i.e. the request goes to a host the scope never allowed.
    #   * connection host only would pass a coalesced stream to `evil.test` riding an
    #     `acme.test` connection, because the URL it tested was the connection's, not the
    #     request's.
    #
    # So both are tested and either refusal is a refusal. On an ordinary connection the two
    # names are equal and the second test is skipped, so the common path costs one evaluation.
    private def sandbox_refuses_locked(block : HeadRewrite::Block) : Bool
      return false unless @ordered   # a response exists only for a request already allowed
      return false unless block.head # trailers/PUSH_PROMISE carry no request URL to test
      fields = block.fields
      authority = HeadCodec.pseudo_of(fields, ":authority") || @host
      host, _ = Upstream.split_host_port(authority, @port)
      scheme = HeadCodec.pseudo_of(fields, ":scheme") || "https"
      target = HeadCodec.pseudo_of(fields, ":path") || "/"
      blocked = @interceptor.sandbox_blocks?(scheme, host, target) ||
                (host != @host && @interceptor.sandbox_blocks?(scheme, @host, target))
      return false unless blocked
      refuse_locked(block)
      true
    end

    # Refuse one stream. The head never goes on the wire, so it is fed to the assembler for the
    # PROJECTION ONLY — `write` is what logs a frame, and P7 logs what gori actually wrote — and
    # the flow is finalized with h1's own sandbox reason, so a blocked attempt stays visible in
    # History exactly as `ClientConn#record_blocked_request` keeps it (P4/P7).
    #
    # Then RST_STREAM(CANCEL) to the CLIENT only. The origin never saw this stream open, and
    # RST_STREAM on an idle stream is itself a connection error (§6.4), so telling it would take
    # down every other stream on the connection — the same per-leg reasoning `drop_locked`
    # spells out. The client leg belongs to the peer gate, hence the cross list.
    #
    # h1 answers a blocked request with `403 + X-Gori-Sandbox: blocked`, and h2 deliberately
    # does not, for the reason step 3 rejected a synthesized 502: encoding a response head into
    # the client-bound direction makes gori a SECOND producer of HPACK-bearing frames there,
    # correct only while dynamic-table insertion stays off. A refusal is the last place to spend
    # that, since it would be spent on every out-of-scope subresource of every page.
    private def refuse_locked(block : HeadRewrite::Block) : Nil
      @heads.latch # suppressing a block desyncs HPACK exactly as reordering one does
      project(block)
      @assembler.drop_stream(block.stream_id, SANDBOX_REASON)
      remember_refused(block.stream_id)
      @deferred_cross << block.stream_id
    end

    # Past the ceiling the connection goes. Everywhere else in this file an overflow fails OPEN
    # (`fail_open`, `close`, the #123 reaper) because the thing being lost is a human's chance
    # to look at a message. Here it is the record of which streams must never reach the origin,
    # and a blocking gate that has forgotten what it blocked is not a gate.
    private def remember_refused(stream_id : UInt32) : Nil
      @refused << stream_id
      return if @refused.size <= MAX_REFUSED_STREAMS
      ::Log.warn do
        "h2 #{@direction}: over #{MAX_REFUSED_STREAMS} streams refused on one connection " \
        "(sandbox or intercept drop) — closing it, because gori can no longer keep track of " \
        "which streams must not reach the far end"
      end
      raise Gori::Error.new("h2: refused-stream ceiling reached")
    end

    # `HeadRewrite::Deferrer`. A header block this direction could not read.
    #
    # With the sandbox OFF this is a no-op and the frames go out verbatim — step 2's behaviour
    # and P7's, since the raw log is the truth and the peer is entitled to gori's honest relay
    # of what it received. With the sandbox ON the same forward is a hole: an unreadable head
    # has no URL to scope-test, so it would be the one request shape that walks past a blocking
    # gate, and it is the shape most likely to be hostile. Both causes (§6.1 padding, §4.3
    # HPACK) are CONNECTION errors by spec, so the far end would end the connection over this
    # block anyway — gori doing it first costs nothing and is the only answer that does not
    # guess. Response-direction blocks are left alone: they bypass no request gate.
    def undecodable(stream_id : UInt32) : Nil
      return unless @ordered && @interceptor.sandbox_enabled?
      ::Log.warn do
        "h2 out: stream #{stream_id} carries a header block gori cannot decode (RFC 9113 " \
        "§6.1/§4.3) — the sandbox is on and an unreadable head has no URL to scope-test, " \
        "so the connection is closed rather than forwarded unexamined"
      end
      raise Gori::Error.new("h2 sandbox: undecodable header block on stream #{stream_id}")
    end

    # --- hold side -----------------------------------------------------------

    # Ask the Interceptor whether this head is held, and enqueue it if so. Returns nil (forward
    # normally) for a block that is not a message head, an interim 1xx, or anything the precise
    # per-request/per-response gates decline.
    private def start_hold(block : HeadRewrite::Block) : Gori::Interceptor::Item?
      head = block.head
      return nil unless head
      block.request ? hold_request(block, head) : hold_response(block, head)
    end

    private def hold_request(block : HeadRewrite::Block, head : Bytes) : Gori::Interceptor::Item?
      fields = block.fields
      authority = HeadCodec.pseudo_of(fields, ":authority") || @host
      host, port = Upstream.split_host_port(authority, @port)
      method = HeadCodec.pseudo_of(fields, ":method") || "GET"
      target = HeadCodec.pseudo_of(fields, ":path") || "/"
      scheme = HeadCodec.pseudo_of(fields, ":scheme") || "https"
      return nil unless @interceptor.intercepts_request?(
                          method: method, host: host, target: target, scheme: scheme)
      @interceptor.enqueue_request(head, method: method, target: target,
        host: host, port: port, scheme: scheme)
    end

    private def hold_response(block : HeadRewrite::Block, head : Bytes) : Gori::Interceptor::Item?
      status = (HeadCodec.pseudo_of(block.fields, ":status") || "0").to_i? || 0
      # h1 skips interim 1xx BEFORE the hold gate (`client_conn.cr:467` → `:501`), so an Early
      # Hints response never consumes the decision meant for the real one. Parity, not a gap.
      return nil if status < 200
      ref = @assembler.request_ref(block.stream_id)
      if ref.nil?
        # No request projected for this stream (past `Assembler::MAX_LIVE_STREAMS`). h1 scopes a
        # response hold on the REQUEST's target (`client_conn.cr:501`); with no request target
        # there is nothing to scope against, and inventing one is how a hold escapes scope.
        warn_unscopable(block.stream_id)
        return nil
      end
      host, port = Upstream.split_host_port(ref.authority, @port)
      return nil unless @interceptor.intercepts_response?(
                          method: ref.method, host: host, target: ref.target,
                          scheme: ref.scheme, status: status)
      # h1's response Item carries "<status> <reason>"; h2 has no reason phrase (§8.3.2).
      @interceptor.enqueue_response(head, flow_id: @assembler.flow_id_of(block.stream_id),
        method: ref.method, target: status.to_s, host: host, port: port, scheme: ref.scheme)
    end

    private def wait_for(item : Gori::Interceptor::Item, block : HeadRewrite::Block) : Nil
      spawn do
        decision = item.reply.receive
        run_cross(@mutex.synchronize { resolve_locked(item, block, decision) })
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
        slot.decided = decision.bytes == block.head ? block : edited(block, decision.bytes)
      end
      slot.ready = true
      drain_locked
    end

    # The operator's bytes, back through the same pipeline a rule takes.
    private def edited(block : HeadRewrite::Block, bytes : Bytes) : HeadRewrite::Block
      head, body = split_edit(bytes)
      # h2 holds the HEAD only (#492 step 3, D2) — DATA streams past untouched, so a body typed
      # into the editor has nowhere to go. Ignoring it silently is the failure class this epic
      # exists to remove, so say it once. (`content-length` needs no equivalent warning: the
      # editor's own automatic `Content-Length:` on a dirty edit is reverted by
      # `HeadCodec.restore_content_length`, which is required anyway because DATA is untouched.)
      if body && !@warned_body
        @warned_body = true
        ::Log.warn { "h2 #{@direction}: an intercept edit added a body (stream #{block.stream_id}) — h2 holds the head only, the body was ignored" }
      end
      @heads.encode_edited(block, head) || block
    end

    # {head incl. its terminating blank line, whether anything followed it}.
    private def split_edit(bytes : Bytes) : {Bytes, Bool}
      text = String.new(bytes)
      idx = text.index("\r\n\r\n").try(&.+(4)) || text.index("\n\n").try(&.+(2))
      return {bytes, false} unless idx
      {bytes[0, idx], idx < bytes.size}
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
      if b = slot.decided || slot.pending
        last = b.frames.size - 1
        b.frames.each_with_index { |f, i| write(f, i == last ? b.pre : nil) }
      end
      slot.frames.each { |(f, pre)| write(f, pre) }
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
      @assembler.feed(@direction, frame, pre)
      # Session-binding extraction (#501 slice 2), on the frames that were actually WRITTEN.
      # A head the sandbox suppressed or the operator dropped goes to `project`, not here, so
      # "delivered, not arrived" holds structurally. Response direction only, and nil for every
      # frame that is not the end of a header block.
      @extract.try(&.observe(frame, pre))
    end

    # Feed a held head to the assembler for the DECODED projection only, without logging it as
    # a frame: these bytes never went on the wire.
    private def project(block : HeadRewrite::Block) : Nil
      last = block.frames.size - 1
      block.frames.each_with_index { |f, i| @assembler.feed(@direction, f, i == last ? block.pre : nil) }
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
        "h2 in: stream #{stream_id} is not tracked (over #{Assembler::MAX_LIVE_STREAMS} live " \
        "streams), so its response has no request target to scope an intercept hold against — not held"
      end
    end
  end
end
