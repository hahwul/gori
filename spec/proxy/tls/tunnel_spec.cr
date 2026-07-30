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
# `advertise_h2: false` makes it an HTTP/1.1-only origin (no h2 in ALPN) — used to exercise
# gori's ALPN reflection, which must fall the client back to h1 for such origins.
private def start_tls_origin(body : String, seen : Channel(String), advertise_h2 : Bool = true) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: advertise_h2)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        # Only a real request line reaches `seen`. ALPN reflection pre-dials a throwaway probe
        # connection that sends nothing (read_head → nil); that artifact must not be mistaken
        # for the forwarded request.
        next unless head
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

# An HTTP/1.1-only origin (no h2 ALPN) that counts every accepted connection. Used to prove the
# negative ALPN cache skips the probe on a repeat visit: visit 1 = probe + real = 2 accepts,
# a cached visit 2 = real only = 1 accept.
private def start_counting_h1_origin(body : String, accepts : Array(Int32)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while raw = origin.accept?
      accepts[0] += 1 # one-element box: a shared reference (Atomic is a struct and would copy)
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head # a probe connection sends nothing
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

# A minimal HTTP/2 origin: negotiates the h2 ALPN, reads the forwarded client preface + first
# frame, then writes one recognizable frame back. It is a byte peer, not a real h2 stack — just
# enough to exercise the relay's end-to-end pump. Holds the connection open until `ack` fires so
# the reply isn't lost to a close race. gori reuses the single pre-dialed (probe) socket for the
# relay, so the origin sees exactly ONE connection.
private def start_h2_origin(reply : Bytes, ack : Channel(Nil)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: true)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    if raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        ssl.sync = true
        Gori::Proxy::H2::Frame.read_preface(ssl) # gori forwarded the client's preface
        Gori::Proxy::H2::Frame.read(ssl)         # + its first frame (SETTINGS)
        ssl.write(reply)                         # a frame the client must receive via the relay
        ssl.flush
        ack.receive # keep the connection open until the client has read the reply
        ssl.close rescue nil
      rescue
      end
    end
  end
  port
end

# A minimal HTTP/2 origin that HPACK-decodes the first HEADERS block it receives and reports
# that block's `:path`. Enough to prove a Match&Replace HEAD rule reached an h2 request head
# end-to-end — the relay re-encodes the block literal-only, so a fresh decoder reads it.
private def start_h2_head_origin(path_seen : Channel(String), ack : Channel(Nil)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: true)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    if raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        ssl.sync = true
        Gori::Proxy::H2::Frame.read_preface(ssl)
        decoder = Gori::Proxy::H2::HPACK::Decoder.new
        while frame = Gori::Proxy::H2::Frame.read(ssl)
          next unless frame.frame_type == Gori::Proxy::H2::Frame::Type::Headers
          fields = decoder.decode(frame.payload)
          path_seen.send(fields.find { |(n, _)| n == ":path" }.try(&.[1]) || "")
          break
        end
        ack.receive
        ssl.close rescue nil
      rescue
      end
    end
  end
  port
end

# A minimal HTTP/2 origin that reports the `:path` of EVERY HEADERS block it receives, rather
# than stopping at the first. That is what makes it usable as a negative: a request the sandbox
# refused must never turn up here, on a connection that is carrying other streams fine.
private def start_h2_path_log_origin(paths : Channel(String), ack : Channel(Nil)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: true)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    if raw = origin.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        ssl.sync = true
        # The read loop is its own fiber so `ack` still gates teardown while it runs.
        spawn do
          begin
            Gori::Proxy::H2::Frame.read_preface(ssl)
            decoder = Gori::Proxy::H2::HPACK::Decoder.new
            while frame = Gori::Proxy::H2::Frame.read(ssl)
              next unless frame.frame_type == Gori::Proxy::H2::Frame::Type::Headers
              fields = decoder.decode(frame.payload)
              paths.send(fields.find { |(n, _)| n == ":path" }.try(&.[1]) || "")
            end
          rescue
          end
        end
        ack.receive
        ssl.close rescue nil
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

  it "reflects an h2 origin: reuses the pre-dialed socket for the end-to-end h2 relay (#323)" do
    # The common browser→h2-origin path. ALPN reflection pre-dials the origin offering h2, sees
    # it negotiate h2, advertises h2 to the client, and hands that SAME pre-dialed socket to the
    # relay (no re-dial). This drives a minimal frame round-trip to prove the reused socket pumps
    # both directions — the h1/error tests never touch this handoff.
    dir = File.tempname("gori-ca-h2h2")
    done = Channel(Nil).new(4) # relay uses on_h2_* not on_response; buffered so teardown can't wedge
    ack = Channel(Nil).new(1)
    begin
      reply = Gori::Proxy::H2::Frame::Header.new(0x6_u8, 0_u8, 0_u32, "GORIPING".to_slice).wire_bytes # PING
      origin_port = start_h2_origin(reply, ack)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      client_ctx = OpenSSL::SSL::Context::Client.new
      client_ctx.alpn_protocol = "h2"
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(st, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls.sync = true
      tls.alpn_protocol.should eq("h2") # origin speaks h2 → gori reflected h2 → the relay path

      # Client preface + one frame, then read the origin's reply back through the reused upstream.
      tls.write(Gori::Proxy::H2::Frame::PREFACE)
      tls.write(Gori::Proxy::H2::Frame::Header.new(0x4_u8, 0_u8, 0_u32, Bytes.new(0)).wire_bytes) # SETTINGS
      tls.flush

      relayed = Gori::Proxy::H2::Frame.read(tls).not_nil!
      String.new(relayed.payload).should eq("GORIPING") # origin's frame arrived via the relay
      ack.send(nil)
      tls.close rescue nil
      proxy.stop
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "keeps h2 for a HEAD rule and applies it to the h2 request head (#492)" do
    # The reason #492 step 2 exists. Before it, ANY live Match&Replace rule forced the
    # connection to HTTP/1.1, and an h2/gRPC client that cannot take that downgrade had its
    # preface rejected outright (`conn/client_conn.cr:158`) — one rule killed every gRPC
    # client on the host. The head now reaches the rewriter over h2 instead.
    dir = File.tempname("gori-ca-h2mr")
    dbpath = File.tempname("gori-h2mr", ".db")
    path_seen = Channel(String).new(1)
    ack = Channel(Nil).new(1)
    done = Channel(Nil).new(4) # relay uses on_h2_*; buffered so teardown can't wedge
    store : Gori::Store? = nil
    begin
      origin_port = start_h2_head_origin(path_seen, ack)
      ca = CertAuthority.load_or_create(dir)
      store = Gori::Store.open(dbpath)
      rules = Gori::Rules.load(store.not_nil!)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "/secret", "/rewritten")
      rules.active?.should be_true

      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false, rewriter: rules))
      proxy.start

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      client_ctx = OpenSSL::SSL::Context::Client.new
      client_ctx.alpn_protocol = "h2"
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(st, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls.sync = true
      tls.alpn_protocol.should eq("h2") # a head rule no longer costs the connection its protocol

      encoder = Gori::Proxy::H2::HPACK::Encoder.new
      block = encoder.encode([{":method", "GET"}, {":scheme", "https"},
                              {":authority", "localhost"}, {":path", "/secret"}])
      tls.write(Gori::Proxy::H2::Frame::PREFACE)
      tls.write(Gori::Proxy::H2::Frame::Header.new(0x4_u8, 0_u8, 0_u32, Bytes.new(0)).wire_bytes) # SETTINGS
      tls.write(Gori::Proxy::H2::Frame::Header.new(
        Gori::Proxy::H2::Frame::Type::Headers.value,
        Gori::Proxy::H2::Frame::END_HEADERS | Gori::Proxy::H2::Frame::END_STREAM,
        1_u32, block).wire_bytes)
      tls.flush

      path_seen.receive.should eq("/rewritten") # the rule reached the h2 head — no downgrade
      ack.send(nil)
      tls.close rescue nil
      proxy.stop
    ensure
      store.try(&.close)
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
      File.delete?(dbpath)
      File.delete?("#{dbpath}-wal")
      File.delete?("#{dbpath}-shm")
    end
  end

  it "keeps h2 under the SANDBOX and refuses an out-of-scope stream on it (#492 step 4)" do
    # The gate this replaces was not a seam but a BLOCK: the sandbox reached h2 traffic only
    # because every sandboxed connection was forced to HTTP/1.1, where ClientConn blocks per
    # request. So "the spec passes" is not the bar — this drives a real client, over a real h2
    # connection that STAYS h2, and asserts the refused request never reaches the origin.
    dir = File.tempname("gori-ca-h2sandbox")
    dbpath = File.tempname("gori-h2sandbox", ".db")
    paths = Channel(String).new(4)
    ack = Channel(Nil).new(1)
    done = Channel(Nil).new(4)
    store : Gori::Store? = nil
    begin
      origin_port = start_h2_path_log_origin(paths, ack)
      ca = CertAuthority.load_or_create(dir)
      store = Gori::Store.open(dbpath)
      scope = Gori::Scope.load(store.not_nil!)
      # A URL-level include, which is the shape that makes the pre-handshake gate a no-op:
      # `sandbox_blocks_host?` reads one as "the path might match on any host", so it passes
      # every CONNECT and the per-request decision is the only decision there is.
      scope.add("include", "string", "https://localhost/api/")
      scope.enable_sandbox
      ic = Gori::Interceptor.new(scope)

      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false, interceptor: ic),
        interceptor: ic)
      proxy.start

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      String.new(Codec::Http1.read_head(raw).not_nil!).should contain("200") # not refused at CONNECT

      client_ctx = OpenSSL::SSL::Context::Client.new
      client_ctx.alpn_protocol = "h2"
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(st, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls.sync = true
      tls.alpn_protocol.should eq("h2") # the sandbox no longer costs the connection its protocol

      encoder = Gori::Proxy::H2::HPACK::Encoder.new
      tls.write(Gori::Proxy::H2::Frame::PREFACE)
      tls.write(Gori::Proxy::H2::Frame::Header.new(0x4_u8, 0_u8, 0_u32, Bytes.new(0)).wire_bytes) # SETTINGS
      # Stream 1 is out of scope, stream 3 is in scope, and they share one h2 connection.
      [{1_u32, "/admin"}, {3_u32, "/api/v1"}].each do |(id, path)|
        block = encoder.encode([{":method", "GET"}, {":scheme", "https"},
                                {":authority", "localhost"}, {":path", path}])
        tls.write(Gori::Proxy::H2::Frame::Header.new(
          Gori::Proxy::H2::Frame::Type::Headers.value,
          Gori::Proxy::H2::Frame::END_HEADERS | Gori::Proxy::H2::Frame::END_STREAM,
          id, block).wire_bytes)
      end
      tls.flush

      # The FIRST path the origin ever sees is the in-scope one: /admin did not leave gori.
      paths.receive.should eq("/api/v1")

      # And the client is told, rather than left hanging on a stream that is never coming back.
      rst = nil
      while frame = Gori::Proxy::H2::Frame.read(tls)
        next unless frame.frame_type == Gori::Proxy::H2::Frame::Type::RstStream
        rst = frame
        break
      end
      rst.not_nil!.stream_id.should eq(1_u32)
      IO::ByteFormat::BigEndian.decode(UInt32, rst.not_nil!.payload)
        .should eq(Gori::Proxy::H2::StreamGate::CANCEL)

      done.receive # the blocked attempt is recorded, exactly as the h1 path records one
      sink.requests.first.target.should eq("/admin")
      # The only flow finished so far: /api/v1 reached the origin and is still waiting on it.
      sink.responses.first.error.should eq(Gori::Outbound::SANDBOX_ERROR)

      ack.send(nil)
      tls.close rescue nil
      proxy.stop
    ensure
      store.try(&.close)
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
      File.delete?(dbpath)
      File.delete?("#{dbpath}-wal")
      File.delete?("#{dbpath}-shm")
    end
  end

  it "still downgrades an h2 client when a BODY rule is live (body rewrite is #492 step 5)" do
    # The gate narrowed from `active?` to a body-rule test rather than being removed. A body
    # rule works TODAY precisely because it downgrades — the buffered-body rewrite lives on the
    # ClientConn path — and `Rules#active?` is true for a body-only rule set, so dropping the
    # gate outright would have regressed body rules from working to silently not working.
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
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "/secret", "/rewritten")
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body, "aaa", "bbb")
      rules.rewrites_request_body?.should be_true

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
      tls.alpn_protocol.should_not eq("h2") # a live BODY rule still refuses h2 → the h1 path
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

  it "downgrades an h2 client when a SHORT-CIRCUIT rule is live, and answers it (#511)" do
    # The stub seam lives on the ClientConn path and the h2 relay never asks for it. Left
    # ungated, an operator who stubbed an endpoint would watch an h2 host forward the request
    # to the origin anyway — the exact thing the rule exists to prevent — with nothing saying
    # why. So a live stub rule earns the downgrade, and the h1 path then answers it.
    dir = File.tempname("gori-ca-sc")
    dbpath = File.tempname("gori-sc", ".db")
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    store : Gori::Store? = nil
    begin
      origin_port = start_tls_origin("FROM-ORIGIN", seen)
      ca = CertAuthority.load_or_create(dir)
      store = Gori::Store.open(dbpath)
      rules = Gori::Rules.load(store.not_nil!)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/stubbed", "200 OK\n\nFROM-RULE", op: Gori::Store::RuleOp::ShortCircuit)
      rules.short_circuits?.should be_true
      # It is NOT a body rule — the pre-#511 gate would have let this reach the h2 relay.
      rules.rewrites_request_body?.should be_false
      rules.rewrites_response_body?.should be_false

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
      tls.alpn_protocol.should_not eq("h2") # a live stub rule refuses h2 → the h1 path
      tls << "GET /stubbed HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      tls.flush
      answer = tls.gets_to_end
      tls.close

      done.receive
      proxy.stop
      answer.should contain("FROM-RULE") # the rule answered...
      answer.should_not contain("FROM-ORIGIN")
      sink.requests.first.short_circuited?.should be_true
    ensure
      store.try(&.close)
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
      File.delete?(dbpath)
      File.delete?("#{dbpath}-wal")
      File.delete?("#{dbpath}-shm")
    end
  end

  it "reflects an h1-only origin's ALPN: an h2 client falls back to h1 and the flow loads (#323)" do
    dir = File.tempname("gori-ca-h1only")
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    begin
      # An HTTP/1.1-only origin (no h2 in its ALPN). Before ALPN reflection, gori advertised h2
      # to the client, the client took h2, and the h2 tunnel died with no h1 fallback — a blank
      # page + empty History (#323). Now gori pre-dials the origin, sees it won't speak h2, and
      # reflects h1 to the client so the request loads over the h1 path.
      origin_port = start_tls_origin("TOP SECRET", seen, advertise_h2: false)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      client_ctx = OpenSSL::SSL::Context::Client.new
      client_ctx.alpn_protocol = "h2" # client OFFERS h2 …
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(st, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls.alpn_protocol.should_not eq("h2") # … but gori reflected the origin's h1, not h2
      tls << "GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush
      response = tls.gets_to_end
      tls.close

      done.receive
      proxy.stop

      response.should contain("200 OK")
      response.should contain("TOP SECRET")          # loaded end-to-end over h1 (no blank page)
      seen.receive.should eq("GET /secret HTTP/1.1") # origin saw the forwarded request

      req = sink.requests.first
      req.host.should eq("localhost")
      req.port.should eq(origin_port)
      req.http_version.should eq("HTTP/1.1") # captured via the h1 path, not a dead h2 tunnel
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "caches an h1-only origin so a repeat visit skips the ALPN probe (fewer origin connections)" do
    dir = File.tempname("gori-ca-h1cache")
    done = Channel(Nil).new(4)
    accepts = [0] # one-element box shared with the origin fiber
    begin
      origin_port = start_counting_h1_origin("OK", accepts)
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      # One Tunnel instance across both visits — the negative cache lives on it.
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))

      2.times do
        raw = TCPSocket.new("127.0.0.1", proxy.port)
        raw << "CONNECT localhost:#{origin_port} HTTP/1.1\r\nHost: localhost:#{origin_port}\r\n\r\n"
        raw.flush
        Codec::Http1.read_head(raw).not_nil!

        client_ctx = OpenSSL::SSL::Context::Client.new
        client_ctx.alpn_protocol = "h2"
        st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
        LibCrypto.x509_store_add_cert(st, ca_cert.handle)

        tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
        tls.alpn_protocol.should_not eq("h2") # reflected h1 on both visits
        tls << "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        tls.flush
        tls.gets_to_end
        tls.close
        done.receive # wait for the flow to complete before the next visit (deterministic count)
      end

      proxy.stop
      # visit 1: probe + real = 2 accepts; cached visit 2: real only = 1. 4 would mean no caching.
      accepts[0].should eq(3)
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "reflects an unreachable origin as h1, surfacing the dial failure via the h1 path (#323)" do
    dir = File.tempname("gori-ca-dead")
    done = Channel(Nil).new(1)
    begin
      ca = CertAuthority.load_or_create(dir)
      sink = RecordingSink.new(done)
      proxy = Server.new("127.0.0.1", 0, sink, tls: Tunnel.new(ca, verify_upstream: false))
      proxy.start

      # A port with nothing listening → the ALPN-reflection pre-dial fails, so gori reflects h1
      # and the client takes the h1 path, which records the dial failure (no silent drop).
      dead = TCPServer.new("127.0.0.1", 0)
      dead_port = dead.local_address.port
      dead.close

      raw = TCPSocket.new("127.0.0.1", proxy.port)
      raw << "CONNECT localhost:#{dead_port} HTTP/1.1\r\nHost: localhost:#{dead_port}\r\n\r\n"
      raw.flush
      Codec::Http1.read_head(raw).not_nil!

      client_ctx = OpenSSL::SSL::Context::Client.new
      client_ctx.alpn_protocol = "h2" # client offers h2; the dead origin can't confirm it
      ca_cert = Cert.read_pem(File.join(dir, "root.crt.pem"))
      st = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(st, ca_cert.handle)

      tls = OpenSSL::SSL::Socket::Client.new(raw, context: client_ctx, sync_close: true, hostname: "localhost")
      tls.alpn_protocol.should_not eq("h2") # reflected h1: nothing upstream to relay h2 to
      tls << "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
      tls.flush

      done.receive # the h1 path recorded the failure (previously: silent drop, empty History)
      tls.close rescue nil
      proxy.stop

      req = sink.requests.first
      req.scheme.should eq("https")
      req.host.should eq("localhost")
      req.port.should eq(dead_port)

      resp = sink.responses.first
      resp.state.should eq(Gori::Store::FlowState::Error)
      resp.error.not_nil!.should contain("localhost:#{dead_port}")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
