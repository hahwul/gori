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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @messages << {direction, opcode, String.new(payload)}
  end
end

# Wait for `n` captured WS rows, BOUNDED: a row that never arrives has to fail the example
# rather than park the suite on a channel nobody will send to.
private def expect_ws_rows(chan : Channel(Nil), n : Int32) : Nil
  n.times do
    select
    when chan.receive
      # got one
    when timeout(3.seconds)
      fail "timed out waiting for a captured ws_messages row"
    end
  end
end

private MASKED_HI   = Bytes[0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x69, 0x6b] # masked text "hi"
private UNMASKED_YO = Bytes[0x81, 0x02, 0x79, 0x6f]                         # unmasked text "yo"

# The 101 handshake identity every rewrite/hold in this file scopes on.
private WS_CTX = Gori::Proxy::WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

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
    # `capture_frame` only emits a message on FIN, so the default (byte-exact) pump had no
    # per-message boundary of its own: a second data message arriving before the first FIN'd
    # was concatenated into the first, and an unterminated fragment at teardown was dropped
    # entirely. `AssemblingPump` was given both (`start_message` / its `run` ensure) and the
    # oversized branch has the first, so the two pumps disagreed about identical bytes —
    # which this file already treats as a bug for the oversized case. Capture only; the wire
    # is byte-exact either way, and both examples assert that too.
    it "does not merge a second data message into one that never sent its FIN" do
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)
      cs_w.close # the client sends nothing; EOF so that direction's pump ends

      frames = Bytes[0x01, 0x03, 0x41, 0x41, 0x41] + # TEXT fin=0 "AAA" — §5.4 violation follows
               Bytes[0x81, 0x03, 0x42, 0x42, 0x42]   # TEXT fin=1 "BBB"
      ss_w.write(frames); ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink)

      relayed = Bytes.new(frames.size)
      tc_r.read_fully(relayed)
      relayed.should eq(frames) # the wire keeps the peer's own framing (P7)
      sink.messages.should eq([{"in", 1, "AAA"}, {"in", 1, "BBB"}])
      _ = ts_r
    end

    it "captures an unterminated fragment left when the direction ends" do
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)
      cs_w.close # the client sends nothing; EOF so that direction's pump ends

      frames = Bytes[0x81, 0x06, 0x4D, 0x41, 0x52, 0x4B, 0x45, 0x52] + # TEXT fin=1 "MARKER"
               Bytes[0x01, 0x06, 0x55, 0x4E, 0x54, 0x45, 0x52, 0x4D]   # TEXT fin=0 "UNTERM", no FIN
      ss_w.write(frames); ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink)

      relayed = Bytes.new(frames.size)
      tc_r.read_fully(relayed)
      relayed.should eq(frames) # gori put all 16 bytes on the wire...
      # ...so History must not be missing the 6 it relayed itself.
      sink.messages.should eq([{"in", 1, "MARKER"}, {"in", 1, "UNTERM"}])
      _ = ts_r
    end

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
      receive_within(drain)
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
      receive_within(drain)
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
        WsRewriter.new(to_server: {"hi", "HELLO"}), WS_CTX)

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
        WsRewriter.new(to_client: {"yo", "YOYO"}), WS_CTX)

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
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      fwd = Bytes.new(MASKED_HI.size)
      ts_r.read_fully(fwd)
      fwd.should eq(MASKED_HI) # same mask key, same framing — not re-encoded
      sink.messages.should contain({"out", 1, "hi"})
    end

    it "forwards a FRAGMENTED message no rule matched as the peer's own frames, byte-exact" do
      # The single-frame case above was already byte-exact; a multi-frame one was not.
      # With any `part: ws` rule live, both fragments were buffered and re-emitted as ONE
      # frame under a mask key gori invented — for a message the rule never matched.
      # Fragmentation IS the payload for per-frame length checks and WAF/IDS bypass tests.
      first = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "nomatch-".to_slice, fin: false)
      second = masked_op_frame(Gori::Proxy::WS::OP_CONT, "tail".to_slice)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(first); cs_w.write(second); cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      ts_w.close                                          # the relay is done writing; read the whole forwarded stream
      ts_r.gets_to_end.to_slice.should eq(first + second) # two frames, FIN bits and mask keys intact
      sink.messages.should contain({"out", 1, "nomatch-tail"})
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
        WsRewriter.new(to_server: {"hi", "HELLO"}), WS_CTX)

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
        WsRewriter.new(to_server: {"hi there", "bye"}), WS_CTX)

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
        WsRewriter.new(to_server: {"hi there", "bye"}), WS_CTX)

      first = Gori::Proxy::WS.read_header(ts_r).not_nil!
      first.opcode.should eq(Gori::Proxy::WS::OP_PING) # ahead of the message it arrived inside
      Gori::Proxy::WS.read_body(ts_r, first).not_nil!
      second = Gori::Proxy::WS.read_header(ts_r).not_nil!
      second.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      String.new(Gori::Proxy::WS.read_body(ts_r, second).not_nil!.payload).should eq("bye")
    end

    # ... but a message NOTHING changed must keep the interleave, because the interleave is
    # the test. `TEXT fin=0 "AAA"` / `PING` / `CONT fin=1 "BBB"` asks whether the peer accepts
    # a control frame between fragments (RFC 6455 §5.4). Arming ANY `part: ws` rule — even one
    # scoped to a pattern that never matches — used to hoist the PING to the front, so gori
    # answered the question before the peer could. The bytes were all there; the sequence,
    # which is the whole finding, was not.
    it "keeps a PING exactly where it arrived inside a message no rule matched" do
      first = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false)
      ping = masked_op_frame(Gori::Proxy::WS::OP_PING, "pi".to_slice)
      second = masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(first); cs_w.write(ping); cs_w.write(second); cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      ts_w.close
      # Byte-for-byte what the client wrote, in the order it wrote it — which is also exactly
      # what the byte-exact pump (no rule armed) puts on this socket.
      ts_r.gets_to_end.to_slice.should eq(first + ping + second)
      sink.messages.should eq([{"out", 9, "pi"}, {"out", 1, "AAABBB"}])
    end

    it "keeps a server PONG where it arrived on the in direction too" do
      lead = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, mask: false, fin: false)
      pong = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_PONG, "p".to_slice, mask: false)
      tail = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CONT, "BBB".to_slice, mask: false)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.close
      ss_w.write(lead); ss_w.write(pong); ss_w.write(tail); ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_client: {"absent", "x"}), WS_CTX)

      tc_w.close
      tc_r.gets_to_end.to_slice.should eq(lead + pong + tail)
      _ = ts_r
    end

    # The other side of the same rule: once gori is re-framing the message, the sender's
    # fragmentation is gone and there is no position left to hold the control frame at — so it
    # goes out AHEAD, which is what keeps the peer's ping timer answered. Both dispositions in
    # one place, because the boundary between them is the whole design.
    # The parking ceiling (`MAX_PARKED_CONTROLS`) is a REORDER gori performs on the wire, and
    # until now it told only `gori.log` — "which reaches only an operator who knew to tail it",
    # the exact argument #518 used to move the `Sec-WebSocket-Extensions` advisory onto the
    # flow's own `ws_messages` stream. Control rows are recorded at ARRIVAL and message rows at
    # EMIT, so with the interleave preserved and with it given up the capture reads identically
    # — History, `gori run show`, MCP `get_flow` and an export could not tell the two apart.
    # Both sides of the ceiling are asserted here, because that is the only thing that makes
    # the marker mean anything.
    it "records the parking-ceiling reorder as a [gori] row, above the ceiling only" do
      lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false)
      tail = masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice)
      pings = (0...9).map do |i|
        masked_op_frame(Gori::Proxy::WS::OP_PING, Bytes[0x70_u8, (0x30 + i).to_u8])
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

      sink = WsSink.new
      # A rule that matches nothing: the message itself is still forwarded as the peer's own
      # frames, so the ONLY thing gori changed about this socket is where the PINGs sit.
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      ts_w.close
      # The documented hoist: the ninth PING trips the ceiling, everything parked goes out
      # ahead of the fragments, and the message follows byte-exact.
      ts_r.gets_to_end.to_slice.should eq(pings.reduce(Bytes.empty) { |a, p| a + p } + lead + tail)

      notices = sink.messages.select { |(_, _, text)| text.starts_with?("[gori] ") }
      notices.size.should eq(1) # once per direction per socket, like the warn
      # NOT "out", which is what a WebSocket repeater seed reads: a diagnostic is not traffic.
      # See the seed-leak example below and `Relay::NOTICE_DIRECTION`.
      notices.first[0].should eq("in")
      notices.first[2].should contain("more than 8 control frames arrived between the fragments")
      # The row's column no longer says which side it is about, so the SENTENCE has to — or a
      # notice about the client's own frames reads as something the origin did.
      notices.first[2].should contain("client→server")
      # Its POSITION is what names the message: right where gori gave up, after the eight it
      # had parked and before the one that broke the ceiling.
      sink.messages.index(notices.first).should eq(8)
      sink.messages.last.should eq({"out", 1, "AAABBB"})
      _ = tc_r
    end

    # F1, the regression the row above introduced. A `ws_messages` row on the OUT direction is
    # not only a record — it is what `run repeater create --flow`, MCP `create_repeater` and
    # the TUI seed a WebSocket repeater session from, opcode and bytes straight across. Writing
    # the advisory on the pump's own direction therefore put gori's own 242-byte sentence into
    # the operator's test case as a masked client→server TEXT frame the client never sent, and
    # made `run repeater send` report one more message than the client had frames. Round 3
    # built this row on the `Sec-WebSocket-Extensions` advisory's precedent, and that one is
    # safe for exactly one reason: it is `direction: "in"`, and seeding takes `out`.
    #
    # Asserted as the SEED sees it — every out row, in order — rather than by fishing the
    # notice out, because "the seed is the client's frames and nothing else" is the property.
    it "leaves no [gori] row on the direction a WebSocket repeater seeds from" do
      lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false)
      tail = masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice)
      pings = (0...9).map do |i|
        masked_op_frame(Gori::Proxy::WS::OP_PING, Bytes[0x70_u8, (0x30 + i).to_u8])
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

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      seed = sink.messages.select { |(dir, _, _)| dir == "out" }
      seed.size.should eq(10) # the client sent ten frames; the seed is ten messages
      seed.each { |(_, _, text)| text.starts_with?("[gori] ").should be_false }
      seed.last.should eq({"out", 1, "AAABBB"})
      # ... and the advisory is still recorded, just not where it can be replayed.
      sink.messages.count { |(_, _, text)| text.starts_with?("[gori] ") }.should eq(1)
      ts_w.close
      _ = {ts_r, tc_r}
    end

    # The complement, one frame BELOW the ceiling: eight parked controls still ride out inside
    # the message at the offsets they arrived at, and nothing claims a reorder that did not
    # happen. A marker that fires on both sides of a boundary carries no information.
    it "keeps the interleave and writes no [gori] row one frame below the parking ceiling" do
      lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false)
      tail = masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice)
      pings = (0...8).map do |i|
        masked_op_frame(Gori::Proxy::WS::OP_PING, Bytes[0x70_u8, (0x30 + i).to_u8])
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

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      ts_w.close
      ts_r.gets_to_end.to_slice
        .should eq(lead + pings.reduce(Bytes.empty) { |a, p| a + p } + tail)
      sink.messages.count { |(_, _, text)| text.starts_with?("[gori] ") }.should eq(0)
      sink.messages.last.should eq({"out", 1, "AAABBB"})
      _ = tc_r
    end

    # The same "a parked control frame must never be silently dropped" rule, at the other
    # place it was broken: a LEADING FRAGMENT MAY BE EMPTY. `TEXT fin=0 ""` puts bytes in the
    # raw accumulator and none in the payload buffer, so a PING parked inside that message sat
    # in a message `start_message`'s `@buffer.size > 0` test called "not there" — and the
    # `reset_raw` right after it discarded the PING with no wire write and no way to tell.
    # `MessageShape#frames`' own comment names this hazard ("the payload buffer cannot answer
    # it, because a leading fragment may be empty").
    it "does not swallow a control frame parked inside a message whose leading fragment is empty" do
      lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, Bytes.empty, fin: false)
      ping = masked_op_frame(Gori::Proxy::WS::OP_PING, "pi".to_slice)
      # A new data message while the previous one never FIN'd (RFC 6455 §5.4) — the exit that
      # dropped it.
      second = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "second".to_slice)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(lead); cs_w.write(ping); cs_w.write(second); cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      ts_w.close
      # The PING and the empty fragment it was parked inside BOTH reach the origin, in arrival
      # order. Round 3 fixed half of this: the PING was never written at all, and then the
      # fragment that carried it still was not — `flush_withheld` owed nothing while the
      # payload buffer was empty and `reset_raw` dropped the frame's own wire bytes. The
      # byte-exact pump forwards it (asserted below), and "a rule that matches nothing leaves
      # the socket byte-exact" is the invariant this whole pump exists to keep.
      ts_r.gets_to_end.to_slice.should eq(lead + ping + second)
      _ = tc_r
    end

    # The same wire, with no rule armed at all. Written as a pair on purpose: the finding is
    # not "gori drops an empty fragment", it is "gori drops it only where a rule is live", and
    # only the two together say that.
    it "forwards an empty leading fragment identically with and without a rule armed" do
      lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, Bytes.empty, fin: false)
      ping = masked_op_frame(Gori::Proxy::WS::OP_PING, "pi".to_slice)
      # The message never FINs — the socket just ends. A message that DOES complete was never
      # affected (`emit_message` puts `@raw` back on the wire whole), which is why three rounds
      # of fragmentation tests walked past this.
      wire = lead + ping

      relayed = ->(rewriter : Gori::Proxy::HeadRewriter?) do
        cs_r, cs_w = IO.pipe
        ts_r, ts_w = IO.pipe
        ss_r, ss_w = IO.pipe
        tc_r, tc_w = IO.pipe
        cs_w.write(wire); cs_w.close
        ss_w.close
        sink = WsSink.new
        Gori::Proxy::WS::Relay.run(IO::Stapled.new(cs_r, tc_w), IO::Stapled.new(ss_r, ts_w),
          7_i64, sink, rewriter, WS_CTX)
        ts_w.close
        _ = tc_r
        {ts_r.gets_to_end.to_slice, sink.messages}
      end

      armed_bytes, armed_rows = relayed.call(WsRewriter.new(to_server: {"absent", "x"}))
      plain_bytes, plain_rows = relayed.call(nil)
      plain_bytes.should eq(wire) # the byte-exact pump has always done this
      armed_bytes.should eq(plain_bytes)
      # ... and the two pumps have to agree about the rows as well: the PING's arrival, and no
      # row of its own for a zero-byte fragment.
      armed_rows.should eq(plain_rows)
      armed_rows.should eq([{"out", 9, "pi"}])
    end

    # The complement of "empty": one byte of payload in the leading fragment took the branch
    # that always worked, which is why the defect survived three rounds of fragmentation tests.
    it "forwards a NON-empty leading fragment and its parked PING unchanged" do
      lead = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "X".to_slice, fin: false)
      ping = masked_op_frame(Gori::Proxy::WS::OP_PING, "pi".to_slice)
      second = masked_op_frame(Gori::Proxy::WS::OP_TEXT, "second".to_slice)
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe

      cs_w.write(lead); cs_w.write(ping); cs_w.write(second); cs_w.close
      ss_w.close

      sink = WsSink.new
      Gori::Proxy::WS::Relay.run(IO::Stapled.new(cs_r, tc_w), IO::Stapled.new(ss_r, ts_w),
        7_i64, sink, WsRewriter.new(to_server: {"absent", "x"}), WS_CTX)

      ts_w.close
      ts_r.gets_to_end.to_slice.should eq(lead + ping + second)
      sink.messages.should eq([{"out", 9, "pi"}, {"out", 1, "X"}, {"out", 1, "second"}])
      _ = tc_r
    end

    # An empty leading fragment is a NOTED frame with no payload, so the shape accumulator has
    # to be cleared by whoever decides not to write a row for it — on BOTH pumps. Left standing
    # it was inherited: `TEXT fin=0 ""` then `TEXT fin=1 "BBB"` (a §5.4 violation, two separate
    # messages) surfaced "BBB" as a two-frame message that had never ended.
    it "does not let an empty leading fragment's shape leak onto the next message's row" do
      lead = client_frame(Gori::Proxy::WS::OP_TEXT, Bytes.empty, fin: false)
      second = client_frame(Gori::Proxy::WS::OP_TEXT, "BBB".to_slice)
      plain = shape_capture(lead + second)
      armed = shape_capture(lead + second, WsRewriter.new(to_server: {"absent", "x"}))
      armed.map { |r| {r[0], r[1], r[2], r[3].frames, r[3].fin} }
        .should eq(plain.map { |r| {r[0], r[1], r[2], r[3].frames, r[3].fin} })
      plain.size.should eq(1)
      plain[0][2].should eq("BBB")
      plain[0][3].frames.should eq(1) # was 2 — the empty fragment's note, inherited
      plain[0][3].fin.should be_true
    end

    it "hoists an interleaved PING only when the message is actually re-framed" do
      cs_r, cs_w = IO.pipe
      ts_r, ts_w = IO.pipe
      ss_r, ss_w = IO.pipe
      tc_r, tc_w = IO.pipe
      client = IO::Stapled.new(cs_r, tc_w)
      upstream = IO::Stapled.new(ss_r, ts_w)

      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_TEXT, "AAA".to_slice, fin: false))
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_PING, "pi".to_slice))
      cs_w.write(masked_op_frame(Gori::Proxy::WS::OP_CONT, "BBB".to_slice))
      cs_w.close
      ss_w.close

      sink = WsSink.new
      # Matches across the fragment boundary, so the message can only leave re-framed.
      Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink,
        WsRewriter.new(to_server: {"AAABBB", "Z"}), WS_CTX)

      first = Gori::Proxy::WS.read_header(ts_r).not_nil!
      first.opcode.should eq(Gori::Proxy::WS::OP_PING)
      String.new(Gori::Proxy::WS.read_body(ts_r, first).not_nil!.payload).should eq("pi")
      second = Gori::Proxy::WS.read_header(ts_r).not_nil!
      second.opcode.should eq(Gori::Proxy::WS::OP_TEXT)
      String.new(Gori::Proxy::WS.read_body(ts_r, second).not_nil!.payload).should eq("Z")
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
        WsRewriter.new(to_server: {"second", "SECOND"}), WS_CTX)

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

  describe ".carries_extensions?" do
    # Asked of the head gori ACTUALLY SENT, because the strip runs before Match&Replace and a
    # rule is allowed to put the offer back — in which case the origin's acceptance is genuine
    # and must be relayed. The client's own parsed request cannot answer that.
    it "sees an offer that survived onto the wire" do
      Gori::Proxy::WS::Handshake.carries_extensions?(
        handshake("Sec-WebSocket-Extensions: permessage-deflate\r\n")).should be_true
    end

    it "is false once the line is gone" do
      Gori::Proxy::WS::Handshake.carries_extensions?(handshake("")).should be_false
    end

    it "never counts a start-line shaped like the header" do
      raw = "sec-websocket-extensions: permessage-deflate\r\nUpgrade: websocket\r\n\r\n"
      Gori::Proxy::WS::Handshake.carries_extensions?(raw.to_slice).should be_false
    end

    it "does not count a header whose name only STARTS with it" do
      Gori::Proxy::WS::Handshake.carries_extensions?(
        handshake("Sec-WebSocket-Extensions-Note: keep\r\n")).should be_false
    end
  end

  describe ".strip_extensions" do
    # The same method serves both directions: it copies the start-line through and only ever
    # drops a header line, so the origin's ACCEPT comes out of a 101 exactly as the client's
    # OFFER comes out of the request.
    it "removes the acceptance from a 101 response head as well" do
      resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
             "Connection: Upgrade\r\nSec-WebSocket-Extensions: permessage-deflate\r\n" \
             "Sec-WebSocket-Accept: abc\r\n\r\n"
      want = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
             "Connection: Upgrade\r\nSec-WebSocket-Accept: abc\r\n\r\n"
      Gori::Proxy::WS::Handshake.strip_extensions(resp.to_slice).should eq(want.to_slice)
    end

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

    receive_within(ws_chan) # out
    receive_within(ws_chan) # in
    client.close
    proxy.stop

    sink.ws.should contain({"out", "ping"})
    sink.ws.should contain({"in", "ping"})
  end

  it "relays client frames when the 101 also carries Content-Type: text/event-stream" do
    # `Content-Type` on a 101 is purely origin-chosen, and `relax_for_streaming_response` read it
    # as "this is an SSE stream" — which spawns a client-abort watcher parked on `@io.read`. The
    # 101 branch then hands `@io` to `WS::Relay` instead of closing it (closing is what ends that
    # watcher everywhere else), so two fibers read the same client socket and the already-parked
    # watcher swallowed every client->server byte into its scratch buffer for the tunnel's whole
    # lifetime: the origin below never saw the frame.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    got = Channel(String).new(1)
    spawn do
      conn = origin.accept
      conn.read_timeout = 5.seconds
      Gori::Proxy::Codec::Http1.read_head(conn) # the upgrade GET
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Content-Type: text/event-stream\r\n\r\n"
      conn.flush
      frame = Gori::Proxy::WS.read_frame(conn).not_nil!
      got.send(String.new(frame.payload))
      conn.write(Bytes[0x81_u8, frame.payload.size.to_u8]) # unmasked echo
      conn.write(frame.payload)
      conn.flush
    rescue ex
      got.send("origin-err:#{ex.class}") rescue nil
    end

    ws_chan = Channel(Nil).new(4)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    client.flush
    String.new(Gori::Proxy::Codec::Http1.read_head(client).not_nil!).should contain("101")

    client.write(masked_frame("ping"))
    client.flush
    # The origin — not just the client — must see it: a swallowed frame reports origin-err here.
    receive_within(got).should eq("ping")
    echoed = Gori::Proxy::WS.read_frame(client).not_nil!
    String.new(echoed.payload).should eq("ping")

    client.close
    proxy.stop
    origin.close rescue nil
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

    origin_head = receive_within(seen)
    origin_head.downcase.should_not contain("sec-websocket-extensions")
    origin_head.should contain("Sec-WebSocket-Key: dGhlIHNhbXBsZQ==") # everything else survives
    origin_head.should contain("User-Agent: probe")

    resp_head = Gori::Proxy::Codec::Http1.read_head(client).not_nil!
    String.new(resp_head).should contain("101")

    client.write(masked_frame("hello"))
    client.flush
    Gori::Proxy::WS.read_frame(client).not_nil!
    receive_within(ws_chan) # out
    receive_within(ws_chan) # in
    client.close
    proxy.stop

    # The RECORDED request is the handshake gori sent, not the client's offer: an offer
    # captured beside a 101 with no acceptance would read as "the origin declined".
    sink.heads.size.should eq(1)
    sink.heads[0].downcase.should_not contain("sec-websocket-extensions")
    sink.ws.should contain({"out", "hello"})
  end

  # An origin that accepts `permessage-deflate` unconditionally is common in the wild, and it
  # answers an offer gori had already removed. Relaying that acceptance told the client to
  # turn compression on and send RSV1 frames into an origin that had negotiated nothing — the
  # RFC 6455 §5.2 connection failure the "don't strip the accept" policy existed to avoid,
  # aimed at the other peer. Once gori removed the offer, the accept is answering a header
  # nobody sent, so removing it is what PREVENTS a desync rather than what causes one.
  it "removes an acceptance that answers the offer it stripped, and says so on the flow (#518)" do
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    seen = Channel(String).new(1)
    spawn do
      conn = origin.accept
      seen.send(String.new(Gori::Proxy::Codec::Http1.read_head(conn).not_nil!))
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
      conn.flush
      frame = Gori::Proxy::WS.read_frame(conn).not_nil!
      conn.write(Bytes[0x81_u8, frame.payload.size.to_u8])
      conn.write(frame.payload)
      conn.flush
    rescue
    end

    ws_chan = Channel(Nil).new(8)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /pmd HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n" \
              "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
    client.flush

    receive_within(seen).downcase.should_not contain("sec-websocket-extensions") # the offer, as before
    resp_head = String.new(Gori::Proxy::Codec::Http1.read_head(client).not_nil!)
    resp_head.should contain("101")
    # ... and now the acceptance too, so the client never turns permessage-deflate on.
    resp_head.downcase.should_not contain("sec-websocket-extensions")

    client.write(masked_frame("hello"))
    client.flush
    Gori::Proxy::WS.read_frame(client).not_nil!
    expect_ws_rows(ws_chan, 3) # the notice, then out, then in
    client.close
    proxy.stop

    # A gori.log line reaches only an operator who knew to tail it. The flow's own message
    # stream is where they are already looking.
    notice = sink.ws.find { |(_, text)| text.starts_with?("[gori] ") }
    notice.should_not be_nil
    notice.not_nil![1].should contain("permessage-deflate")
    notice.not_nil![1].should contain("removed the origin's")
    sink.ws.should contain({"out", "hello"})
  end

  it "leaves an unsolicited acceptance alone — there the two peers really do agree (#518)" do
    # The client offered nothing, so gori stripped nothing; an acceptance here is the origin
    # violating RFC 6455 §4.1 (or an operator's rule putting the offer back). Removing it
    # WOULD manufacture the desync the old policy warned about, so the bytes stand and only
    # the advisory changes — what suffers is gori's store, and that is what it says.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    seen = Channel(String).new(1)
    spawn do
      conn = origin.accept
      seen.send(String.new(Gori::Proxy::Codec::Http1.read_head(conn).not_nil!))
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
      conn.flush
      Gori::Proxy::WS.read_frame(conn)
    rescue
    end

    ws_chan = Channel(Nil).new(8)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    client.flush

    receive_within(seen)
    resp_head = String.new(Gori::Proxy::Codec::Http1.read_head(client).not_nil!)
    resp_head.should contain("Sec-WebSocket-Extensions: permessage-deflate") # P7: untouched
    expect_ws_rows(ws_chan, 1)                                               # the notice row
    client.close
    proxy.stop

    notice = sink.ws.find { |(_, text)| text.starts_with?("[gori] ") }
    notice.should_not be_nil
    notice.not_nil![1].should contain("that gori did not remove")
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

    receive_within(seen).should contain("Sec-WebSocket-Extensions: permessage-deflate")
    Gori::Proxy::Codec::Http1.read_head(client)
    client.close
    proxy.stop
  end

  it "decodes the tunnel when the 101's Upgrade is a protocol LIST, not one value" do
    # `ClientConn` compared the WHOLE `Upgrade` field-value to "websocket", so an origin
    # answering the RFC 7230 §6.7 list form (`Upgrade: websocket, h2c`) fell out of the
    # WebSocket branch and was relayed as an opaque byte tunnel — no frames captured, no
    # `part: ws` rule, no `proto:ws` hold — on a socket gori can decode. The question now has
    # one home, `WS::Handshake.upgrades_to_websocket?`, which matches the TOKEN.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      conn = origin.accept
      conn.read_timeout = 5.seconds
      Gori::Proxy::Codec::Http1.read_head(conn) # the upgrade GET
      # `Upgrade` is a comma-separated protocol list: this is still a WebSocket handshake.
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket, h2c\r\nConnection: Upgrade\r\n\r\n"
      conn.flush
      frame = Gori::Proxy::WS.read_frame(conn).not_nil!    # client's (masked) frame
      conn.write(Bytes[0x81_u8, frame.payload.size.to_u8]) # unmasked echo
      conn.write(frame.payload)
      conn.flush
    rescue
    end

    ws_chan = Channel(Nil).new(8)
    sink = IntegSink.new(ws_chan)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    client.flush
    String.new(Gori::Proxy::Codec::Http1.read_head(client).not_nil!).should contain("101")

    client.write(masked_frame("ping"))
    client.flush
    echoed = Gori::Proxy::WS.read_frame(client).not_nil!
    String.new(echoed.payload).should eq("ping")

    # Both directions must reach the store as decoded frames, not as an opaque tunnel.
    receive_within(ws_chan, 5, "the client->server frame row")
    receive_within(ws_chan, 5, "the server->client frame row")

    client.close
    proxy.stop
    origin.close rescue nil

    sink.ws.should contain({"out", "ping"})
    sink.ws.should contain({"in", "ping"})
    # An opaque relay leaves a `[gori]` notice row instead of traffic; there must be none.
    sink.ws.any? { |(_, text)| text.starts_with?(Gori::Proxy::WS::NOTICE_PREFIX) }.should be_false
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

