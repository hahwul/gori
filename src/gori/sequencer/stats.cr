require "compress/deflate"
require "./types"

module Gori::Sequencer
  # The randomness math — pure, byte-level, stdlib-only, spec-testable in isolation
  # (no Repeater/Store/TUI dependency). "char" means "byte" throughout, so non-ASCII /
  # binary tokens are analyzed safely. `analyze` takes the successfully-extracted
  # tokens and returns a Report: entropy figures, a per-test verdict table, an overall
  # rating, and raw arrays for the DIST-style charts (no baked color — the view resolves
  # theme at draw time). p-values come from Math.erfc (normal tail) and a Wilson–Hilferty
  # chi-square approximation, so the whole module is closed-form and deterministic.
  module Stats
    # Below this usable-sample count the statistical bands are unreliable, so a would-be
    # FAIL softens to WARN and the rating can't certify Secure (clamped ≤ Moderate).
    SMALL_SAMPLE = 20

    # Bytes of concatenated token text fed to the compression test. The deflate ratio settles
    # well before a full sample, and analyze is re-run on a UI throttle, so this bounds the
    # single largest allocation in the report.
    COMPRESS_SCAN_CAP = 256 * 1024

    # How many rows in one report take their verdict from a p-value: Monobit, Poker, Runs,
    # Chi-square, Cusum, Approx entropy, Spectral. Their thresholds below are Bonferroni-split
    # by this count.
    #
    # Without the split, adding a test makes a GENUINELY RANDOM token more likely to be
    # demoted: `rate` costs a tier per FAIL, so at a flat α=0.01 each, seven independent tests
    # give a clean token a 1-0.99^7 ≈ 6.8% chance of one spurious FAIL — and every future test
    # would push that higher. Splitting α across the family holds the family-wise false-alarm
    # rate at the ~1% a single test carried, which is what makes the family safe to grow.
    # Real weakness is unaffected: a broken generator's p-values are ~0, orders below either
    # threshold. The four rows judged on a hand-set effect size instead (Long run, Serial corr,
    # Compression, Bit bias) are not part of this family and keep their own bands.
    P_VALUE_TESTS = 7
    ALPHA_FAIL    = 0.01 / P_VALUE_TESTS
    ALPHA_WARN    = 0.05 / P_VALUE_TESTS

    # Approximate-entropy block length, chosen per corpus as floor(log2 n) - 6 within these
    # bounds (NIST wants m < log2(n) - 5; one further bit of headroom keeps ~64 observations per
    # pattern, so the chi-square is not read off a sparse table).
    #
    # A FIXED small m is the trap here: at m=2 the test only sees 2- and 3-bit blocks, and a
    # stream built by repeating each nibble — an 8-bit period — has perfectly uniform statistics
    # at that width. Measured, it scored ApEn=0.693, the ideal, on a corpus three other rows
    # flagged. The block has to be wide enough to contain the repeat before this test can see it.
    APEN_M_MIN    =    2
    APEN_M_MAX    =    8
    APEN_MIN_BITS = 1000

    # The spectral test needs a power-of-two length for the radix-2 FFT, so the bitstream is
    # truncated to the largest one it covers. The cap bounds an O(n log n) pass that the TUI
    # re-runs on a throttle: 2^16 bits is ~1M butterfly ops, and the peak-count statistic is
    # settled long before a full multi-megabit sample.
    DFT_MIN_BITS = 1024
    DFT_MAX_BITS = 1 << 16

    # Above this the Cusum p-value series would run more terms than the answer is worth. A
    # max excursion that small over that many bits is not a near-miss — see `cusum_p`.
    CUSUM_MAX_TERMS = 10_000

    enum Verdict
      Pass
      Warn
      Fail
      Info

      def label : String
        case self
        in Pass then "PASS"
        in Warn then "WARN"
        in Fail then "FAIL"
        in Info then "INFO"
        end
      end
    end

    # Overall grade. Ordinal (Critical=0 … Secure=3) so demotion is arithmetic.
    enum Rating
      Critical
      Weak
      Moderate
      Secure

      def label : String
        case self
        in Critical then "CRITICAL"
        in Weak     then "WEAK"
        in Moderate then "MODERATE"
        in Secure   then "SECURE"
        end
      end
    end

    # One row of the analysis table.
    record TestRow, name : String, value : String, detail : String, verdict : Verdict

    # Which bytes of a token the byte-level tests may read — see the variable region in
    # `analyze`. Every column of the aligned window that never varies is skipped; every byte
    # outside the window is kept (a corpus of mixed lengths has no column evidence out there,
    # so nothing is known to be constant). `full` keeps everything.
    struct Region
      def initialize(@min_len : Int32, @constant : Array(Bool), @from_end : Bool, @all : Bool = false)
      end

      def self.full : Region
        new(0, [] of Bool, false, all: true)
      end

      # The corpus flattened to the bytes the tests may read, in token order. Built ONCE and
      # shared by the frequency table, the symbol bitstream, the symbol sequence and the
      # compression input, all of which used to re-walk `usable` themselves.
      def bytes(usable : Array(String)) : Bytes
        dropped = @constant.count(true)
        return flatten(usable) if @all || @min_len <= 0 || dropped == 0
        # `min_len` IS the shortest token's length, so the window fits inside every token and
        # each one loses exactly `dropped` bytes — the size is known without a counting pass.
        buf = Bytes.new(usable.sum(&.bytesize) - usable.size * dropped)
        off = 0
        usable.each do |t|
          sl = t.to_slice
          w0 = @from_end ? sl.size - @min_len : 0
          i = 0
          while i < sl.size
            unless i >= w0 && i - w0 < @min_len && @constant.unsafe_fetch(i - w0)
              buf.unsafe_put(off, sl.unsafe_fetch(i))
              off += 1
            end
            i += 1
          end
        end
        buf
      end

      private def flatten(usable : Array(String)) : Bytes
        buf = Bytes.new(usable.sum(&.bytesize))
        off = 0
        usable.each do |t|
          sl = t.to_slice
          sl.copy_to(buf.to_unsafe + off, sl.size)
          off += sl.size
        end
        buf
      end
    end

    record Report,
      sample_count : Int32,
      usable_count : Int32,
      min_len : Int32,
      max_len : Int32,
      variable_length : Bool,
      charset_size : Int32,
      charset_label : String,
      bits_per_char : Float64,
      shannon_total : Float64,
      effective_entropy : Float64,
      length_entropy : Float64,
      uniqueness : Float64,
      duplicate_count : Int32,
      sequential : Bool,
      rating : Rating,
      tests : Array(TestRow),
      char_counts : Array({UInt8, Int32}),
      len_hist : Array(Int32),
      len_min : Int32,
      len_max : Int32,
      per_pos_entropy : Array(Float64),
      bit_bias : Array(Float64),
      # Positions in the aligned window that NEVER vary — a token's structural skeleton (a
      # `sess_` prefix, a version byte, base64 padding). They contribute exactly 0 to
      # `effective_entropy` already; naming the count is what tells an operator that a
      # 40-character token is really a 24-character one.
      constant_positions : Int32 = 0,
      # Whether the per-position window was anchored to the END of each token rather than its
      # start — see `analyze`. Always false for a fixed-length corpus, where the two agree.
      aligned_from_end : Bool = false do
      # A one-line rationale for the rating banner.
      def rationale : String
        return "no usable tokens" if usable_count == 0
        if duplicate_count > 0
          "#{duplicate_count} duplicate token#{duplicate_count == 1 ? "" : "s"} · effective entropy #{effective_entropy.round(1)}b"
        elsif sequential
          "sequential pattern · effective entropy #{effective_entropy.round(1)}b"
        else
          fails = tests.count(&.verdict.fail?)
          "effective entropy #{effective_entropy.round(1)}b · #{fails == 0 ? "all tests passed" : "#{fails} test#{fails == 1 ? "" : "s"} failed"}"
        end
      end
    end

    def self.analyze(tokens : Array(String)) : Report
      usable = tokens.reject(&.empty?)
      n = usable.size
      return empty_report(tokens.size) if n == 0
      small = n < SMALL_SAMPLE

      lengths = usable.map(&.bytesize)
      len_min = lengths.min
      len_max = lengths.max
      min_len = len_min

      # Per-position entropy + the headline effective-entropy budget
      # (Σ log2(distinct bytes seen at each position over a fixed window of min_len positions).
      #
      # It runs BEFORE the byte-frequency pass because its output decides which bytes that pass
      # is allowed to look at — see the variable region below.
      per_pos, effective, const_mask, aligned_from_end =
        aligned_positions(usable, min_len, n, variable_length: len_min != len_max)
      shannon_total = per_pos.sum
      constant_positions = const_mask.count(true)

      region_bytes = variable_region(usable, min_len, const_mask, aligned_from_end)
      total_bytes = region_bytes.size.to_i64

      gcounts = Array(Int32).new(256, 0)
      region_bytes.each { |b| gcounts[b] += 1 }
      present = [] of UInt8
      gcounts.each_with_index { |c, i| present << i.to_u8 if c > 0 }
      charset_size = present.size
      charset_label = classify(present)
      bits_per_char = shannon(gcounts, total_bytes)

      lcounts = Hash(Int32, Int32).new(0)
      lengths.each { |l| lcounts[l] += 1 }
      length_entropy = shannon_hash(lcounts, n)

      # to_set.size, not uniq.size: Array#uniq is `to_set.to_a` for a sample this size, so it
      # built an n-element Array purely to read .size off it.
      unique = usable.to_set.size
      duplicate_count = n - unique
      uniqueness = unique.to_f / n

      char_counts = present.map { |b| {b, gcounts[b]} }.sort_by! { |(_, c)| -c }
      len_bins = (len_max - len_min + 1).clamp(1, 24)
      len_hist = histogram(lengths, len_bins, len_min, len_max)

      # The bit-level tests run over a SYMBOL bitstream, not the raw ASCII bytes: each
      # character maps to its index in the observed alphabet and contributes
      # ceil(log2(charset)) bits. This measures the token's real entropy rather than its
      # encoding — a hex token's ASCII bytes are structurally non-uniform (0x30-0x66) and
      # would fail every bit test even when the underlying value is perfectly random.
      # Byte → alphabet index as a flat 256-entry LUT rather than a Hash. This is probed once
      # per sample byte by three separate loops below (the bit-bias scan, symbol_bits and
      # symbol_seq), and the sample reaches millions of bytes, so a direct index beats hashing
      # every one of them. -1 marks a byte absent from the alphabet (never hit: the table is
      # built from the bytes actually present).
      idx_of = Array(Int32).new(256, -1)
      present.each_with_index { |b, i| idx_of[b] = i }
      bps = charset_size <= 1 ? 0 : Math.log2(charset_size.to_f).ceil.to_i
      # The fixed-width symbol-bit encoding is only unbiased when the alphabet size is a
      # power of two (hex=16, base64=64). For a non-power-of-2 alphabet (decimal=10,
      # base62, …) the unused high index bits are structurally starved of 1s, so the raw
      # bit tests would FAIL a genuinely-random token. Gate their FAIL contribution below.
      pow2 = charset_size > 0 && (charset_size & (charset_size - 1)) == 0

      # Per-symbol-bit bias over the fixed window (feeds the chart + a test). Anchored to the
      # same end as the per-position pass above — a suffix-aligned corpus measured from the
      # start would score every column's bias against bytes from different logical fields.
      window_bits = min_len * bps
      ones_at = Array(Int32).new(window_bits, 0)
      if bps > 0
        usable.each do |t|
          sl = t.to_slice
          (0...min_len).each do |p|
            v = idx_of.unsafe_fetch(sl[aligned_from_end ? sl.size - min_len + p : p])
            (0...bps).each { |k| ones_at[p * bps + k] += 1 if (v >> (bps - 1 - k)) & 1 == 1 }
          end
        end
      end
      bit_bias = ones_at.map { |c| (c.to_f / n - 0.5).abs }

      bits = symbol_bits(region_bytes, idx_of, bps)
      sym_seq = symbol_seq(region_bytes, idx_of)
      # Over the WHOLE tokens, not the region: whether one value follows another is a property
      # of the value an operator was issued, and a counter hidden behind a constant prefix is
      # exactly what `detect_sequential` already goes out of its way to find.
      seq, seq_detail = detect_sequential(usable)

      tests = [] of TestRow
      tests << uniqueness_test(unique, n, duplicate_count)
      tests << TestRow.new("Sequential", seq ? "detected" : "none", seq_detail,
        seq ? Verdict::Fail : Verdict::Pass)
      tests << structure_test(constant_positions, min_len, aligned_from_end)
      tests << gate_bits(monobit_test(bits, small), pow2)
      tests << gate_bits(poker_test(bits, small), pow2)
      tests << gate_bits(runs_test(bits, small), pow2)
      tests << gate_bits(longrun_test(bits, small), pow2)
      tests << chi_square_test(gcounts, present, total_bytes, small)
      tests << serial_test(sym_seq, small)
      tests << compression_test(region_bytes, total_bytes, charset_size, small)
      tests << gate_bits(bit_bias_test(ones_at, n, small, const_mask, bps), pow2)
      # The three NIST-style additions. Each reads the SAME symbol bitstream the four classic
      # bit tests do, so each is gated on a power-of-two alphabet for the same reason, and each
      # catches a failure the existing table cannot: Cusum a drift that shows up only partway
      # through the stream (the monobit total stays balanced), Approx entropy a repeating block
      # structure (frequencies stay uniform), Spectral a periodicity — the signature of an LCG
      # or a time-seeded counter, which passes every frequency-and-runs test there is.
      tests << gate_bits(cusum_test(bits, small), pow2)
      tests << gate_bits(approx_entropy_test(bits, small), pow2)
      tests << gate_bits(spectral_test(bits, small), pow2)

      rating = rate(effective, duplicate_count, seq, tests, small)

      Report.new(
        sample_count: tokens.size, usable_count: n,
        min_len: min_len, max_len: len_max, variable_length: len_min != len_max,
        charset_size: charset_size, charset_label: charset_label,
        bits_per_char: bits_per_char, shannon_total: shannon_total,
        effective_entropy: effective, length_entropy: length_entropy,
        uniqueness: uniqueness, duplicate_count: duplicate_count,
        sequential: seq, rating: rating, tests: tests,
        char_counts: char_counts, len_hist: len_hist, len_min: len_min, len_max: len_max,
        per_pos_entropy: per_pos, bit_bias: bit_bias,
        constant_positions: constant_positions, aligned_from_end: aligned_from_end)
    end

    # The per-position pass, anchored to whichever END of the token carries more entropy.
    #
    # Anchoring to the START unconditionally — which is all this did — silently under-reports
    # every token whose random part is a SUFFIX behind a variable-length structural head
    # (`v2.<random>` / `<user-id>-<random>`): the columns then mix bytes from different logical
    # fields, distinct counts collapse toward the shared structure, and a strong token reads
    # Weak. Both alignments are the same measurement of the same corpus, so taking the larger
    # keeps the figure conservative (still capped by min(N, alphabet) per column) without letting
    # an arbitrary anchor choice decide the grade. A fixed-length corpus yields identical
    # windows, so it never pays for the second pass.
    private def self.aligned_positions(usable : Array(String), min_len : Int32, n : Int32,
                                       variable_length : Bool) : {Array(Float64), Float64, Array(Bool), Bool}
      per_pos, effective, mask = positional(usable, min_len, n, from_end: false)
      return {per_pos, effective, mask, false} unless variable_length
      s_pos, s_eff, s_mask = positional(usable, min_len, n, from_end: true)
      s_eff > effective ? {s_pos, s_eff, s_mask, true} : {per_pos, effective, mask, false}
    end

    # THE VARIABLE REGION: every byte except those sitting at a window column that never varies.
    # Everything byte-level in `analyze` — the alphabet, Shannon, the char chart, chi-square, the
    # symbol bitstream all eight bit tests read, and compression — is measured over these bytes
    # and no others.
    #
    # Reading the structural bytes too does not merely add noise, it disables the analysis.
    # Measured on 300 tokens of `sess_v1_` + 24 random hex chars: the eight prefix bytes drag
    # five extra characters into the alphabet, so charset reads 19 instead of 16 — NOT a power of
    # two, which gates every bit test off as "n/a"; chi-square then fails on a byte distribution
    # skewed purely by the constant prefix, compression fails because the repeated prefix
    # deflates, and what is left is a WEAK grade on 96 bits of perfectly good hex, produced by
    # tests that never looked at it. Excluded, the same corpus is what it actually is: a
    # lower-hex alphabet with the full bit-test battery active and every row passing.
    #
    # A constant column carries exactly zero information — `effective_entropy` already scores it
    # 0 — so dropping it removes nothing a test could have used. The `Region.full` fallback is
    # for a corpus with NO varying column (an all-identical sample): there the exclusion would
    # leave nothing to measure at all, and the honest answer is the one the unfiltered bytes give.
    private def self.variable_region(usable : Array(String), min_len : Int32,
                                     const_mask : Array(Bool), from_end : Bool) : Bytes
      bytes = Region.new(min_len, const_mask, from_end).bytes(usable)
      bytes.empty? ? Region.full.bytes(usable) : bytes
    end

    # Per-position byte entropy over a fixed window of `min_len` positions, with the
    # effective-entropy budget (Σ log2 distinct) and a mask marking the columns that never vary.
    # `from_end` reads position p as the p-th byte from the END of each token; both returned
    # arrays are in token order (left to right within the window), so a caller charting them
    # never has to know which anchor won.
    #
    # One 256-entry column table, refilled per position rather than reallocated: this runs
    # twice for a variable-length corpus and min_len reaches the hundreds.
    private def self.positional(usable : Array(String), min_len : Int32, n : Int32,
                                from_end : Bool) : {Array(Float64), Float64, Array(Bool)}
      per_pos = Array(Float64).new(min_len, 0.0)
      constant = Array(Bool).new(min_len, false)
      effective = 0.0
      col = Array(Int32).new(256, 0)
      (0...min_len).each do |p|
        col.fill(0)
        usable.each do |t|
          sl = t.to_slice
          col[sl.unsafe_fetch(from_end ? sl.size - min_len + p : p)] += 1
        end
        distinct = col.count(&.positive?)
        per_pos[p] = shannon(col, n.to_i64)
        effective += Math.log2(distinct.to_f) if distinct > 0
        constant[p] = distinct == 1
      end
      {per_pos, effective, constant}
    end

    # A raw fixed-width bit test (monobit/poker/runs/long-run/bit-bias) only measures true
    # randomness for a power-of-two alphabet. For any other alphabet a genuinely-random token
    # fails spuriously, so a FAIL is downgraded to INFO — it no longer penalizes the rating
    # (rate counts only .fail?) and is labelled as not applicable. The encoding-neutral tests
    # (chi-square on byte frequencies, serial on symbol indices, compression vs the log2(charset)
    # floor) stay active, so real weakness is still caught.
    private def self.gate_bits(row : TestRow, pow2 : Bool) : TestRow
      return row if pow2 || !row.verdict.fail?
      TestRow.new(row.name, row.value, "#{row.detail} · n/a for non-power-of-2 alphabet", Verdict::Info)
    end

    # ── rating ────────────────────────────────────────────────────────────────────

    private def self.rate(effective : Float64, duplicate_count : Int32, seq : Bool,
                          tests : Array(TestRow), small : Bool) : Rating
      return Rating::Critical if duplicate_count > 0 || seq
      base = tier(effective)
      fails = tests.count(&.verdict.fail?)
      r = Rating.from_value((base.value - fails).clamp(0, 3))
      r = Rating::Moderate if small && r.value > Rating::Moderate.value
      r
    end

    private def self.tier(bits : Float64) : Rating
      if bits >= 88.0
        Rating::Secure
      elsif bits >= 60.0
        Rating::Moderate
      elsif bits >= 30.0
        Rating::Weak
      else
        Rating::Critical
      end
    end

    # ── individual tests ────────────────────────────────────────────────────────────

    private def self.uniqueness_test(unique : Int32, n : Int32, dups : Int32) : TestRow
      TestRow.new("Uniqueness", "#{unique}/#{n}",
        dups > 0 ? "#{dups} duplicate#{dups == 1 ? "" : "s"}" : "all distinct",
        dups > 0 ? Verdict::Fail : Verdict::Pass)
    end

    private def self.monobit_test(bits : Array(UInt8), small : Bool) : TestRow
      n = bits.size
      return insufficient("Monobit", "#{n} bits") if n < 100
      ones = bits.count(1_u8).to_i64
      z = (2.0 * ones - n) / Math.sqrt(n.to_f)
      p = two_sided(z)
      TestRow.new("Monobit", "z=#{fmt(z)}", "ones #{pct(ones.to_f / n)}", grade(p, small))
    end

    private def self.poker_test(bits : Array(UInt8), small : Bool) : TestRow
      m = bits.size // 4
      return insufficient("Poker", "#{m} groups") if m < 80
      freq = Array(Int32).new(16, 0)
      m.times do |i|
        v = (bits[i * 4] << 3) | (bits[i * 4 + 1] << 2) | (bits[i * 4 + 2] << 1) | bits[i * 4 + 3]
        freq[v] += 1
      end
      sumsq = freq.sum { |f| f.to_f * f.to_f }
      x = (16.0 / m) * sumsq - m
      p = chi2_sf(x, 15)
      TestRow.new("Poker", "X=#{fmt(x)}", "df 15", grade(p, small))
    end

    private def self.runs_test(bits : Array(UInt8), small : Bool) : TestRow
      n = bits.size
      return insufficient("Runs", "#{n} bits") if n < 100
      ones = bits.count(1_u8).to_i64
      zeros = n - ones
      return TestRow.new("Runs", "constant", "all bits identical", Verdict::Fail) if ones == 0 || zeros == 0
      runs = 1_i64
      (1...bits.size).each { |i| runs += 1 if bits[i] != bits[i - 1] }
      mu = 2.0 * ones * zeros / n + 1.0
      variance = 2.0 * ones * zeros * (2.0 * ones * zeros - n) / (n.to_f * n * (n - 1))
      return insufficient("Runs", "#{runs} runs") if variance <= 0
      z = (runs - mu) / Math.sqrt(variance)
      p = two_sided(z)
      TestRow.new("Runs", "#{runs}", "expected #{mu.round(0).to_i}", grade(p, small))
    end

    private def self.longrun_test(bits : Array(UInt8), small : Bool) : TestRow
      n = bits.size
      return insufficient("Long run", "#{n} bits") if n < 100
      longest = 0
      cur = 0
      prev = 2_u8
      bits.each do |b|
        if b == prev
          cur += 1
        else
          cur = 1
          prev = b
        end
        longest = cur if cur > longest
      end
      exp = Math.log2(n.to_f)
      verdict = if longest >= 2.5 * exp
                  small ? Verdict::Warn : Verdict::Fail
                elsif longest >= 2.0 * exp
                  Verdict::Warn
                else
                  Verdict::Pass
                end
      TestRow.new("Long run", "#{longest}", "expected ~#{exp.round(0).to_i}", verdict)
    end

    private def self.chi_square_test(gcounts : Array(Int32), present : Array(UInt8),
                                     total : Int64, small : Bool) : TestRow
      k = present.size
      return TestRow.new("Chi-square", "1 value", "no byte variation", Verdict::Fail) if k < 2
      e = total.to_f / k
      return insufficient("Chi-square", "E=#{fmt(e)}") if e < 5.0
      x = 0.0
      present.each do |b|
        d = gcounts[b] - e
        x += d * d / e
      end
      p = chi2_sf(x, k - 1)
      TestRow.new("Chi-square", "p=#{fmt(p)}", "df #{k - 1}", grade(p, small))
    end

    # Lag-1 serial correlation over the concatenated SYMBOL stream (detects structure /
    # transitions a uniform frequency table would miss), using the alphabet indices so a
    # hex/base64 encoding doesn't inject spurious correlation.
    private def self.serial_test(seq : Array(Int32), small : Bool) : TestRow
      m = seq.size
      return insufficient("Serial corr", "#{m} symbols") if m < 100
      sx = 0.0; sy = 0.0; sxy = 0.0; sx2 = 0.0; sy2 = 0.0
      pairs = m - 1
      (0...pairs).each do |i|
        x = seq[i].to_f; y = seq[i + 1].to_f
        sx += x; sy += y; sxy += x * y; sx2 += x * x; sy2 += y * y
      end
      den = Math.sqrt((pairs * sx2 - sx * sx) * (pairs * sy2 - sy * sy))
      r = den == 0 ? 0.0 : (pairs * sxy - sx * sy) / den
      verdict = if r.abs > 0.1
                  small ? Verdict::Warn : Verdict::Fail
                elsif r.abs > 0.05
                  Verdict::Warn
                else
                  Verdict::Pass
                end
      TestRow.new("Serial corr", "r=#{fmt(r)}", "lag-1 symbol", verdict)
    end

    # Deflate ratio vs the token alphabet's own entropy floor (log2(charset)/8). A random
    # token compresses to ~its floor; a ratio well below it means real structure. Judging
    # against a flat 1.0 would wrongly fail every hex/base64 token for its encoding.
    private def self.compression_test(region : Bytes, bytes : Int64,
                                      charset_size : Int32, small : Bool) : TestRow
      return insufficient("Compression", "#{bytes} bytes") if bytes < 64
      # Cap the deflate input. The ratio is a stable statistic long before the whole sample is
      # consumed, but a full 50k-token sample is multiple megabytes to deflate — on a path the
      # TUI re-runs on a throttle and every MCP poll re-runs from scratch. A prefix of the
      # region buffer, so the constant columns a structural prefix contributes (which deflate to
      # nothing and would drag the ratio under any floor) are already out of it.
      raw = region[0, {region.size, COMPRESS_SCAN_CAP}.min]
      io = IO::Memory.new(raw.size // 2)
      Compress::Deflate::Writer.open(io, &.write(raw))
      ratio = io.size.to_f / raw.size
      floor = charset_size <= 1 ? 0.0 : Math.log2(charset_size.to_f) / 8.0
      verdict = if ratio < floor * 0.85
                  small ? Verdict::Warn : Verdict::Fail
                elsif ratio < floor * 0.95
                  Verdict::Warn
                else
                  Verdict::Pass
                end
      # Say so when the ratio came from a prefix rather than the whole sample, so the number is
      # never silently a different measurement from the one the sample size implies.
      detail = raw.size < bytes ? "floor #{fmt(floor)} · first #{raw.size // 1024} KB" : "floor #{fmt(floor)}"
      TestRow.new("Compression", fmt(ratio), detail, verdict)
    end

    # How much of the token is skeleton rather than secret. INFO, never a FAIL: these columns
    # already contribute 0 to `effective_entropy`, so grading them again would charge the same
    # weakness twice — this row exists to explain a low headline figure, not to lower it.
    private def self.structure_test(constant : Int32, min_len : Int32, from_end : Bool) : TestRow
      return TestRow.new("Structure", "—", "no fixed window", Verdict::Info) if min_len <= 0
      anchor = from_end ? "aligned to token end" : "aligned to token start"
      detail = constant == 0 ? "every position varies · #{anchor}" : "#{min_len - constant} varying · #{anchor}"
      TestRow.new("Structure", "#{constant}/#{min_len} fixed", detail, Verdict::Info)
    end

    # NIST SP 800-22 §2.13 (forward cumulative sums). The bits walk ±1 and the statistic is the
    # largest absolute excursion. A generator whose bias appears only partway through the stream
    # — a counter that rolls over, a pool that degrades once it drains — keeps a balanced ONES
    # TOTAL and sails through Monobit while walking far off zero here.
    private def self.cusum_test(bits : Array(UInt8), small : Bool) : TestRow
      n = bits.size
      return insufficient("Cusum", "#{n} bits") if n < 100
      s = 0
      z = 0
      bits.each do |b|
        s += b == 1_u8 ? 1 : -1
        a = s.abs
        z = a if a > z
      end
      # A walk that never leaves zero is not a near-miss — it is a perfectly alternating stream.
      return TestRow.new("Cusum", "z=0", "walk never leaves 0", small ? Verdict::Warn : Verdict::Fail) if z == 0
      p = cusum_p(z, n)
      TestRow.new("Cusum", "z=#{z}", "max excursion · expected ~#{Math.sqrt(n.to_f).round.to_i}", grade(p, small))
    end

    # The forward-cusum p-value: 1 - Σ[Φ((4k+1)z/√n) - Φ((4k-1)z/√n)] + Σ[Φ((4k+3)z/√n) -
    # Φ((4k+1)z/√n)], both series over k ≈ ±n/(4z). For a random walk z ≈ √n, so the term count
    # is ≈ √n/2 — a few hundred terms even on a multi-megabit stream. A z small enough to blow
    # that budget (n/z past CUSUM_MAX_TERMS·4) means an excursion orders of magnitude under the
    # random expectation, which is itself decisive: report 0 rather than spend the series
    # confirming it.
    private def self.cusum_p(z : Int32, n : Int32) : Float64
      return 0.0 if n.to_f / z > 4.0 * CUSUM_MAX_TERMS
      sq = Math.sqrt(n.to_f)
      zf = z.to_f
      kmax = ((n.to_f / zf - 1.0) / 4.0).floor.to_i
      sum1 = 0.0
      k = ((-n.to_f / zf + 1.0) / 4.0).ceil.to_i
      while k <= kmax
        sum1 += phi(((4 * k + 1) * zf) / sq) - phi(((4 * k - 1) * zf) / sq)
        k += 1
      end
      sum2 = 0.0
      k = ((-n.to_f / zf - 3.0) / 4.0).ceil.to_i
      while k <= kmax
        sum2 += phi(((4 * k + 3) * zf) / sq) - phi(((4 * k + 1) * zf) / sq)
        k += 1
      end
      (1.0 - sum1 + sum2).clamp(0.0, 1.0)
    end

    # NIST SP 800-22 §2.12. Compares the pattern-frequency entropy of m-bit blocks with that of
    # (m+1)-bit blocks: for a random stream the extra bit buys a full ln2 of surprise. A stream
    # built from a repeating block — a nonce reused across a chunk of the token, a PRNG with a
    # short cycle — keeps every SINGLE-bit frequency uniform (so Monobit/Poker pass) while the
    # transition structure gives it away here.
    private def self.approx_entropy_test(bits : Array(UInt8), small : Bool) : TestRow
      n = bits.size
      return insufficient("Approx entropy", "#{n} bits") if n < APEN_MIN_BITS
      m = (Math.log2(n.to_f).floor.to_i - 6).clamp(APEN_M_MIN, APEN_M_MAX)
      apen = block_phi(bits, m) - block_phi(bits, m + 1)
      chi = 2.0 * n * (Math.log(2.0) - apen)
      p = chi2_sf(chi, 1 << m)
      TestRow.new("Approx entropy", "ApEn=#{fmt(apen)}", "m=#{m} · ideal #{fmt(Math.log(2.0))}", grade(p, small))
    end

    # φ^(m): Σ π ln π over the 2^m block patterns of the CIRCULARLY extended bitstream (the
    # last m-1 bits wrap onto the first), so all n windows exist and the two φ values are
    # comparable. A flat 2^m counter array, rolled with a shift-and-mask.
    private def self.block_phi(bits : Array(UInt8), m : Int32) : Float64
      n = bits.size
      counts = Array(Int32).new(1 << m, 0)
      mask = (1 << m) - 1
      v = 0
      (0...(m - 1)).each { |i| v = ((v << 1) | bits.unsafe_fetch(i)) & mask }
      n.times do |i|
        v = ((v << 1) | bits.unsafe_fetch((i + m - 1) % n)) & mask
        counts[v] += 1
      end
      total = n.to_f
      s = 0.0
      counts.each do |c|
        next if c == 0
        pr = c / total
        s += pr * Math.log(pr)
      end
      s
    end

    # NIST SP 800-22 §2.6 (discrete Fourier transform). Counts how many spectral peaks fall
    # under the 95% height threshold; a periodic component pushes peaks above it. This is the
    # test that catches a linear-congruential or time-seeded generator — such a stream has
    # uniform bit frequencies, well-behaved runs and near-ideal compression, and every other
    # row in this table passes it.
    private def self.spectral_test(bits : Array(UInt8), small : Bool) : TestRow
      avail = {bits.size, DFT_MAX_BITS}.min
      return insufficient("Spectral", "#{bits.size} bits") if avail < DFT_MIN_BITS
      n = 1 << Math.log2(avail.to_f).floor.to_i # radix-2 FFT wants a power-of-two length
      re = Array(Float64).new(n) { |i| bits.unsafe_fetch(i) == 1_u8 ? 1.0 : -1.0 }
      im = Array(Float64).new(n, 0.0)
      fft(re, im)
      threshold = Math.sqrt(Math.log(1.0 / 0.05) * n)
      half = n // 2
      below = 0
      half.times { |i| below += 1 if Math.sqrt(re[i] * re[i] + im[i] * im[i]) < threshold }
      expected = 0.95 * half
      d = (below - expected) / Math.sqrt(n * 0.95 * 0.05 / 4.0)
      # Say so when the spectrum came from a prefix, so the number is never silently a different
      # measurement from the one the sample size implies (same rule as the compression row).
      scope = n < bits.size ? " · first #{n} bits" : ""
      TestRow.new("Spectral", "d=#{fmt(d)}", "#{below}/#{half} peaks under T#{scope}", grade(two_sided(d), small))
    end

    # In-place iterative radix-2 Cooley-Tukey FFT. `re`/`im` must share a power-of-two length.
    # The twiddle factor is advanced by recurrence rather than recomputed per butterfly: the
    # accumulated drift over the 2^16-bit cap is far below the resolution of a peak COUNT
    # against a fixed threshold, and per-step trig would cost a million calls.
    private def self.fft(re : Array(Float64), im : Array(Float64)) : Nil
      n = re.size
      j = 0
      (1...n).each do |i|
        bit = n >> 1
        while j & bit != 0
          j ^= bit
          bit >>= 1
        end
        j |= bit
        if i < j
          re.swap(i, j)
          im.swap(i, j)
        end
      end
      len = 2
      while len <= n
        ang = -2.0 * Math::PI / len
        wr = Math.cos(ang)
        wi = Math.sin(ang)
        half = len // 2
        i = 0
        while i < n
          cr = 1.0
          ci = 0.0
          half.times do |k|
            ur = re.unsafe_fetch(i + k)
            ui = im.unsafe_fetch(i + k)
            xr = re.unsafe_fetch(i + k + half)
            xi = im.unsafe_fetch(i + k + half)
            vr = xr * cr - xi * ci
            vi = xr * ci + xi * cr
            re.unsafe_put(i + k, ur + vr)
            im.unsafe_put(i + k, ui + vi)
            re.unsafe_put(i + k + half, ur - vr)
            im.unsafe_put(i + k + half, ui - vi)
            ncr = cr * wr - ci * wi
            ci = cr * wi + ci * wr
            cr = ncr
          end
          i += len
        end
        len <<= 1
      end
    end

    # Standard normal CDF, for the cusum series.
    private def self.phi(x : Float64) : Float64
      0.5 * Math.erfc(-x / Math.sqrt(2.0))
    end

    # `constant`/`bps` locate the window columns that never vary, whose bits are skipped. A
    # constant column's ones-count is 0 or n by definition, so every one of its bits scores
    # |z| = √n and counted as "biased" — a token behind an 8-character prefix reported 85 of 160
    # positions biased on a corpus whose varying region was flawless. Structure is reported by
    # its own INFO row; this row is about the bits that were supposed to be random.
    private def self.bit_bias_test(ones_at : Array(Int32), n : Int32, small : Bool,
                                   constant : Array(Bool), bps : Int32) : TestRow
      return insufficient("Bit bias", "no fixed window") if ones_at.empty? || n < SMALL_SAMPLE
      total = 0
      biased = 0
      ones_at.each_with_index do |c, i|
        next if bps > 0 && constant[i // bps]? == true
        total += 1
        z = (2.0 * c - n) / Math.sqrt(n.to_f)
        biased += 1 if z.abs > 2.58
      end
      return insufficient("Bit bias", "no varying column") if total == 0
      frac = biased.to_f / total
      verdict = if frac > 0.05
                  small ? Verdict::Warn : Verdict::Fail
                elsif frac > 0.02
                  Verdict::Warn
                else
                  Verdict::Pass
                end
      TestRow.new("Bit bias", "#{biased}/#{total}", "biased positions", verdict)
    end

    # ── sequential detection ────────────────────────────────────────────────────────

    private def self.detect_sequential(tokens : Array(String)) : {Bool, String}
      n = tokens.size
      return {false, "n/a"} if n < 3
      # Numeric fast path — incrementing/decrementing counters.
      if tokens.all? { |t| !t.empty? && t.size <= 18 && t.each_char.all?(&.ascii_number?) }
        vals = tokens.map(&.to_i64)
        inc = (1...vals.size).all? { |i| vals[i] > vals[i - 1] }
        dec = (1...vals.size).all? { |i| vals[i] < vals[i - 1] }
        if inc || dec
          step = constant_step(vals)
          return {true, step ? "constant step #{step}" : (inc ? "monotonic up" : "monotonic down")}
        end
        # Reached only when arrival order is NEITHER ascending nor descending — so
        # "shuffled" below is an earned claim, not a guess. Collection order isn't
        # issuance order once concurrency > 1 (sequence_start allows up to 20 in
        # flight): two in-flight replays can complete swapped, so a textbook
        # incrementing counter can arrive shuffled and the inc/dec check above misses
        # it. Check the SORTED values for an even step — order-independent, so
        # concurrent collection can't hide it. Gated behind SMALL_SAMPLE because a tiny
        # sample "sorts evenly" by pure coincidence often enough to be noise (e.g.
        # [1, 5, 3] sorts to a constant step of 2 despite being a genuinely
        # non-monotonic 3-token run — see the up-then-down spec); at real sample sizes
        # that coincidence is negligible.
        if n >= SMALL_SAMPLE && (step = constant_step(vals.sort))
          return {true, "constant step #{step} (sorted — arrival order was shuffled)"}
        end
        return {false, "non-monotonic"}
      end
      # Hex path — same correlation idea as the general path below, but decodes each
      # token's hex DIGITS to their numeric value first instead of reading raw ASCII
      # bytes. `leading_value` (the general path) treats the string's own bytes as the
      # magnitude, which silently distorts hex text: ASCII '9' (0x39) to 'a' (0x61) is a
      # 40-point jump for what is logically a +1 step, so a straightforward incrementing
      # hex counter can land well under the 0.9 threshold and be missed entirely —
      # confirmed: `2..301` formatted as zero-padded `%08x` scores corr=0.774 under the
      # general path despite being a textbook sequential counter. Decoding nibbles first
      # keeps the magnitude linear in the counter's real value, matching the numeric fast
      # path's precision for decimal tokens above.
      if tokens.all? { |t| !t.empty? && t.each_char.all? { |c| c.ascii_number? || ('a'..'f').includes?(c) || ('A'..'F').includes?(c) } }
        skip = common_prefix_len(tokens)
        xs = Array(Float64).new(n, &.to_f)
        ys = tokens.map { |t| hex_leading_value(t, skip) }
        r = pearson(xs, ys)
        return {r.abs > 0.9, "corr=#{fmt(r)}"}
      end
      # General path — correlation of arrival order with a leading-byte magnitude. Shares
      # the same order-dependency the numeric fast path had above (arrival order can be
      # shuffled by concurrency), but isn't fixed here — a coordinate-only fix couldn't
      # reuse the sort-then-diff trick since this path also weighs HOW closely order
      # tracks magnitude, not just whether the values are evenly spaced.
      # Skip the constant prefix every token shares before reading the leading magnitude. A
      # counter behind an >=8-char fixed prefix (`PREFIXAB000001`, `PREFIXAB000002`, …) has a
      # CONSTANT leading value in the first 8 bytes → variance 0 → correlation 0 → mislabeled
      # "none/random", exactly the token shape a tester is trying to catch. Dropping the shared
      # prefix puts the varying region under the 8-byte window.
      skip = common_prefix_len(tokens)
      xs = Array(Float64).new(n, &.to_f)
      ys = tokens.map { |t| leading_value(t, skip) }
      r = pearson(xs, ys)
      {r.abs > 0.9, "corr=#{fmt(r)}"}
    end

    # Length of the longest prefix every token shares, byte-wise. Bounded by the shortest
    # token. Zero when the tokens diverge at the first byte (the common case).
    private def self.common_prefix_len(tokens : Array(String)) : Int32
      return 0 if tokens.size < 2
      first = tokens[0].to_slice
      limit = tokens.min_of(&.bytesize)
      i = 0
      while i < limit && tokens.all? { |t| t.to_slice[i] == first[i] }
        i += 1
      end
      i
    end

    # The constant gap between every consecutive pair in `values`, or nil if the gaps
    # vary (or all values are identical). Short-circuits on the first mismatching pair
    # rather than building a full delta array + `.uniq` just to read its size. Shared by
    # detect_sequential's arrival-order and sorted-order checks so both express "is this
    # an even arithmetic progression" the same way.
    private def self.constant_step(values : Array(Int64)) : Int64?
      return nil if values.size < 2
      step = values[1] - values[0]
      return nil if step == 0
      (2...values.size).all? { |i| values[i] - values[i - 1] == step } ? step : nil
    end

    private def self.leading_value(t : String, skip : Int32 = 0) : Float64
      v = 0.0
      slice = t.to_slice
      start = {skip, slice.size}.min
      slice[start, {8, slice.size - start}.min].each { |b| v = v * 256.0 + b }
      v
    end

    # Like `leading_value`, but for hex text: decodes each character to its NIBBLE value
    # (0-15) instead of using the character's raw ASCII byte — see the hex path in
    # `detect_sequential` for why the distinction matters. Window widened to 16 chars (64
    # bits of hex) to match `leading_value`'s 8-BYTE window at one hex digit per nibble.
    private def self.hex_leading_value(t : String, skip : Int32 = 0) : Float64
      v = 0.0
      chars = t.chars
      start = {skip, chars.size}.min
      chars[start, {16, chars.size - start}.min].each do |c|
        nibble = c.ascii_number? ? (c.ord - '0'.ord) : (c.downcase.ord - 'a'.ord + 10)
        v = v * 16.0 + nibble
      end
      v
    end

    private def self.pearson(xs : Array(Float64), ys : Array(Float64)) : Float64
      m = xs.size
      return 0.0 if m < 2
      sx = xs.sum; sy = ys.sum
      sxy = 0.0; sx2 = 0.0; sy2 = 0.0
      m.times do |i|
        sxy += xs[i] * ys[i]
        sx2 += xs[i] * xs[i]
        sy2 += ys[i] * ys[i]
      end
      # Each factor is a variance (scaled by m) and mathematically can't be negative, but
      # floating-point cancellation can land it just below 0 for a constant/near-constant
      # series — clamp before the product so sqrt never sees a negative radicand and
      # returns NaN. A clamped-to-0 factor means (near-)zero variance, so den == 0 below
      # still catches it and correlation falls back to the intended 0.0.
      vx = {0.0, m * sx2 - sx * sx}.max
      vy = {0.0, m * sy2 - sy * sy}.max
      den = Math.sqrt(vx * vy)
      den == 0 ? 0.0 : (m * sxy - sx * sy) / den
    end

    # ── shared numeric helpers ──────────────────────────────────────────────────────

    # The symbol bitstream over the variable region: each byte → its alphabet index → `bps` bits
    # (MSB-first). Empty when the alphabet has ≤ 1 symbol (no bits to test).
    #
    # Presized: the final length is known exactly (region bytes × bps), and growing from
    # capacity 0 to the millions of elements a full sample produces means ~20 doubling reallocs,
    # each copying everything written so far.
    private def self.symbol_bits(region : Bytes, idx_of : Array(Int32), bps : Int32) : Array(UInt8)
      return [] of UInt8 if bps <= 0
      bits = Array(UInt8).new(region.size * bps)
      region.each do |b|
        v = idx_of.unsafe_fetch(b)
        (bps - 1).downto(0) { |k| bits << ((v >> k) & 1).to_u8 }
      end
      bits
    end

    # The sequence of alphabet indices (for serial correlation). Presized for the same reason.
    private def self.symbol_seq(region : Bytes, idx_of : Array(Int32)) : Array(Int32)
      seq = Array(Int32).new(region.size)
      region.each { |b| seq << idx_of.unsafe_fetch(b) }
      seq
    end

    private def self.shannon(counts : Array(Int32), n : Int64) : Float64
      return 0.0 if n <= 0
      h = 0.0
      counts.each do |c|
        next if c == 0
        pr = c.to_f / n
        h -= pr * Math.log2(pr)
      end
      h
    end

    private def self.shannon_hash(counts : Hash(Int32, Int32), n : Int32) : Float64
      return 0.0 if n <= 0
      h = 0.0
      counts.each_value do |c|
        next if c == 0
        pr = c.to_f / n
        h -= pr * Math.log2(pr)
      end
      h
    end

    private def self.classify(present : Array(UInt8)) : String
      return "—" if present.empty?
      chars = present.map(&.chr)
      return "lower-hex" if chars.all? { |c| c.ascii_number? || ('a'..'f').includes?(c) }
      return "upper-hex" if chars.all? { |c| c.ascii_number? || ('A'..'F').includes?(c) }
      return "hex" if chars.all? { |c| c.ascii_number? || ('a'..'f').includes?(c) || ('A'..'F').includes?(c) }
      return "base64url" if chars.all? { |c| c.ascii_alphanumeric? || c == '-' || c == '_' || c == '=' }
      return "base64" if chars.all? { |c| c.ascii_alphanumeric? || c == '+' || c == '/' || c == '=' }
      return "ascii" if chars.all? { |c| c.ord >= 0x20 && c.ord <= 0x7e }
      "binary"
    end

    private def self.histogram(values : Array(Int32), bins : Int32, min : Int32, max : Int32) : Array(Int32)
      acc = Array(Int32).new(bins, 0)
      return acc if bins <= 0
      span = (max - min).to_f
      values.each do |v|
        idx = span <= 0 ? 0 : ((v - min).to_f / span * (bins - 1)).round.to_i
        acc[idx.clamp(0, bins - 1)] += 1
      end
      acc
    end

    # Two-sided normal p-value for a z-score (P(|Z| > |z|)).
    private def self.two_sided(z : Float64) : Float64
      Math.erfc(z.abs / Math.sqrt(2.0))
    end

    # Upper-tail chi-square p-value via the Wilson–Hilferty normal approximation.
    private def self.chi2_sf(x : Float64, df : Int32) : Float64
      return 1.0 if x <= 0 || df <= 0
      k = df.to_f
      t = 2.0 / (9.0 * k)
      z = ((x / k) ** (1.0 / 3.0) - (1.0 - t)) / Math.sqrt(t)
      0.5 * Math.erfc(z / Math.sqrt(2.0))
    end

    # Verdict for a p-value test. The bands are Bonferroni-split across the family — see
    # `P_VALUE_TESTS` for why a per-test α would make every added test cost accuracy.
    private def self.grade(p : Float64, small : Bool) : Verdict
      if p < ALPHA_FAIL
        small ? Verdict::Warn : Verdict::Fail
      elsif p < ALPHA_WARN
        Verdict::Warn
      else
        Verdict::Pass
      end
    end

    private def self.insufficient(name : String, value : String) : TestRow
      TestRow.new(name, value, "insufficient sample", Verdict::Info)
    end

    private def self.fmt(v : Float64) : String
      v.abs < 0.0005 ? "0.00" : v.round(v.abs < 10 ? 3 : 1).to_s
    end

    private def self.pct(frac : Float64) : String
      "#{(frac * 100).round(1)}%"
    end

    private def self.empty_report(sample_count : Int32) : Report
      Report.new(
        sample_count: sample_count, usable_count: 0,
        min_len: 0, max_len: 0, variable_length: false,
        charset_size: 0, charset_label: "—",
        bits_per_char: 0.0, shannon_total: 0.0, effective_entropy: 0.0, length_entropy: 0.0,
        uniqueness: 0.0, duplicate_count: 0, sequential: false, rating: Rating::Critical,
        tests: [TestRow.new("Samples", "0", "no usable tokens", Verdict::Info)],
        char_counts: [] of {UInt8, Int32}, len_hist: [] of Int32, len_min: 0, len_max: 0,
        per_pos_entropy: [] of Float64, bit_bias: [] of Float64)
    end
  end
end
