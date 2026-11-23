require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

# The reserved host (`gori.proxy`) is answered by gori itself on every listener path, never
# dialled: bare `gori` resolves to a stranger on a network with a DNS search domain. The
# SOCKS5 and transparent listeners reach TLS through `Server#serve_pinned_tls`, which has to
# make the same decision the CONNECT path makes. A dial there fails here (the name does not
# resolve) and comes back as a 502 over the intercepted TLS; the page can only come from gori.

private class PinnedSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @requests.size.to_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private def with_pinned_listener(socks5 : Bool, serve_landing : Bool = true, &)
  dir = File.tempname("gori-pinned-ca")
  Dir.mkdir_p(dir)
  ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
  sink = PinnedSink.new
  tunnel = Gori::Proxy::Tls::Tunnel.new(ca, verify_upstream: false, serve_landing: serve_landing)
  proxy = if socks5
            Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel, socks5: true)
          else
            Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel, transparent: true, target_port: 443)
          end
  proxy.start
  begin
    yield proxy, sink
  ensure
    proxy.stop
    FileUtils.rm_rf(dir)
  end
end

private def socks5_tunnel(port : Int32, host : String, dst_port : Int32) : TCPSocket
  sock = TCPSocket.new("127.0.0.1", port)
  sock.read_timeout = 3.seconds
  sock.write(Bytes[5_u8, 1_u8, 0_u8])
  sock.flush
  sock.read_fully(Bytes.new(2))
  name = host.to_slice
  sock.write(Bytes[5_u8, 1_u8, 0_u8, 3_u8, name.size.to_u8])
  sock.write(name)
  sock.write(Bytes[(dst_port >> 8).to_u8, (dst_port & 0xFF).to_u8])
  sock.flush
  head = Bytes.new(4)
  sock.read_fully(head)
  sock.read_fully(Bytes.new((head[3] == 4_u8 ? 16 : 4) + 2))
  sock
end

# GET /ca.pem over TLS to `sni`; the response, or nil when the TLS handshake never completed.
private def fetch_ca_over_tls(raw : TCPSocket, sni : String) : String?
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  ctx.remove_options(OpenSSL::SSL::Options::ENABLE_KTLS)
  ssl = begin
    OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
  rescue
    raw.close rescue nil
    return nil
  end
  ssl << "GET /ca.pem HTTP/1.1\r\nHost: #{sni}\r\nConnection: close\r\n\r\n"
  ssl.flush
  resp = (ssl.gets_to_end rescue "")
  ssl.close rescue nil
  resp
end

describe "Gori::Proxy::Server pinned TLS to the reserved host" do
  it "serves the setup page over a SOCKS5 TLS tunnel instead of dialling gori.proxy" do
    with_pinned_listener(socks5: true) do |proxy, sink|
      resp = fetch_ca_over_tls(socks5_tunnel(proxy.port, "gori.proxy", 443), "gori.proxy")
      resp.should_not be_nil
      resp.not_nil!.should start_with("HTTP/1.1 200")
      resp.not_nil!.should contain("BEGIN CERTIFICATE")
      sink.requests.should be_empty # answered locally, nothing proxied
    end
  end

  it "serves the setup page to a transparent TLS client that names gori.proxy" do
    with_pinned_listener(socks5: false) do |proxy, sink|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw.read_timeout = 3.seconds
      resp = fetch_ca_over_tls(raw, "gori.proxy")
      resp.should_not be_nil
      resp.not_nil!.should start_with("HTTP/1.1 200")
      sink.requests.should be_empty
    end
  end

  it "drops the connection, still without a dial, when the landing page is off" do
    with_pinned_listener(socks5: true, serve_landing: false) do |proxy, sink|
      fetch_ca_over_tls(socks5_tunnel(proxy.port, "gori.proxy", 443), "gori.proxy").should be_nil
      sink.requests.should be_empty
    end
  end
end