# --- V7: the frame SHAPE, and control frames, reach capture at all -----------------
#
# `ws_messages(direction, opcode, payload)` recorded a message's bytes and nothing about the
# frames that carried them, and the relay never called the sink for a control frame at all.
# Between them that lost the CLOSE code and reason — the most diagnostic thing a failed
# WebSocket test produces, and something the repeater engine already reported, so the two
# surfaces disagreed about the same protocol — plus the RSV bits (a deflate frame and a plain
# one were the same row), an unmasked client frame (§5.1), and fragmentation.
private class ShapeSink < Gori::Proxy::FlowSink
  getter rows = [] of {String, Int32, String, Gori::Proxy::WS::Shape}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << {direction, opcode, String.new(payload), shape}
  end
end

# A client frame with an arbitrary header, so a spec can put an RSV bit or an unmasked client
# frame on the wire — the shapes the raw recording origin logged for this round.
private def client_frame(opcode : UInt8, payload : Bytes, *, fin : Bool = true,
                         rsv : Int32 = 0, mask : Bytes? = Bytes[0x01, 0x02, 0x03, 0x04]) : Bytes
  Gori::Proxy::WS.encode(opcode, payload, mask: !mask.nil?, fin: fin, rsv: rsv, mask_key: mask)
end

# Relay `bytes` client→upstream with both peers then at EOF, and hand back what capture saw.
private def shape_capture(bytes : Bytes, rewriter = nil) : Array({String, Int32, String, Gori::Proxy::WS::Shape})
  cs_r, cs_w = IO.pipe
  ts_r, ts_w = IO.pipe
  ss_r, ss_w = IO.pipe
  tc_r, tc_w = IO.pipe
  client = IO::Stapled.new(cs_r, tc_w)
  upstream = IO::Stapled.new(ss_r, ts_w)
  cs_w.write(bytes); cs_w.close
  ss_w.close
  sink = ShapeSink.new
  Gori::Proxy::WS::Relay.run(client, upstream, 7_i64, sink, rewriter,
    rewriter ? WS_CTX : Gori::Proxy::WS::Context::NONE)
  ts_w.close
  _ = {ts_r, tc_r}
  sink.rows
