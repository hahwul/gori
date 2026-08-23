require "../spec_helper"
require "socket"

# Regressions from the WebSocket-fuzzing review. Each case is a defect that shipped in the first
# cut of the feature and would read as working from the outside.
private alias Fuzz = Gori::Fuzz
private alias WS = Gori::Proxy::WS

private HS = "GET /ws HTTP/1.1\r\nHost: w.test\r\n" \
             "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

private def plan_for(template : String, ws : Array(Fuzz::WsMessageSource)? = nil,
                     marks = [] of String, auto = false) : Fuzz::Plan
  Fuzz::Plan.build(
    Fuzz::PlanOptions.new(template,
      default_target: "http://w.test", auto_mark: auto, marks: marks,
      sources: [Fuzz::InlineList.new(["a"])] of Fuzz::PayloadSource,
      ws_messages: ws),
    ungated_outbound)
end

describe "WebSocket fuzzing — review regressions" do
  # 1. The record guard used to sniff `Upgrade: websocket` in the request BYTES, which cannot
  #    tell which engine ran. `--ws-http-only` sweeps those exact bytes as ordinary HTTP, so
  #    `--record-history all` recorded nothing while the refusal message told the operator that
  #    ws-http-only "does record".
  describe "history recording keys on the ENGINE, not the bytes" do
    ws_req = HS.to_slice
    head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".to_slice
    r = Fuzz::Result.new(1_i64, ["p"], nil, 101, 2_i64, 1, 1, 5_i64, nil, true, false, nil,
      head: head, body: "hi".to_slice, request: ws_req)

    it "refuses when the run took the framed path" do
      Fuzz::HistoryRecord.records?(:all, r, websocket: true).should be_false
    end

    it "RECORDS the same handshake bytes when the run was ws-http-only" do
      Fuzz::HistoryRecord.records?(:all, r, websocket: false).should be_true
    end
  end

  # 2. `shadowed &&= sh2` made a --mark shadowed only if EVERY part contained it and had it
  #    marked already, so the "your mark added no position" warning never fired on a WS run.
  it "reports a --mark that added no position on a WebSocket script" do
    hs = "GET /ws?room=§ROOM§ HTTP/1.1\r\nHost: w.test\r\n" \
         "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
    plan = plan_for(hs, [Fuzz::WsMessageSource.new(1, "§v§")], marks: ["ROOM"])
    plan.mark_matches.should eq([{"ROOM", 0}])
    plan.shadowed_marks.should eq(["ROOM"])
  end

  # 5. An EMPTY frame list is truthy in Crystal, so a capture whose only outbound rows were
  #    gori advisories produced a FRAMED run that dialed a socket per payload, sent nothing, and
  #    then waited out the 15s handshake timeout. A handshake-only script is an HTTP sweep.
  it "folds an empty frame list to an ordinary HTTP sweep" do
    plan = plan_for("GET /ws?room=§r§ HTTP/1.1\r\nHost: w.test\r\n" \
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
      [] of Fuzz::WsMessageSource)
    plan.websocket?.should be_false
  end

  # 6. `mark_body`'s urlencoded sniff needs only an `=` and no newline, which a BINARY frame
  #    satisfies by accident — a protobuf carrying 0x3D was carved into bogus positions.
  describe "--auto marks TEXT frames only" do
    binary = String.new(Bytes[0x08, 0x3d, 0xff, 0xfe, 0x01, 0x02, 0x26, 0x77, 0x3d, 0x32])

    it "leaves a binary frame alone" do
      Fuzz::Template.auto_mark_payload(binary, 2).should eq(binary)
    end

    it "still marks a text frame" do
      Fuzz::Template.auto_mark_payload(%({"q":"term"}), 1).should contain("§term§")
    end

    it "does not carve positions out of a binary frame in a real plan" do
      expect_raises(Fuzz::PlanError) do
        plan_for(HS, [Fuzz::WsMessageSource.new(2, binary)], auto: true)
      end
    end
  end

  # 8. `WsOutcome.failed` carried `frames_in: 0`, and every reader tests presence — so an
  #    errored row printed `ws 0 frames` and emitted `"ws_frames_in": 0`.
  it "leaves ws_frames_in nil for a session that never upgraded" do
    Fuzz::WsOutcome.failed.frames_in.should be_nil
    r = Fuzz::Result.new(1_i64, ["p"], nil, nil, 0_i64, 0, 0, 0_i64, "dial failed", false, false, nil)
      .with_ws(Fuzz::WsOutcome.failed)
    r.ws_frames_in.should be_nil
    r.ws_close_code.should be_nil
    Gori::CLI::Output.fuzz_row_text(r).should_not contain("ws 0 frames")
    Gori::CLI::Output.fuzz_row_json(r).should_not contain("ws_frames_in")
  end
end

# 4. Captured frames must go through `Run.seed_shape`, which drops the recorded MASK KEY: it is
#    a §5.3 nonce, and seeding it pins one fixed key onto every frame of every variation.
describe "a captured WebSocket seed drops the recorded mask key" do
  it "keeps fin/rsv and drops mask_key" do
    captured = Gori::Store::WsShape.new(fin: false, rsv: 4, masked: true,
      mask_key: Bytes[0xde, 0xad, 0xbe, 0xef], declared_len: 99)
    seeded = Gori::CLI::Run.seed_shape(captured)
    seeded.fin.should be_false
    seeded.rsv.should eq(4)
    seeded.mask_key.should be_nil
    seeded.declared_len.should be_nil
  end
end

# 7. `--message-frame hex=`/`b64=` are RAW BYTES the operator supplied; a `C2 A7` pair in them
#    is not a marker anyone typed.
describe "Repeater::WsFrameSpec.parse_kind" do
  it "reports which payload form was used" do
    Gori::Repeater::WsFrameSpec.parse_kind("opcode=text,text=hi")[2].should eq("text")
    Gori::Repeater::WsFrameSpec.parse_kind("opcode=bin,hex=c2a7")[2].should eq("hex")
    Gori::Repeater::WsFrameSpec.parse_kind("opcode=bin,b64=wqc=")[2].should eq("b64")
    Gori::Repeater::WsFrameSpec.parse_kind("opcode=ping")[2].should be_nil
  end

  it "keeps parse's own two-tuple contract intact" do
    msg, err = Gori::Repeater::WsFrameSpec.parse("opcode=ping,text=hi")
    err.should be_nil
    msg.not_nil!.opcode.should eq(9)
  end
end
