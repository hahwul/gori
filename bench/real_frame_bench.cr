# REAL per-frame cost through the actual Termisu::Buffer (double-buffered, diffed),
# NOT the SinkBackend the other benches use. This exposes the per-cell termisu cost
# (grapheme_size guard + Cell.new grapheme extraction + grapheme_width) that the
# SinkBackend hides — the true dominant cost of a gori frame.
#
# Build: crystal build bench/real_frame_bench.cr -o bin/real_frame_bench --release
require "benchmark"
require "../src/gori/tui"

include Gori::Tui

# A Renderer that discards all output — we measure buffer set_cell + diff cost,
# not terminal I/O.
class NullRenderer < Termisu::Renderer
  def write(data : String, columns_advanced = 0); end

  def flush; end

  def size : {Int32, Int32}
    {W, H}
  end

  def close; end

  def move_cursor(x : Int32, y : Int32); end

  def show_cursor; end

  def hide_cursor; end

  def foreground=(color : Termisu::Color); end

  def background=(color : Termisu::Color); end

  def reset_attributes; end

  def enable_bold; end

  def enable_underline; end

  def enable_reverse; end

  def enable_blink; end

  def enable_dim; end

  def enable_cursive; end

  def enable_hidden; end

  def enable_strikethrough; end
end

# Backend that writes into a real Termisu::Buffer (the production path).
class BufferBackend < Backend
  getter buffer : Termisu::Buffer

  def initialize(@w : Int32, @h : Int32)
    @buffer = Termisu::Buffer.new(@w, @h)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
    g = grapheme.is_a?(Char) ? grapheme.to_s : grapheme
    @buffer.set_cell(x, y, g, fg: fg, bg: bg, attr: attr)
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

W = 200
H =  50
backend = BufferBackend.new(W, H)
buffer = backend.buffer
renderer = NullRenderer.new
screen = Screen.new(backend)

# A realistic styled HTTP response viewport (ASCII head + JSON body), as the detail
# view holds it.
HEAD = ("HTTP/1.1 200 OK\r\n" +
        "Content-Type: application/json; charset=utf-8\r\n" +
        "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
        "Server: nginx/1.25.0\r\n" +
        "Date: Mon, 15 Jul 2026 12:00:00 GMT\r\n" +
        "X-Request-Id: 7f3a9c2e-1b4d-4e8a-9c1f-2d6b8e0a1c3d\r\n\r\n").to_slice
BODY = begin
  io = IO::Memory.new
  200.times do |i|
    io << %(  {"id": #{1000 + i}, "name": "Alice Example #{i}", "email": "a#{i}@example.com", ) \
      << %("active": true, "score": -12.5e3, "tags": ["alpha", "beta"], "note": "ordinary value"},\n)
  end
  io.to_slice
end
WINDOWED = Highlight.message_windowed(HEAD, BODY, false)

def paint_frame(screen, scroll)
  screen.fill(Rect.new(0, 0, W, H), Theme.bg)
  (0...H).each do |i|
    li = scroll + i
    break if li >= WINDOWED.total
    Highlight.draw(screen, 0, i, WINDOWED.line_at(li))
  end
end

# Warm the front buffer to the first frame.
paint_frame(screen, 0)
buffer.render_to(renderer)

puts "REAL frame through Termisu::Buffer (#{W}x#{H}), fill + styled viewport:"
Benchmark.ips do |x|
  # Static frame: fill + draw same content, then diff (0 rows change → measures pure
  # set_cell rebuild cost, since termisu diff emits nothing).
  x.report("static frame (fill+draw+diff, no change)") do
    paint_frame(screen, 0)
    buffer.render_to(renderer)
  end
end

# Scroll: alternate between two adjacent scroll offsets so every frame the whole
# viewport shifts by one line — the real scrolling hot path.
puts "\nScroll frame (content shifts 1 line each frame):"
toggle = 0
Benchmark.ips do |x|
  x.report("scroll frame (fill+draw+diff)") do
    toggle = toggle == 0 ? 1 : 0
    paint_frame(screen, toggle)
    buffer.render_to(renderer)
  end
end

# Isolate raw set_cell cost: 10000 space fills into the back buffer.
puts "\nRaw set_cell cost (10000 ASCII space cells):"
Benchmark.ips do |x|
  x.report("10000x buffer.set_cell(\" \")") do
    y = 0
    while y < H
      xx = 0
      while xx < W
        buffer.set_cell(xx, y, " ", fg: Termisu::Color.white, bg: Termisu::Color.default)
        xx += 1
      end
      y += 1
    end
  end
end
