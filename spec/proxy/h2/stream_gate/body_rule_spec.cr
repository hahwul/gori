require "../../../spec_helper"
require "socket"

# #1628: a Match&Replace BODY rule runs on HTTP/2 instead of downgrading the host. Every example
# puts a real h2 client and a real h2 origin on either side of `H2::Relay` over 127.0.0.1, both
# of which keep flow control honestly: each tracks its receive windows and records a
# FLOW_CONTROL_ERROR the moment one goes negative, and each sends only what its send windows
# allow. A shrink that strands credit or a grow that overruns a window shows up as a stall or an
# error, not as a pass.

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

private REQ  = Gori::Store::RuleTarget::Request
private RESP = Gori::Store::RuleTarget::Response
private BODY = Gori::Store::RulePart::Body

private class BodySink < Gori::Proxy::FlowSink
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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# One h2 endpoint that keeps both of its windows the way RFC 9113 §6.9 says a peer must.
private class Peer
  getter errors = [] of String
  getter heads = {} of UInt32 => Array({String, String})
  getter trailers = {} of UInt32 => Array({String, String})
  getter bodies = Hash(UInt32, IO::Memory).new { |h, k| h[k] = IO::Memory.new }
  getter data_frames = Hash(UInt32, Array(Int32)).new { |h, k| h[k] = [] of Int32 }
  getter done = [] of UInt32
  # RST_STREAMs and GOAWAYs received — expected in some examples, so kept apart from `errors`.
  getter resets = [] of UInt32
  getter goaways = 0
  property on_complete : Proc(UInt32, Nil)? = nil
  # Called (on its own fiber) when a stream's first head arrives.
  property on_open : Proc(UInt32, Nil)? = nil
  # Stream credit is held back until this much is owed, the way curl/nghttp2 and Firefox ack a
  # wide per-stream window: late. 0 = every frame.
  property stream_ack = 0_i64
  # While set, connection credit is held back until `release_conn`: a reader that stopped.
  property? hold_conn = false
  @held_conn = 0

  # Both connection windows, readable once the exchange is at rest: the sender's view of the
  # receiver's window has to equal the receiver's own, or credit was stranded or invented.
  getter send_conn = 65_535_i64
  getter recv_conn = 65_535_i64

  # `lag` delays every WINDOW_UPDATE this peer sends, the way a slow reader does. Credit then
  # trails the data, which is when a sender trusting a window it was not given overruns it.
  def initialize(@io : IO, @server : Bool, @recv_initial : Int64 = 65_535_i64, @lag : Time::Span? = nil)
    @mutex = Mutex.new
    @enc = HPACK::Encoder.new
    @dec = HPACK::Decoder.new
    @send_initial = 65_535_i64
    @send_streams = {} of UInt32 => Int64
    @recv_streams = {} of UInt32 => Int64
    @block = IO::Memory.new
    @block_stream = 0_u32
    @block_end = false
    @closing = false
    @unacked = Hash(UInt32, Int64).new(0_i64)
  end

  # Widen one stream's receive window by `n` up front.
  def bump(stream : UInt32, n : Int32) : Nil
    @recv_streams[stream] = recv_window(stream) + n
    window_update(stream, n)
  end

  # Announce a new SETTINGS_INITIAL_WINDOW_SIZE; every open stream's window moves with it.
  def change_initial(value : Int64) : Nil
    delta = value - @recv_initial
    @recv_initial = value
    @recv_streams.each_key { |k| @recv_streams[k] += delta }
    payload = Bytes.new(6)
    IO::ByteFormat::BigEndian.encode(0x4_u16, payload[0, 2])
    IO::ByteFormat::BigEndian.encode(value.to_u32, payload[2, 4])
    frame(Frame::Type::Settings, 0_u8, 0_u32, payload)
  end

  def send_rst(stream : UInt32) : Nil
    frame(Frame::Type::RstStream, 0_u8, stream, Bytes[0, 0, 0, 8])
  end

  def send_goaway(last : UInt32) : Nil
    payload = Bytes.new(8)
    IO::ByteFormat::BigEndian.encode(last, payload[0, 4])
    frame(Frame::Type::Goaway, 0_u8, 0_u32, payload)
  end

  private def recv_window(stream : UInt32) : Int64
    @recv_streams[stream]? || @recv_initial
  end

  def start : Nil
    @io.write(Frame::PREFACE) unless @server
    payload = Bytes.empty
    if @recv_initial != 65_535
      payload = Bytes.new(6)
      IO::ByteFormat::BigEndian.encode(0x4_u16, payload[0, 2])
      IO::ByteFormat::BigEndian.encode(@recv_initial.to_u32, payload[2, 4])
    end
    frame(Frame::Type::Settings, 0_u8, 0_u32, payload)
    spawn { read_loop }
  end

  def close : Nil
    @closing = true
    @io.close rescue nil
  end

  # One DATA frame as given, padding and all — outside the window bookkeeping, so keep it small.
  def send_raw_data(stream : UInt32, payload : Bytes, flags : UInt8) : Nil
    @mutex.synchronize do
      @send_conn -= payload.size
      @send_streams[stream] = send_window(stream) - payload.size
    end
    frame(Frame::Type::Data, flags, stream, payload)
  end

  def send_head(stream : UInt32, fields : Array({String, String}), end_stream : Bool) : Nil
    @mutex.synchronize do
      block = @enc.encode(fields)
      flags = Frame::END_HEADERS | (end_stream ? Frame::END_STREAM : 0_u8)
      @io.write(Frame::Header.new(Frame::Type::Headers.value, flags, stream, block).to_bytes)
      @io.flush
    end
  end

  # Only as fast as the windows allow, in frames of at most 16 KiB.
  def send_body(stream : UInt32, body : Bytes, end_stream : Bool) : Nil
    at = 0
    loop do
      left = body.size - at
      if left == 0
        frame(Frame::Type::Data, Frame::END_STREAM, stream, Bytes.empty) if end_stream
        return
      end
      avail = wait_window(stream) || return
      take = {left, 16_384, avail}.min
      last = at + take == body.size
      @mutex.synchronize do
        @send_conn -= take
        @send_streams[stream] = send_window(stream) - take
      end
      frame(Frame::Type::Data, last && end_stream ? Frame::END_STREAM : 0_u8, stream, body[at, take])
      at += take
      return if last
    end
  end

  def send(stream : UInt32, fields : Array({String, String}), body : Bytes,
           trailer : Array({String, String})? = nil) : Nil
    send_head(stream, fields, body.empty? && trailer.nil?)
    send_body(stream, body, trailer.nil?) unless body.empty?
    send_head(stream, trailer, true) if trailer
  end

  def wait_done(stream : UInt32, timeout = 10.seconds) : Bool
    deadline = Time.instant + timeout
    until @done.includes?(stream)
      return false if Time.instant > deadline || !@errors.empty?
      sleep 2.milliseconds
    end
    true
  end

  def body_of(stream : UInt32) : String
    String.new(bodies[stream].to_slice)
  end

  def send_window(stream : UInt32) : Int64
    @send_streams[stream]? || @send_initial
  end

  def release_conn : Nil
    @hold_conn = false
    @recv_conn += @held_conn
    window_update(0_u32, @held_conn) if @held_conn > 0
    @held_conn = 0
  end

  private def wait_window(stream : UInt32) : Int32?
    deadline = Time.instant + 10.seconds
    loop do
      avail = Math.min(@send_conn, send_window(stream))
      return avail.to_i32 if avail > 0
      if Time.instant > deadline
        @errors << "stalled waiting for window on stream #{stream}"
        return nil
      end
      sleep 1.millisecond
    end
  end

  private def frame(type : Frame::Type, flags : UInt8, stream : UInt32, payload : Bytes) : Nil
    @mutex.synchronize do
      @io.write(Frame::Header.new(type.value, flags, stream, payload).to_bytes)
      @io.flush
    end
  end

  private def window_update(stream : UInt32, n : Int32) : Nil
    payload = Bytes.new(4)
    IO::ByteFormat::BigEndian.encode(n.to_u32, payload)
    frame(Frame::Type::WindowUpdate, 0_u8, stream, payload)
  end

  private def read_loop : Nil
    Frame.read_preface(@io) if @server
    while f = Frame.read(@io)
      handle(f)
    end
  rescue ex
    @errors << "read: #{ex.message}" unless @closing
  end

  private def handle(f : Frame::Header) : Nil
    case f.frame_type
    when Frame::Type::Settings     then on_settings(f)
    when Frame::Type::WindowUpdate then on_window_update(f)
    when Frame::Type::Headers, Frame::Type::Continuation
      on_headers(f)
    when Frame::Type::Data      then on_data(f)
    when Frame::Type::RstStream then @resets << f.stream_id
    when Frame::Type::Goaway    then @goaways += 1
    end
  end

  private def on_settings(f : Frame::Header) : Nil
    return if f.ack?
    at = 0
    while at + 6 <= f.payload.size
      if IO::ByteFormat::BigEndian.decode(UInt16, f.payload[at, 2]) == 0x4
        value = IO::ByteFormat::BigEndian.decode(UInt32, f.payload[at + 2, 4]).to_i64
        delta = value - @send_initial
        @send_initial = value
        @send_streams.each_key { |k| @send_streams[k] += delta }
      end
      at += 6
    end
    frame(Frame::Type::Settings, Frame::ACK, 0_u32, Bytes.empty)
  end

  private def on_window_update(f : Frame::Header) : Nil
    n = (IO::ByteFormat::BigEndian.decode(UInt32, f.payload) & 0x7fff_ffff_u32).to_i64
    @errors << "zero WINDOW_UPDATE on stream #{f.stream_id}" if n == 0
    if f.stream_id == 0
      @send_conn += n
    else
      @send_streams[f.stream_id] = send_window(f.stream_id) + n
    end
  end

  private def on_headers(f : Frame::Header) : Nil
    if f.frame_type == Frame::Type::Headers
      @block.clear
      @block_stream = f.stream_id
      @block_end = f.end_stream?
    end
    @block.write(f.payload)
    return unless f.end_headers?
    fields = @dec.decode(@block.to_slice.dup)
    if heads.has_key?(@block_stream)
      trailers[@block_stream] = fields
    else
      heads[@block_stream] = fields
      stream = @block_stream
      @on_open.try { |cb| spawn { cb.call(stream) } }
    end
    complete(@block_stream) if @block_end
  end

  private def on_data(f : Frame::Header) : Nil
    n = f.payload.size
    @recv_conn -= n
    left = recv_window(f.stream_id) - n
    @recv_streams[f.stream_id] = left
    @errors << "FLOW_CONTROL_ERROR (connection, #{@recv_conn})" if @recv_conn < 0
    @errors << "FLOW_CONTROL_ERROR (stream #{f.stream_id}, #{left})" if left < 0
    bodies[f.stream_id].write(f.payload)
    data_frames[f.stream_id] << n
    credit(f.stream_id, n, f.end_stream?) if n > 0
    complete(f.stream_id) if f.end_stream?
  end

  # Consumed at once, so credited — conn and, while it is open, stream — at once or after `lag`.
  private def credit(stream : UInt32, n : Int32, ended : Bool) : Nil
    if lag = @lag
      spawn do
        sleep lag
        grant(stream, n, ended) rescue nil
      end
    else
      grant(stream, n, ended)
    end
  end

  private def grant(stream : UInt32, n : Int32, ended : Bool) : Nil
    if @hold_conn
      @held_conn += n
    else
      @recv_conn += n
      window_update(0_u32, n)
    end
    return if ended
    @unacked[stream] += n
    return if @unacked[stream] < @stream_ack
    owed = @unacked.delete(stream).not_nil!.to_i32
    @recv_streams[stream] = recv_window(stream) + owed
    window_update(stream, owed)
  end

  private def complete(stream : UInt32) : Nil
    @done << stream
    if cb = @on_complete
      spawn { cb.call(stream) }
    end
  end
