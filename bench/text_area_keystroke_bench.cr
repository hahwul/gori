# What ONE keystroke costs in a TextArea, as a function of buffer size.
#
# `TextArea#highlighted` memoises on {kind, Theme.revision, Env.highlight_rev} with NO
# content version, and every mutation sets `@styled = nil` — so each typed character
# re-tokenises the WHOLE buffer. This is the Repeater / Fuzzer / Intercept / Rewriter / JWT
# editor path, i.e. the one an operator holds a key down in.
#
# Build: crystal build bench/text_area_keystroke_bench.cr -o bin/text_area_keystroke_bench --release
# Run:   bin/text_area_keystroke_bench
require "benchmark"
require "../src/gori"
require "../spec/support/memory_backend"

include Gori::Tui

def request_text(body_kb : Int32) : String
  body = ({"id" => 1, "tok" => "abcdefghijklmnop"}.to_s + "\n") * (body_kb * 1024 // 40)
  "POST /api/v1/submit HTTP/1.1\r\nHost: api.example.com\r\n" \
  "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
end

{1, 64, 512}.each do |kb|
  text = request_text(kb)
  lines = text.count('\n') + 1
  ta = TextArea.new(text)
  backend = MemoryBackend.new(120, 40)
  rect = Rect.new(0, 0, 120, 40)
  # Warm: style once so the memo is populated the way a settled editor is.
  ta.render(Screen.new(backend), rect, cursor: true, highlight: :request)

  t = Time.instant
  n = 20
  n.times do
    ta.insert('x') # invalidates @styled
    ta.render(Screen.new(backend), rect, cursor: true, highlight: :request)
  end
  per = (Time.instant - t).total_milliseconds / n
  puts "buffer #{kb.to_s.rjust(3)} KB (#{lines} lines): #{per.round(3)} ms per keystroke+frame"
end

# SCROLLING a WRAPPED pane over long lines. Under wrap one logical line becomes N visual
# rows, and the draw loop asks for the same line index once per row — so a windowed
# `line_at` without a memo re-tokenises the same line N times per frame, which the old
# eager array never did. This case exists to keep that from regressing again.
puts ""
long_body = (%({"k":"#{"v" * 4000}"}) + "\n") * 40
text = "POST /x HTTP/1.1\r\nContent-Type: application/json\r\n\r\n#{long_body}"
ta = TextArea.new(text)
ta.wrap = true
backend = MemoryBackend.new(100, 40)
rect = Rect.new(0, 0, 100, 40)
ta.render(Screen.new(backend), rect, cursor: false, highlight: :request)
t = Time.instant
n = 30
n.times do
  ta.move(1, 0) # scroll, NO buffer mutation: the styled memo must survive this
  ta.render(Screen.new(backend), rect, cursor: false, highlight: :request)
end
puts "wrapped scroll over 4 KB lines: #{((Time.instant - t).total_milliseconds / n).round(3)} ms per frame"
