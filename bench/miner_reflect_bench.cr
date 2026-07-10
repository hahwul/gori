# Miner reflection micro-benchmark: the K-canary reflection test per bucket probe.
# Old path ran K full-body `includes?` scans + two String.new(body/head).scrub allocations
# per probe; the new path scans body+head ONCE into a Set. This drives Baseline.decide over
# a realistic bucket (128 canaries) against a 100 KB response with a few reflected.
#
# Build: crystal build bench/miner_reflect_bench.cr -o bin/miner_reflect_bench --release
# Run:   bin/miner_reflect_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/miner/types"
require "../src/gori/miner/fingerprint"

include Gori::Miner

# A 100 KB response body that echoes 3 of the bucket's canaries somewhere inside it.
def body_with(canaries : Array(String)) : Bytes
  io = IO::Memory.new
  200.times do |i|
    io << %({"row":) << i << %(,"label":"ordinary value number ) << i << %(","tags":["a","b","c"]}\n)
  end
  # sprinkle 3 reflected canaries
  io << "reflected1=" << canaries[3] << " reflected2=" << canaries[40] << " x" << canaries[120] << "y\n"
  400.times { |i| io << %(filler line with lorem ipsum dolor sit amet consectetur ) << i << "\n" }
  io.to_slice.dup
end

HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nServer: nginx\r\n\r\n".to_slice

# Build a bucket of 128 canaries + the reflected body once.
CANARIES = Array.new(128) { Canary.fresh }
BODY = body_with(CANARIES)
INV = begin
  h = Hash(String, String).new
  CANARIES.each_with_index { |c, i| h[c] = "param#{i}" }
  h
end

# A minimal Replay::Result stand-in via Fingerprint.probe's input shape.
def make_result : Gori::Replay::Result
  Gori::Replay::Result.new(HEAD, BODY, nil, 1000_i64)
end

puts "Miner reflection over a 128-canary bucket, 100KB body (3 reflected):"
res = make_result
Benchmark.ips do |x|
  x.report("probe + decide (scan-once)") do
    probe = Fingerprint.probe(res)
    n = 0
    INV.each { |c, _| n += 1 if probe.reflects?(c) }
    n
  end
end
