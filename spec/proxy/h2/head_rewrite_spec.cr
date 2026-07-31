require "../../spec_helper"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK
private alias HeadBlock = Gori::Proxy::H2::Assembler::HeadBlock

# Records the decoded projection so a spec can assert what History would show.
private class RecSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse
  @id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

# One literal substitution over the head TEXT — the shape every Match&Replace head rule has.
private class SubRewriter < Gori::Proxy::HeadRewriter
  def initialize(@from : String, @to : String, @on : Bool = true)
  end

  def active? : Bool
    @on
  end

  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).gsub(@from, @to).to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    String.new(head).gsub(@from, @to).to_slice
  end
end

private def pipeline(rewriter : Gori::Proxy::HeadRewriter, direction = "out",
                     sink = RecSink.new) : {Gori::Proxy::H2::HeadRewrite, Gori::Proxy::H2::Assembler, RecSink}
  assembler = Gori::Proxy::H2::Assembler.new(sink, "api.example.com", 443, 1_i64)
  {Gori::Proxy::H2::HeadRewrite.new(direction, rewriter, assembler, "api.example.com"), assembler, sink}
end

# Feed one frame and collect what the relay would forward, plus the projection it would hand
# the assembler — mirroring `Relay#pump` exactly.
private def push(pipe, assembler, frame : Frame::Header) : Array(Frame::Header)
  emitted = [] of Frame::Header
  pipe.accept(frame) do |f, pre|
    emitted << f
    assembler.feed("out", f, pre)
  end
  emitted
end

private def headers(stream : UInt32, block : Bytes, flags = Frame::END_HEADERS | Frame::END_STREAM) : Frame::Header
  Frame::Header.new(Frame::Type::Headers.value, flags, stream, block)
end

private def req(path : String) : Array({String, String})
  [{":method", "GET"}, {":scheme", "https"}, {":authority", "api.example.com"}, {":path", path}]
end

