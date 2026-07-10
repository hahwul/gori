# Body-tokenizer micro-benchmark. body_styled runs per visible body line per render (up to
# ~40 lines × 20fps during capture/scroll). The old path allocated a whole-line Array(Char)
# + a per-span sub-array + join; the byte-scan slices the source directly.
#
# Build: crystal build bench/highlight_bench.cr -o bin/highlight_bench --release
# Run:   bin/highlight_bench
require "benchmark"
require "../src/gori/tui"

include Gori::Tui

JSON_LINE = %(  {"id": 12345, "name": "Alice Example", "email": "a@example.com", "active": true, "score": -12.5e3, "tags": ["alpha", "beta", "gamma"], "note": "ordinary value"},)
HTML_LINE = %(<div class="card" id="main"><span class="label">Hello</span><a href="http://x/y">link</a><br/><b>bold</b> and some plain text here</div>)
FORM_LINE = "username=alice&password=hunter2&csrf=abcdef0123456789&remember=true&redirect=%2Fdashboard&locale=en-US&theme=dark"

# A ~40-line viewport of each, styled per render.
def frame(line : String, kind : Symbol) : Int32
  total = 0
  40.times { total += Highlight.body_styled(line, kind).size }
  total
end

puts "body_styled over a 40-line viewport (per render):"
Benchmark.ips do |x|
  x.report("json (#{JSON_LINE.bytesize}B/line)") { frame(JSON_LINE, :json) }
  x.report("html (#{HTML_LINE.bytesize}B/line)") { frame(HTML_LINE, :html) }
  x.report("form (#{FORM_LINE.bytesize}B/line)") { frame(FORM_LINE, :form) }
end
