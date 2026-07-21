require "../spec_helper"

private alias S = Gori::Sequencer::Stats

# Deterministic hex tokens of `len` nibbles from a seeded PRNG (reproducible specs).
private def random_hex(count : Int32, len : Int32, seed : UInt64 = 1234_u64) : Array(String)
  rng = Random.new(seed)
  Array(String).new(count) { String.build { |io| len.times { io << "0123456789abcdef"[rng.rand(16)] } } }
end

# The `detail` string of the Sequential test row for a given token set — the human-readable
# classification ("constant step N", "monotonic up/down", "non-monotonic", "corr=…", "n/a").
private def seq_detail(tokens : Array(String)) : String
  S.analyze(tokens).tests.find { |t| t.name == "Sequential" }.not_nil!.detail
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

  # ── classify: byte-set → charset label ──────────────────────────────────────────

  it "labels each ASCII byte-set family via the classify precedence chain" do
    # digits + uppercase A–F only → upper-hex (lower-hex requires a..f, so 'A' skips it)
    S.analyze(Array.new(5, "A1B2C3")).charset_label.should eq("upper-hex")
    # both cases of hex present → neither lower- nor upper-hex, but still hex
    S.analyze(Array.new(5, "aF3bC9")).charset_label.should eq("hex")
    # base64url-only markers ('-' / '_') plus alnum → base64url (a '-' is not hex)
    S.analyze(Array.new(5, "gZ-_09")).charset_label.should eq("base64url")
    # base64-only markers ('+' / '/') → base64 (a '+' is not allowed in base64url)
    S.analyze(Array.new(5, "ab+/CD09")).charset_label.should eq("base64")
    # printable ASCII with punctuation outside the base64 set → ascii
    S.analyze(Array.new(5, "hi! .#")).charset_label.should eq("ascii")
  end

  it "classifies any multibyte / control / invalid-UTF-8 token as binary (byte-based)" do
    S.analyze(Array.new(5, "안녕세계")).charset_label.should eq("binary")
    S.analyze(Array.new(5, "😀🎉")).charset_label.should eq("binary")
    S.analyze(Array.new(5, "a\u0001b")).charset_label.should eq("binary") # 0x01 control byte
    S.analyze(Array.new(5, String.new(Bytes[0xff_u8, 0xfe_u8, 0x80_u8]))).charset_label.should eq("binary")
  end

  # ── detect_sequential: numeric fast path ────────────────────────────────────────

  it "labels a constant-step numeric counter with its step" do
    report = S.analyze(["100", "102", "104"])
    report.sequential.should be_true
    seq_detail(["100", "102", "104"]).should eq("constant step 2")
  end

  it "labels a variable-step decreasing run 'monotonic down'" do
    report = S.analyze(["100", "98", "95"])
    report.sequential.should be_true
    seq_detail(["100", "98", "95"]).should eq("monotonic down")
  end

  it "labels a variable-step increasing run 'monotonic up'" do
    report = S.analyze(["1", "3", "6"])
    report.sequential.should be_true
    seq_detail(["1", "3", "6"]).should eq("monotonic up")
  end

  it "reports 'non-monotonic' and not-sequential for an up-then-down numeric run" do
    report = S.analyze(["1", "5", "3"])
    report.sequential.should be_false
    seq_detail(["1", "5", "3"]).should eq("non-monotonic")
  end

  # ── detect_sequential: 18-digit boundary guard against Int64 overflow ────────────

  it "keeps exactly-18-digit tokens on the numeric fast path" do
    eighteen = ["100000000000000000", "100000000000000001", "100000000000000002"]
    eighteen.each(&.size.should(eq(18)))
    report = S.analyze(eighteen)
    report.sequential.should be_true
    seq_detail(eighteen).should eq("constant step 1")
  end

  it "sends 19-digit numeric tokens down the general path without an Int64 overflow raise" do
    # Each value exceeds Int64::MAX (9_223_372_036_854_775_807); a to_i64 attempt would raise.
    big = ["9999999999999999999", "9999999999999999998", "9999999999999999997"]
    big.each(&.size.should(eq(19)))
    report = S.analyze(big)                    # must not raise
    seq_detail(big).should start_with("corr=") # general (correlation) path, not "constant step"
    report.sequential.should be_false          # identical leading bytes → r = 0
  end

  # ── detect_sequential: general (leading-byte correlation) path ───────────────────

  it "flags non-numeric tokens whose leading byte increases monotonically as sequential" do
    inc = ('a'..'j').map { |c| "#{c}zzzzzzzz" } # first byte a<b<…<j, tail constant
    report = S.analyze(inc)
    report.sequential.should be_true
    seq_detail(inc).should start_with("corr=")
  end

  it "does not flag non-numeric tokens with a randomized leading byte" do
    rng = Random.new(2024_u64)
    letters = "ghijklmnopqrstuvwxyz"
    shuffled = Array(String).new(30) { "#{letters[rng.rand(letters.size)]}zzzzzzzz" }
    S.analyze(shuffled).sequential.should be_false
  end

  it "returns 'n/a' sequential detail for fewer than three tokens" do
    S.analyze(["abcd", "efgh"]).sequential.should be_false
    seq_detail(["abcd", "efgh"]).should eq("n/a")
    seq_detail(["solo"]).should eq("n/a")
  end

  # ── gate_bits: power-of-two alphabet gating ──────────────────────────────────────

  it "downgrades failing bit tests to INFO for a non-power-of-2 alphabet and spares the rating" do
    rng = Random.new(42_u64)
    dec = Array(String).new(60) { String.build { |io| 20.times { io << "0123456789"[rng.rand(10)] } } }
    report = S.analyze(dec)
    report.charset_size.should eq(10) # decimal, non-power-of-2

    gated = ["Monobit", "Poker", "Runs", "Long run", "Bit bias"]
    # A would-be FAIL is downgraded — no gated bit test may carry a FAIL verdict.
    report.tests.select { |t| gated.includes?(t.name) }.none?(&.verdict.fail?).should be_true
    # …and at least one carries the not-applicable note as INFO.
    downgraded = report.tests.select { |t| gated.includes?(t.name) && t.verdict.info? }
    downgraded.any? { |t| t.detail.includes?("n/a for non-power-of-2 alphabet") }.should be_true
    # A gated INFO never counts as a fail, so it cannot pull the rating down to Critical.
    report.rating.should_not eq(S::Rating::Critical)
  end

  it "keeps bit tests active for a power-of-2 (hex) alphabet — no gating note" do
    report = S.analyze(random_hex(60, 32))
    report.charset_size.should eq(16)
    report.tests.none? { |t| t.detail.includes?("n/a for non-power-of-2 alphabet") }.should be_true
  end

  # ── Report#rationale ─────────────────────────────────────────────────────────────

  it "renders singular vs plural duplicate-token rationale" do
    base = random_hex(60, 32)

    one = base.dup
    one << base[0]
    r1 = S.analyze(one)
    r1.duplicate_count.should eq(1)
    r1.rationale.should contain("1 duplicate token ")
    r1.rationale.includes?("duplicate tokens").should be_false

    two = base.dup
    two << base[0]
    two << base[1]
    r2 = S.analyze(two)
    r2.duplicate_count.should eq(2)
    r2.rationale.should contain("2 duplicate tokens")
  end

  it "renders sequential-pattern rationale for a counter" do
    report = S.analyze((100000..100050).map(&.to_s))
    report.sequential.should be_true
    report.rationale.should contain("sequential pattern")
  end

  it "renders 'all tests passed' rationale for a clean high-entropy corpus" do
    report = S.analyze(random_hex(300, 32))
    report.duplicate_count.should eq(0)
    report.sequential.should be_false
    report.tests.count(&.verdict.fail?).should eq(0)
    report.rationale.should contain("all tests passed")
  end

  it "renders plural 'N tests failed' rationale when several tests fail without dup/seq" do
    pref = random_hex(60, 60, 99_u64).map { |s| "abcd" + s[4..] } # constant prefix, random tail
    report = S.analyze(pref)
    report.duplicate_count.should eq(0)
    report.sequential.should be_false
    fails = report.tests.count(&.verdict.fail?)
    fails.should be > 1
    report.rationale.should contain("#{fails} tests failed")
  end

  it "renders 'no usable tokens' rationale for an empty report" do
    S.analyze([] of String).rationale.should eq("no usable tokens")
    S.analyze(["", "", ""]).rationale.should eq("no usable tokens")
  end

  # ── rate: tier / FAIL demotion and small-sample clamp ────────────────────────────

  it "demotes a Secure-tier corpus one step per FAIL (and renders singular 'test failed')" do
    # Skewed decimal: Secure-tier entropy, non-power-of-2 → the bit tests gate to INFO,
    # leaving chi-square as the lone active failure. Secure(3) − 1 fail = Moderate.
    rng = Random.new(7_u64)
    dec = Array(String).new(60) do
      String.build { |io| 30.times { io << (rng.rand < 0.25 ? '0' : "0123456789"[rng.rand(10)]) } }
    end
    report = S.analyze(dec)
    report.charset_size.should eq(10)
    report.effective_entropy.should be >= 88.0 # tier == Secure
    report.sequential.should be_false
    report.duplicate_count.should eq(0)
    report.tests.count(&.verdict.fail?).should eq(1)
    report.tests.find { |t| t.name == "Chi-square" }.not_nil!.verdict.should eq(S::Verdict::Fail)
    report.rating.should eq(S::Rating::Moderate)
    report.rationale.should contain("1 test failed")
    report.rationale.includes?("tests failed").should be_false
  end

  it "clamps to <= Moderate below the small-sample threshold — n==20 vs n==19 boundary" do
    at_threshold = S.analyze(random_hex(20, 32)) # n == SMALL_SAMPLE (20): not small
    at_threshold.effective_entropy.should be >= 88.0
    at_threshold.tests.count(&.verdict.fail?).should eq(0)
    at_threshold.rating.should eq(S::Rating::Secure) # clamp does not apply

    below = S.analyze(random_hex(19, 32)) # n == 19: small
    below.effective_entropy.should be >= 88.0
    below.tests.count(&.verdict.fail?).should eq(0)
    below.rating.should eq(S::Rating::Moderate) # Secure tier clamped down
  end

  # ── single-distinct-byte corpus (charset_size 1) ─────────────────────────────────

  it "fails chi-square with 'no byte variation' for a single-distinct-byte corpus" do
    report = S.analyze(Array.new(50, "aaaaaaaaaaaaaaaa"))
    report.charset_size.should eq(1)
    chi = report.tests.find { |t| t.name == "Chi-square" }.not_nil!
    chi.value.should eq("1 value")
    chi.detail.should eq("no byte variation")
    chi.verdict.should eq(S::Verdict::Fail)
  end

  it "analyzes a single-distinct-byte, variable-length corpus without raising" do
    report = S.analyze((1..40).map { |n| "a" * n }) # charset 1, bps 0, distinct lengths
    report.charset_size.should eq(1)
    report.usable_count.should eq(40)
    report.bits_per_char.should eq(0.0)
  end

  # ── length histogram binning ─────────────────────────────────────────────────────

  it "clamps the length histogram to 24 bins for a wide length span" do
    rng = Random.new(9_u64)
    spanning = (1..40).map do |len|
      String.build { |io| len.times { io << "0123456789abcdef"[rng.rand(16)] } }
    end
    report = S.analyze(spanning)
    report.len_min.should eq(1)
    report.len_max.should eq(40)
    report.len_hist.size.should eq(24) # (40 - 1 + 1) clamped to 24
    report.len_hist.sum.should eq(40)  # every token bucketed exactly once
  end

  it "collapses a fixed-length corpus into a single histogram bin" do
    report = S.analyze(random_hex(50, 16))
    report.len_min.should eq(16)
    report.len_max.should eq(16)
    report.len_hist.size.should eq(1) # span 0 → bins clamped to 1
    report.len_hist[0].should eq(50)
  end

  # ── sample vs usable accounting + adversarial robustness ─────────────────────────

  it "separates sample_count from usable_count when empty tokens are present" do
    report = S.analyze(["", "abcd", "", "efgh", "ijkl"])
    report.sample_count.should eq(5)
    report.usable_count.should eq(3)
  end

  it "handles a large single-byte corpus and invalid-UTF-8 bytes without raising" do
    large = S.analyze(Array.new(5000, "x" * 40)) # bps 0 → no symbol-bit allocation
    large.charset_size.should eq(1)
    large.usable_count.should eq(5000)

    bad = Array(String).new(30) { |i| String.new(Bytes[0xff_u8, (i % 250 + 1).to_u8, 0x00_u8, 0x80_u8]) }
    report = S.analyze(bad)
    report.charset_label.should eq("binary")
    report.usable_count.should eq(30)
  end
end
