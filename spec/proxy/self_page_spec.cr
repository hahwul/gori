require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

# Records captured flows in memory so the proxy can be driven without a DB. A
# self-page hit records NOTHING (it's a local UI response, not proxied traffic),
# so `responses` staying empty is itself an assertion.
private class RecordingSink < Gori::Proxy::FlowSink
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

# Read a whole response (the server sends `Connection: close`, so the socket EOFs)
# as raw bytes, robust to a binary DER body.
private def read_all(io : IO) : Bytes
  buf = IO::Memory.new
  IO.copy(io, buf)
  buf.to_slice
end

# Split an HTTP response into its header text and body bytes at CRLFCRLF.
private def split_response(resp : Bytes) : {String, Bytes}
  i = 0
  while i + 3 < resp.size
    if resp[i] == 0x0d && resp[i + 1] == 0x0a && resp[i + 2] == 0x0d && resp[i + 3] == 0x0a
      return {String.new(resp[0, i]), resp[(i + 4)..]}
    end
    i += 1
  end
  {String.new(resp), Bytes.empty}
end

# Stand up a live proxy whose TLS tunnel carries a real CA, so the self-page can
# hand out the cert. Yields {proxy, ca, sink, done}.
private def with_landing_proxy(serve_landing : Bool, &)
  dir = File.tempname("gori-selfpage-ca")
  Dir.mkdir_p(dir)
  ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
  tunnel = Gori::Proxy::Tls::Tunnel.new(ca, serve_landing: serve_landing)
  done = Channel(Nil).new(4)
  sink = RecordingSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel)
  proxy.start
  begin
    yield proxy, ca, sink, done
  ensure
    proxy.stop
    FileUtils.rm_rf(dir)
  end
end

