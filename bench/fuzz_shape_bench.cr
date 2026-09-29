# Cost of the response-shape fingerprint (#1351) on the per-response hot path.
#
# `Matcher#build` runs once per response, and `Shape.compute` now runs inside it over the body
# that call already decoded. This measures it against the build it rides in, on a 216 KB HTML
# body, a 1.2 MB one past the scan window, and a small JSON answer,
# with and without a reflected payload to mask. The number that matters is the allocation
# column: the fingerprint must not add a per-response buffer (P6).
#
# Measured (M-series, --release): `Shape.compute` is 0 B/op; `Shape.needles` 176 B/op, only for
# the needle Array (the HTML/percent variants are built only for a payload that has them). Time:
# ~0.35 µs on the small answer, ~105 µs on anything past the scan window — ~1.3 ns/byte of
# token-dense HTML, flat from 184 KB to 1.2 MB because only `SCAN_HEAD + SCAN_TAIL` is read.
#
# Build: crystal build bench/fuzz_shape_bench.cr -o bin/fuzz_shape_bench --release
# Run:   bin/fuzz_shape_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/utf8"
require "../src/gori/fuzz/types"
require "../src/gori/fuzz/matcher"

include Gori::Fuzz

HEAD = "HTTP/1.1 200 OK\r\nDate: Mon, 01 Jan 2024 00:00:00 GMT\r\nContent-Type: text/html\r\n" \
       "Set-Cookie: s=1\r\nX-Request-Id: 8f3a\r\n\r\n".to_slice

BIG = begin
  io = IO::Memory.new
  3000.times { |i| io << "<tr><td class=\"c#{i}\">row #{i} query needle-payload</td></tr>\n" }
  io.to_slice
end

HUGE = begin
  io = IO::Memory.new
  20000.times { |i| io << "<tr><td class=\"c#{i}\">row #{i} query needle-payload</td></tr>\n" }
  io.to_slice
end

SMALL = %({"ok":false,"error":"invalid credentials","ts":1727600000,"id":"550e8400-e29b"}).to_slice

REQUEST = "GET /?q=needle-payload HTTP/1.1\r\nHost: t\r\n\r\n".to_slice
JOB     = Job.new(0_i64, ["needle-payload"], 0, REQUEST, [{8, 14}])
NEEDLES = Shape.needles(JOB)

puts "body sizes: huge=#{HUGE.size} big=#{BIG.size} small=#{SMALL.size}"
{"huge" => HUGE, "big" => BIG, "small" => SMALL}.each do |name, body|
  Benchmark.ips do |x|
    x.report("#{name}: Shape.compute (masking)") do
      Shape.compute(200, nil, nil, false, false, HEAD, body, NEEDLES)
    end
    x.report("#{name}: Shape.compute (no needles)") do
      Shape.compute(200, nil, nil, false, false, HEAD, body)
    end
    x.report("#{name}: Shape.needles") { Shape.needles(JOB) }
  end
end

response = Gori::Proxy::Codec::Http1.parse_response_head(HEAD)
m = Matcher.new(keep_bodies: :none)
{"huge" => HUGE, "big" => BIG, "small" => SMALL}.each do |name, body|
  raw = Gori::Repeater::Result.new(HEAD, body, response, 1000_i64, nil)
  Benchmark.ips do |x|
    # The decode + word/line pass every response already paid before the shape existed.
    x.report("#{name}: Matcher#metrics (baseline)") { m.metrics(raw) }
    x.report("#{name}: Matcher#build (with shape)") { m.build(JOB, raw) }
  end
end
