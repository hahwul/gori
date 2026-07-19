# FuzzerView per-frame render cost during a LIVE run — the busiest moment in the tool: results
# stream in, every one forces a redraw, and the results pane plus the open detail pane are both
# redrawn in full each time.
#
# Two shapes that used to scale with the whole result set rather than the visible rows:
#   * matched_count — a rev-keyed memo whose key bumped on every appended result, so the full
#     count(&.matched?) scan over RESULT_CAP rows ran on every frame of a live run anyway.
#   * the detail pane's selection spans — rebuilt once per DRAWN ROW inside the row loop, then
#     all but the matching line discarded.
#
# Build: crystal build bench/fuzz_view_frame_bench.cr -o bin/fuzz_view_frame_bench --release
# Run:   bin/fuzz_view_frame_bench
require "benchmark"
require "../src/gori/tui"
require "../spec/support/memory_backend"

include Gori::Tui

W = 160
H =  48

def result(idx : Int32, matched : Bool, body_lines : Int32 = 40) : Gori::Fuzz::Result
  head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nServer: nginx\r\n\r\n".to_slice
  body = String.build do |io|
    body_lines.times { |i| io << %({"row":) << i << %(,"label":"value ) << i << "\"}\n" }
  end.to_slice
  Gori::Fuzz::Result.new(idx.to_i64, ["payload#{idx}"], nil, 200, body.size.to_i64, 120, 41,
    (1000 + idx * 7).to_i64, nil, matched, false, nil,
    head: matched ? head : nil, body: matched ? body : nil,
    request: matched ? head : nil)
end

def build_view(n : Int32) : FuzzerView
  view = FuzzerView.new
  view.load_request("https://api.example.com",
    "POST /api/v1/search?q=§term§ HTTP/1.1\r\nHost: api.example.com\r\n\r\n", false, "")
  view.begin_run(n.to_i64)
  n.times { |i| view.append_result(result(i, i % 7 == 0)) }
  view
end

FULL = build_view(Gori::Tui::FuzzerView::RESULT_CAP)

# Same view with the detail pane open on a matched row — exercises the per-row chrome path.
DETAIL = begin
  v = build_view(Gori::Tui::FuzzerView::RESULT_CAP)
  v.focus_pane(:results)
  v.open_detail
  v
end

# Detail open on a LARGE response with a selection spanning the whole body. This is the shape
# the per-row span rebuild punished: highlight_spans emits one tuple per selected line, and it
# used to run once per DRAWN ROW, so the cost was rows x selected-lines per frame.
BIG_SEL = begin
  v = FuzzerView.new
  v.load_request("https://api.example.com", "GET /big HTTP/1.1\r\nHost: api.example.com\r\n\r\n", false, "")
  v.begin_run(1_i64)
  v.append_result(result(0, true, body_lines: 3000))
  v.focus_pane(:results)
  v.open_detail
  3000.times { v.detail_move(1, 0, selecting: true) } # select the whole body
  v
end

backend = MemoryBackend.new(W, H)
screen = Screen.new(backend)
rect = Rect.new(0, 0, W, H)

puts "FuzzerView frame render, #{Gori::Tui::FuzzerView::RESULT_CAP} results, #{W}x#{H}:"
puts "  matched_count = #{FULL.matched_count} of #{FULL.result_count}"

Benchmark.ips do |x|
  # A live run appends a result between frames, so any cache keyed on the result revision is
  # invalidated exactly the way it is in the real loop.
  x.report("results pane, live (append + render)") do
    FULL.append_result(result(0, false))
    FULL.render(screen, rect)
  end
  x.report("detail open, live (append + render)") do
    DETAIL.append_result(result(0, false))
    DETAIL.render(screen, rect)
  end
  x.report("results pane, idle (render only)") { FULL.render(screen, rect) }
  x.report("detail, 3000-line selection    ") { BIG_SEL.render(screen, rect) }
end
