require "../spec_helper"

private alias Q = Gori::Sequencer
private alias F = Gori::Fuzz

# A backend that issues an incrementing session cookie each send (a sequential-token
# server) so a collection over it is both extractable and detectably weak. `latency`
# simulates real network round-trip time with a `sleep` — a fiber yield point that lets
# the dispatcher fiber race ahead of completions, exactly like a real socket read would.
# A near-instantaneous fake backend (the old default here) never yields between dispatch
# and completion often enough to expose that race, which is why this spec didn't catch
# the live-collection overshoot bug (see engine.cr's dispatch loop comment).
private class CounterCookieBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @start : Int32 = 1000, @latency : Time::Span = 2.milliseconds)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    sleep @latency
    n = @start + @sent
    @sent += 1
    head = "HTTP/1.1 200 OK\r\nSet-Cookie: SID=#{n}; Path=/\r\nContent-Length: 2\r\n\r\n"
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
    Gori::Repeater::Result.new(head.to_slice, "ok".to_slice, resp, 500_i64)
  end
end

private class BlockedBackend < F::Backend
  getter origin : F::Origin

  def initialize(@origin : F::Origin, @reason : String)
  end

  # The shape Outbound-gated senders return: no head, no response, the reason in `error`.
  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, @reason)
  end
end

private def run_blocked(reason : String) : Q::DoneEvent
  backend = BlockedBackend.new(F::Origin.new("http", "h", 80), reason)
  config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 2, concurrency: 1,
    retries: 2, retry_pause: 1.millisecond)
  req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  done = nil.as(Q::DoneEvent?)
  Q::Engine.new(req, http2: false, backend: backend, config: config).run do |ev|
    done = ev if ev.is_a?(Q::DoneEvent)
  end
  done.not_nil!
end

private def drain(engine : Q::Engine) : Array(Q::Sample)
  samples = [] of Q::Sample
  engine.run { |ev| samples << ev.sample if ev.is_a?(Q::SampleEvent) }
  samples
end

