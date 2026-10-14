require "../spec_helper"

private alias F = Gori::Fuzz

# Answers `ok` sends, then refuses every later one as the spent project budget would (#1601).
private class SpentBudgetBackend < F::Backend
  getter calls = 0

  def initialize(@origin : F::Origin, @ok : Int32)
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @calls += 1
    return Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, Gori::Outbound::BUDGET_SPENT_ERROR) if @calls > @ok
    head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, "ok".to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

describe "the project request budget mid-run" do
  it "does not count a refused send as a request, and ends the run on it" do
    capped = F::CappedBackend.new(SpentBudgetBackend.new(F::Origin.new("http", "x", 80), 1), nil)
    capped.send("GET / HTTP/1.1\r\n\r\n".to_slice).error.should be_nil
    capped.send("GET / HTTP/1.1\r\n\r\n".to_slice).error.should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
    capped.sent.should eq(1)
    capped.cap_reached?.should be_true
    capped.send("GET / HTTP/1.1\r\n\r\n".to_slice).error.should eq(F::CappedBackend::CAP_ERROR)
  end

  it "stops a fuzz sweep and reports it budget_exhausted" do
    backend = SpentBudgetBackend.new(F::Origin.new("http", "x", 80), 3)
    tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: x\r\n\r\n")
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
    engine = F::Engine.new(F::Generator.new(tmpl, [F::PayloadSet.new(F::InlineList.new((1..30).map(&.to_s)))], cfg),
      F::Matcher.new, backend, cfg)
    done = nil.as(F::DoneEvent?)
    engine.run { |ev| done = ev if ev.is_a?(F::DoneEvent) }
    d = done.should_not be_nil
    backend.calls.should eq(4) # three sent, one refused, and nothing after it
    d.progress.requests.should eq(3)
    d.progress.blocked_reason.should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
    F.terminal_verdict(d.progress, d.stopped, nil).should eq(F::Terminal::BudgetExhausted)
  end
end