end

# What the origin answers a finished request with: {head, body, trailers}.
# nil = the answer block sent (or withheld) the response itself.
private alias Answer = {Array({String, String}), Bytes, Array({String, String})?}?

private class BodyRig
  getter sink = BodySink.new
  getter client : Peer
  getter! origin : Peer
  @servers : Array(TCPServer)

  def initialize(rules : Gori::Rules, ic : Gori::Interceptor, host : String = "127.0.0.1",
                 origin_window : Int64 = 65_535_i64, lag : Time::Span? = nil,
                 client_window : Int64 = 65_535_i64, opened : Proc(UInt32, Peer, Nil)? = nil,
                 &answer : UInt32, Peer -> Answer)
    origin_srv = TCPServer.new("127.0.0.1", 0)
    front = TCPServer.new("127.0.0.1", 0)
    @servers = [origin_srv, front]
    origin_port = origin_srv.local_address.port
    sink = @sink
    spawn do
      next unless conn = origin_srv.accept?
      conn.read_timeout = 15.seconds
      peer = Peer.new(conn, true, origin_window, lag)
      peer.on_complete = ->(stream : UInt32) do
        if reply = answer.call(stream, peer)
          head, body, trailer = reply
          peer.send(stream, head, body, trailer)
        end
        nil
      end
      opened.try { |cb| peer.on_open = ->(stream : UInt32) { cb.call(stream, peer) } }
      @origin = peer
      peer.start
    end
    spawn do
      next unless conn = front.accept?
      upstream = TCPSocket.new("127.0.0.1", origin_port)
      Gori::Proxy::H2::Relay.run(conn, upstream, host, origin_port, sink, rewriter: rules, interceptor: ic)
    end
    socket = TCPSocket.new("127.0.0.1", front.local_address.port)
    socket.read_timeout = 15.seconds
    @client = Peer.new(socket, false, client_window)
    @client.start
  end

  def wait_origin : Peer
    20.times { break if @origin; sleep 10.milliseconds }
    origin
  end

  def close : Nil
    @client.close
    @origin.try(&.close)
    @servers.each { |s| s.close rescue nil }
  end
end

private def post(path : String, length : Int32? = nil, authority = "127.0.0.1",
                 type = "application/x-www-form-urlencoded") : Array({String, String})
  head = [{":method", "POST"}, {":scheme", "https"}, {":authority", authority}, {":path", path},
          {"content-type", type}]
  head << {"content-length", length.to_s} if length
  head
end

private def get(path : String, authority = "127.0.0.1") : Array({String, String})
  [{":method", "GET"}, {":scheme", "https"}, {":authority", authority}, {":path", path}]
end

private def ok(length : Int32? = nil, type = "text/plain") : Array({String, String})
  head = [{":status", "200"}, {"content-type", type}]
  head << {"content-length", length.to_s} if length
  head
end

private def grpc_post : Array({String, String})
  [{":method", "POST"}, {":scheme", "https"}, {":authority", "127.0.0.1"},
   {":path", "/pkg.Svc/Ping"}, {"content-type", "application/grpc"}, {"te", "trailers"}]
end

private def echo(stream : UInt32, peer : Peer) : Answer
  {ok, "ok".to_slice, nil}
end

private def field(fields : Array({String, String}), name : String) : String?
  fields.find { |(n, _)| n == name }.try(&.[1])
end

# At rest, the sender's view of the receiver's connection window is the receiver's own: credit
# was neither stranded (a shrink) nor invented (a grow).
private def settled(sender : Peer, receiver : Peer) : Nil
  50.times do
    break if sender.send_conn == receiver.recv_conn
    sleep 10.milliseconds
  end
  sender.send_conn.should eq(receiver.recv_conn)
end

private def with_rules(&)
  with_store do |store|
    yield Gori::Rules.load(store), Gori::Interceptor.new(Gori::Scope.load(store))
  end
end

