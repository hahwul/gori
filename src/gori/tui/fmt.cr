module Gori::Tui
  # Compact, fixed-width formatters for the frequently-scanned size/latency cells
  # shared by the History list and the Repeater response pane. Pure functions (no
  # Screen/Theme) so any view can reuse them — kept here so there is ONE rounding
  # convention (e.g. 1023.6 KB rolls up to "1.0MB", not the misleading "1024KB").
  module Fmt
    # Compact response size (B/KB/MB/GB), bounded to ≤6 cols. "—" until the response
    # lands. The unit is picked from the ROUNDED magnitude so a value just under a
    # boundary (e.g. 1023.6 KB) rolls up to the next unit ("1.0MB") instead of the
    # misleading "1024KB".
    def self.size(bytes : Int64?) : String
      return "—" unless bytes
      return "#{bytes}B" if bytes < 1024
      kb = bytes / 1024.0
      return unit(kb, "KB") if kb.round < 1024
      mb = bytes / 1_048_576.0
      return unit(mb, "MB") if mb.round < 1024
      unit(bytes / 1_073_741_824.0, "GB")
    end

    # One decimal under 10 (3.4KB), whole at/above (345KB) — keeps the cell ≤6 cols.
    #
    # `to_i64`, and the finite/range guard, because THIS is where every formatter in this
    # module ends and `Float64#to_i` is Crystal's CHECKED conversion into **Int32**: any
    # rounded magnitude past 2.1e9 raised `OverflowError` here, on the render path. That is
    # reachable from stored data, not just from arithmetic — an imported HAR's `"time"` is
    # carried into `duration_us` as-is (`Import::Har.parse_time` only bounds it at
    # `Int64::MAX`), so a HAR declaring `"time": 8e15` makes `dur` raise every time the
    # History row is drawn: the same frame fails again 50ms later, three strikes trip the
    # Runner's tick breaker, and the process ends. A number too big to spell is a formatting
    # problem and must read like one — "∞" says the cell could not be rendered, where a
    # backtrace said the session was over.
    def self.unit(v : Float64, suffix : String) : String
      v < 10 ? "#{v.round(1)}#{suffix}" : whole(v.round, suffix)
    end

    # The ONE place a Float64 magnitude becomes a whole number for display — `unit`, `pct` and
    # `bits` all end here, because each of them wrote `v.round.to_i` separately and each was
    # separately able to raise. A value that cannot be spelled says so in the cell rather than
    # taking the frame down: NaN (a statistic computed over nothing) reads as the module's
    # usual "—", and a magnitude past Int64 as "∞".
    #
    # The upper bound is STRICT and the lower one is not, which is not a slip: `Int64::MIN` is
    # a power of two and converts to Float64 exactly, while `Int64::MAX.to_f64` rounds UP to
    # 2^63 — one more than Int64 can hold. `v <= Int64::MAX.to_f64` therefore admits exactly
    # the value that then overflows `to_i64`, in the function written to stop that.
    private def self.whole(v : Float64, suffix : String) : String
      return "—" if v.nan?
      return "#{v < 0 ? "-∞" : "∞"}#{suffix}" unless Int64::MIN.to_f64 <= v < Int64::MAX.to_f64
      "#{v.to_i64}#{suffix}"
    end

    # Compact occurrence count (1.2k / 3.4M / 5.0B) for tallies that can grow
    # unbounded (e.g. Probe hit_count). Plain integer below 1000; same rounding
    # convention as `size` so a value just under a boundary rolls up to the next
    # unit instead of showing a misleading "1000k".
    def self.count(n : Int64) : String
      return n.to_s if n < 1000
      k = n / 1000.0
      return unit(k, "k") if k.round < 1000
      m = n / 1_000_000.0
      return unit(m, "M") if m.round < 1000
      unit(n / 1_000_000_000.0, "B")
    end

    # A fraction (0.0–1.0) as a percentage: whole at/above 10% (27%), one decimal below
    # (3.4%). Used by the Sequencer's entropy/uniqueness readouts.
    #
    # NaN is routed to `whole` rather than left to the decimal branch: `pct` is the formatter
    # fed a RATIO, and `uniqueness` is `unique.to_f / n` — the 0/0 that `whole`'s comment calls
    # "a statistic computed over nothing". Both of the old comparisons are false for NaN, so it
    # fell through and printed "NaN%" while `bits` printed the module's dash for the same
    # quantity. One spelling for one condition.
    def self.pct(frac : Float64) : String
      v = frac * 100
      return whole(v, "%") if v.nan?
      v >= 10 || v <= -10 ? whole(v.round, "%") : "#{v.round(1)}%"
    end

    # A bits figure for the Sequencer's entropy readouts (132b / 5.98b), one decimal
    # below 100 and whole above — same rounding spirit as `unit`.
    def self.bits(v : Float64) : String
      v.abs < 100 ? "#{v.round(1)}b" : whole(v.round, "b")
    end

    # Compact request→response latency (µs/ms/s/m/h), bounded to ≤6 cols. "—" until the
    # response lands; a minute/hour tier keeps very slow flows from overflowing.
    #
    # The store's unit is MICROseconds, so the sub-millisecond tier is not a nicety: a
    # loopback or LAN target answers in 100–900 µs, and integer-truncating to ms rendered
    # every one of those as a flat "0ms". That is worst in the Fuzzer, where `dur` labels
    # both the result rows and the DIST time histogram's min/max — a timing side-channel
    # reads as "0ms → 0ms" with the whole spread collapsed. Same rounding convention as
    # `size`/`count`: pick the unit from the ROUNDED magnitude so 999.6 ms rolls up to
    # "1.0s" rather than the misleading "1000ms".
    def self.dur(us : Int64?) : String
      return "—" unless us
      return "#{us}µs" if us < 1000
      ms = us / 1000.0
      return unit(ms, "ms") if ms.round < 1000
      s = us / 1_000_000.0
      return unit(s, "s") if s.round < 60
      m = us / 60_000_000.0
      return unit(m, "m") if m.round < 60
      unit(us / 3_600_000_000.0, "h")
    end

    # Compact relative age — "3s" / "5m" / "2h" / "1d" — for a row that reports how long ago
    # something happened. Three overlays each carried a private copy of these eight lines
    # (the OAST session picker, the notifications centre, the TLS passthrough inventory),
    # identical apart from one guard, which is the reason this lives here now.
    #
    # That guard: elapsed is CLAMPED AT ZERO. Two of the three read a wall-clock `Time`, which
    # can move backwards under an NTP correction or when the record was written by another
    # machine — the passthrough list lacked the clamp and would render `-5s` for a bypass it
    # believed happened in the future. The notifications centre is safe by construction
    # (`Time::Instant` is monotonic) and passes through the same door anyway.
    def self.ago(seconds : Int64) : String
      secs = {seconds, 0_i64}.max
      return "#{secs}s" if secs < 60
      mins = secs // 60
      return "#{mins}m" if mins < 60
      hours = mins // 60
      return "#{hours}h" if hours < 24
      "#{hours // 24}d"
    end

    # Wall-clock overload. `Time.local - t` is a Span; the clamp above is what makes a
    # backwards clock render "0s" rather than a negative age.
    def self.ago(t : Time) : String
      ago((Time.local - t).total_seconds.to_i64)
    end

    # Monotonic overload — process-relative instants, which cannot run backwards.
    def self.ago(t : Time::Instant) : String
      ago((Time.instant - t).total_seconds.to_i64)
    end
  end
end