end

describe "Gori::Proxy::WS::Relay frame shape capture (V7)" do
  it "records a PING, a PONG and a CLOSE — with its code and reason — as rows of their own" do
    wire = client_frame(Gori::Proxy::WS::OP_PING, "ping-with-payload".to_slice) +
           client_frame(Gori::Proxy::WS::OP_PONG, "unsolicited-pong".to_slice) +
           client_frame(Gori::Proxy::WS::OP_CLOSE, Bytes[0x03, 0xEA] + "bye-reason".to_slice)
    rows = shape_capture(wire)
    rows.map { |r| {r[0], r[1]} }.should eq([{"out", 9}, {"out", 10}, {"out", 8}])
    rows[0][2].should eq("ping-with-payload")
    # The CLOSE row carries §5.5.1's 2-byte code AND its reason, which existed nowhere.
    close = Gori::Store::WsMessage.new(0_i64, 1_i64, nil, 0_i64, "out", 8, rows[2][2].to_slice)
    close.close_code.should eq(1002)
    String.new(close.close_reason.not_nil!).should eq("bye-reason")
  end

  it "keeps the RSV nibble, so a §5.2 extension frame is not the same row as a plain one" do
    wire = client_frame(Gori::Proxy::WS::OP_TEXT, "plain".to_slice) +
           client_frame(Gori::Proxy::WS::OP_TEXT, "rsv1".to_slice, rsv: 4)
    shape_capture(wire).map { |r| {r[2], r[3].rsv} }.should eq([{"plain", 0}, {"rsv1", 4}])
  end

  it "records that a client frame arrived UNMASKED (§5.1), and the key when it did not" do
    wire = client_frame(Gori::Proxy::WS::OP_TEXT, "masked".to_slice) +
           client_frame(Gori::Proxy::WS::OP_TEXT, "bare".to_slice, mask: nil)
    rows = shape_capture(wire)
    rows[0][3].masked.should be_true
    rows[0][3].mask_key.not_nil!.should eq(Bytes[0x01, 0x02, 0x03, 0x04])
    rows[1][3].masked.should be_false
    rows[1][3].mask_key.should be_nil
  end

  it "counts the frames a reassembled message spanned" do
    wire = client_frame(Gori::Proxy::WS::OP_TEXT, "frag1|".to_slice, fin: false) +
           client_frame(Gori::Proxy::WS::OP_CONT, "frag2".to_slice)
    rows = shape_capture(wire)
    rows.size.should eq(1)
    rows[0][2].should eq("frag1|frag2")
    rows[0][3].frames.should eq(2) # ONE row, but two frames on the wire
    rows[0][3].fin.should be_true  # ... and the last of them did FIN
  end

  it "records the re-framed shape (1 frame) when a rewrite collapses fragmentation" do
    # Re-framing replaces multi-fragment wire bytes with ONE frame; capture must not keep
    # the arrived frames=2 / RSV / mask key. emit_message used to pass `arrived` into the
    # gate branch (and `emitted` was a dead store); the direct path already used emitted.
    wire = client_frame(Gori::Proxy::WS::OP_TEXT, "hi ".to_slice, fin: false) +
           client_frame(Gori::Proxy::WS::OP_CONT, "there".to_slice)
    rows = shape_capture(wire, WsRewriter.new(to_server: {"hi there", "bye"}))
    rows.size.should eq(1)
    rows[0][2].should eq("bye")
    rows[0][3].frames.should eq(1) # gori's one frame, not the peer's two
    rows[0][3].fin.should be_true
    rows[0][3].rsv.should eq(0)
  end

  it "marks a message that ended with no FIN at all" do
    rows = shape_capture(client_frame(Gori::Proxy::WS::OP_TEXT, "never-ends".to_slice, fin: false))
    rows.size.should eq(1)
    rows[0][3].fin.should be_false
  end

  # Both pumps have to record the same facts about the same bytes, or a finding would depend
  # on whether a Match&Replace rule happened to be live for some other host.
  it "records the same shape on the ASSEMBLING pump as on the byte-exact one" do
    wire = client_frame(Gori::Proxy::WS::OP_TEXT, "rsv1".to_slice, rsv: 4) +
           client_frame(Gori::Proxy::WS::OP_PING, "p".to_slice) +
           client_frame(Gori::Proxy::WS::OP_TEXT, "a".to_slice, fin: false) +
           client_frame(Gori::Proxy::WS::OP_CONT, "b".to_slice)
    plain = shape_capture(wire).map { |r| {r[0], r[1], r[2], r[3].rsv, r[3].frames, r[3].fin} }
    armed = shape_capture(wire, WsRewriter.new(to_server: {"absent", "x"}))
      .map { |r| {r[0], r[1], r[2], r[3].rsv, r[3].frames, r[3].fin} }
    armed.should eq(plain)
    plain.map(&.[](1)).should eq([1, 9, 1])
  end

  # A REWRITTEN message goes out as gori's OWN single frame, so claiming the sender's RSV
  # bits and fragment count on that row would be a claim about bytes nobody sent.
  it "reports gori's OWN framing for a message a rule rewrote" do
    wire = client_frame(Gori::Proxy::WS::OP_TEXT, "has-OLD".to_slice, rsv: 4)
    rows = shape_capture(wire, WsRewriter.new(to_server: {"OLD", "NEW"}))
    rows.size.should eq(1)
    rows[0][2].should eq("has-NEW")
    rows[0][3].rsv.should eq(0) # not the sender's 4 — gori re-framed it
  end
