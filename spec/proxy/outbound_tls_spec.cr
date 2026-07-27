require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

include Gori::Proxy::Tls

private def reset_outbound_tls : Nil
  Gori::Settings.outbound_tls = [] of Gori::Settings::OutboundTlsRule
end

private def tls_rule(host : String, cert : String = "", key : String = "",
                     min_version : String = "", ciphers : String = "",
                     permissive : Bool = false) : Gori::Settings::OutboundTlsRule
  Gori::Settings::OutboundTlsRule.new(host, cert, key, min_version, ciphers, permissive)
end

# Write a self-signed cert + key pair to disk and yield their paths — what a client certificate
# actually is on this path (PEM files, not inline material).
private def with_client_cert(&)
  dir = File.tempname("gori-client-cert")
  Dir.mkdir_p(dir)
  cert_path = File.join(dir, "client.crt.pem")
  key_path = File.join(dir, "client.key.pem")
  cert, key = CertBuilder.build_root("client.test")
  cert.write_pem(cert_path)
  key.write_pem(key_path)
  begin
    yield cert_path, key_path
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A TLS server that ASKS for a client certificate and reports the subject it received, so mutual
# TLS is asserted by what the server saw rather than by "the handshake didn't blow up".
#
# `client_ca` is trusted so a presented certificate verifies; without it OpenSSL checks the
# client chain against an empty store and aborts the handshake, which would make this helper
# report a failure for the very case it is meant to observe. VerifyMode::PEER *without*
# FAIL_IF_NO_PEER_CERT is deliberate: a client that presents nothing must still connect, which
# is what the control example asserts.
private def start_mtls_origin(seen : Channel(String), client_ca : String? = nil) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::PEER
  ctx.ca_certificates = client_ca if client_ca
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        peer = ssl.peer_certificate
        seen.send(peer ? peer.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",") : "(none)")
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        ssl.flush
        ssl.close
      rescue
        seen.send("(handshake failed)") rescue nil
      end
    end
  end
  port
end

