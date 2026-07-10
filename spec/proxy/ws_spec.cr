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

    it "returns nil for an oversized advertised length (buffered form)" do
      # 127 length header advertising > MAX_FRAME, unmasked. read_frame must refuse
      # to buffer it (the relay streams it instead).
      hdr = IO::Memory.new
      hdr.write_byte(0x82_u8)
      hdr.write_byte(0x7f_u8)
      len = (Gori::Proxy::WS::MAX_FRAME + 1)
      (0..7).each { |i| hdr.write_byte((len >> (56 - i * 8)).to_u8!) }
      Gori::Proxy::WS.read_frame(IO::Memory.new(hdr.to_slice)).should be_nil
    end
  end

  describe ".unmask" do
    it "is byte-identical to the scalar RFC 6455 mask across every length + offset (word-XOR)" do
      key = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
      # Cover 0..40 so every tail remainder (n % 4 ∈ 0,1,2,3) and multi-word bodies run.
      (0..40).each do |n|
        src = Bytes.new(n) { |i| ((i * 37 + 11) & 0xff).to_u8 }
        want = Bytes.new(n) { |i| src[i] ^ key[i & 3] } # scalar reference
        got = Bytes.new(n)
        Gori::Proxy::WS.unmask(src, key, got)
        got.should eq(want)
      end
    end

    it "round-trips: unmask(mask(x)) == x for a non-word-aligned length" do
      key = Bytes[0x01, 0x7f, 0x80, 0xFE]
      x = "the quick brown fox — 27 bytes!".to_slice # 31 bytes (tail = 3)
      masked = Bytes.new(x.size) { |i| x[i] ^ key[i & 3] }
      back = Bytes.new(x.size)
      Gori::Proxy::WS.unmask(masked, key, back)
      back.should eq(x)
    end
  end

  describe ".read_header" do
    it "parses a masked header exposing len and mask key without the payload" do
      h = Gori::Proxy::WS.read_header(IO::Memory.new(MASKED_HI)).not_nil!
      h.fin?.should be_true
      h.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      h.masked?.should be_true
      h.len.should eq(2)
      h.mask_key.should eq(Bytes[0x01, 0x02, 0x03, 0x04])
    end
  end

  describe ".stream_payload" do
    it "copies exactly len bytes byte-exact and reports completion" do
      src = IO::Memory.new(Bytes.new(1000) { |i| (i % 256).to_u8 })
      dst = IO::Memory.new
      Gori::Proxy::WS.stream_payload(src, dst, 1000_u64, Bytes.new(64)).should be_true
      dst.to_slice.should eq(Bytes.new(1000) { |i| (i % 256).to_u8 })
    end

    it "returns false if the source dies mid-payload (truncated frame)" do
      src = IO::Memory.new(Bytes.new(10, 0x41_u8)) # only 10 bytes available
      dst = IO::Memory.new
      Gori::Proxy::WS.stream_payload(src, dst, 100_u64, Bytes.new(64)).should be_false
      dst.to_slice.size.should eq(10) # forwarded what arrived, byte-exact
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

    it "streams a frame larger than MAX_FRAME byte-exact instead of killing the tunnel" do
      big = Gori::Proxy::WS::MAX_FRAME.to_i + 16
      # Unmasked server binary frame: FIN|OP_BIN, 127 length, 8-byte big-endian length.
      hdr = IO::Memory.new
      hdr.write_byte(0x82_u8)
      hdr.write_byte(0x7f_u8)
      len = big.to_u64
      (0..7).each { |i| hdr.write_byte((len >> (56 - i * 8)).to_u8!) }
      header = hdr.to_slice
      payload = Bytes.new(big, 0x41_u8) # 'A' * big

      # Real (evented) socket pairs, not IO.pipe: kernel buffering + truly
      # independent directions, so a 16 MiB stream doesn't deadlock the fibers.
      client_side, relay_client = UNIXSocket.pair
      origin_side, relay_upstream = UNIXSocket.pair

      # Drain forwarded-to-client bytes concurrently (the ~16 MiB write would block).
      # The relay closes its end when both pumps finish, so the read sees EOF then.
      forwarded = IO::Memory.new
      drain = Channel(Nil).new
      spawn do
        buf = Bytes.new(64 * 1024)
        while (n = client_side.read(buf)) > 0
          forwarded.write(buf[0, n])
        end
      rescue IO::Error
        # relay closed its end — end of the forwarded stream
      ensure
        drain.send(nil)
      end
      # Origin sends the oversized frame, then a normal "yo" frame, then EOF.
      spawn do
        origin_side.write(header)
        origin_side.write(payload)
        origin_side.write(UNMASKED_YO)
        origin_side.close
      end

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(relay_client, relay_upstream, 9_i64, sink)
      drain.receive
      client_side.close rescue nil

      fwd = forwarded.to_slice
      # Both frames forwarded whole and byte-exact (was: 0 bytes, tunnel killed).
      fwd.size.should eq(header.size + big + UNMASKED_YO.size)
      fwd[0, header.size].should eq(header)
      fwd[header.size].should eq(0x41_u8)
      fwd[header.size + big - 1].should eq(0x41_u8)
      fwd[(header.size + big), UNMASKED_YO.size].should eq(UNMASKED_YO)
      # The oversized frame is surfaced as a marker (not silently dropped); the
      # normal frame still captures.
      sink.messages.any? { |(_, _, s)| s.includes?("too large to capture") }.should be_true
      sink.messages.should contain({"in", 1, "yo"})
    end

    it "preserves a small leading fragment when a LATER fragment is oversized (was dropped)" do
      big = Gori::Proxy::WS::MAX_FRAME.to_i + 16
      f1 = Bytes[0x01_u8, 0x03_u8, 0x61_u8, 0x62_u8, 0x63_u8] # OP_TEXT, no FIN, len 3, "abc"
      hdr = IO::Memory.new
      hdr.write_byte(0x80_u8) # FIN | OP_CONT(0x0)
      hdr.write_byte(0x7f_u8)
      len = big.to_u64
      (0..7).each { |i| hdr.write_byte((len >> (56 - i * 8)).to_u8!) }
      f2_hdr = hdr.to_slice
      payload = Bytes.new(big, 0x41_u8)

      client_side, relay_client = UNIXSocket.pair
      origin_side, relay_upstream = UNIXSocket.pair

      drain = Channel(Nil).new
      spawn do
        buf = Bytes.new(64 * 1024)
        while (n = client_side.read(buf)) > 0
        end
      rescue IO::Error
      ensure
        drain.send(nil)
      end
      spawn do
        origin_side.write(f1)
        origin_side.write(f2_hdr)
        origin_side.write(payload)
        origin_side.close
      end

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(relay_client, relay_upstream, 11_i64, sink)
      drain.receive
      client_side.close rescue nil

      # The leading "abc" fragment reaches the sink (not silently discarded because the
      # message's final fragment turned out to be oversized), plus the oversized marker.
      sink.messages.should contain({"in", 1, "abc"})
      sink.messages.any? { |(_, _, s)| s.includes?("too large to capture") }.should be_true
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

  it "blind-tunnels a NON-WebSocket 101 upgrade instead of parsing the post-upgrade bytes as HTTP (desync)" do
    # origin: accept the upgrade, answer 101 with a non-websocket Upgrade, then speak a
    # raw post-upgrade protocol (read the client's bytes, answer with SRV:<echo>).
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      conn = origin.accept
      Gori::Proxy::Codec::Http1.read_head(conn) # the upgrade GET
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: raftproto\r\nConnection: Upgrade\r\n\r\n"
      conn.flush
      buf = Bytes.new(64)
      n = conn.read(buf)
      conn.write("SRV:".to_slice)
      conn.write(buf[0, n])
      conn.flush
    rescue
    end

    ws_chan = Channel(Nil).new(4)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 3.seconds # a broken tunnel must fail fast, not hang the suite
    client << "GET /up HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: raftproto\r\nConnection: Upgrade\r\n\r\n"
    client.flush

    resp_head = Gori::Proxy::Codec::Http1.read_head(client).not_nil!
    String.new(resp_head).should contain("101")

    # Post-upgrade raw bytes must flow both ways THROUGH the tunnel. Without the fix the
    # proxy kept the connection HTTP keep-alive and read "PING" as the next request head,
    # so it never reached the origin and no SRV:PING ever came back.
    client.write("PING".to_slice)
    client.flush
    buf = Bytes.new(64)
    n = client.read(buf)
    String.new(buf[0, n]).should eq("SRV:PING")

    client.close
    proxy.stop
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
