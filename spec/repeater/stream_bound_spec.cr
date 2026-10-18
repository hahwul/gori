require "../spec_helper"
require "../support/sse_origin"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK
private alias StreamBound = Gori::Repeater::StreamBound

private GET = "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice

private def h1_send(port : Int32, bound : StreamBound?) : Gori::Repeater::Result
  Gori::Repeater::Engine.send(GET, scheme: "http", host: "127.0.0.1", port: port,
    verify_upstream: false, timeout: 20.seconds, sse: bound)
end

private def events_in(result : Gori::Repeater::Result) : Int32
  Gori::Sse.from_response(result.head, result.body).size
end

# A cleartext-h2 origin answering stream 1 with an event stream: one DATA frame per event every
# `every`, `events` of them and then END_STREAM, or forever when nil.
private def start_h2_sse_origin(every : Time::Span, events : Int32? = nil,
                                content_type : String = "text/event-stream") : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    begin
      conn.read_timeout = 30.seconds
      Frame.read_preface(conn)
      conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
      loop do
        f = Frame.read(conn)
        break if f.nil?
        break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
      end
      block = HPACK::Encoder.new.encode([{":status", "200"}, {"content-type", content_type}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
      n = 0
      until events && n >= events
        conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, "data: #{n}\n\n".to_slice).to_bytes)
        conn.flush
        n += 1
        sleep every
      end
      conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, Bytes.empty).to_bytes)
      conn.flush
      sleep 0.2.seconds
    rescue
    ensure
      conn.close rescue nil
    end
  end
  port
end

private def h2_send(port : Int32, bound : StreamBound?) : Gori::Repeater::Result
  Gori::Repeater::H2Engine.send(GET, scheme: "http", host: "127.0.0.1", port: port,
    verify_upstream: false, timeout: 20.seconds, sse: bound)
end

describe Gori::Repeater::StreamBound do
  it "resolves a surface's arguments over a default, 0 switching an axis off" do
    send = StreamBound::SEND
    StreamBound.resolve(nil, nil, send).should eq(send)
    StreamBound.resolve(5_i64, nil, send).should eq(StreamBound.new(5, send.max_time))
    StreamBound.resolve(0_i64, 2.seconds, send).should eq(StreamBound.new(nil, 2.seconds))
    StreamBound.resolve(0_i64, Time::Span.zero, send).should be_nil
  end

  describe "on the h1 engine" do
    it "stops a chunked stream at the event bound and keeps those events" do
      result = h1_send(start_sse_origin, StreamBound.new(3, nil))
      result.ok?.should be_true
      result.bounded.should eq("events")
      result.incomplete?.should be_true # the socket still carries the rest
      result.timed_out?.should be_false
      events_in(result).should eq(3)
    end

    it "stops a close-delimited stream at the event bound" do
      result = h1_send(start_sse_origin(chunked: false), StreamBound.new(4, nil))
      result.bounded.should eq("events")
      events_in(result).should eq(4)
    end

    # The origin sends nothing after the head, so this is the read the time bound has to wake.
    it "stops at the time bound even while a read is blocked" do
      started = Time.instant
      result = h1_send(start_sse_origin(every: 10.seconds), StreamBound.new(nil, 300.milliseconds))
      (Time.instant - started).should be < 3.seconds
      result.ok?.should be_true
      result.bounded.should eq("time")
      result.timed_out?.should be_false
      events_in(result).should eq(1)
    end

    it "leaves a stream that ends before the bound complete" do
      result = h1_send(start_sse_origin(events: 2), StreamBound.new(5, 5.seconds))
      result.bounded.should be_nil
      result.incomplete?.should be_false
      events_in(result).should eq(2)
    end

    it "ignores the bound on a response that is not an event stream" do
      result = h1_send(start_sse_origin(content_type: "text/plain", events: 6), StreamBound.new(2, 5.seconds))
      result.bounded.should be_nil
      result.incomplete?.should be_false
      String.new(Gori::Proxy::Codec::ContentDecode.dechunk(result.body.not_nil!)).scan("data: x").size.should eq(6)
    end
  end

  describe "on the h2 engine" do
    it "stops at the event bound and keeps those events" do
      result = h2_send(start_h2_sse_origin(10.milliseconds), StreamBound.new(3, nil))
      result.ok?.should be_true
      result.bounded.should eq("events")
      result.incomplete?.should be_true
      result.timed_out?.should be_false
      events_in(result).should eq(3)
    end

    it "stops at the time bound even while a read is blocked" do
      started = Time.instant
      result = h2_send(start_h2_sse_origin(10.seconds), StreamBound.new(nil, 300.milliseconds))
      (Time.instant - started).should be < 3.seconds
      result.ok?.should be_true
      result.bounded.should eq("time")
      result.timed_out?.should be_false
      events_in(result).should eq(1)
    end

    it "ignores the bound on a response that is not an event stream" do
      result = h2_send(start_h2_sse_origin(10.milliseconds, events: 5, content_type: "text/plain"),
        StreamBound.new(2, 5.seconds))
      result.bounded.should be_nil
      result.incomplete?.should be_false
      String.new(result.body.not_nil!).scan("data:").size.should eq(5)
    end
  end

  describe "through Fuzz::Sender's pool" do
    # One payload against an SSE endpoint used to cost the whole idle timeout.
    it "finishes each send at the bound and does not park the stream's socket" do
      port = start_sse_origin
      sender = Gori::Fuzz::Sender.new(Gori::Fuzz::Origin.new("http", "127.0.0.1", port),
        ungated_outbound, false, false, timeout: 20.seconds, keep_alive: true, idle_conns: 1,
        sse: StreamBound.new(2, 5.seconds))
      started = Time.instant
      2.times do
        r = sender.send(GET)
        r.bounded.should eq("events")
        events_in(r).should eq(2)
      end
      (Time.instant - started).should be < 5.seconds
      sender.pool.not_nil!.dialed.should eq(2)
    end

    # A bounded row must not read "origin closed" on either surface's fuzz row.
    it "carries the bound onto the fuzz row both surfaces word it from" do
      port = start_sse_origin
      sender = Gori::Fuzz::Sender.new(Gori::Fuzz::Origin.new("http", "127.0.0.1", port),
        ungated_outbound, false, false, timeout: 20.seconds, sse: StreamBound.new(2, 5.seconds))
      row = Gori::Fuzz::Matcher.new.build(Gori::Fuzz::Job.new(0_i64, ["p"], nil, GET), sender.send(GET))
      row.bounded.should eq("events")
      Gori::CLI::Output.fuzz_row_text(row).should contain("event bound")
      json = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.fuzz_result(j, row) })
      json["incomplete_reason"].as_s.should contain("event bound")
    end

    it "is bounded by default on a Fuzzer and a Miner run" do
      Gori::Fuzz::Config.new.sse.should eq(StreamBound::SWEEP)
      Gori::Miner::Config.new.sse.should eq(StreamBound::SWEEP)
    end
  end
