require "../../spec_helper"
require "../../../src/gori/repeater/timing"

private alias Timing = Gori::Repeater::Timing

# A side with no responses has no distribution: `Stats` fills it with zeros, which the JSON
# used to emit as a 0µs median — and `median_gap_us` as the other side's median, a gap
# nothing measured. Both surfaces (MCP `timing_requests`, `gori run repeater timing`) print
# this one emitter.
describe Gori::Repeater::Timing::Present do
  it "emits null for an empty side's stats and for the gap" do
    samples = Array.new(4) { Timing::Stats::Sample.new(120_i64, nil) }
    rep = Timing::Stats.analyze(samples)
    json = JSON.parse(Timing::Present.report_json(rep, Timing::Present::Subject.new(a_label: "a", b_label: "b")))

    json["median_gap_us"].raw.should be_nil
    b = json["variants"]["b"]
    b["n"].as_i.should eq(0)
    %w[min_us q1_us median_us q3_us max_us].each { |k| b[k].raw.should be_nil }
    json["variants"]["a"]["median_us"].as_f.should eq(120.0)
  end

  it "keeps the numbers when both sides answered" do
    samples = Array.new(4) { Timing::Stats::Sample.new(150_i64, 100_i64) }
    json = JSON.parse(Timing::Present.report_json(Timing::Stats.analyze(samples),
      Timing::Present::Subject.new(a_label: "a", b_label: "b")))
    json["median_gap_us"].as_f.should eq(50.0)
    json["variants"]["b"]["min_us"].as_i.should eq(100)
  end
end