end

# An IO whose READ RAISES where a pipe would report end of stream — a transport reset, the
# other of the two ways a WebSocket ends without a CLOSE frame. gori distinguishes them
# (a FIN is `read_fully?` → nil, a reset raises) and used to throw the difference away, so an
# operator staring at a `101 / complete / empty transcript` flow could not tell "the peer hung
# up normally" from "something killed this socket".
private class ResettingIO < IO
  def initialize(@src : IO, @dst : IO)
  end

  def read(slice : Bytes) : Int32
    n = @src.read(slice)
    raise IO::Error.new("Connection reset by peer") if n == 0
    n
  end

  def write(slice : Bytes) : Nil
    @dst.write(slice)
  end

  def flush : Nil
    @dst.flush
  end

  def close : Nil
    @src.close rescue nil
    @dst.close rescue nil
  end
end

describe "Gori::Proxy::WS::Relay teardown, FIN vs RST" do
  # A frame, then the origin's socket RESET. The frame's own row is untouched (it really did
  # arrive); what is added is the sentence saying HOW the socket ended, on the flow's own
  # `ws_messages` stream so `gori run show`, the WS pane, MCP `get_flow` and an export all
  # carry it.
  it "names a peer that RESET the socket instead of closing it" do
    ss_r, ss_w = IO.pipe
    ts_r, ts_w = IO.pipe
    cs_r, cs_w = IO.pipe
    tc_r, tc_w = IO.pipe
    client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
    upstream = ResettingIO.new(ss_r, ts_w)

    # The CLIENT stays live throughout, so the reset is the FIRST ending `run` observes —
    # exactly the shape of the case an operator asks about, a socket killed under a peer that
    # is still there. (`run` closes both legs on an abnormal end, which reaps the other pump.)
    ss_w.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "from-server".to_slice, mask: false))
    ss_w.close # ResettingIO turns this end of stream into a raise

    sink = WsSink.new
    Gori::Proxy::WS::Relay.run(client, upstream, 9_i64, sink, nil, WS_CTX)
    cs_w.close

    notices = sink.messages.select { |(_, _, t)| t.starts_with?("[gori] ") }
    notices.size.should eq(1)
    # A diagnostic is not traffic: NOTICE_DIRECTION, never the direction a repeater seeds from.
    notices.first[0].should eq("in")
    notices.first[2].should contain("the server ended this WebSocket with a transport-level RESET")
    notices.first[2].should contain("leaves no row here")   # so its ABSENCE is readable
    sink.messages.first.should eq({"in", 1, "from-server"}) # the frame's own row is untouched
    _ = {ts_r, tc_r}
  end

  # The complement, and the reason the sentence above says what absence means: the SAME
  # transcript ended by a plain FIN gets no row. A WebSocket dying on a FIN with no CLOSE is
  # how one ordinarily dies in the field, and a `[gori]` row on a large fraction of every
  # capture saying "nothing unusual happened" is how the anomalous row stops being noticed.
  it "writes no teardown row when the peer merely closed (FIN)" do
    ss_r, ss_w = IO.pipe
    ts_r, ts_w = IO.pipe
    cs_r, cs_w = IO.pipe
    tc_r, tc_w = IO.pipe
    client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
    upstream = IO::Stapled.new(ss_r, ts_w)

    ss_w.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "from-server".to_slice, mask: false))
    ss_w.close # a plain end of stream: the peer's FIN

    sink = WsSink.new
    Gori::Proxy::WS::Relay.run(client, upstream, 10_i64, sink, nil, WS_CTX)
    cs_w.close
    sink.messages.should eq([{"in", 1, "from-server"}])
    _ = {ts_r, tc_r}
  end

  # ... and a proper closing handshake gets none either, even though gori's own teardown then
  # unblocks the surviving pump's read: only endings observed BEFORE `run` closes the sockets
  # are the peers', or the diagnostic would report gori's own reap as a peer's reset.
  it "writes no teardown row when the peer sent a CLOSE frame" do
    ss_r, ss_w = IO.pipe
    ts_r, ts_w = IO.pipe
    cs_r, cs_w = IO.pipe
    tc_r, tc_w = IO.pipe
    client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
    upstream = ResettingIO.new(ss_r, ts_w)

    ss_w.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    cs_w.close # both directions end at once; neither ending is a reset

    sink = WsSink.new
    Gori::Proxy::WS::Relay.run(client, upstream, 11_i64, sink, nil, WS_CTX)
    sink.messages.count { |(_, _, t)| t.starts_with?("[gori] ") }.should eq(0)
    ss_w.close
    _ = {ts_r, tc_r}
  end
