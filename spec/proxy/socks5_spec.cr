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

# A peer that hands over `head` and then holds the socket open saying nothing. `IO::Memory`
# cannot model this — it answers EOF, which is the OTHER thing a quiet client can do and the
# one the listener deliberately records nothing for.
private class StallingIO < IO
  def initialize(@head : Bytes)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    raise IO::TimeoutError.new("read timed out") if @pos >= @head.size
    n = Math.min(slice.size, @head.size - @pos)
    slice[0, n].copy_from(@head[@pos, n])
    @pos += n
    n
  end

  def write(slice : Bytes) : Nil
  end
end

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

# A SERVER-SPEAKS-FIRST origin: it greets the instant a peer connects and never waits for the
# client to say anything. SMTP, IMAP, POP3, MySQL and SSH all have this shape, and `ssh -D` is
# what most people point a SOCKS5 listener at. `dialled` counts CONNECTIONS, so an example can
# assert that gori reached the origin at all — the half a passing banner alone cannot separate
# from a client talking to something else.
private def start_banner_origin(dialled : Channel(Nil)) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      spawn do
        begin
          dialled.send(nil)
          conn << "220 banner.origin ESMTP ready\r\n"
          conn.flush
          conn.gets_to_end # hold the relay open until the client hangs up
        rescue
        ensure
          conn.close rescue nil
        end
      end
    end
  end
  port
end

# A BOUNDED wait on the sink, for the examples whose failure mode IS silence. `done.receive` is
# this file's usual shape and is right wherever a response is guaranteed — but the defect these
# examples are about is a connection that produces no flow at all, and waiting on the channel
# for it wedges the suite instead of failing it (a CI run that hangs reports nothing, which is
# the same "nothing came vs nobody looked" confusion one layer up).
private def await_flows(sink : RecordingSink, n : Int32 = 1) : Nil
  250.times do
    break if sink.requests.size >= n
    sleep 0.02.seconds
  end
end

# `network.tls_passthrough` set for the duration of one example and put back afterwards — it is
# process-global settings state, and a leak makes the NEXT example's origin unreachable in a way
# that reads as a proxy bug.
private def with_passthrough(hosts : Array(String), &)
  prev = Gori::Settings.tls_passthrough
  begin
    Gori::Settings.tls_passthrough = hosts
    yield
  ensure
    Gori::Settings.tls_passthrough = prev
  end
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

