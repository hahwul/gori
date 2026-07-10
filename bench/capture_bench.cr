# Isolated CaptureBuffer / Body.stream micro-benchmark.
#
# proxy_bench measures a full loopback round-trip, whose socket + scheduler noise
# (±40% run-to-run) drowns out a per-request allocation change. This drives the
# body codec's tee path directly over IO::Memory (no sockets), so Benchmark.ips
# isolates the CaptureBuffer allocation/copy cost with stable ns/op + bytes/op.
#
# Build: crystal build bench/capture_bench.cr -o bin/capture_bench --release
# Run:   bin/capture_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/codec/body"

include Gori::Proxy::Codec

CAP = Gori::Proxy::Codec::Body::CAPTURE_MAX

def len_body(n : Int32) : Bytes
  b = Bytes.new(n)
  n.times { |i| b[i] = (32 + (i % 90)).to_u8 }
  b
end

def chunked_wire(n : Int32, chunk : Int32) : Bytes
  io = IO::Memory.new
  off = 0
  while off < n
    sz = {chunk, n - off}.min
    io << sz.to_s(16) << "\r\n"
    io.write(len_body(sz))
    io << "\r\n"
    off += sz
  end
  io << "0\r\n\r\n"
  io.to_slice.dup
end

BODY_64K   = len_body(64 * 1024)
BODY_1M    = len_body(1024 * 1024)
CHUNK_64K  = chunked_wire(64 * 1024, 16 * 1024)
CHUNK_1M   = chunked_wire(1024 * 1024, 16 * 1024)

# Drive one Content-Length body through Body.stream, teeing into a fresh
# CaptureBuffer sized by `hint`, and return the captured slice (so DCE can't
# drop the work).
def run_length(body : Bytes, hint : Int64) : Bytes
  src = IO::Memory.new(body, writeable: false)
  dst = IO::Memory.new(body.size)
  cap = CaptureBuffer.new(CAP, hint)
  Body.stream(src, dst, BodyFraming::Length, body.size.to_i64, cap)
  cap.to_slice
end

def run_chunked(wire : Bytes) : Bytes
  src = IO::Memory.new(wire, writeable: false)
  dst = IO::Memory.new(wire.size)
  cap = CaptureBuffer.new(CAP)
  Body.stream(src, dst, BodyFraming::Chunked, 0_i64, cap)
  cap.to_slice
end

# A bodyless GET: None framing, capture never written — measures the wasted
# per-flow CaptureBuffer allocation on the dominant traffic shape.
def run_none : Int32
  cap = CaptureBuffer.new(CAP)
  Body.stream(IO::Memory.new, IO::Memory.new, BodyFraming::None, 0_i64, cap)
  cap.to_slice.size
end

puts "CaptureBuffer / Body.stream isolated (ips):"
puts "(hint) = presized to Content-Length; (nohint) = old default-growth path"
Benchmark.ips do |x|
  x.report("none (bodyless GET)")    { run_none }
  x.report("length 64K (hint)")      { run_length(BODY_64K, BODY_64K.size.to_i64) }
  x.report("length 64K (nohint)")    { run_length(BODY_64K, 0_i64) }
  x.report("length 1M  (hint)")      { run_length(BODY_1M, BODY_1M.size.to_i64) }
  x.report("length 1M  (nohint)")    { run_length(BODY_1M, 0_i64) }
  x.report("chunked 64K")            { run_chunked(CHUNK_64K) }
  x.report("chunked 1M")             { run_chunked(CHUNK_1M) }
end