describe Gori::Proxy::H2::HeadRewrite do
  it "forwards a head no rule changes byte-exact, and stays unengaged" do
    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten"))
    block = HPACK::Encoder.new.encode(req("/public"))
    sent = push(pipe, assembler, headers(1_u32, block))

    sent.size.should eq(1)
    sent.first.payload.should eq(block) # untouched bytes on the wire (P7)
    pipe.engaged?.should be_false       # the peer's HPACK table is still the sender's to drive
  end

  it "does nothing at all when no rule is live" do
    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten", on: false))
    block = HPACK::Encoder.new.encode(req("/secret"))
    sent = push(pipe, assembler, headers(1_u32, block))
    sent.first.payload.should eq(block)
    pipe.engaged?.should be_false
  end

  it "re-encodes a head a rule changed, and the peer reads the rewritten value" do
    pipe, assembler, sink = pipeline(SubRewriter.new("/secret", "/rewritten"))
    block = HPACK::Encoder.new.encode(req("/secret"))
    sent = push(pipe, assembler, headers(1_u32, block))

    sent.size.should eq(1)
    peer = HPACK::Decoder.new.decode(sent.first.payload)
    peer.find { |(n, _)| n == ":path" }.not_nil![1].should eq("/rewritten")
    pipe.engaged?.should be_true
    # P7: the capture shows what actually went on the wire, not the pre-rewrite bytes.
    String.new(sink.requests.first.head).should contain("GET /rewritten HTTP/2")
    sink.requests.first.target.should eq("/rewritten")
  end

  it "keeps re-encoding every later head in the direction — and that is what keeps the peer readable" do
    # The invariant, and the proof that "re-encode only the heads a rule changed" is unsound
    # rather than merely uncompressed. The sender indexes incrementally (§6.2.1), so its second
    # block back-references entries the peer only holds if it saw the first block's inserts.
    # Re-encoding block 1 literal-only means the peer never inserted them.
    sender = HPACK::Encoder.new(indexing: true)
    b1 = sender.encode(req("/secret") + [{"x-token", "abcdefghijklmnop"}])
    b2 = sender.encode(req("/public") + [{"x-token", "abcdefghijklmnop"}])
    b2.should_not eq(HPACK::Encoder.new.encode(req("/public") + [{"x-token", "abcdefghijklmnop"}]))

    # A peer that received block 1 re-encoded (so: no inserts) cannot read block 2 as sent.
    expect_raises(Exception) { HPACK::Decoder.new.decode(b2) }

    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten"))
    peer = HPACK::Decoder.new # ONE decoder for the connection, like a real peer
    out1 = push(pipe, assembler, headers(1_u32, b1))
    peer.decode(out1.first.payload)

    out2 = push(pipe, assembler, headers(3_u32, b2))
    pipe.engaged?.should be_true
    out2.first.payload.should_not eq(b2) # re-encoded although no rule touched it
    fields = peer.decode(out2.first.payload)
    fields.find { |(n, _)| n == ":path" }.not_nil![1].should eq("/public")
    fields.find { |(n, _)| n == "x-token" }.not_nil![1].should eq("abcdefghijklmnop")
  end

  it "re-encodes a trailer block once engaged, but never runs rules over it" do
    # A trailer block has no start line, and the header ops treat line 0 as one and skip it —
    # running them over trailers would mangle the first trailer. h1 rules never see trailers
    # either (they sit inside the chunked body), so not applying them is what keeps the two
    # protocols equivalent. Re-encoding them is NOT optional once the direction has engaged.
    pipe, assembler, _ = pipeline(SubRewriter.new("alpha", "beta"), direction: "in")
    sender = HPACK::Encoder.new(indexing: true)
    head = sender.encode([{":status", "200"}, {"x-tag", "alpha"}])
    trailer = sender.encode([{"grpc-status", "0"}, {"x-tag", "alpha"}])

    emitted = [] of Frame::Header
    pipe.accept(headers(1_u32, head, Frame::END_HEADERS)) { |f, pre| emitted << f; assembler.feed("in", f, pre) }
    pipe.accept(headers(1_u32, trailer, Frame::END_HEADERS | Frame::END_STREAM)) { |f, pre| emitted << f; assembler.feed("in", f, pre) }

    pipe.engaged?.should be_true
    peer = HPACK::Decoder.new
    peer.decode(emitted[0].payload).find { |(n, _)| n == "x-tag" }.not_nil![1].should eq("beta")
    emitted[1].payload.should_not eq(trailer) # re-encoded — the peer never saw the head's inserts
    peer.decode(emitted[1].payload).find { |(n, _)| n == "x-tag" }.not_nil![1].should eq("alpha")
  end

  it "splits an oversized re-encoded head into HEADERS + CONTINUATION at 16384" do
    # RFC 9113 §6.5.2 makes 16384 the floor every endpoint must accept, so re-framing needs
    # no reading of the peer's SETTINGS.
    big = "v" * 40_000
    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten"))
    block = HPACK::Encoder.new.encode(req("/secret") + [{"x-big", big}])
    sent = push(pipe, assembler, headers(1_u32, block))

    sent.size.should be > 1
    sent.first.type.should eq(Frame::Type::Headers.value)
    sent.first.end_headers?.should be_false
    sent.first.end_stream?.should be_true # END_STREAM stays on the leading frame
    sent[1..].each { |f| f.type.should eq(Frame::Type::Continuation.value) }
    sent[1..-2].each(&.end_headers?.should(be_false))
    sent.last.end_headers?.should be_true
    sent.each { |f| f.payload.size.should be <= 16384 }

    joined = IO::Memory.new
    sent.each { |f| joined.write(f.payload) }
    HPACK::Decoder.new.decode(joined.to_slice)
      .find { |(n, _)| n == "x-big" }.not_nil![1].should eq(big)
  end

  it "emits nothing until END_HEADERS, then the whole block" do
    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten"))
    block = HPACK::Encoder.new.encode(req("/secret"))
    half = block.size // 2

    push(pipe, assembler, headers(1_u32, block[0, half], 0_u8)).should be_empty
    sent = push(pipe, assembler,
      Frame::Header.new(Frame::Type::Continuation.value, Frame::END_HEADERS, 1_u32, block[half..]))
    HPACK::Decoder.new.decode(sent.first.payload)
      .find { |(n, _)| n == ":path" }.not_nil![1].should eq("/rewritten")
  end

  it "releases a buffered block verbatim, in arrival order, when an intruder frame arrives" do
    # RFC 9113 §6.2/§6.10: only a CONTINUATION for the same stream may follow an unterminated
    # HEADERS. Anything else is a connection error, so there is nothing worth rewriting — but
    # the frames the peer did send must still go out, in order (P7).
    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten"))
    block = HPACK::Encoder.new.encode(req("/secret"))
    partial = headers(1_u32, block, 0_u8)
    push(pipe, assembler, partial).should be_empty

    intruder = Frame::Header.new(Frame::Type::Data.value, 0_u8, 3_u32, "x".to_slice)
    sent = push(pipe, assembler, intruder)
    sent.size.should eq(2)
    sent[0].payload.should eq(block) # the held HEADERS, untouched and first
    sent[1].payload.should eq("x".to_slice)
    pipe.engaged?.should be_false
  end

  it "releases a block still buffered at connection teardown" do
    pipe, assembler, _ = pipeline(SubRewriter.new("/secret", "/rewritten"))
    block = HPACK::Encoder.new.encode(req("/secret"))
    push(pipe, assembler, headers(1_u32, block, 0_u8)).should be_empty
    drained = [] of Frame::Header
    pipe.drain { |f, _| drained << f }
    drained.map(&.payload).should eq([block])
  end

  it "forwards the original head when a rule mangles it beyond parsing" do
    # Loud, not silent: the relay logs it once per direction. Forwarding garbage is not an
    # option on h2, and dropping the stream would be worse than not applying the rule.
    pipe, assembler, _ = pipeline(SubRewriter.new("Host: ", "Host "))
    block = HPACK::Encoder.new.encode(req("/secret"))
    sent = push(pipe, assembler, headers(1_u32, block))
    sent.first.payload.should eq(block)
    pipe.engaged?.should be_false
  end

  it "stays byte-exact for a rule whose change cannot reach the h2 wire at all" do
    # `HTTP/2` is a token the synthesized head carries and the wire format does not. A rule
    # rewriting it changes the text and no field, so re-encoding would cost fidelity for
    # nothing — and must not engage the latch either.
    pipe, assembler, _ = pipeline(SubRewriter.new("HTTP/2", "HTTP/1.1"))
    block = HPACK::Encoder.new.encode(req("/x"))
    sent = push(pipe, assembler, headers(1_u32, block))
    sent.first.payload.should eq(block)
    pipe.engaged?.should be_false
  end

  it "restores content-length so the untouched DATA frames still match the head" do
    # DATA streams untouched until #492 step 5, and h2 validates content-length against it
    # (RFC 9113 §8.1.1) — a rule-changed value would RST the stream instead of rewriting.
    pipe, assembler, _ = pipeline(SubRewriter.new("content-length: 5", "content-length: 999"))
    block = HPACK::Encoder.new.encode(req("/x") + [{"content-length", "5"}])
    sent = push(pipe, assembler, headers(1_u32, block, Frame::END_HEADERS))
    HPACK::Decoder.new.decode(sent.first.payload)
      .find { |(n, _)| n == "content-length" }.not_nil![1].should eq("5")
  end

  it "rewrites a response head and leaves the request direction alone" do
    pipe, assembler, _ = pipeline(SubRewriter.new("HTTP/2 200", "HTTP/2 503"), direction: "in")
    block = HPACK::Encoder.new.encode([{":status", "200"}, {"content-type", "text/html"}])
    emitted = [] of Frame::Header
    pipe.accept(headers(1_u32, block)) { |f, pre| emitted << f; assembler.feed("in", f, pre) }
    HPACK::Decoder.new.decode(emitted.first.payload)
      .find { |(n, _)| n == ":status" }.not_nil![1].should eq("503")
  end

  it "keeps a head-block decode from happening twice (the projection comes from the relay)" do
    # A stateful HPACK decoder run twice over one block is desynced from the sender for the
    # rest of the connection. The assembler must take the relay's already-decoded fields.
    pipe, assembler, sink = pipeline(SubRewriter.new("/secret", "/rewritten"))
    sender = HPACK::Encoder.new(indexing: true)
    push(pipe, assembler, headers(1_u32, sender.encode(req("/secret") + [{"x-a", "0123456789abcdef"}])))
    push(pipe, assembler, headers(3_u32, sender.encode(req("/second") + [{"x-a", "0123456789abcdef"}])))

    # The second block back-references the first's insert; only a decoder advanced exactly
    # once per block resolves it.
    sink.requests.size.should eq(2)
    sink.requests[1].target.should eq("/second")
    String.new(sink.requests[1].head).should contain("x-a: 0123456789abcdef")
  end

  # #517. A field value carrying the head's own delimiter has no h1-text form, and the bridge
  # used to turn it into two well-formed wire fields — a message the far endpoint would have
  # REJECTED (RFC 9113 §8.2.1) arriving as one it accepts. Everything below decodes what the
  # far side actually receives, with a fresh decoder, exactly as a real peer would.
  describe "a peer head the h1 text cannot carry (#517)" do
    it "does not split a CRLF-bearing request value into a second header" do
      pipe, assembler, _ = pipeline(SubRewriter.new("x-tag: a", "x-tag: b"))
      fields = req("/x") + [{"x-tag", "a"}, {"x-echo", "safe\r\nx-admin: true"}]
      block = HPACK::Encoder.new.encode(fields)
      sent = push(pipe, assembler, headers(1_u32, block))

      origin = HPACK::Decoder.new.decode(sent.first.payload)
      origin.should eq(fields)                                         # the peer's head, field for field
      origin.map(&.[0]).should_not contain("x-admin")                  # nothing was invented
      origin.count { |(n, _)| n == "x-echo" }.should eq(1)             # one field in, one field out
      origin.find { |(n, _)| n == "x-tag" }.not_nil![1].should eq("a") # the rule did NOT run
    end

    it "does not split a CRLF-bearing response value into a second header" do
      pipe, assembler, _ = pipeline(SubRewriter.new("x-tag: a", "x-tag: b"), direction: "in")
      fields = [{":status", "200"}, {"x-tag", "a"}, {"x-echo", "safe\r\nset-cookie: injected=1"}]
      block = HPACK::Encoder.new.encode(fields)
      emitted = [] of Frame::Header
      pipe.accept(headers(1_u32, block)) { |f, pre| emitted << f; assembler.feed("in", f, pre) }

      client = HPACK::Decoder.new.decode(emitted.first.payload)
      client.should eq(fields)
      client.map(&.[0]).should_not contain("set-cookie")
    end

    it "still RE-ENCODES it once the direction has latched, rather than falling back to passthrough" do
      # The disposition is "emit the ORIGINAL FIELDS", not "forward the original frames". On an
      # engaged direction those are not the same thing: the sender's encoder has kept indexing
      # (§6.2.1) against a table the peer no longer shares, so a passthrough block here would
      # resolve its dynamic indices against the wrong table. Malformed in, malformed out — but
      # re-encoded, because the latch is one-way.
      pipe, assembler, _ = pipeline(SubRewriter.new("x-tag: alpha", "x-tag: beta"), direction: "in")
      sender = HPACK::Encoder.new(indexing: true)
      b1 = sender.encode([{":status", "200"}, {"x-tag", "alpha"}, {"x-token", "abcdefghijklmnop"}])
      evil = [{":status", "200"}, {"x-echo", "safe\r\nset-cookie: injected=1"}, {"x-token", "abcdefghijklmnop"}]
      b2 = sender.encode(evil)

      peer = HPACK::Decoder.new # ONE decoder for the connection, like a real client
      out1 = [] of Frame::Header
      pipe.accept(headers(1_u32, b1)) { |f, pre| out1 << f; assembler.feed("in", f, pre) }
      peer.decode(out1.first.payload)
      pipe.engaged?.should be_true

      out2 = [] of Frame::Header
      pipe.accept(headers(3_u32, b2)) { |f, pre| out2 << f; assembler.feed("in", f, pre) }
      out2.first.payload.should_not eq(b2) # re-encoded, not forwarded as it arrived
      peer.decode(out2.first.payload).should eq(evil)
    end

    it "refuses an intercept edit of one, because the text the operator edited is not the message" do
      pipe, _, _ = pipeline(SubRewriter.new("x-tag: a", "x-tag: b"), direction: "in")
      evil = [HPACK::Field.new(":status", "200"),
              HPACK::Field.new("x-echo", "safe\r\nset-cookie: injected=1")]
      block = Gori::Proxy::H2::HeadRewrite::Block.new(
        [] of Frame::Header, HeadBlock.new(evil.map(&.to_tuple)), evil,
        "HTTP/2 200\r\nx-echo: safe\r\nset-cookie: injected=1\r\n\r\n".to_slice,
        headers(1_u32, Bytes.empty), Bytes.empty, false)
      pipe.encode_edited(block, "HTTP/2 200\r\nx-echo: edited\r\n\r\n".to_slice).should be_nil

      # Control: the same edit on a head the text CAN carry is applied as it always was.
      ok = [HPACK::Field.new(":status", "200"), HPACK::Field.new("x-echo", "safe")]
      fine = Gori::Proxy::H2::HeadRewrite::Block.new(
        [] of Frame::Header, HeadBlock.new(ok.map(&.to_tuple)), ok,
        "HTTP/2 200\r\nx-echo: safe\r\n\r\n".to_slice,
        headers(1_u32, Bytes.empty), Bytes.empty, false)
      edited = pipe.encode_edited(fine, "HTTP/2 200\r\nx-echo: edited\r\n\r\n".to_slice).not_nil!
      edited.fields.map(&.to_tuple).should eq([{":status", "200"}, {"x-echo", "edited"}])
    end

    it "still adds two headers for a CRLF the OPERATOR wrote — those are their bytes (P7)" do
      # The guard reads what the PEER sent, never what a rule produced. The identical rule adds
      # two headers on h1; making h2 disagree would be the silent-divergence class this epic
      # exists to remove.
      pipe, assembler, _ = pipeline(SubRewriter.new("x-tag: a", "x-tag: b\r\nx-added: 1"), direction: "in")
      block = HPACK::Encoder.new.encode([{":status", "200"}, {"x-tag", "a"}])
      emitted = [] of Frame::Header
      pipe.accept(headers(1_u32, block)) { |f, pre| emitted << f; assembler.feed("in", f, pre) }
      HPACK::Decoder.new.decode(emitted.first.payload)
        .should eq([{":status", "200"}, {"x-tag", "b"}, {"x-added", "1"}])
    end
  end
end
