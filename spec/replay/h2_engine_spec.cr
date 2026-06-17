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

describe Gori::Replay::H2Engine do
  it "replays a GET as real cleartext h2 and reassembles the response" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "replayed!", seen)

    request = "GET /api/thing HTTP/2\r\nx-replay: yes\r\n\r\n".to_slice
    result = Gori::Replay::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("GET /api/thing body=") # origin saw the HPACK-encoded request
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.head).should contain("HTTP/2 200")
    String.new(result.head).should contain("server: gori-test")
    String.new(result.body.not_nil!).should eq("replayed!")
  end

  it "sends a request body as DATA frames" do
    seen = Channel(String).new(1)
    port = start_h2_origin(201, "created", seen)

    request = "POST /submit HTTP/2\r\ncontent-type: text/plain\r\n\r\nhello-h2-body".to_slice
    result = Gori::Replay::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq("POST /submit body=hello-h2-body")
    result.response.not_nil!.status.should eq(201)
    String.new(result.body.not_nil!).should eq("created")
  end

  it "reports an error when the origin is unreachable" do
    result = Gori::Replay::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    result.ok?.should be_false
    result.error.should_not be_nil
  end
end
