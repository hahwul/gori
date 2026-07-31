require "../../spec_helper"

private alias Frame = Gori::Proxy::H2::Frame
private alias HeadBlock = Gori::Proxy::H2::Assembler::HeadBlock

private class NullSink < Gori::Proxy::FlowSink
  @id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

private def with_bindings(&)
  path = File.tempname("gori-h2-extract", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Bindings.load(store), store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def pipeline(bindings : Gori::Bindings) : {Gori::Proxy::H2::Extract, Gori::Proxy::H2::Assembler}
  assembler = Gori::Proxy::H2::Assembler.new(NullSink.new, "acme.test", 443, 1_i64)
  {Gori::Proxy::H2::Extract.new(bindings, assembler, "acme.test", 443), assembler}
end

# Open a stream by feeding its REQUEST head to the assembler, exactly as the relay does. The
# `pre` projection is what the rewrite path hands over, so no HPACK encoding is needed here.
private def open_stream(assembler, stream : UInt32, path : String = "/login", method : String = "POST") : Nil
  fields = [{":method", method}, {":scheme", "https"}, {":authority", "acme.test"}, {":path", path}]
  assembler.feed("out", Frame::Header.new(Frame::Type::Headers.value,
    Frame::END_HEADERS, stream, Bytes.empty), HeadBlock.new(fields))
end

private def response_frame(stream : UInt32) : Frame::Header
  Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, stream, Bytes.empty)
end

# --- the gate rig (the P4 half) ---------------------------------------------

private alias HPACK = Gori::Proxy::H2::HPACK

# A live client+origin pair of gates over in-memory legs, with the response direction carrying
# an `H2::Extract`. Mirrors `Relay#gates`, which is the only place the two are wired together.
private class GateRig
  getter enc_out = HPACK::Encoder.new
  getter enc_in = HPACK::Encoder.new
  getter c2s : Gori::Proxy::H2::StreamGate
  getter s2c : Gori::Proxy::H2::StreamGate

  def initialize(ic : Gori::Interceptor, bindings : Gori::Bindings)
    sink = NullSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "acme.test", 443, 1_i64)
    heads_out = Gori::Proxy::H2::HeadRewrite.new("out", nil, assembler, "acme.test")
    heads_in = Gori::Proxy::H2::HeadRewrite.new("in", nil, assembler, "acme.test")
    @c2s = Gori::Proxy::H2::StreamGate.new("out", IO::Memory.new, 1_i64, sink, assembler,
      "acme.test", 443, ic, heads_out)
    @s2c = Gori::Proxy::H2::StreamGate.new("in", IO::Memory.new, 1_i64, sink, assembler,
      "acme.test", 443, ic, heads_in,
      Gori::Proxy::H2::Extract.new(bindings, assembler, "acme.test", 443))
    @c2s.peer = @s2c
    @s2c.peer = @c2s
  end

  def open_request(path : String) : Nil
    fields = [{":method", "POST"}, {":scheme", "https"}, {":authority", "acme.test"}, {":path", path}]
    @c2s.accept(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32,
      @enc_out.encode(fields)))
  end

  def respond(status : String, cookie : String) : Nil
    fields = [{":status", status}, {"set-cookie", cookie}]
    @s2c.accept(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32,
      @enc_in.encode(fields)))
  end
end

