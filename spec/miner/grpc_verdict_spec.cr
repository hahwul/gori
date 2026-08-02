require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# Round 8 — `grep -rni grpc src/gori/{miner,discover,sequencer,probe}/` returned only two
# `tech_grpc` display labels in probe/issue.cr. Miner (like Fuzz before round 7) reads only
# the h2 `:status`, which is 200 BY DEFINITION for every gRPC response — so a mine against a
# target that PERMISSION_DENIED-ed every candidate but granted the hidden one looked exactly
# like a mine against a target with no gRPC awareness at all: the isolated Finding carried a
# `status` of 200 either way. The real per-candidate outcome lives in the `grpc-status` /
# `grpc-message` trailers the confirming round's response head carries (`Fuzz::GrpcVerdict`,
# the same projection round 7 wired into the Fuzzer).
#
# A backend simulating a gRPC service: every candidate except one magic name is denied
# (grpc-status 7) with a short body; the magic name is granted (grpc-status 0) AND its body
# grows, which is the metric signal `Miner.decide` isolates via bisection. So the Finding this
# produces is exactly the shape a real "hidden parameter that bypasses an authz check on a
# gRPC endpoint" investigation looks for — and the DEFECT was that its `grpc_status` was
# unreachable no matter how the candidate was isolated.
private class GrpcHiddenParamBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @grant : String)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    params = query_params(bytes)
    granted = params.has_key?(@grant)
    body = granted ? "OK" + "X" * 40 : "OK"
    code = granted ? 0 : 7
    msg = granted ? nil : "nope; you may not"
    head = String.build do |io|
      io << "HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\n"
      io << "Content-Length: #{body.bytesize}\r\ngrpc-status: #{code}\r\n"
      io << "grpc-message: #{msg}\r\n" if msg
      io << "\r\n"
    end.to_slice
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

private def mine(backend : F::Backend, names : Array(String), config : M::Config) : Array(M::Finding)
  base = "GET /pkg.Svc/Method HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  engine = M::Engine.new(base, http2: false, names: names, backend: backend, config: config)
  findings = [] of M::Finding
  engine.run do |ev|
    findings << ev.finding if ev.is_a?(M::FindingEvent)
  end
  findings
end

describe "mine over gRPC" do
  it "carries the confirming round's grpc-status/grpc-message onto the isolated Finding" do
    backend = GrpcHiddenParamBackend.new(F::Origin.new("http", "h", 80), "secret")
    names = ["alpha", "beta", "gamma", "secret", "delta", "epsilon", "zeta", "eta"]
    findings = mine(backend, names, cfg)

    secret = findings.find { |f| f.name == "secret" }
    raise "expected a finding for 'secret'" unless secret
    secret.status.should eq(200) # the h2 status is 200 for the granted call too — the whole point
    secret.grpc_status.should eq(0)
    secret.grpc_message.should be_nil # an empty grpc-message is absent, not ""

    findings.map(&.name).should_not contain("alpha")
  end

  # F1, the reporting half: CLI JSON/text and MCP JSON only render the field when present,
  # so a non-gRPC mine's rows are unchanged (the complement below).
  it "emits grpc_status / grpc_status_name / grpc_message on the CLI and MCP rows, only when present" do
    f = M::Finding.new("secret", M::Location::Query, M::Evidence::Length, M::Confidence::Confirmed,
      nil, 200, 40_i64, grpc_status: 7, grpc_message: "nope; you may not")
    j = JSON.parse(Gori::CLI::Output.mine_row_json(f))
    j["grpc_status"].as_i.should eq(7)
    j["grpc_status_name"].as_s.should eq("PERMISSION_DENIED")
    j["grpc_message"].as_s.should eq("nope; you may not")
    text = Gori::CLI::Output.mine_row_text(f)
    text.should contain("grpc 7 PERMISSION_DENIED")
    text.should contain("nope; you may not")

    # Complement: an ordinary (non-gRPC) finding is byte-identical to what it was.
    plain = M::Finding.new("secret", M::Location::Query, M::Evidence::Length, M::Confidence::Confirmed, nil, 200, 40_i64)
    Gori::CLI::Output.mine_row_json(plain).should_not contain("grpc")
    Gori::CLI::Output.mine_row_text(plain).should_not contain("grpc")
  end
end
