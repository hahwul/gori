require "../spec_helper"
require "json"

private alias S = Gori::Sequencer::Stats
private alias P = Gori::Sequencer::Present
private alias TR = Gori::Sequencer::Stats::TestRow

# Deterministic hex tokens of `len` nibbles from a seeded PRNG (reproducible specs).
private def random_hex(count : Int32, len : Int32, seed : UInt64 = 4321_u64) : Array(String)
  rng = Random.new(seed)
  Array(String).new(count) { String.build { |io| len.times { io << "0123456789abcdef"[rng.rand(16)] } } }
end

# Present is documented as pure over a Stats::Report, so a synthetic report lets us drive
# exact field values / verdict labels / the empty-detail branch that analyze can't reach
# (every TestRow analyze emits carries a non-empty detail).
private def build_report(
  sample_count = 10, usable_count = 10,
  min_len = 32, max_len = 32, variable_length = false,
  charset_size = 16, charset_label = "lower-hex",
  bits_per_char = 4.0, effective_entropy = 128.0,
  uniqueness = 1.0, duplicate_count = 0, sequential = false,
  rating = S::Rating::Secure,
  tests = [] of TR,
) : S::Report
  S::Report.new(
    sample_count: sample_count, usable_count: usable_count,
    min_len: min_len, max_len: max_len, variable_length: variable_length,
    charset_size: charset_size, charset_label: charset_label,
    bits_per_char: bits_per_char, shannon_total: 0.0,
    effective_entropy: effective_entropy, length_entropy: 0.0,
    uniqueness: uniqueness, duplicate_count: duplicate_count,
    sequential: sequential, rating: rating, tests: tests,
    char_counts: [] of {UInt8, Int32}, len_hist: [] of Int32,
    len_min: min_len, len_max: max_len,
    per_pos_entropy: [] of Float64, bit_bias: [] of Float64)
end

# The exact top-level field set the JSON contract promises (anti-drift for CLI + MCP).
private JSON_FIELDS = %w[
  rating rationale sample_count usable_count
  effective_entropy_bits shannon_bits_per_char
  charset_size charset min_len max_len variable_length
  uniqueness duplicate_count sequential tests
]

