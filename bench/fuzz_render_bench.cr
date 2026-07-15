# Template#render micro-benchmark. render() splices payloads into the marked template on
# EVERY emitted fuzz request (Generator#emit). The output IO::Memory started at the default
# 64B and regrew 64→128→…→N for a KB-scale request each emit; pre-sizing to the exact output
# length removes that realloc chain. For GET query fuzz the render output IS the wire bytes.
#
# Build: crystal build bench/fuzz_render_bench.cr -o bin/fuzz_render_bench --release
# Run:   bin/fuzz_render_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/fuzz/template"

include Gori::Fuzz

# A realistic marked request: long query line + Cookie header + small JSON body, 4 positions.
RAW = ("POST /api/v1/search?q=§term§&page=§page§ HTTP/1.1\r\n" +
       "Host: api.example.com\r\n" +
       "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
       "Accept: application/json\r\n" +
       "Cookie: session=§sid§; csrf=abcdef0123456789; theme=dark; lang=en\r\n" +
       "Content-Type: application/json\r\n" +
       "\r\n" +
       %({"filter":"§filter§","limit":50,"offset":0,"sort":"relevance"}))

TEMPLATE = Template.parse(RAW, http2: false)
PAYLOADS = ["hello world query string", "42", "deadbeefcafebabe0123456789abcdef", "active"]

# Sanity: show the produced size.
OUT = TEMPLATE.render(PAYLOADS)
puts "template render: #{TEMPLATE.position_count} positions, output = #{OUT.size} bytes"
Benchmark.ips do |x|
  x.report("Template#render") { TEMPLATE.render(PAYLOADS) }
end
