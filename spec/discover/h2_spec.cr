require "../spec_helper"
require "socket"

private alias D = Gori::Discover
private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# A cleartext-h2 origin that serves any number of requests per connection, counts the
# connections it accepted and keeps every request's DECODED header list — so an example can
# assert the fields Discover put on the h2 wire, not only the connection arithmetic. The same
# shape as spec/fuzz/h2_pool_spec.cr's origin, which wants different accessors.
private class H2DiscoverOrigin
  getter port : Int32
  getter connections = 0
  getter requests = 0
  getter fields = [] of Array({String, String})

  @server : TCPServer

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close rescue nil
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      spawn serve(conn)
    end
  rescue
    # server closed
  end

  private def serve(conn : TCPSocket) : Nil
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    enc = HPACK::Encoder.new
    dec = HPACK::Decoder.new
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        next unless f.end_headers?
        @fields << dec.decode(f.payload)
        respond(conn, enc, f.stream_id) if f.end_stream?
      when Frame::Type::Goaway
        break
      else
        # SETTINGS / WINDOW_UPDATE / PING from the client — nothing to do here.
      end
    end
  rescue
    # The client closing a parked connection is the normal end of a pooled one.
  ensure
    conn.close rescue nil
  end

  private def respond(conn : TCPSocket, enc : HPACK::Encoder, id : UInt32) : Nil
    @requests += 1
    block = enc.encode([{":status", "200"}, {"content-type", "text/plain"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, id, block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, id, "pong".to_slice).to_bytes)
    conn.flush
  end
end

private def h2_sender(keep_alive : Bool) : D::Sender
  D::Sender.new(verify: false, timeout: 5.seconds, http2: true, keep_alive: keep_alive, idle_conns: 4)
end

describe "Discover over HTTP/2" do
  # `Connection` is a connection-specific field: RFC 9113 §8.2.2 says a request carrying one is
  # MALFORMED, and `H2Engine` passes it through untouched (right for operator bytes). Discover's
  # requests are gori's own, so the h1 `Connection: close` must never be written under h2 —
  # with keep-alive on or off.
  it "writes no connection field on the h2 wire" do
    [true, false].each do |keep_alive|
      origin = H2DiscoverOrigin.new
      s = h2_sender(keep_alive)
      s.fetch("http", "127.0.0.1", origin.port, "/a").error.should be_nil
      origin.fields.size.should eq(1)
      names = origin.fields[0].map(&.[0])
      names.should_not contain("connection")
      names.should contain(":path")
      String.new(s.request_head("http", "127.0.0.1", origin.port, "/a")).downcase.should_not contain("connection:")
      s.close
      origin.close
    end
  end

  # The same handshake win `Fuzz::Sender` has had since #881: `H2Pool` carries the probes
  # serially over one connection instead of paying a dial — on https a TLS handshake, and an
  # h2 preface round — per probe.
  it "serves many probes off ONE h2 connection with keep-alive on" do
    origin = H2DiscoverOrigin.new
    s = h2_sender(true)
    10.times { |i| s.fetch("http", "127.0.0.1", origin.port, "/probe#{i}").error.should be_nil }
    origin.requests.should eq(10)
    origin.connections.should eq(1)
    stats = s.pool_stats.not_nil!
    stats.dialed.should eq(1)
    stats.reused.should eq(9)
    s.close
    origin.close
  end

  it "still dials once per probe with keep-alive off" do
    origin = H2DiscoverOrigin.new
    s = h2_sender(false)
    5.times { |i| s.fetch("http", "127.0.0.1", origin.port, "/probe#{i}").error.should be_nil }
    origin.connections.should eq(5)
    s.pool_stats.should be_nil
    s.close
    origin.close
  end

  # The fd bound holds for h2 pools exactly as for h1 ones: past MAX_POOLS an origin dials per
  # send, and `pool_stats` sums every pool whichever protocol it carries.
  it "pools per origin and falls back to dial-per-send past MAX_POOLS" do
    origins = Array.new(D::Sender::MAX_POOLS + 1) { H2DiscoverOrigin.new }
    s = h2_sender(true)
    origins.each do |o|
      2.times { s.fetch("http", "127.0.0.1", o.port, "/a").error.should be_nil }
    end
    origins[0, D::Sender::MAX_POOLS].each(&.connections.should(eq(1)))
    origins.last.connections.should eq(2)
    s.pool_stats.not_nil!.reused.should eq(D::Sender::MAX_POOLS.to_i64)
    s.close
    origins.each(&.close)
  end

  # Through `Plan.build`, the one constructor every surface uses — so `--http2` with the
  # default keep-alive reaches the wire on all three, and a finished run releases the pool.
  it "reaches the wire through the plan builder, and the finished run releases the pool" do
    {true => 1, false => 3}.each do |keep_alive, expected_connections|
      origin = H2DiscoverOrigin.new
      cfg = D::Config.new(concurrency: 1, spider: false, bruteforce: true, retries: 0,
        max_depth: 0, containment: D::Containment::SameOrigin, keep_alive: keep_alive,
        max_requests: 3_i64)
      plan = D::Plan.build(
        D::PlanOptions.new("http://127.0.0.1:#{origin.port}/", config: cfg, verify: false, http2: true),
        ungated_outbound)
      plan.engine.run { |_| }
      origin.requests.should eq(3)
      origin.connections.should eq(expected_connections)
      # `close_all` drained the idle list when the engine finished, so a further send dials.
      before = origin.connections
      plan.sender.fetch("http", "127.0.0.1", origin.port, "/after")
      origin.connections.should eq(before + 1)
      plan.sender.close
      origin.close
    end
  end
end
