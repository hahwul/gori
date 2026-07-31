require "../spec_helper"
require "socket"

# A minimal WebSocket client handshake; `extra` lands between the version and the
# User-Agent so a stripped line has neighbours on both sides to preserve.
private def handshake(extra : String) : Bytes
  ("GET /ws HTTP/1.1\r\nHost: echo.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
   "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n#{extra}" \
   "User-Agent: probe\r\n\r\n").to_slice
end

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
  getter heads = [] of String

  def initialize(@ws_chan : Channel(Nil))
    @next = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @heads << String.new(req.head)
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

# A masked client frame of any opcode, for payloads under 126 bytes.
private def masked_op_frame(opcode : UInt8, payload : Bytes, fin : Bool = true) : Bytes
  mask = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
  io = IO::Memory.new
  io.write_byte((fin ? 0x80_u8 : 0_u8) | opcode)
  io.write_byte((0x80 | payload.size).to_u8)
  io.write(mask)
  payload.each_with_index { |b, i| io.write_byte(b ^ mask[i & 3]) }
  io.to_slice
end

# A Match & Replace lens that only knows about WebSocket messages (#500 step 1); each
# direction is either nil (no rule live) or one literal find/replace pair. `to_server` is
# the "out" direction, `to_client` is "in" — `in` and `out` are Crystal keywords.
private class WsRewriter < Gori::Proxy::HeadRewriter
  def initialize(@to_server : {String, String}? = nil, @to_client : {String, String}? = nil)
  end

  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_ws_out_for_host?(host : String) : Bool
    !@to_server.nil?
  end

  def rewrites_ws_in_for_host?(host : String) : Bool
    !@to_client.nil?
  end

  def rewrite_ws_out(payload : Bytes, host : String) : Bytes
    sub(payload, @to_server)
  end

  def rewrite_ws_in(payload : Bytes, host : String) : Bytes
    sub(payload, @to_client)
  end

  # Mirrors `Rules#apply`'s contract: the SAME bytes back when nothing matched, so the
  # relay can forward the peer's original frame instead of re-framing it.
  private def sub(payload : Bytes, pair : {String, String}?) : Bytes
    return payload unless pair
    text = String.new(payload)
    return payload unless text.valid_encoding?
    out = text.gsub(pair[0], pair[1])
    out == text ? payload : out.to_slice
  end
