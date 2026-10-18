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
require "../src/gori/proxy/live_capture"
require "../src/gori/sse"

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

BODY_64K  = len_body(64 * 1024)
BODY_1M   = len_body(1024 * 1024)
CHUNK_64K = chunked_wire(64 * 1024, 16 * 1024)
CHUNK_1M  = chunked_wire(1024 * 1024, 16 * 1024)

# One copy buffer reused across ops, as ClientConn lends a pooled one
# (CopyBufPool), and a DiscardIO sink, so bytes/op is the capture alone.
SCRATCH = Bytes.new(Body::BUFSIZE)
SINK    = DiscardIO.new

# Drive one Content-Length body through Body.stream, teeing into a fresh
# CaptureBuffer sized by `hint`, and return the captured slice (so DCE can't
# drop the work).
def run_length(body : Bytes, hint : Int64) : Bytes
  src = IO::Memory.new(body, writeable: false)
  cap = CaptureBuffer.new(CAP, hint)
  Body.stream(src, SINK, BodyFraming::Length, body.size.to_i64, cap, SCRATCH)
  cap.to_slice
end

def run_chunked(wire : Bytes) : Bytes
  src = IO::Memory.new(wire, writeable: false)
  cap = CaptureBuffer.new(CAP)
  Body.stream(src, SINK, BodyFraming::Chunked, 0_i64, cap, SCRATCH)
  cap.to_slice
end

# A bodyless GET: None framing, capture never written — measures the wasted
# per-flow CaptureBuffer allocation on the dominant traffic shape.
def run_none : Int32
  cap = CaptureBuffer.new(CAP)
  Body.stream(IO::Memory.new, IO::Memory.new, BodyFraming::None, 0_i64, cap)
  cap.to_slice.size
end

# A chunked event stream: 256 events of ~250 bytes, one chunk each, as an SSE origin sends them.
SSE_EVENT = "data: #{"x" * 240}\n\n"
SSE_WIRE  = String.build do |io|
  256.times { io << SSE_EVENT.bytesize.to_s(16) << "\r\n" << SSE_EVENT << "\r\n" }
  io << "0\r\n\r\n"
end.to_slice

# Takes every live append and drops it, so bytes/op is the tee's own batching and copying.
class NullLiveSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end

  def on_live_body(flow_id : Int64, off : Int64, bytes : Bytes, head : Gori::Store::CapturedResponse?) : Bool
    true
  end
end

LIVE_SINK = NullLiveSink.new
LIVE_HEAD = Gori::Store::CapturedResponse.new(flow_id: 1_i64, status: 200,
  head: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice,
  state: Gori::Store::FlowState::Pending)

# The SSE path (#1631): the same chunked copy, teed into a LiveCapture. In one burst the clock
# never passes FLUSH_EVERY, so this is the first-event append plus the 16 KiB size trigger.
def run_sse_live(wire : Bytes) : Bytes
  src = IO::Memory.new(wire, writeable: false)
  cap = Gori::Proxy::LiveCapture.new(CAP, 0_i64, LIVE_SINK, LIVE_HEAD)
  Body.stream(src, SINK, BodyFraming::Chunked, 0_i64, cap, SCRATCH)
  cap.to_slice
end

puts "CaptureBuffer / Body.stream isolated (ips):"
puts "(hint) = presized to Content-Length; (nohint) = old default-growth path"
Benchmark.ips do |x|
  x.report("none (bodyless GET)") { run_none }
  x.report("length 64K (hint)") { run_length(BODY_64K, BODY_64K.size.to_i64) }
  x.report("length 64K (nohint)") { run_length(BODY_64K, 0_i64) }
  x.report("length 1M  (hint)") { run_length(BODY_1M, BODY_1M.size.to_i64) }
  x.report("length 1M  (nohint)") { run_length(BODY_1M, 0_i64) }
  x.report("chunked 64K") { run_chunked(CHUNK_64K) }
  x.report("chunked 1M") { run_chunked(CHUNK_1M) }
  # The streaming path's SSE decision, asked of every streamed response (#1631).
  x.report("sse? (text/html)") { Gori::Sse.sse?("text/html; charset=utf-8") }
  x.report("chunked SSE 64K (plain)") { run_chunked(SSE_WIRE) }
  x.report("chunked SSE 64K (live)") { run_sse_live(SSE_WIRE) }
end
