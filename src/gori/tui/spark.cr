module Gori::Tui
  # Compact in-terminal microcharts for the Fuzzer DIST pane. Pure functions (no
  # Screen/Theme) — width-safe (every glyph is exactly one terminal column) and
  # spec-testable. Sibling to Fmt: one place for the block-element math so bars and
  # sparklines round identically everywhere.
  module Spark
    FULL    = '█'        # U+2588 full block
    EIGHTHS = "▏▎▍▌▋▊▉"  # U+258F..U+2589 — 1/8 .. 7/8 left-fill, rising width
    LEVELS  = "▁▂▃▄▅▆▇█" # U+2581..U+2588 — 8 rising levels for sparklines

    # A horizontal bar of `value/max`, exactly `width` columns wide: full blocks plus
    # one fractional 1/8th cell, space-padded so display width == width. value<=0 or
    # max<=0 → all spaces; a nonzero value always shows ≥ a 1/8 sliver (so a lone
    # count-of-1 bar is still visible — the anomaly cue).
    def self.bar(value : Int | Float, max : Int | Float, width : Int32) : String
      return "" if width <= 0
      return " " * width if max.to_f <= 0 || value.to_f <= 0
      frac = (value.to_f / max.to_f).clamp(0.0, 1.0)
      eighths = (frac * width * 8).round.to_i
      eighths = 1 if eighths < 1 # guarantee a visible sliver for value > 0
      eighths = width * 8 if eighths > width * 8
      full = eighths // 8
      rem = eighths % 8
      String.build do |io|
        full.times { io << FULL }
        if rem > 0 && full < width
          io << EIGHTHS[rem - 1] # rem ∈ 1..7 → EIGHTHS[0..6]
          full += 1
        end
        (width - full).times { io << ' ' }
      end
    end

    # A sparkline of `▁..█` from per-bucket counts, scaled to the tallest bucket. Zero
    # buckets render as a blank (so an outlier bucket pops out of empty space); any
    # nonzero bucket shows at least `▁`. All-zero / empty → blanks. Result is exactly
    # `width` (default counts.size) columns.
    def self.line(counts : Array(Int32), width : Int32? = nil) : String
      w = width || counts.size
      return "" if w <= 0
      data = fit(counts, w)
      max = data.max? || 0
      return " " * w if max <= 0
      String.build do |io|
        data.each do |c|
          if c <= 0
            io << ' '
          else
            lvl = ((c.to_f / max) * (LEVELS.size - 1)).round.to_i
            io << LEVELS[lvl.clamp(0, LEVELS.size - 1)]
          end
        end
      end
    end

    # Per-bin counts of `values` over `bins` equal-width bins across [min,max]
    # (defaults to the data's own min/max). Left-inclusive bins; the max value lands
    # in the last bin (top-inclusive). Values outside an explicit [min,max] clamp into
    # the edge bins. min==max (all identical / single value) → everything in bin 0 (a
    # single spike — the "no spread" signal). Generic over Int32/Int64/Float.
    def self.histogram(values : Array(T), bins : Int32, min : Float64? = nil, max : Float64? = nil) : Array(Int32) forall T
      return [] of Int32 if bins <= 0
      counts = Array(Int32).new(bins, 0)
      return counts if values.empty?
      lo = min || values.min.to_f
      hi = max || values.max.to_f
      if hi <= lo
        counts[0] = values.size
        return counts
      end
      span = hi - lo
      values.each do |v|
        idx = ((v.to_f - lo) / span * bins).floor.to_i
        counts[idx.clamp(0, bins - 1)] += 1
      end
      counts
    end

    # Resize `counts` to exactly `w` entries. Equal → identity (the normal path, since
    # the histogram is built with bins = pane width). Shorter → right-pad with zeros.
    # Longer → max-pool so an outlier bucket survives the squeeze.
    private def self.fit(counts : Array(Int32), w : Int32) : Array(Int32)
      return counts if counts.size == w
      return Array(Int32).new(w) { |i| counts[i]? || 0 } if counts.size < w
      Array(Int32).new(w) do |i|
        lo = i * counts.size // w
        hi = {(i + 1) * counts.size // w, lo + 1}.max
        (lo...hi).max_of { |j| counts[j] }
      end
    end
  end
end
