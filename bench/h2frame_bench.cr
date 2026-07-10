# h2 Frame.read allocation micro-benchmark. The relay pump calls Frame.read once per
# frame (every DATA/HEADERS/WINDOW_UPDATE/PING/SETTINGS, both directions), so the 9-byte
# header buffer it allocated per frame was pure GC churn. This drives Frame.read over a
# stream of small frames (the WINDOW_UPDATE/PING/SETTINGS shape that dominates a busy h2
# connection) and reports bytes/op.
#
# Build: crystal build bench/h2frame_bench.cr -o bin/h2frame_bench --release
# Run:   bin/h2frame_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/h2/frame"

include Gori::Proxy::H2

# Build a wire buffer of many tiny frames (8-byte WINDOW_UPDATE payload = the busiest shape).
def frame_stream(count : Int32, payload_len : Int32) : Bytes
  io = IO::Memory.new
  count.times do
    io.write_byte(((payload_len >> 16) & 0xff).to_u8)
    io.write_byte(((payload_len >> 8) & 0xff).to_u8)
    io.write_byte((payload_len & 0xff).to_u8)
    io.write_byte(0x08_u8) # type WINDOW_UPDATE
    io.write_byte(0x00_u8) # flags
    io.write_byte(0x00_u8); io.write_byte(0x00_u8); io.write_byte(0x00_u8); io.write_byte(0x01_u8) # stream 1
    payload_len.times { |i| io.write_byte((i & 0xff).to_u8) }
  end
  io.to_slice.dup
end

SMALL = frame_stream(1000, 4)    # 1000 tiny frames (WINDOW_UPDATE-ish)
DATA  = frame_stream(500, 16384) # 500 x 16KB DATA frames

def drain(wire : Bytes) : Int32
  io = IO::Memory.new(wire, writeable: false)
  n = 0
  while f = Frame.read(io)
    n += f.payload.size
  end
  n
end

puts "h2 Frame.read over a frame stream (bytes/op = per whole stream):"
Benchmark.ips do |x|
  x.report("1000 tiny frames (4B payload)") { drain(SMALL) }
  x.report("500 DATA frames (16KB payload)") { drain(DATA) }
end