describe "H2::StreamGate body rules (#1628)" do
  it "shrinks a request body and makes its content-length true" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "hunter2", "x", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        body = "user=admin&password=hunter2"
        rig.client.send(1_u32, post("/login", body.bytesize), body.to_slice)
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.body_of(1_u32).should eq("user=admin&password=x")
        field(origin.heads[1_u32], "content-length").should eq("21")
        rig.client.body_of(1_u32).should eq("ok")
        (rig.client.errors + origin.errors).should be_empty

        captured = rig.sink.requests.first
        String.new(captured.body.not_nil!).should eq("user=admin&password=x")
        rewrite = captured.rewrite.not_nil!
        String.new(rewrite.body.not_nil!).should eq(body)
        rewrite.hits.size.should eq(1)
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  # 100 KiB in, 200 KiB out: both past the 65,535-byte initial window, against an origin that
  # only allows 16 KiB per stream and credits it late, so the re-emit has to wait on the
  # origin's WINDOW_UPDATEs rather than on its connection window alone.
  it "grows a request body past the initial window without a stall or FLOW_CONTROL_ERROR" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "aa", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic, origin_window: 16_384_i64, lag: 20.milliseconds) { |s, p| echo(s, p) }
      begin
        body = "a" * 100_000
        rig.client.send(1_u32, post("/upload", body.bytesize), body.to_slice)
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.body_of(1_u32).should eq("a" * 200_000)
        field(origin.heads[1_u32], "content-length").should eq("200000")
        (rig.client.errors + origin.errors).should be_empty

        # And the connection still carries a second, ordinary exchange afterwards: no credit was
        # stranded on either leg.
        rig.client.send(3_u32, post("/again", 3), "abc".to_slice)
        rig.client.wait_done(3_u32).should be_true
        origin.body_of(3_u32).should eq("aabc")
        (rig.client.errors + origin.errors).should be_empty
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  # The rewrite grows stream 1 by 29,000 bytes the client never sent, so the origin's connection
  # window is 29,000 short of what the client believes, and an origin slow to credit does not say
  # so for a while. Stream 3 is passthrough and fills what the client thinks is free: without
  # gori holding back what would overrun the origin, that is FLOW_CONTROL_ERROR.
  it "holds passthrough DATA back while the origin still owes gori for a grown body" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "x", "x" * 30, host: "127.0.0.1")
      rig = BodyRig.new(rules, ic, lag: 150.milliseconds) { |s, p| echo(s, p) }
      begin
        rig.client.send(1_u32, post("/grow", 1_000), ("x" * 1_000).to_slice)
        rig.client.wait_done(1_u32).should be_true
        body = "p" * 60_000
        rig.client.send(3_u32, post("/pass", body.bytesize, authority: "other.test"), body.to_slice)
        rig.client.wait_done(3_u32).should be_true
        origin = rig.wait_origin
        origin.body_of(1_u32).should eq("x" * 30_000)
        origin.body_of(3_u32).should eq(body)
        (rig.client.errors + origin.errors).should be_empty
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  it "shrinks a response body past the initial window and fixes its content-length" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "SECRET", "", host: "127.0.0.1")
      body = "SECRET" * 20_000 + "tail"
      rig = BodyRig.new(rules, ic) { |_, _| {ok(body.bytesize), body.to_slice, nil} }
      begin
        rig.client.send(1_u32, post("/x", 1), "q".to_slice)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("tail")
        field(rig.client.heads[1_u32], "content-length").should eq("4")
        (rig.client.errors + rig.wait_origin.errors).should be_empty

        rig.client.send(3_u32, post("/y", 1), "q".to_slice)
        rig.client.wait_done(3_u32).should be_true
        rig.client.body_of(3_u32).should eq("tail")
        (rig.client.errors + rig.wait_origin.errors).should be_empty
        settled(rig.wait_origin, rig.client)
      ensure
        rig.close
      end
    end
  end

  it "grows a response body with no declared length past the client's window" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "bbb", host: "127.0.0.1")
      body = "b" * 70_000
      rig = BodyRig.new(rules, ic) { |_, _| {ok, body.to_slice, nil} }
      begin
        rig.client.send(1_u32, post("/x", 1), "q".to_slice)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("b" * 210_000)
        field(rig.client.heads[1_u32], "content-length").should be_nil
        (rig.client.errors + rig.wait_origin.errors).should be_empty
        settled(rig.wait_origin, rig.client)
      ensure
        rig.close
      end
    end
  end

  # Stream 1's response is a body rule's and is still arriving; stream 3's is for a host no rule
  # matches (RFC 9113 §9.1.1 coalescing) and finishes its whole exchange in the meantime.
  it "does not hold up a concurrent stream the rule does not match" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "half", "HALF", host: "127.0.0.1")
      release = Channel(Nil).new
      rig = BodyRig.new(rules, ic) do |s, p|
        next {ok, "half".to_slice, nil} unless s == 1_u32
        p.send_head(1_u32, ok, false)
        p.send_body(1_u32, "first half,".to_slice, false)
        release.receive
        p.send_body(1_u32, " second half".to_slice, true)
        nil
      end
      begin
        rig.client.send_head(1_u32, get("/slow"), true)
        sleep 50.milliseconds
        rig.client.send_head(3_u32, get("/fast", "other.test"), true)
        rig.client.wait_done(3_u32).should be_true
        rig.client.body_of(3_u32).should eq("half")
        rig.client.heads.has_key?(1_u32).should be_true   # no declared length: the head went out
        rig.client.bodies.has_key?(1_u32).should be_false # its body is still with gori

        release.send(nil)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("first HALF, second HALF")
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # Stream 1 declares its length, so its head waits for its body — and RFC 9113 §5.1.1 puts the
  # later stream 3 behind it. Stream 3's DATA waits parked, then both go out in order.
  it "releases a later stream behind a request head that waited for its body" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "one", "ONE", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send_head(1_u32, post("/first", 6), false)
        rig.client.send_body(1_u32, "one".to_slice, false)
        rig.client.send(3_u32, post("/second", 3, authority: "other.test"), "one".to_slice)
        sleep 50.milliseconds
        origin = rig.wait_origin
        origin.heads.should be_empty # nothing may open ahead of stream 1's held head

        rig.client.send_body(1_u32, "two".to_slice, true)
        rig.client.wait_done(1_u32).should be_true
        rig.client.wait_done(3_u32).should be_true
        origin.body_of(1_u32).should eq("ONEtwo")
        origin.body_of(3_u32).should eq("one")
        field(origin.heads[1_u32], "content-length").should eq("6")
        (rig.client.errors + origin.errors).should be_empty
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  it "carries trailers after a rewritten body" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "cat", "dog", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send(1_u32, post("/t", 5, type: "text/plain"), "a cat".to_slice, [{"x-checksum", "1"}])
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.body_of(1_u32).should eq("a dog")
        origin.trailers[1_u32].should eq([{"x-checksum", "1"}])
        (rig.client.errors + origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # A padded frame is bytes only the assembler knows how to strip, so the body goes out as it
  # arrived, padding and all, and the flow says why.
  it "forwards a padded body unmodified" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "abc", "xyz", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send_head(1_u32, post("/p", 3), false)
        padded = Bytes[2] + "abc".to_slice + Bytes[0, 0]
        rig.client.send_raw_data(1_u32, padded, Frame::END_STREAM | Frame::PADDED)
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.bodies[1_u32].to_slice.should eq(padded)
        rig.sink.requests.first.advisory.not_nil!.should contain("arrived padded")
        (rig.client.errors + origin.errors).should be_empty
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  # No declared length, so gori only finds out mid-body that it is over the ceiling: what it
  # buffered goes out as it arrived and the rest streams after it, credit following the bytes.
  it "spills a body that runs past the buffering ceiling and forwards it unmodified" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "z", "Z", host: "127.0.0.1")
      body = Bytes.new(Gori::Proxy::H2::StreamGate::MAX_RULE_BODY + 100_000, 'z'.ord.to_u8)
      rig = BodyRig.new(rules, ic) { |_, _| {ok, body, nil} }
      begin
        rig.client.send_head(1_u32, get("/big"), true)
        rig.client.wait_done(1_u32, 30.seconds).should be_true
        rig.client.bodies[1_u32].to_slice.should eq(body)
        rig.sink.responses.first.advisory.not_nil!.should contain("ceiling")
        (rig.client.errors + rig.wait_origin.errors).should be_empty
        settled(rig.wait_origin, rig.client)
      ensure
        rig.close
      end
    end
  end

  # The rule is scoped to a host this connection is not, so the relay never builds the body
  # path: the origin sees the client's own DATA frames, boundaries and all.
  it "keeps the untouched frame path for a host no body rule matches" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "b", host: "alpha.test")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        body = "a" * 40_000
        rig.client.send(1_u32, post("/x", body.bytesize), body.to_slice)
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.body_of(1_u32).should eq(body)
        origin.data_frames[1_u32].should eq([16_384, 16_384, 7_232])
        (rig.client.errors + origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  it "forwards a body no rule changed as the peer's own frames" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "absent", "x", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        body = "a" * 40_000
        rig.client.send(1_u32, post("/x", body.bytesize), body.to_slice)
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.body_of(1_u32).should eq(body)
        origin.data_frames[1_u32].should eq([16_384, 16_384, 7_232])
        field(origin.heads[1_u32], "content-length").should eq("40000")
        rig.sink.requests.first.rewrite.should be_nil
        (rig.client.errors + origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  it "leaves a compressed body alone and says so on the flow" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "b", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        head = post("/x", 3) << {"content-encoding", "gzip"}
        rig.client.send(1_u32, head, "aaa".to_slice)
        rig.client.wait_done(1_u32).should be_true
        rig.wait_origin.body_of(1_u32).should eq("aaa")
        rig.sink.requests.first.advisory.not_nil!.should contain("arrived compressed")
      ensure
        rig.close
      end
    end
  end

  # gRPC (#1637): length-prefixed messages, `te: trailers`, and the status in TRAILERS. A unary
  # call has the rule run over each message's payload and the 5-byte prefix re-framed around it,
  # on a connection that stays h2.
  it "rewrites a unary gRPC call both ways, re-framing each message" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "ping", "PINGED", host: "127.0.0.1")
      rules.add(RESP, BODY, "pong", "P", host: "127.0.0.1")
      message = Bytes[0, 0, 0, 0, 4] + "ping".to_slice
      reply = Bytes[0, 0, 0, 0, 4] + "pong".to_slice
      rig = BodyRig.new(rules, ic) do |_, _|
        {[{":status", "200"}, {"content-type", "application/grpc"}], reply, [{"grpc-status", "0"}]}
      end
      begin
        rig.client.send(1_u32, grpc_post, message)
        rig.client.wait_done(1_u32).should be_true
        origin = rig.wait_origin
        origin.bodies[1_u32].to_slice.should eq(Bytes[0, 0, 0, 0, 6] + "PINGED".to_slice)
        rig.client.bodies[1_u32].to_slice.should eq(Bytes[0, 0, 0, 0, 1] + "P".to_slice)
        rig.client.trailers[1_u32].should eq([{"grpc-status", "0"}])
        rig.sink.requests.first.rewrite.not_nil!.body.not_nil!.should eq(message)
        (rig.client.errors + origin.errors).should be_empty
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  it "leaves a client-streaming gRPC call as it arrived" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "ping", "PONG", host: "127.0.0.1")
      body = Bytes[0, 0, 0, 0, 4] + "ping".to_slice + Bytes[0, 0, 0, 0, 4] + "ping".to_slice
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send(1_u32, grpc_post, body)
        rig.client.wait_done(1_u32).should be_true
        rig.wait_origin.bodies[1_u32].to_slice.should eq(body)
        rig.sink.requests.first.advisory.not_nil!.should contain("more than one gRPC message")
      ensure
        rig.close
      end
    end
  end

  it "leaves a compressed gRPC message as it arrived" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "ping", "PONG", host: "127.0.0.1")
      message = Bytes[1, 0, 0, 0, 4] + "ping".to_slice
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send(1_u32, grpc_post << {"grpc-encoding", "gzip"}, message)
        rig.client.wait_done(1_u32).should be_true
        rig.wait_origin.bodies[1_u32].to_slice.should eq(message)
        rig.sink.requests.first.advisory.not_nil!.should contain("compressed")
      ensure
        rig.close
      end
    end
  end

  # A bidirectional call whose client sends one message and waits for the reply before ending
  # the request: buffering it to END_STREAM would deadlock, so it goes on after the grace.
  it "lets a gRPC message whose stream does not end go on after the grace" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "ping", "PONG", host: "127.0.0.1")
      message = Bytes[0, 0, 0, 0, 4] + "ping".to_slice
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send_head(1_u32, grpc_post, false)
        rig.client.send_body(1_u32, message, false)
        origin = rig.wait_origin
        deadline = Time.instant + 2.seconds
        until origin.bodies[1_u32].size == message.size || Time.instant > deadline
          sleep 5.milliseconds
        end
        origin.bodies[1_u32].to_slice.should eq(message)
        rig.client.send_body(1_u32, Bytes.empty, true)
        rig.client.wait_done(1_u32).should be_true
        rig.sink.requests.first.advisory.not_nil!.should contain("may be a streaming call")
        (rig.client.errors + origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # The stall timer may be asleep until a held upload's 5 s deadline; a gRPC grace started under
  # it still runs out on time.
  it "ends a gRPC grace on time while a held upload's timer sleeps" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "ping", "PONG", host: "127.0.0.1")
      message = Bytes[0, 0, 0, 0, 4] + "ping".to_slice
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send_head(1_u32, grpc_post, false)
        rig.client.send_head(3_u32, post("/up", 100), false)
        rig.client.send_body(3_u32, ("a" * 10).to_slice, false)
        sleep 50.milliseconds
        rig.client.send_body(1_u32, message, false)
        origin = rig.wait_origin
        deadline = Time.instant + 1.second
        until origin.bodies[1_u32].size == message.size || Time.instant > deadline
          sleep 5.milliseconds
        end
        origin.bodies[1_u32].to_slice.should eq(message)
      ensure
        rig.close
      end
    end
  end

  # Review #1: curl/nghttp2 and Firefox widen a stream's window right after the request and ack
  # late. That credit reached the origin before gori owned the response, so it is gori's to
  # spend: seeding the owned stream at the initial window alone stalled it at 65,535 bytes.
  it "spends stream credit the client granted before the response arrived" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      body = "b" * 300_000
      rig = BodyRig.new(rules, ic) { |_, _| {ok, body.to_slice, nil} }
      begin
        rig.client.stream_ack = 500_000_i64
        rig.client.send_head(1_u32, get("/x"), true)
        rig.client.bump(1_u32, 1_000_000)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("c" * 300_000)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # Review #4: a request with no declared length may be full duplex, so it is never buffered —
  # here the origin answers before the request ends, as a Connect or ndjson stream would.
  it "leaves a request with no declared length streaming, full duplex included" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "ping", "PONG", host: "127.0.0.1")
      opened = ->(stream : UInt32, origin : Peer) do
        origin.send(stream, ok, "pong".to_slice)
        nil
      end
      rig = BodyRig.new(rules, ic, opened: opened) { |_, _| nil }
      begin
        rig.client.send_head(1_u32, post("/duplex"), false)
        rig.client.send_body(1_u32, "ping,".to_slice, false)
        rig.client.wait_done(1_u32).should be_true # the reply arrived while the request is open
        rig.client.send_body(1_u32, "ping".to_slice, true)
        origin = rig.wait_origin
        origin.wait_done(1_u32).should be_true
        origin.body_of(1_u32).should eq("ping,ping")
        (rig.client.errors + origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # Review #4: a response held for its declared length must not hold the origin's stream credit
  # for the REQUEST with it, or an origin that finishes its reply only after the whole upload
  # waits on an upload that waits on that credit.
  it "keeps the request's stream credit moving while its response head is held" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "hello", "HELLO", host: "127.0.0.1")
      opened = ->(stream : UInt32, origin : Peer) do
        origin.send_head(stream, ok(10), false)
        origin.send_body(stream, "hello".to_slice, false)
        origin.wait_done(stream)
        origin.send_body(stream, "world".to_slice, true)
        nil
      end
      rig = BodyRig.new(rules, ic, opened: opened) { |_, _| nil }
      begin
        upload = "u" * 200_000
        rig.client.send_head(1_u32, post("/up", type: "text/plain"), false)
        rig.client.send_body(1_u32, upload.to_slice, true)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("HELLOworld")
        rig.wait_origin.body_of(1_u32).should eq(upload)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # Review #2: the origin would answer 100 Continue to a head gori was holding for the very body
  # the client will not send until it does.
  it "does not hold a request head that asks for 100-continue" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "abc", "xyz", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) { |s, p| echo(s, p) }
      begin
        rig.client.send_head(1_u32, post("/c", 3) << {"expect", "100-continue"}, false)
        origin = rig.wait_origin
        10.times { break if origin.heads.has_key?(1_u32); sleep 20.milliseconds }
        origin.heads.has_key?(1_u32).should be_true
        rig.client.send_body(1_u32, "abc".to_slice, true)
        rig.client.wait_done(1_u32).should be_true
        origin.body_of(1_u32).should eq("abc")
        rig.sink.requests.first.advisory.not_nil!.should contain("100-continue")
      ensure
        rig.close
      end
    end
  end

  # Review #3: each owned stream is credited as it arrives, so without a budget across streams
  # two 9 MiB responses would sit in memory at once. The one that crosses it spills.
  it "spills the stream that crosses the connection's buffering budget" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      body = Bytes.new(9 * 1024 * 1024, 'b'.ord.to_u8)
      # Both bodies are sent before either ends, so both are buffering at once.
      sent = Channel(Nil).new(2)
      go = Channel(Nil).new(2)
      rig = BodyRig.new(rules, ic) do |s, p|
        p.send_head(s, ok, false)
        p.send_body(s, body, false)
        sent.send(nil)
        go.receive
        p.send_raw_data(s, Bytes.empty, Frame::END_STREAM)
        nil
      end
      begin
        rig.client.send_head(1_u32, get("/one"), true)
        rig.client.send_head(3_u32, get("/two"), true)
        2.times { sent.receive }
        2.times { go.send(nil) }
        rig.client.wait_done(1_u32, 30.seconds).should be_true
        rig.client.wait_done(3_u32, 30.seconds).should be_true
        got = [1_u32, 3_u32].map { |id| rig.client.bodies[id].to_slice }
        got.each(&.size.should(eq(body.size)))
        got.count(&.==(body)).should eq(1) # one spilled unmodified, the other was rewritten
        advisories = rig.sink.responses.compact_map(&.advisory)
        advisories.any?(&.includes?("buffered on this connection")).should be_true
        (rig.client.errors + rig.wait_origin.errors).should be_empty
        settled(rig.wait_origin, rig.client)
      ensure
        rig.close
      end
    end
  end

  # A body that finished arriving still sits with gori until a slow reader takes it, and its
  # sender was credited on arrival: it counts against the budget until it is written, or three
  # 8 MiB downloads to a client that never widens its streams hold 24 MiB.
  it "counts a finished body against the budget until the receiver takes it" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "zzz", "yyy", host: "127.0.0.1")
      size = 8 * 1024 * 1024
      sent = [] of UInt32
      rig = BodyRig.new(rules, ic) do |s, p|
        spawn do
          p.send(s, ok(size), Bytes.new(size, 'a'.ord.to_u8))
          sent << s
        end
        nil
      end
      begin
        rig.client.stream_ack = 1_000_000_000_i64 # a slow reader: no stream credit past the first window
        [1_u32, 3_u32, 5_u32].each do |id|
          rig.client.send_head(id, get("/big#{id}"), true)
          40.times { break if sent.includes?(id); sleep 50.milliseconds }
        end
        sent.should eq([1_u32, 3_u32]) # the third spilled, so its origin is credited only as gori sends
      ensure
        rig.close
      end
    end
  end

  # Review #5: h1 runs no rule over an empty body, so a `^` pattern does not invent one.
  it "runs no rule over an empty body" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "^", "X", match_kind: Gori::Store::MatchKind::Regex, host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) do |s, p|
        p.send_head(s, ok, false)
        p.send_raw_data(s, Bytes.empty, Frame::END_STREAM)
        nil
      end
      begin
        rig.client.send_head(1_u32, get("/empty"), true)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("")
      ensure
        rig.close
      end
    end
  end

  it "survives a reset from either side mid-buffer, and the connection carries on" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "q", "Q", host: "127.0.0.1")
      rules.add(RESP, BODY, "r", "R", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) do |s, p|
        case s
        when 3_u32 # the origin resets a response it was sending
          p.send_head(s, ok(10), false)
          p.send_body(s, "rrr".to_slice, false)
          p.send_rst(s)
          nil
        when 5_u32 # a response the client will reset
          p.send_head(s, ok, false)
          p.send_body(s, "rrr".to_slice, false)
          nil
        else
          {ok, "rr".to_slice, nil}
        end
      end
      begin
        # The client resets a request whose head gori is still holding for its body.
        rig.client.send_head(1_u32, post("/a", 10), false)
        rig.client.send_body(1_u32, "qqq".to_slice, false)
        rig.client.send_rst(1_u32)

        rig.client.send(3_u32, post("/b", 1), "q".to_slice)
        10.times { break if rig.client.resets.includes?(3_u32); sleep 20.milliseconds }
        rig.client.resets.should contain(3_u32)
        rig.client.heads.has_key?(3_u32).should be_false # its head was held for the body

        rig.client.send(5_u32, post("/c", 1), "q".to_slice)
        sleep 50.milliseconds
        rig.client.send_rst(5_u32)

        rig.client.send(7_u32, post("/d", 2), "qq".to_slice)
        rig.client.wait_done(7_u32).should be_true
        rig.client.body_of(7_u32).should eq("RR")
        origin = rig.wait_origin
        origin.heads.has_key?(1_u32).should be_false # never opened on the origin
        origin.body_of(7_u32).should eq("QQ")
        origin.resets.should contain(5_u32)
        (rig.client.errors + origin.errors).should be_empty
        settled(rig.client, origin)
        settled(origin, rig.client)
      ensure
        rig.close
      end
    end
  end

  # The client widens SETTINGS_INITIAL_WINDOW_SIZE while gori owns its response and never acks
  # the stream itself, so the only room past 20,000 bytes is the setting's change (§6.9.2).
  it "follows a SETTINGS_INITIAL_WINDOW_SIZE change on an owned stream" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      body = "b" * 60_000
      rig = BodyRig.new(rules, ic, client_window: 20_000_i64) { |_, _| {ok, body.to_slice, nil} }
      begin
        rig.client.stream_ack = 10_000_000_i64
        rig.client.send_head(1_u32, get("/x"), true)
        sleep 100.milliseconds
        rig.client.bodies[1_u32].size.should eq(20_000)
        rig.client.change_initial(100_000_i64)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("c" * 60_000)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # A client that advertises a zero initial window and opens each stream only once its response
  # head is in: that credit is the origin's only way to send at all, so it cannot stop at gori.
  it "passes stream credit through to a sender that has none" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic, client_window: 0_i64) { |_, _| {ok, "bbbb".to_slice, nil} }
      begin
        rig.client.send_head(1_u32, get("/x"), true)
        50.times { break if rig.client.heads.has_key?(1_u32); sleep 20.milliseconds }
        rig.client.bump(1_u32, 100_000)
        rig.client.wait_done(1_u32, 3.seconds).should be_true
        rig.client.body_of(1_u32).should eq("cccc")
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # A spilled stream whose sender has used its whole window while the receiver's connection
  # window is spent: gori owes the sender the credit of every frame it still queues, so stream
  # credit the receiver grants then is not the sender's as well, or it is paid twice.
  it "passes no stream credit to a sender that queued frames gori still owes it for" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) do |s, p|
        p.send_head(s, ok, false)
        p.send_raw_data(s, Bytes[2] + "aaaaaaa".to_slice + Bytes[0, 0], Frame::PADDED) # spills it
        p.send_body(s, Bytes.new(200_000, 'a'.ord.to_u8), true)
        nil
      end
      begin
        rig.client.hold_conn = true
        rig.client.stream_ack = 1_000_000_000_i64
        rig.client.send_head(1_u32, get("/x"), true)
        origin = rig.wait_origin
        100.times { break if origin.send_conn == 0 && origin.send_window(1_u32) == 0; sleep 20.milliseconds }
        origin.send_window(1_u32).should eq(0)
        rig.client.bump(1_u32, 1_000)
        sleep 100.milliseconds
        origin.send_window(1_u32).should eq(0)
        rig.client.release_conn
        rig.client.bump(1_u32, 200_000)
        rig.client.wait_done(1_u32).should be_true
        rig.client.bodies[1_u32].size.should eq(200_010)
        (rig.client.errors + origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # Review r2 #1: credit a client gives a stream AFTER its response ended (a slow reader acking
  # what it consumed) used to stay recorded for good, and past 1,024 such streams the stall the
  # pre-response credit fixes came back for every new one.
  it "keeps spending pre-response credit after many streams were credited late" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      body = "b" * 300_000
      rig = BodyRig.new(rules, ic) { |s, _| s < 2_049_u32 ? {ok, "ok".to_slice, nil} : {ok, body.to_slice, nil} }
      begin
        stream = 1_u32
        1_024.times do
          rig.client.send_head(stream, get("/x"), true)
          rig.client.wait_done(stream).should be_true
          rig.client.bump(stream, 1_000)
          stream += 2
        end
        rig.client.stream_ack = 500_000_i64
        rig.client.send_head(stream, get("/x"), true)
        rig.client.bump(stream, 1_000_000)
        rig.client.wait_done(stream).should be_true
        rig.client.body_of(stream).should eq("c" * 300_000)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # The same, through the other exit: the client credits a stream up front and the ORIGIN resets
  # it before any response, which only the response gate's own write of the RST sees.
  it "keeps spending pre-response credit after many origin resets" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      body = "b" * 300_000
      rig = BodyRig.new(rules, ic) do |s, p|
        next {ok, body.to_slice, nil} if s >= 2_049_u32
        p.send_rst(s)
        nil
      end
      begin
        stream = 1_u32
        1_024.times do
          rig.client.send_head(stream, get("/x"), true)
          rig.client.bump(stream, 1_000)
          stream += 2
        end
        50.times { break if rig.client.resets.size == 1_024; sleep 20.milliseconds }
        rig.client.resets.size.should eq(1_024)
        rig.client.stream_ack = 500_000_i64
        rig.client.send_head(stream, get("/x"), true)
        rig.client.bump(stream, 1_000_000)
        rig.client.wait_done(stream).should be_true
        rig.client.body_of(stream).should eq("c" * 300_000)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # GOAWAY names the last stream the origin will process; an owned one below it still finishes.
  it "finishes an owned stream across a GOAWAY" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "b", "c", host: "127.0.0.1")
      rig = BodyRig.new(rules, ic) do |s, p|
        p.send_goaway(s)
        {ok(5), "bbbbb".to_slice, nil}
      end
      begin
        rig.client.send_head(1_u32, get("/x"), true)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("ccccc")
        rig.client.goaways.should eq(1)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # A WebSocket over h2 (RFC 8441): the origin's `:status 200` opens a tunnel that never ends on
  # its own, so a response rule buffering it would hold every server frame until the socket closed.
  it "relays an extended CONNECT's tunnel with a response body rule live" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "zzz", "yyy", host: "127.0.0.1")
      opened = ->(stream : UInt32, origin : Peer) do
        origin.send_head(stream, [{":status", "200"}], false)
        origin.send_body(stream, Bytes[0x81, 0x05] + "hello".to_slice, false)
        nil
      end
      rig = BodyRig.new(rules, ic, opened: opened) { |_, _| nil }
      begin
        head = [{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"},
                {":authority", "127.0.0.1"}, {":path", "/chat"}, {"sec-websocket-version", "13"}]
        rig.client.send_head(1_u32, head, false)
        50.times { break if rig.client.bodies[1_u32].size > 0; sleep 20.milliseconds }
        rig.client.bodies[1_u32].size.should eq(7)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end

  # Past `Assembler::MAX_LIVE_STREAMS` open streams the assembler tracks no new one, so the gate
  # cannot see that this answer is to a CONNECT; it must not own a response it cannot place.
  it "relays an extended CONNECT's tunnel the assembler is not tracking" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "zzz", "yyy", host: "127.0.0.1")
      last = 2_u32 * Gori::Proxy::H2::Assembler::MAX_LIVE_STREAMS + 1
      opened = ->(stream : UInt32, origin : Peer) do
        if stream == last
          origin.send_head(stream, [{":status", "200"}], false)
          origin.send_body(stream, Bytes[0x81, 0x05] + "hello".to_slice, false)
        end
        nil
      end
      rig = BodyRig.new(rules, ic, opened: opened) { |_, _| nil }
      begin
        (1_u32...last).step(2) { |id| rig.client.send_head(id, get("/open#{id}"), true) }
        head = [{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"},
                {":authority", "127.0.0.1"}, {":path", "/chat"}, {"sec-websocket-version", "13"}]
        rig.client.send_head(last, head, false)
        100.times { break if rig.client.bodies[last].size > 0; sleep 20.milliseconds }
        rig.client.bodies[last].size.should eq(7)
        (rig.client.errors + rig.wait_origin.errors).should be_empty
      ensure
        rig.close
      end
    end
  end
end

# Against the gates directly, so the deadline can be short.
private class GatePair
  getter sink = BodySink.new
  getter up = IO::Memory.new   # what the origin was sent
  getter down = IO::Memory.new # what the client was sent
  getter out_gate : Gori::Proxy::H2::StreamGate
  getter in_gate : Gori::Proxy::H2::StreamGate
  @enc_in = HPACK::Encoder.new

  # `indexing`: the client's encoder inserts into its dynamic table, as a browser's does, so a
  # block that reaches the origin out of order or re-encoded is one that would decode wrong.
  def initialize(rules : Gori::Rules, ic : Gori::Interceptor, deadline : Time::Span, indexing = false)
    @enc_out = HPACK::Encoder.new(indexing: indexing)
    host = "api.example.com"
    assembler = Gori::Proxy::H2::Assembler.new(@sink, host, 443)
    @out_gate = Gori::Proxy::H2::StreamGate.new("out", @up, 1_i64, @sink, assembler, host, 443, ic,
      Gori::Proxy::H2::HeadRewrite.new("out", rules, assembler, host, nil, true), body_rewriter: rules)
    @in_gate = Gori::Proxy::H2::StreamGate.new("in", @down, 1_i64, @sink, assembler, host, 443, ic,
      Gori::Proxy::H2::HeadRewrite.new("in", rules, assembler, host, nil, true), nil, rules)
    @out_gate.peer = @in_gate
    @in_gate.peer = @out_gate
    @out_gate.hold_wait_deadline = deadline
    @in_gate.hold_wait_deadline = deadline
  end

  # The HEADERS payload the client sent.
  def request(stream : UInt32, fields : Array({String, String}), end_stream = false) : Bytes
    flags = Frame::END_HEADERS | (end_stream ? Frame::END_STREAM : 0_u8)
    payload = @enc_out.encode(fields)
    @out_gate.accept(Frame::Header.new(Frame::Type::Headers.value, flags, stream, payload))
    payload
  end

  def response(stream : UInt32, fields : Array({String, String})) : Nil
    @in_gate.accept(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, stream, @enc_in.encode(fields)))
  end

  def data(gate : Gori::Proxy::H2::StreamGate, stream : UInt32, body : String, last = false) : Nil
    gate.accept(Frame::Header.new(Frame::Type::Data.value, last ? Frame::END_STREAM : 0_u8, stream, body.to_slice))
  end

  def frames(io : IO::Memory) : Array(Frame::Header)
    frames = [] of Frame::Header
    reader = IO::Memory.new(io.to_slice)
    while f = Frame.read(reader)
      frames << f
    end
    frames
  end

  def close : Nil
    @out_gate.close
    @in_gate.close
  end
