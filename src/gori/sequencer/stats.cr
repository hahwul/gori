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

      # Per-symbol-bit bias over the fixed common prefix (feeds the chart + a test).
      prefix_bits = min_len * bps
      ones_at = Array(Int32).new(prefix_bits, 0)
      if bps > 0
        usable.each do |t|
          sl = t.to_slice
          (0...min_len).each do |p|
            v = idx_of.unsafe_fetch(sl[p])
            (0...bps).each { |k| ones_at[p * bps + k] += 1 if (v >> (bps - 1 - k)) & 1 == 1 }
          end
        end
      end
      bit_bias = ones_at.map { |c| (c.to_f / n - 0.5).abs }

      bits = symbol_bits(usable, idx_of, bps, total_bytes)
      sym_seq = symbol_seq(usable, idx_of, total_bytes)
      seq, seq_detail = detect_sequential(usable)

      tests = [] of TestRow
      tests << uniqueness_test(unique, n, duplicate_count)
      tests << TestRow.new("Sequential", seq ? "detected" : "none", seq_detail,
        seq ? Verdict::Fail : Verdict::Pass)
      tests << gate_bits(monobit_test(bits, small), pow2)
      tests << gate_bits(poker_test(bits, small), pow2)
      tests << gate_bits(runs_test(bits, small), pow2)
      tests << gate_bits(longrun_test(bits, small), pow2)
      tests << chi_square_test(gcounts, present, total_bytes, small)
      tests << serial_test(sym_seq, small)
      tests << compression_test(usable, total_bytes, charset_size, small)
      tests << gate_bits(bit_bias_test(ones_at, n, small), pow2)

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
    private def self.compression_test(tokens : Array(String), bytes : Int64,
                                      charset_size : Int32, small : Bool) : TestRow
      return insufficient("Compression", "#{bytes} bytes") if bytes < 64
      # Cap the deflate input. The ratio is a stable statistic long before the whole sample is
      # consumed, but `tokens.join` over a full 50k-token sample built a multi-MB String (from
      # a String.build starting at capacity 64, so a realloc chain on top) and then deflated
      # every byte of it — on a path the TUI re-runs on a throttle and every MCP poll re-runs
      # from scratch. Whole tokens only, so a token is never split mid-value.
      raw = join_capped(tokens, COMPRESS_SCAN_CAP)
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
      # General path — correlation of arrival order with a leading-byte magnitude. Shares
      # the same order-dependency the numeric fast path had above (arrival order can be
      # shuffled by concurrency), but isn't fixed here — a coordinate-only fix couldn't
      # reuse the sort-then-diff trick since this path also weighs HOW closely order
      # tracks magnitude, not just whether the values are evenly spaced.
      xs = Array(Float64).new(n, &.to_f)
      ys = tokens.map { |t| leading_value(t) }
      r = pearson(xs, ys)
      {r.abs > 0.9, "corr=#{fmt(r)}"}
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
    # Concatenated token bytes, stopping at the first WHOLE token that would cross `cap` (so a
    # token is never split mid-value). Presized, unlike `tokens.join`.
    private def self.join_capped(tokens : Array(String), cap : Int32) : Bytes
      total = 0
      taken = 0
      tokens.each do |t|
        break if total + t.bytesize > cap && taken > 0
        total += t.bytesize
        taken += 1
      end
      buf = Bytes.new(total)
      off = 0
      taken.times do |i|
        sl = tokens.unsafe_fetch(i).to_slice
        sl.copy_to(buf.to_unsafe + off, sl.size)
        off += sl.size
      end
      buf
    end

    # Presized: the final length is known exactly (total sample bytes × bps), and growing from
    # capacity 0 to the millions of elements a full sample produces means ~20 doubling reallocs,
    # each copying everything written so far.
    private def self.symbol_bits(tokens : Array(String), idx_of : Array(Int32), bps : Int32,
                                 total_bytes : Int64) : Array(UInt8)
      return [] of UInt8 if bps <= 0
      bits = Array(UInt8).new((total_bytes * bps).to_i)
      tokens.each do |t|
        t.to_slice.each do |b|
          v = idx_of.unsafe_fetch(b)
          (bps - 1).downto(0) { |k| bits << ((v >> k) & 1).to_u8 }
        end
      end
      bits
    end

    # The concatenated sequence of alphabet indices (for serial correlation). Presized for the
    # same reason as symbol_bits.
    private def self.symbol_seq(tokens : Array(String), idx_of : Array(Int32),
                                total_bytes : Int64) : Array(Int32)
      seq = Array(Int32).new(total_bytes.to_i)
      tokens.each { |t| t.to_slice.each { |b| seq << idx_of.unsafe_fetch(b) } }
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
