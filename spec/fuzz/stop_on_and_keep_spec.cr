require "../spec_helper"

private alias F = Gori::Fuzz

# Answers each send with a caller-supplied {status, body}, indexed by send order. Lets a spec
# stage exactly which response trips a stop condition, and counts how many sends actually
# happened before the engine halted.
private class ScriptedBackend < F::Backend
  getter sent = 0

  # `replies` is {status, body} per send; past its end every send is a plain 200 with an
  # empty body, so a run that keeps going after the script does not crash.
  def initialize(@origin : F::Origin, @replies : Array({Int32, String}))
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    status, body = @replies[@sent]? || {200, ""}
    @sent += 1
    head = "HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, body.to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

# Stops the engine while its first request is in flight (an operator ^X / `fuzz_stop`), then
# answers with a body that meets the stop condition.
private class StopDuringSendBackend < F::Backend
  property engine : F::Engine?

  def initialize(@origin : F::Origin)
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @engine.try(&.stop)
    body = "STOP"
    head = "HTTP/1.1 200 X\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, body.to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

# Answers each payload after a payload-keyed delay, with a body that meets a `STOP` condition
# when the payload is listed in `stop`. With concurrency > 1 that makes COMPLETION order differ
# from payload order — the shape where the row that trips a stop is not the lowest index.
private class DelayedBackend < F::Backend
  def initialize(@origin : F::Origin, @delays : Hash(String, Time::Span), @stop : Set(String))
  end

  def origin : F::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    payload = String.new(bytes)[/q=(\w+)/, 1]? || ""
    sleep(@delays[payload]? || 0.seconds)
    body = @stop.includes?(payload) ? "STOP" : "go"
    head = "HTTP/1.1 200 X\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, body.to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

# One-position sweep of N inline payloads "0".."N-1", concurrency 1 so send order is the
# dispatch order and a stop lands deterministically.
private def sweep(be : F::Backend, matcher : F::Matcher, n : Int32, cfg : F::Config) : {Array(F::Result), F::DoneEvent}
  payloads = (0...n).map(&.to_s)
  gen = F::Generator.new(F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n"),
    [F::PayloadSet.new(F::InlineList.new(payloads))], cfg)
  engine = F::Engine.new(gen, matcher, be, cfg)
  results = [] of F::Result
  done = nil.as(F::DoneEvent?)
  engine.run do |ev|
    case ev
    when F::ResultEvent then results << ev.result
    when F::DoneEvent   then done = ev
    end
  end
  {results, done.not_nil!}
end

describe "Fuzz::Keep" do
  it "parses its two spellings and rejects the rest" do
    F::Keep.parse?("all").should eq(F::Keep::All)
    F::Keep.parse?("interesting").should eq(F::Keep::Interesting)
    F::Keep.parse?("INTERESTING").should eq(F::Keep::Interesting)
    F::Keep.parse?("some").should be_nil
    F::Keep.parse?(nil).should be_nil
  end

  it "keeps every row under All, and only interesting rows under Interesting" do
    plain = F::Result.new(0_i64, ["x"], nil, 200, 5_i64, 1, 1, 1_i64, nil, false, false, nil)
    hit = F::Result.new(1_i64, ["x"], nil, 200, 5_i64, 1, 1, 1_i64, nil, true, false, nil)
    F::Keep::All.keeps?(plain).should be_true
    F::Keep::All.keeps?(hit).should be_true
    F::Keep::Interesting.keeps?(plain).should be_false # a bare unmatched row is dropped
    F::Keep::Interesting.keeps?(hit).should be_true    # a match is kept
  end
end

describe "Fuzz::Result#interesting?" do
  it "is true for a match, an error, a re-send, a truncation or a stop hit — false otherwise" do
    base = ->(matched : Bool, error : String?) {
      F::Result.new(0_i64, ["x"], nil, 200, 1_i64, 1, 1, 1_i64, error, matched, false, nil)
    }
    base.call(false, nil).interesting?.should be_false
    base.call(true, nil).interesting?.should be_true
    base.call(false, "boom").interesting?.should be_true
    F::Result.new(0_i64, ["x"], nil, 200, 1_i64, 1, 1, 1_i64, nil, false, false, nil,
      stop_hit: true).interesting?.should be_true
    F::Result.new(0_i64, ["x"], nil, 200, 1_i64, 1, 1, 1_i64, nil, false, false, nil,
      resent_count: 2).interesting?.should be_true
  end
end

