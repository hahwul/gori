require "../spec_helper"
require "socket"

private alias F = Gori::Fuzz
private alias Q = Gori::Sequencer

# A keep-alive origin that answers every request on whatever socket it arrives on and counts
# how many CONNECTIONS it ever accepted. That count is the whole point of this file: it is the
# number of TCP (and, on https, TLS) handshakes the caller paid, it is exact, and it needs no
# timing — which is what makes it a gate rather than a benchmark. `bench/proxy_bench.cr` has
# ±40% run-to-run noise, so a wall-clock assertion here would be unfalsifiable.
private class CountingOrigin
  getter port : Int32
  getter connections : Int32 = 0
  getter requests : Int32 = 0
  # Incremented when a served connection's read loop ends, i.e. when the CLIENT hung up.
  # Spec-local on purpose: proving the pool released its socket needs no production API.
  getter closed : Int32 = 0

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
    n = 0
    loop do
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      break unless head
      req = Gori::Proxy::Codec::Http1.parse_request_head(head)
      if (cl = req.headers.get?("Content-Length")) && (len = cl.to_i?) && len > 0
        buf = Bytes.new(len)
        conn.read_fully?(buf)
      end
      @requests += 1
      n += 1
      # A fresh incrementing token per request, so the Sequencer has something to extract
      # and the run reaches its goal instead of stopping on repeated misses.
      body = "ok"
      conn << "HTTP/1.1 200 OK\r\nSet-Cookie: SID=#{1000 + @requests}; Path=/\r\n"
      conn << "Content-Length: #{body.bytesize}\r\n\r\n" << body
      conn.flush
    end
    @closed += 1
    conn.close rescue nil
  end
end

# Poll rather than block: the origin's read loop notices the hang-up on its own fiber, and
# spec_helper's note on PR #555 is explicit that a bare blocking wait on socket-driven work
# is how CI hangs for 24 minutes with no output.
private def eventually(timeout : Time::Span = 3.seconds, &) : Bool
  deadline = Time.instant + timeout
  until Time.instant > deadline
    return true if yield
    sleep 10.milliseconds
  end
  false
end

private def with_origin(&)
  origin = CountingOrigin.new
  begin
    yield origin
  ensure
    origin.close
  end
end

# Regression coverage for the callers that had a keep-alive pool available and never asked
# for it. The comment on `Fuzz::Sender#initialize` filed them under "one-shot senders [that]
# have nothing to amortise"; none of them is one-shot, and every caller believed the comment.
describe "keep-alive across the non-sweep senders" do
  # Driven through `Plan.build`, not a hand-built Sender: the bug was never in the pool, it
  # was that this builder never asked for one. Assembling the sender here would pin the pool
  # and leave the actual defect free to come back.
  it "collects a whole Sequencer run over ONE connection instead of one per sample" do
    with_origin do |origin|
      config = Q::Config.new(mode: Q::Mode::LiveReplay,
        token_loc: Q::TokenLoc.cookie("SID"), goal: 25, concurrency: 1)
      config.retries = 0
      config.timeout = 5.seconds
      plan = Q::Plan.build(Q::PlanOptions.new(
        "GET /login HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        target: "http://127.0.0.1:#{origin.port}", config: config, verify: false),
        ungated_outbound)

      samples = [] of Q::Sample
      plan.engine.run { |ev| samples << ev.sample if ev.is_a?(Q::SampleEvent) }

      samples.size.should eq(25) # the run really happened
      origin.requests.should eq(25)
      # The headline: 25 samples used to be 25 handshakes. At the shipped default of
      # `--count 500` that was 500 sequential TCP+TLS handshakes to collect 500 tokens.
      origin.connections.should eq(1)

      # `Engine#orchestrate`'s ensure closes the backend. Without it the pool keeps the
      # socket parked for the life of the process — a leaked fd per run, which is what a
      # caller buys by turning keep-alive on without owning the close.
      eventually { origin.closed == 1 }.should be_true
    end
  end

  it "leaves keep-alive off for h2, which frames its own connection" do
    sender = F::Sender.new(
      F::Origin.new("https", "127.0.0.1", 1), ungated_outbound,
      http2: true, verify: false, keep_alive: true, idle_conns: 4)
    sender.pool.should be_nil
  end
end

describe "the Sequencer's keep-alive escape hatch" do
  # The Sequencer's output is a statistical claim about how an origin GENERATES tokens, so
  # the transport is not neutral: an origin whose session issuance is connection-bound would
  # have its verdict shaped by socket reuse. `--no-keep-alive` lets the operator re-take the
  # sample over fresh connections and compare, the way `gori run fuzz`/`mine`/`discover`
  # already allow. On by default — the 500-handshake case above is the normal one.
  it "dials per sample when keep_alive is off" do
    with_origin do |origin|
      config = Q::Config.new(mode: Q::Mode::LiveReplay,
        token_loc: Q::TokenLoc.cookie("SID"), goal: 5, concurrency: 1)
      config.retries = 0
      config.timeout = 5.seconds
      config.keep_alive = false
      plan = Q::Plan.build(Q::PlanOptions.new(
        "GET /login HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        target: "http://127.0.0.1:#{origin.port}", config: config, verify: false),
        ungated_outbound)
      plan.engine.run { }

      origin.requests.should eq(5)
      origin.connections.should eq(5) # one dial per sample, which is the whole point
    end
  end

  it "is on by default" do
    Q::Config.new.keep_alive?.should be_true
  end
end