private def with_gate(&)
  path = File.tempname("gori-h2-extract-gate", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle
    ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
    bindings = Gori::Bindings.load(store)
    yield bindings, GateRig.new(ic, bindings), ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The gate spawns a fiber per held stream; let it reach `reply.receive` and, after a decision,
# let it run the release.
private def settle : Nil
  3.times { Fiber.yield }
end

describe Gori::Proxy::H2::Extract do
  it "binds a cookie off a delivered h2 response head" do
    with_bindings do |bindings, _|
      bindings.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
      extract, assembler = pipeline(bindings)
      open_stream(assembler, 1_u32)
      extract.observe(response_frame(1_u32),
        HeadBlock.new([{":status", "200"}, {"set-cookie", "sid=h2t0ken; Path=/"}]))
      bindings.values["SESSION"].should eq "h2t0ken"
    end
  end

  # The rule's condition scopes on the REQUEST's method and target; an h2 response head carries
  # neither, so the assembler's live stream map is the only source. That is the same map the
  # intercept response gate reads.
  it "scopes the condition on the request the assembler is tracking" do
    with_bindings do |bindings, _|
      bindings.add("SESSION", "path:/login AND method:POST", Gori::ExtractKind::Cookie, "sid").should be_nil
      extract, assembler = pipeline(bindings)
      open_stream(assembler, 1_u32, path: "/logout")
      open_stream(assembler, 3_u32, path: "/login", method: "GET")
      extract.observe(response_frame(1_u32), HeadBlock.new([{":status", "200"}, {"set-cookie", "sid=no"}]))
      extract.observe(response_frame(3_u32), HeadBlock.new([{":status", "200"}, {"set-cookie", "sid=no"}]))
      bindings.bound?("SESSION").should be_false
    end
  end

  # Past `Assembler::MAX_LIVE_STREAMS` the connection stops tracking new streams, so a response
  # arrives with no request target to test the condition against. Inventing one is how an
  # extraction escapes its declared scope — so nothing is extracted.
  it "does not extract from a stream the assembler never tracked" do
    with_bindings do |bindings, _|
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      extract, _ = pipeline(bindings)
      extract.observe(response_frame(99_u32), HeadBlock.new([{":status", "200"}, {"set-cookie", "sid=ghost"}]))
      bindings.bound?("SESSION").should be_false
    end
  end

  it "skips an interim 1xx, as h1 does before its own gates" do
    with_bindings do |bindings, _|
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      extract, assembler = pipeline(bindings)
      open_stream(assembler, 1_u32)
      extract.observe(response_frame(1_u32), HeadBlock.new([{":status", "103"}, {"set-cookie", "sid=early"}]))
      bindings.bound?("SESSION").should be_false
      extract.observe(response_frame(1_u32), HeadBlock.new([{":status", "200"}, {"set-cookie", "sid=final"}]))
      bindings.values["SESSION"].should eq "final"
    end
  end

  it "ignores a request head, a trailer block and every DATA frame" do
    with_bindings do |bindings, store|
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      extract, assembler = pipeline(bindings)
      open_stream(assembler, 1_u32)
      # No `:status` at all — a request head or a trailer block.
      extract.observe(response_frame(1_u32), HeadBlock.new([{"grpc-status", "0"}]))
      # A DATA frame carries no projection at all, which is the cheap test that runs first.
      extract.observe(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, "x".to_slice), nil)
      # An undecodable block: the assembler is told, and there is nothing to read.
      extract.observe(response_frame(1_u32), HeadBlock.new(nil))
      bindings.bound?("SESSION").should be_false
      store.events_after(0, 50).should be_empty
    end
  end

  # DATA streams past this relay untouched, so a body-scoped descriptor has nothing to read.
  # It should not get there at all — `Tls::Tunnel#h2_candidate?` downgrades the host first —
  # but if it does, it says which of the two it was rather than blaming its own selector.
  it "tells a body-scoped rule there was no body, rather than that it found nothing" do
    with_bindings do |bindings, store|
      bindings.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
      extract, assembler = pipeline(bindings)
      open_stream(assembler, 1_u32)
      extract.observe(response_frame(1_u32), HeadBlock.new([{":status", "200"}]))
      events = store.events_after(0, 50)
      events.count { |e| e.kind == "extract_no_body" }.should eq 1
      events.any? { |e| e.kind == "extract_miss" }.should be_false
    end
  end

  it "costs nothing when no extract rule is configured" do
    with_bindings do |bindings, store|
      extract, assembler = pipeline(bindings)
      open_stream(assembler, 1_u32)
      extract.observe(response_frame(1_u32), HeadBlock.new([{":status", "200"}, {"set-cookie", "sid=x"}]))
      store.events_after(0, 50).should be_empty
    end
  end
end

# The P4 half, through a real `StreamGate` rather than by calling the observer directly: a
# response the operator DROPPED never reached the client, so it must not bind. That holds
# structurally — a dropped head goes to `project` (the decoded projection only) and never to
# `write` (the frames gori actually sent) — but "structurally" is exactly the kind of claim
# that quietly stops being true, so it is pinned.
describe "H2::StreamGate — extraction and the intercept decision" do
  it "binds from a response the operator FORWARDED" do
    with_gate do |bindings, rig, ic|
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      rig.open_request("/login")
      rig.respond("200", "sid=forwarded")
      settle
      # Still HELD: the client has not received a byte of it, so nothing may have bound yet.
      bindings.bound?("SESSION").should be_false
      ic.forward(ic.pending.first.id)
      settle
      bindings.values["SESSION"].should eq "forwarded"
    end
  end

  it "does NOT bind from a response the operator DROPPED" do
    with_gate do |bindings, rig, ic|
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      rig.open_request("/login")
      rig.respond("200", "sid=dropped")
      settle
      ic.drop(ic.pending.first.id)
      settle
      bindings.bound?("SESSION").should be_false
    end
  end
end