describe "Fuzz.terminal_verdict" do
  it "ranks a stop condition above stopped and the budget" do
    p = F::Progress.new(3_i64, 100_i64, 1_i64, 0_i64)
    F.terminal_verdict(p, true, nil, false, "reached 1 match").should eq(F::Terminal::ConditionMet)
    F.terminal_verdict(p, true, nil).should eq(F::Terminal::Stopped)
    # sent < total AND the wire budget was reached ⇒ budget_exhausted
    F.terminal_verdict(F::Progress.new(3_i64, 100_i64, 1_i64, 0_i64, requests: 10_i64), false, 10_i64)
      .should eq(F::Terminal::BudgetExhausted)
    F.terminal_verdict(F::Progress.new(100_i64, 100_i64, 0_i64, 0_i64), false, nil).should eq(F::Terminal::Done)
  end

  it "labels condition_met durably" do
    F::Terminal::ConditionMet.label.should eq("condition_met")
    F.terminal_status(F::Progress.new(1_i64, 9_i64, 1_i64, 0_i64), true, nil,
      stop_reason: "reached 1 match").should eq("condition_met")
  end
end

describe "Fuzz::Matcher stop condition" do
  it "flags the row that meets a separate body-regex condition without a second decode" do
    run = F::Matcher.new
    run.match_status = "200" # every 200 matches the run's own matchers
    cond = F::Matcher.new
    cond.match_regex = /WELCOME/
    run.stop_condition = cond

    hit = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n".to_slice, "WELCOME admin".to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head("HTTP/1.1 200 OK\r\n\r\n".to_slice), 1_i64)
    miss = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "no".to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head("HTTP/1.1 200 OK\r\n\r\n".to_slice), 1_i64)
    job = F::Job.new(0_i64, ["x"], nil, "GET / HTTP/1.1\r\n\r\n".to_slice)

    run.build(job, hit).stop_hit?.should be_true
    run.build(job, miss).stop_hit?.should be_false
    run.build(job, miss).matched?.should be_true # the run's own verdict is independent of the stop
  end

  it "reports a stop-condition spec error through the run matcher's spec_error" do
    run = F::Matcher.new
    cond = F::Matcher.new
    cond.match_size = "1O00" # a letter O — can never fire
    run.stop_condition = cond
    err = run.spec_error
    err.should_not be_nil
    err.not_nil!.starts_with?("stop ").should be_true
  end
end

describe "Fuzz.apply_stop_term" do
  it "maps DIM:SPEC onto match dimensions and !DIM onto filters" do
    m = F::Matcher.new
    F.apply_stop_term("status:200", m).should be_nil
    m.match_status.should eq("200")
    F.apply_stop_term("!regex:Invalid password", m).should be_nil
    m.filter_regex.try(&.source).should eq("Invalid password")
  end

  it "refuses an unknown dimension and an uncompilable regex" do
    F.apply_stop_term("bogus:1", F::Matcher.new).should_not be_nil
    F.apply_stop_term("noколon", F::Matcher.new).should_not be_nil
    F.apply_stop_term("regex:(", F::Matcher.new).should_not be_nil
  end

  it "refuses empty values in stop terms" do
    %w[status: header: size: regex:].each do |t|
      m = F::Matcher.new
      err = F.apply_stop_term(t, m)
      err.should_not be_nil
      err.not_nil!.should contain("empty value")
    end
    err = F.apply_stop_term("status:   ", F::Matcher.new)
    err.should_not be_nil
    err.not_nil!.should contain("empty value")
  end
end

describe "Fuzz::Result serialization" do
  it "serializes stop_hit in CLI json and text output" do
    hit = F::Result.new(0_i64, ["x"], nil, 200, 1_i64, 1, 1, 1_i64, nil, false, false, nil, stop_hit: true)
    miss = F::Result.new(1_i64, ["y"], nil, 200, 1_i64, 1, 1, 1_i64, nil, false, false, nil, stop_hit: false)

    json = JSON.parse(Gori::CLI::Output.fuzz_row_json(hit))
    json["stop_hit"]?.try(&.as_bool).should be_true
    Gori::CLI::Output.fuzz_row_text(hit).should contain("stop-hit")

    clean_json = JSON.parse(Gori::CLI::Output.fuzz_row_json(miss))
    clean_json["stop_hit"]?.should be_nil
    Gori::CLI::Output.fuzz_row_text(miss).should_not contain("stop-hit")
  end
end

