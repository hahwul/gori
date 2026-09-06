# `Screen#fill` micro-benchmark. Every frame starts with a full-screen fill (`Runner#render`)
# and ~150 more sites fill a card or a selected row, so the fill is the frame's largest fixed
# cost. It used to go through `Screen#cell` → `Backend#put` per cell (bounds checks, the ASCII
# intern, `accepted_width`, a `cont?` fetch, a `GridCell.new`); `Backend#fill_span` writes one
# known-width-1 blank straight into the grid instead, and handles the wide-glyph edge cases
# only at the two ends of the span. This drives the production `TermisuBackend` against a
# recording terminal double so the measured path is the real one.
#
# Build: crystal build bench/fill_span_bench.cr -o bin/fill_span_bench --release
# Run:   bin/fill_span_bench
require "benchmark"
require "../src/gori"

include Gori::Tui

# The duck-typed terminal `TermisuBackend` is generic over: records nothing, so the cost
# measured is the grid write, not the terminal.
class SinkTerm
  def initialize(@w : Int32, @h : Int32)
  end

  def set_cell(x : Int32, y : Int32, g : String, *, fg : Color, bg : Color, attr : Attribute) : Bool
    true
  end

  def render : Nil
  end

  def sync : Nil
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

W = 200
H =  50
backend = TermisuBackend.new(SinkTerm.new(W, H))
screen = Screen.new(backend)
full = Rect.new(0, 0, W, H)
row = Rect.new(2, 10, W - 4, 1)

puts "full-screen fill #{W}x#{H} (the top of every frame), and one selected-row band:"
Benchmark.ips do |x|
  x.report("fill full screen via fill_span") { screen.fill(full, Theme.bg) }
  x.report("fill full screen cell by cell") do
    (full.y...full.bottom).each do |yy|
      (full.x...full.right).each { |xx| screen.cell(xx, yy, ' ', Theme.text, Theme.bg) }
    end
  end
  x.report("fill one row band via fill_span") { screen.fill(row, Theme.accent_bg) }
end
