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
      bit_bias : Array(Float64) do
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

      # Global byte-frequency table (drives Shannon/char-set/chi-square/char chart).
      gcounts = Array(Int32).new(256, 0)
      total_bytes = 0_i64
      usable.each do |t|
        t.to_slice.each do |b|
          gcounts[b] += 1
          total_bytes += 1
        end
      end
      present = [] of UInt8
      gcounts.each_with_index { |c, i| present << i.to_u8 if c > 0 }
      charset_size = present.size
      charset_label = classify(present)
      bits_per_char = shannon(gcounts, total_bytes)

      # Per-position entropy + the headline effective-entropy budget
      # (Σ log2(distinct bytes seen at each position over the common prefix)).
      per_pos = Array(Float64).new(min_len, 0.0)
      effective = 0.0
      (0...min_len).each do |p|
        col = Array(Int32).new(256, 0)
        usable.each { |t| col[t.to_slice[p]] += 1 }
        distinct = col.count(&.positive?)
        per_pos[p] = shannon(col, n.to_i64)
        effective += Math.log2(distinct.to_f) if distinct > 0
      end
      shannon_total = per_pos.sum

      lcounts = Hash(Int32, Int32).new(0)
      lengths.each { |l| lcounts[l] += 1 }
      length_entropy = shannon_hash(lcounts, n)

      unique = usable.uniq.size
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
      idx_of = Hash(UInt8, Int32).new
      present.each_with_index { |b, i| idx_of[b] = i }
      bps = charset_size <= 1 ? 0 : Math.log2(charset_size.to_f).ceil.to_i

      # Per-symbol-bit bias over the fixed common prefix (feeds the chart + a test).
      prefix_bits = min_len * bps
      ones_at = Array(Int32).new(prefix_bits, 0)
      if bps > 0
        usable.each do |t|
          sl = t.to_slice
          (0...min_len).each do |p|
            v = idx_of[sl[p]]
            (0...bps).each { |k| ones_at[p * bps + k] += 1 if (v >> (bps - 1 - k)) & 1 == 1 }
          end
        end
      end
      bit_bias = ones_at.map { |c| (c.to_f / n - 0.5).abs }

      bits = symbol_bits(usable, idx_of, bps)
      sym_seq = symbol_seq(usable, idx_of)
      seq, seq_detail = detect_sequential(usable)

      tests = [] of TestRow
      tests << uniqueness_test(unique, n, duplicate_count)
      tests << TestRow.new("Sequential", seq ? "detected" : "none", seq_detail,
        seq ? Verdict::Fail : Verdict::Pass)
      tests << monobit_test(bits, small)
      tests << poker_test(bits, small)
      tests << runs_test(bits, small)
      tests << longrun_test(bits, small)
      tests << chi_square_test(gcounts, present, total_bytes, small)
      tests << serial_test(sym_seq, small)
      tests << compression_test(usable, total_bytes, charset_size, small)
      tests << bit_bias_test(ones_at, n, small)

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
        per_pos_entropy: per_pos, bit_bias: bit_bias)
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
    private def self.compression_test(tokens : Array(String), bytes : Int64,
                                      charset_size : Int32, small : Bool) : TestRow
      return insufficient("Compression", "#{bytes} bytes") if bytes < 64
      raw = tokens.join.to_slice
      io = IO::Memory.new
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
      TestRow.new("Compression", fmt(ratio), "floor #{fmt(floor)}", verdict)
    end

    private def self.bit_bias_test(ones_at : Array(Int32), n : Int32, small : Bool) : TestRow
      total = ones_at.size
      return insufficient("Bit bias", "no fixed prefix") if total == 0 || n < SMALL_SAMPLE
      biased = 0
      ones_at.each do |c|
        z = (2.0 * c - n) / Math.sqrt(n.to_f)
        biased += 1 if z.abs > 2.58
      end
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
          deltas = (1...vals.size).map { |i| vals[i] - vals[i - 1] }
          return {true, deltas.uniq.size == 1 ? "constant step #{deltas.first}" : (inc ? "monotonic up" : "monotonic down")}
        end
        return {false, "non-monotonic"}
      end
      # General path — correlation of arrival order with a leading-byte magnitude.
      xs = Array(Float64).new(n, &.to_f)
      ys = tokens.map { |t| leading_value(t) }
      r = pearson(xs, ys)
      {r.abs > 0.9, "corr=#{fmt(r)}"}
    end

    private def self.leading_value(t : String) : Float64
      v = 0.0
      t.to_slice[0, {8, t.bytesize}.min].each { |b| v = v * 256.0 + b }
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
      den = Math.sqrt((m * sx2 - sx * sx) * (m * sy2 - sy * sy))
      den == 0 ? 0.0 : (m * sxy - sx * sy) / den
    end

    # ── shared numeric helpers ──────────────────────────────────────────────────────

    # The concatenated symbol bitstream: each byte → its alphabet index → `bps` bits
    # (MSB-first). Empty when the alphabet has ≤ 1 symbol (no bits to test).
    private def self.symbol_bits(tokens : Array(String), idx_of : Hash(UInt8, Int32), bps : Int32) : Array(UInt8)
      bits = [] of UInt8
      return bits if bps <= 0
      tokens.each do |t|
        t.to_slice.each do |b|
          v = idx_of[b]
          (bps - 1).downto(0) { |k| bits << ((v >> k) & 1).to_u8 }
        end
      end
      bits
    end

    # The concatenated sequence of alphabet indices (for serial correlation).
    private def self.symbol_seq(tokens : Array(String), idx_of : Hash(UInt8, Int32)) : Array(Int32)
      seq = [] of Int32
      tokens.each { |t| t.to_slice.each { |b| seq << idx_of[b] } }
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

    private def self.grade(p : Float64, small : Bool) : Verdict
      if p < 0.01
        small ? Verdict::Warn : Verdict::Fail
      elsif p < 0.05
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