end

private def shape(frames : Array(Frame::Header)) : Array({Frame::Type?, UInt32})
  frames.map { |w| {w.frame_type, w.stream_id} }
end

private API = "api.example.com"

describe "H2::StreamGate body rules: the stall deadline" do
  # Review #2: a request head held for a declared length whose body stalls goes out by the
  # deadline, and the stream opened behind it goes out after it.
  it "releases a stalled request head, and the stream behind it" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "one", "ONE", host: API)
      g = GatePair.new(rules, ic, 50.milliseconds)
      g.request(1_u32, post("/first", 10, authority: API))
      g.data(g.out_gate, 1_u32, "one")
      g.request(3_u32, get("/second", API), true)
      g.up.size.should eq(0) # stream 1 waits for its body, stream 3 waits for stream 1

      sleep 150.milliseconds
      frames = g.frames(g.up)
      shape(frames).should eq([{Frame::Type::Headers, 1_u32}, {Frame::Type::Data, 1_u32}, {Frame::Type::Headers, 3_u32}])
      String.new(frames[1].payload).should eq("one") # the partial body, unmodified
      g.close
    end
  end

  # Review r2 #2: the deadline measures a STALL. A body still arriving is waited for, however
  # long it takes in total — with nothing waiting behind it, the wall never runs (#1658).
  it "waits for a request body that is slow but still arriving" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "b", host: API)
      g = GatePair.new(rules, ic, 80.milliseconds)
      g.request(1_u32, post("/slow", 6, authority: API))
      6.times do |i|
        sleep 40.milliseconds
        g.data(g.out_gate, 1_u32, "a", i == 5)
      end
      frames = g.frames(g.up)
      shape(frames).should eq([{Frame::Type::Headers, 1_u32}, {Frame::Type::Data, 1_u32}])
      String.new(frames[1].payload).should eq("bbbbbb") # rewritten: 240 ms in all, never 80 idle
      g.close
    end
  end

  # Review r2 #2: a held RESPONSE head blocks no other stream, so it has no deadline at all.
  it "waits for a response body however slowly it arrives" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "one", "ONE", host: API)
      g = GatePair.new(rules, ic, 30.milliseconds)
      g.request(1_u32, get("/x", API), true)
      g.response(1_u32, ok(6))
      g.data(g.in_gate, 1_u32, "one")
      sleep 120.milliseconds
      g.down.size.should eq(0)
      g.data(g.in_gate, 1_u32, "two", true)
      frames = g.frames(g.down)
      shape(frames).should eq([{Frame::Type::Headers, 1_u32}, {Frame::Type::Data, 1_u32}])
      String.new(frames[1].payload).should eq("ONEtwo")
      g.close
    end
  end

  # Review r2 #3: a request that finished and was rewritten, then waited behind a slower lower
  # stream, is not stalled. Stream 3 finishes at once; stream 1 keeps trickling, so if stream 3
  # still counted as held it would be the first judged late, and spilled with a false advisory.
  it "does not skip a finished request that waited behind a slower one" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "one", "ONE", host: API)
      g = GatePair.new(rules, ic, 80.milliseconds)
      g.request(1_u32, post("/slow", 10, authority: API))
      g.data(g.out_gate, 1_u32, "o")
      g.request(3_u32, post("/done", 3, authority: API))
      g.data(g.out_gate, 3_u32, "one", true)
      sleep 50.milliseconds
      g.data(g.out_gate, 1_u32, "n") # stream 1 is still arriving: its stall clock restarts
      sleep 200.milliseconds         # ...then it stalls, and goes out at the deadline
      frames = g.frames(g.up)
      shape(frames).should eq([{Frame::Type::Headers, 1_u32}, {Frame::Type::Data, 1_u32}, {Frame::Type::Data, 1_u32},
                               {Frame::Type::Headers, 3_u32}, {Frame::Type::Data, 3_u32}])
      String.new(frames[4].payload).should eq("ONE")
      done = g.sink.requests.find! { |r| r.target == "/done" }
      done.advisory.should be_nil
      g.close
    end
  end

  # #1658: a body still arriving is waited for only while nothing queues behind it. Once a later
  # open waits, the wall runs, and past it the upload goes out unmodified so the open can go.
  it "releases a slow upload by the wall clock once a later request waits behind it" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "b", host: API)
      g = GatePair.new(rules, ic, 60.milliseconds)
      g.request(1_u32, post("/slow", 8, authority: API))
      g.request(3_u32, get("/next", API), true)
      8.times do |i|
        sleep 20.milliseconds # never 60 idle: only the wall can release it
        g.data(g.out_gate, 1_u32, "a", i == 7)
      end
      frames = shape(g.frames(g.up))
      frames.index!({Frame::Type::Headers, 3_u32}).should be < frames.rindex!({Frame::Type::Data, 1_u32})
      data_of(g.frames(g.up), 1_u32).should eq("aaaaaaaa") # unmodified
      slow = g.sink.requests.find! { |r| r.target == "/slow" }
      slow.advisory.not_nil!.should contain("still arriving")
      g.close
    end
  end

  # Review of #1663: only the head first in line holds the opens behind it. One behind an
  # intercept hold moves nothing by spilling, so it keeps waiting for its body and its rewrite.
  it "runs no wall on an upload queued behind another hold" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "b", host: API)
      ic.toggle
      ic.set_filter("path:/held")
      g = GatePair.new(rules, ic, 60.milliseconds)
      g.request(1_u32, get("/held", API), true)
      ic.pending.size.should eq(1)
      g.request(3_u32, post("/slow", 8, authority: API))
      g.request(5_u32, get("/next", API), true)
      8.times do |i|
        sleep 20.milliseconds # never 60 idle; 160 ms in all, past the wall
        g.data(g.out_gate, 3_u32, "a", i == 7)
      end
      g.up.size.should eq(0) # stream 1 is still held
      ic.forward(ic.pending.first.id)
      sleep 50.milliseconds
      data_of(g.frames(g.up), 3_u32).should eq("bbbbbbbb")
      g.sink.requests.find! { |r| r.target == "/slow" }.advisory.should be_nil
      g.close
    end
  end
