require "../spec_helper"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# A minimal cleartext-h2 origin: reads the preface + request, records the decoded
# request line and body, then replies SETTINGS + HEADERS(:status) + DATA.
private def start_h2_origin(status : Int32, body : String, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    dec = HPACK::Decoder.new
    method = path = ""
    req_body = IO::Memory.new
    headers_done = false
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        if f.stream_id == 1 && f.end_headers?
          dec.decode(f.payload).each do |(n, v)|
            method = v if n == ":method"
            path = v if n == ":path"
          end
          headers_done = true
          break if f.end_stream?
        end
      when Frame::Type::Data
        req_body.write(f.payload) if f.stream_id == 1
        break if f.end_stream?
      else
        # ignore SETTINGS/WINDOW_UPDATE from the client
      end
    end
    seen.send("#{method} #{path} body=#{req_body}")

    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    status_block = HPACK::Encoder.new.encode([{":status", status.to_s}, {"server", "gori-test"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, status_block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that records the decoded `:authority` pseudo-header of the
# request (so a test can assert what authority the client actually put on the wire).
private def start_h2_origin_authority(status : Int32, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    dec = HPACK::Decoder.new
    authority = "(none)"
    loop do
      f = Frame.read(conn)
      break if f.nil?
      if f.frame_type == Frame::Type::Headers && f.stream_id == 1 && f.end_headers?
        dec.decode(f.payload).each { |(n, v)| authority = v if n == ":authority" }
        break if f.end_stream?
      elsif f.frame_type == Frame::Type::Data && f.end_stream?
        break
      end
    end
    seen.send(authority)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that sends HEADERS(:status) + one DATA frame WITHOUT
# END_STREAM, then drops the connection — a truncated response the client must
# flag as incomplete (no END_STREAM ever arrives).
private def start_h2_origin_truncated(status : Int32, partial : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    block = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
    # DATA WITHOUT END_STREAM, then close mid-stream.
    conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, partial.to_slice).to_bytes)
    conn.flush
    conn.close
  end
  port
end

# A cleartext-h2 origin that ENFORCES flow control: it sends `body` as DATA frames
# but never exceeds the available connection/stream window (both start at the 65535
# default), blocking for the client's WINDOW_UPDATE frames to replenish. A client
# that never sends WINDOW_UPDATE stalls past 65535 bytes (the bug this guards).
private def start_h2_origin_flow_controlled(status : Int32, body : Bytes) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    # drain to the request's END_STREAM (a body-less GET)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type == Frame::Type::Headers && f.stream_id == 1 && f.end_stream?
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.flush

    conn_win = 65535
    stream_win = 65535
    offset = 0
    begin
      while offset < body.size
        while conn_win <= 0 || stream_win <= 0
          f = Frame.read(conn)
          break if f.nil?
          next unless f.frame_type == Frame::Type::WindowUpdate
          inc = (IO::ByteFormat::BigEndian.decode(UInt32, f.payload) & 0x7fff_ffff).to_i
          f.stream_id == 0 ? (conn_win += inc) : (stream_win += inc)
        end
        n = {16384, body.size - offset, conn_win, stream_win}.min
        last = offset + n >= body.size
        conn.write(Frame::Header.new(Frame::Type::Data.value, last ? Frame::END_STREAM : 0_u8, 1_u32, body[offset, n]).to_bytes)
        conn.flush
        conn_win -= n
        stream_win -= n
        offset += n
      end
      sleep 0.2.seconds
    rescue
    end
    conn.close
  end
  port
end

# An origin that interleaves PING frames (no END_STREAM) before the real response — the
# non-terminal-frame path the MAX_FRAMES counter now guards. A handful must be ACKed and
# must NOT stall or corrupt the response.
private def start_h2_origin_pings(status : Int32, body : String, pings : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    pings.times { conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes) }
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

describe Gori::Repeater::H2Engine do
  it "repeaters a GET as real cleartext h2 and reassembles the response" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "replayed!", seen)

    request = "GET /api/thing HTTP/2\r\nx-repeater: yes\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("GET /api/thing body=") # origin saw the HPACK-encoded request
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.head).should contain("HTTP/2 200")
    String.new(result.head).should contain("server: gori-test")
    String.new(result.body.not_nil!).should eq("replayed!")
    result.incomplete?.should be_false # END_STREAM was seen — a complete response
  end

  it "flags an h2 response cut short before END_STREAM as incomplete" do
    port = start_h2_origin_truncated(200, "partial")

    request = "GET /trunc HTTP/2\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true # a status + partial body did arrive
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("partial") # what arrived is captured
    result.incomplete?.should be_true                     # but no END_STREAM — incomplete
  end

  it "sends a request body as DATA frames" do
    seen = Channel(String).new(1)
    port = start_h2_origin(201, "created", seen)

    request = "POST /submit HTTP/2\r\ncontent-type: text/plain\r\n\r\nhello-h2-body".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("POST /submit body=hello-h2-body")
    result.response.not_nil!.status.should eq(201)
    String.new(result.body.not_nil!).should eq("created")
  end

  it "handles interleaved PING frames before the response without stalling" do
    port = start_h2_origin_pings(200, "pong-ok", 20)
    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("pong-ok")
  end

  it "maps an edited Host header to :authority (h1↔h2 parity for host-confusion probes)" do
    seen = Channel(String).new(1)
    port = start_h2_origin_authority(200, seen)

    # Connect to 127.0.0.1 but CLAIM a different authority via the Host header — the
    # h2 engine must send :authority = the edited Host, not the dialed target.
    request = "GET / HTTP/2\r\nHost: victim.internal\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("victim.internal")
    result.ok?.should be_true
  end

  it "falls back to the dialed host for :authority when no Host header is present" do
    seen = Channel(String).new(1)
    port = start_h2_origin_authority(200, seen)

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("127.0.0.1:#{port}")
    result.ok?.should be_true
  end

  it "reports an error when the origin is unreachable" do
    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    result.ok?.should be_false
    result.error.should_not be_nil
  end

  it "credits flow-control windows so a response past the default window completes" do
    body = Bytes.new(100_000) { |i| (65 + i % 26).to_u8 } # 100 KB > the 65535 window
    port = start_h2_origin_flow_controlled(200, body)

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nhost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true # would time out (incomplete) without WINDOW_UPDATE
    result.response.not_nil!.status.should eq(200)
    result.body.not_nil!.size.should eq(100_000)
  end
end
