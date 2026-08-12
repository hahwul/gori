require "../spec_helper"
require "socket"

private alias D = Gori::Discover

# An origin that answers every request on the SAME socket and counts how many connections it
# ever accepted, plus the first request head it saw (so a spec can assert the bytes Discover
# actually wrote, not just the connection arithmetic). Modelled on the fuzz pool's helper —
# a shared support class would have to serve both, and the two want different accessors.
private class KeepAliveOrigin
  getter port : Int32
  getter connections : Int32 = 0
  getter requests : Int32 = 0
  getter first_head : String = ""

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      spawn { serve(conn) }
    end
  rescue
    # server closed
  end

  private def serve(conn : TCPSocket) : Nil
    loop do
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      break unless head
      @first_head = String.new(head) if @first_head.empty?
      @requests += 1
      body = "pong"
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
      conn.flush
    end
  rescue
    # The client closing a parked socket while this fiber sits in read_head is the NORMAL end
    # of a pooled connection (Sender#close does exactly that), not a failure to report.
  ensure
    conn.close rescue nil
  end
end

private def sender(keep_alive : Bool, idle : Int32 = 4) : D::Sender
  D::Sender.new(verify: false, timeout: 2.seconds, keep_alive: keep_alive, idle_conns: idle)
end

describe "Discover keep-alive" do
  # The whole point of the change: a brute-force pass is ~278 sends PER DIRECTORY, and every
  # one of them used to pay a TCP (and on https a TLS) handshake.
  it "serves many probes off ONE connection instead of dialing per probe" do
    origin = KeepAliveOrigin.new
    s = sender(true)
    10.times { |i| s.fetch("http", "127.0.0.1", origin.port, "/probe#{i}").error.should be_nil }
    origin.requests.should eq(10)
    origin.connections.should eq(1)
    stats = s.pool_stats.not_nil!
    stats.dialed.should eq(1)
    stats.reused.should eq(9)
    s.close
    origin.close
  end

  # The control: without it the example above would pass against an origin that simply
  # tolerates whatever gori sends.
  it "still dials once per probe with keep-alive off" do
    origin = KeepAliveOrigin.new
    s = sender(false)
    5.times { |i| s.fetch("http", "127.0.0.1", origin.port, "/probe#{i}") }
    origin.requests.should eq(5)
    origin.connections.should eq(5)
    s.pool_stats.should be_nil
    s.close
    origin.close
  end

  # `Connection: close` is what made every send single-use, and `ConnPool.reusable_request?`
  # refuses to park a socket that carried it — so leaving it in would make keep-alive a
  # silent no-op that still looks enabled. Assert the header on the wire, not the counters.
  it "omits Connection: close when pooling and keeps it when not" do
    pooled = KeepAliveOrigin.new
    s = sender(true)
    s.fetch("http", "127.0.0.1", pooled.port, "/a")
    pooled.first_head.downcase.should_not contain("connection: close")
    pooled.first_head.should contain("User-Agent: gori-discover")
    s.close
    pooled.close

    plain = KeepAliveOrigin.new
    ns = sender(false)
    ns.fetch("http", "127.0.0.1", plain.port, "/a")
    plain.first_head.should contain("Connection: close\r\n")
    ns.close
    plain.close
  end

  # A crawl derives URLs on several in-scope hosts, so the pool is per ORIGIN — but each one
  # parks up to `idle_conns` sockets, so the MAP is capped (an fd bound). Past the cap the
  # least-recently-used pool is EVICTED, not refused: the cap used to mean the fifth origin
  # got no pool AND every origin after it dialled per send for the rest of the run, silently.
  # Same host, distinct ports = distinct origins.
  it "evicts the least-recently-used pool past MAX_POOLS instead of giving up on keep-alive" do
    origins = Array.new(D::Sender::MAX_POOLS + 1) { KeepAliveOrigin.new }
    s = sender(true)
    origins.each do |o|
      2.times { s.fetch("http", "127.0.0.1", o.port, "/a") }
    end
    # EVERY origin reused its socket, including the one past the cap — the fifth evicts the
    # first, which by then is done with. Under the old rule this origin dialled twice.
    origins.each(&.connections.should(eq(1)))
    s.pool_stats.not_nil!.reused.should eq((D::Sender::MAX_POOLS + 1).to_i64)
    s.close
    origins.each(&.close)
  end

  # The fd bound is the POINT of the cap, so eviction has to close what it drops rather than
  # just forgetting the map entry — otherwise a crawl over many origins leaks a socket per
  # evicted pool and the cap stops meaning anything.
  it "closes the evicted pool's parked sockets" do
    origins = Array.new(D::Sender::MAX_POOLS + 1) { KeepAliveOrigin.new }
    s = sender(true)
    origins.each { |o| 2.times { s.fetch("http", "127.0.0.1", o.port, "/a") } }
    # origins[0] was evicted when origins.last arrived. Its socket is gone, so coming back to
    # it dials afresh rather than handing back a socket nobody is holding open.
    before = origins[0].connections
    s.fetch("http", "127.0.0.1", origins[0].port, "/again")
    origins[0].connections.should eq(before + 1)
    s.close
    origins.each(&.close)
  end

  it "releases every parked socket when the run's engine finishes" do
    origin = KeepAliveOrigin.new
    s = sender(true)
    # No spider, no bruteforce candidates that resolve — the seed fetch alone is enough to
    # make the engine open (and then have to close) a pooled connection.
    cfg = D::Config.new(concurrency: 2, spider: true, bruteforce: false, max_depth: 0,
      containment: D::Containment::SameOrigin, retries: 0, keep_alive: true)
    engine = D::Engine.new("http://127.0.0.1:#{origin.port}/", [] of String, s, cfg)
    engine.run { |_| }
    # `close_all` drained the idle list, so a further send has to dial again rather than
    # hand back a socket the engine already released.
    before = origin.connections
    s.fetch("http", "127.0.0.1", origin.port, "/after")
    origin.connections.should eq(before + 1)
    s.close
    origin.close
  end

  # `Plan.build` is the ONE place a Discover::Sender is constructed on every surface, so a
  # Config knob that never reached it would be a silent no-op on all three at once.
  it "is on by default and reaches the wire through the plan builder" do
    D::Config.new.keep_alive?.should be_true

    {true => 1, false => 3}.each do |keep_alive, expected_connections|
      origin = KeepAliveOrigin.new
      # `max_requests` bounds the run at 3 real sends (CappedBackend refuses the rest without
      # touching the network), so the connection count is the only thing that varies here.
      cfg = D::Config.new(concurrency: 1, spider: false, bruteforce: true, retries: 0,
        max_depth: 0, containment: D::Containment::SameOrigin, keep_alive: keep_alive,
        max_requests: 3_i64)
      plan = D::Plan.build(
        D::PlanOptions.new("http://127.0.0.1:#{origin.port}/", config: cfg, verify: false),
        ungated_outbound)
      plan.engine.run { |_| }
      origin.requests.should eq(3)
      origin.connections.should eq(expected_connections)
      origin.close
    end
  end
end