end

# #1658: a request head held only for a body rule, or for order behind one, keeps the client's
# own HEADERS unless something actually goes out ahead of it or it does not go out as it came.
describe "H2::StreamGate body rules: the HPACK latch" do
  it "keeps the client's HEADERS byte for byte when nothing overtook a held head" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "absent", "x", host: API)
      g = GatePair.new(rules, ic, 5.seconds, indexing: true)
      sent = [g.request(1_u32, post("/first", 3, authority: API))]
      sent << g.request(3_u32, post("/second", 3, authority: API)) # queued behind stream 1
      g.data(g.out_gate, 1_u32, "one", true)
      g.data(g.out_gate, 3_u32, "two", true)
      sent << g.request(5_u32, get("/third", API), true)
      g.frames(g.up).select(&.frame_type.==(Frame::Type::Headers)).map(&.payload).should eq(sent)
      g.out_gate.@heads.engaged?.should be_false
      g.close
    end
  end

  it "re-encodes a block that goes out ahead of a held head, and the held head still decodes" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "absent", "x", host: API)
      g = GatePair.new(rules, ic, 5.seconds, indexing: true)
      g.request(1_u32, post("/stream", authority: API)) # no length: never held, stays open
      g.request(3_u32, post("/held", 3, authority: API) + [{"x-tag", "t3"}])
      trailer = [{"x-tag", "t3"}] # indexed against stream 3's insertion
      g.request(1_u32, trailer, true)
      g.data(g.out_gate, 3_u32, "one", true)
      frames = g.frames(g.up)
      shape(frames).should eq([{Frame::Type::Headers, 1_u32}, {Frame::Type::Headers, 1_u32},
                               {Frame::Type::Headers, 3_u32}, {Frame::Type::Data, 3_u32}])
      heads_of(frames, 1_u32).last.should eq(trailer)
      heads_of(frames, 3_u32).first.should eq(post("/held", 3, authority: API) + [{"x-tag", "t3"}])
      g.close
    end
  end

  it "re-encodes a head queued behind one whose rewrite changed its length" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "one", "ONE!", host: API)
      g = GatePair.new(rules, ic, 5.seconds, indexing: true)
      g.request(1_u32, post("/grown", 3, authority: API) + [{"x-tag", "t1"}])
      second = post("/kept", 3, authority: API) + [{"x-tag", "t1"}] # indexed against stream 1's
      g.request(3_u32, second)
      g.data(g.out_gate, 3_u32, "two", true)
      g.data(g.out_gate, 1_u32, "one", true)
      frames = g.frames(g.up)
      field(heads_of(frames, 1_u32).first, "content-length").should eq("4")
      heads_of(frames, 3_u32).first.should eq(second)
      g.close
    end
  end

  it "re-encodes trailers parked behind a held head, ahead of a head queued after them" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "absent", "x", host: API)
      g = GatePair.new(rules, ic, 5.seconds, indexing: true)
      g.request(1_u32, post("/held", 3, authority: API))
      g.request(3_u32, post("/stream", authority: API)) # no length: queued for order only
      g.request(5_u32, get("/next", API) + [{"x-tag", "t5"}], true)
      trailer = [{"x-tag", "t5"}] # indexed against stream 5's insertion
      g.request(3_u32, trailer, true)
      g.data(g.out_gate, 1_u32, "one", true)
      frames = g.frames(g.up)
      shape(frames).should eq([{Frame::Type::Headers, 1_u32}, {Frame::Type::Data, 1_u32}, {Frame::Type::Headers, 3_u32},
                               {Frame::Type::Headers, 3_u32}, {Frame::Type::Headers, 5_u32}])
      heads_of(frames, 3_u32).last.should eq(trailer)
      heads_of(frames, 5_u32).first.should eq(get("/next", API) + [{"x-tag", "t5"}])
      g.close
    end
  end

  it "re-encodes a head queued behind a held head the client reset" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "absent", "x", host: API)
      g = GatePair.new(rules, ic, 5.seconds, indexing: true)
      g.request(1_u32, post("/gone", 3, authority: API) + [{"x-tag", "t1"}])
      second = post("/kept", 3, authority: API) + [{"x-tag", "t1"}] # indexed against stream 1's
      sent = g.request(3_u32, second)
      g.out_gate.accept(Frame::Header.new(Frame::Type::RstStream.value, 0_u8, 1_u32, Bytes[0, 0, 0, 8]))
      g.data(g.out_gate, 3_u32, "two", true)
      frames = g.frames(g.up)
      shape(frames).should eq([{Frame::Type::Headers, 3_u32}, {Frame::Type::Data, 3_u32}])
      frames.first.payload.should_not eq(sent)
      heads_of(frames, 3_u32).first.should eq(second)
      g.close
    end
  end
