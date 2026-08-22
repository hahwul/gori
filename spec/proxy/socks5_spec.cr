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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# --- protocol-level helpers (no sockets) ---------------------------------------------------

# One handshake against `Socks5.negotiate`, driven off a byte string. Returns what the module
# decided plus everything it wrote back, so a spec can assert the REPLY as well as the verdict.
private def negotiate(bytes : Bytes, bind : Socket::IPAddress? = nil) : {Socks5::Negotiation, Bytes}
  written = IO::Memory.new
  io = IO::Stapled.new(IO::Memory.new(bytes), written)
  {Socks5.negotiate(io, bind), written.to_slice}
end

# VER=5, one method, NO-AUTH — the greeting every client that reaches this listener sends.
GREETING = Bytes[5_u8, 1_u8, 0_u8]

# --- socket-level helpers ------------------------------------------------------------------

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

# A Sandbox that can only ever allow `allowed.test`, so every other host is refused before a
# byte is dialled. Scope lives in a project store, hence the tempfile.
private def with_sandbox_scope(&)
  path = File.tempname("gori-socks5-sbx", ".db")
  store = Gori::Store.open(path)
  scope = Gori::Scope.load(store)
  scope.add("include", "host", "allowed.test")
  scope.enable_sandbox
  begin
    yield Gori::Interceptor.new(scope)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def with_socks5_listener(interceptor : Gori::Interceptor? = nil, &)
  dir = File.tempname("gori-socks5-ca")
  Dir.mkdir_p(dir)
  done = Channel(Nil).new(4)
  ca = CertAuthority.load_or_create(dir)
  sink = RecordingSink.new(done)
  tunnel = Tunnel.new(ca, verify_upstream: false)
  proxy = Server.new("127.0.0.1", 0, sink, tls: tunnel, socks5: true, interceptor: interceptor)
  proxy.start
  begin
    yield proxy, sink, done, dir
  ensure
    proxy.stop
    FileUtils.rm_rf(dir)
  end
end

# The CLIENT half of RFC 1928, as a tool pointed at `ALL_PROXY` would speak it. Returns the
# socket sitting at the start of the tunnel, or the raw reply when gori refused.
private def socks5_connect(port : Int32, host : String, dst_port : Int32,
                           cmd : UInt8 = Socks5::CMD_CONNECT,
                           methods : Bytes = Bytes[0_u8]) : {TCPSocket, Bytes}
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write(Bytes[5_u8, methods.size.to_u8])
  sock.write(methods)
  sock.flush
  selection = Bytes.new(2)
  return {sock, selection} unless sock.read_fully?(selection) && selection[1] == 0
  name = host.to_slice
  sock.write(Bytes[5_u8, cmd, 0_u8, 3_u8, name.size.to_u8])
  sock.write(name)
  sock.write(Bytes[(dst_port >> 8).to_u8, (dst_port & 0xFF).to_u8])
  sock.flush
  head = Bytes.new(4)
  return {sock, head} unless sock.read_fully?(head)
  # Drain BND.ADDR + BND.PORT so the socket sits exactly at the tunnel start.
  bound = case head[3]
          when Socks5::ATYP_IPV4 then 4
          when Socks5::ATYP_IPV6 then 16
          else                        0
          end
  sock.read_fully?(Bytes.new(bound + 2))
  {sock, head}
end

