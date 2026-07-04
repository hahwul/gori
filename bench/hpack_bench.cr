# HPACK decode micro-benchmark: the per-h2-HEADERS-frame cost. Every h2 request
# and response header block is HPACK-decoded (and most header strings are
# Huffman-coded on the wire), so this runs twice per h2 flow on the proxy hot
# path. Isolates huffman_decode (bit-by-bit tree walk) + the block decode.
#
# Build: crystal build bench/hpack_bench.cr -o bin/hpack_bench --release
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/h2/hpack"

include Gori::Proxy::H2

# A realistic request + response header set (what a browser sends / a server
# returns). Encode them ONCE with the stateless encoder (Huffman-coded), then
# decode repeatedly to measure the decode hot path.
REQ_HEADERS = [
  {":method", "GET"},
  {":scheme", "https"},
  {":authority", "api.example.com"},
  {":path", "/api/v1/users/12345/profile?include=avatar,bio&fmt=json"},
  {"user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
  {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"},
  {"accept-language", "en-US,en;q=0.9"},
  {"accept-encoding", "gzip, deflate, br"},
  {"cookie", "session=abc123def456ghi789; csrf=xyz789uvw012; theme=dark; lang=en; _ga=GA1.2.1234567890.1234567890"},
  {"referer", "https://www.example.com/dashboard/settings"},
]

RESP_HEADERS = [
  {":status", "200"},
  {"content-type", "application/json; charset=utf-8"},
  {"content-length", "4096"},
  {"cache-control", "no-cache, no-store, must-revalidate"},
  {"date", "Mon, 23 Jun 2026 12:00:00 GMT"},
  {"server", "nginx/1.25.0"},
  {"vary", "Accept-Encoding"},
  {"x-request-id", "7f3a9b2c-1d4e-4f5a-8b6c-9d0e1f2a3b4c"},
  {"set-cookie", "session=abc123def456ghi789; Path=/; HttpOnly; Secure; SameSite=Lax"},
  {"strict-transport-security", "max-age=31536000; includeSubDomains; preload"},
]

REQ_BLOCK  = HPACK::Encoder.new.encode(REQ_HEADERS)
RESP_BLOCK = HPACK::Encoder.new.encode(RESP_HEADERS)

# A pure Huffman-coded payload (the big cookie string) to isolate huffman_decode.
BIG_STRING   = REQ_HEADERS[8][1] * 4
HUFF_PAYLOAD = HPACK.huffman_encode(BIG_STRING)

puts "req block = #{REQ_BLOCK.size} bytes, resp block = #{RESP_BLOCK.size} bytes"
puts "huffman payload = #{HUFF_PAYLOAD.size} bytes (decodes to #{BIG_STRING.bytesize})\n\n"

# Sanity: round-trip correctness.
raise "req decode mismatch" unless HPACK::Decoder.new.decode(REQ_BLOCK) == REQ_HEADERS
raise "resp decode mismatch" unless HPACK::Decoder.new.decode(RESP_BLOCK) == RESP_HEADERS
raise "huff mismatch" unless HPACK.huffman_decode(HUFF_PAYLOAD) == BIG_STRING

Benchmark.ips do |x|
  x.report("decode REQ block (fresh decoder)") do
    HPACK::Decoder.new.decode(REQ_BLOCK)
  end
  x.report("decode RESP block (fresh decoder)") do
    HPACK::Decoder.new.decode(RESP_BLOCK)
  end
  x.report("huffman_decode (big cookie x4)") do
    HPACK.huffman_decode(HUFF_PAYLOAD)
  end
end
