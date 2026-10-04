require "../../spec_helper"
require "socket"
require "openssl"
require "file_utils"
require "log/spec" # `Log.capture` — the handshake-failure notice in #755 is a LOG claim

include Gori::Proxy
include Gori::Proxy::Tls

# #755, half two: `handle_connect`'s first-byte peek used to route `0x50` to the h2c relay and
# EVERYTHING ELSE to a TLS server handshake. So `ssh -o ProxyCommand='nc -X connect …'` fed
# `SSH-2.0-OpenSSH…` to OpenSSL, which raised into `Tunnel#intercept`'s bare rescue and closed
# with no flow and no log — after `reflect_origin_h2` had already completed a real TLS handshake
# against the SSH server's port. Both halves are measured here: the flow, and the untouched origin.

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

# A raw TCP listener that REPORTS what reaches it, over a channel. The measuring instrument for
# the second half of the defect: gori must not touch this port at all for a tunnel it refuses. A
# NON-TLS origin on purpose — it stands in for the SSH server on port 22 that used to be handed a
# ClientHello.
#
# A channel and not a counter. An `@accepted` incremented in the accept fiber can be READ before
# that fiber has run: a TCP connect to a listening socket completes out of the backlog, so a
# regression that restored the old routing would be dialling this port while `accepted` still
# says 0, and the guard would pass green. `untouched?` instead waits for the accept to arrive and
# only calls it clean when nothing does.
private class CountingOrigin
  getter port : Int32

  def initialize
    @hits = Channel(Nil).new(4)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    server = @server
    hits = @hits
    spawn do
      while conn = server.accept?
        hits.send(nil)
        conn.close rescue nil
      end
    end
  end

  # True when no connection arrived within `wait` — an explicit "nothing came" rather than a
  # snapshot of a counter another fiber owns.
  def untouched?(wait : Time::Span = 300.milliseconds) : Bool
    select
    when @hits.receive
      false
    when timeout(wait)
      true
    end
  end

  def close : Nil
    @server.close rescue nil
  end
end

# A self-signed HTTP/1.1 TLS origin, for the examples that need the tunnel to actually work.
private def start_tls_origin(body : String) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head # the ALPN probe connection sends nothing
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

# A raw TCP origin that echoes one line back, so a byte-exact relay can be measured end to end
# rather than inferred. Returns {port, channel of the first line it received}.
private def start_echo_origin : {Int32, Channel(String)}
  seen = Channel(String).new(1)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      begin
        if line = conn.gets(chomp: false)
          seen.send(line)
          conn << "SSH-2.0-OpenSSH_9.6-origin\r\n"
          conn.flush
        end
      rescue
      ensure
        conn.close rescue nil
      end
    end
  end
  {port, seen}
end

# A CA-backed MITM proxy with NOTHING on the passthrough list — the configuration in which the
# peek runs at all.
private def with_mitm_proxy(&)
  dir = File.tempname("gori-non-tls-connect-ca")
  done = Channel(Nil).new(4)
  begin
    ca = CertAuthority.load_or_create(dir)
    sink = RecordingSink.new(done)
    tunnel = Tunnel.new(ca, verify_upstream: false)
    proxy = Server.new("127.0.0.1", 0, sink, tls: tunnel)
    proxy.start
    begin
      yield proxy, sink, done, tunnel
    ensure
      proxy.stop
    end
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

private def open_tunnel(proxy : Server, authority : String) : TCPSocket
  raw = TCPSocket.new("127.0.0.1", proxy.port)
  raw.read_timeout = 10.seconds
  raw << "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n"
  raw.flush
  String.new(Codec::Http1.read_head(raw).not_nil!).should contain("200")
  raw
end

private def blind_client_context : OpenSSL::SSL::Context::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  ctx
end

