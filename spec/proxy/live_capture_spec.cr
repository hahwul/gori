require "../spec_helper"

# Records each live append; refuses the next `refuse` of them, as a saturated writer would.
private class LiveSink < Gori::Proxy::FlowSink
  getter appends = [] of {Int64, String, Bool}
  getter times = [] of {Int32, Array(Int64)}
  property refuse = 0

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end

  def on_live_body(flow_id : Int64, off : Int64, bytes : Bytes, head : Gori::Store::CapturedResponse?,
                   first : Int32, times : Bytes) : Bool
    if @refuse > 0
      @refuse -= 1
      return false
    end
    @appends << {off, String.new(bytes), !head.nil?}
    @times << {first, Gori::Sse::Arrivals.unpack(times)} unless times.empty?
    true
  end

  # The appended bytes in offset order, which is what `get_flow` concatenates.
  def body : String
    @appends.sort_by(&.[0]).map(&.[1]).join
  end
end

private def live_head : Gori::Store::CapturedResponse
  Gori::Store::CapturedResponse.new(flow_id: 7_i64, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice,
    state: Gori::Store::FlowState::Pending)
end

# Timed by default, as every stream the proxy can count is; `arrivals: nil` is a compressed one.
private def live_capture(sink : LiveSink, limit : Int32 = 1 << 20,
                         arrivals : Gori::Sse::Arrivals? = Gori::Sse::Arrivals.new(chunked: false)) : Gori::Proxy::LiveCapture
  Gori::Proxy::LiveCapture.new(limit, 0_i64, sink, live_head, arrivals)
end

