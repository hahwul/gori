# Wrap.mark_search growth harness. `mark_search` overdraws the ^F band on ONE drawn row,
# but scans the WHOLE logical line (a match straddling a soft-wrap break must light up on
# both rows, see the comment above it), and every pane with a live query calls it once per
# drawn row. So its per-call cost is multiplied by the viewport height on exactly the line
# that is worst for it: a long, token-dense minified body.
#
# What this measures is the SHAPE of that cost, not its absolute value: µs per match must
# stay flat as the match count doubles. It quadrupled per doubling until the rewrite in
# `Wrap.mark_search` — the loop handed `String#index` a CHARACTER offset, which it converts
# by walking that many characters from byte 0 on every call; `row_col` re-measured from the
# row start for every match; and a char-index slice of a non-ASCII line walked from byte 0
# a third time, which is why CJK cost ~150x what ASCII did at the same match count. The
# scan is byte-linear now and three forward-only cursors carry the character index, the
# byte offset and the column, so the last section below (a no-match scan, which builds no
# cursor at all) is the floor every other section sits on.
#
# Build: crystal build bench/mark_search_bench.cr -o bin/mark_search_bench --release
# Run:   bin/mark_search_bench
require "../src/gori"

include Gori::Tui

# Records nothing: the subject is the scan, not cell storage.
class SinkBackend < Backend
  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

W = 120
backend = SinkBackend.new(W, 1)
screen = Screen.new(backend)

REPS = 5

def timed(reps : Int32, &) : Float64
  yield # warm
  t0 = Time.instant
  reps.times { yield }
  (Time.instant - t0).total_milliseconds / reps
end

def report(title : String, counts : Array(Int32), &block : Int32 -> Float64)
  puts
  puts title
  puts "  matches       ms     µs/match     growth"
  prev = nil
  counts.each do |n|
    ms = block.call(n)
    growth = prev ? (ms / prev) : 0.0
    printf("  %-9d %8.3f  %9.4f  %s\n", n, ms, ms * 1000 / n,
      prev ? sprintf("%.2fx", growth) : "—")
    prev = ms
  end
end

COUNTS = [1_000, 2_000, 4_000, 8_000, 16_000]

# The reported case: an ASCII token-dense line, every 2 columns a fresh match. Painting is
# clipped to the viewport, so nearly all the work is the match walk itself.
report("dense ASCII matches, one drawn row (clipped to #{W} cols)", COUNTS) do |n|
  text = "ab" * n
  timed(REPS) { Wrap.mark_search(screen, 0, 0, text, 0, text.size, "ab", W) }
end

# The same line under soft wrap, marked for a row in the MIDDLE of it. Every match before
# the row is still scanned (it must be, to find the ones that touch it); what must not
# happen is a fresh walk from the row start per match.
report("dense ASCII, one wrapped row at the line's midpoint", COUNTS) do |n|
  text = "ab" * n
  a = (text.size // 2) // W * W
  timed(REPS) { Wrap.mark_search(screen, 0, 0, text, a, a + W, "ab", W) }
end

# Non-ASCII: no `ascii_only?` fast path anywhere, so the column accumulator and the slices
# are the whole cost. CJK is width-2 per cluster, which also exercises grapheme_cols.
report("dense CJK matches, one drawn row", COUNTS) do |n|
  text = "世界" * n
  timed(REPS) { Wrap.mark_search(screen, 0, 0, text, 0, text.size, "世", W) }
end

# A long line with NO match: one full scan, the floor every case above builds on.
puts
puts "no-match scan (one byte_index pass, no cursor built — should be flat per 100k)"
[100_000, 200_000, 400_000, 800_000].each do |n|
  text = "a" * n
  ms = timed(REPS) { Wrap.mark_search(screen, 0, 0, text, 0, text.size, "zzz", W) }
  printf("  %-9d %8.3f ms  %8.4f ms/100k\n", n, ms, ms / (n / 100_000.0))
end

# A VIEWPORT of wrapped rows over one long line, the shape every read pane draws when a
# minified body is on screen with a live ^F — and the TUI shares its scheduler with the
# proxy, so a slow frame here is a capture stall (P6). The whole-line work (downcase, match
# walk, ASCII verdicts, char↔byte bookkeeping, the grapheme walk up to the row) used to be
# redone per DRAWN row: 60-150 ms a frame on a 1.6 MB ASCII line, ~1.5 s once a single
# non-ASCII char sent the column cursor down its grapheme walk from the head. A pane's
# `Wrap::SearchMemo` keeps it across rows and frames; a row is then a binary search.
ROWS_PER_FRAME =  40
FW             = 150
fscreen = Screen.new(SinkBackend.new(FW, ROWS_PER_FRAME))

body = String.build do |io|
  12_000.times do |i|
    io << %({"id":#{i},"name":"user#{i}","email":"u#{i}@example.com","tags":["a","b","0.123"],)
    io << %("nested":{"x":#{i * 2},"y":[1,2,3],"z":null,"ok":true}},)
  end
end

def frame(screen : Screen, line : String, start : Int32, q : String, memo : Wrap::SearchMemo?) : Nil
  ROWS_PER_FRAME.times do |r|
    a = start + r * FW
    Wrap.mark_search(screen, 0, r, line, a, a + FW, q, FW, memo: memo)
  end
end

puts
puts "one wrapped #{body.bytesize // 1024} KB line, #{ROWS_PER_FRAME} rows of #{FW} per frame (ms/frame)"
puts "  line          query  rows at      per-row scan   memo, cold   memo, warm"
{"ASCII" => body, "one é" => body.sub("user5", "usér5")}.each do |label, line|
  {"user", "zzz"}.each do |q|
    {0, line.size // 2, line.size - ROWS_PER_FRAME * FW}.each do |start|
      # No memo builds the whole-line scan per call — the order of work every row did
      # before the memo, which is the cost it takes off the frame.
      slow = timed(1) { frame(fscreen, line, start, q, nil) }
      memo = Wrap::SearchMemo.new
      t0 = Time.instant
      frame(fscreen, line, start, q, memo)
      cold = (Time.instant - t0).total_milliseconds
      warm = timed(REPS) { frame(fscreen, line, start, q, memo) }
      printf("  %-12s  %-5s  %-12d %10.2f   %10.2f   %10.4f\n", label, q, start, slow, cold, warm)
    end
  end
end
