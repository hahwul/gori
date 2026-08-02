require "../spec_helper"

private alias Q = Gori::Sequencer
private alias F = Gori::Fuzz

# Round 8 — `grep -rni grpc src/gori/{miner,discover,sequencer,probe}/` returned only two
# `tech_grpc` display labels in probe/issue.cr. Sequencer's live-replay collection reads
# `raw.response.try(&.status)` for `Sample#status`, and for gRPC the h2 `:status` is 200 BY
# DEFINITION — so a token-randomness collection replaying against a target that is actually
# denying every call (an expired/invalid session, say — the exact case an operator runs
# Sequencer to characterize) reported every sample as a healthy 200, with the real per-call
# outcome (`grpc-status`/`grpc-message` trailers) nowhere. `Fuzz::GrpcVerdict` is the same
# projection round 7 wired into the Fuzzer over `raw.head`.
private class GrpcCookieBackend < F::Backend
  getter origin : F::Origin

  def initialize(@origin : F::Origin, @code : Int32, @message : String?)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    head = String.build do |io|
      io << "HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\n"
      io << "Set-Cookie: SID=1000; Path=/\r\nContent-Length: 2\r\n"
      io << "grpc-status: #{@code}\r\n"
      io << "grpc-message: #{@message}\r\n" if @message
      io << "\r\n"
    end.to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, "ok".to_slice, resp, 500_i64)
  end
end

private def drain(engine : Q::Engine) : Array(Q::Sample)
  samples = [] of Q::Sample
  engine.run { |ev| samples << ev.sample if ev.is_a?(Q::SampleEvent) }
  samples
end

private def collect_one(backend : F::Backend) : Q::Sample
  config = Q::Config.new(mode: Q::Mode::LiveReplay,
    token_loc: Q::TokenLoc.cookie("SID"), goal: 1, concurrency: 1, retries: 0)
  req = "GET /pkg.Svc/Method HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  drain(Q::Engine.new(req, http2: false, backend: backend, config: config)).first
end

describe "sequence over gRPC" do
  it "carries the grpc-status/grpc-message trailers on the collected Sample, distinguishing denied from granted" do
    denied = collect_one(GrpcCookieBackend.new(F::Origin.new("http", "h", 80), 7, "nope; you may not"))
    denied.status.should eq(200) # the h2 status is 200 for BOTH — that is the whole point
    denied.grpc_status.should eq(7)
    denied.grpc_message.should eq("nope; you may not")

    granted = collect_one(GrpcCookieBackend.new(F::Origin.new("http", "h", 80), 0, nil))
    granted.status.should eq(200)
    granted.grpc_status.should eq(0)
    granted.grpc_message.should be_nil # an empty grpc-message is absent, not ""

    denied.grpc_status.should_not eq(granted.grpc_status)
  end

  # The reporting half: `--format jsonl` only renders the fields when present, so a
  # non-gRPC sample's JSON line is unchanged (the complement).
  it "emits grpc_status / grpc_status_name / grpc_message on the jsonl sample row, only when present" do
    s = Q::Sample.new(0, "tok", 200, 3, 500_i64, nil, grpc_status: 7, grpc_message: "nope; you may not")
    j = JSON.parse(Gori::CLI::Output.sequence_sample_json(s))
    j["grpc_status"].as_i.should eq(7)
    j["grpc_status_name"].as_s.should eq("PERMISSION_DENIED")
    j["grpc_message"].as_s.should eq("nope; you may not")

    plain = Q::Sample.new(1, "tok2", 200, 4, 500_i64, nil)
    Gori::CLI::Output.sequence_sample_json(plain).should_not contain("grpc")
  end
end
