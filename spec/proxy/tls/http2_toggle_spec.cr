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

# An origin that DOES speak h2 (advertises it in ALPN) and counts how many times it was
# connected to. The count is the measurement for "off skips the ALPN probe": with h2 available
# gori normally pre-dials a probe connection, so probe+real = 2 accepts, and skipping it = 1.
private def start_h2_capable_origin(body : String, accepts : Array(Int32)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: true)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      accepts[0] += 1 # one-element box: a shared reference (Atomic is a struct and would copy)
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head # an ALPN probe connection sends nothing
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

# A client that OFFERS h2 and trusts gori's CA, so `alpn_protocol` reports what gori advertised.
private def h2_offering_client(raw : TCPSocket, ca_dir : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.alpn_protocol = "h2"
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: "localhost")
end

describe "HTTP/2 toggle (network.http2)" do
  describe ".http2_disabled?" do
    it "is off only for an explicit \"off\"" do
      Gori::Settings.http2 = "auto"
      Gori::Settings.http2_disabled?.should be_false
      Gori::Settings.http2 = "off"
      Gori::Settings.http2_disabled?.should be_true
    ensure
      Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
    end

    # A hand-edited typo must not silently force h1 — the safe reading of an unknown value is
    # "behave as before", i.e. auto.
    it "reads an unrecognised value as auto rather than as off" do
      Gori::Settings.http2 = "no"
      Gori::Settings.http2_disabled?.should be_false
    ensure
      Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
    end
  end

  # The point of the setting: force h1 with NO other behaviour changed. Before this, the only
  # lever was h2_candidate? seeing a live Match&Replace rule, so operators enabled a no-op rule
  # to get here — which also turns on head rewriting.
  it "forces an h2-offering client onto HTTP/1.1 with no Match&Replace rule involved" do
    dir = File.tempname("gori-ca-h2off")
    accepts = [0]
    done = Channel(Nil).new(1)
    begin
      origin_port = start_h2_capable_origin("OK", accepts)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      # No rewriter, no interceptor: nothing but the setting can cause a downgrade here.
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start
      Gori::Settings.http2 = "off"

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      tls = h2_offering_client(raw, dir)
      tls.alpn_protocol.should_not eq("h2") # gori never advertised it
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      tls.gets_to_end
      tls.close

      done.receive
      proxy.stop

      # The h1 path captures through ClientConn, so the flow is recorded per request.
      sink.requests.size.should eq(1)
      sink.requests.first.target.should eq("/secret")

      # ONE origin connection: "off" short-circuits before reflect_origin_h2, so the ALPN probe
      # never happens. Under "auto" this origin would have been dialed twice.
      accepts[0].should eq(1)
    ensure
      Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # The control: same proxy, same h2-capable origin, same h2-offering client — only the setting
  # differs. Without it, "the client got h1" would not be attributable to the setting.
  it "still negotiates h2 for the same client and origin under auto" do
    dir = File.tempname("gori-ca-h2auto")
    accepts = [0]
    done = Channel(Nil).new(1)
    begin
      origin_port = start_h2_capable_origin("OK", accepts)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start
      Gori::Settings.http2 = "auto"

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      tls = h2_offering_client(raw, dir)
      tls.alpn_protocol.should eq("h2") # reflected from the origin, as before this setting
      tls.close
      proxy.stop
    ensure
      Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  describe "settings persistence" do
    it "round-trips through settings.json and rejects an out-of-range value on load" do
      dir = File.tempname("gori-settings-http2")
      Dir.mkdir_p(dir)
      prev_home = ENV["GORI_HOME"]?
      begin
        ENV["GORI_HOME"] = dir
        Gori::Settings.http2 = "off"
        Gori::Settings.save.should be_true
        File.read(Gori::Settings.path).should contain(%("http2"))

        Gori::Settings.http2 = "auto"
        Gori::Settings.load
        Gori::Settings.http2.should eq("off")

        # An unknown value on disk keeps whatever the process has, rather than storing junk.
        File.write(File.join(dir, "settings.json"), %({"network":{"http2":"h3"}}))
        Gori::Settings.http2 = "auto"
        Gori::Settings.load
        Gori::Settings.http2.should eq("auto")
      ensure
        prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
      end
    end
  end
end
