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

# Extracts a token on some sends and MISSES on the rest — the shape neither
# `CounterCookieBackend` (never misses) nor a wrong descriptor (always misses) can produce,
# and the only one that exercises the dispatcher's projection SHRINKING again after it has
# already reached the goal. `latency` is a real `sleep`, i.e. a fiber yield point, for the
# reason CounterCookieBackend carries one.
private class HalfMissBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @hit_every : Int32 = 2, @latency : Time::Span = 1.millisecond)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    sleep @latency
    n = @sent
    @sent += 1
    head = if n % @hit_every == 0
             "HTTP/1.1 200 OK\r\nSet-Cookie: SID=#{1000 + n}; Path=/\r\nContent-Length: 2\r\n\r\n"
           else
             "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n"
           end
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
    Gori::Repeater::Result.new(head.to_slice, "ok".to_slice, resp, 500_i64)
  end
end

# An origin that DELETES the session on every reply: `Set-Cookie: SID=` with no value is
# what a logout / stale-session response carries, and it is a real `Set-Cookie` for the
# named cookie — so the descriptor MATCHES and hands back "".
private class EmptyCookieBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    head = "HTTP/1.1 200 OK\r\nSet-Cookie: SID=; Max-Age=0; Path=/\r\nContent-Length: 2\r\n\r\n"
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
    Gori::Repeater::Result.new(head.to_slice, "ok".to_slice, resp, 500_i64)
  end
end

# Fails every send with a TRANSIENT error, so `send_with_retries` runs its full chain.
private class RefusedBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
  end
end

private def collect_done(engine : Q::Engine) : Q::DoneEvent
  done = nil.as(Q::DoneEvent?)
  engine.run { |ev| done = ev if ev.is_a?(Q::DoneEvent) }
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

  # A miss LOWERS the dispatcher's optimistic projection again, and the loop used to have
  # broken out of itself by then: the run ended below its goal with the `max_sends` budget
  # barely touched, and the shortfall grew with concurrency (19/20 at 1, 35/40 at 5). It now
  # HOLDS on the projection and tops up instead — landing exactly on the goal, still with no
  # overshoot, and still bounded by `max_sends` for a descriptor that never matches.
  it "tops up a late extraction miss instead of ending below the goal" do
    backend = HalfMissBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 20, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    d = collect_done(Q::Engine.new(req, http2: false, backend: backend, config: config))
    d.collected.should eq(20)
    d.requests.should be <= config.max_sends
  end

  it "tops up late extraction misses at concurrency > 1 too" do
    backend = HalfMissBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 40, concurrency: 5, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    d = collect_done(Q::Engine.new(req, http2: false, backend: backend, config: config))
    d.collected.should eq(40)
    d.requests.should be <= config.max_sends
  end

  # A retry is a NEW request, so a stop mid-chain used to keep aiming `retries` more of them
  # at the target and hold the run open for `retries * retry_pause` per worker — up to 1000
  # requests and ~8 minutes on MCP's ceilings, after `sequence_stop` had already answered.
  it "ends the retry chain on stop instead of sending the rest of it" do
    backend = RefusedBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 5, concurrency: 1,
      retries: 20, retry_pause: 20.milliseconds)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = Q::Engine.new(req, http2: false, backend: backend, config: config)
    at_stop = 0
    spawn do
      sleep 60.milliseconds
      at_stop = backend.sent
      engine.stop
    end
    d = collect_done(engine)
    at_stop.should be > 0 # guard: the stop landed mid-chain, not before the first send
    d.stopped.should be_true
    # The in-flight request may still be counted; the remaining ~17 retries may not.
    (backend.sent - at_stop).should be <= 1
  end

  # `""` is truthy in Crystal, so an empty extraction counted toward the goal and carried no
  # error — while `Stats.analyze` drops empty tokens. A collection against an origin that
  # DELETES the session cookie reported "5 collected" over a report reading "0 usable / 5
  # total · CRITICAL (no usable tokens)". Manual mode has always skipped an empty token.
  it "treats an empty extraction as a miss, not a collected token" do
    backend = EmptyCookieBackend.new(F::Origin.new("http", "h", 80))
    config = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"), goal: 5, concurrency: 1, retries: 0)
    req = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = Q::Engine.new(req, http2: false, backend: backend, config: config)
    samples = drain(engine)
    samples.none?(&.token).should be_true
    samples.all? { |s| s.error == "no token matched" }.should be_true
    # The goal is never met, so the run ends on the max-sends guard rather than reporting
    # a full collection of unusable tokens.
    backend.sent.should eq(config.max_sends)
    engine.first_error.should be_nil
  end
end
