require "../spec_helper"

private alias Q = Gori::Sequencer
private alias F = Gori::Fuzz

# A backend that issues an incrementing session cookie each send (a sequential-token
# server) so a collection over it is both extractable and detectably weak.
private class CounterCookieBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @start : Int32 = 1000)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    n = @start + @sent
    @sent += 1
    head = "HTTP/1.1 200 OK\r\nSet-Cookie: SID=#{n}; Path=/\r\nContent-Length: 2\r\n\r\n"
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
    Gori::Repeater::Result.new(head.to_slice, "ok".to_slice, resp, 500_i64)
  end
end

private def drain(engine : Q::Engine) : Array(Q::Sample)
  samples = [] of Q::Sample
  engine.run { |ev| samples << ev.sample if ev.is_a?(Q::SampleEvent) }
  samples
end

describe Gori::Sequencer::Engine do
  it "collects the goal count of tokens in live-replay mode" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::LiveReplay,
      token_loc: Q::TokenLoc.cookie("SID"), goal: 25, concurrency: 1, retries: 0)
    req = "GET /login HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    samples = drain(Q::Engine.new(req, http2: false, backend: backend, config: config))

    # The goal is counted by successful extractions; the pipeline may overshoot by up
    # to `concurrency` (the dispatcher races one job ahead of the collected counter).
    samples.size.should be >= 25
    samples.size.should be <= 25 + config.concurrency
    samples.all? { |s| s.token }.should be_true
    Q::Stats.analyze(samples.compact_map(&.token)).sequential.should be_true
  end

  it "terminates via the max-sends cap when the descriptor never matches" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::LiveReplay,
      token_loc: Q::TokenLoc.cookie("NOPE"), goal: 100, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    samples = drain(Q::Engine.new(req, http2: false, backend: backend, config: config))

    samples.none?(&.token).should be_true
    backend.sent.should be <= config.max_sends # goal never met → stops at the cap (goal*2)
  end

  it "emits pasted tokens in manual mode without touching the network" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["aa", "bb", "", "cc"])
    samples = drain(Q::Engine.new(Bytes.empty, http2: false, backend: backend, config: config))

    samples.map(&.token).should eq(["aa", "bb", "cc"])
    backend.sent.should eq(0)
  end

  it "reports a Done event with collected/sent counts" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 10, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    done = nil.as(Q::DoneEvent?)
    Q::Engine.new(req, http2: false, backend: backend, config: config).run do |ev|
      done = ev if ev.is_a?(Q::DoneEvent)
    end
    done.not_nil!.collected.should be >= 10 # ≥ goal (may overshoot by ≤ concurrency)
  end
end
