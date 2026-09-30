require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

include Gori::Proxy
include Gori::Proxy::Tls

# An absolute-form `https://` request sent to the PLAINTEXT forward listener (no CONNECT) is
# recorded with scheme https, so its origin has to be dialled over TLS. The dial used to follow
# the listener's `tls_upstream` alone, which is false there: the request's path, cookies and body
# went to the origin in cleartext while History read https.

private class HttpsForwardSink < FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @next_id = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private def start_https_forward_origin(seen : Channel(String)) : TCPServer
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head
        seen.send(String.new(head).lines.first)
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  server
end

# Reports the first bytes a peer sends, whatever they are.
private def start_sniffer(first : Channel(Bytes)) : TCPServer
  server = TCPServer.new("127.0.0.1", 0)
  spawn do
    if conn = server.accept?
      buf = Bytes.new(16)
      n = conn.read(buf) rescue 0
      first.send(buf[0, n].dup)
      conn.close
    end
  end
  server
end

private def with_forward_proxy(verify_upstream : Bool, &)
  dir = File.tempname("gori-abs-https-ca")
  Dir.mkdir_p(dir)
  done = Channel(Nil).new(4)
  sink = HttpsForwardSink.new(done)
  tunnel = Tunnel.new(CertAuthority.load_or_create(dir), verify_upstream: verify_upstream)
  proxy = Server.new("127.0.0.1", 0, sink, tls: tunnel)
  proxy.start
  begin
    yield proxy, sink, done
  ensure
    proxy.stop
    FileUtils.rm_rf(dir)
  end
end

private def send_raw(port : Int32, request : String) : String
  client = TCPSocket.new("127.0.0.1", port)
  client.read_timeout = 5.seconds
  client << request
  client.flush
  out = client.gets_to_end rescue ""
  client.close
  out
end

describe "Gori::Proxy absolute-form https:// on the plaintext forward listener" do
  it "dials the origin over TLS and records the exchange as https" do
    seen = Channel(String).new(1)
    server = start_https_forward_origin(seen)
    origin = server.local_address.port
    with_forward_proxy(verify_upstream: false) do |proxy, sink, done|
      reply = send_raw(proxy.port,
        "GET https://127.0.0.1:#{origin}/secret?token=abc HTTP/1.1\r\nHost: 127.0.0.1:#{origin}\r\nConnection: close\r\n\r\n")
      select
      when line = seen.receive
        line.should eq("GET /secret?token=abc HTTP/1.1")
      when timeout(5.seconds)
        fail "the TLS origin never read a request"
      end
      done.receive
      reply.should start_with("HTTP/1.1 200 OK")
      sink.requests.first.scheme.should eq("https")
    end
  ensure
    server.try(&.close)
  end

  it "never puts the request on the wire in cleartext" do
    first = Channel(Bytes).new(1)
    server = start_sniffer(first)
    port = server.local_address.port
    with_forward_proxy(verify_upstream: false) do |proxy, _sink, _done|
      spawn { send_raw(proxy.port, "GET https://127.0.0.1:#{port}/secret HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n") }
      bytes = first.receive
      bytes.empty?.should be_false
      bytes[0].should eq(0x16_u8) # a TLS handshake record, not "GET /secret"
    end
  ensure
    server.try(&.close)
  end

  it "keeps the tunnel's certificate verification" do
    seen = Channel(String).new(1)
    server = start_https_forward_origin(seen)
    origin = server.local_address.port
    with_forward_proxy(verify_upstream: true) do |proxy, sink, _done|
      send_raw(proxy.port, "GET https://127.0.0.1:#{origin}/x HTTP/1.1\r\nHost: 127.0.0.1:#{origin}\r\nConnection: close\r\n\r\n")
      select
      when line = seen.receive
        fail "an untrusted origin was sent the request: #{line}"
      when timeout(300.milliseconds)
      end
      sink.requests.first.scheme.should eq("https")
    end
  ensure
    server.try(&.close)
  end
end
