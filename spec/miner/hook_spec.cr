require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# The per-request transform HOOK (#818/#846): a mine can pipe each assembled request through
# an external command before it ships — the difference between mining a signed/HMAC'd API and
# not being able to mine it at all. Pinned by what the backend RECEIVES and by execution COUNT,
# the same discipline #851's regressions use.

# Records every request that reaches the wire (post-hook), and answers a stable baseline so
# calibration succeeds.
private class RecordingBackend < F::Backend
  getter origin : F::Origin
  getter received = [] of String

  def initialize(@origin : F::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @received << String.new(bytes)
    body = "BASELINE BODY CONTENT"
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end
end

private def cfg : M::Config
  c = M::Config.new
  c.locations = [M::Location::Query]
  c.bucket_size = M::Config::DEFAULT_BUCKETS.dup
  c.bucket_size[M::Location::Query] = 4
  c.concurrency = 2
  c.stability_rounds = 2
  c.confirm_rounds = 1
  c.retries = 0
  c
end

# A hook that appends one line to a tally per run and passes stdin through, tagging its output
# so the backend can see the transform reached the wire.
private def with_counting_hook(&)
  dir = File.tempname("gori-miner-hook")
  Dir.mkdir_p(dir)
  path = File.join(dir, "h.sh")
  tally = File.join(dir, "tally")
  File.write(path, "#!/bin/sh\necho ran >> '#{tally}'\nprintf 'HOOKED '\ncat\n")
  File.chmod(path, 0o755)
  begin
    yield({path, -> { File.exists?(tally) ? File.read(tally).lines.size : 0 }})
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def drain(engine : M::Engine) : {Array(M::Finding), Bool}
  findings = [] of M::Finding
  done = false
  engine.run do |ev|
    findings << ev.finding if ev.is_a?(M::FindingEvent)
    done = true if ev.is_a?(M::DoneEvent)
  end
  {findings, done}
end

describe "Miner per-request hook (#846)" do
  it "transforms every request through the hook before it is sent, once per request" do
    with_counting_hook do |hook, runs|
      inner = RecordingBackend.new(F::Origin.new("http", "h", 80))
      backend = M::HookBackend.new(inner, [hook], 5.seconds)
      base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      engine = M::Engine.new(base, http2: false, names: ["a", "b"], backend: backend, config: cfg)
      _findings, done = drain(engine)

      done.should be_true
      inner.received.should_not be_empty
      # Every request that reached the wire carries the hook's transform…
      inner.received.all?(&.starts_with?("HOOKED ")).should be_true
      # …and the command was forked exactly once per outbound request — the P6 unit.
      runs.call.should eq inner.received.size
    end
  end

  # A hook that cannot spawn must SKIP the candidate with a reported reason, never make it look
  # like a clean negative (#818's "absence of a finding reads as clean") — and the run must
  # finish rather than wedge.
  it "skips candidates with a reported reason when the hook cannot run, and does not wedge" do
    inner = RecordingBackend.new(F::Origin.new("http", "h", 80))
    backend = M::HookBackend.new(inner, ["/nonexistent/gori-hook"], 5.seconds)
    base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = M::Engine.new(base, http2: false, names: ["alpha", "secret"], backend: backend, config: cfg)
    findings, done = drain(engine)

    done.should be_true            # completed, not wedged
    findings.should be_empty       # a hook that never ran does not "find" every candidate
    inner.received.should be_empty # nothing reached the wire — the hook failed before the send
    engine.first_error.not_nil!.should contain("miner hook")
  end

  # A broken hook command is refused at PLAN BUILD, before the run starts — an un-tokenizable
  # argv is a build-time error, not a per-worker surprise on every send.
  it "refuses a hook whose argv does not parse, at plan build" do
    config = M::Config.new
    config.hook = %(./sign.sh "unterminated)
    ex = expect_raises(M::PlanError) do
      M::Plan.build(M::PlanOptions.new(
        "GET /api HTTP/1.1\r\nHost: t.test\r\n\r\n",
        target: "http://t.test", config: config), ungated_outbound)
    end
    ex.reason.should eq(M::PlanError::Reason::HookArgv)
  end

  # A hook-failure error is a PERMANENT refusal — not retried, so a broken command is not
  # re-forked `retries` times per candidate.
  it "does not retry a hook failure" do
    M.permanent_refusal?("miner hook: ./x: could not run it (No such file or directory)").should be_true
  end
end
