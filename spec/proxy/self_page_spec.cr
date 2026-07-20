require "../spec_helper"
require "socket"
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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
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
end