end

describe "Gori::Proxy::WS.encode frame shapes" do
  # Every one of these was inexpressible: `encode` had no `rsv`, no explicit mask key and no
  # way to decouple the length header from the payload, and nothing above it plumbed `fin`.
  it "sets the RSV nibble in the first header octet (RSV1=4)" do
    Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "x".to_slice, mask: false, rsv: 4)[0]
      .should eq(0xC1_u8) # FIN | RSV1 | TEXT
  end

  it "uses the mask key the caller chose, and folds a short one to 4 bytes" do
    f = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "ab".to_slice,
      mask_key: Bytes[0xDE, 0xAD, 0xBE, 0xEF])
    f[2, 4].should eq(Bytes[0xDE, 0xAD, 0xBE, 0xEF])
    Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "ab".to_slice, mask_key: Bytes[0x11])[2, 4]
      .should eq(Bytes[0x11, 0x00, 0x00, 0x00])
  end

  it "emits an UNMASKED client frame when asked (the §5.1 hardening probe)" do
    f = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "hi".to_slice, mask: false)
    (f[1] & 0x80).should eq(0) # no MASK bit
    f.should eq(Bytes[0x81, 0x02] + "hi".to_slice)
  end

  it "advertises `declared_len` while writing the real payload — a length that lies" do
    f = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "abc".to_slice, mask: false,
      declared_len: 99)
    f[1].should eq(99_u8)   # the header promises 99
    f.size.should eq(2 + 3) # ... and 3 bytes follow it
    f[2, 3].should eq("abc".to_slice)
  end

  it "picks the length FORM from the declared length, not the payload's" do
    # An over-declared 200 must take the 16-bit form even though the payload is 1 byte,
    # or the receiver reads a different header than the one that was asked for.
    f = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "z".to_slice, mask: false,
      declared_len: 200)
    f[1].should eq(126_u8)
    ((f[2].to_i << 8) | f[3].to_i).should eq(200)
  end

  it "is byte-identical to the pre-shape encoder when the shape is the default" do
    # The regression pin: the default send path must not have moved. `Shape::DEFAULT` says
    # nothing, so the keyword form and the shape form have to agree with a fixed key.
    key = Bytes[0x01, 0x02, 0x03, 0x04]
    plain = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "hello".to_slice, mask_key: key)
    shaped = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "hello".to_slice,
      Gori::Proxy::WS::Shape.new(mask_key: key))
    shaped.should eq(plain)
    plain.should eq(Bytes[0x81, 0x85, 0x01, 0x02, 0x03, 0x04, 0x69, 0x67, 0x6f, 0x68, 0x6e]) # "hello" ^ key
  end

  it "lets a Shape's `masked` override the direction default, and nil defer to it" do
    unmasked = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "h".to_slice,
      Gori::Proxy::WS::Shape.new(masked: false), mask: true)
    (unmasked[1] & 0x80).should eq(0)
    deferred = Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "h".to_slice,
      Gori::Proxy::WS::Shape.new, mask: true)
    (deferred[1] & 0x80).should eq(0x80)
  end