describe Gori::Proxy::SelfPage do
  describe ".route" do
    it "maps known paths and strips query/fragment" do
      Gori::Proxy::SelfPage.route("").should eq(:index)
      Gori::Proxy::SelfPage.route("/").should eq(:index)
      Gori::Proxy::SelfPage.route("/ca.pem").should eq(:pem)
      Gori::Proxy::SelfPage.route("/ca.pem?x=1").should eq(:pem)
      Gori::Proxy::SelfPage.route("/ca.der").should eq(:der)
      Gori::Proxy::SelfPage.route("/ca.crt").should eq(:der)
      Gori::Proxy::SelfPage.route("/favicon.ico").should eq(:favicon)
      Gori::Proxy::SelfPage.route("/nope").should eq(:not_found)
    end

    # A proxy-configured client sends the ABSOLUTE form, so the authority reaches `route`
    # too. Without the strip every magic-host request 404s instead of serving the cert.
    it "routes an absolute-form target by its path (a proxy-configured client)" do
      Gori::Proxy::SelfPage.route("http://gori.proxy/").should eq(:index)
      Gori::Proxy::SelfPage.route("http://gori.proxy").should eq(:index) # no path at all
      Gori::Proxy::SelfPage.route("http://gori.proxy/ca.pem").should eq(:pem)
      Gori::Proxy::SelfPage.route("http://gori.proxy/ca.der?x=1").should eq(:der)
      Gori::Proxy::SelfPage.route("https://gori.proxy/ca.crt").should eq(:der)
      Gori::Proxy::SelfPage.route("http://127.0.0.1:8070/ca.pem").should eq(:pem)
      Gori::Proxy::SelfPage.route("http://gori.proxy/nope").should eq(:not_found)
    end

    # The query strip runs first, so a '/' inside the query can't be read as the path.
    it "does not mistake a slash inside the query for the path" do
      Gori::Proxy::SelfPage.route("http://gori.proxy?next=/ca.der").should eq(:index)
    end
  end

  describe ".magic_host?" do
    it "matches the reserved names, case-insensitively and with a trailing dot" do
      Gori::Proxy::SelfPage.magic_host?("gori.proxy").should be_true
      Gori::Proxy::SelfPage.magic_host?("GORI.PROXY").should be_true
      Gori::Proxy::SelfPage.magic_host?("gori.proxy.").should be_true # fully-qualified
      Gori::Proxy::SelfPage.magic_host?("gori").should be_true
      Gori::Proxy::SelfPage.magic_host?("gori.").should be_true
    end

    it "does not match a lookalike that a real origin could own" do
      Gori::Proxy::SelfPage.magic_host?("gori.proxy.com").should be_false
      Gori::Proxy::SelfPage.magic_host?("evil.gori.proxy").should be_false
      Gori::Proxy::SelfPage.magic_host?("agori").should be_false
      Gori::Proxy::SelfPage.magic_host?("gori.local").should be_false
      Gori::Proxy::SelfPage.magic_host?("example.com").should be_false
      Gori::Proxy::SelfPage.magic_host?("").should be_false
    end
  end

  describe ".respond" do
    pem = "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n"
    der = Bytes[0x30, 0x82, 0x01, 0x02]
    listen = {"127.0.0.1", 8070}

    it "serves the HTML info page for /" do
      resp = Gori::Proxy::SelfPage.respond("/", pem: pem, der: der, spki: "SPKI==",
        ca_path: "/home/u/.gori/ca/root.crt.pem", listen: listen, version: "9.9.9", head_only: false)
      head, body = split_response(resp)
      head.should contain("200 OK")
      head.should contain("text/html")
      text = String.new(body)
      text.should contain("gori")
      text.should contain("localhost:8070")
      text.should contain("9.9.9")
      text.should contain("/ca.der")
      text.should contain("/ca.pem")
    end

    it "brackets an IPv6 reached-address on the Listening line" do
      # Since 5b956ee `listen[0]` is the CONCRETE address the device reached us on, which
      # under a `::` bind is a bare IPv6 literal — "fe80::1:8070" is ambiguous and not
      # copy-pasteable, which matters most here since this page exists to be read off a
      # phone screen.
      resp = Gori::Proxy::SelfPage.respond("/", pem: pem, der: der, spki: "SPKI==",
        ca_path: "/home/u/.gori/ca/root.crt.pem", listen: {"fe80::1", 8070},
        version: "9.9.9", head_only: false)
      _, body = split_response(resp)
      String.new(body).should contain("[fe80::1]:8070")
    end

    it "serves the PEM with an attachment disposition" do
      resp = Gori::Proxy::SelfPage.respond("/ca.pem", pem: pem, der: der, spki: nil,
        ca_path: nil, listen: listen, version: "1", head_only: false)
      head, body = split_response(resp)
      head.should contain("200 OK")
      head.should contain("application/x-pem-file")
      head.should contain(%(Content-Disposition: attachment; filename="gori-ca.pem"))
      String.new(body).should eq(pem)
    end

    it "serves the DER bytes verbatim" do
      resp = Gori::Proxy::SelfPage.respond("/ca.der", pem: pem, der: der, spki: nil,
        ca_path: nil, listen: listen, version: "1", head_only: false)
      head, body = split_response(resp)
      head.should contain("200 OK")
      head.should contain("application/x-x509-ca-cert")
      head.should contain(%(filename="gori-ca.der"))
      body.should eq(der)
    end

    it "404s a cert download when there is no CA (MITM off)" do
      resp = Gori::Proxy::SelfPage.respond("/ca.pem", pem: nil, der: nil, spki: nil,
        ca_path: nil, listen: listen, version: "1", head_only: false)
      String.new(resp).should contain("404 Not Found")
    end

    it "204s the favicon and 404s an unknown path" do
      String.new(Gori::Proxy::SelfPage.respond("/favicon.ico", pem: pem, der: der, spki: nil,
        ca_path: nil, listen: listen, version: "1", head_only: false)).should contain("204 No Content")
      String.new(Gori::Proxy::SelfPage.respond("/nope", pem: pem, der: der, spki: nil,
        ca_path: nil, listen: listen, version: "1", head_only: false)).should contain("404 Not Found")
    end

    it "omits the body for a HEAD request but keeps the headers" do
      resp = Gori::Proxy::SelfPage.respond("/", pem: pem, der: der, spki: nil,
        ca_path: nil, listen: listen, version: "1", head_only: true)
      head, body = split_response(resp)
      head.should contain("200 OK")
      head.should contain("Content-Length:")
      body.empty?.should be_true
    end
  end
