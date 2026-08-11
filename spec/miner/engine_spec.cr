require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# A backend that simulates a server with hidden parameters. It parses the query string
# of each request; if a "magic" param is present it changes the response accordingly:
#   - REFLECT params echo their (canary) value in the body.
#   - GROW params append extra bytes to the body (a metric/length signal, no reflection).
#   - ECHO mode reflects EVERY param value back (an echo API like httpbin/get), the
#     reflect-all false-positive trap the miner must recognise and suppress.
# Everything else returns a stable baseline body.
private class HiddenParamBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @reflect : Array(String) = [] of String,
                 @grow : Array(String) = [] of String, @echo : Bool = false)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    params = query_params(bytes)
    body = "BASELINE BODY CONTENT"
    if @echo
      params.each { |k, v| body += " #{k}=#{v}" } # echo API: reflects ANY input value
    else
      @reflect.each { |name| (v = params[name]?) && (body += " reflected=#{v}") }
      @grow.each { |name| params.has_key?(name) && (body += " XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX") }
    end
    ok(body)
  end

  private def query_params(bytes : Bytes) : Hash(String, String)
    pairs = Hash(String, String).new
    line = String.new(bytes).lines.first? || ""
    target = line.split(' ')[1]? || ""
    qi = target.index('?')
    return pairs unless qi
    target[(qi + 1)..].split('&').each do |pair|
      k, _, v = pair.partition('=')
      pairs[k] = v unless k.empty?
    end
    pairs
  end

  private def ok(body : String) : Gori::Repeater::Result
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end
end

# Returns one fixed (large) body regardless of input — for exercising the baseline
# tolerance floors on a big page.
private class FixedBodyBackend < F::Backend
  getter origin : F::Origin

  def initialize(@origin : F::Origin, @body : String)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{@body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, @body.to_slice, resp, 1000_i64)
  end
end

private class BlockedBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @reason : String)
  end

  # The shape Outbound-gated senders return: no head, no response, the reason in `error`.
  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, @reason)
  end
end

# Reacts to a magic name at the QUERY *and* at the HEADER location, and yields inside every
# send so the scheduler can interleave — which is what makes the in-flight measurements below
# real rather than always 1.
#
#   max_in_flight     — the most sends outstanding at one moment.
#   mixed_in_flight   — a QUERY bucket and a HEADER bucket were outstanding TOGETHER, which
#                       a per-location schedule can never produce.
#   closed            — the end-of-run release of the send backend (the pool's sockets).
private class MultiLocationBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0
  getter closed : Bool = false
  getter max_in_flight : Int32 = 0
  getter mixed_in_flight : Bool = false

  def initialize(@origin : F::Origin, @magic : String)
    @in_flight = 0
    @query_in_flight = 0
    @header_in_flight = 0
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    text = String.new(bytes)
    line = text.lines.first? || ""
    # A canary is "gq" + 8 hex, injected as `name=gqXXXXXXXX` in the query and as
    # `name: gqXXXXXXXX` in a header — so the request itself says which bucket this is.
    query = line.includes?("=gq")
    header = text.includes?(": gq")
    @sent += 1
    @in_flight += 1
    @query_in_flight += 1 if query
    @header_in_flight += 1 if header
    @max_in_flight = @in_flight if @in_flight > @max_in_flight
    @mixed_in_flight = true if @query_in_flight > 0 && @header_in_flight > 0
    Fiber.yield
    @in_flight -= 1
    @query_in_flight -= 1 if query
    @header_in_flight -= 1 if header
    hit = line.includes?("#{@magic}=gq") || text.includes?("\r\n#{@magic}: gq")
    body = "BASELINE BODY CONTENT"
    body += " XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" if hit
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end

  def close : Nil
    @closed = true
  end
end

