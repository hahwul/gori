require "../src/gori/tui"

include Gori::Tui

def time_ms(reps : Int32, & : ->) : Float64
  2.times { yield }
  samples = Array(Float64).new(reps)
  reps.times do
    t0 = Time.instant
    yield
    samples << (Time.instant - t0).total_milliseconds
  end
  samples.sort!
  samples[samples.size // 2]
end

line = "x" * 14 + "\n"
n_lines = 100_000
io = IO::Memory.new(line.bytesize * n_lines)
n_lines.times { io << line }
body = io.to_slice
head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice

puts "fixture: body=#{body.size} bytes (~#{n_lines} lines of 15B)"

eager_open = time_ms(7) do
  String.new(body).scrub.split('\n').map(&.rstrip('\r'))
end

lazy_open = time_ms(7) do
  Highlight.message_windowed(head, body, request: false)
end

win = Highlight.message_windowed(head, body, request: false)
visible_style = time_ms(11) do
  40.times { |i| win.line_at(win.head.size + 10_000 + i) }
end

eager_full_style = time_ms(3) do
  lines = String.new(body).scrub.split('\n').map(&.rstrip('\r'))
  lines.each { |raw| Highlight.body_styled(raw, :text) }
end

puts "median open eager split (old):     #{eager_open.round(2)} ms  (allocates ~#{win.body.size} strings)"
puts "median open message_windowed(new): #{lazy_open.round(2)} ms  (LF index only + head style)"
puts "median style 40 visible lines:     #{visible_style.round(2)} ms"
puts "median style ALL body lines:       #{eager_full_style.round(2)} ms  (what old full message() did)"
ratio = eager_open / {lazy_open, 0.001}.max
puts "open speedup (eager/lazy):         #{ratio.round(1)}x"
puts "win.body.size=#{win.body.size} head.size=#{win.head.size} total=#{win.total}"
puts "OK"
