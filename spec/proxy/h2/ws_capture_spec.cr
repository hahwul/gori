require "../../spec_helper"

# RFC 8441 extended CONNECT — a WebSocket opened over HTTP/2 (#733).
#
# The relay always worked: the CONNECT stream's DATA frames go out byte-for-byte, and gori
# relays the origin's SETTINGS (SETTINGS_ENABLE_CONNECT_PROTOCOL included) verbatim, so a
# browser facing an 8441 origin is entitled to take this path. What did not work is everything
# above the wire — the socket landed as one opaque DATA blob capped at `Settings.capture_max`,
# so there were no `ws_messages` rows at all. These cover the transcript that replaces it.
#
# The axis every one of them turns on: **a DATA frame boundary and a WebSocket frame boundary
# are unrelated.** A frame straddles two DATA frames as readily as ten frames share one, so the
# reader has to be a stream reassembler and the specs feed it accordingly.
private alias Frame = Gori::Proxy::H2::Frame
private alias WS = Gori::Proxy::WS

private def headers_frame(stream : UInt32, flags : UInt8, block : Bytes) : Frame::Header
  Frame::Header.new(Frame::Type::Headers.value, flags, stream, block)
end

private def data_frame(stream : UInt32, flags : UInt8, body : Bytes) : Frame::Header
  Frame::Header.new(Frame::Type::Data.value, flags, stream, body)
end

private def hpack(fields : Array({String, String})) : Bytes
  Gori::Proxy::H2::HPACK::Encoder.new.encode(fields)
end

# An RFC 8441 extended CONNECT request head. `protocol` is the `:protocol` pseudo-header, the
# whole of what distinguishes this from an ordinary CONNECT tunnel.
private def connect_block(protocol : String = "websocket") : Bytes
  hpack([{":method", "CONNECT"}, {":protocol", protocol}, {":scheme", "https"},
         {":path", "/chat"}, {":authority", "ws.example.com"},
         {"sec-websocket-version", "13"}])
end

private def status_block(status : String) : Bytes
  hpack([{":status", status}])
end

# A client→server frame is masked (RFC 6455 §5.3); a server→client one is not (§5.1).
private def ws_out(opcode : UInt8, payload : String, fin : Bool = true) : Bytes
  WS.encode(opcode, payload.to_slice, mask: true, fin: fin)
end

private def ws_in(opcode : UInt8, payload : String, fin : Bool = true) : Bytes
  WS.encode(opcode, payload.to_slice, mask: false, fin: fin)
end

private def cat(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

private record WsRow, flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
  shape : Gori::Proxy::WS::Shape do
  def text : String
    String.new(payload)
  end
end

private class WsSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse
  getter ws = [] of WsRow
  @id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @ws << WsRow.new(flow_id, direction, opcode, payload, shape)
  end

  # The transcript with gori's own `[gori] …` notices taken out — a diagnostic is not traffic,
  # and the frames a peer actually sent are what most of these specs are about.
  def frames : Array(WsRow)
    @ws.reject { |r| Gori::Proxy::WS.notice?(r.payload) }
  end
end

# An armed and ACCEPTED extended CONNECT: request head, then the origin's 200. Every socket
# spec starts here, because a 2xx is what opens the socket (RFC 8441 §5.1).
private def open_socket(sink : WsSink, protocol : String = "websocket",
                        status : String = "200") : Gori::Proxy::H2::Assembler
  assembler = Gori::Proxy::H2::Assembler.new(sink, "ws.example.com", 443, 1_i64)
  assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS, connect_block(protocol)))
  assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, status_block(status)))
  assembler
end

