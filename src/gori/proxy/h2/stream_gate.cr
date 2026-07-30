require "./frame"
require "./head_codec"
require "./head_rewrite"
require "./assembler"
require "../sink"
require "../upstream"
require "../../interceptor"

module Gori::Proxy::H2
  # One direction's writer, and the intercept gate in front of it (#492 step 3).
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
    CANCEL = 0x8_u32

    # Ceiling on the frames parked behind one deferred stream. A sender is already throttled by
    # its own flow-control window — it gets no credit for bytes the far end never saw — so this
    # only bites against a peer that ignores that window. Past it the hold FAILS OPEN, the same
    # disposition as toggle-off (`interceptor.cr:147`), `release_all` and the #123 reaper.
    MAX_DEFERRED_BYTES = 1 << 20

    # h1 records exactly these strings (`client_conn.cr:1234`, `:840`), so History reads the
    # same on both protocols.
    DROP_REQUEST_REASON  = "dropped by intercept (request)"
    DROP_RESPONSE_REASON = "dropped by intercept"

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
                   @interceptor : Gori::Interceptor, @heads : HeadRewrite)
      @mutex = Mutex.new
      @slots = {} of UInt32 => Slot
      # Deferred stream-OPENING ids in arrival order (= increasing id order), request direction
      # only. Rule 1 above: releases follow this order, not decision order.
      @opens = [] of UInt32
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
      # and be decoded later out of sequence.
      @heads.accept(frame) do |f, pre|
        slot = @slots[f.stream_id]?
        if slot.nil?
          write(f, pre)
        elsif f.frame_type == Frame::Type::RstStream
          cross = cross + abandon_locked(slot, f)
        else
          park(slot, f, pre)
        end
      end
      cross
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

    private def park(slot : Slot, frame : Frame::Header, pre : Assembler::HeadBlock?) : Nil
      slot.frames << {frame, pre}
      slot.bytes += frame.payload.size
      fail_open(slot) if slot.bytes > MAX_DEFERRED_BYTES
    end

    private def park_block(slot : Slot, block : HeadRewrite::Block) : Nil
      last = block.frames.size - 1
      block.frames.each_with_index { |f, i| park(slot, f, i == last ? block.pre : nil) }
    end

    # Past the buffer ceiling. Release the hold everything is waiting on with the ORIGINAL head
    # (fail open), not this slot's — in the request direction a slot may be queued behind an
    # earlier one and releasing it alone would move nothing.
    private def fail_open(slot : Slot) : Nil
      target = slot.item ? slot : @slots.values.find(&.item)
      return unless target
      item = target.item
      return unless item
      target.item = nil
      unless @warned_overflow
        @warned_overflow = true
        ::Log.warn do
          "h2 #{@direction}: held stream #{target.stream_id} buffered over " \
          "#{MAX_DEFERRED_BYTES} bytes — forwarded it unedited"
        end
      end
      @interceptor.forward(item.id)
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