describe Gori::Proxy::LiveCapture do
  it "sends the head alone at once, the first event at once, and batches the rest" do
    sink = LiveSink.new
    cap = live_capture(sink)
    sink.appends.should eq([{0_i64, "", true}])
    cap.write("data: one\n\n".to_slice)
    sink.appends.size.should eq(2)
    sink.appends.last.should eq({0_i64, "data: one\n\n", false})
    cap.write("data: two\n\n".to_slice) # inside FLUSH_EVERY and under FLUSH_BYTES: held
    sink.appends.size.should eq(2)
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("data: three\n\n".to_slice)
    sink.appends.last.should eq({11_i64, "data: two\n\ndata: three\n\n", false})
    String.new(cap.to_slice).should eq(sink.body)
  end

  it "appends on time only at the end of an event, so a chunk-size line does not hold it back" do
    sink = LiveSink.new
    cap = live_capture(sink, arrivals: Gori::Sse::Arrivals.new(chunked: true))
    cap.write("b\r\n".to_slice)
    sink.appends.size.should eq(1) # the head only
    cap.write("data: one\n\n".to_slice)
    cap.write("\r\n".to_slice)
    sink.appends.last.should eq({0_i64, "b\r\ndata: one\n\n", false})
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("d\r\n".to_slice)
    cap.write("data: two\r\n\r\n".to_slice)
    sink.appends.last.should eq({14_i64, "\r\nd\r\ndata: two\r\n\r\n", false})
  end

  it "appends once FLUSH_BYTES are pending, without waiting for the clock" do
    sink = LiveSink.new
    cap = live_capture(sink)
    cap.write("a".to_slice)
    sink.appends.size.should eq(1) # no event has ended
    cap.write(Bytes.new(Gori::Proxy::LiveCapture::FLUSH_BYTES, 'b'.ord.to_u8))
    sink.appends.size.should eq(2)
    sink.appends.last[1].bytesize.should eq(Gori::Proxy::LiveCapture::FLUSH_BYTES + 1)
  end

  it "stops appending at the capture cap" do
    sink = LiveSink.new
    cap = live_capture(sink, limit: 32)
    cap.write("data: aaaaaaaaaa\n\n".to_slice)
    cap.write("data: bbbbbbbbbb\n\n".to_slice)
    cap.truncated?.should be_true
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("data: cccccccccc\n\n".to_slice)
    sink.body.should eq(String.new(cap.to_slice))
    sink.body.bytesize.should eq(32)
    appended = sink.appends.size
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("data: dddddddddd\n\n".to_slice)
    cap.write(Bytes.new(Gori::Proxy::LiveCapture::FLUSH_BYTES, 'e'.ord.to_u8))
    sink.appends.size.should eq(appended)
  end

  it "resends a dropped append inside the next one, leaving no gap" do
    sink = LiveSink.new
    sink.refuse = 1 # the head
    cap = live_capture(sink)
    sink.appends.should be_empty
    sink.refuse = 1 # and the first event
    cap.write("data: one\n\n".to_slice)
    sink.appends.should be_empty
    # A drop waits out FLUSH_EVERY: no copy of the pending bytes on every write.
    cap.write(Bytes.new(Gori::Proxy::LiveCapture::FLUSH_BYTES, 'x'.ord.to_u8))
    sink.appends.should be_empty
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("data: two\n\n".to_slice)
    sink.appends.size.should eq(1)
    off, _, head = sink.appends.first
    off.should eq(0)
    head.should be_true # the head rides the first append that was taken
    sink.body.should eq(String.new(cap.to_slice))
  end

  # #1631: the arrivals ride the appends, numbered so the store can join them.
  it "carries each event's arrival with the append that holds it, and all of them at the end" do
    sink = LiveSink.new
    cap = live_capture(sink, arrivals: Gori::Sse::Arrivals.new(chunked: false))
    cap.write("data: one\n\n".to_slice)
    sink.times.size.should eq(1)
    sink.times[0][0].should eq(0)
    sink.refuse = 1 # a saturated writer drops the next append, times and all
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("data: two\n\n".to_slice)
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("data: three\n\n".to_slice)
    first, times = sink.times.last
    first.should eq(1)
    times.size.should eq(2) # two and three, resent together
    all = Gori::Sse::Arrivals.unpack(cap.event_times.not_nil!)
    all.size.should eq(3)
    (all[1] - all[0]).should be >= Gori::Proxy::LiveCapture::FLUSH_EVERY.total_microseconds.to_i64
  end

  it "times only the events the capture cap kept" do
    sink = LiveSink.new
    cap = live_capture(sink, limit: 20, arrivals: Gori::Sse::Arrivals.new(chunked: false))
    cap.write("data: aaaaaaaaaa\n\n".to_slice) # 18 bytes
    cap.write("data: bbbbbbbbbb\n\n".to_slice) # cut at 20
    Gori::Sse::Arrivals.unpack(cap.event_times.not_nil!).size.should eq(1)
  end

  it "has no times for an untimed stream" do
    live_capture(LiveSink.new, arrivals: nil).event_times.should be_nil
  end

  it "appends an event whose blank line arrives in a write of its own" do
    sink = LiveSink.new
    cap = live_capture(sink)
    cap.write("data: one\n".to_slice)
    sink.appends.size.should eq(1) # the head only: no event has ended
    cap.write("\n".to_slice)
    sink.appends.last.should eq({0_i64, "data: one\n\n", false})
  end

  # A compressed stream's bytes almost never hold a blank line, so it appends on time alone,
  # skipping only a write of chunk framing (which ends in a line end).
  it "appends a compressed stream on time, not on its chunk framing" do
    sink = LiveSink.new
    cap = live_capture(sink, arrivals: nil)
    deflated = Bytes.new(26) { |i| (0x20 + i).to_u8 }
    cap.write("1a\r\n".to_slice)
    sink.appends.size.should eq(1) # the head only
    cap.write(deflated)
    sink.appends.size.should eq(2)
    cap.write("\r\n".to_slice)
    sleep Gori::Proxy::LiveCapture::FLUSH_EVERY + 20.milliseconds
    cap.write("1a\r\n".to_slice)
    sink.appends.size.should eq(2)
    cap.write(deflated)
    sink.appends.size.should eq(3)
    sink.body.should eq(String.new(cap.to_slice))
  end
