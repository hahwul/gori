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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
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

private PROXY_ENV_KEYS = [
  "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
  "http_proxy", "https_proxy", "all_proxy", "no_proxy",
]

# The process proxy variables set for one example, with gori's own upstream knobs blank so the
# environment is the route that answers, and everything put back afterwards.
private def with_proxy_environment(values : Hash(String, String), &)
  previous = PROXY_ENV_KEYS.map { |key| {key, ENV[key]?} }
  saved_proxy = Gori::Settings.upstream_proxy
  saved_project = Gori::Settings.project_upstream_proxy
  saved_rules = Gori::Settings.upstream_rules
  begin
    PROXY_ENV_KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    Gori::Settings.upstream_proxy = ""
    Gori::Settings.project_upstream_proxy = nil
    Gori::Settings.upstream_rules = [] of Gori::Settings::UpstreamRule
    yield
  ensure
    previous.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
    Gori::Settings.upstream_proxy = saved_proxy
    Gori::Settings.project_upstream_proxy = saved_project
    Gori::Settings.upstream_rules = saved_rules
  end
end

# A one-shot upstream HTTP proxy that records the CONNECT request line it was handed and answers
# 200. Whether it hears anything at all is the measurement: the environment below names it under
# `HTTPS_PROXY` only, so a dial that asked the route for an `http` origin never arrives here.
private def with_recording_upstream_proxy(&)
  server = TCPServer.new("127.0.0.1", 0)
  seen = Channel(String).new(1)
  spawn do
    conn = server.accept
    request_line = conn.gets("\r\n", chomp: true) || ""
    while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
    end
    conn << "HTTP/1.1 200 Connection established\r\n\r\n"
    conn.flush
    seen.send(request_line)
    sleep 50.milliseconds
    conn.close rescue nil
  rescue
  end
  begin
    yield server.local_address.port, seen
  ensure
    server.close rescue nil
  end
end

private def receive_within(ch : Channel(String), seconds : Int32, what : String) : String
  select
  when got = ch.receive
    got
  when timeout(seconds.seconds)
    fail "#{what} did not arrive within #{seconds}s"
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
  # The passthrough dial is a TLS origin's dial, so it must ask the environment for the proxy
  # `HTTPS_PROXY` names — the decrypting branch already does (`dial_tls_result`). It used to
  # ask for an `http` origin, which selects `HTTP_PROXY`, so an environment exporting only
  # `HTTPS_PROXY` saw the one shape it exists to carry go DIRECT — and this proxy heard nothing.
  #
  # A NON-loopback authority on purpose, and one that need not resolve: the recording proxy
  # receiving `CONNECT passthrough.test:<port>` IS the assertion, and a loopback target takes
  # the direct carve-out below before the environment is even asked.
  it "dials a passthrough CONNECT through HTTPS_PROXY, the TLS origin's variable (#1114)" do
    with_passthrough_proxy(["passthrough.test"]) do |proxy, origin_port, sink, _seen, _done|
      with_recording_upstream_proxy do |pport, connect_seen|
        with_proxy_environment({"HTTPS_PROXY" => "http://127.0.0.1:#{pport}"}) do
          raw = TCPSocket.new("127.0.0.1", proxy.port)
          raw << "CONNECT passthrough.test:#{origin_port} HTTP/1.1\r\nHost: passthrough.test:#{origin_port}\r\n\r\n"
          raw.flush
          String.new(Codec::Http1.read_head(raw).not_nil!).should contain("200")
          receive_within(connect_seen, 5, "the CONNECT at the environment proxy")
            .should eq("CONNECT passthrough.test:#{origin_port} HTTP/1.1")
          raw.close
          sink.requests.should be_empty
        end
      end
    end
  end

  # The other half of the same contract: a LOOPBACK target is direct before `NO_PROXY` or the
  # variables are consulted (DESIGN.md §7, 2026-09-21), and that holds on the passthrough path
  # too — the same `HTTPS_PROXY` that carried the CONNECT above hears nothing here. `127.0.0.1`
  # rather than `localhost`, so nothing depends on how a host resolves that name.
  it "sends a loopback passthrough CONNECT direct under the same HTTPS_PROXY (#1114)" do
    with_passthrough_proxy(["127.0.0.1"]) do |proxy, origin_port, sink, _seen, _done|
      with_recording_upstream_proxy do |pport, connect_seen|
        with_proxy_environment({"HTTPS_PROXY" => "http://127.0.0.1:#{pport}"}) do
          raw = TCPSocket.new("127.0.0.1", proxy.port)
          raw << "CONNECT 127.0.0.1:#{origin_port} HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
          raw.flush
          # 200 means the dial reached the pinned origin; a proxy that heard nothing means it
          # got there directly (a failed direct dial would have answered 502).
          String.new(Codec::Http1.read_head(raw).not_nil!).should contain("200")
          select
          when line = connect_seen.receive
            fail "the loopback CONNECT reached the environment proxy: #{line}"
          when timeout(300.milliseconds)
          end
          raw.close
          sink.requests.should be_empty
        end
      end
    end
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