describe "a CONNECT tunnel whose payload is not TLS" do
  it "records a refusal naming tls_passthrough, and never touches the origin (#755)" do
    origin = CountingOrigin.new
    begin
      with_mitm_proxy do |proxy, sink, done|
        raw = open_tunnel(proxy, "localhost:#{origin.port}")
        raw << "SSH-2.0-OpenSSH_9.6\r\n" # what `nc -X connect` puts in the tunnel
        raw.flush
        raw.gets_to_end # nothing is written back: an SSH peer cannot parse an HTTP response
        raw.close

        receive_within(done, seconds: 10, what: "the recorded flow")
        sink.responses.size.should eq(1)
        resp = sink.responses.first
        resp.state.should eq(Gori::Store::FlowState::Error)
        msg = resp.error.not_nil!
        msg.should contain("CONNECT tunnel refused")
        # Named AND glossed: one byte, but a PRINTABLE one, so an operator debugging
        # `ProxyCommand` does not need an ASCII table to recognise their own SSH banner.
        msg.should contain("the byte 0x53 (\"S\")")
        msg.should contain("network.tls_passthrough")
        msg.should contain("Nothing was dialed")
        # The CONNECT itself is the flow, so the columns are populated (unlike a bodyless refusal).
        sink.requests.first.method.should eq("CONNECT")
        sink.requests.first.host.should eq("localhost")
        sink.requests.first.port.should eq(origin.port)
      end
      # The second half of the defect, and the reason a counting origin is here at all:
      # `reflect_origin_h2` used to complete a real ALPN-h2 TLS handshake against this port
      # before the client handshake failed.
      origin.untouched?.should be_true
    ensure
      origin.close
    end
  end

  # A ClientHello is `0x16 0x03` — the record type AND a major version of 3, which every TLS
  # version from SSL3 to 1.3 carries. `0x16` alone is not the test, and checking the second byte
  # costs one read on the TLS path and nothing anywhere else.
  it "refuses a 0x16 that is not followed by a TLS major version" do
    origin = CountingOrigin.new
    begin
      with_mitm_proxy do |proxy, sink, done|
        raw = open_tunnel(proxy, "localhost:#{origin.port}")
        raw.write(Bytes[0x16, 0x99, 0x01, 0x00])
        raw.flush
        raw.gets_to_end
        raw.close

        receive_within(done, seconds: 10, what: "the recorded flow")
        msg = sink.responses.first.error.not_nil!
        msg.should contain("CONNECT tunnel refused")
        msg.should contain("the bytes 0x16 0x99") # both bytes it judged, plural and named
      end
      origin.untouched?.should be_true
    ensure
      origin.close
    end
  end

  # The h2c arm of the same defect. `0x50` is `PUT`, `POST`, `PATCH` and `PROPFIND` as well as
  # `PRI`, so a first-byte branch sent a plaintext request tunnelled to port 80 into the HTTP/2
  # relay — which dials the origin and then dies at `Frame.read_preface` — while the identical
  # request spelled `GET` took the refusal arm. Behaviour split on the first letter of the method.
  it "refuses a plaintext POST inside CONNECT instead of diverting it into the h2 relay (#755)" do
    origin = CountingOrigin.new
    begin
      with_mitm_proxy do |proxy, sink, done|
        raw = open_tunnel(proxy, "localhost:#{origin.port}")
        raw << "POST /form HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
        raw.flush
        raw.gets_to_end
        raw.close

        receive_within(done, seconds: 10, what: "the recorded flow")
        msg = sink.responses.first.error.not_nil!
        msg.should contain("CONNECT tunnel refused")
        # All four judged octets, glossed — `PRI ` is what it was compared against.
        msg.should contain(%(the bytes 0x50 0x4f 0x53 0x54 ("POST")))
        msg.should contain("network.tls_passthrough")
      end
      origin.untouched?.should be_true # intercept_h2c used to dial before failing
    ensure
      origin.close
    end
  end

  # THE CONTROL. The peek got narrower, so the thing it must still admit is asserted in the same
  # file: a real ClientHello is MITM'd exactly as before and the request inside is captured.
  it "still intercepts a real TLS ClientHello and captures the request inside it" do
    origin_port = start_tls_origin("TOP SECRET")
    with_mitm_proxy do |proxy, sink, done|
      raw = open_tunnel(proxy, "localhost:#{origin_port}")
      tls = OpenSSL::SSL::Socket::Client.new(raw, context: blind_client_context,
        sync_close: true, hostname: "localhost")
      subject = tls.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
      subject.should contain("localhost") # gori's leaf: the tunnel really was intercepted
      tls << "GET /inside HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      tls.gets_to_end.should contain("TOP SECRET")
      tls.close

      receive_within(done, seconds: 10, what: "the recorded flow")
      sink.requests.first.target.should eq("/inside")
      sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
    end
  end

  # The non-HTTP detector (#729) INSIDE a decrypted tunnel — the one path where
  # `network.tls_passthrough` is literally the remedy, and the one the `@tls` discriminator got
  # wrong: `@tls` is the CONNECT MITM seam and is passed only by the cleartext listener, so the
  # tunnel used to be told "this listener expects HTTP" while a plaintext :8080 client was told
  # gori had terminated its TLS. Now stamped by the caller (`client_tls:`).
  it "words a non-HTTP payload INSIDE the tunnel as a TLS-terminated connection (#755)" do
    origin_port = start_tls_origin("unused")
    with_mitm_proxy do |proxy, sink, done|
      raw = open_tunnel(proxy, "localhost:#{origin_port}")
      tls = OpenSSL::SSL::Socket::Client.new(raw, context: blind_client_context,
        sync_close: true, hostname: "localhost")
      tls.write(Bytes[0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54]) # MQTT CONNECT, inside TLS
      tls.flush
      tls.gets_to_end
      tls.close

      receive_within(done, seconds: 10, what: "the recorded flow")
      msg = sink.responses.first.error.not_nil!
      msg.should contain("not an HTTP request")
      msg.should contain("the byte 0x10")
      msg.should contain("gori terminated TLS on this connection")
      msg.should contain("\"localhost\"") # the tunnel names its host; a cleartext listener cannot
      msg.should contain("network.tls_passthrough")
    end
  end

  # The OTHER direction of the same discriminator, and the one the old code got wrong in the
  # visible half: this proxy HAS a CA (so `@tls` is set), but a client that lands on the cleartext
  # listener without a CONNECT has had no TLS terminated for it. It must not be told otherwise —
  # passthrough is meaningless advice for a connection with no TLS leg.
  it "words a non-HTTP payload on the CLEARTEXT listener of a MITM-capable proxy as cleartext" do
    with_mitm_proxy do |proxy, sink, done|
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw.read_timeout = 10.seconds
      raw.write(Bytes[0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51]) # MQTT CONNECT, no CONNECT verb, no TLS
      raw.flush
      raw.gets_to_end
      raw.close

      receive_within(done, seconds: 10, what: "the recorded flow")
      msg = sink.responses.first.error.not_nil!
      msg.should contain("not an HTTP request")
      msg.should contain("this listener expects HTTP")
      msg.should_not contain("gori terminated TLS")
    end
  end

  # THE ADVICE, executed. A refusal that names a remedy is only worth writing if the remedy
  # works, so the same SSH banner is sent again with the host listed — where the passthrough
  # branch is taken one level ABOVE the peek, so nothing is peeked, nothing is refused, and the
  # bytes cross byte-exact in both directions.
  it "carries the same non-TLS tunnel byte-exact once the host is on tls_passthrough (#755)" do
    origin_port, seen = start_echo_origin
    saved = Gori::Settings.tls_passthrough
    begin
      Gori::Settings.tls_passthrough = ["localhost"]
      with_mitm_proxy do |proxy, sink, _done|
        raw = open_tunnel(proxy, "localhost:#{origin_port}")
        raw << "SSH-2.0-OpenSSH_9.6\r\n"
        raw.flush
        raw.gets(chomp: false).should eq("SSH-2.0-OpenSSH_9.6-origin\r\n") # the origin answered
        raw.close

        receive_within(seen, seconds: 10, what: "the banner at the origin")
          .should eq("SSH-2.0-OpenSSH_9.6\r\n") # byte-exact, no peek consumed and no refusal
        sink.responses.should be_empty          # a blind tunnel is not a captured flow
      end
    ensure
      Gori::Settings.tls_passthrough = saved
    end
  end

  # `Tunnel#intercept`'s rescue. A log line and not a flow, on purpose — see
  # `notice_handshake_failure`: there is no `RawRequest` here, and the dominant member of this
  # population is a client that does not trust gori's CA, which retries.
  it "says in gori.log why a client handshake it could not complete was closed (#755)" do
    origin_port = start_tls_origin("unused")
    drained = [] of String
    logs = Log.capture(level: Log::Severity::Warn) do
      with_mitm_proxy do |proxy, _sink, _done, tunnel|
        # Twice: a retrying client is the ordinary member of this population, and the TUI queue
        # rides the log line's {host:port, class} dedup.
        2.times do
          raw = open_tunnel(proxy, "localhost:#{origin_port}")
          # A well-formed TLS record header (so the peek admits it) carrying a handshake body
          # OpenSSL cannot make sense of.
          raw.write(Bytes[0x16, 0x03, 0x01, 0x00, 0x05, 0x01, 0x00, 0x00, 0x01, 0xff])
          raw.flush
          raw.gets_to_end
          raw.close
        end
        drained = tunnel.drain_untrusted_handshakes
        tunnel.drain_untrusted_handshakes.should be_empty # taken, not peeked
      end
    end
    logs.check(:warn, /client TLS handshake failed for localhost:#{origin_port}/)
    # The OpenSSL class is the untrusted-CA one, so it is queued for the TUI too — once.
    drained.should eq(["localhost:#{origin_port}"])
  end
end
