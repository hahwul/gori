require "../../spec_helper"
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

# A self-signed HTTP/1.1 TLS origin whose certificate is CN=origin.test — deliberately NOT the
# host the client CONNECTs to. That mismatch is the whole measuring instrument here: whichever
# certificate the client ends up validating names who terminated its TLS. gori's leaf is minted
# for the CONNECT authority ("localhost"), so `CN=localhost` means MITM and `CN=origin.test`
# means the bytes went through untouched.
private def start_pinned_origin(body : String, seen : Channel(String)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head # an ALPN probe connection sends nothing
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

# A client context that validates nothing, so the spec can read the certificate the client was
# actually handed (peer_certificate) instead of inferring MITM from a handshake failure.
private def blind_client_context : OpenSSL::SSL::Context::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  ctx
end

# CONNECT through `proxy` to localhost:`origin_port`, then GET / over TLS. Yields the subject of
# the certificate the client was served plus the response text.
private def connect_and_get(proxy : Server, origin_port : Int32) : {String, String}
  raw = TCPSocket.new("127.0.0.1", proxy.port)
  raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
  raw.flush
  String.new(Codec::Http1.read_head(raw).not_nil!).should contain("200")

  tls = OpenSSL::SSL::Socket::Client.new(raw, context: blind_client_context,
    sync_close: true, hostname: "localhost")
  # X509::Name has no to_s override (it renders as #<OpenSSL::X509::Name:0x…>), so flatten the
  # RDNs by hand to get an assertable "CN=…" string.
  subject = tls.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
  tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
  tls.flush
  response = tls.gets_to_end
  tls.close
  {subject, response}
end

# Stand up a CA-backed proxy with `passthrough` configured, and always restore the global
# setting — it is process-wide state that would otherwise leak into every later spec.
private def with_passthrough_proxy(passthrough : Array(String), &)
  dir = File.tempname("gori-passthrough-ca")
  seen = Channel(String).new(2)
  done = Channel(Nil).new(2)
  saved = Gori::Settings.tls_passthrough
  begin
    Gori::Settings.tls_passthrough = passthrough
    origin_port = start_pinned_origin("TOP SECRET", seen)
    ca = CertAuthority.load_or_create(dir)
    sink = RecordingSink.new(done)
    proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
    proxy.start
    begin
      yield proxy, origin_port, sink, seen, done
    ensure
      proxy.stop
    end
  ensure
    Gori::Settings.tls_passthrough = saved
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

describe "TLS passthrough" do
  # The feature: a pinning client must reach the origin's OWN certificate. Asserted by
  # certificate identity, not by inference — CN=origin.test can only have come from the origin.
  it "relays a listed host opaquely: the client validates the ORIGIN's certificate" do
    with_passthrough_proxy(["localhost"]) do |proxy, origin_port, sink, seen, _done|
      subject, response = connect_and_get(proxy, origin_port)

      subject.should contain("origin.test") # the origin terminated TLS, not gori
      subject.should_not contain("localhost")
      response.should contain("200 OK")
      response.should contain("TOP SECRET") # the tunnel still carries traffic end-to-end
      seen.receive.should eq("GET /secret HTTP/1.1")

      # Nothing decrypted means nothing to record. An empty sink IS the assertion.
      sink.requests.should be_empty
      sink.responses.should be_empty
    end
  end

  # The control for the test above: same proxy, same origin, same client — only the setting
  # differs. Without it, "the handshake behaved differently" would not pin the cause.
  it "still MITMs the same host when the list does not cover it" do
    with_passthrough_proxy([] of String) do |proxy, origin_port, sink, _seen, done|
      subject, response = connect_and_get(proxy, origin_port)
      done.receive

      subject.should contain("localhost") # gori's leaf, minted for the CONNECT authority
      subject.should_not contain("origin.test")
      response.should contain("TOP SECRET")
      sink.requests.size.should eq(1)
      sink.requests.first.target.should eq("/secret")
    end
  end

  # Subdomain semantics come from the shared scope host dialect: a bare pattern covers children.
  it "covers subdomains of a bare pattern, via the shared host-pattern dialect" do
    Gori::Settings.tls_passthrough = ["acme.test"]
    Gori::Settings.tls_passthrough?("acme.test").should be_true
    Gori::Settings.tls_passthrough?("api.acme.test").should be_true
    Gori::Settings.tls_passthrough?("acme.test.evil.test").should be_false
    Gori::Settings.tls_passthrough?("notacme.test").should be_false
  ensure
    Gori::Settings.tls_passthrough = [] of String
  end

  it "treats a glob pattern as a glob (subdomains only, not the bare host)" do
    Gori::Settings.tls_passthrough = ["*.acme.test"]
    Gori::Settings.tls_passthrough?("api.acme.test").should be_true
    Gori::Settings.tls_passthrough?("acme.test").should be_false
  ensure
    Gori::Settings.tls_passthrough = [] of String
  end

  it "matches an IPv6 literal whether the pattern or the host is bracketed" do
    Gori::Settings.tls_passthrough = ["[::1]"]
    Gori::Settings.tls_passthrough?("::1").should be_true
    Gori::Settings.tls_passthrough = ["::1"]
    Gori::Settings.tls_passthrough?("[::1]").should be_true
  ensure
    Gori::Settings.tls_passthrough = [] of String
  end

  it "is case-insensitive and off by default" do
    Gori::Settings.tls_passthrough?("acme.test").should be_false # empty list = MITM everything
    Gori::Settings.tls_passthrough = ["ACME.test"]
    Gori::Settings.tls_passthrough?("api.Acme.TEST").should be_true
  ensure
    Gori::Settings.tls_passthrough = [] of String
  end

  # A malformed glob must never unwind onto the proxy hot path — a CONNECT would die with it.
  it "treats a malformed glob as non-matching instead of raising" do
    Gori::Settings.tls_passthrough = ["[unclosed"]
    Gori::Settings.tls_passthrough?("anything.test").should be_false
  ensure
    Gori::Settings.tls_passthrough = [] of String
  end
end

describe "Gori::Settings.tls_passthrough_error" do
  it "accepts bare hosts, globs, and IPv6 literals" do
    Gori::Settings.tls_passthrough_error(["acme.test", "*.acme.test", "[::1]", "::1", " "]).should be_nil
  end

  # These are the plausible typos. Each would silently match NOTHING, leaving the pinned app
  # broken with the setting apparently configured — so they are rejected at save time.
  it "rejects a scheme, a path, or a :port" do
    Gori::Settings.tls_passthrough_error(["https://acme.test"]).to_s.should contain("without a scheme")
    Gori::Settings.tls_passthrough_error(["acme.test/api"]).to_s.should contain("without a path")
    Gori::Settings.tls_passthrough_error(["acme.test:443"]).to_s.should contain("without a :port")
  end
end
