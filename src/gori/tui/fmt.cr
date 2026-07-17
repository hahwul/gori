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
    def self.unit(v : Float64, suffix : String) : String
      v < 10 ? "#{v.round(1)}#{suffix}" : "#{v.round.to_i}#{suffix}"
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
    def self.pct(frac : Float64) : String
      v = frac * 100
      v >= 10 || v <= -10 ? "#{v.round.to_i}%" : "#{v.round(1)}%"
    end

    # A bits figure for the Sequencer's entropy readouts (132b / 5.98b), one decimal
    # below 100 and whole above — same rounding spirit as `unit`.
    def self.bits(v : Float64) : String
      v.abs < 100 ? "#{v.round(1)}b" : "#{v.round.to_i}b"
    end

    # Compact request→response latency (ms/s/m/h), bounded to ≤6 cols. "—" until the
    # response lands; a minute/hour tier keeps very slow flows from overflowing.
    def self.dur(us : Int64?) : String
      return "—" unless us
      ms = us // 1000
      return "#{ms}ms" if ms < 1000
      return "#{(ms / 1000.0).round(1)}s" if ms < 60_000
      return "#{(ms / 60_000.0).round(1)}m" if ms < 3_600_000
      "#{(ms / 3_600_000.0).round(1)}h"
    end
  end
end