describe Gori::Proxy::H2::WsCapture do
  # The whole point. Before this, both of these frames were bytes inside one `flows.body` blob.
  it "turns an extended CONNECT stream's DATA into a message transcript, both directions" do
    sink = WsSink.new
    a = open_socket(sink)
    a.feed("out", data_frame(1_u32, 0_u8, ws_out(WS::OP_TEXT, "ping from the client")))
    a.feed("in", data_frame(1_u32, 0_u8, ws_in(WS::OP_TEXT, "pong from the origin")))

    rows = sink.frames
    rows.size.should eq(2)
    rows[0].direction.should eq("out")
    rows[0].opcode.should eq(WS::OP_TEXT.to_i)
    # The captured payload is UNMASKED — capture is the readable projection, and the §5.3 mask
    # is a wire fact the shape records instead.
    rows[0].text.should eq("ping from the client")
    rows[0].shape.masked.should be_true
    rows[1].direction.should eq("in")
    rows[1].text.should eq("pong from the origin")
    rows[1].shape.masked.should be_false
  end

  # The reassembly property, stated as harshly as it can be: one byte per DATA frame. A
  # per-DATA-frame parser reads nothing at all here, and a parser that does not rewind on a
  # short header eats the header's first bytes and desyncs for the life of the socket.
  it "reassembles a message whose frame is split one byte per DATA frame" do
    sink = WsSink.new
    a = open_socket(sink)
    wire = ws_in(WS::OP_TEXT, "straddled across every boundary")
    wire.each { |b| a.feed("in", data_frame(1_u32, 0_u8, Bytes[b])) }

    sink.frames.size.should eq(1)
    sink.frames.first.text.should eq("straddled across every boundary")
  end

  # ... and the other way round: many WebSocket frames inside ONE DATA frame.
  it "reads several WebSocket frames out of a single DATA frame" do
    sink = WsSink.new
    a = open_socket(sink)
    a.feed("in", data_frame(1_u32, 0_u8, cat(
      ws_in(WS::OP_TEXT, "one"), ws_in(WS::OP_TEXT, "two"), ws_in(WS::OP_TEXT, "three"))))

    sink.frames.map(&.text).should eq(["one", "two", "three"])
  end

  # A fragmented message is ONE row, and the row says it was fragmented — the same fact the h1
  # path records, from the same `MessageShape` accumulator.
  it "reassembles a fragmented message into one row that reports its frame count" do
    sink = WsSink.new
    a = open_socket(sink)
    a.feed("in", data_frame(1_u32, 0_u8, cat(
      ws_in(WS::OP_TEXT, "frag", fin: false), ws_in(WS::OP_CONT, "mented"))))

    sink.frames.size.should eq(1)
    sink.frames.first.text.should eq("fragmented")
    sink.frames.first.shape.frames.should eq(2)
    sink.frames.first.shape.fin.should be_true
  end

  # Control frames are the diagnostic half of a WebSocket transcript: a CLOSE carries the code
  # and reason, which is the single most useful thing a failed socket produces.
  it "captures control frames, CLOSE code included" do
    sink = WsSink.new
    a = open_socket(sink)
    a.feed("in", data_frame(1_u32, 0_u8, cat(
      ws_in(WS::OP_PING, "keepalive"), ws_in(WS::OP_CLOSE, "\u{03}\u{e8}going away"))))

    rows = sink.frames
    rows.size.should eq(2)
    rows[0].opcode.should eq(WS::OP_PING.to_i)
    rows[1].opcode.should eq(WS::OP_CLOSE.to_i)
    rows[1].text.should contain("going away")
  end

  # A message whose FIN never arrives still reaches the transcript at teardown — gori saw those
  # fragments, so dropping them would make the transcript disagree with the raw frame log it is
  # derived from (P7). The h1 pump's own `ensure` does exactly this.
  it "flushes an unterminated message when the connection closes" do
    sink = WsSink.new
    a = open_socket(sink)
    a.feed("in", data_frame(1_u32, 0_u8, ws_in(WS::OP_TEXT, "never finished", fin: false)))
    sink.frames.should be_empty # nothing to emit yet: the message is still open
    a.finalize_all("h2 connection closed")

    sink.frames.size.should eq(1)
    sink.frames.first.text.should eq("never finished")
    sink.frames.first.shape.fin.should be_false # ... and the row says the FIN never came
  end

  # The flow has to exist WHILE the socket is live, or the rows have nothing to hang on. A
  # CONNECT stream's request half never half-closes until the socket ends, so the projection
  # cannot wait for END_STREAM the way every other h2 stream's does.
  it "projects the flow at the request head so the transcript has a flow to attach to" do
    sink = WsSink.new
    a = open_socket(sink)
    sink.requests.size.should eq(1)
    sink.responses.size.should eq(1) # ... and the 200, the way the h1 path records its 101
    a.feed("in", data_frame(1_u32, 0_u8, ws_in(WS::OP_TEXT, "live")))
    sink.frames.first.flow_id.should eq(sink.requests.size.to_i64)
  end

  # An origin that CLOSES its half first must not take the stream with it: the client's own
  # CLOSE frame is still in flight, and it is half of the §7.1.1 closing handshake.
  it "keeps reading the client's half after the origin ends its own" do
    sink = WsSink.new
    a = open_socket(sink)
    a.feed("in", data_frame(1_u32, Frame::END_STREAM, ws_in(WS::OP_CLOSE, "\u{03}\u{e8}")))
    a.feed("out", data_frame(1_u32, Frame::END_STREAM, ws_out(WS::OP_CLOSE, "\u{03}\u{e8}")))

    sink.frames.map(&.direction).should eq(["in", "out"])
    sink.responses.last.state.should eq(Gori::Store::FlowState::Complete)
  end

  # The origin REFUSED the socket. What follows on that stream is an ordinary error body, not
  # RFC 6455 framing — pointing the codec at it would invent messages out of HTML.
  it "does not read frames off an extended CONNECT the origin refused" do
    sink = WsSink.new
    a = open_socket(sink, status: "403")
    a.feed("in", data_frame(1_u32, Frame::END_STREAM, "<html>no websockets here</html>".to_slice))

    sink.ws.should be_empty
    String.new(sink.responses.last.body.not_nil!).should contain("no websockets here")
  end

  # Recognition is by the `:protocol` TOKEN. An extended CONNECT can carry `connect-udp`
  # (RFC 9298) or `connect-ip` (RFC 9484), and those are not WebSocket framing at all.
  it "leaves a non-WebSocket :protocol as opaque DATA and says so" do
    sink = WsSink.new
    a = open_socket(sink, protocol: "connect-udp")
    a.feed("in", data_frame(1_u32, Frame::END_STREAM, ws_in(WS::OP_TEXT, "not a ws frame")))
    # Nothing armed it, so the flow is projected where every other h2 stream's is: at the
    # request half-close, which for a CONNECT means the end of the tunnel.
    a.feed("out", data_frame(1_u32, Frame::END_STREAM, Bytes.empty))

    sink.ws.should be_empty
    advisory = sink.requests.first.advisory.not_nil!
    advisory.should contain("not WebSocket framing")
    advisory.should contain("no message transcript")
  end

  # The advisory is the only place an operator learns what gori could and could not do here.
  # Capture-only is the honest scope (a per-message hold would have to re-frame a DATA payload
  # to a different length, which deadlocks on flow control — #492 step 5), so it has to say
  # BOTH halves rather than the pre-#733 "no transcript" or a bare "WebSocket captured".
  it "advises that the transcript exists but intercept and Match&Replace do not" do
    sink = WsSink.new
    open_socket(sink)
    advisory = sink.requests.first.advisory.not_nil!
    advisory.should contain("RFC 8441 extended CONNECT")
    advisory.should contain("gori read its frames")
    advisory.should contain("Match&Replace are NOT available")
    advisory.should_not contain("no message transcript")
  end

  # A reassembler holds up to one frame plus one message per direction, and h2 lets ONE
  # connection open a great many streams. Past the ceiling a stream keeps exactly the pre-#733
  # disposition — opaque DATA — and the advisory says which one it got, rather than the
  # capture quietly being absent.
  it "bounds concurrent transcripts per connection and names the stream that missed out" do
    sink = WsSink.new
    a = Gori::Proxy::H2::Assembler.new(sink, "ws.example.com", 443, 1_i64)
    max = Gori::Proxy::H2::WsCapture::MAX_STREAMS
    ids = (0..max).map { |i| (i * 2 + 1).to_u32 }
    ids.each do |id|
      a.feed("out", headers_frame(id, Frame::END_HEADERS, connect_block))
      a.feed("in", headers_frame(id, Frame::END_HEADERS, status_block("200")))
      a.feed("in", data_frame(id, 0_u8, ws_in(WS::OP_TEXT, "hello #{id}")))
    end
    # The ceiling is about CONCURRENT sockets, so every one of them is still open here; the
    # unarmed stream's flow is projected the ordinary way, at teardown.
    a.finalize_all("h2 connection closed")

    # The first MAX_STREAMS sockets each produced their message; the one past the ceiling did
    # not, and its advisory explains itself instead of going quiet.
    sink.frames.size.should eq(max)
    sink.requests[max].advisory.not_nil!.should contain("no message transcript")
    sink.requests[max].advisory.not_nil!.should contain("already being read on this connection")
  end

  # A capture slot is RELEASED when its stream ends, or a long-lived connection that opens and
  # closes sockets in sequence would run itself out of them.
  it "releases a capture slot when the socket ends" do
    sink = WsSink.new
    a = Gori::Proxy::H2::Assembler.new(sink, "ws.example.com", 443, 1_i64)
    max = Gori::Proxy::H2::WsCapture::MAX_STREAMS
    (0...(max * 3)).each do |i|
      id = (i * 2 + 1).to_u32
      a.feed("out", headers_frame(id, Frame::END_HEADERS, connect_block))
      a.feed("in", headers_frame(id, Frame::END_HEADERS, status_block("200")))
      a.feed("in", data_frame(id, Frame::END_STREAM, ws_in(WS::OP_TEXT, "hi")))
      a.feed("out", data_frame(id, Frame::END_STREAM, ws_out(WS::OP_CLOSE, "\u{03}\u{e8}")))
    end

    sink.frames.count { |r| r.text == "hi" }.should eq(max * 3)
  end

  # An ordinary h2 request on the same connection is untouched: its DATA is still a BODY.
  it "leaves an ordinary stream's DATA as a body" do
    sink = WsSink.new
    a = Gori::Proxy::H2::Assembler.new(sink, "ws.example.com", 443, 1_i64)
    a.feed("out", headers_frame(1_u32, Frame::END_HEADERS,
      hpack([{":method", "POST"}, {":scheme", "https"}, {":path", "/"},
             {":authority", "ws.example.com"}])))
    a.feed("out", data_frame(1_u32, Frame::END_STREAM, "an ordinary body".to_slice))
    a.feed("in", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM, status_block("200")))

    sink.ws.should be_empty
    String.new(sink.requests.first.body.not_nil!).should eq("an ordinary body")
  end
end
