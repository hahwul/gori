# Match&Replace BODY rules on HTTP/2 (#1628) — reopens `Gori::Proxy::H2::StreamGate` (see
# `proxy/h2/stream_gate.cr` for the class, its state and the `*_locked` lock invariant every
# method here is bound by).
#
# ## Why a body rewrite is a flow-control problem, and how this answers it
#
# The relay is transparent: DATA goes forward as it arrived and both flow-control windows stay
# end to end, the receiver's WINDOW_UPDATEs crediting the sender for bytes it actually sent.
# Buffering a body and sending a different one breaks that both ways. A shrunk body leaves the
# sender charged for bytes nobody will ever credit, so its window drains for good; a grown one
# overruns what the receiver advertised, which is FLOW_CONTROL_ERROR.
#
# So for a stream a body rule could apply to, gori stops relaying its DATA and becomes the
# sender itself:
#
#   * **Stream level, the stream is terminated at gori.** Every DATA byte that arrives is
#     credited back to the sender by a WINDOW_UPDATE gori writes (on arrival while the body is
#     buffering, once forwarded after it spilled). Toward the receiver gori spends that
#     stream's own window, opened at the receiver's SETTINGS_INITIAL_WINDOW_SIZE and topped up
#     by the receiver's WINDOW_UPDATEs, which stop here instead of reaching the sender.
#   * **Connection level, the window is shared** with every passthrough stream, so it cannot be
#     terminated. It is kept as a DEBT instead: every byte gori writes on an owned stream is a
#     byte the receiver will credit, and that credit is gori's, not the sender's. The receiver's
#     connection WINDOW_UPDATEs pay the debt first (`credit_locked`) and only the rest is
#     forwarded. Until it is paid the sender believes it has `debt` more window than the
#     receiver gave, so passthrough DATA that would overrun the receiver waits here (`deliver`)
#     instead of earning a FLOW_CONTROL_ERROR. gori never writes past the receiver's window, so
#     the debt is bounded by that window, and the queue by the window the sender believes in.
#
# Nothing here exists unless a body rule matched the CONNECT host when the relay was built
# (`Relay#gates`, the same once-per-connection question the old HTTP/1.1 downgrade asked), so
# a connection no body rule can touch keeps exactly the frame path it had: no buffer, no
# window arithmetic, no WINDOW_UPDATE detour through the opposite gate.
#
# ## The head, and content-length
#
# A head that declares `content-length` is held (a Slot, the hold machinery's own) until the
# body is in and the rules have run, then goes out with the length the body actually has. In
# the request direction that holds later stream OPENS behind it (rule 1 in the class comment);
# streams already open keep moving, and a body that STALLS for `HOLD_WAIT_DEADLINE` gives the
# wait up. A held response head blocks no other stream, so it waits however long its body
# takes. A response with no declared length goes out at once and only the DATA waits. Either way a body no rule changed goes out as the peer's own DATA frames.
#
# A REQUEST with no declared length is never buffered. Nothing on the wire tells a finite
# upload from a full-duplex stream (Connect, ndjson, a hand-rolled RPC) whose client waits for
# the reply before it ends the request, and buffering that one to END_STREAM deadlocks it.
class Gori::Proxy::H2::StreamGate
  # RFC 9113 §6.9.2: what a receiver allows before any SETTINGS or WINDOW_UPDATE of its own,
  # connection and stream alike.
  DEFAULT_WINDOW = 65_535_i64

  # The body-rule buffering ceiling, shared with HTTP/1.1 so one rule costs the same on both
  # transports. A declared length over it is never buffered; an undeclared body that grows past
  # it spills and goes through unmodified (`spill_locked`).
  MAX_RULE_BODY = Proxy::ClientConn::MAX_REWRITE_BODY

  # What one direction may hold in rule buffers at once, across its streams. Each stream is
  # credited on arrival so it can finish, which means the per-stream ceiling alone would let a
  # hundred concurrent streams hold a hundred times it (P6). The stream whose DATA would cross
  # this spills instead.
  MAX_RULE_BUFFERED = MAX_RULE_BODY

  # One leg's receiver, as gori the sender sees it — plus the receiver frames that arrived on
  # THIS gate's pump for the PEER to account (`heard`). Built only on a body-rule connection.
  private class Flow
    # The receiver's connection window as this leg has spent it: every DATA `write` puts on
    # the wire comes off it, every connection WINDOW_UPDATE from the receiver goes on.
    property window = DEFAULT_WINDOW
    # The receiver's SETTINGS_INITIAL_WINDOW_SIZE, which each owned stream's window opens at.
    property initial = DEFAULT_WINDOW
    # Connection credit the receiver owes GORI for bytes it wrote on owned streams.
    property debt = 0_i64
    # Passthrough frames waiting for the connection window, in order, and how many each stream
    # has in there (a later frame on the same stream must not overtake one).
    getter waiting = [] of {Frame::Header, Assembler::HeadBlock?}
    getter waiting_on = Hash(UInt32, Int32).new(0)
    getter owned = {} of UInt32 => Owned
    # Stream-level credit owed to the sender, flushed beside `@swallowed`.
    getter refunds = Hash(UInt32, Int32).new(0)
    getter heard = [] of Frame::Header
    # Stream credit the receiver granted before gori owned the stream — a client widening its
    # window right after the request, before any response — forwarded at the time, and owed to
    # the stream's window once gori becomes its sender. Response direction only; taken by the
    # response head, dropped at RST_STREAM (either side's) and at the end of the response, and
    # capped at `Assembler::MAX_LIVE_STREAMS` entries by evicting the lowest stream id: an entry
    # a late WINDOW_UPDATE leaves behind is never read again, and ids only grow, so the lowest
    # is the stalest — refusing new entries instead would bring back the stall it exists for.
    getter pre_credit = Hash(UInt32, Int64).new(0_i64)
    # Streams whose response head has passed and whose response has not ended: credit for them
    # is not "before ownership", so it is not recorded.
    getter headed = Set(UInt32).new
    # Bytes held in rule buffers across this direction's streams (`MAX_RULE_BUFFERED`).
    property buffered = 0_i64
  end

  # One stream whose DATA this gate sends itself.
  private class Owned
    getter stream_id : UInt32
    getter host : String
    getter? request : Bool
    # The head as the rules read it, kept for the rule's record (#1589).
    getter head : Bytes?
    getter? declares_length : Bool
    property window : Int64
    # The held head, while one is held. nil once it went out, or when it was never held.
    property slot : Slot?
    # DATA as it arrived, while the body is buffering.
    getter arrived = [] of Frame::Header
    property size = 0
    property? spilled = false
    property? complete = false
    property? head_out = false
    # When a held head started waiting for its body (`expire_owned_heads_locked`).
    property held_since : Time::Instant?
    # DATA to send, each with the credit its sending returns to the sender (0 when that credit
    # was already returned on arrival).
    getter sends = [] of {Frame::Header, Int32}
    # Trailers, written once `sends` has drained.
    getter after = [] of {Frame::Header, Assembler::HeadBlock?}

    def initialize(@stream_id, @host, @request, @head, @declares_length, @window)
    end
  end

  # The stream this head opens, as one this gate will send itself, or nil to relay it as ever.
  # Same questions h1 asks before buffering (`ClientConn#rewrite_request_body?`,
  # `#buffer_response_body?`), on the stream's own host.
  private def plan_body(block : HeadRewrite::Block, pre_credit : Int64) : Owned?
    rw = @body_rewriter
    fc = @flow
    head = block.head
    return nil unless rw && fc && head
    return nil if block.first.end_stream? || block.first.frame_type != Frame::Type::Headers
    host = @heads.host_of(block)
    return nil unless body_rule_for?(rw, block.fields, host)
    return nil if streaming?(block.fields) || unbufferable?(block, head)
    len = declared_body_length(block.fields)
    return nil if @ordered && unholdable_request?(block, len)
    Owned.new(block.stream_id, host, @ordered, head, !len.nil?, fc.initial + pre_credit)
  end

  # A request whose head this gate cannot hold for its body. With no declared length it may be
  # full duplex (see the file comment); with `expect: 100-continue` the client sends no body
  # until the origin answers a head gori would be holding, so it waits out its own timeout.
  private def unholdable_request?(block : HeadRewrite::Block, len : Int32?) : Bool
    if len.nil?
      skip_body(block.stream_id, "it declares no content-length, so it may be a stream whose " \
                                 "client waits for the reply before ending it")
      return true
    end
    expect = block.fields.find { |f| f.name == "expect" }.try(&.value.downcase)
    return false unless expect == "100-continue"
    skip_body(block.stream_id, "it asks for 100-continue, which the origin can only answer once it has the head")
    true
  end

  private def body_rule_for?(rw : Proxy::HeadRewriter, fields : Array(HPACK::Field), host : String) : Bool
    if @ordered
      # An extended CONNECT (RFC 8441) carries a tunnel, not an entity.
      HeadCodec.pseudo_of(fields, ":method") != "CONNECT" && rw.rewrites_request_body_for_host?(host)
    else
      status = HeadCodec.pseudo_of(fields, ":status").try(&.to_i?)
      # An interim 1xx is not the message.
      !(status && status < 200) && rw.rewrites_response_body_for_host?(host)
    end
  end

  # A body h1 would not buffer for a rule either: compressed, or a declared length over the
  # ceiling — or one gori cannot read.
  private def unbufferable?(block : HeadRewrite::Block, head : Bytes) : Bool
    if Codec::ContentDecode.content_encoded?(head)
      skip_body(block.stream_id, "it arrived compressed and gori never decompresses on the wire path")
      return true
    end
    len = declared_body_length(block.fields)
    # Two lengths, or one that is not a number: malformed (RFC 9113 §8.1.1), and gori does not
    # get to pick the one it believes. It goes out as it arrived (P7).
    return block.fields.any? { |f| f.name == "content-length" } if len.nil?
    return false unless len > MAX_RULE_BODY
    skip_body(block.stream_id, "it declares #{len} bytes, over the #{MAX_RULE_BODY}-byte ceiling gori buffers a body to rewrite")
    true
  end

  # `plan_body`'s answer for a head `defer?` is about to place, or nil. A held stream is the
  # hold's: the operator edits that body, so the rule says it stood aside.
  private def body_for(block : HeadRewrite::Block, held : Bool) : Owned?
    own = plan_body(block, take_pre_credit(block))
    return own unless own && held
    skip_body(block.stream_id, "it was held at intercept, and the hold owns its body")
    nil
  end

  # SSE and gRPC never end on a schedule gori can wait for: a body rule leaves them streaming,
  # as h1 leaves SSE. A gRPC body is length-prefixed frames, and a bidirectional call would wait
  # forever for an END_STREAM its client only sends after reading the reply.
  private def streaming?(fields : Array(HPACK::Field)) : Bool
    type = fields.find { |f| f.name == "content-type" }.try(&.value.downcase) || return false
    STREAMING_TYPES.any? { |prefix| type.starts_with?(prefix) }
  end

  # Content types whose body is a stream of messages rather than one entity: SSE, gRPC (and
  # gRPC-Web), Connect streaming, newline-delimited JSON.
  STREAMING_TYPES = {"text/event-stream", "application/grpc", "application/connect+",
                     "application/x-ndjson", "application/ndjson"}

  private def skip_body(stream_id : UInt32, why : String) : Nil
    @assembler.note_advisory(stream_id,
      "Match&Replace was NOT applied to this #{@ordered ? "request" : "response"} body: #{why}. " \
      "It went through unmodified")
  end

  # The response head ends the window in which a stream's credit is "before ownership", owned
  # or not — which is also what keeps `pre_credit` from growing past the streams in flight.
  private def take_pre_credit(block : HeadRewrite::Block) : Int64
    fc = @flow
    return 0_i64 unless fc && !@ordered && block.head
    status = HeadCodec.pseudo_of(block.fields, ":status").try(&.to_i?)
    return 0_i64 if status && status < 200
    fc.headed << block.stream_id unless block.first.end_stream?
    fc.pre_credit.delete(block.stream_id) || 0_i64
  end

  # `write`'s bookkeeping on a body-rule connection: the receiver's connection window, and the
  # end of a response — END_STREAM or a reset, whoever sent it — for `pre_credit`.
  private def note_written(fc : Flow, frame : Frame::Header) : Nil
    data = frame.frame_type == Frame::Type::Data
    fc.window -= frame.payload.size if data
    return if @ordered
    reset = frame.frame_type == Frame::Type::RstStream
    return unless reset || (frame.end_stream? && (data || frame.frame_type == Frame::Type::Headers))
    forget_response(fc, frame.stream_id)
  end

  private def forget_response(fc : Flow, stream_id : UInt32) : Nil
    fc.pre_credit.delete(stream_id) unless fc.pre_credit.empty?
    fc.headed.delete(stream_id) unless fc.headed.empty?
  end

  # Take a stream on, after `defer?` has decided whether its head waits. A REQUEST head that
  # waits for a declared length gets `HOLD_WAIT_DEADLINE` as a stall bound (`held_since`), since
  # every later stream open waits behind it. A held response head blocks no other stream, so it
  # waits for its body however slowly the body comes, as it did on the h1 path.
  private def adopt_locked(own : Owned?, slot : Slot?) : Nil
    fc = @flow
    return unless own && fc
    own.slot = slot
    own.head_out = slot.nil?
    fc.owned[own.stream_id] = own
    return unless slot && own.declares_length? && @ordered
    own.held_since = Time.instant
    arm_stall_timer
  end

  # Whether this gate's stall timer is running (`arm_stall_timer`).
  @stall_timer = false

  # One timer per gate, not per held head: it sleeps until the earliest held head could have
  # stalled, checks, and stops once no request head is held. Only a body-rule connection with a
  # request head held for its declared length ever starts it (P6).
  private def arm_stall_timer : Nil
    return if @stall_timer
    @stall_timer = true
    spawn do
      while wait = @mutex.synchronize { next_stall_check }
        sleep wait
        begin
          run_cross(@mutex.synchronize { @closed ? NO_CROSS : (expire_owned_heads_locked; take_deferred_cross(NO_CROSS)) })
        rescue
          # A release that writes to a leg already dead raises here, on a spawned fiber with no
          # caller to unwind to; `arm_wait_deadline` guards its own the same way.
        end
        refund_swallowed
      end
    end
  end

  # How long until the earliest held request head could be late, or nil (stopping the timer)
  # when none is held.
  private def next_stall_check : Time::Span?
    fc = @flow
    earliest = nil.as(Time::Instant?)
    unless @closed || fc.nil?
      fc.owned.each_value do |own|
        since = own.held_since
        earliest = since if since && own.slot && (earliest.nil? || since < earliest)
      end
    end
    unless earliest
      @stall_timer = false
      return nil
    end
    {earliest + hold_wait_deadline - Time.instant, 1.millisecond}.max
  end

  # A held request head whose body has STALLED — no DATA for the deadline — goes out as it
  # arrived and its body follows unmodified: a declared length says how big the body is, not
  # that it is coming, and every later stream open waits behind it. Run on every frame and by
  # the stall timer, beside `check_waiting_locked`'s identical question.
  private def expire_owned_heads_locked : Nil
    fc = @flow
    return unless fc && !fc.owned.empty?
    now = Time.instant
    return unless fc.owned.each_value.any? { |own| late?(own, now) }
    fc.owned.values.select { |own| late?(own, now) }.each do |own|
      spill_locked(fc, own, "its body stopped arriving for #{hold_wait_deadline.total_seconds.round(1)} s " \
                            "while later requests waited behind it, so its head went out with the length it declared")
    end
  end

  # A header block on a stream this gate has frames waiting for: trailers behind an owned body,
  # or behind passthrough DATA still waiting for the window. It waits with them, re-encoded —
  # later blocks will reach the peer ahead of it, which is the reordering `HeadRewrite#engage`
  # exists for.
  private def follow_body_locked(block : HeadRewrite::Block) : Bool
    fc = @flow
    return false unless fc
    if own = fc.owned[block.stream_id]?
      block = @heads.engage(block)
      last = block.frames.size - 1
      block.frames.each_with_index { |f, i| own.after << {f, i == last ? block.pre : nil} }
      if block.first.end_stream?
        own.spilled? ? (own.complete = true) : finish_owned_locked(fc, own)
        pump_owned_locked(fc, own)
      end
      return true
    end
    return false unless fc.waiting_on.has_key?(block.stream_id)
    block = @heads.engage(block)
    last = block.frames.size - 1
    block.frames.each_with_index { |f, i| queue_waiting(fc, f, i == last ? block.pre : nil) }
    true
  end

  # DATA and RST_STREAM on an owned stream, and RST_STREAM on one with DATA waiting. true when
  # handled here.
  private def own_frame_locked(f : Frame::Header) : Bool
    fc = @flow
    return false unless fc
    if own = fc.owned[f.stream_id]?
      if f.frame_type == Frame::Type::Data
        own_data_locked(fc, own, f)
        return true
      elsif f.frame_type == Frame::Type::RstStream
        @deferred_cross.concat(abandon_owned_locked(fc, own, f))
        return true
      end
    elsif f.frame_type == Frame::Type::RstStream && fc.waiting_on.delete(f.stream_id)
      # The stream is gone; its waiting DATA would only spend the receiver's window on a closed
      # stream. The sender was charged for it all the same, so it is owed back.
      fc.waiting.reject! do |(w, _)|
        next false unless w.stream_id == f.stream_id
        @swallowed += w.payload.size if w.frame_type == Frame::Type::Data
        true
      end
      write(f, nil)
      return true
    end
    false
  end

  private def own_data_locked(fc : Flow, own : Owned, f : Frame::Header) : Nil
    if own.spilled?
      own.sends << {f, f.payload.size}
      own.complete = true if f.end_stream?
      pump_owned_locked(fc, own)
      return
    end
    own.arrived << f
    own.size += f.payload.size
    fc.buffered += f.payload.size
    own.held_since = Time.instant if own.held_since # a body still arriving has not stalled
    refund_locked(fc, own.stream_id, f.payload.size, f.end_stream?)
    # A PADDED frame carries bytes only `Assembler#data_block` knows how to strip, so the body
    # is one gori will not rewrite — the same call `note_body_frame` makes for a hold.
    if f.padded?
      spill_locked(fc, own, "a DATA frame arrived padded")
    elsif own.size > MAX_RULE_BODY
      spill_locked(fc, own, "it ran past the #{MAX_RULE_BODY}-byte ceiling gori buffers a body to rewrite")
    elsif fc.buffered > MAX_RULE_BUFFERED
      spill_locked(fc, own, "the bodies buffered on this connection passed #{MAX_RULE_BUFFERED} bytes")
    elsif f.end_stream?
      finish_owned_locked(fc, own)
      pump_owned_locked(fc, own)
    end
  end

  # Give the buffer up: what arrived goes out as it arrived, and the rest follows as it comes.
  private def spill_locked(fc : Flow, own : Owned, why : String) : Nil
    own.held_since = nil
    skip_body(own.stream_id, why)
    own.spilled = true
    own.complete = true if own.arrived.last?.try(&.end_stream?)
    own.arrived.each { |f| own.sends << {f, 0} }
    clear_arrived(fc, own)
    if slot = own.slot
      # The held head goes as it arrived, with the length it declared, which is now true.
      slot.ready = true
      @deferred_cross.concat(drain_locked)
    else
      pump_owned_locked(fc, own)
    end
  end

  # The body is in: run the rules, and queue what goes out — the peer's own frames when nothing
  # changed (P7), re-framed DATA when something did, with the held head's length made true.
  private def finish_owned_locked(fc : Flow, own : Owned) : Nil
    own.complete = true
    # Done arriving: it may still wait behind a lower stream, but it has not stalled.
    own.held_since = nil
    rw = @body_rewriter
    return unless rw
    entity = Bytes.new(own.size)
    at = 0
    own.arrived.each do |f|
      f.payload.copy_to(entity + at)
      at += f.payload.size
    end
    hits = [] of Store::RuleRef
    # An empty body runs no rule, as on h1 (`ClientConn#apply_body_rewrite`): a `^` pattern
    # would otherwise invent one for every bodiless message.
    rewritten = if entity.empty?
                  entity
                elsif own.request?
                  rw.rewrite_request_body(entity, own.host, hits)
                else
                  rw.rewrite_response_body(entity, own.host, hits)
                end
    rw.settle_hits(hits, 0, entity, rewritten) { |b| b }
    if rewritten == entity
      own.arrived.each { |f| own.sends << {f, 0} }
    else
      # False when trailers end the message: the flag stays on whatever ended it.
      ends = own.arrived.last?.try(&.end_stream?) || false
      data_frames(own.stream_id, rewritten, ends).each { |f| own.sends << {f, 0} }
      @assembler.note_body_rewrite(own.stream_id, own.request?, hits, own.head, entity)
      if (slot = own.slot) && (pending = slot.pending)
        slot.decided = @heads.reencode(pending, with_length(pending.fields, rewritten.size))
      end
    end
    clear_arrived(fc, own)
    if slot = own.slot
      slot.ready = true
      @deferred_cross.concat(drain_locked)
    end
  end

  private def late?(own : Owned, now : Time::Instant) : Bool
    since = own.held_since
    !own.slot.nil? && !since.nil? && now - since >= hold_wait_deadline
  end

  private def clear_arrived(fc : Flow, own : Owned) : Nil
    fc.buffered -= own.size unless own.arrived.empty?
    own.arrived.clear
  end

  private def with_length(fields : Array(HPACK::Field), size : Int32) : Array(HPACK::Field)
    fields.map { |f| f.name == "content-length" ? HPACK::Field.new(f.name, size.to_s) : f }
  end

  # `release_locked` just wrote an owned stream's held head. A head that left before its body
  # was in — the slot failed open behind another stream's overflow — declared a length a rewrite
  # could no longer keep true, so that body goes through unmodified.
  private def release_owned_locked(slot : Slot) : Nil
    fc = @flow
    return unless fc
    own = fc.owned[slot.stream_id]?
    return unless own && own.slot.same?(slot)
    own.slot = nil
    own.head_out = true
    if !own.complete? && !own.spilled? && own.declares_length?
      spill_locked(fc, own, "its head had to go out before the body was in, so the length it declared could not change")
    else
      pump_owned_locked(fc, own)
    end
  end

  # Send what the windows allow of one owned stream. Re-framed DATA splits to fit; the peer's
  # own frames do too unless padded, since a padded frame cannot be cut.
  private def pump_owned_locked(fc : Flow, own : Owned) : Nil
    # A release inside the caller can already have finished this stream.
    return unless own.head_out? && fc.owned[own.stream_id]?.same?(own)
    while entry = own.sends.first?
      f, credit = entry
      size = f.payload.size
      room = Math.min(fc.window, own.window)
      if size > 0 && size > room
        break if f.padded? || room <= 0
        piece = room.to_i32
        own.sends[0] = {Frame::Header.new(f.type, f.flags, f.stream_id, f.payload[piece..]), 0}
        f = Frame::Header.new(f.type, 0_u8, f.stream_id, f.payload[0, piece])
      else
        own.sends.shift
      end
      write(f, nil)
      own.window -= f.payload.size
      fc.debt += f.payload.size
      refund_locked(fc, own.stream_id, credit, f.end_stream?) if credit > 0
    end
    return unless own.sends.empty? && own.complete?
    own.after.each { |(f, pre)| write(f, pre) }
    fc.owned.delete(own.stream_id)
  end

  # Credit the sender for `n` bytes this gate took off it. Not on the stream for the frame that
  # ended it: the sender is done with that window.
  private def refund_locked(fc : Flow, stream_id : UInt32, n : Int32, last : Bool) : Nil
    @swallowed += n
    fc.refunds[stream_id] += n unless last || n <= 0
  end

  # The sender reset an owned stream. Its unsent credit is owed back; the RST reaches the far
  # end only if the far end has the stream open.
  private def abandon_owned_locked(fc : Flow, own : Owned, rst : Frame::Header) : Array(CrossRst)
    forget_owned(fc, own)
    if slot = own.slot
      remove(slot)
      if b = slot.pending
        project(b)
        @assembler.drop_stream(own.stream_id, "stream reset by the peer while its body was buffered for a Match&Replace body rule")
      end
      write(rst, nil) unless @ordered
      return drain_locked
    end
    write(rst, nil)
    NO_CROSS
  end

  private def forget_owned(fc : Flow, own : Owned) : Nil
    own.sends.each { |(_, credit)| @swallowed += credit }
    clear_arrived(fc, own)
    fc.owned.delete(own.stream_id)
  end

  # Forward one frame, or queue it behind the connection window. Only DATA waits: a body-rule
  # connection's sender may believe it has the receiver's debt to gori as window too.
  private def deliver(f : Frame::Header, pre : Assembler::HeadBlock?) : Nil
    fc = @flow
    if fc && f.frame_type == Frame::Type::Data &&
       (fc.waiting_on.has_key?(f.stream_id) || !fc.waiting.empty? || f.payload.size > fc.window)
      queue_waiting(fc, f, pre)
    else
      write(f, pre)
    end
  end

  private def queue_waiting(fc : Flow, f : Frame::Header, pre : Assembler::HeadBlock?) : Nil
    fc.waiting << {f, pre}
    fc.waiting_on[f.stream_id] += 1
  end

  private def pump_all_locked(fc : Flow) : Nil
    while entry = fc.waiting.first?
      f, pre = entry
      break if f.frame_type == Frame::Type::Data && f.payload.size > fc.window
      fc.waiting.shift
      left = fc.waiting_on[f.stream_id] - 1
      left > 0 ? (fc.waiting_on[f.stream_id] = left) : fc.waiting_on.delete(f.stream_id)
      write(f, pre)
    end
    fc.owned.values.each { |own| pump_owned_locked(fc, own) }
  end

  # A frame from the far end that the PEER gate's accounting needs: every WINDOW_UPDATE (held
  # back here — the peer decides what of it the sender gets), and SETTINGS and RST_STREAM
  # (forwarded as ever, and told). true = withheld.
  private def heard_locked(fc : Flow, f : Frame::Header) : Bool
    case f.frame_type
    when Frame::Type::WindowUpdate
      fc.heard << f
      true
    when Frame::Type::Settings
      fc.heard << f unless f.ack?
      false
    when Frame::Type::RstStream
      fc.heard << f
      false
    else
      false
    end
  end

  # Hand what `heard_locked` collected to the peer, outside this gate's lock, and forward what
  # the peer gives back. Paired with `accept` like `run_cross` and `refund_swallowed`.
  private def run_flow : Nil
    fc = @flow
    return unless fc
    heard = @mutex.synchronize do
      next nil if fc.heard.empty?
      taken = fc.heard.dup
      fc.heard.clear
      taken
    end
    return unless heard
    peer = @peer
    heard.each do |f|
      fwd = f.frame_type == Frame::Type::WindowUpdate ? f : nil
      if peer
        fwd = peer.account(f)
        peer.refund_swallowed
      end
      forward_heard(fwd) if fwd
    end
  end

  # A WINDOW_UPDATE for a stream this gate holds the head of is parked behind it only in the
  # REQUEST direction, where the far end has not seen the stream open (RFC 9113 §5.1: idle).
  # In the response direction the stream is open on both legs, the update widens the OTHER
  # direction's sending, and parking it behind a response head held for its body would
  # deadlock a full-duplex exchange whose origin finishes the response only after the request.
  private def forward_heard(f : Frame::Header) : Nil
    @mutex.synchronize do
      next if @closed || @refused.includes?(f.stream_id)
      if @ordered && f.stream_id != 0 && (slot = @slots[f.stream_id]?)
        park(slot, f, nil)
      else
        write(f, nil)
      end
    end
  rescue
    # this leg is gone; nobody is left to credit
  end

  # One receiver frame the opposite gate heard, against this gate's sends. Returns the
  # WINDOW_UPDATE to forward to the sender, or nil.
  protected def account(f : Frame::Header) : Frame::Header?
    @mutex.synchronize do
      fc = @flow
      next (f.frame_type == Frame::Type::WindowUpdate ? f : nil) unless fc && !@closed
      case f.frame_type
      when Frame::Type::WindowUpdate then credit_locked(fc, f)
      when Frame::Type::Settings     then settings_locked(fc, f)
      when Frame::Type::RstStream
        forget_response(fc, f.stream_id) unless @ordered
        fc.owned[f.stream_id]?.try { |own| reset_owned_locked(fc, own) }
      end
    end
  rescue
    # A send this credit released hit this gate's dead leg. Nothing is forwarded for it: the
    # leg that would have used the credit is gone. Raising here would end the CALLER's pump.
    nil
  end

  private def credit_locked(fc : Flow, f : Frame::Header) : Frame::Header?
    # A malformed or zero increment is the sender's to raise a PROTOCOL_ERROR about.
    return f unless f.payload.size == 4
    n = (IO::ByteFormat::BigEndian.decode(UInt32, f.payload) & 0x7fff_ffff_u32).to_i64
    return f if n == 0
    if f.stream_id == 0
      fc.window += n
      kept = Math.min(n, fc.debt)
      fc.debt -= kept
      pump_all_locked(fc)
      return f if kept == 0
      return nil if kept == n
      window_update(0_u32, (n - kept).to_i32)
    elsif own = fc.owned[f.stream_id]?
      own.window += n
      pump_owned_locked(fc, own)
      nil
    else
      note_pre_credit(fc, f.stream_id, n) unless @ordered
      f
    end
  end

  private def note_pre_credit(fc : Flow, stream_id : UInt32, n : Int64) : Nil
    return if fc.headed.includes?(stream_id)
    if fc.pre_credit.size >= Assembler::MAX_LIVE_STREAMS && !fc.pre_credit.has_key?(stream_id)
      fc.pre_credit.delete(fc.pre_credit.keys.min)
    end
    fc.pre_credit[stream_id] += n
  end

  # SETTINGS_INITIAL_WINDOW_SIZE (0x4) moves every open stream's window by the change
  # (RFC 9113 §6.9.2), owned ones included. Nil: the frame was already forwarded.
  private def settings_locked(fc : Flow, f : Frame::Header) : Frame::Header?
    at = 0
    while at + 6 <= f.payload.size
      id = IO::ByteFormat::BigEndian.decode(UInt16, f.payload[at, 2])
      if id == 0x4
        value = IO::ByteFormat::BigEndian.decode(UInt32, f.payload[at + 2, 4]).to_i64
        delta = value - fc.initial
        fc.initial = value
        fc.owned.each_value { |own| own.window += delta }
      end
      at += 6
    end
    pump_all_locked(fc)
    nil
  end

  # The receiver reset an owned stream: stop sending on it.
  private def reset_owned_locked(fc : Flow, own : Owned) : Frame::Header?
    forget_owned(fc, own)
    if slot = own.slot
      remove(slot)
      slot.pending.try { |b| project(b) }
      @assembler.drop_stream(own.stream_id, "stream reset by the peer while its body was buffered for a Match&Replace body rule")
    end
    nil
  end

  private def window_update(stream_id : UInt32, increment : Int32) : Frame::Header
    payload = Bytes.new(4)
    IO::ByteFormat::BigEndian.encode(increment.to_u32 & 0x7fff_ffff_u32, payload)
    Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, stream_id, payload)
  end
end
