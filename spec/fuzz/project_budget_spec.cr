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

# An origin that records how old each request's `t=<unix ms>` was when it arrived.
private def skew_origin(skews : Array(Int64)) : {TCPServer, Int32}
  srv = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = srv.accept?
      spawn do
        c = conn
        if head = Gori::Proxy::Codec::Http1.read_head(c)
          if m = String.new(head).match(/t=(\d+)/)
            skews << Time.utc.to_unix_ms - m[1].to_i64
          end
          c << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
          c.flush
        end
        c.close rescue nil
      end
    end
  end
  {srv, srv.local_address.port}
end

describe "a $GEN value under the project rate" do
  it "is minted after the wait for the slot, on both send seams" do
    with_store do |store|
      store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_RPS_KEY, "5"}] of {String, String?})
      skews = [] of Int64
      srv, port = skew_origin(skews)
      ob = Gori::Outbound.interactive(Gori::Scope.load(store))
      fuzz = F::Sender.new(F::Origin.new("http", "127.0.0.1", port), ob, http2: false, verify: false)
      rep = Gori::Repeater::Sender.new(ob, scheme: "http", host: "127.0.0.1", port: port, verify: false)
      req = "GET /?t=$GEN.TIMESTAMP_MS HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        done = Channel(Nil).new
        3.times { spawn { fuzz.send(req, nil); done.send(nil) } }
        3.times { spawn { rep.send(req); done.send(nil) } }
        6.times { done.receive }
      end
      srv.close
      skews.size.should eq(6)
      # Six sends 200ms apart: minted before the wait, the last would be ~1s old.
      skews.max.should be < 150
    end
  end
end

# Answers the first send; every later one waits for the budget until the run is stopped, and then
# comes back the way `Outbound#admit` does when its `halt` ends the wait.
private class StopWaitBackend < F::Backend
  property engine : F::Engine? = nil

  def initialize(@origin : F::Origin)
    @calls = 0
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @calls += 1
    if @calls == 1
      head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
      return Gori::Repeater::Result.new(head, "ok".to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
    end
    until engine.try(&.stopped?)
      sleep 10.milliseconds
    end
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, Gori::Outbound::BUDGET_STOPPED_ERROR)
  end
end

describe "a stop during a wait for the project budget" do
  it "leaves no row for the payloads that were never sent" do
    backend = StopWaitBackend.new(F::Origin.new("http", "x", 80))
    tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: x\r\n\r\n")
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 4)
    engine = F::Engine.new(F::Generator.new(tmpl, [F::PayloadSet.new(F::InlineList.new((1..10).map(&.to_s)))], cfg),
      F::Matcher.new, backend, cfg)
    backend.engine = engine
    rows = [] of F::Result
    done = nil.as(F::DoneEvent?)
    spawn do
      sleep 100.milliseconds
      engine.stop
    end
    engine.run do |ev|
      rows << ev.result if ev.is_a?(F::ResultEvent)
      done = ev if ev.is_a?(F::DoneEvent)
    end
    d = done.should_not be_nil
    rows.size.should eq(1)
    d.progress.errors.should eq(0)
    d.progress.blocked.should eq(0)
    d.progress.blocked_reason.should be_nil
  end
end

# A retry that waits for the budget and is stopped there sent nothing, but the attempt it was
# retrying did go out: its failure is the row.
private class FailThenStopWaitBackend < F::Backend
  property engine : F::Engine? = nil
  getter calls = 0

  def initialize(@origin : F::Origin)
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @calls += 1
    return Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "read: Connection reset by peer") if @calls == 1
    until engine.try(&.stopped?)
      sleep 10.milliseconds
    end
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, Gori::Outbound::BUDGET_STOPPED_ERROR)
  end
end

describe "a stop during a retry's wait for the project budget" do
  it "keeps the row of the attempt that was sent" do
    backend = FailThenStopWaitBackend.new(F::Origin.new("http", "x", 80))
    tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: x\r\n\r\n")
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 2, retry_pause: 10.milliseconds)
    engine = F::Engine.new(F::Generator.new(tmpl, [F::PayloadSet.new(F::InlineList.new(["1"]))], cfg),
      F::Matcher.new, backend, cfg)
    backend.engine = engine
    rows = [] of F::Result
    spawn do
      sleep 150.milliseconds
      engine.stop
    end
    engine.run { |ev| rows << ev.result if ev.is_a?(F::ResultEvent) }
    backend.calls.should eq(2)
    rows.size.should eq(1)
    rows[0].error.should eq("read: Connection reset by peer")
  end
end

# Answers the first request on each connection, then closes it.
private def answer_once_origin : {TCPServer, Int32}
  srv = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = srv.accept?
      c = conn
      spawn do
        if Gori::Proxy::Codec::Http1.read_head(c)
          c << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
          c.flush
        end
      rescue
      ensure
        c.close rescue nil
      end
    end
  end
  {srv, srv.local_address.port}
end

private def budget_outbound(store : Gori::Store) : Gori::Outbound
  store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, "10"}] of {String, String?})
  Gori::Outbound.interactive(Gori::Scope.load(store))
end

private def spent(store : Gori::Store) : String?
  Gori::Outbound::Budget.release(store)
  store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY)
end

# A group's slots are taken up front; one for a request that never went out comes back.
describe "a fuzz group send's project budget slots" do
  it "refunds the pipeline members skipped after the connection died" do
    with_store do |store|
      srv, port = answer_once_origin
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", port), budget_outbound(store),
        http2: false, verify: false)
      req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice
      results = sender.send_pipeline([req, req, req, req])
      srv.close
      results.count(&.error.== Gori::Repeater::Engine::PIPELINE_SKIPPED).should eq(2)
      spent(store).should eq("2") # was 4
    end
  end

  it "refunds the warm-up slots of race connections that never dialled" do
    with_store do |store|
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", 1), budget_outbound(store),
        http2: false, verify: false)
      bytes = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice
      jobs = Array.new(2) { |i| F::Job.new(i.to_i64, [] of String, nil, bytes) }
      sender.send_race(jobs, warmup: bytes).each(&.error.to_s.should(start_with("race: dial failed")))
      spent(store).should eq("2") # was 4: one per member, plus a warm-up that never went out
    end
  end
end

# Holds the cap's re-send veto, the hook a pooled `Sender` calls before a stale re-send.
private class VetoCapture < F::Backend
  getter veto : Proc(String?, String?)? = nil

  def origin : F::Origin
    F::Origin.new("http", "x", 80)
  end

  def resend_veto=(veto : Proc(String?, String?)) : Nil
    @veto = veto
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, nil)
  end
end

describe "a pooled re-send the project budget refuses" do
  # The row keeps the first copy's failure, so the cap has to hear the refusal to end the run
  # `budget_exhausted` rather than `done` with an error row.
  it "latches the refusal on the cap, as a refused send does" do
    inner = VetoCapture.new
    capped = F::CappedBackend.new(inner, nil)
    inner.veto.not_nil!.call(Gori::Outbound::BUDGET_SPENT_ERROR).should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
    capped.budget_refusal.should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
    capped.cap_reached?.should be_true
    # …but a stop ending the wait is the operator's stop, not the budget's.
    inner2 = VetoCapture.new
    capped2 = F::CappedBackend.new(inner2, nil)
    inner2.veto.not_nil!.call(Gori::Outbound::BUDGET_STOPPED_ERROR)
    capped2.budget_refusal.should be_nil
  end
end
