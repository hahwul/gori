require "../spec_helper"

private alias WS = Gori::Proxy::WS

private class TruncSink < Gori::Proxy::FlowSink
  getter rows = [] of {String, Int32, Bytes}
  getter shapes = [] of Gori::Proxy::WS::Shape

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << {direction, opcode, payload.dup}
    @shapes << shape
  end
end

private def data_frame(fin : Bool, payload : Bytes) : WS::Frame
  WS::Frame.new(fin, WS::OP_TEXT, payload, Bytes.empty)
end

# The raw forward is byte-exact either way (P7); only the captured PROJECTION is capped at
# MAX_MESSAGE. The oversized-FRAME path already writes a `NOTICE_PREFIX` marker row saying so
# ("too large to capture"), but a message assembled past the cap by FRAGMENTATION used to be
# written with `fin: true` and a plausible payload and nothing else — so a truncated
# transcript was indistinguishable from a complete one. `ws_messages` has no truncation
# column (unlike `CapturedResponse#body_truncated`), hence a row of its own.
describe "WS capture truncation" do
  it "marks a fragmented message that overruns the capture cap" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    # First fragment fills the buffer to just under the cap; the second crosses it.
    head = Bytes.new(WS::Relay::MAX_MESSAGE - 4, 'A'.ord.to_u8)
    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(data_frame(false, head), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)
    sink.rows.should be_empty # no FIN yet, and nothing dropped yet

    tail = Bytes.new(64, 'B'.ord.to_u8)
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, tail), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)

    sink.rows.size.should eq(2)

    notice, payload = sink.rows[0], sink.rows[1]
    WS.notice?(notice[2]).should be_true
    String.new(notice[2]).should contain("truncated")
    # The payload row keeps the captured PREFIX — that is the evidence worth having — and
    # stops exactly at the cap.
    WS.notice?(payload[2]).should be_false
    payload[2].size.should eq(WS::Relay::MAX_MESSAGE)
  end

  # A lone FIN frame with nothing assembled normally skips the buffer; one past the cap must
  # still take the truncating path, so the row stops at MAX_MESSAGE and says so.
  it "marks a single FIN frame that overruns the capture cap on its own" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, Bytes.new(WS::Relay::MAX_MESSAGE + 8, 'A'.ord.to_u8)),
      IO::Memory.new, "in", 1_i64, sink, WS::OP_TEXT, shape)

    sink.rows.size.should eq(2)
    WS.notice?(sink.rows[0][2]).should be_true
    sink.rows[1][2].size.should eq(WS::Relay::MAX_MESSAGE)
  end

  it "hands a single FIN frame's payload over whole, with its shape" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    key = Bytes[1_u8, 2_u8, 3_u8, 4_u8]
    shape.note(true, 4_u8, true, key)
    buf = IO::Memory.new
    WS::Relay.capture_frame(data_frame(true, "whole".to_slice), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape).should be(buf)

    sink.rows.should eq([{"out", 1, "whole".to_slice}])
    sink.shapes[0].frames.should eq(1)
    sink.shapes[0].rsv.should eq(4)
    sink.shapes[0].mask_key.should eq(key)
    shape.frames.should eq(0) # taken, so the next message starts clean
  end

  it "does not mark a message that fits, and emits it once on FIN" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(data_frame(false, "AAA".to_slice), buf, "in", 1_i64, sink,
      WS::OP_TEXT, shape)
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, "BBB".to_slice), buf, "in", 1_i64, sink,
      WS::OP_TEXT, shape)

    sink.rows.size.should eq(1)
    String.new(sink.rows[0][2]).should eq("AAABBB")
  end

  # `MessageShape#take` RESETS the accumulator, so taking it for the notice handed the real
  # payload row a fabricated shape — frames 1, masked nil — losing the fragment count and the
  # masking evidence the shape exists to record. The notice is gori's own row, so it carries
  # the DEFAULT shape like every other NOTICE, and the payload row keeps the message's.
  it "does not spend the message's shape on the notice row" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new
    key = Bytes[1_u8, 2_u8, 3_u8, 4_u8]

    head = Bytes.new(WS::Relay::MAX_MESSAGE - 4, 'A'.ord.to_u8)
    shape.note(false, 0_u8, true, key)
    buf = WS::Relay.capture_frame(data_frame(false, head), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)
    shape.note(true, 0_u8, true, key)
    WS::Relay.capture_frame(data_frame(true, Bytes.new(64, 'B'.ord.to_u8)), buf, "out",
      1_i64, sink, WS::OP_TEXT, shape)

    sink.rows.size.should eq(2)
    payload_shape = sink.shapes[1] # the real message row, emitted after the notice
    payload_shape.frames.should eq(2)
    payload_shape.masked.should be_true
  end

  # An EXACT fill followed by more fragments used to drop every later byte with no notice:
  # nothing is lost on the filling frame, and `remaining` is 0 for all the rest.
  it "marks an overrun when a fragment lands exactly on the cap and more follows" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(
      data_frame(false, Bytes.new(WS::Relay::MAX_MESSAGE, 'A'.ord.to_u8)), buf, "out",
      1_i64, sink, WS::OP_TEXT, shape)
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, Bytes.new(32, 'B'.ord.to_u8)), buf, "out",
      1_i64, sink, WS::OP_TEXT, shape)

    sink.rows.count { |(_, _, p)| WS.notice?(p) }.should eq(1)
  end

  # One notice per MESSAGE, not one per fragment: after the crossing frame every later
  # fragment also drops bytes, and a notice for each would bury the transcript.
  it "marks the overrun exactly once across later fragments" do
    sink = TruncSink.new
    shape = WS::MessageShape.new
    buf = IO::Memory.new

    head = Bytes.new(WS::Relay::MAX_MESSAGE - 4, 'A'.ord.to_u8)
    shape.note(false, 0_u8, false, nil)
    buf = WS::Relay.capture_frame(data_frame(false, head), buf, "out", 1_i64, sink,
      WS::OP_TEXT, shape)

    3.times do
      shape.note(false, 0_u8, false, nil)
      buf = WS::Relay.capture_frame(data_frame(false, Bytes.new(32, 'B'.ord.to_u8)), buf,
        "out", 1_i64, sink, WS::OP_TEXT, shape)
    end
    shape.note(true, 0_u8, false, nil)
    WS::Relay.capture_frame(data_frame(true, Bytes.new(32, 'C'.ord.to_u8)), buf, "out",
      1_i64, sink, WS::OP_TEXT, shape)

    notices = sink.rows.count { |(_, _, p)| WS.notice?(p) }
    notices.should eq(1)
  end
end
