require "../../spec_helper"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK
private alias Gate = Gori::Proxy::H2::StreamGate

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

# A live client+origin pair of gates over in-memory legs, plus a real Interceptor.
private class Rig
  getter c2s : Gate # client → origin, writes to `upstream`
  getter s2c : Gate # origin → client, writes to `client`
  getter upstream : IO::Memory
  getter client : IO::Memory
  getter ic : Gori::Interceptor
  getter sink : RecSink
  getter assembler : Gori::Proxy::H2::Assembler
  getter enc_out = HPACK::Encoder.new # stands in for the client's encoder
  getter enc_in = HPACK::Encoder.new  # stands in for the origin's encoder
  getter heads_out : Gori::Proxy::H2::HeadRewrite
  getter heads_in : Gori::Proxy::H2::HeadRewrite

  def initialize(@ic : Gori::Interceptor)
    @sink = RecSink.new
    @upstream = IO::Memory.new
    @client = IO::Memory.new
    @assembler = Gori::Proxy::H2::Assembler.new(@sink, "api.example.com", 443, 1_i64)
    @heads_out = Gori::Proxy::H2::HeadRewrite.new("out", nil, @assembler, "api.example.com")
    @heads_in = Gori::Proxy::H2::HeadRewrite.new("in", nil, @assembler, "api.example.com")
    @c2s = Gate.new("out", @upstream, 1_i64, @sink, @assembler, "api.example.com", 443, @ic, @heads_out)
    @s2c = Gate.new("in", @client, 1_i64, @sink, @assembler, "api.example.com", 443, @ic, @heads_in)
    @c2s.peer = @s2c
    @s2c.peer = @c2s
  end

  # Frames actually written to the origin / the client so far.
  def to_origin : Array(Frame::Header)
    drain(@upstream)
  end

  def to_client : Array(Frame::Header)
    drain(@client)
  end

  private def drain(io : IO::Memory) : Array(Frame::Header)
    frames = [] of Frame::Header
    reader = IO::Memory.new(io.to_slice)
    begin
      while (f = Frame.read(reader))
        frames << f
      end
    rescue
      # a partially-written trailing frame is not what any of these specs assert on
    end
    frames
  end
end

private def headers(stream : UInt32, block : Bytes, flags = Frame::END_HEADERS | Frame::END_STREAM) : Frame::Header
  Frame::Header.new(Frame::Type::Headers.value, flags, stream, block)
end

private def data(stream : UInt32, body : String, flags = 0_u8) : Frame::Header
  Frame::Header.new(Frame::Type::Data.value, flags, stream, body.to_slice)
end

private def request(path : String) : Array({String, String})
  [{":method", "GET"}, {":scheme", "https"}, {":authority", "api.example.com"}, {":path", path}]
end

private def response(status : String) : Array({String, String})
  [{":status", status}, {"content-type", "text/plain"}]
end

