# ReadPane per-frame cost with a STYLED provider — the Intercept detail preview, the
# Rewriter/OAST output panes, the Probe description pane. Every one of them wraps, and a
# wrapped logical line becomes N visual rows.
#
# `render` already materialises the PLAIN line once per logical line (`cached_li`) for
# exactly that reason. The `styled_at` provider had no such guard, so it ran once per DRAWN
# ROW — and it is the more expensive of the two providers, since it tokenises the line
# rather than just slicing it. One JSON body line wide enough to fill the viewport was
# therefore tokenised ~`rect.h` times per frame. `TextArea#styled_line` carries the same
# memo for the same reason; this is the pane that lacked it.
#
# Two shapes, so the fix is visible where it bites and provably neutral where it doesn't:
#   * WRAPPED long lines  — one logical line per several visual rows (the regression case)
#   * WRAPPED short lines — one logical line per visual row (the memo must not cost anything)
#
# Build: crystal build bench/read_pane_frame_bench.cr -o bin/read_pane_frame_bench --release
# Run:   bin/read_pane_frame_bench
require "benchmark"
require "../src/gori"

include Gori::Tui

# Records nothing: the subject is the row loop and its providers, not cell storage.
class SinkBackend < Backend
  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

W = 100
H =  40

# The Intercept preview's exact wiring: a windowed message, colour through `line_at` and
# plain text through `plain_at` — which is the pane's other half of the same story. It used
# to bridge the text through `Highlight.plain(line_at(i))`, i.e. tokenise the line and then
# discard every colour, so each drawn logical line was styled TWICE a frame.
def wrapped_pane(body : String) : {ReadPane, Highlight::Windowed}
  lines = ("POST /api/v1/submit HTTP/1.1\r\nHost: api.example.com\r\n" \
           "Content-Type: application/json\r\n\r\n#{body}").split('\n').map(&.rstrip('\r'))
  win = Highlight.from_lines_windowed(lines, true)
  pane = ReadPane.new(wrap: true)
  pane.source(win.total, ->(i : Int32) { win.plain_at(i) })
  {pane, win}
end

# LONG lines: each logical line is ~6 visual rows at W=100, so the viewport holds ~7 of them.
long_body = (0...60).map do |i|
  %({"id": #{1000 + i}, "name": "Alice Example #{i}", "email": "a#{i}@example.com", ) +
    %("active": true, "score": -12.5e3, "tags": ["alpha", "beta"], "note": "an ordinary value here"})
end.join("\n")

# SHORT lines: one logical line per visual row — nothing to reuse, so this is the memo's cost.
short_body = (0...200).map { |i| %({"id": #{1000 + i}, "ok": true}) }.join("\n")

{ {"wrapped, long lines (~6 rows/line)", long_body},
 {"wrapped, short lines (1 row/line)", short_body} }.each do |(label, body)|
  pane, win = wrapped_pane(body)
  screen = Screen.new(SinkBackend.new(W, H))
  rect = Rect.new(0, 0, W, H)
  styled = ->(i : Int32) { win.line_at(i) }
  pane.render(screen, rect, true, styled_at: styled) # warm

  puts
  puts "ReadPane#render #{W}x#{H} — #{label}:"
  Benchmark.ips do |x|
    x.report("render (styled)") { pane.render(screen, rect, true, styled_at: styled) }
  end
end
