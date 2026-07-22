# Screen#cell allocation micro-benchmark. `cell` is the universal draw primitive; a
# per-Char `to_s` allocated a fresh 1-char String on every cell. This drives a realistic
# frame (full-screen fill + text rows) and reports bytes/op so the interning win is visible.
#
# Build: crystal build bench/screen_cell_bench.cr -o bin/screen_cell_bench --release
# Run:   bin/screen_cell_bench
require "benchmark"
require "../src/gori/tui"

include Gori::Tui

# A minimal recording backend that keeps only the last glyph (no per-cell grid alloc that
# would dwarf the measurement) — we're measuring Screen#cell's own allocation, not storage.
class SinkBackend < Backend
  @last = ' '.as(Char | String)

  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
    @last = grapheme
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

W    = 200
H    =  50
backend = SinkBackend.new(W, H)
screen = Screen.new(backend)
LINE = "GET /api/v1/users/12345/profile?include=avatar HTTP/1.1  200  1.4kB  api.example.com"

puts "Screen frame draw (fill #{W}x#{H} + #{H} text rows):"
Benchmark.ips do |x|
  x.report("full-frame fill + text rows") do
    screen.fill(Rect.new(0, 0, W, H), Theme.bg)
    H.times { |y| screen.text(2, y, LINE, Theme.text) }
  end
end
