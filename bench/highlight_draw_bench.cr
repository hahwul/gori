# Highlight.draw micro-benchmark. `draw` renders a styled Line (spans) into Screen
# cells and is the per-visible-line render primitive for the History detail, Repeater,
# Intercept, Fuzzer, Decoder, and Project message panes (16 call sites). It runs for
# every on-screen line per frame during scroll/capture. Unlike Screen#text it walked
# every span with each_grapheme + grapheme_width(g.to_s) + cell(g.to_s) — a String per
# grapheme, even on pure-ASCII HTTP lines (the common case). This drives a realistic
# ~45-line styled viewport and reports bytes/op so the ASCII fast-path win is visible.
#
# Build: crystal build bench/highlight_draw_bench.cr -o bin/highlight_draw_bench --release
# Run:   bin/highlight_draw_bench
require "benchmark"
require "../src/gori/tui"

include Gori::Tui

# Recording backend that keeps only the last glyph (no per-cell grid alloc that would
# dwarf the measurement). We measure Highlight.draw's own cost, not cell storage.
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

W = 120
H =  50
backend = SinkBackend.new(W, H)
screen = Screen.new(backend)

# A realistic captured HTTP/1.1 exchange (ASCII head + JSON body), styled once into
# `Line`s the way the detail view holds them, then drawn every frame.
HEAD = ("HTTP/1.1 200 OK\r\n" +
        "Content-Type: application/json; charset=utf-8\r\n" +
        "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
        "Server: nginx/1.25.0\r\n" +
        "Date: Mon, 15 Jul 2026 12:00:00 GMT\r\n" +
        "X-Request-Id: 7f3a9c2e-1b4d-4e8a-9c1f-2d6b8e0a1c3d\r\n\r\n").to_slice
BODY = begin
  io = IO::Memory.new
  20.times do |i|
    io << %(  {"id": #{1000 + i}, "name": "Alice Example #{i}", "email": "a#{i}@example.com", ) \
      << %("active": true, "score": -12.5e3, "tags": ["alpha", "beta"], "note": "ordinary value"},\n)
  end
  io.to_slice
end

WINDOWED = Highlight.message_windowed(HEAD, BODY, false)
# Materialize the styled Lines for the whole viewport once (open cost isn't measured).
LINES = (0...{WINDOWED.total, H}.min).map { |i| WINDOWED.line_at(i) }
# Reference: the plain (unstyled) glyphs Screen#text draws for the same lines.
PLAIN = LINES.map { |l| l.map(&.text).join }

puts "Highlight.draw over a #{LINES.size}-line ASCII styled viewport (per frame):"
Benchmark.ips do |x|
  x.report("draw viewport (styled)") do
    LINES.each_with_index { |line, y| Highlight.draw(screen, 0, y, line) }
  end
  x.report("ref: screen.text (plain)") do
    PLAIN.each_with_index { |s, y| screen.text(0, y, s, Theme.text) }
  end
end
