require "../spec_helper"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# An h1 origin that accepts N connections and records the exact request bytes each one sent,
# replying `200` + `body` and closing. The multi-endpoint race dials one connection per member,
# so it must accept repeatedly.
private def start_h1_race_origin(body : String, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn_with(conn) do |c|
        head = Gori::Proxy::Codec::Http1.read_head(c)
        seen.send(head ? String.new(head) : "")
        c << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        c.flush
        c.close rescue nil
      end
    end
  rescue
  end
  port
end

# A cleartext-h2 origin that speaks N streams on ONE connection — the single-packet target.
# Records the decoded `:path` of every stream and replies `status` + a per-path body once the
# stream ends (END_STREAM on HEADERS or on a DATA frame), closing after `expect` streams.
private def start_h2_race_origin(status : Int32, seen : Channel(String), expect : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    dec = HPACK::Decoder.new
    paths = {} of UInt32 => String
    answered = 0
    loop do
      f = Frame.read(conn)
      break if f.nil?
      ended = false
      case f.frame_type
      when Frame::Type::Headers
        # The client writes the block END_STREAM-clear; CONTINUATION is not exercised here.
        dec.decode(f.payload).each { |(n, v)| paths[f.stream_id] = v if n == ":path" }
        ended = f.end_stream?
      when Frame::Type::Data
        ended = f.end_stream?
      else
        # SETTINGS ack / WINDOW_UPDATE from the client — ignore.
      end
      next unless ended
      path = paths[f.stream_id]? || "?"
      seen.send(path)
      reply = "hit:#{path}"
      sb = HPACK::Encoder.new.encode([{":status", status.to_s}, {"server", "gori-test"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, f.stream_id, sb).to_bytes)
      conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, f.stream_id, reply.to_slice).to_bytes)
      conn.flush
      answered += 1
      break if answered >= expect
    end
    sleep 0.2.seconds
    conn.close rescue nil
  rescue
  end
  port
end

describe "Repeater multi-endpoint race" do
  describe "HTTP/1.1 last-byte sync (Engine.race_h1)" do
    it "puts N distinct requests on N connections and returns a result per member" do
      seen = Channel(String).new(4)
      port = start_h1_race_origin("pong", seen)

      wires = [
        "GET /apply-coupon HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        "GET /checkout HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      ]
      results = Gori::Repeater::Engine.race_h1(wires,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

      results.size.should eq(2)
      results.all?(&.ok?).should be_true
      results.each { |r| String.new(r.body.not_nil!).should eq("pong") }
      # Each member kept its OWN wire (not one shared buffer, unlike the Fuzzer race).
      results.map { |r| String.new(r.wire.not_nil!) }.should eq(wires.map { |w| String.new(w) })

      got = [seen.receive, seen.receive].map(&.lines.first)
      got.sort.should eq(["GET /apply-coupon HTTP/1.1", "GET /checkout HTTP/1.1"])
    end

    it "refuses the whole release when fewer than 2 connections survive" do
      seen = Channel(String).new(1)
      port = start_h1_race_origin("pong", seen)
      results = Gori::Repeater::Engine.race_h1(
        ["GET /only HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice],
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
      results.size.should eq(1)
      results.first.ok?.should be_false
      results.first.error.not_nil!.should contain("enough live connections")
    end

    it "returns an empty array for an empty group" do
      Gori::Repeater::Engine.race_h1([] of Bytes,
        scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false).should be_empty
    end
  end

  describe "HTTP/2 single-packet (H2Engine.single_packet)" do
    it "opens one stream per member and demultiplexes a response for each" do
      seen = Channel(String).new(4)
      port = start_h2_race_origin(200, seen, expect: 2)

      wires = [
        "GET /apply-coupon HTTP/2\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        "GET /checkout HTTP/2\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      ]
      results = Gori::Repeater::H2Engine.single_packet(wires,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

      results.size.should eq(2)
      results.all?(&.ok?).should be_true
      results.each(&.response.not_nil!.status.should(eq(200)))
      # Per-member body is keyed to that member's own path — proof the demux routed each
      # stream's response back to the right member.
      String.new(results[0].body.not_nil!).should eq("hit:/apply-coupon")
      String.new(results[1].body.not_nil!).should eq("hit:/checkout")

      got = [seen.receive, seen.receive]
      got.sort.should eq(["/apply-coupon", "/checkout"])
    end

    it "refuses the whole release when fewer than 2 streams survive" do
      seen = Channel(String).new(1)
      port = start_h2_race_origin(200, seen, expect: 1)
      results = Gori::Repeater::H2Engine.single_packet(
        ["GET /only HTTP/2\r\nHost: 127.0.0.1\r\n\r\n".to_slice],
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
      results.size.should eq(1)
      results.first.ok?.should be_false
      results.first.error.not_nil!.should contain("enough live streams")
    end
  end
end