private def trusting_client(raw : TCPSocket, ca_dir : String, sni : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
end

describe Gori::Proxy::Socks5 do
  it "reads a DOMAIN request and does NOT answer it — the caller decides" do
    # `negotiate` stops short of `succeeded` on purpose: the listener still has a self-loop and
    # a Sandbox question to ask, and a reply once sent cannot be retracted.
    result, written = negotiate(GREETING + Bytes[5, 1, 0, 3, 9] + "acme.test".to_slice + Bytes[1, 187])
    result.target.should eq(Socks5::Target.new("acme.test", 443))
    result.refusal.should be_nil
    written.should eq(Bytes[5, 0]) # the method selection, and nothing else
  end

  it "reads an IPv4 and an IPv6 literal as an address a URL authority can carry" do
    v4, _ = negotiate(GREETING + Bytes[5, 1, 0, 1, 127, 0, 0, 1, 0x1f, 0x90])
    v4.target.should eq(Socks5::Target.new("127.0.0.1", 8080))
    v6, _ = negotiate(GREETING + Bytes[5, 1, 0, 4] + Bytes.new(15) { |i| i == 14 ? 0_u8 : 0_u8 } + Bytes[1_u8] + Bytes[0, 80])
    # `::1`, the spelling the rest of gori compares against — not the hand-expanded
    # `0:0:0:0:0:0:0:1`, which the Sandbox, `tls_passthrough?` and a `host:` filter would all
    # read as a different address. Bracketed, because everything downstream reads a host as a
    # URL authority.
    v6.target.try(&.host).should eq("[::1]")
  end

  it "refuses a DOMAIN carrying a byte no host can hold" do
    # It becomes this connection's `fixed_host` — the name gori dials, records on every flow and
    # gates the Sandbox on — so it goes through the same predicate a request line does.
    name = "a b.test"
    result, written = negotiate(GREETING + Bytes[5, 1, 0, 3, name.bytesize.to_u8] + name.to_slice + Bytes[1, 187])
    result.target.should be_nil
    result.refusal.to_s.should contain("no host can hold")
    written[3].should eq(Socks5::REP_GENERAL_FAILURE)
  end

  it "spells BND.ADDR with the address type its bytes actually are" do
    # A reply whose ATYP disagrees with the address length desyncs the stream for every byte
    # after it — the client would read the tunnel's first bytes as the tail of this reply.
    v4 = IO::Memory.new
    Socks5.grant(v4, Socket::IPAddress.new("127.0.0.1", 1080))
    v4.to_slice.should eq(Bytes[5, 0, 0, 1, 127, 0, 0, 1, 0x04, 0x38])

    v6 = IO::Memory.new
    Socks5.grant(v6, Socket::IPAddress.new("::1", 1080))
    v6.to_slice.should eq(Bytes[5, 0, 0, 4] + Bytes.new(15, 0_u8) + Bytes[1_u8] + Bytes[0x04, 0x38])

    none = IO::Memory.new
    Socks5.grant(none, nil)
    none.to_slice.should eq(Bytes[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]) # the unspecified form
  end

  it "refuses a greeting that offers no method gori serves, with 0xFF and no reply frame" do
    result, written = negotiate(Bytes[5, 1, 2]) # USERNAME/PASSWORD only
    result.target.should be_nil
    result.refusal.to_s.should contain("NO-AUTH only")
    written.should eq(Bytes[5, 0xff])
  end

  it "refuses a version that is not 5 without reading past that byte" do
    result, written = negotiate(Bytes[4, 1, 0]) # SOCKS4
    result.target.should be_nil
    result.refusal.to_s.should contain("version 4")
    written.empty?.should be_true
  end

  it "refuses BIND and UDP ASSOCIATE with 0x07, naming what was asked for" do
    [{Socks5::CMD_BIND, "BIND"}, {Socks5::CMD_UDP_ASSOCIATE, "UDP ASSOCIATE"}].each do |(cmd, name)|
      result, written = negotiate(GREETING + Bytes[5, cmd, 0, 3, 9] + "acme.test".to_slice + Bytes[1, 187])
      result.target.should be_nil
      result.refusal.to_s.should contain(name)
      written[2].should eq(5_u8) # after the [5,0] selection
      written[3].should eq(Socks5::REP_CMD_NOT_SUPPORTED)
    end
  end

  it "refuses an address type RFC 1928 does not define" do
    result, written = negotiate(GREETING + Bytes[5, 1, 0, 9, 1, 2])
    result.target.should be_nil
    result.refusal.to_s.should contain("address type 9")
    written[3].should eq(Socks5::REP_ATYP_NOT_SUPPORTED)
  end

  it "tells a truncated address apart from an unreadable one" do
    # Both come back nil from the address reader, and they must not read the same: "your client
    # hung up" and "gori does not speak that" send an operator to two different places.
    truncated, _ = negotiate(GREETING + Bytes[5, 1, 0, 3])
    truncated.target.should be_nil
    truncated.refusal.to_s.should contain("closed in the middle")
    truncated.refusal.to_s.should_not contain("address type")
  end
end

describe "socks5 listener" do
  it "carries a cleartext request to the destination the CLIENT named" do
    seen = Channel(String).new(1)
    origin = start_plain_origin(seen)
    with_socks5_listener do |proxy, sink, done, _|
      sock, reply = socks5_connect(proxy.port, "127.0.0.1", origin)
      reply[1].should eq(Socks5::REP_SUCCEEDED)
      # A `Host` naming somewhere else entirely: the SOCKS authority is what gori believes,
      # and the client's own header still goes to the origin byte-exact (P7).
      sock << "GET /a HTTP/1.1\r\nHost: lying.test\r\nConnection: close\r\n\r\n"
      sock.flush
      response = sock.gets_to_end
      sock.close
      done.receive

      response.should contain("HTTP/1.1 200 OK")
      response.should contain("hi")
      seen.receive.should eq("GET /a HTTP/1.1 | Host: lying.test")
      req = sink.requests.first
      req.host.should eq("127.0.0.1") # the SOCKS destination, not the Host header
      req.port.should eq(origin)
    end
  end

  it "MITMs TLS opened through the tunnel, minting for the name the client asked for" do
    seen = Channel(String).new(1)
    origin = start_tls_origin("secret", seen)
    with_socks5_listener do |proxy, sink, done, dir|
      raw, reply = socks5_connect(proxy.port, "127.0.0.1", origin)
      reply[1].should eq(Socks5::REP_SUCCEEDED)
      ssl = trusting_client(raw, dir, "127.0.0.1")
      ssl << "GET /s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      ssl.flush
      body = ssl.gets_to_end
      ssl.close
      done.receive

      body.should contain("secret")
      seen.receive.should eq("GET /s HTTP/1.1")
      sink.requests.first.scheme.should eq("https")
    end
  end

  it "refuses a destination that names gori's own listener, and records why" do
    with_socks5_listener do |proxy, sink, done, _|
      sock, reply = socks5_connect(proxy.port, "127.0.0.1", proxy.port)
      reply[1].should eq(Socks5::REP_NOT_ALLOWED)
      sock.close
      done.receive

      sink.responses.first.error.to_s.should contain("a socket gori is serving")
    end
  end

  it "refuses a host the Sandbox excludes, before anything is dialled" do
    # The security half of the same gate, and the one both config pages lead with. Answered in
    # SOCKS's own terms rather than by dropping the connection, so the client reports a cause.
    with_sandbox_scope do |interceptor|
      with_socks5_listener(interceptor) do |proxy, sink, done, _|
        sock, reply = socks5_connect(proxy.port, "excluded.test", 80)
        reply[1].should eq(Socks5::REP_NOT_ALLOWED)
        sock.close
        done.receive

        sink.responses.first.error.to_s.should contain("Sandbox excludes")
      end
    end
  end

  it "reads the TLS record start on TWO bytes, so a 0x16 that is not a ClientHello is not one" do
    # `ssh -D` is what most people point at a SOCKS listener, and an SSH banner or any other
    # binary protocol whose first octet happens to be 0x16 must not be fed to an OpenSSL server
    # handshake. It falls through to the HTTP path, which says what it saw (#729).
    with_socks5_listener do |proxy, sink, done, _|
      sock, reply = socks5_connect(proxy.port, "acme.test", 443)
      reply[1].should eq(Socks5::REP_SUCCEEDED)
      sock.write(Bytes[0x16_u8, 0x99_u8, 0x01_u8, 0x00_u8]) # 0x16, but not 0x16 0x03
      sock.flush
      sock.gets_to_end
      sock.close
      done.receive

      sink.responses.first.error.to_s.should contain("not an HTTP request")
    end
  end

  it "does not mistake every host on gori's port for gori, under a wildcard bind" do
    # The first attempt asked `Settings`' bind-coexistence predicate, where a WILDCARD matches
    # every address of its family. Under the documented `bind_host: 0.0.0.0` setup (the LAN /
    # mobile-device shape, which is exactly when a SOCKS5 listener gets added) that made every
    # REMOTE host on gori's own port look like gori — so with a bind port of 8080 or 3128 a
    # large share of ordinary targets was refused, with a flow claiming the client had named
    # gori itself. Only the handshake matters here; the dial that follows has nowhere to go.
    prev_host, prev_port = Gori::Settings.bind_host, Gori::Settings.bind_port
    begin
      Gori::Settings.bind_host = "0.0.0.0"
      Gori::Settings.bind_port = 8080
      with_socks5_listener do |proxy, _, _, _|
        # RFC 5737 TEST-NET-1: an IP literal, so no DNS, and unroutable, so nothing is reached.
        # Only the HANDSHAKE is under test — `succeeded` means the gate let it through, and
        # what the dial does afterwards is a different answer on a different code path.
        sock, reply = socks5_connect(proxy.port, "192.0.2.1", 8080)
        reply[1].should eq(Socks5::REP_SUCCEEDED)
        sock.close
      end
    ensure
      Gori::Settings.bind_host = prev_host
      Gori::Settings.bind_port = prev_port
    end
  end

  it "still refuses a loopback target on a socket gori serves — a sibling, not this listener" do
    prev_host, prev_port = Gori::Settings.bind_host, Gori::Settings.bind_port
    begin
      Gori::Settings.bind_host = "127.0.0.1"
      Gori::Settings.bind_port = 8070
      with_socks5_listener do |proxy, sink, done, _|
        sock, reply = socks5_connect(proxy.port, "127.0.0.1", 8070) # the PRIMARY bind
        reply[1].should eq(Socks5::REP_NOT_ALLOWED)
        sock.close
        done.receive
        sink.responses.first.error.to_s.should contain("a socket gori is serving")
      end
    ensure
      Gori::Settings.bind_host = prev_host
      Gori::Settings.bind_port = prev_port
    end
  end

  it "refuses UDP ASSOCIATE on the wire and puts the refusal on the record" do
    with_socks5_listener do |proxy, sink, done, _|
      sock, reply = socks5_connect(proxy.port, "acme.test", 443, cmd: Socks5::CMD_UDP_ASSOCIATE)
      reply[1].should eq(Socks5::REP_CMD_NOT_SUPPORTED)
      sock.close
      done.receive

      sink.responses.first.error.to_s.should contain("CONNECT only")
    end
  end

  it "records NOTHING for a connection that opened and closed without a word" do
    # A port scan, a health check pointed at :1080, a speculative preconnect. Recorded, this was
    # one flow and one log line per TCP connection — 50 connects, 50 rows about nobody — which
    # fills the project with noise and drowns the History it exists to produce. The other three
    # listener modes record nothing for the same shape.
    with_socks5_listener do |proxy, sink, _, _|
      10.times { TCPSocket.new("127.0.0.1", proxy.port).close }
      # Then a real refusal, to prove the silence is about THIS shape and not a broken sink: it
      # arrives after the ten, so an empty list here would mean nothing at all was recorded.
      sock, _ = socks5_connect(proxy.port, "acme.test", 443, cmd: Socks5::CMD_UDP_ASSOCIATE)
      sock.close
      sleep 50.milliseconds
      sink.requests.size.should eq(1)
      sink.responses.first.error.to_s.should contain("CONNECT only")
    end
  end

  it "will not open a CONNECT tunnel past the destination the handshake pinned" do
    # `handle_connect` runs before `resolve_forward`, so `fixed_host` never reached it: a granted
    # tunnel to one host plus one line of HTTP used to open a blind byte tunnel to another, with
    # no flow to show for it — and it walked around the handshake's own self-loop gate.
    seen = Channel(String).new(1)
    origin = start_plain_origin(seen)
    with_socks5_listener do |proxy, sink, done, _|
      sock, reply = socks5_connect(proxy.port, "127.0.0.1", origin)
      reply[1].should eq(Socks5::REP_SUCCEEDED)
      sock << "CONNECT elsewhere.test:443 HTTP/1.1\r\nHost: elsewhere.test:443\r\n\r\n"
      sock.flush
      answer = sock.gets_to_end
      sock.close
      done.receive

      answer.should contain("403 Forbidden")
      answer.should_not contain("200 Connection Established")
      sink.responses.first.error.to_s.should contain("not a forward proxy")
    end
  end

  it "records a client that speaks something other than SOCKS5 at it" do
    with_socks5_listener do |proxy, sink, done, _|
      sock = TCPSocket.new("127.0.0.1", proxy.port)
      sock << "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n" # an HTTP client pointed at the wrong port
      sock.flush
      sock.gets_to_end
      sock.close
      done.receive

      sink.responses.first.error.to_s.should contain("SOCKS5")
    end
  end
end
