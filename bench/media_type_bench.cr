# `MediaType.of` micro-benchmark — the per-flow Content-Type read `Store#insert_one` does on
# the writer fiber for every captured request (and every Pretty / GraphQL / FormData / Params
# / SSE render after it).
#
# `legacy` is the `String` scan `of` still falls back to for a head with a byte >= 0x80: copy
# the head, scrub it, build one `String` per line. The byte-scan path answers the same for a
# pure-ASCII head (spec/media_type_spec.cr, differentially) and allocates only the value.
#
# Build: crystal build bench/media_type_bench.cr -o bin/media_type_bench --release
# Run:   bin/media_type_bench
require "benchmark"
require "../src/gori/media_type"

def legacy_of(h : Bytes) : String?
  String.new(h).scrub.each_line do |raw|
    line = raw.chomp
    break if line.empty?
    idx = line.index(':') || next
    next unless line[0, idx].strip.compare("content-type", case_insensitive: true) == 0
    return line[(idx + 1)..].strip
  end
  nil
end

# A browser-shaped 14-header POST with the Content-Type near the END — the realistic worst
# case for a scan that stops at the first match.
POST = ("POST /api/v1/users/12345/profile?include=avatar HTTP/1.1\r\n" \
        "Host: api.example.com\r\n" \
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n" \
        "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n" \
        "Accept-Language: en-US,en;q=0.9\r\nAccept-Encoding: gzip, deflate, br\r\n" \
        "Cookie: session=abc123def456ghi789; csrf=xyz789uvw012; theme=dark; lang=en; _ga=GA1.2.1234567890.1234567890\r\n" \
        "Referer: https://www.example.com/dashboard/settings\r\nOrigin: https://www.example.com\r\n" \
        "Sec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\nContent-Length: 42\r\n" \
        "Content-Type: application/json; charset=utf-8\r\nConnection: keep-alive\r\n\r\n").to_slice
# The common GET: no Content-Type, so the whole head is walked.
GET = String.new(POST).sub("Content-Type: application/json; charset=utf-8\r\n", "").to_slice
# One obs-text byte in a header value: the fallback, which should cost what legacy costs.
UTF8 = String.new(POST).sub("theme=dark", "theme=därk").to_slice

[POST, GET, UTF8].each do |h|
  raise "diverged on #{String.new(h).inspect}" unless Gori::MediaType.of(h) == legacy_of(h)
end

Benchmark.ips do |x|
  x.report("legacy  POST (content-type last)") { legacy_of(POST) }
  x.report("of      POST (content-type last)") { Gori::MediaType.of(POST) }
  x.report("legacy  GET  (no content-type)") { legacy_of(GET) }
  x.report("of      GET  (no content-type)") { Gori::MediaType.of(GET) }
  x.report("of      POST non-ASCII (fallback)") { Gori::MediaType.of(UTF8) }
end
