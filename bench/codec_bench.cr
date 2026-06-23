# Codec micro-benchmarks: the per-request HTTP/1.1 head parsing costs that run
# twice per flow (request head + response head) on the proxy hot path. These are
# hidden under the upstream connect cost today; once upstream reuse removes that,
# they become the visible per-request overhead.
#
# Build: crystal build bench/codec_bench.cr -o bin/codec_bench --release
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/codec/http1"
require "../src/gori/proxy/codec/body"

include Gori::Proxy::Codec

REQ_HEAD = ("GET /api/v1/users/12345/profile?include=avatar,bio&fmt=json HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
            "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n" +
            "Accept-Language: en-US,en;q=0.9\r\n" +
            "Accept-Encoding: gzip, deflate, br\r\n" +
            "Cookie: session=abc123def456; csrf=xyz789; theme=dark; lang=en\r\n" +
            "Referer: https://www.example.com/dashboard\r\n" +
            "Connection: keep-alive\r\n\r\n").to_slice

RESP_HEAD = ("HTTP/1.1 200 OK\r\n" +
             "Content-Type: application/json; charset=utf-8\r\n" +
             "Content-Length: 4096\r\n" +
             "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
             "Date: Mon, 23 Jun 2026 12:00:00 GMT\r\n" +
             "Server: nginx/1.25.0\r\n" +
             "Vary: Accept-Encoding\r\n" +
             "X-Request-Id: 7f3a9b2c-1d4e-4f5a-8b6c-9d0e1f2a3b4c\r\n" +
             "Connection: keep-alive\r\n\r\n").to_slice

puts "request head = #{REQ_HEAD.size} bytes, response head = #{RESP_HEAD.size} bytes\n\n"

# Simulate the per-request work in client_conn's hot path.
def simulate_request_parse
  req = Http1.parse_request_head(REQ_HEAD)
  # the lookups client_conn does on every request:
  req.host?
  Body.request_framing(req)
  req.method.upcase
end

def simulate_response_parse
  resp = Http1.parse_response_head(RESP_HEAD)
  Body.response_framing(resp, "GET")
  # keep_alive? lookups
  resp.headers.get?("Connection")
  resp.headers.get?("Upgrade")
  resp.headers.get?("Content-Type")
end

Benchmark.ips do |x|
  x.report("read_head (req, from IO::Memory)") do
    Http1.read_head(IO::Memory.new(REQ_HEAD))
  end
  x.report("parse_request_head") do
    Http1.parse_request_head(REQ_HEAD)
  end
  x.report("parse_response_head") do
    Http1.parse_response_head(RESP_HEAD)
  end
  x.report("HeaderList#get? x5 (resp)") do
    resp = Http1.parse_response_head(RESP_HEAD)
    resp.headers.get?("Connection")
    resp.headers.get?("Upgrade")
    resp.headers.get?("Content-Type")
    resp.headers.get?("Transfer-Encoding")
    resp.headers.get?("Content-Length")
  end
  x.report("FULL req parse+lookups") { simulate_request_parse }
  x.report("FULL resp parse+lookups") { simulate_response_parse }
end
