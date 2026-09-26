module Gori::Repeater::Timing
  # The differential-timing math — pure, stdlib-only, deterministic, spec-testable in isolation
  # (no Store / TUI / Repeater-engine dependency). Given the per-pair durations collected by
  # `Timing::Runner`, it computes each variant's quartile distribution, the paired ORDER bias
  # (in how many pairs did A arrive after B), a two-sided binomial sign test on that bias, and a
  # verdict that refuses to overclaim below a floor of usable pairs. Modeled on `Sequencer::Stats`
  # (`src/gori/sequencer/stats.cr`): a pure module returning one immutable `Report`, p-values from
  # `Math.erfc` (normal tail), a `SMALL_SAMPLE` guard that softens the verdict.
  #
  # WHY ORDER, NOT LATENCY (#1246, PortSwigger "Listen to the whispers", 2024). Absolute latency is
  # dominated by network + server-load noise that a single Repeater send cannot see past. But when A
  # and B are released in the SAME narrow window (the single-packet attack / last-byte-sync race,
  # #1236), that noise is COMMON to both, so the SIGN of (A − B) survives it: if A is genuinely
  # processed slower, A arrives second in a consistent majority of pairs even when both durations
  # jitter together. The quartiles are reported alongside so the operator sees the spread, but the
  # VERDICT is taken on the order bias — a differential oracle, never an absolute-latency SLA.
  module Stats
    # Default / ceiling / warm-up for the sampling loop. Kept here so every surface names one home.
    DEFAULT_ITERATIONS =  30
    MAX_ITERATIONS     = 500
    DEFAULT_WARMUP     =   3

    # Below this many USABLE pairs (both members answered) the sign test's normal approximation is
    # unreliable and a real effect is as likely swamped as shown, so the verdict is clamped to
    # `Inconclusive` regardless of the count split — the "report confidence without overclaiming"
    # guard (`Sequencer::Stats::SMALL_SAMPLE` is the same number for the same reason).
    SMALL_SAMPLE = 20

    # Two-sided significance the sign test must clear to name a slower side. 0.01, not 0.05: this is
    # an oracle an operator will act on, and one differential run is cheap to repeat with a larger N,
    # so the cost of a false "A is slower" is higher than the cost of an unconfirmed "no difference".
    ALPHA = 0.01

    # Default bucket count for a distribution histogram — a fixed width the JSON reports verbatim
    # (a consumer can re-bin) and the TUI overrides with its pane width. 24 reads a bimodal spread.
    HIST_BINS = 24

    # One A/B pair's release-relative durations, in microseconds. `nil` = that member did not answer
    # this pair (an error / timeout), so the pair is dropped from BOTH the order test and that
    # member's quartiles — a missing sample is not a fast or a slow one.
    record Sample, a_us : Int64?, b_us : Int64?

    enum Verdict
      ASlower
      BSlower
      NoDifference
      Inconclusive

      def label : String
        case self
        in ASlower      then "A consistently slower"
        in BSlower      then "B consistently slower"
        in NoDifference then "no measurable difference"
        in Inconclusive then "inconclusive"
        end
      end
    end

    # One variant's arrival-time distribution, all microseconds. `n` is the count of pairs in which
    # this member answered; the quartiles are over exactly those samples. `samples` is the ASCENDING
    # raw list, kept so a surface can histogram it at its own bucket width (`Stats.histogram`).
    record VariantDist,
      n : Int32,
      min : Int64,
      q1 : Float64,
      median : Float64,
      q3 : Float64,
      max : Int64,
      samples : Array(Int64)

    record Report,
      iterations : Int32,  # pairs actually sent (after warm-up), whatever their outcome
      pairs_valid : Int32, # pairs where BOTH members answered — the order test's denominator
      a : VariantDist,
      b : VariantDist,
      a_slower : Int32, # pairs where A arrived AFTER B
      b_slower : Int32, # pairs where B arrived after A
      ties : Int32,     # pairs with identical microsecond durations
      a_slower_frac : Float64,
      median_gap_us : Float64, # median(A) − median(B); sign matches the verdict, |·| is the effect
      p_value : Float64,
      verdict : Verdict do
      # One line for the verdict banner / the CLI summary — the shape `Sequencer::Report#rationale`
      # has, phrased for a differential oracle.
      # The pairs that decided a direction (ties carry none) — the sign test's and the
      # order-bias fraction's denominator. Naming it in the rationale keeps `pct × denom == count`.
      def decisive : Int32
        a_slower + b_slower
      end

      def rationale : String
        case verdict
        in Verdict::Inconclusive
          pairs_valid == 0 ? "no pair had both responses" : "only #{pairs_valid} usable pair#{pairs_valid == 1 ? "" : "s"} — need ≥ #{SMALL_SAMPLE}"
        in Verdict::NoDifference
          "A slower in #{a_slower}/#{decisive} decisive pairs (#{pct(a_slower_frac)}, p=#{Stats.fmt_p(p_value)} — within noise)"
        in Verdict::ASlower
          "A slower in #{a_slower}/#{decisive} decisive pairs (#{pct(a_slower_frac)}) · median +#{Stats.fmt_us(median_gap_us.abs.round.to_i64)} (p=#{Stats.fmt_p(p_value)})"
        in Verdict::BSlower
          "B slower in #{b_slower}/#{decisive} decisive pairs (#{pct(1.0 - a_slower_frac)}) · median +#{Stats.fmt_us(median_gap_us.abs.round.to_i64)} (p=#{Stats.fmt_p(p_value)})"
        end
      end

      # The two variants' shared microsecond scale, for a histogram drawn with both rows
      # comparable. An EMPTY variant (n=0, so its min/max are the 0 defaults) is skipped — else a
      # side that never answered would drag the shared lower bound to 0 and squash the live side's
      # distribution against the top of the range.
      def hist_min : Int64
        vals = [] of Int64
        vals << a.min if a.n > 0
        vals << b.min if b.n > 0
        vals.min? || 0_i64
      end

      def hist_max : Int64
        vals = [] of Int64
        vals << a.max if a.n > 0
        vals << b.max if b.n > 0
        vals.max? || 0_i64
      end

      private def pct(f : Float64) : String
        "#{(f * 100).round.to_i}%"
      end
    end

    # The ONE microsecond formatter (µs / ms / s) and p-value formatter for every surface — the
    # `Report` rationale, the CLI/MCP `Present` text, and the TUI card all call these so the three
    # cannot print the same figure differently. Kept in the engine layer (no `CLI::Output`).
    def self.fmt_us(us : Int64) : String
      if us < 1_000
        "#{us}µs"
      elsif us < 1_000_000
        "#{(us / 1_000.0).round(1)}ms"
      else
        "#{(us / 1_000_000.0).round(2)}s"
      end
    end

    def self.fmt_p(p : Float64) : String
      p < 0.001 ? "<0.001" : p.round(3).to_s
    end

    def self.analyze(samples : Array(Sample)) : Report
      iterations = samples.size
      a_vals = samples.compact_map(&.a_us)
      b_vals = samples.compact_map(&.b_us)

      a_slower = 0
      b_slower = 0
      ties = 0
      samples.each do |s|
        av = s.a_us
        bv = s.b_us
        next unless av && bv # a dropped member is not a win for either side
        if av > bv
          a_slower += 1
        elsif bv > av
          b_slower += 1
        else
          ties += 1
        end
      end
      pairs_valid = a_slower + b_slower + ties

      # Order-bias fraction over the DECISIVE pairs (ties carry no direction). With no decisive pair
      # the fraction is 0.5 — perfectly undecided — so the verdict falls to NoDifference/Inconclusive.
      decisive = a_slower + b_slower
      a_slower_frac = decisive == 0 ? 0.5 : a_slower.to_f / decisive

      # Two-sided binomial sign test against p=0.5 with a continuity correction, p from the normal
      # tail (`Math.erfc`) — the closed-form `Sequencer::Stats` uses. Read on the DECISIVE count.
      p_value =
        if decisive == 0
          1.0
        else
          z = (2 * a_slower - decisive).abs.to_f
          z = (z - 1.0).clamp(0.0, Float64::INFINITY) # continuity correction
          z /= Math.sqrt(decisive.to_f)
          Math.erfc(z / Math.sqrt(2.0))
        end

      a_dist = distribution(a_vals)
      b_dist = distribution(b_vals)
      median_gap = a_dist.median - b_dist.median

      verdict =
        if pairs_valid < SMALL_SAMPLE
          Verdict::Inconclusive
        elsif p_value >= ALPHA
          Verdict::NoDifference
        elsif a_slower_frac > 0.5
          Verdict::ASlower
        else
          Verdict::BSlower
        end

      Report.new(
        iterations: iterations, pairs_valid: pairs_valid,
        a: a_dist, b: b_dist,
        a_slower: a_slower, b_slower: b_slower, ties: ties,
        a_slower_frac: a_slower_frac, median_gap_us: median_gap,
        p_value: p_value, verdict: verdict)
    end

    private def self.distribution(vals : Array(Int64)) : VariantDist
      return VariantDist.new(0, 0_i64, 0.0, 0.0, 0.0, 0_i64, [] of Int64) if vals.empty?
      sorted = vals.sort
      VariantDist.new(
        n: sorted.size,
        min: sorted.first,
        q1: percentile(sorted, 0.25),
        median: percentile(sorted, 0.50),
        q3: percentile(sorted, 0.75),
        max: sorted.last,
        samples: sorted)
    end

    # Linear-interpolation percentile over an ASCENDING array (the "R-7" / Excel method): rank
    # `q*(n-1)`, interpolate between the two straddling samples. `q` in [0,1].
    def self.percentile(sorted : Array(Int64), q : Float64) : Float64
      return 0.0 if sorted.empty?
      return sorted.first.to_f if sorted.size == 1
      rank = q * (sorted.size - 1)
      lo = rank.floor.to_i
      hi = rank.ceil.to_i
      return sorted[lo].to_f if lo == hi
      frac = rank - lo
      sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    end

    # Per-bin counts of `vals` over `bins` equal-width bins across [min,max]. Left-inclusive, the max
    # value lands in the last bin; min==max puts everything in bin 0. A PURE twin of
    # `Tui::Spark.histogram` (this module must not reach into the TUI layer — `spec/layering_spec.cr`),
    # so both the JSON `Present` and the TUI overlay share one binning rule by calling THIS.
    def self.histogram(vals : Array(Int64), bins : Int32, min : Float64, max : Float64) : Array(Int32)
      counts = Array(Int32).new(bins, 0)
      return counts if bins <= 0 || vals.empty?
      if max <= min
        counts[0] = vals.size
        return counts
      end
      span = max - min
      vals.each do |v|
        idx = ((v.to_f - min) / span * bins).floor.to_i
        counts[idx.clamp(0, bins - 1)] += 1
      end
      counts
    end
  end
end
