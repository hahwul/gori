require "../spec_helper"
require "socket"
require "file_utils"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

private class RecSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse
  @id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# A minimal cleartext-HTTP/2 (h2c) origin: reads the preface, waits for the
# request HEADERS, then replies with SETTINGS + HEADERS(:status 200) + DATA.
private def start_h2c_origin(body : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil? || f.frame_type == Frame::Type::Headers
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    status = HPACK::Encoder.new.encode([{":status", "200"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, status).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A multi-stream h2c origin. Unlike `start_h2c_origin` it answers EVERY request stream and
# records the stream ids it was asked for — which is how the sandbox spec proves that a refused
# stream never reached an origin, rather than merely that the client saw an RST.
private class MultiH2cOrigin
  getter seen = [] of UInt32

  def initialize(@body : String = "ok")
    @server = TCPServer.new("127.0.0.1", 0)
  end

  def port : Int32
    @server.local_address.port
  end

  def start : Nil
    spawn do
      begin
        next unless conn = @server.accept?
        Frame.read_preface(conn)
        conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
        conn.flush
        encoder = HPACK::Encoder.new
        loop do
          f = Frame.read(conn)
          break if f.nil?
          next unless f.frame_type == Frame::Type::Headers
          @seen << f.stream_id
          status = encoder.encode([{":status", "200"}])
          conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, f.stream_id, status).to_bytes)
          conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, f.stream_id, @body.to_slice).to_bytes)
          conn.flush
        end
      rescue
        # the client went away; the spec asserts on what was seen before that
      end
    end
  end

  def stop : Nil
    @server.close rescue nil
  end
end

# Open a CONNECT tunnel to `authority` through `proxy` and consume the 200 head.
private def connect_tunnel(proxy_port : Int32, authority : String) : TCPSocket
  client = TCPSocket.new("127.0.0.1", proxy_port)
  client.read_timeout = 5.seconds
  client << "CONNECT #{authority} HTTP/1.1\r\n\r\n"
  client.flush
  until (line = client.gets) == "" || line.nil?
  end
  client
end

private def h2_headers(encoder : HPACK::Encoder, stream_id : UInt32, authority : String,
                       path : String) : Bytes
  block = encoder.encode([
    {":method", "GET"}, {":path", path}, {":scheme", "http"}, {":authority", authority},
  ])
  Frame::Header.new(Frame::Type::Headers.value,
    Frame::END_HEADERS | Frame::END_STREAM, stream_id, block).to_bytes
end

# Wait (briefly) for the sink to record a flow, so a spec asserting on History is not racing
# the capture that happens just after the refusal.
private def await_response(sink : RecSink) : Nil
  attempts = 0
  while sink.responses.empty? && attempts < 250
    sleep 0.02.seconds
    attempts += 1
  end
end

private def with_sandbox_scope(&)
  path = File.tempname("gori-h2c-sbx", ".db")
  store = Gori::Store.open(path)
  scope = Gori::Scope.load(store)
  # A STRING include (not a host one), so `sandbox_blocks_host?` lets the CONNECT through and
  # the whole decision falls to the per-stream gate — the exact arrangement #731 is about.
  scope.add("include", "string", "/allowed")
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

# A rewriter whose only claim is the one `h2c_refusal` asks about.
private class BodyRuleRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_body_for_host?(host : String) : Bool
    true
  end

  def active? : Bool
    true
  end
end