private def trusting_client(raw : IO, ca_dir : String, sni : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
end

# A client that sends `sni` and then accepts whatever leaf comes back. The one spec that needs
# it is the one where the SNI is the LIE under test: gori is expected to mint for the name the
# handshake DECLARED instead, so a verifying client would fail on the very outcome being
# asserted — and fail identically whichever name it got.
private def unverified_client(raw : IO, sni : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
end

# Splits the FIRST write into its first octet and the rest, with a scheduler yield between —
# which is what puts exactly ONE byte in gori's socket buffer when its `peek` runs. Nothing
# exotic produces this on a real network either: a `TCP_NODELAY` client, a PMTU boundary, or an
# SSL layer that writes its record header separately.
private class SplitFirstWriteIO < IO
  def initialize(@inner : IO)
    @split = true
  end

  def read(slice : Bytes) : Int32
    @inner.read(slice)
  end

  def write(slice : Bytes) : Nil
    if @split && slice.size > 1
      @split = false
      @inner.write(slice[0, 1])
      @inner.flush
      sleep 50.milliseconds # let the listener's fiber run and peek the single octet
      @inner.write(slice[1..])
      return
    end
    @inner.write(slice)
  end

  def flush
    @inner.flush
  end

  def close
    @inner.close
  end
end

describe Gori::Proxy::Socks5 do
  it "reads a DOMAIN request and does NOT answer it — the caller decides" do
    # `negotiate` stops short of `succeeded` on purpose: the listener still has a self-loop and
    # a Sandbox question to ask, and a reply once sent cannot be retracted.
    result, written = negotiate(GREETING + Bytes[5, 1, 0, 3, 9] + "acme.test".to_slice + Bytes[1, 187])
    # `named:` — the ATYP this destination arrived under. It is what lets the listener know it
    # has a NAME to tell History, scope and the passthrough list, rather than an address whose
    # only name would be whatever SNI the client puts in its ClientHello.
    result.target.should eq(Socks5::Target.new("acme.test", 443, named: true))
    result.refusal.should be_nil
    written.should eq(Bytes[5, 0]) # the method selection, and nothing else
  end

  it "reads an IPv4 and an IPv6 literal as an address a URL authority can carry" do
    v4, _ = negotiate(GREETING + Bytes[5, 1, 0, 1, 127, 0, 0, 1, 0x1f, 0x90])
    # `named: false` — a literal names no host, so the SNI is still the only name on the wire.
    v4.target.should eq(Socks5::Target.new("127.0.0.1", 8080, named: false))
    v4.target.not_nil!.named?.should be_false
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

  it "tells a client that says nothing from one that stops part-way through" do
    # Both are `IO::TimeoutError` on the way up and were filed as the same thing: a flow saying
    # the peer never spoke. Only the first is that. The second had sent a greeting and a method
    # list, which is a client doing something — and the listener records the two differently.
    silent = Socks5.negotiate(StallingIO.new(Bytes.empty), nil)
    silent.silent?.should be_true
    silent.timed_out?.should be_true
    silent.refusal.to_s.should contain("no greeting")

    partial = Socks5.negotiate(StallingIO.new(GREETING), nil)
    partial.silent?.should be_false
    partial.timed_out?.should be_false
    partial.refusal.to_s.should contain("part-way through")
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

  it "MITMs a ClientHello SPLIT ACROSS TWO WRITES, which `peek` alone cannot answer for" do
    # `IO::Buffered#peek` is one `read(2)`'s worth and refills only when the buffer is EMPTY, so
    # it can hand back a single octet — and the listeners fed that straight into
    # `record_start?`, a TWO-byte test. A ClientHello split `[0:1] / [1:]` therefore answered
    # "not TLS", fell down the HTTP/1.1 path, and produced a flow whose method was `"\x16"`:
    # no MITM, no capture, and the origin never dialled. A `TCP_NODELAY` client, a PMTU
    # boundary or an SSL layer that writes its record header separately is enough to cause it.
    seen = Channel(String).new(1)
    origin = start_tls_origin("split-secret", seen)
    with_socks5_listener do |proxy, sink, done, dir|
      raw, reply = socks5_connect(proxy.port, "127.0.0.1", origin)
      reply[1].should eq(Socks5::REP_SUCCEEDED)
      # The split, forced under the ClientHello: the first record octet on its own, and only
      # then the rest. `SplitFirstWriteIO` says how.
      ssl = trusting_client(SplitFirstWriteIO.new(raw), dir, "127.0.0.1")
      ssl << "GET /split HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      ssl.flush
      body = ssl.gets_to_end
      ssl.close
      done.receive

      body.should contain("split-secret")
      seen.receive.should eq("GET /split HTTP/1.1")
      # The proof it took the TLS branch rather than the h1 one: a captured https flow, not a
      # `"\x16"` "not an HTTP request" row.
      sink.requests.first.scheme.should eq("https")
      sink.requests.first.target.should eq("/split")
    end
  end

  it "does not let a client-chosen SNI relabel a destination the handshake DECLARED" do
    # The SNI wins over a TRANSPARENT listener's `{host, port}` because that pair is an ADDRESS
    # the kernel reported and the SNI is a NAME. A SOCKS5 client sent its destination AS a name,
    # through a handshake gori already gated and granted — so preferring the ClientHello let it
    # relabel a connection it had already declared, and History, the scope lens and
    # `tls_passthrough` all matched a name the client invented while the dial stayed pinned.
    seen = Channel(String).new(1)
    origin = start_tls_origin("labelled", seen)
    with_socks5_listener do |proxy, sink, _done, _|
      # An ATYP_DOMAIN destination (what `socks5_connect` sends), so the client NAMED it — and
      # a name that happens to be reachable, so the exchange completes rather than dying in DNS.
      raw, reply = socks5_connect(proxy.port, "127.0.0.1", origin)
      reply[1].should eq(Socks5::REP_SUCCEEDED)
      ssl = unverified_client(raw, "evil-sni.example")
      ssl << "GET /x HTTP/1.1\r\nHost: evil-sni.example\r\nConnection: close\r\n\r\n"
      ssl.flush
      ssl.gets_to_end
      ssl.close
      seen.receive

      # The DECLARED destination, not the name the ClientHello made up.
      sink.requests.first.host.should eq("127.0.0.1")
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

  # `network.tls_passthrough` on this listener. The setting names TLS, the UI and the help
  # describe TLS hosts, and the whole of it is which connections it may silence.
  #
  # Matching the list AHEAD of the peek fixed a real hang — a server-speaks-first peer sat out
  # the 30 s client read timeout with the origin never dialled — and opened a silent hole: a
  # relay chosen before any client byte cannot tell a ClientHello from `GET / HTTP/1.1`, so
  # plaintext `http://` to a listed host was piped through with no flow and no advisory. An
  # operator who listed `internal.corp` to dodge a pinned app lost every cleartext capture for
  # it, with nothing anywhere to say so — "nothing came" and "nobody looked" reading the same.
  #
  # These five hold the three properties together. Dropping any one of them re-opens one of the
  # two defects, and no two of them can be satisfied by the same shortcut — capture the
  # cleartext, pass the TLS, do not wait, say what was lost, and leave every other host alone.
  describe "network.tls_passthrough" do
    it "STILL CAPTURES plaintext HTTP to a listed host" do
      # The blackout, stated as the thing that must not happen again. The client speaks first,
      # so there is a byte to route on, and a byte that is not a ClientHello has nothing to do
      # with a setting called `tls_passthrough`.
      seen = Channel(String).new(1)
      origin = start_plain_origin(seen)
      with_passthrough(["localhost"]) do
        with_socks5_listener do |proxy, sink, _done, _|
          sock, reply = socks5_connect(proxy.port, "localhost", origin)
          reply[1].should eq(Socks5::REP_SUCCEEDED)
          sock << "GET /listed HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
          sock.flush
          response = sock.gets_to_end
          sock.close
          await_flows(sink)

          # The RESPONSE still arrives either way — the blackout relayed the bytes faithfully,
          # which is exactly why it was invisible. Only the row tells the two apart.
          response.should contain("200 OK")
          seen.receive.should contain("GET /listed HTTP/1.1")
          # THE ASSERTION THE DEFECT FAILED: a row, for a request that happened.
          sink.requests.size.should eq(1)
          sink.requests.first.host.should eq("localhost")
          sink.requests.first.target.should eq("/listed")
          sink.requests.first.scheme.should eq("http")
        end
      end
    end

    it "STILL PASSES TLS to a listed host through, leaving the origin's own certificate" do
      # The half the setting is named for, unchanged: the ClientHello reaches
      # `serve_pinned_tls`, which asks the list for itself — the one place a `tls_passthrough`
      # decision can be made about actual TLS — and relays without minting a leaf.
      seen = Channel(String).new(1)
      origin = start_tls_origin("passthrough-secret", seen)
      with_passthrough(["localhost"]) do
        with_socks5_listener do |proxy, sink, _done, _|
          raw, reply = socks5_connect(proxy.port, "localhost", origin)
          reply[1].should eq(Socks5::REP_SUCCEEDED)
          ssl = unverified_client(raw, "localhost")
          subject = ssl.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
          ssl << "GET /tls HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
          ssl.flush
          body = ssl.gets_to_end
          ssl.close
          seen.receive

          subject.should contain("origin.test") # relayed opaquely — no leaf was minted
          body.should contain("passthrough-secret")
          sink.requests.should be_empty # nothing decrypted means nothing recorded
        end
      end
    end

    it "relays a SERVER-SPEAKS-FIRST peer on a listed host without waiting out the read timeout" do
      # The hang the ordering was introduced to fix, and it must stay fixed: the client is
      # waiting for a banner, so it sends nothing, and a peek with no deadline means both peers
      # wait 30 s with the origin never dialled. The deadline is `PASSTHROUGH_PEEK_WAIT`, so
      # this completes in about a second — the assertion is bounded well below the 30 s that
      # would mean the wait came back.
      dialled = Channel(Nil).new(2)
      origin = start_banner_origin(dialled)
      with_passthrough(["localhost"]) do
        with_socks5_listener do |proxy, sink, _done, _|
          started = Time.instant
          sock, reply = socks5_connect(proxy.port, "localhost", origin)
          reply[1].should eq(Socks5::REP_SUCCEEDED)
          sock.read_timeout = 20.seconds
          sock.gets.should eq("220 banner.origin ESMTP ready")
          elapsed = Time.instant - started
          sock.close
          dialled.receive # gori really reached the origin

          elapsed.should be < 15.seconds

          # AND THE OPERATOR IS TOLD. A blind relay produces no flow by construction, so
          # without this the History for a listed host is empty whether the client sent
          # nothing, sent everything, or never connected — the failure the whole change is
          # about. The row names the setting, the destination, and that it stands for every
          # later connection too.
          await_flows(sink)
          sink.requests.size.should eq(1)
          sink.requests.first.host.should eq("localhost")
          msg = sink.responses.first.error.to_s
          msg.should contain("no capture")
          msg.should contain("network.tls_passthrough")
          msg.should contain("SERVER-SPEAKS-FIRST")
          msg.should contain("byte-exact")
        end
      end
    end

    it "writes the blackout advisory ONCE per destination while relaying every connection" do
      # `ssh -D` opens a connection per session. A row apiece would drown the History this tool
      # exists to produce — the same measurement that took the connect-and-close row out of
      # this listener — so the sentence is about the SETTING and is written once, and says so
      # in as many words. What must NOT be bounded is the RELAY: every later connection is
      # still carried.
      dialled = Channel(Nil).new(4)
      origin = start_banner_origin(dialled)
      with_passthrough(["localhost"]) do
        with_socks5_listener do |proxy, sink, _done, _|
          3.times do
            sock, reply = socks5_connect(proxy.port, "localhost", origin)
            reply[1].should eq(Socks5::REP_SUCCEEDED)
            sock.read_timeout = 20.seconds
            sock.gets.should eq("220 banner.origin ESMTP ready") # relayed, every time
            sock.close
            dialled.receive
          end
          sleep 0.2.seconds
          sink.requests.size.should eq(1) # advised once
        end
      end
    end

    it "leaves a host NOT on the list alone — a silent client is still not relayed" do
      # The capture bargain on every other destination is not this change's to renegotiate. An
      # unlisted host keeps the 30 s wait and the `record_silent_client` flow, so the origin is
      # NOT dialled while the client stays quiet — which is what `dialled` being empty after
      # several times the passthrough deadline proves.
      dialled = Channel(Nil).new(2)
      origin = start_banner_origin(dialled)
      with_passthrough(["not-this-host.test"]) do
        with_socks5_listener do |proxy, _sink, _done, _|
          sock, reply = socks5_connect(proxy.port, "localhost", origin)
          reply[1].should eq(Socks5::REP_SUCCEEDED)
          sleep 3.seconds # three times PASSTHROUGH_PEEK_WAIT, and nothing may happen
          # A NON-BLOCKING look at the channel: `receive` would wait out the listener's own 30 s
          # and turn a failure into a hang, and the question here is only whether anything has
          # been queued by now.
          select
          when dialled.receive
            fail "an unlisted host was relayed before the client said anything"
          else
            # Nothing dialled, which is the whole assertion.
          end
          sock.close
        end
      end
    end
  end
end