end

# A StoreSink that also notes which responses arrived as live captures.
private class FlagSink < Gori::Proxy::StoreSink
  getter live = [] of Bool

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @live << resp.live?
    super
  end
end

# An origin that sends one event, waits for `release`, then a second and ends the chunked body.
private def slow_sse_origin(release : Channel(Nil), content_type : String) : {Int32, TCPServer}
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    if conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nTransfer-Encoding: chunked\r\n\r\n"
      conn << "b\r\ndata: one\n\n\r\n"
      conn.flush
      release.receive
      conn << "b\r\ndata: two\n\n\r\n0\r\n\r\n"
      conn.flush
      sleep 200.milliseconds
      conn.close rescue nil
    end
  rescue
  end
  {origin.local_address.port, origin}
end

private def wait_for(within : Time::Span = 3.seconds, &) : Bool
  deadline = Time.instant + within
  until yield
    return false if Time.instant > deadline
    sleep 10.milliseconds
  end
  true
end

private def live_rows(store : Gori::Store) : Int64
  store.@db.scalar("SELECT COUNT(*) FROM flow_live_chunks").as(Int64)
end

# Runs one slow stream through the proxy into `store`; yields the flow id while the first event
# is the only one sent, then finishes the stream and returns the id.
private def proxy_slow_stream(store : Gori::Store, sink : Gori::Proxy::FlowSink, content_type : String, &) : Int64
  release = Channel(Nil).new(1)
  origin_port, origin = slow_sse_origin(release, content_type)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
  proxy.start
  client = TCPSocket.new("127.0.0.1", proxy.port)
  client.read_timeout = 5.seconds
  client << "GET /stream HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
  client.flush
  got = IO::Memory.new
  buf = Bytes.new(1024)
  until got.to_s.includes?("one")
    n = client.read(buf)
    break if n == 0
    got.write(buf[0, n])
  end
  id = store.@db.scalar("SELECT MAX(id) FROM flows").as(Int64)
  yield id
  release.send(nil)
  until got.to_s.includes?("two")
    n = client.read(buf)
    break if n == 0
    got.write(buf[0, n])
  end
  wait_for { store.get_flow(id).try { |d| !d.row.state.pending? } }.should be_true
  client.close
  proxy.stop
  origin.close rescue nil
  id
end

