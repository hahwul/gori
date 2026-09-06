require "./spec_helper"

# RFC 6455 §5.1 fixes masking per direction: a client→server frame MUST be masked, a
# server→client frame MUST NOT be. The repeater transcript reused the outbound message
# model to render BOTH directions, so it stamped "unmasked" on every inbound server frame —
# firing the §5.1 marker on the ordinary case and burying the anomaly it exists for. It also
# made `Shape#default?` false for every inbound frame, so the plain `← ABCD` transcript line
# was unreachable and every server frame rendered as `← [TEXT unmasked] ABCD`.
private alias Shape = Gori::Proxy::WS::Shape
private alias Msg = Gori::Store::WsOutMessage

# A CAPTURED row, which carries its own direction — so `shape_note` and `emit_shape_json` can
# ask the §5.1 question the send-side model needs a `to_server` argument for.
private def captured(direction : String, shape : Shape, opcode : Int32 = 1) : Gori::Store::WsMessage
  Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, direction, opcode, "hi".to_slice, shape)
end

private def shape_json(m : Gori::Store::WsMessage) : String
  JSON.build { |j| j.object { m.emit_shape_json(j) } }
end

describe "WebSocket frame shape, per direction" do
  describe "Shape#default?(to_server)" do
    it "treats an unmasked server→client frame as ordinary" do
      Shape.new(masked: false).default?(false).should be_true
    end

    it "still treats an unmasked client→server frame as a departure" do
      Shape.new(masked: false).default?(true).should be_false
    end

    it "treats a MASKED server→client frame as a departure" do
      Shape.new(masked: true).default?(false).should be_false
    end

    it "does not excuse any other departure on the inbound side" do
      Shape.new(fin: false).default?(false).should be_false
      Shape.new(rsv: 4).default?(false).should be_false
      Shape.new(declared_len: 99).default?(false).should be_false
    end

    # A RECEIVED message really can span several frames, and reassembly is what erases the
    # difference: `TEXT fin=0 "AAA"` + `CONT fin=1 "BBB"` and one `TEXT "AAABBB"` have the same
    # payload. The capture side has named it (`[2 frames]`) since V7 — this is what lets the
    # repeater transcript, pointed at the same origin, stop calling it an ordinary line.
    it "treats a multi-frame inbound message as a departure" do
      Shape.new(frames: 2).default?(false).should be_false
      Shape.new(frames: 1).default?(false).should be_true
    end

    # ... and NOT on the send side, where the encoder writes one frame per message: `frames`
    # there is capture metadata a sender cannot honour, so consulting it would push every
    # ordinary seeded row off the untouched path.
    it "leaves the send-side reading of frames alone" do
      Shape.new(frames: 2).default?.should be_true
      Shape.new(frames: 2).default?(true).should be_true
    end

    it "leaves the no-argument form alone" do
      Shape.new.default?.should be_true
      Shape.new(masked: false).default?.should be_false
    end
  end

  describe "WsOutMessage#shape_label(to_server)" do
    it "does not call an unmasked server→client frame unmasked" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false)).shape_label(false).should eq("TEXT")
    end

    it "names the §5.1 violation on the client→server side" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false)).shape_label(true).should eq("TEXT unmasked")
    end

    it "names a masked server→client frame, which is the inbound violation" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: true)).shape_label(false).should eq("TEXT masked")
    end

    it "keeps naming every direction-independent departure inbound" do
      label = Msg.new(9, "p".to_slice, Shape.new(fin: false, rsv: 4, masked: false)).shape_label(false)
      label.should eq("PING fin=0 rsv=4")
    end

    it "defaults to the client→server reading, which is what a send-side caller means" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false)).shape_label.should eq("TEXT unmasked")
    end

    it "names the fragment count a received message was reassembled from" do
      Msg.new(1, "hi".to_slice, Shape.new(masked: false, frames: 3)).shape_label(false)
        .should eq("TEXT 3 frames")
      # A send writes one frame per message, so this can only ever describe what arrived.
      Msg.new(1, "hi".to_slice, Shape.new(frames: 3)).shape_label(true).should eq("TEXT")
    end
  end

  # The CAPTURE side of the same §5.1 question. `shape_note` and `emit_shape_json` know the
  # direction from the row itself, and both used to answer only half of §5.1: the outbound
  # violation (a client frame sent UNMASKED) was named, the inbound one (a server that MASKED)
  # was not — while `masked: false`, the NORM inbound, was emitted on every ordinary server
  # row. The repeater transcript named the inbound violation the whole time, so the two
  # surfaces gave different answers about one origin's frame.
  describe "Store::WsMessage, per direction" do
    it "names a MASKED server→client frame — the inbound §5.1 violation" do
      captured("in", Shape.new(masked: true)).shape_note.should eq("[MASKED]")
      shape_json(captured("in", Shape.new(masked: true))).should eq(%({"masked":true}))
    end

    it "still names an UNMASKED client→server frame" do
      captured("out", Shape.new(masked: false)).shape_note.should eq("[UNMASKED]")
      shape_json(captured("out", Shape.new(masked: false))).should eq(%({"masked":false}))
    end

    it "says nothing about masking that follows §5.1" do
      captured("in", Shape.new(masked: false)).shape_note.should eq("")
      shape_json(captured("in", Shape.new(masked: false))).should eq("{}")
      captured("out", Shape.new(masked: true)).shape_note.should eq("")
      shape_json(captured("out", Shape.new(masked: true))).should eq("{}")
    end

    it "says nothing at all for a pre-V7 row, which does not know" do
      captured("in", Shape.new).shape_note.should eq("")
      shape_json(captured("in", Shape.new)).should eq("{}")
    end

    it "keeps naming the direction-independent departures beside it" do
      note = captured("in", Shape.new(fin: false, rsv: 4, masked: true, frames: 2), 9).shape_note
      note.should eq("[PING fin=0 rsv=4 MASKED 2 frames]")
    end
  end
end