describe "outbound TLS policy" do
  describe ".outbound_tls_for" do
    it "returns the first matching rule, else the all-defaults policy" do
      Gori::Settings.outbound_tls = [
        tls_rule("api.acme.test", min_version: "tls1.0"),
        tls_rule("*", min_version: "tls1.2"),
      ]
      Gori::Settings.outbound_tls_for("api.acme.test").min_version.should eq("tls1.0")
      Gori::Settings.outbound_tls_for("other.test").min_version.should eq("tls1.2")

      reset_outbound_tls
      Gori::Settings.outbound_tls_for("anything.test").default?.should be_true
    ensure
      reset_outbound_tls
    end

    it "covers subdomains and is case-insensitive (shared host dialect)" do
      Gori::Settings.outbound_tls = [tls_rule("Acme.TEST", min_version: "tls1.1")]
      Gori::Settings.outbound_tls_for("api.acme.test").min_version.should eq("tls1.1")
      Gori::Settings.outbound_tls_for("acme.test.evil.test").default?.should be_true
    ensure
      reset_outbound_tls
    end
  end

  # This is the trap both #434 and #437 flagged: the TLS context cache was keyed on
  # {verify, alpn} only. Any policy field left out of the key means the FIRST context built
  # wins for the whole process — a client certificate would be presented to hosts it was never
  # configured for, and a settings change would silently do nothing.
  describe "context cache key" do
    it "gives every distinct policy its own key, and shares ONE key for the defaults" do
      keys = [
        tls_rule("a", cert: "/c.pem", key: "/k.pem"),
        tls_rule("a", cert: "/other.pem", key: "/k.pem"),
        tls_rule("a", min_version: "tls1.0"),
        tls_rule("a", min_version: "tls1.3"),
        tls_rule("a", ciphers: "DEFAULT@SECLEVEL=0"),
        tls_rule("a", permissive: true),
      ].map(&.cache_key)

      keys.uniq.size.should eq(keys.size) # no two distinct policies collide
      keys.should_not contain("")         # every non-default policy is distinguishable

      # All-defaults policies share the empty key, so the common case keeps one shared context.
      tls_rule("a").cache_key.should eq("")
      tls_rule("b").cache_key.should eq("")
      Gori::Settings::DEFAULT_OUTBOUND_TLS.cache_key.should eq("")
    end

    # Concatenating fields without a separator would let two different policies produce one
    # key (a cert path ending exactly where the next field begins).
    it "does not let differently-split fields collide into one key" do
      tls_rule("a", cert: "/ab", key: "/c").cache_key
        .should_not eq(tls_rule("a", cert: "/a", key: "b/c").cache_key)
    end
  end

  describe "client certificates (mutual TLS)" do
    it "presents the configured certificate to a server that asks for one" do
      seen = Channel(String).new(2)
      with_client_cert do |cert, key|
        port = start_mtls_origin(seen, client_ca: cert)
        Gori::Settings.outbound_tls = [tls_rule("localhost", cert: cert, key: key)]
        sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        sock.should_not be_nil
        seen.receive.should contain("client.test") # the origin saw OUR certificate
        sock.try(&.close) rescue nil
      end
    ensure
      reset_outbound_tls
    end

    # The control: same origin, same dial, no rule — nothing is presented. Without this, the
    # test above could pass on a server that happened to report something.
    it "presents nothing when no rule covers the host" do
      seen = Channel(String).new(2)
      port = start_mtls_origin(seen)
      reset_outbound_tls
      sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
      sock.should_not be_nil
      seen.receive.should eq("(none)")
      sock.try(&.close) rescue nil
    ensure
      reset_outbound_tls
    end

    # The consequence of the cache-key fix, stated as behaviour: a certificate configured for
    # one host must not leak to another host dialed later in the same process.
    it "does not leak one host's certificate to a host with no rule" do
      seen = Channel(String).new(4)
      with_client_cert do |cert, key|
        port = start_mtls_origin(seen, client_ca: cert)
        # 127.0.0.1 and localhost are the same origin but different rule keys.
        Gori::Settings.outbound_tls = [tls_rule("localhost", cert: cert, key: key)]
        a = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        seen.receive.should contain("client.test")
        a.try(&.close) rescue nil

        b = Gori::Proxy::Upstream.dial_tls("127.0.0.1", port, verify: false)
        seen.receive.should eq("(none)") # a cached context would have re-presented the cert
        b.try(&.close) rescue nil
      end
    ensure
      reset_outbound_tls
    end
  end

  describe "protocol floor" do
    # Crystal's Context::Client.new adds NO_TLS_V1 | NO_TLS_V1_1, which is exactly why a
    # legacy appliance was unreachable at ANY setting before this. Asserted against a real
    # TLS 1.0-only server, so it pins the behaviour rather than the flag arithmetic.
    it "reaches a TLS 1.0-only origin only when the floor is lowered" do
      cert, key = CertBuilder.build_root("legacy.test")
      ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
      ctx.security_level = 0
      ctx.ciphers = "ALL:@SECLEVEL=0"
      # Force TLS 1.0 only: forbid everything above it.
      ctx.add_options(OpenSSL::SSL::Options.flags(NO_TLS_V1_2, NO_TLS_V1_3))
      ctx.remove_options(OpenSSL::SSL::Options.flags(NO_TLS_V1, NO_TLS_V1_1))
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        while raw = server.accept?
          begin
            ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
            ssl << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
            ssl.flush
            ssl.close
          rescue
          end
        end
      end

      begin
        # Default policy: the constructor's NO_TLS_V1/NO_TLS_V1_1 makes this unreachable.
        reset_outbound_tls
        Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false).should be_nil

        # Floor lowered + legacy ciphers allowed: it connects.
        Gori::Settings.outbound_tls = [
          tls_rule("localhost", min_version: "tls1.0", ciphers: "ALL:@SECLEVEL=0", permissive: true),
        ]
        sock = Gori::Proxy::Upstream.dial_tls("localhost", port, verify: false)
        sock.should_not be_nil
        sock.try(&.close) rescue nil
      ensure
        server.close rescue nil
        reset_outbound_tls
      end
    end
  end

  describe ".outbound_tls_error" do
    it "accepts a rule with neither half of a certificate pair" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", min_version: "tls1.2")).should be_nil
    end

    it "accepts a readable cert/key pair" do
      with_client_cert do |cert, key|
        Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: cert, key: key)).should be_nil
      end
    end

    it "rejects half a pair, since one half alone can never complete a handshake" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: "/tmp/c.pem")).to_s
        .should contain("BOTH client_cert and client_key")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", key: "/tmp/k.pem")).to_s
        .should contain("BOTH client_cert and client_key")
    end

    it "rejects an unreadable file at save time rather than at the first dial" do
      Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: "/nope/c.pem", key: "/nope/k.pem")).to_s
        .should contain("client_cert not readable")
    end

    it "rejects a missing host and an unknown min_version" do
      Gori::Settings.outbound_tls_error(tls_rule(" ")).to_s.should contain("host pattern")
      Gori::Settings.outbound_tls_error(tls_rule("a.test", min_version: "ssl3")).to_s
        .should contain("min_version must be one of")
    end

    # An encrypted key makes OpenSSL prompt for a passphrase on the terminal the TUI owns —
    # the process would look hung with no visible prompt.
    it "rejects a passphrase-protected key, naming the fix" do
      with_client_cert do |cert, key|
        File.write(key, "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n")
        msg = Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: cert, key: key)).to_s
        msg.should contain("passphrase-protected")
        msg.should contain("openssl pkey")
      end
    end

    it "rejects a traditional-format key carrying the legacy Proc-Type header" do
      with_client_cert do |cert, key|
        File.write(key, "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,00\n\nAAAA\n")
        Gori::Settings.outbound_tls_error(tls_rule("a.test", cert: cert, key: key)).to_s
          .should contain("passphrase-protected")
      end
    end
  end
end
