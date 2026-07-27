require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

include Gori::Proxy
include Gori::Proxy::Tls

private class RecordingSink < FlowSink
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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

# A cleartext origin that reports the request line and Host it received.
private def start_plain_origin(seen : Channel(String)) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      begin
        head = Codec::Http1.read_head(conn)
        next unless head
        text = String.new(head)
        seen.send(text.lines.first + " | " + (text.lines.find(&.downcase.starts_with?("host:")) || "").strip)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        conn.flush
        conn.close
      rescue
      end
    end
  end
  port
end

# A self-signed TLS origin, CN=origin.test — so the certificate the client validates says who
# terminated its TLS (CN=<the SNI it sent> means gori did).
private def start_tls_origin(body : String, seen : Channel(String)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head
        seen.send(String.new(head).lines.first)
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

# A TRANSPARENT listener: no CONNECT, no absolute-form target. `target_port` stands in for the
# original destination port the kernel redirect consumed.
private def with_transparent_proxy(target_port : Int32, &)
  dir = File.tempname("gori-transparent-ca")
  Dir.mkdir_p(dir)
  done = Channel(Nil).new(4)
  ca = CertAuthority.load_or_create(dir)
  sink = RecordingSink.new(done)
  tunnel = Tunnel.new(ca, verify_upstream: false)
  proxy = Server.new("127.0.0.1", 0, sink, tls: tunnel,
    transparent: true, target_port: target_port)
  proxy.start
  begin
    yield proxy, sink, done, dir
  ensure
    proxy.stop
    FileUtils.rm_rf(dir)
  end
end

private def trusting_client(raw : TCPSocket, ca_dir : String, sni : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
end

describe "transparent listener" do
  # Cleartext: the client sends an ORIGIN-form request, as it would to the origin itself. The
  # destination has to come from the Host header — there is no other name on the wire.
  it "forwards a cleartext origin-form request to the host named in the Host header" do
    seen = Channel(String).new(1)
    origin_port = start_plain_origin(seen)
    with_transparent_proxy(target_port: origin_port) do |proxy, sink, done, _dir|
      sock = TCPSocket.new("127.0.0.1", proxy.port)
      # No absolute-form target, no CONNECT: exactly what a redirected client emits.
      sock << "GET /shop HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      sock.flush
      response = sock.gets_to_end
      sock.close
      done.receive

      response.should contain("200 OK")
      response.should contain("hi")
      seen.receive.should start_with("GET /shop HTTP/1.1")

      # Captured like any other flow — the whole point of routing it through ClientConn.
      sink.requests.size.should eq(1)
      sink.requests.first.target.should eq("/shop")
      sink.requests.first.host.should eq("127.0.0.1")
    end
  end

  # A Host header with no port must fall back to the LISTENER's target_port, not to 80: the
  # client dialled a port the kernel redirected, and the socket cannot reveal which.
  it "uses the listener's target_port when the Host header names none" do
    seen = Channel(String).new(1)
    origin_port = start_plain_origin(seen)
    with_transparent_proxy(target_port: origin_port) do |proxy, _sink, done, _dir|
      sock = TCPSocket.new("127.0.0.1", proxy.port)
      sock << "GET /noport HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      sock.flush
      sock.gets_to_end
      sock.close
      done.receive
      seen.receive.should start_with("GET /noport HTTP/1.1") # it reached the origin at all
    end
  end

  # TLS: the destination comes from the SNI, read before the handshake. Asserted by certificate
  # identity — a leaf for the SNI name can only have been minted by gori.
  it "MITMs a direct TLS connection using the SNI as the destination" do
    seen = Channel(String).new(1)
    origin_port = start_tls_origin("SECRET", seen)
    with_transparent_proxy(target_port: origin_port) do |proxy, sink, done, dir|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      # Straight into TLS — no CONNECT line at all.
      tls = trusting_client(raw, dir, "localhost")
      subject = tls.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      response = tls.gets_to_end
      tls.close
      done.receive

      subject.should contain("localhost")       # gori's leaf, minted for the SNI
      subject.should_not contain("origin.test") # not the origin's own certificate
      response.should contain("SECRET")
      seen.receive.should eq("GET /secret HTTP/1.1")

      sink.requests.size.should eq(1)
      sink.requests.first.scheme.should eq("https")
      sink.requests.first.host.should eq("localhost")
      sink.requests.first.port.should eq(origin_port)
    end
  end

  # The passthrough list has to hold on this path too — a pinned app is exactly what a
  # transparent listener catches, and it is the one place the operator cannot use a CONNECT-time
  # escape hatch.
  it "honours the TLS passthrough list, leaving the origin's own certificate in place" do
    seen = Channel(String).new(1)
    origin_port = start_tls_origin("SECRET", seen)
    with_transparent_proxy(target_port: origin_port) do |proxy, sink, _done, _dir|
      Gori::Settings.tls_passthrough = ["localhost"]
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      ctx = OpenSSL::SSL::Context::Client.new
      ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      tls = OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: "localhost")
      subject = tls.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      response = tls.gets_to_end
      tls.close

      subject.should contain("origin.test") # relayed opaquely — no leaf was minted
      response.should contain("SECRET")
      sink.requests.should be_empty # nothing decrypted means nothing recorded
    ensure
      Gori::Settings.tls_passthrough = [] of String
    end
  end

  # No SNI means no destination, so there is nothing to mint a certificate for and nothing to
  # gate on. Dropping is the only honest option; it must not hang or crash the listener.
  it "drops a TLS connection with no SNI without disturbing the listener" do
    seen = Channel(String).new(1)
    origin_port = start_plain_origin(seen)
    with_transparent_proxy(target_port: origin_port) do |proxy, sink, done, _dir|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      # A ClientHello-shaped record with no extensions at all.
      body = IO::Memory.new
      body.write Bytes[0x01, 0x00, 0x00, 0x26]
      body.write Bytes[0x03, 0x03]
      body.write Bytes.new(32, 0_u8)
      body.write Bytes[0x00]
      body.write Bytes[0x00, 0x02, 0x13, 0x01]
      body.write Bytes[0x01, 0x00]
      payload = body.to_slice
      raw.write Bytes[0x16, 0x03, 0x01, (payload.size >> 8).to_u8, (payload.size & 0xFF).to_u8]
      raw.write payload
      raw.flush
      raw.gets_to_end # the connection is closed with nothing served
      raw.close
      sink.requests.should be_empty

      # The listener is still alive: a following cleartext connection works.
      sock = TCPSocket.new("127.0.0.1", proxy.port)
      sock << "GET /after HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      sock.flush
      sock.gets_to_end.should contain("200 OK")
      sock.close
      done.receive
      seen.receive.should start_with("GET /after HTTP/1.1")
    end
  end
end
