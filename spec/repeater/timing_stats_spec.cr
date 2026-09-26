require "../spec_helper"
require "../../src/gori/repeater/timing"

private alias Stats = Gori::Repeater::Timing::Stats

private def sample(a : Int64?, b : Int64?)
  Stats::Sample.new(a, b)
end

# A run of `n` pairs where A is `gap` µs slower than B on every pair (both jitter by `jitter`).
private def a_slower_samples(n : Int32, base : Int64 = 100_i64, gap : Int64 = 50_i64, jitter : Int64 = 0_i64) : Array(Stats::Sample)
  Array(Stats::Sample).new(n) do |i|
    j = jitter == 0 ? 0_i64 : (i % (jitter.to_i * 2 + 1)).to_i64 - jitter
    sample(base + gap + j, base + j)
  end
end

describe Gori::Repeater::Timing::Stats do
  describe ".percentile" do
    it "interpolates linearly (R-7) over an ascending array" do
      Stats.percentile([1, 2, 3, 4].map(&.to_i64), 0.5).should eq(2.5)
      Stats.percentile([1, 2, 3, 4, 5].map(&.to_i64), 0.5).should eq(3.0)
      Stats.percentile([10, 20, 30, 40].map(&.to_i64), 0.25).should be_close(17.5, 0.001)
      Stats.percentile([10, 20, 30, 40].map(&.to_i64), 0.75).should be_close(32.5, 0.001)
    end

    it "handles the degenerate sizes" do
      Stats.percentile([] of Int64, 0.5).should eq(0.0)
      Stats.percentile([7_i64], 0.5).should eq(7.0)
    end
  end

  describe ".histogram" do
    it "bins left-inclusive with the max in the last bucket" do
      Stats.histogram([1, 5, 9].map(&.to_i64), 4, 1.0, 9.0).should eq([1, 0, 1, 1])
    end

    it "puts everything in bin 0 when min==max" do
      Stats.histogram([5, 5, 5].map(&.to_i64), 4, 5.0, 5.0).should eq([3, 0, 0, 0])
    end
  end

  describe ".analyze" do
    it "calls A consistently slower when it always trails, with a low p-value" do
      rep = Stats.analyze(a_slower_samples(40, jitter: 5_i64))
      rep.verdict.should eq(Stats::Verdict::ASlower)
      rep.a_slower.should eq(40)
      rep.b_slower.should eq(0)
      rep.a_slower_frac.should eq(1.0)
      rep.p_value.should be < 0.01
      rep.median_gap_us.should be > 0.0
      rep.a.median.should be > rep.b.median
    end

    it "calls B slower symmetrically" do
      samples = a_slower_samples(40).map { |s| sample(s.b_us, s.a_us) }
      rep = Stats.analyze(samples)
      rep.verdict.should eq(Stats::Verdict::BSlower)
      rep.b_slower.should eq(40)
    end

    it "reports no measurable difference when the order is an even coin flip" do
      samples = Array(Stats::Sample).new(60) do |i|
        i.even? ? sample(100_i64, 110_i64) : sample(110_i64, 100_i64)
      end
      rep = Stats.analyze(samples)
      rep.verdict.should eq(Stats::Verdict::NoDifference)
      rep.p_value.should be > 0.01
    end

    it "clamps to inconclusive below the small-sample floor even with a clean signal" do
      rep = Stats.analyze(a_slower_samples(Stats::SMALL_SAMPLE - 1))
      rep.verdict.should eq(Stats::Verdict::Inconclusive)
    end

    it "is inconclusive when no pair had both responses" do
      rep = Stats.analyze([sample(nil, 100_i64), sample(200_i64, nil)])
      rep.verdict.should eq(Stats::Verdict::Inconclusive)
      rep.pairs_valid.should eq(0)
      rep.rationale.should contain("no pair")
    end

    it "drops a member that errored from that variant's quartiles but keeps the other" do
      rep = Stats.analyze([sample(100_i64, nil), sample(200_i64, 50_i64)])
      rep.a.n.should eq(2)
      rep.b.n.should eq(1)
      rep.pairs_valid.should eq(1) # only the second pair had both
    end

    it "keeps the rationale's percentage and count on the same (decisive) denominator when ties exist" do
      # 23 A-slower, 2 B-slower, 5 ties → decisive = 25, pairs_valid = 30.
      samples = Array(Stats::Sample).new(0)
      23.times { samples << sample(200_i64, 100_i64) }
      2.times { samples << sample(100_i64, 200_i64) }
      5.times { samples << sample(150_i64, 150_i64) }
      rep = Stats.analyze(samples)
      rep.pairs_valid.should eq(30)
      rep.decisive.should eq(25)
      rep.verdict.should eq(Stats::Verdict::ASlower)
      # The sentence names the decisive denominator, so "23/25" is consistent with its 92%.
      rep.rationale.should contain("23/25")
      rep.rationale.should_not contain("/30")
    end

    it "does not collapse the shared histogram scale to 0 when one variant never answered" do
      samples = Array(Stats::Sample).new(30) { |i| sample((5000 + i).to_i64, nil) }
      rep = Stats.analyze(samples)
      rep.b.n.should eq(0)
      rep.hist_min.should eq(rep.a.min) # not 0 — the empty B is skipped
      rep.hist_min.should be > 0_i64
      rep.hist_max.should eq(rep.a.max)
    end

    it "counts identical durations as ties, not a win for either side" do
      rep = Stats.analyze(Array(Stats::Sample).new(30) { sample(100_i64, 100_i64) })
      rep.ties.should eq(30)
      rep.a_slower.should eq(0)
      rep.b_slower.should eq(0)
      rep.verdict.should eq(Stats::Verdict::NoDifference)
    end
  end
end
