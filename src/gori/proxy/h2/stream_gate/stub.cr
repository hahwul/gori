# Match&Replace SHORT-CIRCUIT rules on HTTP/2 (#1635) — reopens `Gori::Proxy::H2::StreamGate`
# (see `proxy/h2/stream_gate.cr` for the class, its state and the `*_locked` lock invariant every
# method here is bound by).
#
# A stub answers a request in the origin's place, so on h2 the stream never opens upstream: the
# request gate suppresses its head exactly as a sandbox refusal does (`refuse_locked` — same
# HPACK latch, same projection-only feed), swallows everything the client sends on it after, and
# hands the answer to the response gate, which writes a HEADERS (+ DATA) of gori's own on the
# client leg.
#
#   * **When.** h1 drains the request body before it answers (`ClientConn#serve_short_circuit`),
#     and so does this: the answer goes out at the request's END_STREAM. Each DATA frame is
#     credited back to the client on the stream and the connection as it arrives, so an upload
#     larger than the origin's window still finishes.
#   * **Flow control.** The answer's DATA spends the client's windows, and the client's credit
#     for it would otherwise reach the origin, which never sent it. That is exactly an owned
#     stream's problem (`body_rule.cr`): the answer is queued as one, so it is paced by the
#     client's windows and repaid out of the connection debt. Which is why this runs only on a
#     connection with the rule path on (`Relay#gates`).
#   * **Faults.** h2 has no per-request connection to close, so `close`, `reset` and a `hang`'s
#     release are a RST_STREAM on that one stream; the rest of the connection carries on.
#
# What it shares with h1 by construction: the rule is asked with the head the head rules wrote
# (`Block#head`), after the sandbox and before an intercept hold, and the flow is marked
# `short_circuited` with the rule's ref, with no ttfb or duration.
class Gori::Proxy::H2::StreamGate
  INTERNAL_ERROR = 0x2_u32

  # Fields an h1 stub may carry that HTTP/2 forbids (RFC 9113 §8.2.2): a response with one is
  # malformed. Framing is gori's to derive, as on h1 (`RuleStub.parse_head` already drops
  # `content-length` / `transfer-encoding`).
  H1_ONLY_FIELDS = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te"}

  # A stubbed request still to be answered: its body is arriving, or its rule's delay or hang is
  # running.
  private record Stubbed, stub : Proxy::HeadRewriter::Stub, head_only : Bool

  @stubs = {} of UInt32 => Stubbed
  # Every stream a stub answered. The origin never saw them open, so nothing the client sends on
  # one may reach it (RFC 9113 §5.1: a frame on an idle stream is a connection error).
  # ponytail: past MAX_REFUSED_STREAMS the lowest id is forgotten. A frame the client still
  # sends on it then reaches the origin, a §5.1 connection error if the origin never opened a
  # higher stream; failing closed like `@refused` would end the connection every 4096 stubs.
  # Track the highest id actually forwarded if that ever shows up in practice.
  @stubbed = Set(UInt32).new
  # Stubbed requests whose body is in, for `answer_stubs` to answer outside the lock.
  @answers = [] of UInt32

  # The request this head opens, answered by a stub. True when a rule claimed it.
  private def stub_locked(block : HeadRewrite::Block) : Bool
    rw = @body_rewriter
    head = block.head
    return false unless @ordered && @flow && rw && head
    method = HeadCodec.pseudo_of(block.fields, ":method")
    # An extended CONNECT (RFC 8441) opens a tunnel a stub has no relay for, as h1's 101 does.
    return false if method == "CONNECT"
    stub = rw.short_circuit(head, @heads.host_of(block))
    return false unless stub
    @heads.latch # suppressing a block desyncs HPACK exactly as reordering one does
    @assembler.note_short_circuit(block.stream_id, stub.ref, stub.error)
    project(block)
    @stubbed << block.stream_id
    @stubbed.delete(@stubbed.min) if @stubbed.size > MAX_REFUSED_STREAMS
    @stubs[block.stream_id] = Stubbed.new(stub, method == "HEAD")
    # A client asking for `100-continue` sends no body until it hears back, so it is answered
    # now and its body (if it sends one anyway) is swallowed, as h1's fault path leaves it unread.
    expects = HeadCodec.pseudo_of(block.fields, "expect").try(&.downcase) == "100-continue"
    @answers << block.stream_id if block.first.end_stream? || expects
    true
  end

  # A later header block on a stubbed stream: the request's trailers.
  private def stub_trailers_locked(block : HeadRewrite::Block) : Bool
    project(block)
    @answers << block.stream_id if block.first.end_stream? && @stubs.has_key?(block.stream_id)
    true
  end

  # Any other frame the client sends on a stubbed stream. Its DATA is the request body: fed to
  # the projection and credited back, since nobody downstream ever will.
  private def stub_frame_locked(f : Frame::Header) : Nil
    case f.frame_type
    when Frame::Type::Data
      @swallowed += f.payload.size
      @assembler.feed(@direction, f, nil)
      if f.end_stream?
        @answers << f.stream_id if @stubs.has_key?(f.stream_id)
      elsif (fc = @flow) && !f.payload.empty?
        fc.refunds[f.stream_id] += f.payload.size
      end
    when Frame::Type::RstStream
      if @stubs.delete(f.stream_id)
        @assembler.drop_stream(f.stream_id, "stream reset by the client before the short-circuit answer")
      end
    end
  end

  # Answer the stubbed requests whose body is in, with `@mutex` released: the answer is written
  # by the PEER, and a delay or a hang waits on a fiber of its own so the pump never sleeps.
  private def answer_stubs : Nil
    ids = @mutex.synchronize do
      next nil if @answers.empty?
      taken = @answers.dup
      @answers.clear
      taken
    end
    ids.try &.each do |id|
      stub = @mutex.synchronize { @stubs[id]? }.try(&.stub)
      next unless stub
      # ponytail: no MAX_HELD_CONNECTIONS cap — a held stream is one fiber on a connection the
      # client already multiplexes, bounded only by the client honouring the origin's
      # SETTINGS_MAX_CONCURRENT_STREAMS (forwarded to it, though these streams never reach it).
      if stub.delay || stub.fault
        spawn { answer_stub(id) }
      else
        answer_stub(id)
      end
    end
  end

  private def answer_stub(id : UInt32) : Nil
    stub = @mutex.synchronize { @stubs[id]? }.try(&.stub) || return
    stub.delay.try { |d| sleep d }
    hung = stub.hang || Store::RespondArgs::DEFAULT_HANG_MS.milliseconds
    sleep hung if stub.fault.try(&.hang?)
    # The client may have reset the stream while it waited.
    stubbed = @mutex.synchronize { @closed ? nil : @stubs.delete(id) } || return
    peer = @peer || return
    if fault = stub.fault
      code, done = case fault
                   in .reset? then {INTERNAL_ERROR, "injected reset (RST_STREAM INTERNAL_ERROR)"}
                   in .hang?  then {CANCEL, "injected hang (released after #{hung.total_seconds.round(1)}s)"}
                   in .close? then {CANCEL, "injected close (RST_STREAM CANCEL)"}
                   end
      @assembler.drop_stream(id, "#{done} by #{stub.ref}")
      peer.write_cross_rst(id, code)
    else
      peer.answer_stub(id, stub, stubbed.head_only)
    end
  rescue
    # A spawned answer has no caller to unwind to, and its leg may already be gone.
  end

  # Write a stub's answer on this (the client's) leg. Called by the OPPOSITE gate with its own
  # lock released, like `write_cross_rst`. Framing mirrors `ClientConn#stub_framing`.
  def answer_stub(stream_id : UInt32, stub : Proxy::HeadRewriter::Stub, head_only : Bool) : Nil
    @mutex.synchronize do
      fc = @flow
      next if @closed || fc.nil?
      status = stub.status
      omit_length = status == 204 || status < 200
      send_body = !head_only && !omit_length && status != 304 && !stub.body.empty?
      fields = stub_fields(stub, omit_length)
      frames = @heads.authored(stream_id, fields, !send_body && status >= 200)
      pre = Assembler::HeadBlock.new(fields.map(&.to_tuple))
      last = frames.size - 1
      # Not offered to extract rules: h1 binds nothing off a stub either.
      frames.each_with_index { |f, i| write(f, i == last ? pre : nil, observe: false) }
      if status < 200
        # A 1xx promises a final response that never follows, as h1 says.
        @assembler.drop_stream(stream_id, "short-circuit stub answered with a non-final #{status}; no final response follows")
        write(rst_frame(stream_id), nil)
      elsif send_body
        send_stub_body_locked(fc, stream_id, stub.body)
      end
    end
  rescue
    # this leg is gone; the client will not read an answer
  end

  # The stub's head as h2 fields, its length the body gori sends.
  private def stub_fields(stub : Proxy::HeadRewriter::Stub, omit_length : Bool) : Array(HPACK::Field)
    status_only = [HPACK::Field.new(":status", stub.status.to_s)]
    fields = HeadCodec.parse_response(stub.head + "\r\n".to_slice, status_only) || status_only
    fields.reject! { |f| H1_ONLY_FIELDS.includes?(f.name) }
    fields << HPACK::Field.new("content-length", stub.body.size.to_s) unless omit_length
    fields
  end

  # The answer's DATA, sent as an owned stream: paced by the client's windows, with no sender to
  # credit (every send carries 0), and counted against this direction's rule buffers until written.
  private def send_stub_body_locked(fc : Flow, stream_id : UInt32, body : Bytes) : Nil
    own = Owned.new(stream_id, @host, false, nil, true, fc.initial + (fc.pre_credit.delete(stream_id) || 0_i64), false)
    own.head_out = true
    own.complete = true
    data_frames(stream_id, body, true).each { |f| own.sends << {f, 0} }
    fc.buffered += body.size
    fc.owned[stream_id] = own
    pump_owned_locked(fc, own)
  end
end