describe "Fuzz::Engine — stop_on" do
  it "stops once the matchers have hit stop_after_matches times" do
    cfg = F::Config.new(concurrency: 1, stop_after_matches: 2)
    matcher = F::Matcher.new
    matcher.match_status = "200" # every reply matches
    be = ScriptedBackend.new(F::Origin.new("http", "h", 80), [] of {Int32, String})
    results, done = sweep(be, matcher, 5, cfg)
    be.sent.should eq(2) # the 2nd match halts the dispatcher; the other 3 never go out
    results.count(&.matched?).should eq(2)
    done.stopped.should be_true
    done.stop_reason.should_not be_nil
    F.terminal_status(done.progress, done.stopped, nil, false, done.stop_reason).should eq("condition_met")
    # The row that took the count to 2 is the stop row, although it carries no `stop_hit` —
    # only the separate condition sets that flag (issue #1270).
    done.stop_index.should eq(1_i64)
    results.find! { |r| r.index == 1_i64 }.stop_hit?.should be_false
    done.stop_reason.not_nil!.should contain("on result 1")
  end

  it "stops on a separate condition and flags the row that met it" do
    cfg = F::Config.new(concurrency: 1)
    matcher = F::Matcher.new # unconstrained: no run-matcher hit is needed
    cond = F::Matcher.new
    cond.match_regex = /STOP/
    matcher.stop_condition = cond
    # The 3rd response carries the needle; the run must halt there.
    be = ScriptedBackend.new(F::Origin.new("http", "h", 80),
      [{200, "keep going"}, {200, "keep going"}, {200, "STOP here"}])
    results, done = sweep(be, matcher, 6, cfg)
    be.sent.should eq(3)
    results.last.stop_hit?.should be_true
    done.stop_reason.should_not be_nil
    done.stop_index.should eq(results.last.index)
    done.stop_index.should eq(2_i64)
  end

  it "names the row that TRIPPED the stop, not the lowest index that met the condition" do
    # Payload 0 meets the condition but answers slowly; payload 1 meets it and answers first.
    # The engine stops on 1; 0 is in flight, finishes, and is flagged too — so the lowest
    # flagged index (0) is NOT the stop row, and only the engine can say which one is.
    cfg = F::Config.new(concurrency: 2)
    matcher = F::Matcher.new
    cond = F::Matcher.new
    cond.match_regex = /STOP/
    matcher.stop_condition = cond
    be = DelayedBackend.new(F::Origin.new("http", "h", 80),
      {"0" => 60.milliseconds}, Set{"0", "1"})
    results, done = sweep(be, matcher, 6, cfg)
    results.select(&.stop_hit?).map(&.index).sort!.should eq([0_i64, 1_i64])
    results.first.index.should eq(1_i64) # recorded first
    done.stop_index.should eq(1_i64)
  end

  it "names the row whose OWN match crossed after_matches, even when sends block (#1270)" do
    # A slow consumer fills the engine's event buffer, so both workers are parked in the
    # blocking ResultEvent send when the two matches land. The first to match must not read
    # the second's increment on resume and claim to be the Nth match.
    cfg = F::Config.new(concurrency: 2, stop_after_matches: 2)
    matcher = F::Matcher.new
    matcher.match_regex = /STOP/
    n = F::Engine::EVENT_BUFFER + 40
    hits = Set{(n - 10).to_s, (n - 9).to_s}
    be = DelayedBackend.new(F::Origin.new("http", "h", 80), {} of String => Time::Span, hits)
    payloads = (0...n).map(&.to_s)
    gen = F::Generator.new(F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n"),
      [F::PayloadSet.new(F::InlineList.new(payloads))], cfg)
    engine = F::Engine.new(gen, matcher, be, cfg)
    results = [] of F::Result
    done = nil.as(F::DoneEvent?)
    engine.run do |ev|
      case ev
      when F::ResultEvent
        results << ev.result
        sleep 200.microseconds
      when F::DoneEvent then done = ev
      end
    end
    matched = results.select(&.matched?)
    matched.size.should eq(2)
    done.not_nil!.stop_index.should eq(matched[1].index)
  end

  it "has no stop row for a run that ends without its condition" do
    cfg = F::Config.new(concurrency: 1, stop_after_matches: 9)
    matcher = F::Matcher.new
    matcher.match_status = "200"
    be = ScriptedBackend.new(F::Origin.new("http", "h", 80), [] of {Int32, String})
    _, done = sweep(be, matcher, 3, cfg)
    done.stop_reason.should be_nil
    done.stop_index.should be_nil
  end

  it "keeps an operator stop as `stopped` when an in-flight row then meets the condition" do
    cfg = F::Config.new(concurrency: 1)
    matcher = F::Matcher.new
    cond = F::Matcher.new
    cond.match_regex = /STOP/
    matcher.stop_condition = cond
    be = StopDuringSendBackend.new(F::Origin.new("http", "h", 80))
    gen = F::Generator.new(F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: h\r\n\r\n"),
      [F::PayloadSet.new(F::InlineList.new(["1", "2", "3"]))], cfg)
    engine = F::Engine.new(gen, matcher, be, cfg)
    be.engine = engine
    results = [] of F::Result
    done = nil.as(F::DoneEvent?)
    engine.run do |ev|
      case ev
      when F::ResultEvent then results << ev.result
      when F::DoneEvent   then done = ev
      end
    end
    d = done.not_nil!
    results.first.stop_hit?.should be_true # the row still says what it saw
    d.stopped.should be_true
    d.stop_reason.should be_nil
    d.stop_index.should be_nil # ...but the run has no stop row: nothing tripped it
    F.terminal_verdict(d.progress, d.stopped, nil, false, d.stop_reason).should eq(F::Terminal::Stopped)
  end
end
