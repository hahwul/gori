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
  getter enc_out : HPACK::Encoder    # stands in for the client's encoder
  getter enc_in = HPACK::Encoder.new # stands in for the origin's encoder
  getter heads_out : Gori::Proxy::H2::HeadRewrite
  getter heads_in : Gori::Proxy::H2::HeadRewrite

  # `host` is the CONNECT authority — the connection's own name, which a coalesced stream's
  # `:authority` may differ from (RFC 9113 §9.1.1). `indexing` makes the stand-in client encoder
  # insert into its dynamic table, i.e. behave like a browser rather than like gori's own
  # literal-only encoder.
  def initialize(@ic : Gori::Interceptor, host : String = "api.example.com", indexing : Bool = false)
    @sink = RecSink.new
    @upstream = IO::Memory.new
    @client = IO::Memory.new
    @enc_out = HPACK::Encoder.new(indexing: indexing)
    @assembler = Gori::Proxy::H2::Assembler.new(@sink, host, 443, 1_i64)
    @heads_out = Gori::Proxy::H2::HeadRewrite.new("out", nil, @assembler, host)
    @heads_in = Gori::Proxy::H2::HeadRewrite.new("in", nil, @assembler, host)
    @c2s = Gate.new("out", @upstream, 1_i64, @sink, @assembler, host, 443, @ic, @heads_out)
    @s2c = Gate.new("in", @client, 1_i64, @sink, @assembler, host, 443, @ic, @heads_in)
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

private def request(path : String, authority : String = "api.example.com") : Array({String, String})
  [{":method", "GET"}, {":scheme", "https"}, {":authority", authority}, {":path", path}]
end

private def response(status : String) : Array({String, String})
  [{":status", status}, {"content-type", "text/plain"}]
end

