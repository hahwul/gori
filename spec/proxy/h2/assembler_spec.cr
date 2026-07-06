require "../../spec_helper"

private alias Frame = Gori::Proxy::H2::Frame

private def hexb(s : String) : Bytes
  clean = s.gsub(/\s/, "")
  Bytes.new(clean.size // 2) { |i| clean[i * 2, 2].to_u8(16) }
end

private def headers_frame(stream : UInt32, flags : UInt8, block : Bytes) : Frame::Header
  Frame::Header.new(Frame::Type::Headers.value, flags, stream, block)
end

private def data_frame(stream : UInt32, flags : UInt8, body : String) : Frame::Header
  Frame::Header.new(Frame::Type::Data.value, flags, stream, body.to_slice)
end

# Records emitted flows (decoded projection) without a DB.
private class RecSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse
  @id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

describe Gori::Proxy::H2::Assembler do
  it "assembles a request stream into a flow (HPACK-decoded)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "fallback.host", 443, 123_i64)

    # RFC 7541 C.4.1 header block → GET http / www.example.com, with END_STREAM.
    block = hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM, block))

    sink.requests.size.should eq(1)
    req = sink.requests.first
    req.method.should eq("GET")
    req.scheme.should eq("http")
    req.target.should eq("/")
    req.host.should eq("www.example.com")
    req.port.should eq(443)
    req.http_version.should eq("HTTP/2")
    String.new(req.head).should contain("GET / HTTP/2")
    # The h2 `:authority` pseudo-header is rendered as a `Host:` line so the
    # synthesized head carries the target host (else `show` / QL header:host miss it).
    String.new(req.head).should contain("Host: www.example.com")
  end

  it "links a response (HEADERS + DATA) to the request flow" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)

    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))

    # RFC 7541 C.6.1 response header block (status 302, ...), END_HEADERS only.
    resp_block = hexb("48826402 5885aec3771a4b 6196d07abe941054d444a8200595040b8166e082a62d1bff " \
                      "6e919d29ad1718 63c78f0b97c8e9ae82ae43d3")
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, resp_block))
    assembler.feed("in", data_frame(1_u32, Frame::END_STREAM, "hello h2 body"))

    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.status.should eq(302)
    resp.flow_id.should eq(1) # links to the request flow id
    String.new(resp.body.not_nil!).should eq("hello h2 body")
    String.new(resp.head).should contain("HTTP/2 302")
    String.new(resp.head).should contain("location: https://www.example.com")
    # h2 flows must record latency like h1 does — without this, History/QL/`gori
    # run` JSON show a null duration for every (h2-negotiated) HTTPS flow.
    resp.duration_us.should_not be_nil
    resp.duration_us.not_nil!.should be >= 0
    resp.ttfb_us.should_not be_nil # first response HEADERS frame anchors ttfb
  end

  it "carries a request body across DATA frames" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    # POST-like: headers without END_STREAM, then a DATA frame closes the stream.
    assembler.feed("out", headers_frame(3_u32, Frame::END_HEADERS,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.size.should eq(0) # not complete until END_STREAM
    assembler.feed("out", data_frame(3_u32, Frame::END_STREAM, "q=1&x=2"))
    sink.requests.size.should eq(1)
    String.new(sink.requests.first.body.not_nil!).should eq("q=1&x=2")
  end

  it "emits both halves when the response completes before the request body (early response)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)

    # Client sends request HEADERS but keeps streaming its body (no END_STREAM).
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.size.should eq(0)

    # Server responds and closes its half BEFORE the client finished (e.g. 413).
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM, Bytes[0x88_u8]))
    sink.requests.size.should eq(0) # nothing emitted / lost prematurely
    sink.responses.size.should eq(0)

    # Client finally finishes its request body.
    assembler.feed("out", data_frame(1_u32, Frame::END_STREAM, "late upload"))

    sink.requests.size.should eq(1) # was: silently dropped entirely
    sink.responses.size.should eq(1)
    sink.responses.first.flow_id.should eq(1)
    sink.responses.first.status.should eq(200)
  end

  it "flushes a partial response as Aborted when the stream is reset mid-stream" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)

    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.size.should eq(1)
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8])) # 200, no END_STREAM
    assembler.feed("in", data_frame(1_u32, 0_u8, "partial"))                       # DATA, still open
    sink.responses.size.should eq(0)

    # Client cancels the stream (RST_STREAM, error code 8 = CANCEL) mid-stream.
    assembler.feed("in", Frame::Header.new(Frame::Type::RstStream.value, 0_u8, 1_u32, Bytes[0, 0, 0, 8]))

    sink.responses.size.should eq(1) # was: whole response discarded, flow left Pending
    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Aborted)
    String.new(resp.body.not_nil!).should eq("partial")
  end

  it "finalizes an in-flight stream when the connection closes (no permanent Pending)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)

    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8])) # 200, no END_STREAM
    assembler.feed("in", data_frame(1_u32, 0_u8, "chunk1"))                        # server-stream, never ends
    sink.responses.size.should eq(0)

    assembler.finalize_all("h2 connection closed")

    sink.responses.size.should eq(1)
    sink.responses.first.state.should eq(Gori::Store::FlowState::Aborted)
    String.new(sink.responses.first.body.not_nil!).should eq("chunk1")
  end

  it "skips a PADDED DATA frame whose pad length exceeds the payload (no garbage projection)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(5_u32, Frame::END_HEADERS,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff"))) # request headers, stream open
    # PADDED DATA: payload[0]=0xff claims 255 pad bytes, but only 4 data bytes follow.
    bad = Bytes[0xff_u8, 'd'.ord.to_u8, 'a'.ord.to_u8, 't'.ord.to_u8, 'a'.ord.to_u8]
    assembler.feed("out", Frame::Header.new(Frame::Type::Data.value, Frame::PADDED | Frame::END_STREAM, 5_u32, bad))
    sink.requests.size.should eq(0) # malformed pad → frame skipped, not projected as a body
  end

  it "emits the request when END_STREAM (illegally) rides on a CONTINUATION frame" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    block = hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")
    # HEADERS without END_HEADERS (partial block), then CONTINUATION carrying the rest
    # with END_HEADERS|END_STREAM — RFC-illegal, but must not silently drop + leak.
    assembler.feed("out", headers_frame(7_u32, 0_u8, block[0, 4]))
    assembler.feed("out", Frame::Header.new(Frame::Type::Continuation.value,
      Frame::END_HEADERS | Frame::END_STREAM, 7_u32, block[4..]))
    sink.requests.size.should eq(1) # emitted, not dropped
    sink.requests.first.method.should eq("GET")
  end

  it "ignores connection-level frames (stream 0)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty))
    sink.requests.should be_empty
  end

  it "merges h2 trailers into the response (gRPC grpc-status)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "grpc.test", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))

    # initial response HEADERS: :status 200 (static index 8 → indexed field 0x88)
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(1_u32, 0_u8, "msg")) # DATA, no END_STREAM
    # trailers: literal "grpc-status: 0", END_HEADERS|END_STREAM
    trailer = IO::Memory.new
    trailer.write_byte(0x00_u8) # literal w/o indexing, new name
    trailer.write_byte(0x0b_u8) # name length 11
    trailer << "grpc-status"
    trailer.write_byte(0x01_u8) # value length 1
    trailer << "0"
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM, trailer.to_slice))

    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.status.should eq(200)
    String.new(resp.head).should contain("grpc-status: 0") # trailer merged into the head
  end

  it "captures a server push (PUSH_PROMISE → promised-stream flow + response)" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)

    # PUSH_PROMISE on stream 1 promising stream 2, request = GET / www.example.com.
    pp = IO::Memory.new
    pp.write(Bytes[0x00, 0x00, 0x00, 0x02]) # promised stream id = 2
    pp.write(hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff"))
    assembler.feed("in", Frame::Header.new(Frame::Type::PushPromise.value, Frame::END_HEADERS, 1_u32, pp.to_slice))

    sink.requests.size.should eq(1)
    req = sink.requests.first
    req.method.should eq("GET")
    req.host.should eq("www.example.com")
    req.h2_stream_id.should eq(2)

    # the pushed response arrives on the promised (even) stream
    assembler.feed("in", headers_frame(2_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(2_u32, Frame::END_STREAM, "pushed body"))
    sink.responses.size.should eq(1)
    sink.responses.first.status.should eq(200)
    String.new(sink.responses.first.body.not_nil!).should eq("pushed body")
  end
end
