require "../spec_helper"

# Injecting a frame into a live h1 WebSocket relay (#1630): `WS::Leg`, `WS::Live` and the
# bridge command the capturing instance applies. Pipes stand in for the two sockets, so what
# each peer reads is exactly what the relay wrote.

private alias WS = Gori::Proxy::WS

private LIVE_CTX = WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

private UPGRADE_HEAD = "GET /ws HTTP/1.1\r\nHost: echo.test\r\nUpgrade: websocket\r\n" \
                       "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" \
                       "Sec-WebSocket-Version: 13\r\n\r\n"

# `cs_w` writes as the client, `ts_r` reads as the origin, `ss_w` writes as the origin,
# `tc_r` reads as the client.
private record LiveRig, client : IO, upstream : IO, cs_w : IO, ts_r : IO, ss_w : IO, tc_r : IO do
  def shutdown : Nil
    cs_w.close rescue nil
    ss_w.close rescue nil
  end
end

private def live_rig : LiveRig
  cs_r, cs_w = IO.pipe
  ts_r, ts_w = IO.pipe
  ss_r, ss_w = IO.pipe
  tc_r, tc_w = IO.pipe
  LiveRig.new(IO::Stapled.new(cs_r, tc_w, sync_close: true),
    IO::Stapled.new(ss_r, ts_w, sync_close: true), cs_w, ts_r, ss_w, tc_r)
end