describe Gori::Sequencer::Present do
  describe ".report_json" do
    it "emits exactly the documented top-level field set" do
      rep = S.analyze(random_hex(60, 32))
      keys = JSON.parse(P.report_json(rep)).as_h.keys
      # Membership + no extras is the contract (order is not part of the JSON contract).
      keys.sort.should eq(JSON_FIELDS.sort)
      keys.size.should eq(JSON_FIELDS.size)
    end

    it "preserves the source field order (informational, stable-across-drift)" do
      rep = S.analyze(random_hex(60, 32))
      JSON.parse(P.report_json(rep)).as_h.keys.should eq(JSON_FIELDS)
    end

    it "maps each top-level field to the matching Report accessor" do
      rep = S.analyze(random_hex(60, 32))
      j = JSON.parse(P.report_json(rep)).as_h
      j["rating"].as_s.should eq(rep.rating.label)
      j["rationale"].as_s.should eq(rep.rationale)
      j["sample_count"].as_i.should eq(rep.sample_count)
      j["usable_count"].as_i.should eq(rep.usable_count)
      j["effective_entropy_bits"].as_f.should eq(rep.effective_entropy)
      j["shannon_bits_per_char"].as_f.should eq(rep.bits_per_char)
      j["charset_size"].as_i.should eq(rep.charset_size)
      j["charset"].as_s.should eq(rep.charset_label)
      j["min_len"].as_i.should eq(rep.min_len)
      j["max_len"].as_i.should eq(rep.max_len)
      j["variable_length"].as_bool.should eq(rep.variable_length)
      j["uniqueness"].as_f.should eq(rep.uniqueness)
      j["duplicate_count"].as_i.should eq(rep.duplicate_count)
      j["sequential"].as_bool.should eq(rep.sequential)
    end

    it "renders 'tests' as an array of {name,value,detail,verdict}" do
      rep = S.analyze(random_hex(60, 32))
      tests = JSON.parse(P.report_json(rep))["tests"].as_a
      tests.size.should eq(rep.tests.size)
      tests.each do |t|
        t.as_h.keys.should eq(%w[name value detail verdict])
      end
    end

    it "emits verdict as the STRING label (not the enum ordinal) — incl. a FAIL row" do
      # A monotonically-increasing counter deterministically fails the Sequential test.
      rep = S.analyze((100_000..100_199).map(&.to_s))
      rep.tests.any?(&.verdict.fail?).should be_true # sanity: corpus really has a FAIL row

      tests = JSON.parse(P.report_json(rep))["tests"].as_a
      seq = tests.find { |t| t["name"].as_s == "Sequential" }.not_nil!
      # .as_s raising if this were a JSON number is itself the proof it is the label string.
      seq["verdict"].as_s.should eq("FAIL")

      labels = tests.map(&.["verdict"].as_s)
      labels.should contain("FAIL")
      labels.each { |l| %w[PASS WARN FAIL INFO].should contain(l) }
    end

    it "round-trips every Verdict to its label via a synthetic report" do
      tests = [
        TR.new("A", "1", "d", S::Verdict::Pass),
        TR.new("B", "2", "d", S::Verdict::Warn),
        TR.new("C", "3", "d", S::Verdict::Fail),
        TR.new("D", "4", "d", S::Verdict::Info),
      ]
      verdicts = JSON.parse(P.report_json(build_report(tests: tests)))["tests"].as_a.map(&.["verdict"].as_s)
      verdicts.should eq(%w[PASS WARN FAIL INFO])
    end

    it "produces the documented empty-report shape for no usable tokens" do
      rep = S.analyze(["", ""])
      j = JSON.parse(P.report_json(rep)).as_h
      j["rating"].as_s.should eq("CRITICAL")
      j["sample_count"].as_i.should eq(2)
      j["usable_count"].as_i.should eq(0)
      j["rationale"].as_s.should eq("no usable tokens")

      tests = j["tests"].as_a
      tests.size.should eq(1)
      tests[0]["name"].as_s.should eq("Samples")
      tests[0]["value"].as_s.should eq("0")
      tests[0]["detail"].as_s.should eq("no usable tokens")
      tests[0]["verdict"].as_s.should eq("INFO")
    end

    it "stays valid parseable JSON for adversarial control-byte / invalid-UTF-8 tokens" do
      # Bytes outside 0x20..0x7e force classify → "binary"; construct them so a seed tweak
      # can't silently flip the charset.
      rng = Random.new(11_u64)
      tokens = Array(String).new(40) do
        String.new(Bytes.new(16) { rng.rand(256).to_u8 })
      end
      tokens << String.new(Bytes[0x00_u8, 0x01_u8, 0xff_u8, 0x80_u8, 0x1f_u8, 0x7f_u8, 0xfe_u8, 0x0a_u8])

      rep = S.analyze(tokens)
      rep.charset_label.should eq("binary")

      json = P.report_json(rep)
      parsed = JSON.parse(json) # must not raise
      parsed["charset"].as_s.should eq("binary")
      # The raw (possibly non-UTF-8) token bytes never leak into the JSON — only ASCII stats.
      parsed["tests"].as_a.empty?.should be_false
    end

    it "stays valid JSON for CJK / emoji multibyte tokens" do
      tokens = ["안녕하세요", "世界世界", "🔥🔥🔥", "héllo", "안녕世界🔥"] * 8
      rep = S.analyze(tokens)
      parsed = JSON.parse(P.report_json(rep))
      parsed.as_h.keys.sort!.should eq(JSON_FIELDS.sort)
    end

    it "stays valid JSON for a single-token corpus" do
      rep = S.analyze(["only-one"])
      j = JSON.parse(P.report_json(rep)).as_h
      j["sample_count"].as_i.should eq(1)
      j["usable_count"].as_i.should eq(1)
      j.keys.sort!.should eq(JSON_FIELDS.sort)
    end
  end

  describe ".report_text" do
    it "uses the fixed labels for a fixed-length corpus" do
      rep = S.analyze(random_hex(60, 32))
      text = P.report_text(rep)
      text.should contain("rating:    ")
      text.should contain("samples:   60 usable / 60 total")
      text.should contain("entropy:   ")
      text.should contain("charset:   16 (lower-hex)")
      text.should contain("length:    32 (fixed)")
      text.should contain("unique:    0 duplicate(s)")
      text.should contain("\ntests:\n")
    end

    it "renders variable length as 'MIN-MAX (variable)'" do
      rep = S.analyze(["abcd", "abcde", "abcdef"])
      text = P.report_text(rep)
      text.should contain("length:    4-6 (variable)")
    end

    it "renders fixed length as 'MIN (fixed)'" do
      rep = S.analyze(["abcd", "abcd", "abcd"])
      text = P.report_text(rep)
      text.should contain("length:    4 (fixed)")
    end

    it "formats the empty-report tests row as verdict.ljust(5) name.ljust(14) value (detail)" do
      rep = S.analyze(["", ""])
      text = P.report_text(rep)
      text.should contain("rating:    CRITICAL  (no usable tokens)")
      text.should contain("samples:   0 usable / 2 total")
      text.should contain("charset:   0 (—)")
      text.should contain("length:    0 (fixed)")
      # 2 spaces, "INFO"+1 pad, +1 sep, "Samples"+7 pad, +1 sep, value, 2 spaces + (detail).
      text.should contain("  INFO  Samples        0  (no usable tokens)")
    end

    it "omits the parenthetical when a test row detail is empty (synthetic)" do
      rep = build_report(tests: [TR.new("NoDetail", "val", "", S::Verdict::Pass)])
      line = P.report_text(rep).lines.find(&.includes?("NoDetail")).not_nil!
      line.should eq("  PASS  NoDetail       val")
      line.should_not contain("(")
    end

    it "includes the parenthetical when a test row detail is non-empty (synthetic)" do
      rep = build_report(tests: [TR.new("WithDetail", "val", "some detail", S::Verdict::Warn)])
      line = P.report_text(rep).lines.find(&.includes?("WithDetail")).not_nil!
      line.should eq("  WARN  WithDetail     val  (some detail)")
    end

    it "does not raise on an all-identical corpus with zero entropy / bits (round of zero)" do
      rep = S.analyze(Array.new(30, "aaaaaaaa"))
      rep.effective_entropy.should eq(0.0)
      rep.bits_per_char.should eq(0.0)
      text = P.report_text(rep)
      text.should contain("entropy:   0.0 bits effective · 0.0 bits/char")
      text.should contain("unique:    29 duplicate(s)")
    end

    it "does not raise for adversarial control-byte tokens" do
      rng = Random.new(99_u64)
      tokens = Array(String).new(30) { String.new(Bytes.new(12) { rng.rand(256).to_u8 }) }
      tokens << String.new(Bytes[0x00_u8, 0xff_u8, 0x01_u8, 0x7f_u8])
      text = P.report_text(S.analyze(tokens))
      text.should contain("rating:    ")
      text.should contain("charset:   ")
    end
  end
end
