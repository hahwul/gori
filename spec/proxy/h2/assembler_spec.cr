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

# An RFC 8441 extended CONNECT head — `:method CONNECT` with a `:protocol` pseudo-header,
# which is how a WebSocket is opened over HTTP/2. Encoded rather than hard-coded because
# `:protocol` is not in the HPACK static table.
private def connect_block : Bytes
  Gori::Proxy::H2::HPACK::Encoder.new.encode([
    {":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"},
    {":path", "/chat"}, {":authority", "ws.example.com"},
    {"sec-websocket-version", "13"},
  ])
end

# The same shape WITHOUT `:protocol`: an ordinary CONNECT tunnel.
private def plain_connect_block : Bytes
  Gori::Proxy::H2::HPACK::Encoder.new.encode([
    {":method", "CONNECT"}, {":authority", "tunnel.example.com:443"},
  ])
end

# A trailing HEADERS block of `count` DISTINCT literal-without-indexing fields with empty
# values — the cheapest legal way for an origin to hand the assembler a big trailer-name list
# (9 wire bytes each here), and small enough per field that the whole block stays under
# MAX_HEADER_BLOCK and its decoded size under the cumulative MAX_HEADER_LIST cap.
private def distinct_trailer_block(count : Int32) : Bytes
  io = IO::Memory.new
  count.times do |i|
    name = "t%05d" % i
    io.write_byte(0x00_u8) # literal w/o indexing, new name
    io.write_byte(name.bytesize.to_u8)
    io << name
    io.write_byte(0x00_u8) # empty value
  end
  io.to_slice
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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
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

  it "reports the FINAL status, not an interim 1xx, when a 100 precedes the 200" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    # Interim 100 Continue (END_HEADERS, NO END_STREAM): HPACK literal :status = "100".
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS,
      Bytes[0x48_u8, 0x03_u8, 0x31_u8, 0x30_u8, 0x30_u8]))
    # Then the real 200 (static index 8) + body + END_STREAM.
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(1_u32, Frame::END_STREAM, "ok"))

    sink.responses.size.should eq(1)
    sink.responses.first.status.should eq(200) # was: 100 — the interim block merged ahead of the final
    String.new(sink.responses.first.head).should contain("HTTP/2 200")
  end

  # RFC 9113 8.1 forbids pseudo-headers in trailers, so a `:status` arriving AFTER a final
  # response head is a broken or hostile origin — not the interim-1xx handover the replace
  # branch exists for. It used to take that branch anyway: the trailer REPLACED the real
  # head, so the flow reported the trailer's status and lost the head's content-type and
  # Set-Cookie, with `trailer_names.clear` erasing the marker that would have explained it.
  it "does not let a status-bearing TRAILER replace a final response head" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    # A real 200 head carrying a content-type worth losing.
    head = Gori::Proxy::H2::HPACK::Encoder.new.encode([
      {":status", "200"}, {"content-type", "application/grpc"},
    ])
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, head))
    assembler.feed("in", data_frame(1_u32, 0_u8, "body"))
    # Then a trailer block that illegally carries :status alongside grpc-status.
    trailer = Gori::Proxy::H2::HPACK::Encoder.new.encode([
      {":status", "500"}, {"grpc-status", "13"},
    ])
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM, trailer))

    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.status.should eq(200)                               # not the trailer's 500
    String.new(resp.head).should contain("application/grpc") # the real head survives
    String.new(resp.head).should contain("grpc-status")      # the trailer is still recorded
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
    head = String.new(resp.head)
    head.should contain("grpc-status: 0") # trailer merged into the head — that merge is why
    # grpc-status is reachable at all, and it is also why a trailer used to be
    # INDISTINGUISHABLE from a header the origin sent in the head. For gRPC the trailer IS
    # the call's real status, and whether a target treats a trailer as a header is itself a
    # test — so the merge stays and the head now names which fields came from a trailer.
    head.should contain("X-Gori-Trailers: grpc-status")
  end

  it "does not name a trailer when the response had no trailing HEADERS block" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(1_u32, Frame::END_STREAM, "body"))
    String.new(sink.responses.first.head).should_not contain("X-Gori-Trailers")
  end

  # R3-F5. The request side got the merge and not the marker, so `x-req-trailer` read exactly
  # like a header the client sent in its head — a gRPC client-streaming call or a `TE: trailers`
  # probe is the same test on this side as `grpc-status` is on the other.
  it "names REQUEST trailers in the stored request head, as it already did for the response" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "grpc.test", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    assembler.feed("out", data_frame(1_u32, 0_u8, "body"))
    trailer = IO::Memory.new
    trailer.write_byte(0x00_u8)
    trailer.write_byte(0x0d_u8)
    trailer << "x-req-trailer"
    trailer.write_byte(0x03_u8)
    trailer << "yes"
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM, trailer.to_slice))

    head = String.new(sink.requests.first.head)
    head.should contain("x-req-trailer: yes")
    head.should contain("X-Gori-Trailers: x-req-trailer")
  end

  # Complement: the same request WITHOUT a trailing block must be byte-identical to before.
  it "does not name a trailer on a request that had no trailing HEADERS block" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "grpc.test", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    String.new(sink.requests.first.head).should_not contain("X-Gori-Trailers")
  end

  # Trailer names used to be deduped with `Array#includes?`, a linear scan per field, so a
  # block of N distinct names cost N^2/2 String compares — one legal 1 MiB block (~174k
  # names, still under both the per-block and the cumulative cap) measured 39s. That runs
  # inside the Assembler mutex with no IO, so on Crystal's single-threaded scheduler the TUI,
  # every other connection and the Store writer fiber got no turn for the whole of it (P6).
  it "records a large trailer block without a quadratic dedupe scan" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "grpc.test", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))

    block = distinct_trailer_block(60_000)
    block.size.should be < Gori::Proxy::H2::Assembler::MAX_HEADER_BLOCK # accepted whole
    elapsed = Time.measure do
      assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, block))
    end
    elapsed.should be < 10.seconds # was: minutes, all of it inside the mutex

    assembler.feed("in", data_frame(1_u32, Frame::END_STREAM, ""))
    head = String.new(sink.responses.first.head)
    head.should contain("X-Gori-Trailers: t00000, t00001") # the marker keeps arrival order…
    head.should contain("t59999")                          # …and still names every one
  end

  # The membership index has to be cleared with the array it indexes. A final status block
  # REPLACES an interim 1xx head, taking that head's trailer names with it; an index that
  # remembered `grpc-status` from the discarded head would silently suppress it from the real
  # trailer's marker line.
  it "still names a trailer whose name was already recorded against a replaced interim head" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "grpc.test", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    # Interim 100, then a trailer recorded against it.
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS,
      Gori::Proxy::H2::HPACK::Encoder.new.encode([{":status", "100"}])))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS,
      Gori::Proxy::H2::HPACK::Encoder.new.encode([{"grpc-status", "0"}])))
    # The real response replaces the interim head, then carries its own grpc-status trailer.
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(1_u32, 0_u8, "msg"))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      Gori::Proxy::H2::HPACK::Encoder.new.encode([{"grpc-status", "13"}])))

    head = String.new(sink.responses.first.head)
    head.should contain("grpc-status: 13")
    head.should contain("X-Gori-Trailers: grpc-status")
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

    # R3-F4. A promise is the ORIGIN inventing a request. Projected as an ordinary flow it was
    # indistinguishable in History / QL / the Sitemap from one the client made — rows the
    # origin authored, inside the evidence an operator came to read.
    String.new(req.head).should contain("X-Gori-Pushed: server push promised on stream 1")
    # R4: and as DATA on the row, not only as a line inside the head TEXT. History, QL, the
    # Sitemap, MCP `get_flow` and a HAR export all read the row, and none of them parses a
    # stored head looking for a marker.
    req.advisory.not_nil!.should contain("server push")
    req.advisory.not_nil!.should contain("PUSH_PROMISE on stream 1")
    # The response half must not drop it: `update_one` writes the column outright.
    sink.responses.first.advisory.not_nil!.should contain("server push")
  end

  # Complement: a request the client actually sent carries no push marker.
  it "does not mark an ordinary client request as pushed" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    String.new(sink.requests.first.head).should_not contain("X-Gori-Pushed")
    sink.requests.first.advisory.should be_nil
  end

  # `HeadRewrite` runs BEFORE the frame reaches `feed`, so an advisory can arrive for a stream
  # this assembler has never seen. It has to open the entry the way `feed_locked` does, or the
  # statement is dropped for exactly the messages it is about.
  it "records an advisory that arrives BEFORE the stream's first frame" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.note_advisory(1_u32, "a rule could not run here")
    assembler.note_advisory(1_u32, "a rule could not run here") # deduped, not doubled
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.first.advisory.should eq("a rule could not run here")
  end

  # The complement of "opens the entry": stream 0 is the CONNECTION, never a message, so an
  # advisory keyed to it must not mint a phantom stream (`feed` already treats 0 as
  # not-a-stream, and a Slot keyed 0 is the freeze D1 rule 1 forbids).
  it "ignores an advisory for stream 0" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.note_advisory(0_u32, "not about any message")
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.first.advisory.should be_nil
  end

  # R5-F4. gori relays an RFC 8441 extended CONNECT byte-for-byte (it also relays the origin's
  # SETTINGS verbatim, so a client facing an 8441 origin is entitled to send one) — but it
  # decodes nothing on it: the WS transcript, the message gate, intercept and Match&Replace all
  # live on the h1 Upgrade path. The flow used to end as a bare "h2 connection closed", which
  # describes the symptom and not the fact.
  it "names RFC 8441 extended CONNECT on the flow instead of only the symptom" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "ws.test", 443, 1_i64)
    block = IO::Memory.new
    [{":method", "CONNECT"}, {":scheme", "https"}, {":authority", "ws.test"},
     {":path", "/chat"}, {":protocol", "websocket"}].each do |(n, v)|
      block.write_byte(0x00_u8)
      block.write_byte(n.bytesize.to_u8)
      block << n
      block.write_byte(v.bytesize.to_u8)
      block << v
    end
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS, block.to_slice))
    assembler.finalize_all("h2 connection closed")

    err = sink.responses.first.error.not_nil!
    err.should contain("h2 connection closed")
    err.should contain("RFC 8441 extended CONNECT")
    err.should contain("websocket")
    err.should contain("HTTP/1.1 Upgrade path")
  end

  # Complement: an ordinary stream torn down the same way keeps the bare reason.
  it "leaves an ordinary aborted stream's reason alone" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    assembler.finalize_all("h2 connection closed")
    sink.responses.first.error.should eq("h2 connection closed")
  end

  # #409: a CONTINUATION frame with no preceding un-terminated HEADERS is a protocol violation
  # (RFC 9113 §6.10). A hostile peer sends a lone one to FABRICATE a flow on a never-opened
  # stream — after which the real HEADERS that arrive later would be dropped, spoofing gori's
  # view. It must be ignored, and must not open/track the stream.
  it "drops a lone CONTINUATION on a never-opened stream and still emits the real request" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    # A single CONTINUATION with END_HEADERS|END_STREAM, empty payload, on a stream that never
    # had HEADERS — the fabrication primitive.
    assembler.feed("out", Frame::Header.new(Frame::Type::Continuation.value,
      Frame::END_HEADERS | Frame::END_STREAM, 3_u32, Bytes.empty))
    sink.requests.should be_empty # nothing fabricated

    # The genuine request on the same stream id must still be assembled (not shadowed by a phantom).
    assembler.feed("out", headers_frame(3_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.size.should eq(1)
    sink.requests.first.method.should eq("GET")
    sink.requests.first.host.should eq("www.example.com")
  end

  # #409: a CONTINUATION after a header block already ended (END_HEADERS seen) must also drop,
  # not append to / re-emit the finished stream.
  it "drops a CONTINUATION that arrives after the header block already ended" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(5_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.size.should eq(1)
    # A trailing CONTINUATION with a bogus block — awaiting_continuation is already false.
    assembler.feed("out", Frame::Header.new(Frame::Type::Continuation.value,
      Frame::END_HEADERS, 5_u32, Bytes[0x88_u8, 0x88_u8]))
    sink.requests.size.should eq(1) # not re-emitted, not corrupted
  end

  # #412: only HEADERS opens a stream. A flood of frames that never open one (PRIORITY /
  # WINDOW_UPDATE / DATA / RST for an unknown id) must not consume MAX_LIVE_STREAMS slots and
  # blind capture for the rest of the connection.
  it "does not let non-opening frames exhaust the live-stream cap" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    # More WINDOW_UPDATE frames than the cap, each on a distinct unknown (even) stream id.
    (1_u32..1500_u32).each do |i|
      sid = i * 2
      assembler.feed("in", Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, sid,
        Bytes[0_u8, 0_u8, 0_u8, 1_u8]))
    end
    # A genuine request on a fresh odd id must still be tracked and emitted.
    assembler.feed("out", headers_frame(9001_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.size.should eq(1)
    sink.requests.first.method.should eq("GET")
  end
  # --- RFC 8441 extended CONNECT (a WebSocket over h2) ----------------------------------
  #
  # The relay works end to end, and that is exactly the problem these cover: the flow it
  # leaves behind said nothing. `extended_connect_note` hung off `finalize_stream`, which is
  # reached only when a stream ABORTS — so the normal teardown (a WebSocket Close handshake
  # and END_STREAM, what every conforming client does) completed through `emit_ready` with
  # `error` NULL and `advisory` NULL, and `synth_request`'s pseudo filter dropped `:protocol`
  # from the stored head. Nothing on disk — History, the QL, `run show`, HAR, MCP `get_flow` —
  # could identify the flow as a WebSocket that ran with no transcript, no message intercept
  # and no Match&Replace.
  it "advises on a CLEANLY closed extended CONNECT stream, not only on an aborted one" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS, connect_block))
    # The origin accepts, relays frames, and both halves END_STREAM: state Complete.
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(1_u32, Frame::END_STREAM, "\x81\x03one"))
    assembler.feed("out", data_frame(1_u32, Frame::END_STREAM, "\x88\x02\x03\xe8"))

    sink.requests.size.should eq(1)
    # TWO response writes, and deliberately: since #733 the socket's HTTP half is projected the
    # moment the origin's 200 arrives (the way the h1 path records its 101 before the tunnel
    # starts), so the flow does not sit Pending for the socket's whole life while its transcript
    # fills in underneath it. The row is written again at teardown with the final state and the
    # full duration — `update_response` is last-write-wins.
    sink.responses.size.should eq(2)
    resp = sink.responses.last
    resp.state.should eq(Gori::Store::FlowState::Complete)
    resp.error.should be_nil # the stream really did complete — this is not a failure
    # `advisory_of` joins the accumulated set onto BOTH halves, so it survives to the request
    # row and the response row alike (`update_one` writes the column outright).
    sink.requests.first.advisory.not_nil!.should contain("RFC 8441 extended CONNECT")
    sink.requests.first.advisory.not_nil!.should contain(":protocol \"websocket\"")
    # The sentence's second half, which is the one #733 changed: the transcript IS there now,
    # and what is still missing is the per-message hold and Match&Replace. See
    # `spec/proxy/h2/ws_capture_spec.cr` for the transcript itself.
    resp.advisory.not_nil!.should contain("gori read its frames")
    resp.advisory.not_nil!.should contain("Match&Replace are NOT available")
    # ... and the head names the stream shape, which the pseudo filter dropped entirely.
    String.new(sink.requests.first.head).should contain("X-Gori-Protocol: websocket")
  end

  # The same stream ABORTED: the reason on `flows.error` still explains itself (that path is
  # what an operator reads first), and the advisory is there too rather than instead.
  it "keeps the aborted extended CONNECT reason AND writes the advisory" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS, connect_block))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.finalize_all("h2 connection closed")

    # `.last`, not `.first`: the 200 that opened the socket is projected when it arrives (see
    # the spec above), so the ABORT is the second write to the same row.
    resp = sink.responses.last
    resp.state.should eq(Gori::Store::FlowState::Aborted)
    resp.error.not_nil!.should contain("h2 connection closed")
    resp.error.not_nil!.should contain("RFC 8441 extended CONNECT")
    resp.advisory.not_nil!.should contain("RFC 8441 extended CONNECT")
  end

  # The complement that decides whether either of the above means anything: an ordinary
  # CONNECT tunnel — no `:protocol` pseudo — must get NO advisory and NO head marker, or the
  # signal is on every CONNECT and says nothing.
  it "leaves an ordinary CONNECT tunnel unannotated" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS, plain_connect_block))
    assembler.feed("in", headers_frame(1_u32, Frame::END_HEADERS, Bytes[0x88_u8]))
    assembler.feed("in", data_frame(1_u32, Frame::END_STREAM, "bytes"))
    assembler.feed("out", data_frame(1_u32, Frame::END_STREAM, "bytes"))

    sink.requests.first.advisory.should be_nil
    sink.responses.first.advisory.should be_nil
    String.new(sink.requests.first.head).should_not contain("X-Gori-Protocol")
  end

  # ... and neither does an ordinary GET, which is what every other flow on the connection is.
  it "leaves an ordinary request unannotated" do
    sink = RecSink.new
    assembler = Gori::Proxy::H2::Assembler.new(sink, "example.com", 443, 1_i64)
    assembler.feed("out", headers_frame(1_u32, Frame::END_HEADERS | Frame::END_STREAM,
      hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")))
    sink.requests.first.advisory.should be_nil
    String.new(sink.requests.first.head).should_not contain("X-Gori-Protocol")
  end
end
