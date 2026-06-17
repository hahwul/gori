require "../spec_helper"
require "socket"
require "file_utils"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

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

# A minimal cleartext-HTTP/2 (h2c) origin: reads the preface, waits for the
# request HEADERS, then replies with SETTINGS + HEADERS(:status 200) + DATA.
private def start_h2c_origin(body : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil? || f.frame_type == Frame::Type::Headers
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    status = HPACK::Encoder.new.encode([{":status", "200"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, status).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

describe "h2c via CONNECT (cleartext HTTP/2)" do
  it "relays a cleartext-h2 stream and captures it as an HTTP/2 flow" do
    ca_dir = File.tempname("gori-h2c-ca")
    Dir.mkdir_p(ca_dir)
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
    tunnel = Gori::Proxy::Tls::Tunnel.new(ca, verify_upstream: false)

    origin_port = start_h2c_origin("h2c-ok")
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    # CONNECT to the origin, then speak cleartext h2 ("prior knowledge").
    client << "CONNECT 127.0.0.1:#{origin_port} HTTP/1.1\r\n\r\n"
    client.flush
    # consume the 200 response head
    until (line = client.gets) == "" || line.nil?
    end

    client.write(Frame::PREFACE)
    client.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    req = HPACK::Encoder.new.encode([
      {":method", "GET"}, {":path", "/"}, {":scheme", "http"}, {":authority", "127.0.0.1:#{origin_port}"},
    ])
    client.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS | Frame::END_STREAM, 1_u32, req).to_bytes)
    client.flush

    # read response frames until END_STREAM data
    got_body = ""
    got_status_headers = false
    loop do
      f = Frame.read(client)
      break if f.nil?
      got_status_headers = true if f.frame_type == Frame::Type::Headers && f.stream_id == 1
      if f.frame_type == Frame::Type::Data && f.stream_id == 1
        got_body += String.new(f.payload)
        break if f.end_stream?
      end
    end
    client.close

    got_status_headers.should be_true
    got_body.should eq("h2c-ok") # the relay forwarded both ways over cleartext h2

    # capture happens just after forwarding; poll briefly for the projection
    attempts = 0
    while sink.responses.empty? && attempts < 100
      sleep 0.02.seconds
      attempts += 1
    end
    proxy.stop

    # gori projected the cleartext-h2 stream into a flow
    sink.requests.first.http_version.should eq("HTTP/2")
    sink.requests.first.target.should eq("/")
    sink.responses.first.status.should eq(200)
  ensure
    FileUtils.rm_rf(ca_dir) if ca_dir
  end
end
