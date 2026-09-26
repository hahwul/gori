require "../spec_helper"
require "../../src/gori/repeater/timing"
require "socket"

private alias Timing = Gori::Repeater::Timing
private alias R = Gori::Repeater

# An h1 origin that accepts connections repeatedly and delays the reply for one path, so that
# variant on `slow_path` is consistently slower than the other — the differential signal.
private def start_delayed_origin(slow_path : String, delay : Time::Span) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn_with(conn) do |c|
        head = Gori::Proxy::Codec::Http1.read_head(c)
        line = head ? String.new(head).lines.first? : nil
        sleep delay if line && line.includes?(slow_path)
        body = "ok"
        c << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        c.flush
        c.close rescue nil
      end
    end
  rescue
  end
  port
end

private def build_pair_plan(port : Int32, path_a : String, path_b : String) : R::Plan
  wires = [
    "GET #{path_a} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
    "GET #{path_b} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
  ]
  opts = R::PlanOptions.new(wires, target: "http://127.0.0.1:#{port}", verify: false)
  R::Plan.build(opts, ungated_outbound)
end

describe Gori::Repeater::Timing do
  it "rejects a plan that is not exactly a pair" do
    plan = build_pair_plan(1, "/a", "/b")
    single = R::Plan.build(R::PlanOptions.new(["GET /x HTTP/1.1\r\nHost: h\r\n\r\n".to_slice], target: "http://h"), ungated_outbound)
    expect_raises(ArgumentError, /exactly two/) { Timing.run(single, iterations: 2) }
    plan.requests.size.should eq(2)
  end

  describe "race mode (h1 last-byte-sync)" do
    it "finds A consistently slower when its path is delayed" do
      port = start_delayed_origin("/slow", 6.milliseconds)
      plan = build_pair_plan(port, "/slow", "/fast")
      rep = Timing.run(plan, iterations: 30, mode: Timing::Mode::Race, warmup: 1)
      rep.pairs_valid.should be >= 20
      rep.verdict.should eq(Timing::Stats::Verdict::ASlower)
      rep.a.median.should be > rep.b.median
    end
  end

  describe "interleaved mode (sequential, alternating order)" do
    it "still finds A slower and alternates first-mover each iteration" do
      port = start_delayed_origin("/slow", 6.milliseconds)
      plan = build_pair_plan(port, "/slow", "/fast")
      rep = Timing.run(plan, iterations: 30, mode: Timing::Mode::Interleaved, warmup: 1)
      rep.pairs_valid.should be >= 20
      rep.verdict.should eq(Timing::Stats::Verdict::ASlower)
    end
  end

  it "honours the cancel closure" do
    port = start_delayed_origin("/slow", 1.milliseconds)
    plan = build_pair_plan(port, "/slow", "/fast")
    stop = false
    seen = 0
    rep = Timing.run(plan, iterations: 500, mode: Timing::Mode::Race, warmup: 0,
      cancel: -> { stop },
      progress: ->(n : Int32) { seen = n; stop = true if n >= 3 })
    rep.iterations.should be < 500
    seen.should be <= 4
  end
end
