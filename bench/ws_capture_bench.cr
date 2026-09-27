# WebSocket capture micro-benchmark: `WS::Relay.capture_frame`, the per-data-frame step
# every relayed socket runs (h1 `pump`, `AssemblingPump` passthrough, h2 `WsCapture`).
#
# Most real messages are ONE frame (FIN set, nothing assembled before it). For those the
# payload `WS.read_body` just allocated is already the message, so capture hands it to the
# sink as-is instead of copying it through the reassembly buffer and `dup`ing it back out.
# A fragmented message still goes through the buffer; its row is here as the control.
#
# Build: crystal build bench/ws_capture_bench.cr -o bin/ws_capture_bench --release
# Run:   bin/ws_capture_bench
require "benchmark"

module Gori
  class Error < Exception; end

  # client_conn stamps this into the CONNECT-failure page; see proxy_bench.cr.
  VERSION = "0.0.0-bench"
end

require "../src/gori/proxy/ws/relay"
require "../src/gori/proxy/sink"

class NullSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

include Gori::Proxy

# An unmasked (server→client) frame with the given FIN bit and opcode.
def frame(n : Int32, fin : Bool, opcode : UInt8) : WS::Frame
  io = IO::Memory.new
  io.write_byte((fin ? 0x80_u8 : 0_u8) | opcode)
  if n < 126
    io.write_byte(n.to_u8)
  else
    io.write_byte(127_u8)
    io.write_bytes(n.to_u64, IO::ByteFormat::BigEndian)
  end
  io.write(Bytes.new(n) { |i| (i % 251).to_u8 })
  io.rewind
  WS.read_frame(io) || raise "bad frame"
end

SINK = NullSink.new

{64, 4096, 1 << 20}.each do |n|
  single = frame(n, true, WS::OP_TEXT)
  first = frame(n // 2, false, WS::OP_TEXT)
  last = frame(n - n // 2, true, WS::OP_CONT)
  shape = WS::MessageShape.new
  acc = IO::Memory.new
  puts "\nmessage = #{n} bytes:"
  Benchmark.ips do |x|
    x.report("single FIN frame") do
      shape.note(single)
      acc = WS::Relay.capture_frame(single, acc, "in", 1_i64, SINK, WS::OP_TEXT, shape)
    end
    x.report("two fragments (control)") do
      shape.note(first)
      acc = WS::Relay.capture_frame(first, acc, "in", 1_i64, SINK, WS::OP_TEXT, shape)
      shape.note(last)
      acc = WS::Relay.capture_frame(last, acc, "in", 1_i64, SINK, WS::OP_TEXT, shape)
    end
  end
end
