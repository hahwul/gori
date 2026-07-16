# ContentLength.sync micro-benchmark. sync() runs on EVERY dispatched fuzz request when
# update_content_length is on (the default). The current implementation allocates a head
# String (String.new(bytes[0, sep])), splits it into a per-line Array, scans each line with
# index/strip/downcase, and separately re-walks the head in chunked?  — so even a GET query
# fuzz (no body, no CL header) pays a String + Array allocation and two head passes only to
# return the bytes unchanged.
#
# Build: crystal build bench/fuzz_clsync_bench.cr -o bin/fuzz_clsync_bench --release
# Run:   bin/fuzz_clsync_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/fuzz/content_length"

include Gori::Fuzz

# 1) GET query fuzz — no body, no Content-Length header. The dominant fuzzing shape. sync
#    must return the bytes unchanged; the fast path should allocate nothing.
GET = ("GET /api/v1/search?q=hello+world&page=42&sort=relevance HTTP/1.1\r\n" +
       "Host: api.example.com\r\n" +
       "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
       "Accept: application/json\r\n" +
       "Cookie: session=abcdef0123456789; csrf=0123456789abcdef; theme=dark; lang=en\r\n" +
       "\r\n").to_slice

# 2) POST JSON fuzz — Content-Length present, body changes each request so the value must be
#    rewritten. The real rebuild path.
POST = ("POST /api/v1/search HTTP/1.1\r\n" +
        "Host: api.example.com\r\n" +
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
        "Accept: application/json\r\n" +
        "Cookie: session=abcdef0123456789; csrf=0123456789abcdef; theme=dark; lang=en\r\n" +
        "Content-Type: application/json\r\n" +
        "Content-Length: 12\r\n" +
        "\r\n" +
        %({"filter":"active-account-search-term","limit":50,"offset":0})).to_slice

puts "ContentLength.sync bench"
puts "  GET  input: #{GET.size} bytes (no CL, returns unchanged)"
puts "  POST input: #{POST.size} bytes (CL 12 -> real body length)"
puts

Benchmark.ips do |x|
  x.report("sync GET (no-op, common)") { ContentLength.sync(GET) }
  x.report("sync POST (rewrite CL)  ") { ContentLength.sync(POST) }
end
