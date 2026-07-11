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

# A self-signed TLS origin that echoes the request-line and replies with `body`.
private def start_tls_origin(body : String, seen : Channel(String)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        seen.send(head ? String.new(head).lines.first : "")
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

describe Gori::Proxy::Tls::Tunnel do
  it "intercepts an HTTPS CONNECT and captures the decrypted flow byte-exact (P7)" do
    dir = File.tempname("gori-ca")
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    begin
      origin_port = start_tls_origin("TOP SECRET", seen)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start

      # client -> proxy: CONNECT, then TLS (trusting gori's CA), then a GET
      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      connect_resp = Codec::Http1.read_head(raw).not_nil!
      String.new(connect_resp).should contain("200")

      client_ctx = OpenSSL::SSL::Context::Client.new
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      store = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(store, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      response = tls.gets_to_end
      tls.close

      done.receive
      proxy.stop

      response.should contain("200 OK")
      response.should contain("TOP SECRET")          # end-to-end decrypted + re-encrypted
      seen.receive.should eq("GET /secret HTTP/1.1") # origin saw the forwarded request

      req = sink.requests.first
      req.scheme.should eq("https")
      req.method.should eq("GET")
      req.target.should eq("/secret")
      req.host.should eq("localhost")
      req.port.should eq(origin_port)

      resp = sink.responses.first
      resp.status.should eq(200)
      String.new(resp.body.not_nil!).should eq("TOP SECRET")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "downgrades an h2 client to HTTP/1.1 so live Match&Replace rules still apply" do
    dir = File.tempname("gori-ca-mr")
    dbpath = File.tempname("gori-mr", ".db")
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    store : Gori::Store? = nil
    begin
      origin_port = start_tls_origin("OK", seen)
      ca = CertAuthority.load_or_create(dir)
      store = Gori::Store.open(dbpath)
      rules = Gori::Rules.load(store.not_nil!)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "/secret", "/rewritten") # one enabled rule → active
      rules.active?.should be_true

      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false, rewriter: rules))
      proxy.start

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      client_ctx = OpenSSL::SSL::Context::Client.new
      client_ctx.alpn_protocol = "h2" # client OFFERS h2
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(st, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls.alpn_protocol.should_not eq("h2") # gori refused to advertise h2 → the rewritable h1 path
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      tls.gets_to_end
      tls.close

      done.receive
      proxy.stop
      seen.receive.should eq("GET /rewritten HTTP/1.1") # the rule applied (was silently skipped on h2)
    ensure
      store.try(&.close)
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
      File.delete?(dbpath)
      File.delete?("#{dbpath}-wal")
      File.delete?("#{dbpath}-shm")
    end
  end
end
