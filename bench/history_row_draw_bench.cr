# History LIST paint benchmark — the row loop in `HistoryView#render_list`, the busiest
# list in gori. `history_filter_bench` measures the QUERY; this measures what happens
# per frame AFTER the rows are in memory: per row a timestamp formatted, a Content-Type
# folded to its short label, a method colour, an absolute-form target sliced — all from
# fields that do not change between frames, now memoized on those fields. Three list
# heights, so the per-row cost is visible next to the fixed cost of the frame.
#
# Build: crystal build bench/history_row_draw_bench.cr -o bin/history_row_draw_bench --release
# Run:   bin/history_row_draw_bench
require "benchmark"
require "file_utils"
require "../src/gori"

include Gori::Tui

# Records nothing: the subject is the row loop, not cell storage.
class SinkBackend < Backend
  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

ROWS  = 400
TYPES = ["application/json; charset=utf-8", "text/html; charset=utf-8", "image/png",
         "application/javascript", "text/plain", "application/x-www-form-urlencoded",
         "application/vnd.api+json", "image/svg+xml"]

path = File.tempname("gori-row-draw", ".db")
store = Gori::Store.open(path)
begin
  ROWS.times do |i|
    method = i % 4 == 0 ? "POST" : "GET"
    target = i % 3 == 0 ? "http://acme.test/api/v1/items/#{i}?page=#{i % 7}" : "/api/v1/items/#{i}?page=#{i % 7}"
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_700_000_000_000_000_i64 + i * 1_000_000, scheme: "https", host: "acme.test", port: 443,
      method: method, target: target, http_version: "HTTP/1.1",
      head: "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
      source: Gori::FlowSource::Kind::Proxy))
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
      body: "{}".to_slice, content_type: TYPES[i % TYPES.size]))
  end
  view = HistoryView.new
  view.reload(store)
  Gori::Settings.history_time_format = "absolute"

  {20, 50, 100}.each do |h|
    w = 200
    screen = Screen.new(SinkBackend.new(w, h + 4))
    rect = Rect.new(0, 0, w, h + 4)
    puts
    puts "render_list over #{ROWS} rows, #{w}x#{h + 4} pane (~#{h} drawn rows):"
    Benchmark.ips do |x|
      x.report("render_list, absolute time") { view.render_list(screen, rect, true) }
    end
  end
ensure
  store.close
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end
