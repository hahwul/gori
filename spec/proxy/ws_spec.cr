require "../spec_helper"
require "socket"

# Builds a masked client text frame for short payloads (<126 bytes).
private def masked_frame(text : String) : Bytes
  payload = text.to_slice
  mask = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
  io = IO::Memory.new
  io.write_byte(0x81_u8)
  io.write_byte((0x80 | payload.size).to_u8)
  io.write(mask)
  payload.each_with_index { |b, i| io.write_byte(b ^ mask[i & 3]) }
  io.to_slice
end

private class IntegSink < Gori::Proxy::FlowSink
  getter ws = [] of {String, String}

  def initialize(@ws_chan : Channel(Nil))
    @next = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @next += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
    @ws << {direction, String.new(payload)}
    @ws_chan.send(nil)
  end
end

# Records WS messages; stubs the HTTP side of the sink.
private class WsSink < Gori::Proxy::FlowSink
  getter messages = [] of {String, Int32, String}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
    @messages << {direction, opcode, String.new(payload)}
  end
end

private MASKED_HI   = Bytes[0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x69, 0x6b] # masked text "hi"
private UNMASKED_YO = Bytes[0x81, 0x02, 0x79, 0x6f]                         # unmasked text "yo"

describe Gori::Proxy::WS do
  describe ".read_frame" do
    it "parses + unmasks a client (masked) text frame, preserving raw bytes" do
      frame = Gori::Proxy::WS.read_frame(IO::Memory.new(MASKED_HI)).not_nil!
      frame.fin?.should be_true
      frame.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      String.new(frame.payload).should eq("hi")
      frame.raw.should eq(MASKED_HI) # exact wire bytes for byte-faithful forwarding
    end

    it "parses an unmasked server text frame" do
      frame = Gori::Proxy::WS.read_frame(IO::Memory.new(UNMASKED_YO)).not_nil!
      String.new(frame.payload).should eq("yo")
    end

    it "returns nil on EOF" do
      Gori::Proxy::WS.read_frame(IO::Memory.new(Bytes.empty)).should be_nil
    end
  end

  describe ".encode" do
    it "builds an unmasked server text frame (short length)" do
      Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "yo".to_slice, mask: false).should eq(UNMASKED_YO)
    end

    it "round-trips a masked client frame through read_frame" do
      wire = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "hi".to_slice, mask: true)
      (wire[1] & 0x80_u8).should eq(0x80_u8) # mask bit set
      frame = Gori::Proxy::WS.read_frame(IO::Memory.new(wire)).not_nil!
      frame.fin?.should be_true
      frame.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      String.new(frame.payload).should eq("hi")
    end

    it "round-trips a 200-byte payload (extended 16-bit length)" do
      payload = Bytes.new(200) { |i| (i % 251).to_u8 }
      wire = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_BIN, payload, mask: true)
      (wire[1] & 0x7f_u8).should eq(126_u8) # 16-bit length marker
      frame = Gori::Proxy::WS.read_frame(IO::Memory.new(wire)).not_nil!
      frame.opcode.should eq(Gori::Proxy::WS::OP_BIN)
      frame.payload.should eq(payload)
    end
  end

  describe Gori::Proxy::WS::Relay do
    it "relays frames both directions byte-exact and captures messages" do
      cs_r, cs_w = IO.pipe # client → server
      ts_r, ts_w = IO.pipe # relay → server
      ss_r, ss_w = IO.pipe # server → client
      tc_r, tc_w = IO.pipe # relay → client
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(MASKED_HI); cs_w.close
      ss_w.write(UNMASKED_YO); ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink)

      fwd_server = Bytes.new(MASKED_HI.size)
      ts_r.read_fully(fwd_server)
      fwd_client = Bytes.new(UNMASKED_YO.size)
      tc_r.read_fully(fwd_client)

      fwd_server.should eq(MASKED_HI)   # client→server forwarded verbatim
      fwd_client.should eq(UNMASKED_YO) # server→client forwarded verbatim
      sink.messages.should contain({"out", 1, "hi"})
      sink.messages.should contain({"in", 1, "yo"})
    end
  end
end

describe "WebSocket through the proxy (end-to-end)" do
  it "detects the 101 upgrade, relays frames, and captures both directions" do
    # origin: respond 101, then echo one client frame back (unmasked)
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      conn = origin.accept
      Gori::Proxy::Codec::Http1.read_head(conn) # the upgrade GET
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      conn.flush
      frame = Gori::Proxy::WS.read_frame(conn).not_nil!    # client's (masked) frame
      conn.write(Bytes[0x81_u8, frame.payload.size.to_u8]) # unmasked echo
      conn.write(frame.payload)
      conn.flush
    rescue
    end

    ws_chan = Channel(Nil).new(4)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    client.flush

    resp_head = Gori::Proxy::Codec::Http1.read_head(client).not_nil!
    String.new(resp_head).should contain("101")

    client.write(masked_frame("ping"))
    client.flush
    echoed = Gori::Proxy::WS.read_frame(client).not_nil!
    String.new(echoed.payload).should eq("ping") # round-tripped through gori

    ws_chan.receive # out
    ws_chan.receive # in
    client.close
    proxy.stop

    sink.ws.should contain({"out", "ping"})
    sink.ws.should contain({"in", "ping"})
  end
end

describe "Gori::Store WebSocket messages" do
  it "persists and reads back ws messages for a flow" do
    path = File.tempname("gori-ws", ".db")
    store = Gori::Store.open(path)
    begin
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "echo.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\n\r\n".to_slice, body: nil))
      store.insert_ws_message(id, "out", 1, "hello".to_slice)
      store.insert_ws_message(id, "in", 1, "world".to_slice)

      msgs = store.ws_messages(id)
      msgs.size.should eq(2)
      msgs[0].direction.should eq("out")
      String.new(msgs[0].payload).should eq("hello")
      msgs[1].text?.should be_true
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