describe "h2c via CONNECT (cleartext HTTP/2)" do
  it "relays a cleartext-h2 stream and captures it as an HTTP/2 flow" do
    ca_dir = File.tempname("gori-h2c-ca")
    Dir.mkdir_p(ca_dir)
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
    tunnel = Gori::Proxy::Tls::Tunnel.new(ca, verify_upstream: false)

    origin_port = start_h2c_origin("h2c-ok")
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    # CONNECT to the origin, then speak cleartext h2 ("prior knowledge").
    client << "CONNECT 127.0.0.1:#{origin_port} HTTP/1.1\r\n\r\n"
    client.flush
    # consume the 200 response head
    until (line = client.gets) == "" || line.nil?
    end

    client.write(Frame::PREFACE)
    client.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    req = HPACK::Encoder.new.encode([
      {":method", "GET"}, {":path", "/"}, {":scheme", "http"}, {":authority", "127.0.0.1:#{origin_port}"},
    ])
    client.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS | Frame::END_STREAM, 1_u32, req).to_bytes)
    client.flush

    # read response frames until END_STREAM data
    got_body = ""
    got_status_headers = false
    loop do
      f = Frame.read(client)
      break if f.nil?
      got_status_headers = true if f.frame_type == Frame::Type::Headers && f.stream_id == 1
      if f.frame_type == Frame::Type::Data && f.stream_id == 1
        got_body += String.new(f.payload)
        break if f.end_stream?
      end
    end
    client.close

    got_status_headers.should be_true
    got_body.should eq("h2c-ok") # the relay forwarded both ways over cleartext h2

    # capture happens just after forwarding; poll briefly for the projection
    attempts = 0
    while sink.responses.empty? && attempts < 100
      sleep 0.02.seconds
      attempts += 1
    end
    proxy.stop

    # gori projected the cleartext-h2 stream into a flow
    sink.requests.first.http_version.should eq("HTTP/2")
    sink.requests.first.target.should eq("/")
    sink.responses.first.status.should eq(200)
  ensure
    FileUtils.rm_rf(ca_dir) if ca_dir
  end

  # THE safety argument for #731. The blanket `sandbox_enabled?` refusal in `handle_connect` is
  # gone, so this tunnel OPENS under the sandbox — and what must still hold is that an
  # out-of-scope stream on it never reaches the origin. That is `H2::StreamGate`'s job
  # (#492 step 4), reachable here since #549 threaded `interceptor:` into the relay call.
  #
  # Stub `StreamGate`'s sandbox out (make `sandbox_refuses_locked` return false) and this spec
  # fails on `origin.seen`, which is the whole point of asserting on the ORIGIN rather than on
  # the RST the client happens to see.
  it "still blocks an out-of-scope stream on an h2c tunnel, per stream, and lets an in-scope one through" do
    ca_dir = File.tempname("gori-h2c-sbx-ca")
    Dir.mkdir_p(ca_dir)
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
    tunnel = Gori::Proxy::Tls::Tunnel.new(ca, verify_upstream: false)

    origin = MultiH2cOrigin.new("h2c-ok")
    origin.start
    authority = "127.0.0.1:#{origin.port}"

    with_sandbox_scope do |interceptor|
      sink = RecSink.new
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel, interceptor: interceptor)
      proxy.start

      client = connect_tunnel(proxy.port, authority)
      client.write(Frame::PREFACE)
      client.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
      encoder = HPACK::Encoder.new
      client.write(h2_headers(encoder, 1_u32, authority, "/blocked"))
      client.write(h2_headers(encoder, 3_u32, authority, "/allowed"))
      client.flush

      rst_codes = {} of UInt32 => UInt32
      bodies = {} of UInt32 => String
      # Bounded by the read timeout rather than only by the two frames we want, so a gate that
      # has stopped refusing fails on the assertions below instead of hanging in here.
      client.read_timeout = 2.seconds
      begin
        loop do
          f = Frame.read(client)
          break if f.nil?
          case f.frame_type
          when Frame::Type::RstStream
            rst_codes[f.stream_id] = IO::ByteFormat::BigEndian.decode(UInt32, f.payload) if f.payload.size >= 4
          when Frame::Type::Data
            bodies[f.stream_id] = String.new(f.payload)
          end
          break if rst_codes.has_key?(1_u32) && bodies.has_key?(3_u32)
        end
      rescue IO::TimeoutError
        # nothing more is coming; what did and did not arrive is the assertion
      end
      client.close
      await_response(sink)
      proxy.stop

      # The tunnel was NOT refused outright: the in-scope stream was served end to end.
      bodies[3_u32]?.should eq("h2c-ok")
      # And the out-of-scope one never reached the origin — only stream 3 did.
      origin.seen.should eq([3_u32])
      # The client was told, with the same code the TLS h2 path uses for a sandbox refusal.
      rst_codes[1_u32]?.should eq(Gori::Proxy::H2::StreamGate::CANCEL)
      # …and the blocked attempt stayed visible in History.
      sink.responses.any? { |r| r.error == Gori::Outbound::SANDBOX_ERROR }.should be_true
    end
  ensure
    origin.try(&.stop)
    FileUtils.rm_rf(ca_dir) if ca_dir
  end

  # #731 task 2: the `http2_disabled?` refusal was a bare `return false` AFTER the client had
  # been told `200 Connection Established` — nothing in History, nothing in `gori.log`.
  it "records the refusal when HTTP/2 is switched off, instead of dying silently behind the 200" do
    ca_dir = File.tempname("gori-h2c-off-ca")
    Dir.mkdir_p(ca_dir)
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
    tunnel = Gori::Proxy::Tls::Tunnel.new(ca, verify_upstream: false)
    Gori::Settings.http2 = "off"

    origin = MultiH2cOrigin.new
    origin.start
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel)
    proxy.start

    client = connect_tunnel(proxy.port, "127.0.0.1:#{origin.port}")
    client.write(Frame::PREFACE)
    client.flush
    # An h2 client cannot parse an HTTP/1.1 response and gori does not synthesize h2, so what
    # the wire gets is a clean EOF. The refusal is delivered to the OPERATOR instead.
    client.gets_to_end.should eq("")
    client.close

    await_response(sink)
    proxy.stop

    origin.seen.should be_empty
    sink.responses.should_not be_empty # the refusal is RECORDED, not silent
    err = sink.responses.last.error.not_nil!
    err.should contain("h2c CONNECT tunnel refused")
    err.should contain("HTTP/2 is switched off")
    sink.requests.last.method.should eq("CONNECT")
  ensure
    Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
    origin.try(&.stop)
    FileUtils.rm_rf(ca_dir) if ca_dir
  end

  # The three rule gates already wrote a `gori.log` line but recorded no flow. Same refusal
  # helper now, so History carries them too.
  it "records the refusal when a rule the h2 relay cannot apply is live" do
    ca_dir = File.tempname("gori-h2c-rule-ca")
    Dir.mkdir_p(ca_dir)
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
    tunnel = Gori::Proxy::Tls::Tunnel.new(ca, verify_upstream: false)

    origin = MultiH2cOrigin.new
    origin.start
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel, rewriter: BodyRuleRewriter.new)
    proxy.start

    client = connect_tunnel(proxy.port, "127.0.0.1:#{origin.port}")
    client.write(Frame::PREFACE)
    client.flush
    client.gets_to_end.should eq("")
    client.close

    await_response(sink)
    proxy.stop

    origin.seen.should be_empty
    sink.responses.should_not be_empty # the refusal is RECORDED, not silent
    err = sink.responses.last.error.not_nil!
    err.should contain("h2c CONNECT tunnel refused")
    err.should contain("Match&Replace BODY rule")
  ensure
    origin.try(&.stop)
    FileUtils.rm_rf(ca_dir) if ca_dir
  end
end

# #731 task 3. A cleartext listener carried `H2Offer::Unknown` — "HTTP/2 was not negotiated on
# this connection", documented as deliberately causeless — where the cause is in fact knowable:
# the client arrived without a TLS handshake, so there was no ALPN, and gori serves no h2c
# prior-knowledge of its own.
describe "an h2c prior-knowledge client on a cleartext listener" do
  it "names the true reason it was refused, instead of declining to name one" do
    sink = RecSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "PRI * HTTP/2.0\r\n\r\n"
    client.flush
    client.gets_to_end.should eq("")
    client.close

    await_response(sink)
    proxy.stop

    sink.responses.should_not be_empty
    err = sink.responses.last.error.not_nil!
    err.should contain("rejected h2/gRPC client preface")
    err.should contain("does not serve h2c prior-knowledge here")
    err.should_not contain("HTTP/2 was not negotiated on this connection")
  end
end
