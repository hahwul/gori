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

# A cleartext origin that reports the FULL head it received. The head is what these examples
# are about: a reverse listener's whole job is choosing a destination without reading it, and
# `rewrite_host` is the one thing allowed to change it on the way out.
private def start_plain_origin(seen : Channel(String)) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      begin
        head = Codec::Http1.read_head(conn)
        next unless head
        seen.send(String.new(head))
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

# A REVERSE listener: no CONNECT, no absolute-form target, and — unlike transparent — no Host
# header or SNI consulted for the destination either. The origin is handed in.
private def with_reverse_proxy(origin : {String, String, Int32}, rewrite_host : Bool = false, &)
  dir = File.tempname("gori-reverse-ca")
  Dir.mkdir_p(dir)
  done = Channel(Nil).new(4)
  ca = CertAuthority.load_or_create(dir)
  sink = RecordingSink.new(done)
  tunnel = Tunnel.new(ca, verify_upstream: false)
  proxy = Server.new("127.0.0.1", 0, sink, tls: tunnel,
    origin: origin, rewrite_host: rewrite_host)
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

describe "reverse listener" do
  it "forwards to the DECLARED origin, ignoring the Host header entirely" do
    seen = Channel(String).new(1)
    origin_port = start_plain_origin(seen)
    with_reverse_proxy({"http", "127.0.0.1", origin_port}) do |proxy, sink, done, _dir|
      sock = TCPSocket.new("127.0.0.1", proxy.port)
      # A Host naming somewhere else entirely. A TRANSPARENT listener would try to dial it;
      # this one must not look at it at all — that is the difference the mode exists for.
      sock << "GET /shop HTTP/1.1\r\nHost: elsewhere.invalid\r\n\r\n"
      sock.flush
      response = sock.gets_to_end
      sock.close
      done.receive

      response.should contain("200 OK")
      response.should contain("hi")
      # It reached the declared origin, and the client's Host went upstream BYTE-EXACT (P7):
      # rewrite_host is off, so gori changed nothing.
      head = seen.receive
      head.should start_with("GET /shop HTTP/1.1")
      head.should contain("Host: elsewhere.invalid")

      sink.requests.size.should eq(1)
      sink.requests.first.target.should eq("/shop")
      sink.requests.first.host.should eq("127.0.0.1")
      sink.requests.first.port.should eq(origin_port)
    end
  end

  # A request with NO Host at all is the case a transparent listener cannot serve — there is
  # nothing to derive from. Declared origin, so it just works.
  it "serves a request with no Host header, which transparent cannot" do
    seen = Channel(String).new(1)
    origin_port = start_plain_origin(seen)
    with_reverse_proxy({"http", "127.0.0.1", origin_port}) do |proxy, _sink, done, _dir|
      sock = TCPSocket.new("127.0.0.1", proxy.port)
      sock << "GET /nohost HTTP/1.0\r\n\r\n"
      sock.flush
      sock.gets_to_end
      sock.close
      done.receive
      seen.receive.should start_with("GET /nohost HTTP/1.0")
    end
  end

  describe "rewrite_host" do
    it "leaves the client's Host byte-exact when it is off (the default)" do
      seen = Channel(String).new(1)
      origin_port = start_plain_origin(seen)
      with_reverse_proxy({"http", "127.0.0.1", origin_port}) do |proxy, _sink, done, _dir|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock << "GET /p HTTP/1.1\r\nHost: Www.Example.Com\r\nX-Keep: 1\r\n\r\n"
        sock.flush
        sock.gets_to_end
        sock.close
        done.receive
        head = seen.receive
        head.should contain("Host: Www.Example.Com") # not normalised, not replaced
        head.should contain("X-Keep: 1")
      end
    end

    it "replaces the Host with the declared origin's authority when it is on" do
      seen = Channel(String).new(1)
      origin_port = start_plain_origin(seen)
      with_reverse_proxy({"http", "127.0.0.1", origin_port}, rewrite_host: true) do |proxy, _sink, done, _dir|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock << "GET /p HTTP/1.1\r\nHost: elsewhere.invalid\r\nX-Keep: 1\r\nAccept: */*\r\n\r\n"
        sock.flush
        sock.gets_to_end
        sock.close
        done.receive
        head = seen.receive
        head.should contain("Host: 127.0.0.1:#{origin_port}")
        head.should_not contain("elsewhere.invalid")
        # ONE field changed. Everything else about the head is untouched, including order.
        head.should start_with("GET /p HTTP/1.1")
        head.should contain("X-Keep: 1")
        head.should contain("Accept: */*")
      end
    end

    # Two Host headers is a request-smuggling shape. Declaring the origin and then leaving a
    # second Host behind would hand the origin exactly the ambiguity the declaration removes.
    it "collapses a duplicated Host header to one" do
      seen = Channel(String).new(1)
      origin_port = start_plain_origin(seen)
      with_reverse_proxy({"http", "127.0.0.1", origin_port}, rewrite_host: true) do |proxy, _sink, done, _dir|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock << "GET /p HTTP/1.1\r\nHost: a.invalid\r\nHost: b.invalid\r\n\r\n"
        sock.flush
        sock.gets_to_end
        sock.close
        done.receive
        head = seen.receive
        head.scan(/(?im)^host:/).size.should eq(1)
        head.should contain("Host: 127.0.0.1:#{origin_port}")
      end
    end

    it "inserts a Host when the client sent none" do
      seen = Channel(String).new(1)
      origin_port = start_plain_origin(seen)
      with_reverse_proxy({"http", "127.0.0.1", origin_port}, rewrite_host: true) do |proxy, _sink, done, _dir|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock << "GET /p HTTP/1.0\r\n\r\n"
        sock.flush
        sock.gets_to_end
        sock.close
        done.receive
        seen.receive.should contain("Host: 127.0.0.1:#{origin_port}")
      end
    end

    # Every other example here reaches the listener in CLEARTEXT, and that was the whole gap:
    # `serve_reverse` passed `rewrite_fixed_host:` straight to ClientConn, while
    # `serve_reverse_tls` went through `TlsMitm#intercept`, whose signature had no such
    # parameter — so one listener honoured the setting or ignored it depending on whether the
    # client happened to speak TLS, a distinction the operator never made.
    it "replaces the Host for a TLS client too, not only a cleartext one" do
      seen = Channel(String).new(1)
      origin_port = start_plain_origin(seen)
      with_reverse_proxy({"http", "localhost", origin_port}, rewrite_host: true) do |proxy, _sink, done, dir|
        raw = TCPSocket.new("127.0.0.1", proxy.port)
        tls = trusting_client(raw, dir, "localhost")
        tls << "GET /p HTTP/1.1\r\nHost: elsewhere.invalid\r\nX-Keep: 1\r\n\r\n"
        tls.flush
        tls.gets_to_end
        tls.close
        done.receive
        head = seen.receive
        head.should contain("Host: localhost:#{origin_port}")
        head.should_not contain("elsewhere.invalid")
        head.should contain("X-Keep: 1")
      end
    end

    # A header whose VALUE contains "host:" must not be mistaken for the field.
    it "matches the field name, not the value" do
      seen = Channel(String).new(1)
      origin_port = start_plain_origin(seen)
      with_reverse_proxy({"http", "127.0.0.1", origin_port}, rewrite_host: true) do |proxy, _sink, done, _dir|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock << "GET /p HTTP/1.1\r\nHost: a.invalid\r\nX-Note: host: not-a-header\r\n\r\n"
        sock.flush
        sock.gets_to_end
        sock.close
        done.receive
        seen.receive.should contain("X-Note: host: not-a-header")
      end
    end
  end

  # TLS terminated by the reverse listener. The leaf is minted for the CONFIGURED origin name,
  # never for whatever SNI the client happened to offer — asserted by certificate identity.
  it "terminates TLS with a leaf for the CONFIGURED name, not the client's SNI" do
    seen = Channel(String).new(1)
    origin_port = start_tls_origin("SECRET", seen)
    with_reverse_proxy({"https", "localhost", origin_port}) do |proxy, sink, done, dir|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      tls = trusting_client(raw, dir, "localhost")
      subject = tls.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      response = tls.gets_to_end
      tls.close
      done.receive

      subject.should contain("localhost")       # gori's leaf, minted from CONFIGURATION
      subject.should_not contain("origin.test") # not the origin's own certificate
      response.should contain("SECRET")
      seen.receive.should eq("GET /secret HTTP/1.1")

      sink.requests.size.should eq(1)
      sink.requests.first.scheme.should eq("https")
      sink.requests.first.port.should eq(origin_port)
    end
  end

  # TLS in front of a CLEARTEXT backend — the local-dev shape, and the reason `intercept` grew
  # a `tls_upstream` parameter. Only a reverse listener may ask for it: on the CONNECT and
  # transparent paths the client asked for https, so downgrading the origin leg there would be
  # gori silently weakening a connection the client believes is end-to-end.
  it "terminates TLS in front of a cleartext origin when the origin scheme says http" do
    seen = Channel(String).new(1)
    origin_port = start_plain_origin(seen)
    with_reverse_proxy({"http", "localhost", origin_port}) do |proxy, sink, done, dir|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      tls = trusting_client(raw, dir, "localhost")
      tls << "GET /plainback HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      response = tls.gets_to_end
      tls.close
      done.receive

      response.should contain("hi")
      seen.receive.should start_with("GET /plainback HTTP/1.1")
      # Recorded as what was actually spoken to the ORIGIN, not as what the client spoke to us.
      sink.requests.size.should eq(1)
      sink.requests.first.scheme.should eq("http")
    end
  end

  # Layer 2 is the layer that must be identical on every surface. A reverse listener does not
  # get to be the exception just because its destination was configured.
  it "applies the Sandbox gate before the origin handshake" do
    seen = Channel(String).new(1)
    origin_port = start_tls_origin("SECRET", seen)
    dir = File.tempname("gori-reverse-sandbox")
    db = File.tempname("gori-reverse-scope", ".db")
    Dir.mkdir_p(dir)
    store = Gori::Store.open(db)
    begin
      done = Channel(Nil).new(4)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      tunnel = Tunnel.new(ca, verify_upstream: false)
      scope = Gori::Scope.load(store)
      scope.enable_sandbox # on with no include rules blocks everything
      interceptor = Gori::Interceptor.new(scope)
      proxy = Server.new("127.0.0.1", 0, sink, tls: tunnel, interceptor: interceptor,
        origin: {"https", "localhost", origin_port})
      proxy.start
      begin
        raw = TCPSocket.new("127.0.0.1", proxy.port)
        # Dropped before any handshake, so the client's TLS negotiation fails outright.
        expect_raises(Exception) do
          t = trusting_client(raw, dir, "localhost")
          t << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
          t.flush
          t.gets_to_end
        end
        sink.requests.should be_empty
      ensure
        proxy.stop
      end
    ensure
      store.close
      FileUtils.rm_rf(dir)
      File.delete?(db)
      File.delete?("#{db}-wal")
      File.delete?("#{db}-shm")
    end
  end
end
