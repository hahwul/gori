require "../spec_helper"

private alias Fuzz = Gori::Fuzz
private alias WS = Gori::Proxy::WS

private HANDSHAKE = "GET /ws?room=§lobby§ HTTP/1.1\r\nHost: w.test\r\n" \
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

private def frame(text : String, opcode = 1, shape = WS::Shape::DEFAULT, evidence = false)
  Fuzz::FrameTemplate.new(Fuzz::Template.parse(text, false), opcode, shape, evidence)
end

private def script(handshake : String, frames = [] of Fuzz::FrameTemplate) : Fuzz::WsScript
  Fuzz::WsScript.build(Fuzz::Template.parse(handshake), frames)
end

describe Gori::Fuzz::WsScript do
  # The whole point of the composite: every part's positions land in ONE vector, in part order,
  # with the handshake first. That is what lets Sniper/Pitchfork/ClusterBomb, `--mark` and the
  # payload-set contract work over a WebSocket script with no changes at all.
  describe "the global position index space" do
    it "numbers the handshake first, then each frame in order" do
      s = script(HANDSHAKE, [frame(%({"op":"§sub§","q":"§term§"})), frame("§ping§")])
      s.position_count.should eq(4)
      s.default_payloads.should eq(["lobby", "sub", "term", "ping"])
      # offsets[0] is the handshake, offsets[k + 1] is frames[k].
      s.offsets.should eq([0, 1, 3])
      # `Position#index` is re-stamped globally rather than left at each part's local value.
      s.positions.map(&.index).should eq([0, 1, 2, 3])
    end

    it "handles a handshake with no positions" do
      plain = "GET /ws HTTP/1.1\r\nHost: w.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      s = script(plain, [frame("§a§"), frame("§b§")])
      s.position_count.should eq(2)
      s.offsets.should eq([0, 0, 1])
      s.default_payloads.should eq(["a", "b"])
    end

    it "handles a script with no frames at all (handshake-only)" do
      s = script(HANDSHAKE)
      s.position_count.should eq(1)
      s.offsets.should eq([0])
      s.render_spans(["x"]).frames.should be_empty
    end
  end

  describe "#render_spans" do
    it "splices each part's own slice of the global payload vector" do
      s = script(HANDSHAKE, [frame(%({"op":"§sub§","q":"§term§"})), frame("§ping§")])
      r = s.render_spans(["ROOM", "OP", "TERM", "PING"])
      String.new(r.handshake).should contain("/ws?room=ROOM")
      String.new(r.frames[0].payload).should eq(%({"op":"OP","q":"TERM"}))
      String.new(r.frames[1].payload).should eq("PING")
    end

    it "computes spans against each frame's OWN payload, not the handshake" do
      s = script(HANDSHAKE, [frame(%(pre-§x§-post))])
      r = s.render_spans(["ROOM", "PAYLOAD"])
      # The handshake's span covers `ROOM` in the handshake buffer…
      a, b = r.handshake_spans[0]
      String.new(r.handshake[a, b - a]).should eq("ROOM")
      # …and the frame's covers `PAYLOAD` in the FRAME buffer. A flattened span list would
      # hand `Env.expand_bindings_frame` offsets computed against a different slice.
      c, d = r.frames[0].payload_spans[0]
      String.new(r.frames[0].payload[c, d - c]).should eq("PAYLOAD")
    end

    it "carries each frame's opcode, shape and provenance through the splice" do
      shape = WS::Shape.new(fin: false, rsv: 4, masked: false)
      s = script(HANDSHAKE, [frame("§p§", opcode: 9, shape: shape, evidence: true)])
      f = s.render_spans(["r", "PING"]).frames[0]
      # `WsEngine::OutMsg`'s own comment records the defect this guards: twelve distinct frame
      # shapes replayed as seven identical ones, because the shape was rebuilt rather than
      # carried. A PING must not come out as TEXT, and FIN=0/RSV1 must survive.
      f.opcode.should eq(9)
      f.shape.fin.should be_false
      f.shape.rsv.should eq(4)
      f.shape.masked.should eq(false)
      f.evidence.should be_true
    end

    it "renders the parts it reaches when the payload vector is short" do
      s = script(HANDSHAKE, [frame("§a§"), frame("§b§")])
      r = s.render_spans(["ROOM", "A"])
      String.new(r.frames[0].payload).should eq("A")
      # The last frame renders with no payload rather than raising — the same tolerance
      # `Template#render_spans` has for a list shorter than `position_count`.
      String.new(r.frames[1].payload).should eq("")
    end

    # `Template.parse`/`render` are byte-oriented so a non-UTF-8 body survives them; a frame
    # payload is where that matters most, since RFC 6455 §8.1 UTF-8 validation is itself a
    # standard WebSocket test. The twin of `spec/fuzz/template_bytes_spec.cr`, one part over.
    it "round-trips a non-UTF-8 frame payload byte-exact" do
      raw = Bytes[0x69, 0x6e, 0x76, 0xff, 0xfe, 0x01, 0x02]
      s = script(HANDSHAKE, [frame(String.new(raw), opcode: 2)])
      out = s.render_spans(["r"]).frames[0].payload
      out.to_a.should eq(raw.to_a)
    end
  end

  describe "#urlencoded_positions" do
    # A frame payload is not a URL. Percent-encoding a payload spliced into a JSON TEXT frame
    # would send `%3Cscript%3E` where the operator marked `<script>` — a different test.
    it "names the handshake's query positions and no frame position" do
      s = script(HANDSHAKE, [frame("a=§v§&b=2")])
      s.urlencoded_positions.should eq([0])
    end
  end

  describe "#apply_chains_reported" do
    it "applies each position's own chain, through Template's one implementation" do
      s = script(HANDSHAKE, [frame("§abc¦base64-encode§"), frame("§plain§")])
      out = s.apply_chains_reported(["room", "abc", "plain"], Gori::Decoder.shared_registry)
      out.map(&.[0]).should eq(["room", "YWJj", "plain"])
      out.map(&.[1]).should eq([nil, nil, nil])
    end
  end
end