end

# The TUI's sink (#1631): no axis, a `LiveBody`, and the send's cancel as the only bound.
describe Gori::Repeater::LiveBody do
  # Stops the stream once `n` events have arrived, the way the Repeater's Stop does.
  stop_after = ->(live : Gori::Repeater::LiveBody, n : Int32) do
    spawn do
      until (head = live.head) && Gori::Sse.from_response(head, live.result(Time.instant).try(&.body)).size >= n
        sleep 10.milliseconds
      end
      live.stop
    end
  end

  it "follows an h1 stream and keeps it whole when stopped" do
    live = Gori::Repeater::LiveBody.new
    stop_after.call(live, 3)
    result = Gori::Repeater::Engine.send(GET, scheme: "http", host: "127.0.0.1", port: start_sse_origin,
      verify_upstream: false, timeout: 20.seconds, cancel: -> { live.stopped? },
      sse: StreamBound.new(live: live))
    result.ok?.should be_true
    result.bounded.should eq("cancelled")
    events_in(result).should be >= 3
    live.head.should eq(result.head)
    live.result(Time.instant).not_nil!.body.should eq(result.body)
  end

  it "follows an h2 stream and keeps it whole when stopped" do
    live = Gori::Repeater::LiveBody.new
    stop_after.call(live, 3)
    result = Gori::Repeater::H2Engine.send(GET, scheme: "http", host: "127.0.0.1",
      port: start_h2_sse_origin(10.milliseconds), verify_upstream: false, timeout: 20.seconds,
      cancel: -> { live.stopped? }, sse: StreamBound.new(live: live))
    result.ok?.should be_true
    result.bounded.should eq("cancelled")
    events_in(result).should be >= 3
    live.head.should eq(result.head)
    live.result(Time.instant).not_nil!.body.should eq(result.body)
  end

  it "stays closed on a response that is not an event stream" do
    live = Gori::Repeater::LiveBody.new
    result = h1_send(start_sse_origin(content_type: "text/plain", events: 2), StreamBound.new(live: live))
    result.ok?.should be_true
    live.head.should be_nil
    live.size.should eq(0)
    live.result(Time.instant).should be_nil
  end
end