private def with_ic(intercept : Bool = true, &)
  path = File.tempname("gori-h2gate", ".db")
  store = Gori::Store.open(path)
  begin
    scope = Gori::Scope.load(store)
    ic = Gori::Interceptor.new(scope)
    ic.toggle if intercept
    # The sandbox is independent of intercept, so the step-4 specs take the scope and leave
    # intercept off — the two gates are proved separately, then together.
    yield ic, scope
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

  # ---- #492 step 4: the sandbox, per stream -----------------------------------
  #
  # Every scope here is a `string` rule, i.e. a URL-level one. That is not an arbitrary choice:
  # `Scope#sandbox_blocks_host?` treats ANY url-level include as "the path might match on this
  # host", so the pre-handshake CONNECT gate lets every host through and the per-request gate is
  # the only one that ever fires. It is exactly the scope shape that the tunnel's old
  # `sandbox_enabled?` downgrade was carrying.

  it "refuses an out-of-scope h2 request: nothing upstream, RST_STREAM(CANCEL) to the client" do
    with_ic(intercept: false) do |ic, scope|
      scope.add("include", "string", "https://api.example.com/api/")
      scope.enable_sandbox
      rig = Rig.new(ic)

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/admin"))))

      rig.to_origin.should be_empty # the refused head never reached the origin
      rst = rig.to_client
      rst.map(&.frame_type).should eq([Frame::Type::RstStream])
      rst.first.stream_id.should eq(1_u32)
      IO::ByteFormat::BigEndian.decode(UInt32, rst.first.payload).should eq(Gate::CANCEL)

      # Visible in History under h1's own string for a blocked request (`client_conn.cr:1249`).
      rig.sink.requests.map(&.target).should eq(["/admin"])
      rig.sink.responses.first.error.should eq(Gate::SANDBOX_REASON)
    end
  end

  it "lets an in-scope request through on the same connection" do
    with_ic(intercept: false) do |ic, scope|
      scope.add("include", "string", "https://api.example.com/api/")
      scope.enable_sandbox
      rig = Rig.new(ic)

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/api/v1"))))
      rig.to_origin.map(&.stream_id).should eq([1_u32])
      rig.to_client.should be_empty
    end
  end

  it "swallows a refused stream's later DATA instead of forwarding the body it just refused" do
    with_ic(intercept: false) do |ic, scope|
      scope.add("include", "string", "https://api.example.com/api/")
      scope.enable_sandbox
      rig = Rig.new(ic)

      # No END_STREAM: the client is still uploading when its head is refused.
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/admin")), Frame::END_HEADERS))
      rig.c2s.accept(data(1_u32, "the body the gate refused", Frame::END_STREAM))

      # Forwarding it would hand over the refused body AND be a connection error at an origin
      # that never saw stream 1 open (§5.1).
      rig.to_origin.should be_empty
    end
  end

  it "refuses a COALESCED stream whose :authority is out of scope, on an in-scope connection" do
    with_ic(intercept: false) do |ic, scope|
      # The connection is to api.example.com and that host is in scope. §9.1.1 lets the client
      # reuse it for any name the certificate covers, so the stream's own authority is the one
      # that has to be tested — h1 inside a tunnel never had to face this, because
      # `resolve_forward` pins every request to the CONNECT host.
      scope.add("include", "string", "https://api.example.com/")
      scope.enable_sandbox
      rig = Rig.new(ic, host: "api.example.com")

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/x", authority: "evil.example.com"))))
      rig.to_origin.should be_empty
      rig.to_client.map(&.frame_type).should eq([Frame::Type::RstStream])
    end
  end

  it "refuses an in-scope :authority riding an out-of-scope connection" do
    with_ic(intercept: false) do |ic, scope|
      # The mirror of the case above, and the reason BOTH URLs are tested rather than one: a
      # client that simply claims an in-scope name would otherwise walk a request into an origin
      # the scope never allowed.
      scope.add("include", "string", "https://acme.test/")
      scope.enable_sandbox
      rig = Rig.new(ic, host: "evil.example.com")

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/x", authority: "acme.test"))))
      rig.to_origin.should be_empty
      rig.to_client.map(&.frame_type).should eq([Frame::Type::RstStream])
    end
  end

  it "re-encodes the rest of the direction after a refusal, so a suppressed head cannot desync HPACK" do
    with_ic(intercept: false) do |ic, scope|
      scope.add("include", "string", "https://api.example.com/api/")
      scope.enable_sandbox
      rig = Rig.new(ic, indexing: true) # a client that indexes — i.e. every browser

      # Stream 1 is refused. Its block inserted `x-token` into the CLIENT's dynamic table; the
      # origin never received the block, so the origin's decoder table did not grow.
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/admin") + [{"x-token", "abc"}])))
      rig.heads_out.engaged?.should be_true

      # Stream 3 refers to `x-token` by DYNAMIC INDEX. Passed through verbatim it would resolve
      # against a table missing the insert — the wrong header, silently. `head_of` decodes with a
      # FRESH decoder, which is exactly the origin's position.
      allowed = request("/api/ok") + [{"x-token", "abc"}]
      rig.c2s.accept(headers(3_u32, rig.enc_out.encode(allowed), Frame::END_HEADERS))
      head_of(rig.to_origin, 3_u32).should eq(allowed)
    end
  end

  it "forwards everything when the sandbox is OFF, however narrow the scope is" do
    with_ic(intercept: false) do |ic, scope|
      scope.add("include", "string", "https://api.example.com/api/")
      # Sandbox NOT enabled: the scope is a display lens here, never a block (`scope.cr`).
      rig = Rig.new(ic)

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/admin"))))
      rig.to_origin.map(&.stream_id).should eq([1_u32])
      rig.to_client.should be_empty
      rig.heads_out.engaged?.should be_false # and the direction stays byte-exact
    end
  end

  it "refuses before holding: an out-of-scope request is never offered to the operator" do
    with_ic do |ic, scope| # intercept ON as well
      scope.add("include", "string", "https://api.example.com/api/")
      scope.enable_sandbox
      rig = Rig.new(ic)

      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/admin"))))
      settle
      # There is no decision to offer about a request that is not going anywhere, and a queue
      # row for one would let Forward override the sandbox.
      ic.pending_count.should eq(0)
      rig.to_origin.should be_empty
    end
  end

  it "closes the connection on a header block it cannot decode while the sandbox is on" do
    with_ic(intercept: false) do |ic, scope|
      scope.add("include", "string", "https://api.example.com/")
      scope.enable_sandbox
      rig = Rig.new(ic)

      # An indexed-field representation whose varint never terminates: gori's decoder gives up,
      # and a head it cannot read is a head it cannot scope-test.
      truncated = Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8]
      expect_raises(Gori::Error) { rig.c2s.accept(headers(1_u32, truncated)) }
      rig.to_origin.should be_empty
    end
  end

  it "still forwards a block it cannot decode when the sandbox is off (P7 — the relay is honest)" do
    with_ic(intercept: false) do |ic, _scope|
      rig = Rig.new(ic)
      truncated = Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8]
      rig.c2s.accept(headers(1_u32, truncated))
      rig.to_origin.map(&.stream_id).should eq([1_u32])
    end
  end

  it "swallows a DROPPED request's later DATA too, for the same reason a refused one's" do
    with_ic do |ic, _scope|
      rig = Rig.new(ic)
      rig.c2s.accept(headers(1_u32, rig.enc_out.encode(request("/nope")), Frame::END_HEADERS))
      settle
      ic.drop(ic.pending.first.id)
      settle

      rig.c2s.accept(data(1_u32, "still uploading", Frame::END_STREAM))
      # The origin never saw stream 1 open; before step 4 this DATA was written to it.
      rig.to_origin.should be_empty
    end
  end
end