describe "live SSE capture through the proxy (#1631)" do
  it "shows an HTTP/1.1 event stream's events while it is open, and the canonical body after" do
    with_store do |store|
      sink = FlagSink.new(store)
      id = proxy_slow_stream(store, sink, "text/event-stream") do |open_id|
        wait_for { store.get_flow(open_id).try(&.response_body) }.should be_true
        detail = store.get_flow(open_id).not_nil!
        detail.row.state.should eq(Gori::Store::FlowState::Pending)
        detail.row.status.should eq(200)
        detail.row.content_type.should eq("text/event-stream")
        String.new(detail.response_body.not_nil!).should contain("data: one")
        String.new(detail.response_body.not_nil!).should_not contain("data: two")
        Gori::Sse.from_response(detail.response_head, detail.response_body).map(&.data).should eq(["one"])
      end
      live_rows(store).should eq(0)
      live_body = store.get_flow(id).not_nil!.response_body.not_nil!

      # The same bytes as text/plain take the ordinary capture, and store the same body.
      plain_id = proxy_slow_stream(store, sink, "text/plain") do |open_id|
        store.get_flow(open_id).not_nil!.response_body.should be_nil
      end
      store.get_flow(plain_id).not_nil!.response_body.not_nil!.should eq(live_body)
      sink.live.should eq([true, false])
    end
  end

  it "times an HTTP/1.1 event stream's events while it is open, and keeps the times after close" do
    with_store do |store|
      id = proxy_slow_stream(store, Gori::Proxy::StoreSink.new(store), "text/event-stream") do |open_id|
        wait_for { store.live_event_count(open_id) == 1 }.should be_true
        sleep 150.milliseconds # the origin's second event comes after this
      end
      live_rows(store).should eq(0)
      times = store.get_flow(id).not_nil!.event_times.should_not be_nil
      times.size.should eq(2)
      (times[1] - times[0]).should be >= 150_000
    end
  end

  it "shows an HTTP/2 event stream's events while it is open, and the canonical body after" do
    with_store do |store|
      sink = FlagSink.new(store)
      assembler = Gori::Proxy::H2::Assembler.new(sink, "h2.test", 443)
      encoder = Gori::Proxy::H2::HPACK::Encoder.new
      request = encoder.encode([{":method", "GET"}, {":scheme", "https"}, {":path", "/events"},
                                {":authority", "h2.test"}])
      assembler.feed("out", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS | Gori::Proxy::H2::Frame::END_STREAM, 1_u32, request))
      response = Gori::Proxy::H2::HPACK::Encoder.new.encode([{":status", "200"},
                                                             {"content-type", "text/event-stream"}])
      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS, 1_u32, response))
      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Data.value,
        0_u8, 1_u32, "data: one\n\n".to_slice))
      store.flush

      id = store.@db.scalar("SELECT MAX(id) FROM flows").as(Int64)
      detail = store.get_flow(id).not_nil!
      detail.row.state.should eq(Gori::Store::FlowState::Pending)
      detail.row.status.should eq(200)
      String.new(detail.response_body.not_nil!).should eq("data: one\n\n")

      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Data.value,
        Gori::Proxy::H2::Frame::END_STREAM, 1_u32, "data: two\n\n".to_slice))
      store.flush
      live_rows(store).should eq(0)
      detail = store.get_flow(id).not_nil!
      detail.row.state.should eq(Gori::Store::FlowState::Complete)
      String.new(detail.response_body.not_nil!).should eq("data: one\n\ndata: two\n\n")
      sink.live.should eq([true])
    end
  end

  it "times an HTTP/2 event stream's events while it is open, and keeps the times after close" do
    with_store do |store|
      assembler = Gori::Proxy::H2::Assembler.new(Gori::Proxy::StoreSink.new(store), "h2.test", 443)
      request = Gori::Proxy::H2::HPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "https"},
                                                            {":path", "/events"}, {":authority", "h2.test"}])
      assembler.feed("out", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS | Gori::Proxy::H2::Frame::END_STREAM, 1_u32, request))
      response = Gori::Proxy::H2::HPACK::Encoder.new.encode([{":status", "200"},
                                                             {"content-type", "text/event-stream"}])
      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS, 1_u32, response))
      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Data.value,
        0_u8, 1_u32, "data: one\n\n".to_slice))
      store.flush
      id = store.@db.scalar("SELECT MAX(id) FROM flows").as(Int64)
      store.live_event_count(id).should eq(1)
      sleep 60.milliseconds
      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Data.value,
        Gori::Proxy::H2::Frame::END_STREAM, 1_u32, "data: two\n\n".to_slice))
      store.flush
      times = store.get_flow(id).not_nil!.event_times.should_not be_nil
      times.size.should eq(2)
      (times[1] - times[0]).should be >= 60_000
    end
  end

  it "does not go live on an HTTP/2 event-stream head that ends the stream" do
    with_store do |store|
      sink = FlagSink.new(store)
      assembler = Gori::Proxy::H2::Assembler.new(sink, "h2.test", 443)
      request = Gori::Proxy::H2::HPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "https"},
                                                            {":path", "/events"}, {":authority", "h2.test"}])
      assembler.feed("out", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS | Gori::Proxy::H2::Frame::END_STREAM, 1_u32, request))
      response = Gori::Proxy::H2::HPACK::Encoder.new.encode([{":status", "204"},
                                                             {"content-type", "text/event-stream"}])
      assembler.feed("in", Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS | Gori::Proxy::H2::Frame::END_STREAM, 1_u32, response))
      store.flush
      sink.live.should eq([false])
    end
  end
end