# Records, per send, how many of the run's CANDIDATE names the query carried — the size of
# the bucket that request tested. Baseline's raw probe carries none and its control probe
# carries only bogus `zz…` names, so neither pollutes the count. Grows the body for `magic`,
# so exactly one name is positive and the bisection follows a single, deterministic path
# whose bucket sizes reveal the branch factor. Used to pin `Engine#split`.
private class RecordingBucketBackend < F::Backend
  getter origin : F::Origin
  getter counts = [] of Int32

  def initialize(@origin : F::Origin, @candidates : Set(String), @magic : String)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    params = query_params(bytes)
    @counts << params.keys.count { |k| @candidates.includes?(k) }
    body = "BASELINE BODY CONTENT"
    body += " XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" if params.has_key?(@magic)
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end

  private def query_params(bytes : Bytes) : Hash(String, String)
    pairs = Hash(String, String).new
    line = String.new(bytes).lines.first? || ""
    target = line.split(' ')[1]? || ""
    qi = target.index('?')
    return pairs unless qi
    target[(qi + 1)..].split('&').each do |pair|
      k, _, v = pair.partition('=')
      pairs[k] = v unless k.empty?
    end
    pairs
  end

  # The largest bucket tested AFTER the initial full bucket — i.e. the widest second-generation
  # sub-bucket the split produced. Smaller means a wider (shallower) split.
  def widest_split : Int32
    initial = @counts.max
    @counts.reject { |c| c == initial || c.zero? }.max? || 0
  end
end

private def mine(backend : F::Backend, names : Array(String), config : M::Config) : Array(M::Finding)
  base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  engine = M::Engine.new(base, http2: false, names: names, backend: backend, config: config)
  findings = [] of M::Finding
  engine.run do |ev|
    findings << ev.finding if ev.is_a?(M::FindingEvent)
  end
  findings
end

private def cfg : M::Config
  c = M::Config.new
  c.locations = [M::Location::Query]
  c.bucket_size = M::Config::DEFAULT_BUCKETS.dup
  c.bucket_size[M::Location::Query] = 4 # small → forces bisection
  c.concurrency = 2
  c.stability_rounds = 2
  c.confirm_rounds = 1
  c.retries = 0
  c
end

