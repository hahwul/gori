require "../../spec_helper"
require "socket"
require "openssl"
require "file_utils"

include Gori::Proxy
include Gori::Proxy::Tls

# R5-F3. An h2/gRPC client whose preface lands on the HTTP/1.1 path is refused, and the refusal
# used to hard-code two causes ("settings network.http2 is \"off\" or a Match&Replace body rule
# is live") and point at a `gori.log` line that names which. Two things went stale under that
# reasoning: `h2_candidate?` has FOUR downgrade branches now, and — decisively — the common case
# is NONE of them. The tunnel offered h2, the ORIGIN answered `http/1.1` at ALPN,
# `notice_downgrade` never ran, and `gori.log` stayed 0 bytes. The operator was told to change a
# setting that was already correct and to read a line that did not exist.

private class ErrSink < FlowSink
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

# A TLS origin that does or does not advertise h2 at ALPN. `advertise_h2: false` is the whole
# point of the primary example: gori's probe completes, the origin says `http/1.1`, and gori
# therefore does not offer h2 to the client either (there is no h2 <-> h1 bridge).
private def start_origin(advertise_h2 : Bool) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: advertise_h2)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        Codec::Http1.read_head(ssl)
        ssl.close
      rescue
      end
    end
  end
  port
end

private def h2_offering_client(raw : TCPSocket, ca_dir : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.alpn_protocol = "h2"
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: "localhost")
end

# CONNECT through gori, offer h2, then speak the HTTP/2 client preface regardless of what ALPN
# came back — a hand-rolled gRPC client's exact behaviour. Returns the recorded flow error.
private def preface_refusal(origin_port : Int32, dir : String) : String
  done = Channel(Nil).new(1)
  sink = ErrSink.new(done)
  proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(CertAuthority.load_or_create(dir), verify_upstream: false))
  proxy.start
  begin
    raw = TCPSocket.new("127.0.0.1", proxy.port)
    raw.read_timeout = 10.seconds
    raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
    raw.flush
    Codec::Http1.read_head(raw).not_nil!
    tls = h2_offering_client(raw, dir)
    tls << "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    tls.flush
    # Drain to EOF before closing, the way a real client does. Closing straight after the write
    # raced the proxy on Linux: the peer's close was observed first, the connection was torn
    # down before the refusal was written and recorded, and no response ever reached the sink.
    # macOS timing hid it, so the suite passed locally and hung in CI.
    begin
      buf = Bytes.new(4096)
      while (n = tls.read(buf)) > 0
      end
    rescue
    end
    tls.close rescue nil
    # NEVER a bare `receive` here. This example drives a real proxy over a real socket, so
    # "the response was not captured" is a plausible outcome of a platform difference — and a
    # bare receive turns that into a suite that hangs with no output instead of one example
    # that says what happened. It cost a CI run to learn: `crystal spec` block-buffers its
    # dots under Actions, so a hang leaves nothing behind to read.
    select
    when done.receive
      # captured
    when timeout(20.seconds)
      raise "no response was captured within 20s — the proxy never completed the flow"
    end
    sink.responses.first.error.not_nil!
  ensure
    proxy.stop
  end
end

describe "the reason an h2 preface is refused on the HTTP/1.1 path" do
  it "names the ORIGIN's ALPN, not a setting that is already correct" do
    dir = File.tempname("gori-ca-h2offer")
    begin
      Gori::Settings.http2 = "auto"
      err = preface_refusal(start_origin(advertise_h2: false), dir)

      err.should contain("rejected h2/gRPC client preface")
      err.should contain("the ORIGIN did not negotiate HTTP/2")
      # The two things the old sentence got wrong: it blamed a setting that is on "auto", and
      # it pointed at a gori.log line this path never writes.
      err.should_not contain("network.http2")
      err.should_not contain("Match&Replace")
      err.should_not contain("gori.log")
    ensure
      Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # The complement: the branch that IS the setting's still names it, and still points at the
  # gori.log line, because `notice_downgrade` really does write one there.
  it "still names the setting — and gori.log — when the setting really is the cause" do
    dir = File.tempname("gori-ca-h2off")
    begin
      Gori::Settings.http2 = "off"
      err = preface_refusal(start_origin(advertise_h2: true), dir)

      err.should contain("HTTP/2 is switched off")
      err.should contain("network.http2")
      err.should contain("gori.log")
    ensure
      Gori::Settings.http2 = Gori::Settings::DEFAULT_HTTP2
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # The unit half: every member says something different, and only the branches that write to
  # gori.log mention it.
  describe Gori::Proxy::H2Offer do
    it "gives each cause its own sentence" do
      reasons = Gori::Proxy::H2Offer.values.map(&.refusal_reason)
      reasons.uniq.size.should eq(reasons.size)
      reasons.each { |r| r.should_not be_empty }
    end

    it "mentions gori.log only where a line was actually written" do
      writes = [Gori::Proxy::H2Offer::DisabledBySetting]
      Gori::Proxy::H2Offer.values.each do |offer|
        offer.refusal_reason.includes?("gori.log").should eq(writes.includes?(offer))
      end
    end

    it "asserts no cause at all when nothing stamped one" do
      Gori::Proxy::H2Offer::Unknown.refusal_reason
        .should eq("HTTP/2 was not negotiated on this connection")
    end
  end
end
