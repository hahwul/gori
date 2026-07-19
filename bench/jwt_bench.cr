# Jwt.from_flow micro-benchmark: scan_body runs on every flow's request+response body
# (up to 2MiB) even with no token. The `eyJ` raw-byte pre-gate skips the whole-body
# String.new+scrub+regex when no JWT is present (the common case).
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/decoder/converter"
require "../src/gori/jwt"

# A 200KB JSON response body with NO JWT (the dominant shape).
NO_TOKEN = begin
  io = IO::Memory.new
  400.times { |i| io << %({"id":) << i << %(,"name":"user) << i << %(","email":"u) << i << %(@example.com"}\n) }
  io.to_slice.dup
end

HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice

puts "Jwt.from_flow over a #{NO_TOKEN.size}-byte body with NO token:"
Benchmark.ips do |x|
  x.report("from_flow (resp body, no jwt)") do
    Gori::Jwt.from_flow("/api", HEAD, nil, HEAD, NO_TOKEN).size
  end
end