describe Gori::Sequencer::Engine do
  it "collects exactly the goal count of tokens in live-replay mode, no overshoot" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::LiveReplay,
      token_loc: Q::TokenLoc.cookie("SID"), goal: 25, concurrency: 1, retries: 0)
    req = "GET /login HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    samples = drain(Q::Engine.new(req, http2: false, backend: backend, config: config))

    # The dispatch loop stops handing out jobs once enough are already IN FLIGHT to
    # reach the goal (not only once they've fully round-tripped), so — with a backend
    # that never misses extraction — the count lands EXACTLY on the goal. This backend
    # has non-zero `latency` (a real `sleep`, i.e. a fiber yield point) specifically so
    # this spec exercises the same dispatcher/worker race that only manifested against
    # real network latency; a near-instant fake backend does not reliably yield between
    # dispatch and completion and would let a regression here slip back in unnoticed.
    samples.size.should eq(25)
    samples.all? { |s| s.token }.should be_true
    Q::Stats.analyze(samples.compact_map(&.token)).sequential.should be_true
  end

  it "collects exactly the goal count at concurrency > 1, no overshoot" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::LiveReplay,
      token_loc: Q::TokenLoc.cookie("SID"), goal: 40, concurrency: 5, retries: 0)
    req = "GET /login HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    samples = drain(Q::Engine.new(req, http2: false, backend: backend, config: config))

    samples.size.should eq(40)
    samples.all? { |s| s.token }.should be_true
  end

  it "terminates via the max-sends cap when the descriptor never matches" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::LiveReplay,
      token_loc: Q::TokenLoc.cookie("NOPE"), goal: 100, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    samples = drain(Q::Engine.new(req, http2: false, backend: backend, config: config))

    samples.none?(&.token).should be_true
    backend.sent.should eq(config.max_sends) # goal never met → stops exactly at the cap (goal*2)
  end

  it "emits pasted tokens in manual mode without touching the network" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["aa", "bb", "", "cc"])
    samples = drain(Q::Engine.new(Bytes.empty, http2: false, backend: backend, config: config))

    samples.map(&.token).should eq(["aa", "bb", "cc"])
    backend.sent.should eq(0)
  end

  it "runs manual mode with NO backend at all (an analyse-only engine has no sender)" do
    # Manual mode sends nothing, so it takes no send seam — the TUI used to hand it a
    # throwaway Sender pointed at http://localhost:80 purely to satisfy this constructor.
    config = Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["aa", "bb"])
    samples = drain(Q::Engine.new(Bytes.empty, http2: false, backend: nil, config: config))
    samples.map(&.token).should eq(["aa", "bb"])
  end

  it "refuses a live-replay engine with no backend at construction" do
    # The other half of the nilable backend: rejected here rather than discovered inside a
    # worker fiber, which is what makes manual mode's nil safe everywhere else.
    config = Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: Q::TokenLoc.cookie("SID"), goal: 1)
    expect_raises(ArgumentError, "live replay needs a send backend") do
      Q::Engine.new("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, http2: false, backend: nil, config: config)
    end
  end

  it "reports a Done event with collected/sent counts" do
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 10, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    done = nil.as(Q::DoneEvent?)
    Q::Engine.new(req, http2: false, backend: backend, config: config).run do |ev|
      done = ev if ev.is_a?(Q::DoneEvent)
    end
    done.not_nil!.collected.should eq(10) # lands exactly on the goal, no overshoot
    # …and with no retries, the two send counters agree.
    done.not_nil!.sent.should eq(10)
    done.not_nil!.requests.should eq(10_i64)
  end

  # `sent` counts REPLAYS — the numerator against `goal` — and a retry costs none of it. So a
  # collection against a dead origin with `--retries 2` reported "6 sent" for 18 real
  # requests: a 3x understatement of the load gori put on the target, and `sent` is the number
  # that matters to a tester working inside an agreed request budget on a client's production
  # system. `Fuzz::CappedBackend#sent` was already the true count, already what `max_requests`
  # is enforced against, and already published by miner and discover as their own `sent`.
  it "publishes the TRUE wire count separately from the replay count under --retries" do
    backend = BlockedBackend.new(F::Origin.new("http", "h", 80), "no response from h:80")
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 2, concurrency: 1, retries: 2)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    done = nil.as(Q::DoneEvent?)
    Q::Engine.new(req, http2: false, backend: backend, config: config).run do |ev|
      done = ev if ev.is_a?(Q::DoneEvent)
    end
    d = done.not_nil!
    d.requests.should eq((d.sent * 3).to_i64) # 1 attempt + 2 retries per replay
    d.requests.should be > d.sent.to_i64
  end

  # …but the retry only makes sense for a transient error. A sandbox or exclude refusal is
  # Layer 2 saying no before a socket is ever opened, so the second and third attempt cannot
  # come out differently — they only triple the load gori aims at a target the operator has
  # already put off limits. Both refusals used to be retried like any other error string.
  it "does not retry a sandbox refusal" do
    d = run_blocked(Gori::Outbound::SANDBOX_SWEEP_ERROR)
    d.sent.should be > 0 # guard: without this, `requests == sent` passes vacuously as 0 == 0
    d.requests.should eq(d.sent.to_i64)
  end

  it "does not retry a scope-exclude refusal" do
    d = run_blocked(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
    d.sent.should be > 0
    d.requests.should eq(d.sent.to_i64)
  end

  # A run that collects nothing because every replay was REFUSED is a failure, not a clean
  # "0 collected" — the reason used to be counted into @errors and the string discarded, so
  # `gori run sequence` printed "0 collected" and exited 0.
  it "retains the first refusal reason of a wholly-blocked run" do
    backend = BlockedBackend.new(F::Origin.new("http", "h", 80), "blocked by a scope exclude rule")
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 5, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = Q::Engine.new(req, http2: false, backend: backend, config: config)
    engine.run { }
    engine.first_error.should eq("blocked by a scope exclude rule")
    engine.errors.should be > 0
  end

  it "leaves first_error nil when replays succeed but no token matches" do
    # The control case the CLI backstop depends on: "responded, but the descriptor found
    # nothing" is a real verdict and must NOT be reported as a failed run.
    backend = CounterCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("NOPE"), goal: 3, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = Q::Engine.new(req, http2: false, backend: backend, config: config)
    engine.run { }
    engine.first_error.should be_nil
  end
end
