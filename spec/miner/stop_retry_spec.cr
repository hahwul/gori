require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# A backend that answers OK for `ok_sends` and then errors forever, stopping the engine on
# the first error and counting every send that arrives after the stop. A retry is a NEW
# request, so that count is what a `mine_stop` / ^X costs the target.
private class StopRetryBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0
  getter after_stop : Int32 = 0
  property engine : M::Engine?

  def initialize(@origin : F::Origin, @ok_sends : Int32)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    send(bytes, nil)
  end

  def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    @sent += 1
    @after_stop += 1 if @engine.try(&.stopped?)
    return ok if @sent <= @ok_sends
    @engine.try(&.stop)
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
  end

  private def ok : Gori::Repeater::Result
    body = "BASELINE BODY CONTENT"
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end
end

# Errors on every send, and counts them.
private class DeadBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
  end
end

private RAW = "GET /s?q=hi HTTP/1.1\r\nHost: t.test\r\n\r\n"

describe "a stop ends the miner's retry chain" do
  it "puts nothing more on the wire once the engine is stopped" do
    cfg = M::Config.new(locations: [M::Location::Query], concurrency: 1,
      stability_rounds: 1, confirm_rounds: 1, retries: 5, retry_pause: 1.millisecond)
    plan = M::Plan.build(M::PlanOptions.new(RAW, target: "http://t.test:80", config: cfg),
      ungated_outbound)
    backend = StopRetryBackend.new(F::Origin.new("http", "t.test", 80), 4)
    engine = M::Engine.new(plan.request, false, plan.names, backend, cfg)
    backend.engine = engine
    engine.run { |_| }
    backend.after_stop.should eq(0)
  end

  # The calibration wave's own chain, whose stop check ran only BEFORE the pause: a stop that
  # arrived DURING `retry_pause` — the window a 500 ms default makes the likely one — bought
  # one more real request. The predicate answers false once, then true, which is that arrival.
  it "does not spend another calibration request on a stop that lands during the pause" do
    cfg = M::Config.new(locations: [] of M::Location, stability_rounds: 1,
      retries: 5, retry_pause: 1.millisecond)
    backend = DeadBackend.new(F::Origin.new("http", "t.test", 80))
    # The predicate is asked once before the send too (`calibrate` skips a round that is
    # already stopped), so the third ask is the one that lands inside `retry_pause`.
    asked = 0
    stopped = -> { asked += 1; asked > 2 }
    M::Baseline.new(backend, RAW.to_slice, cfg, stopped).calibrate([] of M::Location)
    backend.sent.should eq(1)
  end
end
