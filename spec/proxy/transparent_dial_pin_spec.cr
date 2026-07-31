require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

include Gori::Proxy
include Gori::Proxy::Tls

# #529 — a transparent listener's destination HOST used to be whatever the client wrote in
# `Host` / SNI, because ONE value did two jobs: it named the connection AND it was resolved to
# get an address. These specs exercise the split — the NAME still drives the certificate,
# scope and History, while the DIAL is pinned to the address the kernel says the client was
# actually going to.
#
# The kernel answer itself (`Proxy::OrigDst`) cannot be produced in a spec: it needs a
# root-owned iptables/pf redirect rule in front of the listener. So these drive the two seams
# the `Server` fills from it — `ClientConn`'s `origin_dst:` and `Tls::Tunnel#intercept`'s
# `dial_addr:` — with the answer injected, which is exactly the value `Server#transparent_dst`
# computes.
#
# The lie the client tells is `::1` while the kernel says `127.0.0.1`. Two IP LITERALS on
# purpose: every origin here binds 127.0.0.1 only, so the lie is refused instantly by the OS
# rather than waiting on a resolver or a connect timeout, and each pair of examples differs in
# exactly one argument — `dial_addr` / `origin_dst`.
private DECOY      = "::1"
private DECOY_HOST = "[::1]" # the bracketed `Host`-header / authority form

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

# The only wait in this file, and it is bounded. A pin that fails to reach the dial shows up
# as a flow that is never recorded, and a bare `receive` would turn that into a hung suite
# rather than a failure naming what did not happen. Everything the ORIGIN saw is read off a
# plain Array afterwards instead of a second channel — `done` already sequences it (the origin
# has replied before a response can be recorded), and it keeps the assertions non-blocking.
private def within(ch : Channel(Nil), what : String) : Nil
  select
  when ch.receive
    nil
  when timeout(15.seconds)
    fail "timed out waiting for #{what}"
  end
end

# A cleartext origin that reports the request line and the `Host` header it was handed.
private def start_plain_origin(seen : Array(String)) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      begin
        head = Codec::Http1.read_head(conn)
        next unless head
        text = String.new(head)
        seen << text.lines.first + " | " + (text.lines.find(&.downcase.starts_with?("host:")) || "").strip
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        conn.flush
        conn.close
      rescue
      end
    end
  end
  port
end

