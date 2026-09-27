# Chunk-size line parse micro-benchmark: `Body.parse_chunk_size`, run once per chunk of every
# chunked request and response body the proxy relays (and by `chunked_complete?` per pooled
# Repeater/Fuzz send). The dominant line is a bare hex size and CRLF, which a byte scan
# answers without the String + strip + slice the general reader builds; anything else (an
# extension, whitespace, a sign, 16+ digits) still takes that reader.
#
# The stream rows put the parse in context: a body of many small chunks, the shape where
# the per-line cost is not hidden behind the payload copy.
#
# Build: crystal build bench/chunk_size_bench.cr -o bin/chunk_size_bench --release
# Run:   bin/chunk_size_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/codec/body"

include Gori::Proxy::Codec

LINES = ["1f40\r\n", "0\r\n", "4000\r\n", "a\n"].map(&.to_slice)
EXT   = "a;name=value\r\n".to_slice

# A chunked body of `count` chunks of `size` bytes each.
def chunked_wire(count : Int32, size : Int32) : Bytes
  io = IO::Memory.new
  count.times do
    io << size.to_s(16) << "\r\n"
    io.write(Bytes.new(size, 0x61_u8))
    io << "\r\n"
  end
  io << "0\r\n\r\n"
  io.to_slice.dup
end

SMALL = chunked_wire(1024, 64)

def run_chunked(wire : Bytes) : Int64
  src = IO::Memory.new(wire, writable: false)
  dst = IO::Memory.new(wire.size)
  cap = CaptureBuffer.new(Body::CAPTURE_MAX)
  Body.stream(src, dst, BodyFraming::Chunked, 0_i64, cap)
  dst.size.to_i64
end

Benchmark.ips do |x|
  x.report("parse 4 plain size lines") { LINES.each { |l| Body.parse_chunk_size(l) } }
  x.report("parse a size line with an extension") { Body.parse_chunk_size(EXT) }
  x.report("stream 1024 x 64B chunks") { run_chunked(SMALL) }
end
