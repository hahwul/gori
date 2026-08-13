require "../spec_helper"
require "socket"

# `Relay.run`'s teardown, which is the one moment at which the relay's two pump fibers and
# `run`'s own fiber are all live at once: it writes what each pump is still withholding while
# BOTH sockets are still open, and only then closes them. Everything here is about that window.
# The byte-exact and rewrite-only paths are covered in ws_spec.cr and the gated ones in
# ws_hold_spec.cr; these are the teardown's own hazards.

private WS_CTX = Gori::Proxy::WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

# A masked client frame of any opcode. Unlike ws_spec.cr's helper this also writes the 16-bit
# extended length, because a control frame LARGER than §5.5's 125 bytes is the whole point of
# the parking-ceiling example below (`forward_control` deliberately relays such a frame).
private def masked_op_frame(opcode : UInt8, payload : Bytes, fin : Bool = true) : Bytes
  mask = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
  io = IO::Memory.new
  io.write_byte((fin ? 0x80_u8 : 0_u8) | opcode)
  if payload.size < 126
    io.write_byte((0x80 | payload.size).to_u8)
  else
    io.write_byte(0xFE_u8) # masked, 16-bit extended length
    io.write_byte((payload.size >> 8).to_u8)
    io.write_byte((payload.size & 0xFF).to_u8)
  end
  io.write(mask)
  payload.each_with_index { |b, i| io.write_byte(b ^ mask[i & 3]) }
  io.to_slice
end

# A Match & Replace lens whose `out` rule matches nothing: enough to put the socket on the
# assembling pump (which is what parks control frames and withholds fragments) while leaving
# every message byte-exact, so the wire says only what the teardown did.
private class TeardownRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_ws_out_for_host?(host : String) : Bool
    true
  end

  def rewrites_ws_in_for_host?(host : String) : Bool
    false
  end

  def rewrite_ws_out(payload : Bytes, host : String) : Bytes
    payload
  end

  def rewrite_ws_in(payload : Bytes, host : String) : Bytes
    payload
  end
end

private class TeardownSink < Gori::Proxy::FlowSink
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
end

# A sink that YIELDS inside the teardown flush, which is what a real one does: every
# `on_ws_message` is a store round-trip. On the first `out` row it also delivers one more
# fragment onto the pump's own socket, so `Relay.run`'s fiber and the still-live pump fiber
# are inside the same half-assembled message at the same time.
private class RacingSink < Gori::Proxy::FlowSink
  getter messages = [] of {String, Int32, String}
  @fired = false

  def initialize(@late_io : IO, @late : Bytes)
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @messages << {direction, opcode, String.new(payload)}
    return if @fired || direction != "out"
    @fired = true
    @late_io.write(@late)
    @late_io.flush
    @late_io.close # ... and then the client is gone, so the pump ends either way
    sleep 30.milliseconds
  end
end

