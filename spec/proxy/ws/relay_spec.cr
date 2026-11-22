require "../../spec_helper"

# A continuation frame with no message in progress (RFC 6455 §5.4 violation) through both of
# `WS::Relay`'s pumps. It is a message of its own with opcode 0 in capture, and it reaches the
# peer as the bytes the sender wrote: never rule-rewritten, never re-framed under the previous
# message's opcode, never held.

private alias WS = Gori::Proxy::WS

private STRAY_CTX = WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

private class StraySink < Gori::Proxy::FlowSink
  getter messages = [] of {String, Int32, String}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @messages << {direction, opcode, String.new(payload)}
  end

  def client_rows : Array({Int32, String})
    @messages.select { |(dir, _, _)| dir == "out" }.map { |(_, op, text)| {op, text} }
  end
end

# A `part: ws` rule on client → server messages: `bbb` becomes `XXXX`.
private class StrayRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_ws_out_for_host?(host : String) : Bool
    true
  end

  def rewrite_ws_out(payload : Bytes, host : String) : Bytes
    s = String.new(payload)
    o = s.gsub("bbb", "XXXX")
    o == s ? payload : o.to_slice
  end
end

private def stray_masked(opcode : UInt8, payload : String, fin : Bool = true) : Bytes
  mask = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
  bytes = payload.to_slice
  io = IO::Memory.new
  io.write_byte((fin ? 0x80_u8 : 0_u8) | opcode)
  io.write_byte((0x80 | bytes.size).to_u8)
  io.write(mask)
  bytes.each_with_index { |b, i| io.write_byte(b ^ mask[i & 3]) }
  io.to_slice
end

private def stray_cat(parts : Array(Bytes)) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

private def stray_frames(wire : Bytes) : Array({UInt8, Bool, String})
  io = IO::Memory.new(wire)
  seen = [] of {UInt8, Bool, String}
  while h = WS.read_header(io)
    seen << {h.opcode, h.fin?, String.new(WS.read_body(io, h).not_nil!.payload)}
  end
  seen
end

# Feed `client_bytes` as the client's whole side of the socket, run the relay to the end, and
# answer what reached the origin.
private def relay_client_bytes(client_bytes : Bytes, sink : StraySink,
                               rewriter : Gori::Proxy::HeadRewriter? = nil) : Bytes
  cs_r, cs_w = IO.pipe
  ts_r, ts_w = IO.pipe
  ss_r, ss_w = IO.pipe
  tc_r, tc_w = IO.pipe
  client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
  upstream = IO::Stapled.new(ss_r, ts_w, sync_close: true)
  cs_w.write(client_bytes)
  cs_w.close
  ss_w.close
  wire = IO::Memory.new
  done = Channel(Nil).new(1)
  spawn do
    buf = Bytes.new(4096)
    while (n = ts_r.read(buf)) > 0
      wire.write(buf[0, n])
    end
    done.send(nil)
  end
  spawn { loop { tc_r.read(Bytes.new(4096)).zero? && break } }
  WS::Relay.run(client, upstream, 3_i64, sink, rewriter, STRAY_CTX)
  done.receive
  wire.to_slice
end

private def with_stray_interceptor(query : String, &)
  path = File.tempname("gori-ws-stray", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle
    ic.set_filter(query)
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def stray_wait_until(what : String, timeout = 3.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until block.call
    raise "timed out waiting for #{what}" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe Gori::Proxy::WS::Relay do
  it "records a stray CONT as opcode 0 on the byte-exact pump" do
    input = stray_cat([
      stray_masked(WS::OP_TEXT, "aaa"),
      stray_masked(WS::OP_CONT, "bbb"),
      # A control frame inside a fragmented message must not end the message in progress.
      stray_masked(WS::OP_TEXT, "frag", fin: false),
      stray_masked(WS::OP_PING, "mid"),
      stray_masked(WS::OP_CONT, "mented"),
      stray_masked(WS::OP_CONT, "again"),
    ])
    sink = StraySink.new
    relay_client_bytes(input, sink).should eq(input)
    sink.client_rows.should eq([
      {WS::OP_TEXT.to_i, "aaa"}, {WS::OP_CONT.to_i, "bbb"},
      {WS::OP_PING.to_i, "mid"}, {WS::OP_TEXT.to_i, "fragmented"},
      {WS::OP_CONT.to_i, "again"},
    ])
  end

  it "forwards a stray CONT byte-exact past a part: ws rule instead of re-framing it" do
    stray = [stray_masked(WS::OP_CONT, "bbb")]
    stray_fragments = [stray_masked(WS::OP_CONT, "bb", fin: false), stray_masked(WS::OP_CONT, "bbb")]
    input = stray_cat([stray_masked(WS::OP_TEXT, "aaa")] + stray + stray_fragments +
                      [stray_masked(WS::OP_TEXT, "bbb")])
    sink = StraySink.new
    wire = relay_client_bytes(input, sink, StrayRewriter.new)

    # The first four frames are the sender's own bytes; only the real TEXT message is rewritten.
    untouched = stray_cat([stray_masked(WS::OP_TEXT, "aaa")] + stray + stray_fragments)
    wire[0, untouched.size].should eq(untouched)
    stray_frames(wire[untouched.size..]).should eq([{WS::OP_TEXT, true, "XXXX"}])
    sink.client_rows.should eq([
      {WS::OP_TEXT.to_i, "aaa"}, {WS::OP_CONT.to_i, "bbb"}, {WS::OP_CONT.to_i, "bbbbb"},
      {WS::OP_TEXT.to_i, "XXXX"},
    ])
  end

  it "never holds a stray CONT, and releases it byte-exact behind a held message" do
    with_stray_interceptor("proto:ws") do |ic|
      ic.set_direction(Gori::Interceptor::Direction::RequestOnly)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
      upstream = IO::Stapled.new(ss_r, ts_w, sync_close: true)
      sink = StraySink.new
      spawn { WS::Relay.run(client, upstream, 4_i64, sink, nil, STRAY_CTX, ic) }

      held = stray_masked(WS::OP_TEXT, "aaa")
      stray = stray_masked(WS::OP_CONT, "bbb")
      cs_w.write(held)
      cs_w.write(stray)
      # A PING read back proves the pump has handled both data frames before it.
      cs_w.write(stray_masked(WS::OP_PING, "mark"))
      h = WS.read_header(ts_r).not_nil!
      WS.read_body(ts_r, h)
      h.opcode.should eq(WS::OP_PING)
      ic.pending_count.should eq(1)
      String.new(ic.pending.first.raw).should eq("aaa")

      ic.forward(ic.pending.first.id)
      got = Bytes.new(held.size + stray.size)
      ts_r.read_fully(got)
      got.should eq(stray_cat([held, stray]))
      stray_wait_until("both rows") { sink.client_rows.size >= 3 }
      sink.client_rows.should eq([
        {WS::OP_PING.to_i, "mark"}, {WS::OP_TEXT.to_i, "aaa"}, {WS::OP_CONT.to_i, "bbb"},
      ])
      ic.pending_count.should eq(0)
      cs_w.close rescue nil
      ss_w.close rescue nil
      tc_r.close rescue nil
    end
  end
end
