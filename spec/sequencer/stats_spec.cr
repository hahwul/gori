require "../spec_helper"

private alias S = Gori::Sequencer::Stats

# Deterministic hex tokens of `len` nibbles from a seeded PRNG (reproducible specs).
private def random_hex(count : Int32, len : Int32, seed : UInt64 = 1234_u64) : Array(String)
  rng = Random.new(seed)
  Array(String).new(count) { String.build { |io| len.times { io << "0123456789abcdef"[rng.rand(16)] } } }
end

describe Gori::Sequencer::Stats do
  it "rates a large high-entropy hex corpus as strong with no duplicates" do
    report = S.analyze(random_hex(300, 32))
    report.usable_count.should eq(300)
    report.duplicate_count.should eq(0)
    report.sequential.should be_false
    report.charset_label.should eq("lower-hex")
    report.effective_entropy.should be > 110.0 # ~32 positions × 4 bits
    report.rating.value.should be >= S::Rating::Moderate.value
    report.tests.find { |t| t.name == "Uniqueness" }.not_nil!.verdict.should eq(S::Verdict::Pass)
  end

  it "flags an incrementing counter as sequential and Critical" do
    report = S.analyze((100000..100199).map(&.to_s))
    report.sequential.should be_true
    report.rating.should eq(S::Rating::Critical)
    report.tests.find { |t| t.name == "Sequential" }.not_nil!.verdict.should eq(S::Verdict::Fail)
  end

  it "fails uniqueness and rates Critical when a token repeats" do
    tokens = random_hex(80, 32) + [random_hex(1, 32).first]
    tokens << tokens[0] # force a duplicate
    report = S.analyze(tokens)
    report.duplicate_count.should be >= 1
    report.rating.should eq(S::Rating::Critical)
    report.tests.find { |t| t.name == "Uniqueness" }.not_nil!.verdict.should eq(S::Verdict::Fail)
  end

  it "rates an all-identical corpus Critical with zero per-position entropy" do
    report = S.analyze(Array.new(50, "SAMESAMESAME1234"))
    report.duplicate_count.should eq(49)
    report.rating.should eq(S::Rating::Critical)
    report.per_pos_entropy.all? { |e| e == 0.0 }.should be_true
  end

  it "grades a short-token corpus as weak (low effective entropy)" do
    report = S.analyze(random_hex(120, 8)) # 8 hex → ~32 bits
    report.effective_entropy.should be < 40.0
    report.rating.value.should be <= S::Rating::Weak.value
  end

  it "clamps the rating below Secure for a tiny sample" do
    report = S.analyze(random_hex(6, 32))
    report.usable_count.should eq(6)
    report.rating.value.should be <= S::Rating::Moderate.value
  end

  it "returns an empty report for no usable tokens" do
    report = S.analyze(["", "", ""])
    report.usable_count.should eq(0)
    report.rating.should eq(S::Rating::Critical)
  end

  it "detects a variable-length corpus" do
    report = S.analyze(["abcd", "abcde", "abcdef"])
    report.variable_length.should be_true
    report.min_len.should eq(4)
    report.max_len.should eq(6)
  end
end