end

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

    # --- Match & Replace over WebSocket (#500 step 1) ----------------------

    it "rewrites an out-direction message and re-frames it as ONE masked frame" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_TEXT, "hi there".to_slice)); cs_w.close
      ss_w.write(UNMASKED_YO); ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"hi", "HELLO"}), "echo.test")

      h = Gori::Proxy::WS.read_header(ts_r).not_nil!
      h.fin?.should be_true
      h.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      h.masked?.should be_true # RFC 6455 §5.3 — a re-emitted client frame gets a fresh key
      String.new(Gori::Proxy::WS.read_body(ts_r, h).not_nil!.payload).should eq("HELLO there")

      # The other direction has no rule, so it never leaves the byte-exact pump.
      fwd_client = Bytes.new(UNMASKED_YO.size)
      tc_r.read_fully(fwd_client)
      fwd_client.should eq(UNMASKED_YO)

      # Capture records what gori WROTE — the bytes the peer actually sees.
      sink.messages.should contain({"out", 1, "HELLO there"})
      sink.messages.should contain({"in", 1, "yo"})
    end

    it "rewrites the in direction and emits it UNMASKED (server→client)" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.close
      ss_w.write(UNMASKED_YO); ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_client: {"yo", "YOYO"}), "echo.test")

      h = Gori::Proxy::WS.read_header(tc_r).not_nil!
      h.masked?.should be_false # a server→client frame must never be masked
      String.new(Gori::Proxy::WS.read_body(tc_r, h).not_nil!.payload).should eq("YOYO")
      sink.messages.should contain({"in", 1, "YOYO"})
    end

    it "forwards a text message no rule matched as the peer's OWN frame, byte-exact" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(MASKED_HI); cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), "echo.test")

      fwd = Bytes.new(MASKED_HI.size)
      ts_r.read_fully(fwd)
      fwd.should eq(MASKED_HI) # same mask key, same framing — not re-encoded
      sink.messages.should contain({"out", 1, "hi"})
    end

    it "never rewrites a BINARY message — a text find/replace over binary is corruption" do
      bin = masked_op_frame(Gori::Proxy::WS::OP_BIN, "hi there".to_slice)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(bin); cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"hi", "HELLO"}), "echo.test")

      fwd = Bytes.new(bin.size)
      ts_r.read_fully(fwd)
      fwd.should eq(bin) # byte-exact: opcode 2 stays on the streaming path whole
      sink.messages.should contain({"out", 2, "hi there"})
    end

    it "assembles a fragmented text message to FIN and emits the rewrite as one frame" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_TEXT, "hi ".to_slice, fin: false))
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_CONT, "there".to_slice))
      cs_w.close
      ss_w.close

      sink = WsSink.new
      # The pattern spans the fragment boundary, so it can only match on the assembled
      # message — which is what makes this an assembly test rather than a rewrite test.
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"hi there", "bye"}), "echo.test")

      h = Gori::Proxy::WS.read_header(ts_r).not_nil!
      h.fin?.should be_true
      h.opcode.should eq(Gori::Proxy::WS::OP_TEXT) # one frame, not two
      String.new(Gori::Proxy::WS.read_body(ts_r, h).not_nil!.payload).should eq("bye")
      sink.messages.should contain({"out", 1, "bye"})
    end

    it "forwards a PING past an assembling message instead of parking it behind the FIN" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      # RFC 6455 §5.4 lets a control frame land inside a fragmented message. Parking it
      # behind the assembly is how a server's 20-30 s ping timer closes the socket while
      # the rewrite is still buffering.
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_TEXT, "hi ".to_slice, fin: false))
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_PING, Bytes.empty))
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_CONT, "there".to_slice))
      cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"hi there", "bye"}), "echo.test")

      first = Gori::Proxy::WS.read_header(ts_r).not_nil!
      first.opcode.should eq(Gori::Proxy::WS::OP_PING) # ahead of the message it arrived inside
      Gori::Proxy::WS.read_body(ts_r, first).not_nil!
      second = Gori::Proxy::WS.read_header(ts_r).not_nil!
      second.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      String.new(Gori::Proxy::WS.read_body(ts_r, second).not_nil!.payload).should eq("bye")
    end

    it "puts a never-FINished message on the wire rather than losing it to the next one" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      # RFC 6455 §5.4 violation: a new data message while the previous one is unfinished.
      # The byte-exact pump has already forwarded those bytes; this pump is withholding
      # them, so they have to go out here instead of being overwritten.
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_TEXT, "orphan".to_slice, fin: false))
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_TEXT, "second".to_slice))
      cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"second", "SECOND"}), "echo.test")

      first = Gori::Proxy::WS.read_header(ts_r).not_nil!
      first.fin?.should be_false # gori does not invent the FIN the sender never sent
      String.new(Gori::Proxy::WS.read_body(ts_r, first).not_nil!.payload).should eq("orphan")
      second = Gori::Proxy::WS.read_header(ts_r).not_nil!
      String.new(Gori::Proxy::WS.read_body(ts_r, second).not_nil!.payload).should eq("SECOND")
      sink.messages.should contain({"out", 1, "orphan"})
      sink.messages.should contain({"out", 1, "SECOND"})
    end

    it "waits for the peer's replying CLOSE frame instead of tearing the tunnel down the instant one side forwards one (RFC 6455 closing handshake)" do
      cs_r, cs_w = IO.pipe # client → server
      ts_r, ts_w = IO.pipe # relay → server
      ss_r, ss_w = IO.pipe # server → client
      tc_r, tc_w = IO.pipe # relay → client
      # sync_close: true so `run`'s internal `client.close`/`upstream.close` propagate to the
      # real underlying pipe fds (as they do for the real sockets `run` is normally handed) —
      # without it, the OLD code's early close only flips IO::Stapled's own closed flag and
      # this spec hangs (tc_r never sees EOF) instead of failing fast.
      client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
      upstream = IO::Stapled.new(ss_r, ts_w, sync_close: true)

      client_close = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CLOSE, "bye".to_slice, mask: true)
      server_close = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CLOSE, "bye".to_slice, mask: false)

      # The client sends its CLOSE and has nothing more to say — like a real client, it
      # doesn't hold the connection open waiting on its own reply.
      cs_w.write(client_close)
      cs_w.close

      # Stands in for the real peer: reads the forwarded CLOSE, then deliberately waits a
      # beat (standing in for the real network round trip a genuine reply needs) before
      # replying. Without the fix, `run` tears down BOTH sockets the instant the
      # client→upstream pump forwards the CLOSE and returns — a near-instant local op, long
      # before this reply is sent — dropping it exactly like the real bug (client saw "EOF
      # while reading 2, got 0" instead of the peer's closing-handshake reply).
      spawn do
        got = Bytes.new(client_close.size)
        ts_r.read_fully(got)
        sleep 0.05.seconds
        ss_w.write(server_close)
        ss_w.close
      rescue
        # broken pipe: the old bug already closed our write end before we got here
      end

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 13_i64, sink)

      # read_fully raises on short read/EOF — the old, buggy behavior (reply dropped, tc_r
      # closes with 0 bytes available).
      forwarded_reply = Bytes.new(server_close.size)
      tc_r.read_fully(forwarded_reply)
      forwarded_reply.should eq(server_close)
    end
  end