describe Gori::Miner::Engine do
  it "isolates a reflected hidden parameter via bisection" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: ["secret"])
    names = ["alpha", "beta", "gamma", "secret", "delta", "epsilon", "zeta", "eta"]
    findings = mine(backend, names, cfg)

    secret = findings.find { |f| f.name == "secret" }
    raise "expected a finding for 'secret'" unless secret
    secret.location.should eq(M::Location::Query)
    secret.evidence.should eq(M::Evidence::Reflection)
    secret.confidence.should eq(M::Confidence::Confirmed)
    findings.map(&.name).should_not contain("alpha")
  end

  it "isolates a length-only (non-reflected) hidden parameter" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), grow: ["debug"])
    names = ["alpha", "beta", "gamma", "debug", "delta", "epsilon", "zeta", "eta"]
    findings = mine(backend, names, cfg)

    debug = findings.find { |f| f.name == "debug" }
    raise "expected a finding for 'debug'" unless debug
    debug.evidence.should eq(M::Evidence::Length)
    findings.size.should eq(1)
  end

  it "isolates EVERY hidden parameter when a whole bucket is positive, for no more requests" do
    # Two guarantees for the densest case (every name positive → the bucket fully expands to
    # singletons):
    #   1. correctness — an off-by-one in the slice arithmetic would drop or double a name and
    #      silently miss it, so assert not one of the ten is lost.
    #   2. budget — a wider split must never send MORE probes than binary would, or a run under
    #      `--max-requests` would exhaust its cap sooner and find fewer (a false negative). The
    #      pruning tree has ~K·b/(b−1) nodes, so 4-ary sends FEWER here, never more.
    names = (1..10).map { |i| "grow#{i}" }
    build = ->(conc : Int32) do
      c = cfg
      c.bucket_size[M::Location::Query] = 16 # one initial bucket holds all 10
      c.concurrency = conc
      backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), grow: names)
      findings = mine(backend, names, c)
      {findings.map(&.name).sort, backend.sent}
    end
    binary_names, binary_sent = build.call(2)
    wide_names, wide_sent = build.call(4) # split ≠ binary
    wide_names.should eq(names.sort)      # every one still isolated…
    binary_names.should eq(names.sort)
    wide_sent.should be <= binary_sent # …and the wider split never costs more requests
  end

  it "splits a positive bucket wider as concurrency rises (shallower bisection tree)" do
    # The mine's critical path is the bisection DEPTH, so a positive bucket is split into
    # `min(concurrency, BISECT_MAX_WAYS)` sub-buckets, not always two — filling idle workers to
    # trade the run's spare throughput for a shorter path. A serial/paced run keeps the binary
    # tree it had. Observe it through the widest second-generation bucket: wider split → smaller.
    names = ["a", "b", "c", "d", "e", "f", "g", "h"]
    cands = names.to_set
    build = ->(conc : Int32) do
      c = cfg
      c.bucket_size[M::Location::Query] = 8 # all eight in one initial bucket
      c.concurrency = conc
      backend = RecordingBucketBackend.new(F::Origin.new("http", "h", 80), cands, "d")
      mine(backend, names, c)
      backend.widest_split
    end
    # concurrency 2 bisects [8]→[4,4]; concurrency 4 splits [8]→[2,2,2,2].
    binary = build.call(2)
    wide = build.call(4)
    binary.should eq(4)
    wide.should be < binary
  end

  it "finds nothing when no parameter influences the response" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80))
    names = ["alpha", "beta", "gamma", "delta", "epsilon"]
    findings = mine(backend, names, cfg)
    findings.should be_empty
  end

  it "suppresses reflection false positives on an echo endpoint (reflects any input)" do
    # An echo API reflects EVERY param, so naive reflection detection would report all
    # candidates. The reflect-all control must recognise this and yield no findings.
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), echo: true)
    names = ["alpha", "beta", "gamma", "secret", "delta", "epsilon", "zeta", "eta"]
    findings = mine(backend, names, cfg)
    findings.should be_empty
  end

  it "warns via the baseline event when the endpoint echoes any input" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), echo: true)
    base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = M::Engine.new(base, http2: false, names: ["a", "b"], backend: backend, config: cfg)
    warning = nil.as(String?)
    engine.run { |ev| warning = ev.warning if ev.is_a?(M::BaselineEvent) }
    warning.should_not be_nil
    warning.not_nil!.should contain("echoes")
  end

  it "emits a Done event and a baseline event" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80))
    base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = M::Engine.new(base, http2: false, names: ["a", "b"], backend: backend, config: cfg)
    saw_baseline = false
    saw_done = false
    engine.run do |ev|
      saw_baseline = true if ev.is_a?(M::BaselineEvent)
      saw_done = true if ev.is_a?(M::DoneEvent)
    end
    saw_baseline.should be_true
    saw_done.should be_true
  end

  it "mines every configured location in ONE pass, not one location after another" do
    # The scheduler runs all locations through a single work queue, so the mine is not
    # serialised per location and the tail of one bisection no longer idles the pool while
    # another location's untouched buckets wait behind a barrier. What must NOT change is
    # the verdict: the same name is still isolated at each location it applies to.
    backend = MultiLocationBackend.new(F::Origin.new("http", "h", 80), "secret")
    c = cfg
    c.locations = [M::Location::Query, M::Location::Headers]
    c.concurrency = 8
    names = ["alpha", "beta", "gamma", "secret", "delta", "epsilon", "zeta", "eta"]
    findings = mine(backend, names, c)
    findings.map(&.name).uniq.should eq(["secret"])
    findings.map(&.location).sort_by(&.value).should eq([M::Location::Query, M::Location::Headers])
    # Buckets from BOTH locations were in flight together — under the old per-location
    # loop the second location could not start until the first had finished entirely.
    backend.mixed_in_flight.should be_true
  end

  it "releases the send backend (the keep-alive pool's sockets) when the run ends" do
    backend = MultiLocationBackend.new(F::Origin.new("http", "h", 80), "secret")
    mine(backend, ["alpha", "secret"], cfg)
    backend.closed.should be_true
  end

  it "calibrates the baseline concurrently, and one at a time when the run is paced" do
    # Calibration is `stability_rounds + locations` round trips of dead air at the head of
    # every mine, and the probes do not depend on each other.
    c = cfg
    c.stability_rounds = 4
    c.concurrency = 4
    base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    backend = MultiLocationBackend.new(F::Origin.new("http", "h", 80), "secret")
    M::Baseline.new(backend, base, c).calibrate([M::Location::Query])
    backend.max_in_flight.should be > 1

    # …but a paced run asked for one request per interval, and the FIRST thing the target
    # sees from a mine must not be a burst of them.
    c.throttle_ms = 50
    paced = MultiLocationBackend.new(F::Origin.new("http", "h", 80), "secret")
    M::Baseline.new(paced, base, c).calibrate([M::Location::Query])
    paced.max_in_flight.should eq(1)
  end

  it "enforces max_requests as a hard cap that counts baseline calibration too" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: ["secret"])
    c = cfg
    c.max_requests = 2_i64 # < the 2 stability rounds + 1 control + mining a naive run would send
    names = (1..30).map { |i| "p#{i}" } + ["secret"]
    findings = mine(backend, names, c)
    # The 2 baseline stability rounds use up the whole cap; control-signal + all mining
    # sends are refused by the CappedBackend. Previously baseline bypassed the cap
    # entirely and mining overshot it by ~2x concurrency.
    backend.sent.should eq(2)
    findings.should be_empty
  end

  it "floors word/line tolerance proportionally to page size (not a fixed 3/2)" do
    # A large, perfectly stable page: calibration jitter is 0, so each tolerance is
    # its FLOOR. The floor must scale with page size, or a big page's natural word/line
    # churn during mining trips a false Words/Lines finding that the length band absorbs.
    body = (["word"] * 600).join("\n") # 600 words across 600 lines
    backend = FixedBodyBackend.new(F::Origin.new("http", "h", 80), body)
    base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    report = M::Baseline.new(backend, base, cfg).calibrate([M::Location::Query])
    report.words_tol.should be > 3 # was fixed 3; now max(3, 600//100) = 6
    report.lines_tol.should be > 2 # was fixed 2; now max(2, ~600//100)
  end

  it "does not overshoot max_requests under concurrency" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: ["secret"])
    c = cfg
    c.concurrency = 8
    c.max_requests = 12_i64
    names = (1..60).map { |i| "p#{i}" } + ["secret"]
    mine(backend, names, c)
    backend.sent.should be <= 12 # was ~cap + 2*concurrency
  end

  it "does not count max-requests cap refusals as errors (fix #19)" do
    # Regression: process_bucket used to count EVERY raw.error as @errors, including
    # CappedBackend's post-cap refusal — buckets already dispatched into the buffered
    # worker channel before the cap check fired. Under concurrency, that inflated
    # "errors" with pure cap-refusals rather than real network failures.
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: ["secret"])
    c = cfg
    c.concurrency = 8
    c.max_requests = 5_i64 # far below what baseline + mining 80 names would need
    names = (1..80).map { |i| "p#{i}" } + ["secret"]
    base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    engine = M::Engine.new(base, http2: false, names: names, backend: backend, config: c)
    done_progress = nil.as(M::Progress?)
    engine.run { |ev| done_progress = ev.progress if ev.is_a?(M::DoneEvent) }
    done_progress.should_not be_nil
    done_progress.not_nil!.errors.should eq(0)
  end

  describe "a wholly-refused run" do
    # `@errors` used to count refusals and throw the STRING away, so a scope-blocked sweep
    # ended "0 found · N sent · N errors" with the reason nowhere and `gori run mine` exiting
    # 0 — CI read that as "no hidden parameters". The engine stays surface-free; it just
    # retains the two facts a consumer needs to tell a verdict from a failure.
    it "retains the first reason and reports that nothing got through" do
      backend = BlockedBackend.new(F::Origin.new("http", "h", 80), "blocked by sandbox (out of scope)")
      base = "GET /api?a=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      engine = M::Engine.new(base, http2: false, names: ["alpha", "beta"], backend: backend, config: cfg)
      engine.run { }
      engine.first_error.should eq("blocked by sandbox (out of scope)")
      engine.successful_sends.should eq(0)
    end

    it "counts successes, so a run that got answers is not mistaken for a refused one" do
      backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: ["secret"])
      base = "GET /api?a=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      engine = M::Engine.new(base, http2: false, names: ["alpha", "secret"], backend: backend, config: cfg)
      engine.run { }
      engine.first_error.should be_nil
      engine.successful_sends.should be > 0
    end

    it "does not retry an exclude-rule refusal (Layer 2 is permanent)" do
      # permanent_refusal? used to list only CAP and SANDBOX — exclude burned retries and
      # the request cap for a refusal that cannot change between attempts.
      reason = Gori::Outbound::EXCLUDE_SWEEP_ERROR
      backend = BlockedBackend.new(F::Origin.new("http", "h", 80), reason)
      c = cfg
      c.retries = 5
      c.retry_pause = 0.milliseconds
      c.concurrency = 1
      c.stability_rounds = 1
      c.confirm_rounds = 1
      base = "GET /api?a=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      engine = M::Engine.new(base, http2: false, names: ["alpha"], backend: backend, config: c)
      engine.run { }
      # One send per planned attempt — never (1 + retries) per attempt.
      backend.sent.should be <= 4 # baseline + a few buckets, all single-shot
      # If exclude were retried, retries=5 would multiply every send by 6.
      backend.sent.should be < 12
      engine.first_error.should eq(reason)
    end
  end

  # Names the wordlist supplied that a location cannot carry. Dropping them is CORRECT — a
  # header/cookie name must be an RFC 7230 token, and `Content-Length`/`Host` would break
  # framing — but `total_names` sums the FILTERED sizes, so the drop surfaced nowhere: the
  # operator's only signal was that one wordlist produced "444 names" against the query and
  # "435 names" against headers, and only if they ran both and compared. `probe` publishes a
  # `skipped` count for exactly this reason.
  describe "#skipped_names" do
    wl_names = ["normalname", "my param", "x=y", "arr[]", "Content-Length", "semi;colon"]

    it "reports how many names each location cannot carry, and the pre-filter denominator" do
      c = cfg
      c.locations = [M::Location::Headers]
      base = "GET /api?a=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      engine = M::Engine.new(base, http2: false, names: wl_names,
        backend: HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: [] of String),
        config: c)
      engine.candidate_names.should eq(6)
      engine.skipped_names.should eq([{M::Location::Headers, 5}])
      engine.total_names.should eq(1_i64) # and the headline count agrees with the difference
    end

    # The complement: the query location accepts every one of those names (Inject
    # percent-encodes what needs it), so there is nothing to report and nothing is printed.
    it "reports nothing for a location that can carry every name" do
      c = cfg
      c.locations = [M::Location::Query]
      base = "GET /api?a=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      engine = M::Engine.new(base, http2: false, names: wl_names,
        backend: HiddenParamBackend.new(F::Origin.new("http", "h", 80), reflect: [] of String),
        config: c)
      engine.skipped_names.should be_empty
      engine.total_names.should eq(6_i64)
    end
  end
end
