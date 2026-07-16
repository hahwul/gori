# Measures the buffered-backend win AND proves it is byte-identical to the eager path.
#
# Two backends drive the SAME gori draws into a real Termisu::Buffer:
#   - EagerBufBackend: forwards every put straight to buffer.set_cell (the OLD behaviour)
#   - GridBufBackend:  accumulates into a grid and forwards only changed cells on flush
#                      (the NEW behaviour, mirroring src/gori/tui/screen.cr TermisuBackend)
# After each frame we assert the two buffers' cells are identical (correctness), then
# Benchmark.ips both (performance).
#
# Build: crystal build bench/buffered_frame_bench.cr -o bin/buffered_frame_bench --release
require "benchmark"
require "../src/gori/tui"

include Gori::Tui

class NullRenderer < Termisu::Renderer
  def write(data : String, columns_advanced = 0); end

  def flush; end

  def size : {Int32, Int32}
    {200, 50}
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

# OLD path: eager per-cell forward.
class EagerBufBackend < Backend
  getter buffer : Termisu::Buffer

  def initialize(@w : Int32, @h : Int32)
    @buffer = Termisu::Buffer.new(@w, @h)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
    g = grapheme.is_a?(String) ? grapheme : grapheme.to_s
    @buffer.set_cell(x, y, g, fg: fg, bg: bg, attr: attr)
  end

  def size : {Int32, Int32}
    {@w, @h}
  end

  def present(renderer, sync)
    sync ? @buffer.sync_to(renderer) : @buffer.render_to(renderer)
  end
end

# NEW path: grid + diff, a faithful copy of the production TermisuBackend but over a
# Termisu::Buffer (no TTY) so it can be benched and asserted.
class GridBufBackend < Backend
  getter buffer : Termisu::Buffer

  private struct GC
    getter grapheme : String
    getter fg : Color
    getter bg : Color
    getter attr : Attribute
    getter? cont : Bool

    def initialize(@grapheme, @fg, @bg, @attr, @cont = false); end

    def self.blank
      new(" ", Color.white, Color.default, Attribute::None)
    end

    def ==(o : GC)
      cont? == o.cont? && grapheme == o.grapheme && fg == o.fg && bg == o.bg && attr == o.attr
    end
  end

  def initialize(@w : Int32, @h : Int32)
    @buffer = Termisu::Buffer.new(@w, @h)
    @back = Array(GC).new(@w * @h) { GC.blank }
    @front = Array(GC).new(@w * @h) { GC.blank }
    @full = true
  end

  # Mirrors src/gori/tui/screen.cr TermisuBackend#put (keep in sync).
  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
    return unless x >= 0 && y >= 0 && x < @w && y < @h
    g = grapheme.is_a?(String) ? grapheme : grapheme.to_s
    width = 1
    if g.bytesize > 1
      cp = g[0].ord
      return if cp >= 0x7f && cp <= 0x9f
      width = Termisu::UnicodeWidth.grapheme_width(g)
      return if width == 0 || (width == 2 && x + 1 >= @w)
    end
    # (put body mirrors screen.cr TermisuBackend#put; kept inline here, not extracted)
    idx = y * @w + x
    @back[idx - 1] = GC.blank if x > 0 && @back[idx].cont?
    @back[idx] = GC.new(g, fg, bg, attr)
    return if x + 1 >= @w
    ni = idx + 1
    if width == 2
      @back[ni] = GC.new("", fg, bg, attr, cont: true)
    elsif @back[ni].cont?
      @back[ni] = GC.blank
    end
  end

  def size : {Int32, Int32}
    {@w, @h}
  end

  def present(renderer, sync)
    full = @full || sync
    i = 0
    n = @back.size
    while i < n
      b = @back[i]
      if full || b != @front[i]
        accepted = b.cont? || @buffer.set_cell(i % @w, i // @w, b.grapheme, fg: b.fg, bg: b.bg, attr: b.attr)
        @front[i] = b if accepted
      end
      i += 1
    end
    @full = false
    sync ? @buffer.sync_to(renderer) : @buffer.render_to(renderer)
  end
end

W = 200
H =  50

HEAD = ("HTTP/1.1 200 OK\r\n" +
        "Content-Type: application/json; charset=utf-8\r\n" +
        "Server: nginx/1.25.0\r\n\r\n").to_slice
BODY = begin
  io = IO::Memory.new
  200.times do |i|
    io << %(  {"id": #{1000 + i}, "name": "Alice Éxample #{i} 안녕 中文", "email": "a#{i}@example.com", "active": true},\n)
  end
  io.to_slice
end
WINDOWED = Highlight.message_windowed(HEAD, BODY, false)

def paint(screen, scroll)
  screen.fill(Rect.new(0, 0, W, H), Theme.bg)
  (0...H).each do |i|
    li = scroll + i
    break if li >= WINDOWED.total
    Highlight.draw(screen, 0, i, WINDOWED.line_at(li))
  end
end

# --- correctness: the two buffers must hold identical cells after each frame ---
def cells_equal?(a : Termisu::Buffer, b : Termisu::Buffer) : {Bool, String}
  (0...H).each do |y|
    (0...W).each do |x|
      ca = a.get_cell(x, y)
      cb = b.get_cell(x, y)
      if ca != cb
        return {false, "mismatch at (#{x},#{y}): eager=#{ca.inspect} grid=#{cb.inspect}"}
      end
    end
  end
  {true, ""}
end

eager = EagerBufBackend.new(W, H)
grid = GridBufBackend.new(W, H)
es = Screen.new(eager)
gs = Screen.new(grid)
rnd = NullRenderer.new

# Exercise several frames incl. scroll (width transitions across CJK) + a static repaint.
[0, 1, 2, 0, 7, 0].each_with_index do |scroll, frame|
  paint(es, scroll); eager.present(rnd, false)
  paint(gs, scroll); grid.present(rnd, false)
  ok, msg = cells_equal?(eager.buffer, grid.buffer)
  unless ok
    STDERR.puts "CORRECTNESS FAIL (frame #{frame}, scroll #{scroll}): #{msg}"
    exit 1
  end
end
puts "correctness: OK (eager and grid buffers identical across 6 frames incl. CJK + scroll)"

# --- performance ---
puts "\nStatic frame (no content change) — old vs new:"
Benchmark.ips do |x|
  x.report("eager (old): fill+draw+diff") do
    paint(es, 0); eager.present(rnd, false)
  end
  x.report("grid  (new): fill+draw+diff") do
    paint(gs, 0); grid.present(rnd, false)
  end
end

puts "\nScroll frame (content shifts 1 line) — old vs new:"
et = 0
gt = 0
Benchmark.ips do |x|
  x.report("eager (old): scroll") do
    et = et == 0 ? 1 : 0
    paint(es, et); eager.present(rnd, false)
  end
  x.report("grid  (new): scroll") do
    gt = gt == 0 ? 1 : 0
    paint(gs, gt); grid.present(rnd, false)
  end
end