# Records every row, and whether the relay called the injected-frame hook for it.
private class LiveSink < Gori::Proxy::FlowSink
  getter rows = [] of {String, Int32, String, Bool}
  getter shapes = [] of Gori::Proxy::WS::Shape

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << {direction, opcode, String.new(payload), false}
  end

  def on_ws_injected(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                     shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << {direction, opcode, String.new(payload), true}
    @shapes << shape
  end
end

# A sink that keeps no origin: the FlowSink default must still record the frame.
private class PlainSink < Gori::Proxy::FlowSink
  getter rows = [] of String

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << String.new(payload)
  end
end

private def masked_frame(opcode : UInt8, payload : String, fin : Bool = true) : Bytes
  WS.encode(opcode, payload.to_slice, mask: true, fin: fin)
end

private def read_frame(io : IO) : WS::Frame
  h = WS.read_header(io).not_nil!
  WS.read_body(io, h).not_nil!
end

private def await_live(sink : Gori::Proxy::FlowSink, flow_id : Int64) : WS::Live::Entry
  200.times do
    if e = WS::Live.find(sink, flow_id)
      return e
    end
    sleep 1.millisecond
  end
  raise "relay never registered flow #{flow_id}"
end

# A `part: ws` lens on the client→server side that changes nothing: it puts that direction on
# the assembling pump, where a BINARY message is relayed frame by frame (passthrough).
private class NoopWsRewriter < Gori::Proxy::HeadRewriter
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

# An upstream whose FIRST write runs `on_write` before it: with nothing relayed to the origin
# yet, that write is the relay's own teardown flush.
private class TeardownTap < IO
  @fired = false

  def initialize(@io : IO, &@on_write : ->)
  end

  def read(slice : Bytes) : Int32
    @io.read(slice)
  end

  def write(slice : Bytes) : Nil
    unless @fired
      @fired = true
      @on_write.call
    end
    @io.write(slice)
  end

  def flush : Nil
    @io.flush
  end

  def close : Nil
    @io.close
  end
end

# Run a relay for `flow_id`, hand the rig to the block, then shut it down and reap the relay.
private def with_relay(sink : Gori::Proxy::FlowSink, flow_id : Int64,
                       rewriter : Gori::Proxy::HeadRewriter? = nil, interceptor : Gori::Interceptor? = nil, &)
  r = live_rig
  done = Channel(Nil).new(1)
  spawn do
    WS::Relay.run(r.client, r.upstream, flow_id, sink, rewriter, LIVE_CTX, interceptor)
    done.send(nil)
  end
  await_live(sink, flow_id)
  begin
    yield r
  ensure
    r.shutdown
    receive_within(done, 5, "the relay to end")
  end
end

# A relay whose CLIENT side is a real 127.0.0.1 socket: the peer behind it is `browser`, which
# the block may simply never read. The origin side stays a pipe.
private def with_socket_relay(sink : Gori::Proxy::FlowSink, flow_id : Int64, & : TCPSocket, IO -> Nil)
  server = TCPServer.new("127.0.0.1", 0)
  browser = TCPSocket.new("127.0.0.1", server.local_address.port)
  client = server.accept
  ss_r, ss_w = IO.pipe
  ts_r, ts_w = IO.pipe
  done = Channel(Nil).new(1)
  spawn do
    WS::Relay.run(client, IO::Stapled.new(ss_r, ts_w, sync_close: true), flow_id, sink, nil, LIVE_CTX)
    done.send(nil)
  end
  await_live(sink, flow_id)
  begin
    yield browser, ss_w
  ensure
    browser.close rescue nil
    ss_w.close rescue nil
    receive_within(done, 10, "the relay to end")
    ts_r.close rescue nil
    server.close
  end
end

private def inject(sink, flow_id, direction, opcode, payload : String, wait = WS::Live::BOUNDARY_WAIT,
                   outbound = ungated_outbound) : String?
  WS::Live.inject(sink, flow_id, direction, opcode, payload.to_slice, outbound, wait)
end

describe Gori::Proxy::WS::Live do
  it "injects client→server masked with a fresh key, and server→client unmasked" do
    sink = LiveSink.new
    with_relay(sink, 401_i64) do |r|
      inject(sink, 401_i64, "out", WS::OP_TEXT, "to-server").should be_nil
      f = read_frame(r.ts_r)
      {f.opcode, f.fin?, f.rsv, f.masked?, String.new(f.payload)}.should eq({WS::OP_TEXT, true, 0_u8, true, "to-server"})

      inject(sink, 401_i64, "in", WS::OP_BIN, "to-client").should be_nil
      g = read_frame(r.tc_r)
      {g.opcode, g.fin?, g.rsv, g.masked?, String.new(g.payload)}.should eq({WS::OP_BIN, true, 0_u8, false, "to-client"})

      sink.rows.should eq([{"out", 1, "to-server", true}, {"in", 2, "to-client", true}])
    end
  end

  it "holds a data frame until a fragmented message ends, then sends it after the final fragment" do
    sink = LiveSink.new
    with_relay(sink, 402_i64) do |r|
      r.cs_w.write(masked_frame(WS::OP_TEXT, "AAA", fin: false))
      read_frame(r.ts_r).fin?.should be_false
      result = Channel(String?).new(1)
      spawn { result.send(inject(sink, 402_i64, "out", WS::OP_TEXT, "X")) }
      select
      when early = result.receive
        fail "the inject went in mid-message: #{early.inspect}"
      when timeout(50.milliseconds)
      end
      r.cs_w.write(masked_frame(WS::OP_CONT, "BBB", fin: true))
      receive_within(result, 5, "the inject").should be_nil
      last = read_frame(r.ts_r)
      {last.opcode, String.new(last.payload)}.should eq({WS::OP_CONT, "BBB"})
      injected = read_frame(r.ts_r)
      {injected.opcode, String.new(injected.payload)}.should eq({WS::OP_TEXT, "X"})
    end
  end

  it "refuses a data frame when the message boundary never comes, and writes nothing" do
    sink = LiveSink.new
    with_relay(sink, 403_i64) do |r|
      r.cs_w.write(masked_frame(WS::OP_TEXT, "open", fin: false))
      read_frame(r.ts_r)
      refusal = inject(sink, 403_i64, "out", WS::OP_TEXT, "late", wait: 100.milliseconds)
      refusal.not_nil!.should contain("stayed mid-message")
      sink.rows.none?(&.[3]).should be_true
      # The next thing the origin reads is the message's own final fragment.
      r.cs_w.write(masked_frame(WS::OP_CONT, "end", fin: true))
      String.new(read_frame(r.ts_r).payload).should eq("end")
    end
  end

  it "records the mask key it put on the wire, so the capture is the peer's bytes" do
    sink = LiveSink.new
    with_relay(sink, 411_i64) do |r|
      inject(sink, 411_i64, "out", WS::OP_TEXT, "keyed").should be_nil
      f = read_frame(r.ts_r)
      key = sink.shapes[0].mask_key.not_nil!
      {key.size, key}.should eq({4, f.mask_key})
      inject(sink, 411_i64, "in", WS::OP_TEXT, "plain").should be_nil
      read_frame(r.tc_r)
      {sink.shapes[1].masked, sink.shapes[1].mask_key}.should eq({false, nil})
    end
  end

  it "refuses a data frame after a CLOSE went out on that side, and still lets a control frame in" do
    sink = LiveSink.new
    with_relay(sink, 412_i64) do |r|
      r.cs_w.write(masked_frame(WS::OP_CLOSE, ""))
      read_frame(r.ts_r).opcode.should eq(WS::OP_CLOSE)
      inject(sink, 412_i64, "out", WS::OP_TEXT, "after").not_nil!.should contain("RFC 6455 §5.5.1")
      inject(sink, 412_i64, "out", WS::OP_PING, "hb").should be_nil
      read_frame(r.ts_r).opcode.should eq(WS::OP_PING)
      # An injected CLOSE counts too.
      inject(sink, 412_i64, "in", WS::OP_CLOSE, "").should be_nil
      inject(sink, 412_i64, "in", WS::OP_TEXT, "after").not_nil!.should contain("RFC 6455 §5.5.1")
      sink.rows.select(&.[3]).map(&.[1]).should eq([9, 8])
    end
  end

  it "lets one data frame wait for a boundary per side and refuses a second at once" do
    sink = LiveSink.new
    with_relay(sink, 413_i64) do |r|
      r.cs_w.write(masked_frame(WS::OP_TEXT, "open", fin: false))
      read_frame(r.ts_r)
      first = Channel(String?).new(1)
      spawn { first.send(inject(sink, 413_i64, "out", WS::OP_TEXT, "one")) }
      sleep 30.milliseconds
      inject(sink, 413_i64, "out", WS::OP_TEXT, "two").should eq(WS::Live::ANOTHER_WAITING)
      inject(sink, 413_i64, "out", WS::OP_PING, "hb").should be_nil
      read_frame(r.ts_r).opcode.should eq(WS::OP_PING)
      r.cs_w.write(masked_frame(WS::OP_CONT, "end", fin: true))
      receive_within(first, 5, "the waiting inject").should be_nil
      read_frame(r.ts_r)
      String.new(read_frame(r.ts_r).payload).should eq("one")
    end
  end

  it "bounds its own write on a peer that stopped reading, so teardown is not pinned" do
    sink = LiveSink.new
    landed = 0
    with_socket_relay(sink, 414_i64) do |_browser, origin|
      result = Channel(String?).new(1)
      big = "x" * (32 * 1024 * 1024)
      # One frame parks on a POSIX socket. Windows takes the whole first send into the kernel
      # however large, and parks the NEXT one once more than SO_SNDBUF is queued, so the frame
      # that parks is the second there (measured on the CI runner: 32 MiB completes in 9 ms).
      spawn do
        outcome = nil
        3.times do
          break if outcome = inject(sink, 414_i64, "in", WS::OP_BIN, big, wait: 300.milliseconds)
          landed += 1
        end
        result.send(outcome)
      end
      sleep 150.milliseconds
      # The origin closes while the inject is parked: the relay's CLOSE forward and teardown
      # writes queue on the same leg and must get through once the inject gives up.
      origin.write(WS.encode(WS::OP_CLOSE, Bytes.empty, mask: false))
      receive_within(result, 5, "the inject to give up").not_nil!.should contain("stopped reading")
    end
    sink.rows.count(&.[3]).should eq(landed) # the frame that parked left no row
    # gori closed the socket, so the peer is not blamed with a RESET row; gori says it did.
    sink.rows.none?(&.[2].includes?("RESET")).should be_true
    sink.rows.map(&.[2]).should contain(
      "#{WS::NOTICE_PREFIX}gori closed this socket: an injected frame could not finish writing server→client")
  end

  it "leaves a client's reset under a parked inject to the client, not to gori" do
    sink = LiveSink.new
    outcome = nil
    with_socket_relay(sink, 415_i64) do |browser, _origin|
      result = Channel(String?).new(1)
      big = "x" * (32 * 1024 * 1024)
      spawn do
        r = nil
        # The default wait, so the reset comes long before the write could time out. Up to
        # three frames for the same reason as above: Windows parks only a later send.
        3.times { break if r = inject(sink, 415_i64, "in", WS::OP_BIN, big) }
        result.send(r)
      end
      sleep 150.milliseconds
      browser.linger = 0 # an RST, not a FIN
      browser.close
      outcome = receive_within(result, 5, "the inject to fail")
    end
    outcome.not_nil!.should contain("failed while writing")
    notes = sink.rows.map(&.[2]).select(&.starts_with?(WS::NOTICE_PREFIX))
    notes.none?(&.includes?("gori closed this socket")).should be_true
    # Crystal's IOCP read path returns an RST as end of stream, so a Windows relay sees a FIN
    # there and, correctly for what it can see, writes no reset row at all.
    {% unless flag?(:win32) %}
      notes.any?(&.includes?("the client ended this WebSocket with a transport-level RESET")).should be_true
    {% end %}
  end

  it "bounds a teardown write queued behind a parked one" do
    server = TCPServer.new("127.0.0.1", 0)
    peer = TCPSocket.new("127.0.0.1", server.local_address.port)
    sock = server.accept
    begin
      leg = WS::Leg.new("in", sock, mask: false)
      # Chunks, not one big write: Windows completes a single send of any size into the kernel
      # and parks only a later one, so keep writing until one parks (the peer never reads).
      spawn { loop { leg.write(Bytes.new(64 * 1024)) } rescue nil }
      sleep 50.milliseconds
      leg.teardown!(100.milliseconds)
      expect_raises(IO::TimeoutError) { leg.write("late".to_slice) }
    ensure
      sock.close rescue nil
      peer.close
      server.close
    end
  end

  # `Live.unregister` closed the legs only after teardown's yields (settle, the flush, the
  # teardown rows), and an inject in that window was written and acked into a closing socket.
  it "refuses an inject once the relay has begun tearing down" do
    sink = LiveSink.new
    cs_r, cs_w = IO.pipe
    ts_r, ts_w = IO.pipe
    ss_r, ss_w = IO.pipe
    tc_r, tc_w = IO.pipe
    during = "not reached"
    upstream = TeardownTap.new(IO::Stapled.new(ss_r, ts_w, sync_close: true)) do
      during = inject(sink, 416_i64, "in", WS::OP_TEXT, "late") || "injected"
    end
    done = Channel(Nil).new(1)
    spawn do
      WS::Relay.run(IO::Stapled.new(cs_r, tc_w, sync_close: true), upstream, 416_i64, sink,
        NoopWsRewriter.new, LIVE_CTX)
      done.send(nil)
    end
    await_live(sink, 416_i64)
    # Half a message the assembling pump withholds, so the teardown has a write to make.
    cs_w.write(masked_frame(WS::OP_TEXT, "half", fin: false))
    sleep 20.milliseconds
    ss_w.close # the origin hangs up: the relay tears down
    receive_within(done, 5, "the relay to end")
    cs_w.close rescue nil
    during.should eq(WS::Live::CLOSED)
    sink.rows.none?(&.[3]).should be_true
    {ts_r, tc_r}.each { |io| io.close rescue nil }
  end

  # A header and part of its payload went out: the next byte on that side would be read as
  # the rest of the payload, so an inject there corrupted the stream and reported success.
  it "closes a leg it could only half forward an oversized frame on" do
    src = IO::Memory.new
    src.write(Bytes[0x82, 127])
    IO::ByteFormat::BigEndian.encode(WS::MAX_FRAME + 1, src)
    src.write(Bytes.new(10)) # ... and then the peer is gone
    src.rewind
    h = WS.read_header(src).not_nil!
    leg = WS::Leg.new("in", IO::Memory.new, mask: false)
    WS::Relay.forward_oversized_frame(src, leg, h, "in", 1_i64, LiveSink.new, WS::OP_BIN,
      Bytes.new(4096)).should be_false
    leg.closed?.should be_true
    leg.inject(WS::OP_TEXT, "x".to_slice, 100.milliseconds).should eq(WS::Live::CLOSED)
  end

  it "lets a control frame in mid-message" do
    sink = LiveSink.new
    with_relay(sink, 404_i64) do |r|
      r.cs_w.write(masked_frame(WS::OP_TEXT, "half", fin: false))
      read_frame(r.ts_r)
      inject(sink, 404_i64, "out", WS::OP_PING, "hb", wait: 100.milliseconds).should be_nil
      ping = read_frame(r.ts_r)
      {ping.opcode, String.new(ping.payload), ping.masked?}.should eq({WS::OP_PING, "hb", true})
    end
  end

  it "tracks a passthrough fragment on the assembling pump, so a data frame waits for it" do
    sink = LiveSink.new
    with_relay(sink, 408_i64, NoopWsRewriter.new) do |r|
      r.cs_w.write(masked_frame(WS::OP_BIN, "frag", fin: false))
      read_frame(r.ts_r).fin?.should be_false
      inject(sink, 408_i64, "out", WS::OP_TEXT, "late", wait: 100.milliseconds).not_nil!.should contain("stayed mid-message")
      r.cs_w.write(masked_frame(WS::OP_CONT, "end", fin: true))
      read_frame(r.ts_r)
      inject(sink, 408_i64, "out", WS::OP_TEXT, "now").should be_nil
      String.new(read_frame(r.ts_r).payload).should eq("now")
    end
  end

  it "goes out ahead of a message Intercept is holding on the same side" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      ic.set_filter("proto:ws")
      sink = LiveSink.new
      with_relay(sink, 409_i64, nil, ic) do |r|
        r.cs_w.write(masked_frame(WS::OP_TEXT, "held"))
        200.times { break if ic.pending_count == 1; sleep 1.millisecond }
        ic.pending_count.should eq(1)
        inject(sink, 409_i64, "out", WS::OP_TEXT, "jump").should be_nil
        String.new(read_frame(r.ts_r).payload).should eq("jump")
        ic.forward(ic.pending.first.id)
        String.new(read_frame(r.ts_r).payload).should eq("held")
      end
    end
  end

  it "refuses under Sandbox against the handshake's host, before any write" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.toggle_sandbox
      sink = LiveSink.new
      with_relay(sink, 405_i64) do |_|
        inject(sink, 405_i64, "out", WS::OP_TEXT, "nope",
          outbound: Gori::Outbound.interactive(scope)).should eq(Gori::Outbound::SANDBOX_ERROR)
        sink.rows.should be_empty
      end
    end
  end

  it "refuses once the socket has closed, and forgets the relay" do
    sink = LiveSink.new
    with_relay(sink, 406_i64) { |_| }
    WS::Live.find(sink, 406_i64).should be_nil
    inject(sink, 406_i64, "out", WS::OP_TEXT, "gone").should eq(WS::Live::CLOSED)
  end

  it "keeps two projects' relays apart under the same flow id" do
    a = LiveSink.new
    b = LiveSink.new
    with_relay(a, 407_i64) do |_|
      WS::Live.find(b, 407_i64).should be_nil
      inject(b, 407_i64, "out", WS::OP_TEXT, "x").should eq(WS::Live::CLOSED)
    end
  end

  it "records an injected frame as an ordinary message on a sink that keeps no origin" do
    sink = PlainSink.new
    sink.on_ws_injected(1_i64, "out", 1, "kept".to_slice)
    sink.rows.should eq(["kept"])
  end

  it "stores an injected row with its origin, and a peer's without one" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "echo.test", port: 80, method: "GET",
        target: "/ws", http_version: "HTTP/1.1", head: UPGRADE_HEAD.to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      sink = Gori::Proxy::StoreSink.new(store)
      sink.on_ws_message(id, "out", 1, "peer".to_slice)
      sink.on_ws_injected(id, "out", 1, "mine".to_slice, WS::Shape.new(masked: true))
      rows = store.ws_messages(id)
      rows.map { |m| {String.new(m.payload), m.origin, m.injected?} }.should eq(
        [{"peer", nil, false}, {"mine", "gori", true}])
    end
  end

  it "names the h2 follow-up for an RFC 8441 handshake, and refuses a non-WebSocket flow" do
    h2 = "CONNECT /ws HTTP/2\r\n#{Gori::Proxy::H2::HeadCodec::PROTOCOL_MARKER}: websocket\r\n\r\n"
    WS::Live.flow_refusal(h2).not_nil!.should contain("HTTP/2 (RFC 8441")
    WS::Live.flow_refusal(UPGRADE_HEAD).should be_nil
    WS::Live.flow_refusal("GET / HTTP/1.1\r\nHost: a\r\n\r\n").should eq("this flow is not a WebSocket handshake")
  end
end

describe "WS::Live.apply_command (the capturing instance's drain)" do
  it "injects on its own fiber and acks the receipt" do
    with_store do |store|
      sink = LiveSink.new
      with_relay(sink, 410_i64) do |r|
        id = store.enqueue_intercept_command("t", Gori::Store::WS_INJECT_VERB, item_id: 410_i64,
          bytes: "hello".to_slice, arg: Gori::Store.ws_inject_arg("out", WS::OP_TEXT))
        cmd = store.intercept_commands_after(0_i64, 10).find(&.id.==(id)).not_nil!
        receipts = Channel(String).new(1)
        WS::Live.apply_command(store, sink, ungated_outbound, cmd) { |rcpt| receipts.send(rcpt) }.should be_true
        receive_within(receipts, 5, "the receipt").should eq("TEXT 5B client→server on flow #410")
        String.new(read_frame(r.ts_r).payload).should eq("hello")
        store.command_status(id).should eq({"injected", "TEXT 5B client→server on flow #410"})
      end
    end
  end

  # The sender stops polling `Store.ws_inject_ack_budget_ms` after enqueueing and reports the
  # inject unconfirmed; one written after that would land again on the agent's retry.
  it "refuses a command whose sender has stopped waiting, and writes nothing" do
    with_store do |store|
      sink = LiveSink.new
      with_relay(sink, 417_i64) do |r|
        id = store.enqueue_intercept_command("t", Gori::Store::WS_INJECT_VERB, item_id: 417_i64,
          bytes: "late".to_slice, arg: Gori::Store.ws_inject_arg("out", WS::OP_TEXT))
        cmd = store.intercept_commands_after(0_i64, 10).find(&.id.==(id)).not_nil!
        cmd.created_at.should be > 0
        stale = Gori::Store::CommandRow.new(cmd.id, cmd.session_token, cmd.verb, cmd.item_id,
          cmd.bytes, cmd.arg, cmd.created_at - Gori::Store.ws_inject_ack_budget_ms.to_i64 * 1000)
        WS::Live.apply_command(store, sink, ungated_outbound, stale) { |_| }.should be_true
        200.times { break unless store.command_status(id).try(&.[0]) == "pending"; sleep 5.milliseconds }
        store.command_status(id).should eq({"refused", WS::Live::EXPIRED})
        # Nothing reached the origin: the next frame it reads is one written after the refusal.
        r.cs_w.write(masked_frame(WS::OP_TEXT, "next"))
        String.new(read_frame(r.ts_r).payload).should eq("next")
        sink.rows.none?(&.[3]).should be_true
      end
    end
  end

  # The sender counts its budget on its own clock: a created_at ahead of this one (a wall clock
  # stepped back since) must not stretch the deadline past what the sender waits.
  it "never sets an inject's deadline past the sender's budget" do
    budget = Gori::Store.ws_inject_ack_budget_ms.milliseconds - WS::Live::ACK_MARGIN
    ahead = (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64 + 3_600_000_000_i64
    (WS::Live.ack_deadline(ahead) <= Time.instant + budget).should be_true
  end

  it "acks a closed socket at once, naming why" do
    with_store do |store|
      id = store.enqueue_intercept_command("t", Gori::Store::WS_INJECT_VERB, item_id: 999_i64,
        bytes: "x".to_slice, arg: Gori::Store.ws_inject_arg("in", WS::OP_TEXT))
      cmd = store.intercept_commands_after(0_i64, 10).find(&.id.==(id)).not_nil!
      WS::Live.apply_command(store, LiveSink.new, ungated_outbound, cmd) { |_| }.should be_false
      store.flush
      store.command_status(id).should eq({"refused", WS::Live::CLOSED})
    end
  end
end
