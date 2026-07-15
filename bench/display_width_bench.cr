# Screen.display_width micro-benchmark. display_width is the terminal-column measure used
# ~36 places across the TUI (caret placement, label centring, tab widths, h-scroll clamps,
# Highlight.line_width/slice_left) — many per frame on short strings. It grapheme-walked
# every string with grapheme_width(g.to_s), allocating a String per glyph even on pure-ASCII
# labels (the common case), where the width is just the char count. This drives realistic
# short/medium ASCII strings + one CJK string (which must keep the grapheme path).
#
# Build: crystal build bench/display_width_bench.cr -o bin/display_width_bench --release
# Run:   bin/display_width_bench
require "benchmark"
require "../src/gori/tui"

include Gori::Tui

LABEL = "History"                                            # a short tab label
PATH  = "GET /api/v1/users/12345/profile?include=avatar,bio" # a request-line-ish string
HOST  = "api.example.com:8443"                               # a host:port
CJK   = "안녕하세요 세계 — 유니코드 폭 측정"                               # width-2 glyphs (grapheme path)

puts "Screen.display_width (per call):"
Benchmark.ips do |x|
  x.report("ascii short label (#{LABEL.size}B)") { Screen.display_width(LABEL) }
  x.report("ascii request-line (#{PATH.size}B)") { Screen.display_width(PATH) }
  x.report("ascii host:port (#{HOST.size}B)") { Screen.display_width(HOST) }
  x.report("cjk mixed (#{CJK.size} cp)") { Screen.display_width(CJK) }
end

# A representative frame's worth of measures (mix of labels + a couple of longer strings).
puts "\nScreen.display_width x ~30 short + 4 long (a frame's worth):"
Benchmark.ips do |x|
  x.report("frame of display_width") do
    30.times { Screen.display_width(LABEL) }
    4.times { Screen.display_width(PATH) }
    4.times { Screen.display_width(HOST) }
  end
end