end

# Every header block in `frames` for `stream`, decoded in wire order (one HPACK context).
private def heads_of(frames : Array(Frame::Header), stream : UInt32) : Array(Array({String, String}))
  dec = HPACK::Decoder.new
  frames.select(&.frame_type.==(Frame::Type::Headers)).compact_map do |f|
    fields = dec.decode(f.payload)
    f.stream_id == stream ? fields : nil
  end
end

private def data_of(frames : Array(Frame::Header), stream : UInt32) : String
  String.build { |io| frames.each { |f| io.write(f.payload) if f.frame_type == Frame::Type::Data && f.stream_id == stream } }
end

# h1 rewrites a held body before the operator sees it (`ClientConn#handle_held_request`).
describe "H2::StreamGate body rules: an intercept hold" do
  it "shows and forwards the rule's rewrite of a held request body" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "hunter2", "x", host: API)
      ic.toggle
      g = GatePair.new(rules, ic, 5.seconds)
      g.request(1_u32, post("/login", 16, authority: API))
      g.data(g.out_gate, 1_u32, "password=hunter2", true)
      item = ic.pending.first
      String.new(item.raw).should contain("content-length: 10")
      String.new(item.raw).should end_with("password=x")
      ic.forward(item.id)
      sleep 50.milliseconds

      frames = g.frames(g.up)
      field(heads_of(frames, 1_u32).first, "content-length").should eq("10")
      data_of(frames, 1_u32).should eq("password=x")
      captured = g.sink.requests.first
      String.new(captured.body.not_nil!).should eq("password=x")
      captured.rewrite.not_nil!.hits.size.should eq(1)
      captured.intercept_original.should be_nil
      g.close
    end
  end

  it "keeps the client's own request beside an edit of the rewrite" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "hunter2", "x", host: API)
      ic.toggle
      g = GatePair.new(rules, ic, 5.seconds)
      g.request(1_u32, post("/login", 16, authority: API))
      g.data(g.out_gate, 1_u32, "password=hunter2", true)
      item = ic.pending.first
      ic.forward(item.id, String.new(item.raw).sub("password=x", "password=y").to_slice)
      sleep 50.milliseconds

      data_of(g.frames(g.up), 1_u32).should eq("password=y")
      original = String.new(g.sink.requests.first.intercept_original.not_nil!)
      original.should contain("content-length: 16")
      original.should end_with("password=hunter2")
      g.close
    end
  end

  # A held response's receiver window is known only as far as its sender was granted it.
  it "does not grow a held response past what its sender was allowed" do
    with_rules do |rules, ic|
      rules.add(RESP, BODY, "a", "aaaa", host: API)
      ic.toggle
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      g = GatePair.new(rules, ic, 5.seconds)
      g.request(1_u32, get("/x", API), true)
      g.response(1_u32, ok(3))
      g.data(g.in_gate, 1_u32, "aaa", true)
      ic.forward(ic.pending.first.id)
      sleep 50.milliseconds

      data_of(g.frames(g.down), 1_u32).should eq("aaa")
      g.sink.responses.first.advisory.not_nil!.should contain("held at intercept")
      g.close
    end
  end
end

# `Relay#gates` is private; a thin caller (test binary only) lets the spec read the gates it
# builds for one connection.
class Gori::Proxy::H2::Relay
  def spec_gates : {Gori::Proxy::H2::StreamGate?, Gori::Proxy::H2::StreamGate?}
    gates(1_i64, Gori::Proxy::H2::Assembler.new(@sink, @host, @port))
  end
end

describe "H2::Relay body-rule path" do
  # A connection no body rule matches pays nothing for the path (P6): no flow-control state, so
  # every frame takes each gate's plain branch.
  it "builds flow-control state only for a host a body rule matches" do
    with_rules do |rules, ic|
      rules.add(REQ, BODY, "a", "b", host: "alpha.test")
      [{"127.0.0.1", false}, {"alpha.test", true}].each do |(host, built)|
        relay = Gori::Proxy::H2::Relay.new(IO::Memory.new, IO::Memory.new, host, 443, BodySink.new,
          rewriter: rules, interceptor: ic)
        relay.spec_gates.each { |gate| gate.not_nil!.@flow.nil?.should eq(!built) }
      end
    end
  end
end
