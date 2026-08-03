require "../spec_helper"
require "socket"

private alias F = Gori::Fuzz

# Workstream B (#10 truthful-reporting): three coupled fixes on the Fuzzer result path.
#   B1 — `incomplete`/`timed_out` are now READ (a truncated body was reported as the whole one).
#   B2 — a `--retries` config re-send is MARKED on the row and every failed attempt counts.
#   B3 — `blocked` is a PAYLOAD-unit count (retries/hops no longer inflate it and poison
#        `all_blocked`), and a scope-refused redirect hop no longer overwrites the payload's 302.

# A Backend whose canned reply is decided per call by a block — the block closes over a counter,
# so a spec can make the same payload fail twice and then succeed, or refuse a payload by name.
private class ScriptBackend < F::Backend
  getter origin : F::Origin
  getter calls = 0

  def initialize(@origin : F::Origin, &@fn : Bytes, Int32 -> Gori::Repeater::Result)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @calls += 1
    @fn.call(bytes, @calls)
  end
end

private def ok_reply(status : Int32, body : String) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
  Gori::Repeater::Result.new(head, body.to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
end

private def drain(engine : F::Engine) : {Array(F::Result), F::DoneEvent?}
  results = [] of F::Result
  done = nil.as(F::DoneEvent?)
  engine.run do |ev|
    case ev
    when F::ResultEvent then results << ev.result
    when F::DoneEvent   then done = ev
    end
  end
  {results, done}
end

private def one_position_gen(payloads : Array(String), cfg : F::Config) : F::Generator
  tpl = F::Template.parse("GET /x?p=§a§ HTTP/1.1\r\nHost: h\r\n\r\n")
  F::Generator.new(tpl, [F::PayloadSet.new(F::InlineList.new(payloads))], cfg)
end

# An origin that declares Content-Length: 100 but writes 2 bytes and hangs up — the classic
# "origin closed before the framed body finished" truncation the capture must not report whole.
private class ShortBodyOrigin
  getter port : Int32

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        spawn do
          if Gori::Proxy::Codec::Http1.read_head(conn)
            conn << "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nab"
            conn.flush
          end
          conn.close rescue nil
        end
      end
    rescue
      # server closed
    end
  end

  def close : Nil
    @server.close
  end
end

# ─────────────────────────── B1 — incomplete / timed_out ───────────────────────────

describe "Fuzz result — B1 incomplete/timed_out are read, not dropped" do
  it "propagates incomplete AND timed_out from the Repeater result onto the row" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".to_slice
    raw = Gori::Repeater::Result.new(head, "ab".to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head(head), 5_i64, nil, true, timed_out: true)
    job = F::Job.new(0_i64, ["x"], 0, "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
    res = F::Matcher.new.build(job, raw)
    res.incomplete?.should be_true
    res.timed_out?.should be_true
  end

  it "surfaces incomplete + the read-deadline reason on JSON, text and MCP, only when set" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".to_slice
    raw = Gori::Repeater::Result.new(head, "ab".to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head(head), 5_i64, nil, true, timed_out: true)
    job = F::Job.new(0_i64, ["x"], 0, "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
    res = F::Matcher.new.build(job, raw)

    j = JSON.parse(Gori::CLI::Output.fuzz_row_json(res))
    j["incomplete"].as_bool.should be_true
    j["incomplete_reason"].as_s.should contain("read deadline") # timed_out → the deadline sentence

    Gori::CLI::Output.fuzz_row_text(res).should contain("read deadline")

    mcp = JSON.parse(JSON.build { |b| Gori::MCP::Serialize.fuzz_result(b, res) })
    mcp["incomplete"].as_bool.should be_true
    mcp["incomplete_reason"].as_s.should contain("read deadline")

    # A clean, complete row carries none of it (no false `incomplete` on every row).
    clean = F::Matcher.new.build(job, ok_reply(200, "abcdef"))
    Gori::CLI::Output.fuzz_row_json(clean).should_not contain("incomplete")
    Gori::CLI::Output.fuzz_row_text(clean).should_not contain("incomplete")
  end

  it "reports a real early-close origin (CL > bytes) as incomplete, not as the whole response" do
    origin = ShortBodyOrigin.new
    begin
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, timeout: 2.seconds)
      gen = one_position_gen(["x"], cfg)
      backend = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port),
        ungated_outbound, false, false)
      results, _ = drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))
      results.size.should eq(1)
      results[0].incomplete?.should be_true
      results[0].timed_out?.should be_false # the origin CLOSED; it did not stall on a deadline
      j = JSON.parse(Gori::CLI::Output.fuzz_row_json(results[0]))
      j["incomplete"].as_bool.should be_true
      j["incomplete_reason"].as_s.should contain("origin closed")
    ensure
      origin.close
    end
  end