end

describe "direct listener access (self-page)" do
  it "serves the info page for a direct GET / and records no flow" do
    with_landing_proxy(serve_landing: true) do |proxy, _ca, sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\n\r\n"
      client.flush
      resp = String.new(read_all(client))
      client.close

      resp.should contain("200 OK")
      resp.should contain("text/html")
      resp.should contain("gori")
      sink.responses.size.should eq(0) # a local UI hit is never captured as a flow
    end
  end

  it "serves the CA certificate as PEM on /ca.pem" do
    with_landing_proxy(serve_landing: true) do |proxy, ca, _sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /ca.pem HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\n\r\n"
      client.flush
      head, body = split_response(read_all(client))
      client.close

      head.should contain("application/x-pem-file")
      String.new(body).should eq(ca.ca_cert_pem)
    end
  end

  it "serves the CA certificate as DER on /ca.der" do
    with_landing_proxy(serve_landing: true) do |proxy, ca, _sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /ca.der HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\n\r\n"
      client.flush
      head, body = split_response(read_all(client))
      client.close

      head.should contain("application/x-x509-ca-cert")
      body.should eq(ca.ca_cert_der)
    end
  end

  it "still refuses (502) a direct hit when the info page is disabled" do
    with_landing_proxy(serve_landing: false) do |proxy, _ca, sink, done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\n\r\n"
      client.flush
      client.gets_to_end
      client.close

      done.receive
      sink.responses.size.should eq(1)
      sink.responses.first.state.should eq(Gori::Store::FlowState::Error)
    end
  end

  it "still refuses (502) a non-GET direct hit even with the info page enabled" do
    with_landing_proxy(serve_landing: true) do |proxy, _ca, sink, done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "POST / HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\nContent-Length: 0\r\n\r\n"
      client.flush
      client.gets_to_end
      client.close

      done.receive
      sink.responses.size.should eq(1)
      sink.responses.first.state.should eq(Gori::Store::FlowState::Error)
    end
  end

  # #280: the client set the proxy FIRST and then typed the listener address, so the request
  # arrives absolute-form. Before, that was refused as a self-loop and the cert stayed out of
  # reach; it is aimed at us, not at an origin, so there is nothing to loop.
  it "serves the info page for an absolute-form GET aimed at its own listener" do
    with_landing_proxy(serve_landing: true) do |proxy, ca, sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET http://127.0.0.1:#{proxy.port}/ca.pem HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\n\r\n"
      client.flush
      head, body = split_response(read_all(client))
      client.close

      head.should contain("application/x-pem-file")
      String.new(body).should eq(ca.ca_cert_pem)
      sink.responses.size.should eq(0)
    end
  end
end