private def with_ic(&)
  path = File.tempname("gori-h2gate", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle # enable
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The gate spawns a fiber per held stream; let it reach `reply.receive` (and, after a
# decision, let it run the release).
private def settle : Nil
  3.times { Fiber.yield }
end

private def head_of(frames : Array(Frame::Header), stream : UInt32) : Array({String, String})?
  f = frames.find { |x| x.stream_id == stream && x.frame_type == Frame::Type::Headers }
  f ? HPACK::Decoder.new.decode(f.payload) : nil
end

describe Gori::Proxy::H2::StreamGate do
  # ---- D1: what a held stream may and may not cost the others -----------------

  it "keeps the whole connection flowing while one request stream is held" do
    with_ic do |ic|
      rig = Rig.new(ic)

      # Stream 1 opens and is held.
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/held"))))
      settle
      ic.pending_count.should eq(1)
      rig.to_origin.should be_empty # the held head has NOT reached the origin

      # Connection-level frames are never deferred (rule 1).
      ping = Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8))
      rig.c2s.accept(ping)
      rig.to_origin.map(&.frame_type).should eq([Frame::Type::Ping])

      # A stream that was already open keeps uploading: open 3 BEFORE the hold would have
      # queued it, by holding nothing on it.
      rig.s2c.accept(headers(1_u32, rig.enc_in.encode(response("200")), Frame::END_HEADERS))
      # ...and the response direction is not blocked by a request hold at all.
      rig.to_client.map(&.frame_type).should eq([Frame::Type::Headers])

      # Release, and the held head finally goes.
      ic.forward(ic.pending.first.id)
      settle
      rig.to_origin.map(&.frame_type).should eq([Frame::Type::Ping, Frame::Type::Headers])
    end
  end

  it "lets an already-open stream keep sending DATA while a LATER stream is held" do
    with_ic do |ic|
      ic.set_filter("path:/held")
      rig = Rig.new(ic)

      # Stream 1 is not held (filter misses) — it opens and stays open.
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/free")), Frame::END_HEADERS))
      settle
      # Stream 3 is held.
      rig.c2s.accept(headers(3_u32, rig.enc_out.encode(request("/held")), Frame::END_HEADERS))
      settle
      ic.pending_count.should eq(1)

      # Stream 1's body flows straight through while 3 sits held.
      rig.c2s.accept(data(1_u32, "chunk", Frame::END_STREAM))
      sent = rig.to_origin
      sent.map { |f| {f.stream_id, f.frame_type} }.should eq([
        {1_u32, Frame::Type::Headers}, {1_u32, Frame::Type::Data},
      ])
    end
  end

  it "queues a LATER stream open behind a held one and releases them in stream-id order" do
    with_ic do |ic|
      ic.set_filter("path:/held")
      rig = Rig.new(ic)

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/held")), Frame::END_HEADERS))
      settle
      # RFC 9113 §5.1.1: forwarding 3 now would implicitly close 1 at the origin and make the
      # late HEADERS(1) a CONNECTION error.
      rig.c2s.accept(headers(3_u32, rig.enc_out.encode(request("/free")), Frame::END_HEADERS))
      settle
      ic.pending_count.should eq(1) # 3 is queued for ORDER, not held
      rig.to_origin.should be_empty

      ic.forward(ic.pending.first.id)
      settle
      rig.to_origin.map(&.stream_id).should eq([1_u32, 3_u32])
    end
  end

  it "holds a response without deferring any other stream's response" do
    with_ic do |ic|
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      ic.set_filter("path:/held")
      rig = Rig.new(ic)

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/held")), Frame::END_HEADERS))
      rig.c2s.accept(headers(3_u32, rig.enc_out.encode(request("/free")), Frame::END_HEADERS))
      settle
      rig.to_origin.size.should eq(2) # neither request is held

      rig.s2c.accept(headers(1_u32, rig.enc_in.encode(response("200")), Frame::END_HEADERS))
      settle
      ic.pending_count.should eq(1)
      rig.to_client.should be_empty

      # Stream 3's response overtakes the held one freely: response HEADERS open nothing.
      rig.s2c.accept(headers(3_u32, rig.enc_in.encode(response("204")), Frame::END_HEADERS))
      settle
      rig.to_client.map(&.stream_id).should eq([3_u32])

      ic.forward(ic.pending.first.id)
      settle
      rig.to_client.map(&.stream_id).should eq([3_u32, 1_u32])
    end
  end

  it "engages the re-encode latch on a defer even when the head is forwarded unedited" do
    with_ic do |ic|
      ic.set_filter("path:/held")
      rig = Rig.new(ic)
      rig.heads_out.engaged?.should be_false
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/held"))))
      settle
      # Deferring alone latches the direction: a block delivered AHEAD of this one would
      # otherwise read dynamic indices against a table missing this block's inserts. It is not
      # conditional on an edit.
      rig.heads_out.engaged?.should be_true

      ic.forward(ic.pending.first.id)
      settle
      HPACK::Decoder.new.decode(rig.to_origin.first.payload).should eq(request("/held"))
      # A block arriving AFTER the latch is re-encoded too, never passed through.
      rig.c2s.accept(headers(3_u32, rig.enc_out.encode(request("/later")), Frame::END_HEADERS))
      HPACK::Decoder.new.decode(rig.to_origin.last.payload).should eq(request("/later"))
    end
  end

  # ---- D3: drop and edit ------------------------------------------------------

  it "drops a request with RST_STREAM(CANCEL) to the CLIENT only, and records the attempt" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/nope"))))
      settle
      ic.drop(ic.pending.first.id)
      settle

      # The origin never saw the stream open, so it must not be sent an RST for it (§6.4).
      rig.to_origin.should be_empty
      rst = rig.to_client
      rst.size.should eq(1)
      rst.first.frame_type.should eq(Frame::Type::RstStream)
      rst.first.stream_id.should eq(1_u32)
      IO::ByteFormat::BigEndian.decode(UInt32, rst.first.payload).should eq(Gate::CANCEL)

      # Visible in History with h1's own reason string, even though nothing went on the wire.
      rig.sink.requests.map(&.target).should eq(["/nope"])
      rig.sink.responses.first.error.should eq(Gate::DROP_REQUEST_REASON)
    end
  end

  it "drops a response with RST_STREAM(CANCEL) on BOTH legs" do
    with_ic do |ic|
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/x")), Frame::END_HEADERS))
      rig.s2c.accept(headers(1_u32, rig.enc_in.encode(response("200")), Frame::END_HEADERS))
      settle
      ic.drop(ic.pending.first.id)
      settle

      rig.to_client.map(&.frame_type).should eq([Frame::Type::RstStream])
      rig.to_origin.map(&.frame_type).should eq([Frame::Type::Headers, Frame::Type::RstStream])
      rig.sink.responses.first.error.should eq(Gate::DROP_RESPONSE_REASON)
    end
  end

  it "sends an edited head to the origin through the same re-encode path a rule takes" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/before"))))
      settle
      item = ic.pending.first
      edited = String.new(item.raw).sub("/before", "/after").sub("Host:", "x-probe: 1\r\nHost:")
      ic.forward(item.id, edited.to_slice)
      settle

      head = head_of(rig.to_origin, 1_u32).not_nil!
      head.find { |(n, _)| n == ":path" }.not_nil![1].should eq("/after")
      head.find { |(n, _)| n == "x-probe" }.not_nil![1].should eq("1")
    end
  end

  it "shows the operator the synthesized h1 head, the same bytes capture stores" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/p"))))
      settle
      String.new(ic.pending.first.raw).should eq("GET /p HTTP/2\r\nHost: api.example.com\r\n\r\n")
      ic.pending.first.method.should eq("GET")
      ic.pending.first.target.should eq("/p")
      ic.pending.first.host.should eq("api.example.com")
    end
  end

  it "ignores a body typed into a held h2 head, and reverts the editor's Content-Length" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/p"))))
      settle
      item = ic.pending.first
      # What `InterceptView#forward_bytes` would produce for an edit that adds a body.
      ic.forward(item.id, "POST /p HTTP/2\r\nHost: api.example.com\r\nContent-Length: 5\r\n\r\nhello".to_slice)
      settle

      head = head_of(rig.to_origin, 1_u32).not_nil!
      head.find { |(n, _)| n == ":method" }.not_nil![1].should eq("POST") # the head edit lands
      head.any? { |(n, _)| n == "content-length" }.should be_false        # DATA is untouched, so CL is not the operator's to set
      rig.to_origin.any? { |f| f.frame_type == Frame::Type::Data }.should be_false
    end
  end

  it "forwards the head as it stood when an edit is no longer parseable" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/p"))))
      settle
      # `HeadCodec` is deliberately lenient (a `:path` may hold a raw space), so this has to be
      # a head it genuinely cannot read: a non-empty field line with no colon.
      ic.forward(ic.pending.first.id, "GET /p HTTP/2\r\nHost api.example.com\r\n\r\n".to_slice)
      settle
      head_of(rig.to_origin, 1_u32).not_nil!.should eq(request("/p"))
    end
  end

  it "never holds an interim 1xx, the way h1 skips them before its own gate" do
    with_ic do |ic|
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/x")), Frame::END_HEADERS))
      rig.s2c.accept(headers(1_u32, rig.enc_in.encode([{":status", "103"}]), Frame::END_HEADERS))
      settle
      ic.pending_count.should eq(0)
      rig.to_client.size.should eq(1)

      rig.s2c.accept(headers(1_u32, rig.enc_in.encode(response("200")), Frame::END_HEADERS))
      settle
      ic.pending_count.should eq(1)
    end
  end

  # ---- teardown and abandonment ----------------------------------------------

  it "releases a held item and projects the attempt when the connection closes" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/held"))))
      settle
      ic.pending_count.should eq(1)

      rig.c2s.close
      settle
      ic.pending_count.should eq(0)                        # no ghost queue row
      rig.sink.requests.map(&.target).should eq(["/held"]) # the attempt is still visible
    end
  end

  it "abandons a hold the peer resets, without forwarding an RST for a stream the origin never saw" do
    with_ic do |ic|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/held"))))
      settle
      rig.c2s.accept(Frame::Header.new(Frame::Type::RstStream.value, 0_u8, 1_u32, Bytes.new(4)))
      settle
      ic.pending_count.should eq(0)
      rig.to_origin.should be_empty
    end
  end

  # ---- the lock invariant -----------------------------------------------------

  it "completes cross-direction drops in both directions at once (the lock is never nested)" do
    with_ic do |ic|
      rig = Rig.new(ic)
      # Stream 1: a held REQUEST (drop crosses out→in). Stream 3: an open exchange whose
      # RESPONSE is held (drop crosses in→out). Both dropped before either releases.
      rig.c2s.accept(headers(3_u32, rig.enc_out.encode(request("/open")), Frame::END_HEADERS))
      settle
      ic.pending.each { |it| ic.forward(it.id) } # let /open through
      settle
      rig.s2c.accept(headers(3_u32, rig.enc_in.encode(response("200")), Frame::END_HEADERS))
      settle
      rig.c2s.accept(headers(5_u32, rig.enc_out.encode(request("/held"))))
      settle

      ic.pending.size.should eq(2)
      ic.pending.each { |it| ic.drop(it.id) }

      done = Channel(Bool).new(1)
      spawn do
        20.times { Fiber.yield }
        done.send(true)
      end
      select
      when done.receive
      when timeout(5.seconds)
        raise "cross-direction drops deadlocked"
      end

      rig.to_origin.map(&.frame_type).should contain(Frame::Type::RstStream)
      rig.to_client.map(&.frame_type).should contain(Frame::Type::RstStream)
    end
  end
end
