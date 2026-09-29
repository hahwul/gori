require "../spec_helper"

# A payload set read from the project's captured data, through `Fuzz::Plan.build` (#1352). The
# plan builder is where a store is read for a run, so what these pin is what every surface gets:
# the resolved size is the preflight count, the source composes with the other sets in every
# mode and goes through the same processing pipeline and position encoding, a run with no
# project to read is refused by name, and an empty source is a refusal, not a clean 0-request run.
private alias F = Gori::Fuzz
private alias PF = Gori::PayloadFrom

private CLOCK = [1_700_000_000_000_000_i64]

private def seed(store : Gori::Store, target : String, host = "api.test") : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443, method: "GET", target: target,
    http_version: "HTTP/1.1", head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ok".to_slice))
  id
end

private def source(descriptor : String, policy : PF::Policy = PF::Policy.new) : F::ProjectSource
  F::ProjectSource.new(PF.parse(descriptor)).with_policy(policy)
end

private def options(sources : Array(F::PayloadSource), store : Gori::Store?, *, template = "GET /find?term=§x§ HTTP/1.1\r\nHost: t.test\r\n\r\n",
                    mode = F::Mode::Sniper, processors = [] of F::Processor) : F::PlanOptions
  F::PlanOptions.new(template, target: "https://t.test", sources: sources, processors: processors,
    config: F::Config.new(mode: mode), project: store)
end

private def payloads_of(plan : F::Plan) : Array(String)
  out = [] of String
  plan.generator.each { |j| out << j.payloads.first }
  out
end

describe Gori::Fuzz::ProjectSource do
  it "is resolved by Plan.build, and its size is the run's preflight count" do
    with_store do |store|
      seed(store, "/a?alpha=1&beta=2")
      seed(store, "/b?gamma=3")
      plan = F::Plan.build(options([source("param-names")] of F::PayloadSource, store), ungated_outbound)
      plan.total.should eq(3_i64)                             # one position × three names
      payloads_of(plan).should eq(["gamma", "alpha", "beta"]) # newest flow first
      plan.payload_reports.size.should eq(1)
      plan.payload_reports.first.values.should eq(3)
      plan.payload_reports.first.flows_scanned.should eq(2)
    end
  end

  it "composes with the other sets in a per-position mode, in the order given" do
    with_store do |store|
      seed(store, "/a?one=1&two=2")
      template = "GET /find?a=§x§&b=§y§ HTTP/1.1\r\nHost: t.test\r\n\r\n"
      sources = [F::InlineList.new(["u1", "u2"]), source("param-names")] of F::PayloadSource
      plan = F::Plan.build(options(sources, store, template: template, mode: F::Mode::Pitchfork), ungated_outbound)
      pairs = [] of Array(String)
      plan.generator.each { |j| pairs << j.payloads }
      pairs.should eq([["u1", "one"], ["u2", "two"]])
      plan.payload_reports.map(&.source).should eq(["param-names"])
    end
  end

  it "runs through the same processing pipeline as any set" do
    with_store do |store|
      seed(store, "/a?alpha=1")
      plan = F::Plan.build(options([source("param-names")] of F::PayloadSource, store,
        processors: [F::Prefix.new("x-"), F::Case.new(:upper)] of F::Processor), ungated_outbound)
      payloads_of(plan).should eq(["X-ALPHA"])
    end
  end

  it "follows the position's own encoding: a query position percent-encodes a captured value once" do
    with_store do |store|
      seed(store, "/a?q=hello%20world%26x")
      plan = F::Plan.build(options([source("param-values")] of F::PayloadSource, store), ungated_outbound)
      wire = [] of String
      plan.generator.each { |j| wire << String.new(j.bytes).lines.first }
      # the captured value is `hello world&x` (decoded once, by Params); the query position encodes it once
      wire.should eq(["GET /find?term=hello%20world%26x HTTP/1.1"])
    end
  end

  it "reads nothing at construction: the plan builder is the one that reads the project" do
    src = source("param-names")
    src.report.should be_nil
    expect_raises(PF::Error, /was never resolved/) { src.size }
    expect_raises(PF::Error, /was never resolved/) { src.open_iterator }
  end

  it "refuses a source with no project to read, naming it" do
    ex = expect_raises(PF::Error, /reads the project's captured data, and this run has no project to read/) do
      F::Plan.build(options([source("host:api.test param-names")] of F::PayloadSource, nil), ungated_outbound)
    end
    ex.message.to_s.should contain("host:api.test param-names")
  end

  it "refuses an empty source rather than run zero requests, and says why" do
    with_store do |store|
      seed(store, "/a?alpha=1", host: "one.test")
      ex = expect_raises(PF::Error, /produced no values/) do
        F::Plan.build(options([source("host:nowhere.test param-names")] of F::PayloadSource, store), ungated_outbound)
      end
      ex.message.to_s.should contain("0 flows")
    end
  end

  it "says an all-withheld source was withheld, not empty of data" do
    with_store do |store|
      seed(store, "/a?password=hunter2&token=abc")
      ex = expect_raises(PF::Error, /produced no values.*2 sensitive skipped/) do
        F::Plan.build(options([source("param-values")] of F::PayloadSource, store), ungated_outbound)
      end
      ex.message.to_s.should_not contain("hunter2")
    end
  end

  it "reads the sensitive values only under the opt-in, and the report carries the policy" do
    with_store do |store|
      seed(store, "/a?password=hunter2")
      plan = F::Plan.build(options([source("param-values", PF::Policy.new(include_sensitive: true))] of F::PayloadSource, store), ungated_outbound)
      payloads_of(plan).should eq(["hunter2"])
      plan.payload_reports.first.policy.should eq("sensitive-included")
    end
  end

  it "resolves once per plan, and a NEW plan reads the project as it is now" do
    with_store do |store|
      seed(store, "/a?alpha=1")
      src = source("param-names")
      plan = F::Plan.build(options([src] of F::PayloadSource, store), ungated_outbound)
      plan.total.should eq(1_i64)
      seed(store, "/b?beta=1")
      src.resolve!(store).values.should eq(1) # already resolved: the same answer
      fresh = F::Plan.build(options([source("param-names")] of F::PayloadSource, store), ungated_outbound)
      fresh.total.should eq(2_i64)
    end
  end

  it "counts against a max_requests cap like any set: the preflight sees the resolved size" do
    with_store do |store|
      20.times { |i| seed(store, "/a?p#{i}=1") }
      plan = F::Plan.build(options([source("param-names")] of F::PayloadSource, store), ungated_outbound)
      plan.total.should eq(20_i64)
      F.request_bound(plan.total, 5_i64).should eq(5_i64)
    end
  end

  it "skips reading for a race, which draws from no set" do
    with_store do |store|
      seed(store, "/a?alpha=1")
      src = source("param-names")
      opts = F::PlanOptions.new("GET /x HTTP/1.1\r\nHost: t.test\r\n\r\n", target: "https://t.test",
        sources: [src] of F::PayloadSource, config: F::Config.new(race_count: 2), project: store)
      plan = F::Plan.build(opts, ungated_outbound)
      plan.payload_reports.should be_empty
      src.report.should be_nil
    end
  end

  it "reports a plan with no project source as having none" do
    plan = F::Plan.build(options([F::InlineList.new(["a"])] of F::PayloadSource, nil), ungated_outbound)
    plan.payload_reports.should be_empty
  end
end
