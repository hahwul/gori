# WS unmask micro-benchmark. Every client→server WS frame is masked, so the unmask runs
# over the whole payload of every upload. Compares the word-XOR against the old scalar loop.
#
# Build: crystal build bench/ws_unmask_bench.cr -o bin/ws_unmask_bench --release
# Run:   bin/ws_unmask_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/ws/frame"

KEY = Bytes[0xAA, 0xBB, 0xCC, 0xDD]

def scalar(src : Bytes, key : Bytes, dst : Bytes) : Nil
  src.size.times { |i| dst[i] = src[i] ^ key[i & 3] }
end

{64, 4096, 65536}.each do |n|
  src = Bytes.new(n) { |i| (i & 0xff).to_u8 }
  dst = Bytes.new(n)
  puts "\npayload = #{n} bytes:"
  Benchmark.ips do |x|
    x.report("scalar byte XOR") { scalar(src, KEY, dst) }
    x.report("word XOR (Frame.unmask)") { Gori::Proxy::WS.unmask(src, KEY, dst) }
  end
end