end

# The defensive half of F1. `Relay::NOTICE_DIRECTION` keeps a NEW advisory off the direction a
# WebSocket repeater seeds from, but a flow captured by an older build still carries one there,
# and two markers legitimately keep the frame's own opcode and direction because they stand in
# for a real frame at its own position (the ping-flood marker rides opcode 9, the oversized
# marker rides the message's). So a seed reader has to be able to recognise a notice row
# itself — `run repeater create --flow`, MCP `create_repeater` and the TUI all take a row's
# opcode and BYTES straight across, and replaying gori's own prose to the application under
# test is a fabricated message the operator never authored.
private def ws_row(payload : Bytes, opcode = 1) : Gori::Store::WsMessage
  Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "out", opcode, payload)
end

describe "Gori::Store::WsMessage#notice?" do
  it "recognises every shape of [gori] row the relay writes" do
    ws_row("[gori] more than 8 control frames arrived".to_slice).notice?.should be_true
    ws_row("[gori] 20000000-byte WebSocket frame forwarded".to_slice).notice?.should be_true
    ws_row("[gori] more than 64 ping/pong frames".to_slice, 9).notice?.should be_true
  end

  it "leaves a peer's own message alone" do
    ws_row("hello".to_slice).notice?.should be_false
    ws_row(Bytes.empty).notice?.should be_false
    # Shorter than the prefix, and a near-miss: the test is the whole prefix or nothing.
    ws_row("[gori".to_slice).notice?.should be_false
    ws_row("[gori]x more".to_slice).notice?.should be_false
    ws_row(" [gori] leading space".to_slice).notice?.should be_false
  end

  it "answers on BYTES, so an invalid-UTF-8 payload is neither decoded nor scrubbed" do
    # `696e76616c6964fffe` is the §8.1/§5.6 validation payload the send path spent two rounds
    # learning not to rewrite; asking this question must not be the thing that touches it.
    invalid = Bytes[0x69, 0x6e, 0x76, 0xff, 0xfe]
    ws_row(invalid).notice?.should be_false
    notice = "[gori] ".to_slice + invalid
    ws_row(notice).notice?.should be_true
  end

  it "is reachable on the converted seed type too, which is what the TUI holds" do
    Gori::Store::WsOutMessage.new(1, "[gori] advisory".to_slice).notice?.should be_true
    Gori::Store::WsOutMessage.text("ordinary").notice?.should be_false
  end
end