end

# ─────────────────────────── B2 — config-retry marked, errors counted ───────────────────────────

describe "Fuzz engine — B2 a --retries re-send is marked and every failed attempt counts" do
  it "marks resent + counts every superseded attempt when the POST succeeds on try 3" do
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 2, retry_pause: 0.seconds)
    gen = one_position_gen(["x"], cfg)
    backend = ScriptBackend.new(F::Origin.new("http", "h", 80)) do |_bytes, n|
      n < 3 ? Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection reset") : ok_reply(200, "ok")
    end
    results, done = drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))

    results.size.should eq(1)
    results[0].resent?.should be_true
    results[0].resent_count.should eq(2) # attempts 1 and 2 were superseded
    results[0].error.should be_nil       # …and the final attempt (3) succeeded
    backend.calls.should eq(3)
    # `errors` counts EVERY failed attempt (2), not only the final result (0 here).
    done.not_nil!.progress.errors.should eq(2)
  end

  it "counts the final failure too when all retries are exhausted" do
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 2, retry_pause: 0.seconds)
    gen = one_position_gen(["x"], cfg)
    backend = ScriptBackend.new(F::Origin.new("http", "h", 80)) do |_bytes, _n|
      Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection reset")
    end
    results, done = drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))

    results[0].resent_count.should eq(2)
    results[0].error.should_not be_nil
    backend.calls.should eq(3)                 # 1 original + 2 retries
    done.not_nil!.progress.errors.should eq(3) # 2 superseded + the final one
  end
end

# ─────────────────────────── B3 — blocked is payload-unit ───────────────────────────

describe "Fuzz engine — B3 blocked counts payloads, not attempts/hops" do
  it "counts a refused payload once (not once per retry) and never retries it" do
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, retries: 2, retry_pause: 0.seconds)
    gen = one_position_gen(["ok", "b1", "b2"], cfg)
    backend = ScriptBackend.new(F::Origin.new("http", "h", 80)) do |bytes, _n|
      s = String.new(bytes)
      if s.includes?("p=b1") || s.includes?("p=b2")
        Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, Gori::Outbound::EXCLUDE_SWEEP_ERROR)
      else
        ok_reply(200, "ok")
      end
    end
    _, done = drain(F::Engine.new(gen, F::Matcher.new, backend, cfg))
    p = done.not_nil!.progress

    p.blocked.should eq(2)   # payload-unit — NOT 6 (2 refused × 3 attempts under the old bug)
    p.sent.should eq(3)
    backend.calls.should eq(3) # each refused payload sent ONCE; no wasted retries of a stable gate
    # A refused payload is still one error (the refusal produces an errored Result); NOT three.
    # Under the old retry-a-gate bug this read 6 — pin the corrected, once-per-payload contract.
    p.errors.should eq(2)
    # `all_blocked` (mcp/tools/fuzz.cr) is `sent>0 && blocked>=sent` — false because a payload 200'd.
    (p.sent > 0 && p.blocked >= p.sent).should be_false
    p.blocked_reason.should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
  end

  # The inverse of the poisoning: a fully-refused run must still read `all_blocked == true`.
  # `@blocked` is bumped only in `run_one`'s payload path, so auto-calibration sends (which go
  # straight to `@backend`, outside `run_one`) correctly do NOT count — but they must also not
  # derail the sweep, or a run where nothing left the machine would read `blocked < sent`.
  it "keeps blocked == sent on a fully-refused run even with auto-calibration on" do
    cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, auto_calibrate: true)
    gen = one_position_gen(["a", "b"], cfg)
    backend = ScriptBackend.new(F::Origin.new("http", "h", 80)) do |_bytes, _n|
      Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, Gori::Outbound::SANDBOX_SWEEP_ERROR)
    end
    engine = F::Engine.new(gen, F::Matcher.new(auto_calibrate: true), backend, cfg)
    engine.calibrate_baseline # 6 refused calibration sends — must not inflate @blocked nor stop the sweep
    _, done = drain(engine)
    p = done.not_nil!.progress

    p.sent.should eq(2)
    p.blocked.should eq(2)
    (p.sent > 0 && p.blocked >= p.sent).should be_true # fully blocked, and it SAYS so
  end
end