end

describe Gori::Proxy::WS::Handshake do
  describe ".offers_extensions?" do
    it "is true for a WebSocket upgrade carrying the header" do
      req = Gori::Proxy::Codec::Http1.parse_request_head(
        handshake("Sec-WebSocket-Extensions: permessage-deflate\r\n"))
      Gori::Proxy::WS::Handshake.offers_extensions?(req.headers).should be_true
    end

    it "matches the field-name and the upgrade token case-insensitively" do
      req = Gori::Proxy::Codec::Http1.parse_request_head(
        ("GET /ws HTTP/1.1\r\nUpgrade: WebSocket\r\n" \
         "SEC-WEBSOCKET-EXTENSIONS: permessage-deflate\r\n\r\n").to_slice)
      Gori::Proxy::WS::Handshake.offers_extensions?(req.headers).should be_true
    end

    it "reads Upgrade as a protocol LIST, not one value" do
      # RFC 7230 §6.7: `Upgrade: websocket, h2c` is still a WebSocket handshake, and a
      # whole-value compare would miss it and leave the offer in place.
      req = Gori::Proxy::Codec::Http1.parse_request_head(
        ("GET /ws HTTP/1.1\r\nUpgrade: h2c, websocket\r\n" \
         "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n").to_slice)
      Gori::Proxy::WS::Handshake.offers_extensions?(req.headers).should be_true
    end

    it "is false without the header" do
      req = Gori::Proxy::Codec::Http1.parse_request_head(handshake(""))
      Gori::Proxy::WS::Handshake.offers_extensions?(req.headers).should be_false
    end

    it "is false when the request is not a WebSocket upgrade" do
      # The field is defined only for the handshake, so on an ordinary request it is inert
      # and the head stays byte-exact (P7) rather than being rewritten for nothing.
      req = Gori::Proxy::Codec::Http1.parse_request_head(
        ("GET /p HTTP/1.1\r\nHost: echo.test\r\n" \
         "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n").to_slice)
      Gori::Proxy::WS::Handshake.offers_extensions?(req.headers).should be_false
    end
  end

  describe ".strip_extensions" do
    it "removes the offer and leaves every other byte alone" do
      stripped = Gori::Proxy::WS::Handshake.strip_extensions(
        handshake("Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"))
      stripped.should eq(handshake(""))
    end

    it "removes EVERY extension line (RFC 6455 allows the offer split across fields)" do
      stripped = Gori::Proxy::WS::Handshake.strip_extensions(
        handshake("Sec-WebSocket-Extensions: permessage-deflate\r\n" \
                  "sec-websocket-extensions: x-webkit-deflate-frame\r\n"))
      stripped.should eq(handshake(""))
    end

    it "is a byte-exact no-op when there is no extension line" do
      Gori::Proxy::WS::Handshake.strip_extensions(handshake("")).should eq(handshake(""))
    end

    it "keeps a header whose name only STARTS with the stripped name" do
      extra = "Sec-WebSocket-Extensions-Note: keep\r\n"
      Gori::Proxy::WS::Handshake.strip_extensions(handshake(extra)).should eq(handshake(extra))
    end

    it "never drops the start-line, even one shaped like the stripped header" do
      raw = "sec-websocket-extensions: permessage-deflate\r\nUpgrade: websocket\r\n\r\n"
      Gori::Proxy::WS::Handshake.strip_extensions(raw.to_slice).should eq(raw.to_slice)
    end

    it "copies non-UTF-8 header VALUE bytes verbatim" do
      # A cookie/auth token carrying raw high bytes must survive the rebuild byte-exact —
      # the strip walks bytes and never round-trips a value through String.
      io = IO::Memory.new
      io << "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nCookie: sid="
      io.write(Bytes[0xFF, 0xFE, 0x80])
      io << "\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
      want = IO::Memory.new
      want << "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nCookie: sid="
      want.write(Bytes[0xFF, 0xFE, 0x80])
      want << "\r\n\r\n"
      Gori::Proxy::WS::Handshake.strip_extensions(io.to_slice).should eq(want.to_slice)
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

  it "strips the client's permessage-deflate offer from the handshake it relays (#518)" do
    # Without the strip the origin accepts the extension, both peers compress, and every
    # frame WS::Relay captures is a deflate stream stored as if it were the message. The
    # offer is the side that gets cut: negotiation is offer-driven, so an origin with
    # nothing to accept leaves the socket uncompressed.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    seen = Channel(String).new(1)
    spawn do
      conn = origin.accept
      head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
      seen.send(String.new(head))
      # Answer as a conformant origin would with nothing offered: no acceptance.
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      conn.flush
      frame = Gori::Proxy::WS.read_frame(conn).not_nil!
      conn.write(Bytes[0x81_u8, frame.payload.size.to_u8])
      conn.write(frame.payload)
      conn.flush
    rescue
    end

    ws_chan = Channel(Nil).new(4)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n" \
              "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n" \
              "User-Agent: probe\r\n\r\n"
    client.flush

    origin_head = seen.receive
    origin_head.downcase.should_not contain("sec-websocket-extensions")
    origin_head.should contain("Sec-WebSocket-Key: dGhlIHNhbXBsZQ==") # everything else survives
    origin_head.should contain("User-Agent: probe")

    resp_head = Gori::Proxy::Codec::Http1.read_head(client).not_nil!
    String.new(resp_head).should contain("101")

    client.write(masked_frame("hello"))
    client.flush
    Gori::Proxy::WS.read_frame(client).not_nil!
    ws_chan.receive # out
    ws_chan.receive # in
    client.close
    proxy.stop

    # The RECORDED request is the handshake gori sent, not the client's offer: an offer
    # captured beside a 101 with no acceptance would read as "the origin declined".
    sink.heads.size.should eq(1)
    sink.heads[0].downcase.should_not contain("sec-websocket-extensions")
    sink.ws.should contain({"out", "hello"})
  end

  it "leaves the header alone on a request that is not upgrading" do
    # The field is defined only for the handshake, so on an ordinary request it is inert
    # and gori has no reason to spend a byte change on it (P7).
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    seen = Channel(String).new(1)
    spawn do
      conn = origin.accept
      seen.send(String.new(Gori::Proxy::Codec::Http1.read_head(conn).not_nil!))
      conn << "HTTP/1.1 204 No Content\r\n\r\n"
      conn.flush
    rescue
    end

    sink = IntegSink.new(Channel(Nil).new(1))
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /p HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
    client.flush

    seen.receive.should contain("Sec-WebSocket-Extensions: permessage-deflate")
    Gori::Proxy::Codec::Http1.read_head(client)
    client.close
    proxy.stop
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
    # read_fully, not read: the origin answers with TWO writes ("SRV:" then the echo), and
    # nothing guarantees they land in one segment. macOS usually coalesces them, Linux
    # reliably does not — a single read there returns just "SRV:". The 3s read_timeout above
    # still makes a genuinely broken tunnel fail fast rather than hang.
    buf = Bytes.new("SRV:PING".bytesize)
    client.read_fully(buf)
    String.new(buf).should eq("SRV:PING")

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