# #280: the mitm.it-style entry point. A client that already has gori configured as its
# proxy sends absolute-form (or CONNECT), so it can never match the direct-hit test above —
# a reserved hostname is the only unambiguous way to hand it the CA.
describe "magic host (proxy-configured client)" do
  it "serves the info page for an absolute-form GET to the reserved host" do
    with_landing_proxy(serve_landing: true) do |proxy, _ca, sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET http://gori.proxy/ HTTP/1.1\r\nHost: gori.proxy\r\n\r\n"
      client.flush
      resp = String.new(read_all(client))
      client.close

      resp.should contain("200 OK")
      resp.should contain("text/html")
      sink.responses.size.should eq(0) # a local UI hit is never captured as a flow
    end
  end

  it "serves the CA on /ca.der over the reserved host" do
    with_landing_proxy(serve_landing: true) do |proxy, ca, _sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET http://gori.proxy/ca.der HTTP/1.1\r\nHost: gori.proxy\r\n\r\n"
      client.flush
      head, body = split_response(read_all(client))
      client.close

      head.should contain("application/x-x509-ca-cert")
      body.should eq(ca.ca_cert_der)
    end
  end

  # A transparent/redirecting proxy hands us origin-form with the name in Host. The
  # port-gated addresses_self? can't see that (Host carries no port -> 80), so this proves
  # the name test covers the shape too.
  it "serves the info page for origin-form with the reserved name in Host" do
    with_landing_proxy(serve_landing: true) do |proxy, _ca, sink, _done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET / HTTP/1.1\r\nHost: gori\r\n\r\n"
      client.flush
      resp = String.new(read_all(client))
      client.close

      resp.should contain("200 OK")
      resp.should contain("text/html")
      sink.responses.size.should eq(0)
    end
  end

  # The reserved name must NEVER reach Upstream.dial: bare "gori" resolves on any network
  # with a DNS search domain, so a fall-through would ship the request to a stranger. Both
  # non-servable shapes below must refuse locally instead.
  it "refuses a non-GET to the reserved host without dialing it" do
    with_landing_proxy(serve_landing: true) do |proxy, _ca, sink, done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "POST http://gori.proxy/ HTTP/1.1\r\nHost: gori.proxy\r\nContent-Length: 0\r\n\r\n"
      client.flush
      String.new(read_all(client)).should contain("502")
      client.close

      done.receive
      sink.responses.size.should eq(1)
      resp = sink.responses.first
      resp.state.should eq(Gori::Store::FlowState::Error)
      # names the reserved host, NOT "upstream connect failed" — proof we never dialed
      resp.error.not_nil!.should contain("reserved host")
    end
  end

  it "refuses the reserved host when the info page is disabled, without dialing it" do
    with_landing_proxy(serve_landing: false) do |proxy, _ca, sink, done|
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET http://gori.proxy/ HTTP/1.1\r\nHost: gori.proxy\r\n\r\n"
      client.flush
      String.new(read_all(client)).should contain("502")
      client.close

      done.receive
      sink.responses.first.error.not_nil!.should contain("reserved host")
    end
  end

  # The ESCAPE HATCH: a LAN that has a real box called "gori" gets it back by writing a host
  # override, and gori then proxies the name instead of answering for it. `reserved_self_host?`
  # used to read the per-project table only, so an operator who wrote the override in
  # settings.json — the global layer, and the only one a session with no project has — still
  # got the setup page (or a 502) with no way out. Asserted by reaching a real listener the
  # override names, which is something the self-page branch can never do.
  it "proxies the reserved host when a GLOBAL override claims it" do
    origin = TCPServer.new("127.0.0.1", 0)
    spawn do
      if conn = origin.accept?
        while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
        end
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nreal-lan"
        conn.flush rescue nil
        conn.close rescue nil
      end
    end
    begin
      Gori::Settings.hostname_overrides = [{"gori.proxy", "127.0.0.1:#{origin.local_address.port}"}]
      with_landing_proxy(serve_landing: true) do |proxy, _ca, _sink, done|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET http://gori.proxy/ HTTP/1.1\r\nHost: gori.proxy\r\n\r\n"
        client.flush
        resp = String.new(read_all(client))
        client.close

        resp.should contain("200 OK")
        resp.should contain("real-lan") # the LAN box answered…
        resp.should_not contain("text/html")
        done.receive # …and it was proxied traffic, so it IS captured (a self-page hit is not)
      end
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
      origin.close
    end
  end

  # `magic_host?` chomps a trailing root dot, so "gori.proxy." is reserved too — and the
  # escape hatch has to fold the same way or that one spelling is unescapable. Same override,
  # the fully-qualified request.
  it "proxies the fully-qualified spelling of the reserved host too" do
    origin = TCPServer.new("127.0.0.1", 0)
    spawn do
      if conn = origin.accept?
        while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
        end
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nreal-lan"
        conn.flush rescue nil
        conn.close rescue nil
      end
    end
    begin
      Gori::Settings.hostname_overrides = [{"gori.proxy", "127.0.0.1:#{origin.local_address.port}"}]
      with_landing_proxy(serve_landing: true) do |proxy, _ca, _sink, done|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET / HTTP/1.1\r\nHost: gori.proxy.\r\n\r\n"
        client.flush
        resp = String.new(read_all(client))
        client.close

        resp.should contain("real-lan")
        done.receive
      end
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
      origin.close
    end
  end

  # https://gori.proxy/ — the HTTPS-First shape. gori answers the CONNECT itself and serves
  # the page under its own leaf. Verification is left ON here so a broken SAN for the
  # reserved name fails the test rather than passing silently.
  it "MITMs a CONNECT to the reserved host and serves the page under its own leaf" do
    with_landing_proxy(serve_landing: true) do |proxy, ca, sink, _done|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT gori.proxy:443 HTTP/1.1\r\nHost: gori.proxy:443\r\n\r\n"
      raw.flush
      String.new(Gori::Proxy::Codec::Http1.read_head(raw).not_nil!).should contain("200")

      ctx = OpenSSL::SSL::Context::Client.new
      ctx.ca_certificates = ca.ca_cert_path.not_nil!
      tls = OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: "gori.proxy")
      tls << "GET /ca.der HTTP/1.1\r\nHost: gori.proxy\r\n\r\n"
      tls.flush
      head, body = split_response(read_all(tls))
      tls.close

      head.should contain("application/x-x509-ca-cert")
      body.should eq(ca.ca_cert_der)
      sink.responses.size.should eq(0) # still not proxied traffic
    end
  end

  it "answers 405 rather than hanging on a non-GET inside the CONNECT tunnel" do
    with_landing_proxy(serve_landing: true) do |proxy, ca, _sink, _done|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT gori.proxy:443 HTTP/1.1\r\nHost: gori.proxy:443\r\n\r\n"
      raw.flush
      Gori::Proxy::Codec::Http1.read_head(raw).not_nil!

      ctx = OpenSSL::SSL::Context::Client.new
      ctx.ca_certificates = ca.ca_cert_path.not_nil!
      tls = OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: "gori.proxy")
      tls << "POST / HTTP/1.1\r\nHost: gori.proxy\r\nContent-Length: 0\r\n\r\n"
      tls.flush
      resp = String.new(read_all(tls))
      tls.close

      resp.should contain("405")
    end
  end

  # CONNECT to :80 then plaintext (curl --proxytunnel). No ClientHello arrives, so forcing a
  # TLS handshake would just hang the client; the peek falls it back to serving in the clear.
  it "serves in the clear when a CONNECT tunnel carries plaintext, not TLS" do
    with_landing_proxy(serve_landing: true) do |proxy, _ca, _sink, _done|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT gori.proxy:80 HTTP/1.1\r\nHost: gori.proxy:80\r\n\r\n"
      raw.flush
      Gori::Proxy::Codec::Http1.read_head(raw).not_nil!

      raw << "GET / HTTP/1.1\r\nHost: gori.proxy\r\n\r\n"
      raw.flush
      resp = String.new(read_all(raw))
      raw.close

      resp.should contain("200 OK")
      resp.should contain("text/html")
    end
  end

  it "refuses a CONNECT to the reserved host when the info page is disabled" do
    with_landing_proxy(serve_landing: false) do |proxy, _ca, _sink, _done|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT gori.proxy:443 HTTP/1.1\r\nHost: gori.proxy:443\r\n\r\n"
      raw.flush
      String.new(read_all(raw)).should contain("502")
      raw.close
    end
  end
end