# A self-signed TLS origin, CN=origin.test — so the certificate the client ends up validating
# says who terminated its TLS (a leaf for the name the client asked for means gori did).
private def start_tls_origin(body : String, seen : Array(String)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head # the ALPN-reflection probe sends nothing
        seen << String.new(head).lines.first
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

# `Server#serve_transparent`'s CLEARTEXT branch, with the kernel answer injected: one
# ClientConn over an accepted socket, `default_port` declared, `origin_dst` supplied or not.
private def with_transparent_conn(sink : FlowSink, default_port : Int32,
                                  origin_dst : {String, Int32}?, &)
  listener = TCPServer.new("127.0.0.1", 0)
  spawn do
    if accepted = listener.accept?
      ClientConn.new(accepted, "http", sink,
        default_port: default_port, origin_dst: origin_dst).run
    end
  end
  client = TCPSocket.new("127.0.0.1", listener.local_address.port)
  client.read_timeout = 15.seconds
  begin
    yield client
  ensure
    client.close rescue nil
    listener.close rescue nil
  end
end

# `Server#serve_transparent_tls`'s MITM branch: `host` is the name read off the ClientHello,
# `dial_addr` the kernel's address. No PrefixIO — nothing was consumed here, so the accepted
# socket still holds the ClientHello for OpenSSL, exactly as on the reverse path.
private def with_transparent_tls(sink : FlowSink, ca_dir : String, host : String,
                                 port : Int32, dial_addr : String?, &)
  ca = CertAuthority.load_or_create(ca_dir)
  tunnel = Tunnel.new(ca, verify_upstream: false)
  listener = TCPServer.new("127.0.0.1", 0)
  spawn do
    if accepted = listener.accept?
      tunnel.intercept(host, port, accepted, sink, dial_addr: dial_addr)
    end
  end
  raw = TCPSocket.new("127.0.0.1", listener.local_address.port)
  raw.read_timeout = 15.seconds
  begin
    yield raw
  ensure
    raw.close rescue nil
    listener.close rescue nil
  end
end

# verify_mode NONE: the leaf is minted for an IP literal the client reached over a different
# address, which is the whole point — what is asserted is the certificate's IDENTITY, read off
# the peer certificate directly.
private def gori_leaf_client(raw : TCPSocket, sni : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
end

private def subject_of(tls : OpenSSL::SSL::Socket::Client) : String
  tls.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
end

describe "transparent dial pin (#529)" do
  describe Gori::Proxy::Upstream do
    # The chokepoint itself. Everything else in this file only proves the pin REACHES here.
    it "connects to the pin instead of resolving the name" do
      listener = TCPServer.new("127.0.0.1", 0)
      begin
        sock = Upstream.dial(DECOY, listener.local_address.port, pin: "127.0.0.1")
        sock.should_not be_nil
        sock.try(&.close)
      ensure
        listener.close
      end
    end

    it "resolves the name when nothing pinned the dial — the pre-#529 behaviour every other mode keeps" do
      listener = TCPServer.new("127.0.0.1", 0)
      begin
        Upstream.dial(DECOY, listener.local_address.port).should be_nil
      ensure
        listener.close
      end
    end

    # Precedence, and it is a decision rather than an accident: a hostname override is a
    # declaration the OPERATOR wrote, while the pin closes a hole where the CLIENT decided.
    # Letting the pin win would make every host override a silent no-op on a transparent
    # listener — see Upstream.connect_target.
    it "lets an operator's hostname override beat the pin" do
      listener = TCPServer.new("127.0.0.1", 0)
      begin
        Gori::Settings.hostname_overrides = [{DECOY, "127.0.0.1"}]
        # 240.0.0.1 is reserved and unroutable: if the pin won, this dial could only fail.
        sock = Upstream.dial(DECOY, listener.local_address.port, 2.seconds, pin: "240.0.0.1")
        sock.should_not be_nil
        sock.try(&.close)
      ensure
        Gori::Settings.hostname_overrides = [] of {String, String}
        listener.close
      end
    end
  end

  describe "cleartext" do
    # THE CONTROL for the cleartext half — the bug, reproduced. Same origin, same port, one
    # argument different.
    it "follows a lying Host header when nothing pinned the dial" do
      seen = [] of String
      done = Channel(Nil).new(1)
      origin_port = start_plain_origin(seen)
      sink = RecordingSink.new(done)
      with_transparent_conn(sink, default_port: origin_port, origin_dst: nil) do |client|
        client << "GET /pinned HTTP/1.1\r\nHost: #{DECOY_HOST}\r\n\r\n"
        client.flush
        response = client.gets_to_end
        within(done, "the failed flow to be recorded")
        # The dial went where the header said, so it never reached the origin this connection
        # was actually redirected to.
        response.should contain("502")
        seen.should be_empty
      end
    end

    it "dials the kernel's address while the Host header still names the destination" do
      seen = [] of String
      done = Channel(Nil).new(1)
      origin_port = start_plain_origin(seen)
      sink = RecordingSink.new(done)
      with_transparent_conn(sink, default_port: 80,
        origin_dst: {"127.0.0.1", origin_port}) do |client|
        client << "GET /pinned HTTP/1.1\r\nHost: #{DECOY_HOST}\r\n\r\n"
        client.flush
        response = client.gets_to_end
        within(done, "the flow to be recorded")

        response.should contain("200 OK")
        response.should contain("hi")
        # The NAME went upstream byte-exact (P7) — the pin changed the connect target, not the
        # request. An origin serving several vhosts still gets the one the client asked for.
        seen.first.should eq("GET /pinned HTTP/1.1 | Host: #{DECOY_HOST}")
        # …and History records the name too, not the address it was reached at.
        sink.requests.size.should eq(1)
        sink.requests.first.host.should eq(DECOY)
        sink.requests.first.port.should eq(origin_port)
      end
    end

    # #528's no-name case, unchanged: with no `Host` at all the kernel's address IS the name,
    # so the pin is a no-op and the request reaches the origin exactly as it did before.
    it "still serves a request with no Host header at all" do
      seen = [] of String
      done = Channel(Nil).new(1)
      origin_port = start_plain_origin(seen)
      sink = RecordingSink.new(done)
      with_transparent_conn(sink, default_port: 80,
        origin_dst: {"127.0.0.1", origin_port}) do |client|
        client << "GET /noname HTTP/1.0\r\n\r\n"
        client.flush
        client.gets_to_end.should contain("200 OK")
        within(done, "the flow to be recorded")
        seen.first.should start_with("GET /noname HTTP/1.0")
        sink.requests.first.host.should eq("127.0.0.1")
      end
    end
  end

  describe "TLS MITM" do
    # THE CONTROL for the TLS half: the SNI decides the dial, so a client that names a host it
    # did not connect to is followed there — past a perfectly reachable origin at the pinned
    # address.
    it "follows a lying SNI when nothing pinned the dial" do
      dir = File.tempname("gori-pin-ca")
      Dir.mkdir_p(dir)
      seen = [] of String
      done = Channel(Nil).new(1)
      begin
        origin_port = start_tls_origin("SECRET", seen)
        sink = RecordingSink.new(done)
        with_transparent_tls(sink, dir, DECOY, origin_port, dial_addr: nil) do |raw|
          tls = gori_leaf_client(raw, DECOY)
          tls << "GET /secret HTTP/1.1\r\nHost: #{DECOY_HOST}\r\n\r\n"
          tls.flush
          response = tls.gets_to_end
          within(done, "the failed flow to be recorded")
          response.should contain("502")
          seen.should be_empty
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "mints the leaf for the SNI while dialing the kernel's address" do
      dir = File.tempname("gori-pin-ca")
      Dir.mkdir_p(dir)
      seen = [] of String
      done = Channel(Nil).new(1)
      begin
        origin_port = start_tls_origin("SECRET", seen)
        sink = RecordingSink.new(done)
        with_transparent_tls(sink, dir, DECOY, origin_port, dial_addr: "127.0.0.1") do |raw|
          tls = gori_leaf_client(raw, DECOY)
          subject = subject_of(tls)
          tls << "GET /secret HTTP/1.1\r\nHost: #{DECOY_HOST}\r\n\r\n"
          tls.flush
          response = tls.gets_to_end
          within(done, "the flow to be recorded")

          # The certificate is minted for the NAME, and the pinned address never appears in
          # it — conflating the two is exactly what would break the client.
          subject.should contain(DECOY)
          subject.should_not contain("origin.test") # gori's leaf, not the origin's own
          subject.should_not contain("127.0.0.1")
          # …and the dial still landed on the pinned origin.
          response.should contain("SECRET")
          seen.first.should eq("GET /secret HTTP/1.1")

          sink.requests.size.should eq(1)
          sink.requests.first.scheme.should eq("https")
          sink.requests.first.host.should eq(DECOY)
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
