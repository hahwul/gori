# `WS::Relay` — the per-frame cost of relaying a WebSocket, on the default byte-exact pump.
#
# Written for #1630, which put every relayed write behind a per-direction `WS::Leg` (one
# uncontended Mutex and a Bool per frame) so a frame can be injected between two relayed ones.
# Pipes stand in for the sockets and the sink records nothing, so what is left is the pump:
# header read, body read, the write, and the capture call. Only `Relay.run`'s public signature
# is used, so the same file runs on a tree without the leg for the before number.
#
# Build: crystal build bench/ws_relay_bench.cr -o bin/ws_relay_bench --release
# Run:   bin/ws_relay_bench
require "../src/gori"

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

FRAMES = 200_000
FRAME  = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, ("x" * 64).to_slice, mask: true)

# Relay FRAMES client→server frames and return {elapsed, bytes allocated}.
def run_once : {Time::Span, UInt64}
  cs_r, cs_w = IO.pipe
  ts_r, ts_w = IO.pipe
  ss_r, ss_w = IO.pipe
  tc_r, tc_w = IO.pipe
  client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
  upstream = IO::Stapled.new(ss_r, ts_w, sync_close: true)
  relayed = Channel(Nil).new(1)
  read_all = Channel(Nil).new(1)
  spawn do
    Gori::Proxy::WS::Relay.run(client, upstream, 1_i64, NullSink.new)
    relayed.send(nil)
  end
  spawn do
    buf = Bytes.new(64 * 1024)
    left = FRAMES.to_i64 * FRAME.size
    while left > 0
      n = ts_r.read(buf)
      break if n == 0
      left -= n
    end
    read_all.send(nil)
  end
  before = GC.stats.total_bytes
  t0 = Time.instant
  FRAMES.times { cs_w.write(FRAME) }
  cs_w.flush
  read_all.receive
  elapsed = Time.instant - t0
  allocated = GC.stats.total_bytes - before
  cs_w.close
  ss_w.close
  relayed.receive
  tc_r.close rescue nil
  {elapsed, allocated}
end

run_once # warm up
runs = Array.new(5) { run_once }
times = runs.map(&.[0]).sort!
median = times[times.size // 2]
bytes = runs.map(&.[1]).sort![runs.size // 2]
puts "ws relay: #{FRAMES} frames of #{FRAME.size}B — median #{median.total_milliseconds.round(1)} ms " \
     "(#{(median.total_nanoseconds / FRAMES).round(0)} ns/frame), #{bytes // FRAMES} B/frame allocated"