describe "WS::Relay teardown" do
  # `Relay.run` reaches `flush_at_teardown` from its OWN fiber while the surviving pump fiber
  # is still reading — the flush latches `@torn_down` (disabling that pump's own `ensure`
  # flush and its loss notice), then yields on the sink write, then ends with `reset_buffer`.
  # A fragment that arrived inside that window was appended by the pump and then either wiped
  # by the reset with no wire write and no row, or — when it carried the FIN — re-emitted from
  # `interleaved_raw`, which still held the leading frame the flush had ALREADY written. The
  # peer then read `TEXT fin=0 "AAA"` twice, a §5.4 violation gori invented rather than
  # relayed, and the transcript claimed a message the wire never carried.
  #
  # `AAA` is written EXACTLY once here. What arrives after the flush is not forwarded — the
  # sockets are closing and there is nothing left that could put it out — but it is not
  # allowed to corrupt what already went.
  it "does not re-emit an already-flushed fragment when one arrives during the teardown flush" do
    lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false)
    tail = masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice)

    cs_r, cs_w = IO.pipe
    ts_r, ts_w = IO.pipe
    ss_r, ss_w = IO.pipe
    tc_r, tc_w = IO.pipe
    client = IO::Stapled.new(cs_r, tc_w)
    upstream = IO::Stapled.new(ss_r, ts_w)

    cs_w.write(lead)
    cs_w.flush
    ss_w.close # the ORIGIN ends first, with the client still mid-message

    sink = RacingSink.new(cs_w, tail)
    Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink, TeardownRewriter.new, WS_CTX)

    ts_w.close
    ts_r.gets_to_end.to_slice.should eq(lead) # was: lead + lead + tail
    # ... and capture says the same thing. The second row was built from a buffer the flush
    # had already emptied, so it claimed a complete "AAABBB" the peer never received.
    sink.messages.select { |(dir, _, _)| dir == "out" }.should eq([{"out", 1, "AAA"}])
    _ = tc_r
  end

  # The parking ceiling used to be a COUNT only, and the constant's own comment justified that
  # with §5.5's 125-byte control payload cap — a cap `forward_control` deliberately does not
  # enforce (P7: a peer that advertises more gets its frame relayed, not its tunnel killed).
  # So "8 frames" really meant "8 x MAX_FRAME" = ~128 MiB parked per direction, outside the
  # MAX_MESSAGE budget that bounds the assembly buffer and the raw accumulator. Three 400-byte
  # PINGs are five frames BELOW the count ceiling, so only the byte ceiling can fire here.
  it "gives up the parked interleave on the byte ceiling, five frames below the count one" do
    lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false)
    tail = masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice)
    pings = (0...3).map do |i|
      masked_op_frame(Gori::Proxy::WS::OP_PING, Bytes.new(400, (0x30 + i).to_u8))
    end

    cs_r, cs_w = IO.pipe
    ts_r, ts_w = IO.pipe
    ss_r, ss_w = IO.pipe
    tc_r, tc_w = IO.pipe
    client = IO::Stapled.new(cs_r, tc_w)
    upstream = IO::Stapled.new(ss_r, ts_w)

    cs_w.write(lead)
    pings.each { |p| cs_w.write(p) }
    cs_w.write(tail)
    cs_w.close
    ss_w.close

    sink = TeardownSink.new
    Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink, TeardownRewriter.new, WS_CTX)

    ts_w.close
    # The documented hoist, identical to the count ceiling's: the third PING trips it,
    # everything parked goes out ahead of the fragments, and the message follows byte-exact.
    ts_r.gets_to_end.to_slice.should eq(pings.reduce(Bytes.empty) { |a, p| a + p } + lead + tail)

    notices = sink.messages.select { |(_, _, text)| text.starts_with?("[gori] ") }
    notices.size.should eq(1)        # once per direction per socket
    notices.first[0].should eq("in") # a diagnostic is not traffic — never the seed direction
    # The sentence names WHICH ceiling gave way; a count of three could not have tripped the
    # other one, and an operator reading "8 control frames" here would be told a falsehood.
    # Read off the constant rather than spelled out: the ceiling is derived from the WIRE size
    # of a compliant control frame (payload cap + header + mask key), so a literal here would
    # pin the arithmetic to whichever of those someone last remembered.
    notices.first[2].should contain(
      "more than #{Gori::Proxy::WS::Relay::MAX_PARKED_BYTES} bytes of control frames arrived between the fragments")
    notices.first[2].should contain("client→server")
    sink.messages.last.should eq({"out", 1, "AAABBB"})
    _ = tc_r
  end

  # Every teardown write happens BEFORE the two `close` calls, and ClientConn relaxes both
  # legs on the way into the tunnel — so a peer that stopped reading blocked the settle/flush
  # writes with no deadline, and `close`, the only thing that could have unblocked them, was
  # sequenced after. That pinned `Relay.run`'s fiber, both pump fibers, both fds and one of
  # the server's connection slots permanently: the fd-exhaustion shape `Pump.blind_tunnel`
  # cross-closes to avoid. Re-arming a bounded timeout makes the stalled write RAISE into the
  # "could not be delivered" disposition both write sites already have.
  #
  # Asserted on the socket rather than by stalling a peer, because the arming is the fix and a
  # filled send buffer is a timing test. `UNIXSocket` is used for the same reason `SocketTuning`
  # resolves through wrappers: the timeout lives on the fd, not on the relay.
  it "re-arms a bounded write timeout on both legs before the teardown writes" do
    client, client_peer = UNIXSocket.pair
    upstream, upstream_peer = UNIXSocket.pair
    Gori::Proxy::SocketTuning.relax(client)
    Gori::Proxy::SocketTuning.relax(upstream)
    client.write_timeout.should be_nil # the state Relay.run inherits from ClientConn
    upstream.write_timeout.should be_nil

    client_peer.close
    upstream_peer.close

    Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, TeardownSink.new)

    client.write_timeout.should eq(Gori::Proxy::WS::Relay::CLOSE_TIMEOUT)
    upstream.write_timeout.should eq(Gori::Proxy::WS::Relay::CLOSE_TIMEOUT)
    # The read timeout comes with it, and that is why the arming is placed AFTER the CLOSE
    # decision window: armed before it, a surviving pump would trip at exactly CLOSE_TIMEOUT
    # and land in `observed` as a peer reset that never happened.
    client.read_timeout.should eq(Gori::Proxy::WS::Relay::CLOSE_TIMEOUT)
  end
end
