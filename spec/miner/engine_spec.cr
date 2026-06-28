require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# A backend that simulates a server with hidden parameters. It parses the query string
# of each request; if a "magic" param is present it changes the response accordingly:
#   - REFLECT params echo their (canary) value in the body.
#   - GROW params append extra bytes to the body (a metric/length signal, no reflection).
# Everything else returns a stable baseline body.
private class HiddenParamBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @reflect : Array(String) = [] of String,
                 @grow : Array(String) = [] of String)
  end

  def send(bytes : Bytes) : Gori::Replay::Result
    @sent += 1
    params = query_params(bytes)
    body = "BASELINE BODY CONTENT"
    @reflect.each { |name| (v = params[name]?) && (body += " reflected=#{v}") }
    @grow.each { |name| params.has_key?(name) && (body += " XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX") }
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

  private def ok(body : String) : Gori::Replay::Result
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Replay::Result.new(head, body.to_slice, resp, 1000_i64)
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

  it "finds nothing when no parameter influences the response" do
    backend = HiddenParamBackend.new(F::Origin.new("http", "h", 80))
    names = ["alpha", "beta", "gamma", "delta", "epsilon"]
    findings = mine(backend, names, cfg)
    findings.should be_empty
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
end
