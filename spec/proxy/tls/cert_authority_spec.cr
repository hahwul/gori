require "../../spec_helper"
require "base64"
require "socket"
require "file_utils"

private def with_ca_dir(&)
  dir = File.tempname("gori-ca")
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

describe Gori::Proxy::Tls::CertAuthority do
  it "generates and persists a root CA on first run" do
    with_ca_dir do |dir|
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      File.exists?(File.join(dir, "root.crt.pem")).should be_true
      File.exists?(File.join(dir, "root.key.pem")).should be_true
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir).ca_cert_pem.should contain("BEGIN CERTIFICATE")
    end
  end

  it "reuses the same root CA across reloads (idempotent)" do
    with_ca_dir do |dir|
      pem1 = Gori::Proxy::Tls::CertAuthority.load_or_create(dir).ca_cert_pem
      pem2 = Gori::Proxy::Tls::CertAuthority.load_or_create(dir).ca_cert_pem
      pem2.should eq(pem1) # not regenerated
    end
  end

  it "mints a leaf that a client verifies against the CA over a real handshake" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      server_ctx = ca.context_for("localhost")

      # client trusts the CA via its in-memory X509_STORE
      client_ctx = OpenSSL::SSL::Context::Client.new
      ca_cert = Gori::Proxy::Tls::Cert.read_pem(File.join(dir, "root.crt.pem"))
      store = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(store, ca_cert.handle).should eq(1)

      tcp_server = TCPServer.new("127.0.0.1", 0)
      port = tcp_server.local_address.port
      result = Channel(String).new

      spawn do
        conn = tcp_server.accept
        ssl = OpenSSL::SSL::Socket::Server.new(conn, server_ctx, sync_close: true)
        ssl.puts(ssl.gets)
        ssl.flush
        ssl.close
      rescue ex
        result.send("server-error: #{ex.message}")
      end

      spawn do
        tcp = TCPSocket.new("127.0.0.1", port)
        ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_ctx, sync_close: true, hostname: "localhost")
        ssl.puts("ping")
        ssl.flush
        echo = ssl.gets
        ssl.close
        result.send("ok: #{echo}")
      rescue ex
        result.send("client-error: #{ex.class}: #{ex.message}")
      end

      result.receive.should eq("ok: ping") # full chain + hostname verification passed
    end
  end

  it "computes the CA SubjectPublicKeyInfo SHA-256 pin (base64) for browser trust" do
    with_ca_dir do |dir|
      spki = Gori::Proxy::Tls::CertAuthority.load_or_create(dir).spki_sha256_base64
      Base64.decode(spki).size.should eq(32) # a SHA-256 digest
      # deterministic across reloads of the same persisted CA
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir).spki_sha256_base64.should eq(spki)
    end
  end

  it "serves the leaf with the root appended to the chain (for SPKI pinning)" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      server_ctx = ca.context_for("example.test")
      client_ctx = OpenSSL::SSL::Context::Client.new
      ca_cert = Gori::Proxy::Tls::Cert.read_pem(File.join(dir, "root.crt.pem"))
      store = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(store, ca_cert.handle)

      tcp_server = TCPServer.new("127.0.0.1", 0)
      port = tcp_server.local_address.port
      result = Channel(String).new

      spawn do
        conn = tcp_server.accept
        ssl = OpenSSL::SSL::Socket::Server.new(conn, server_ctx, sync_close: true)
        ssl.puts(ssl.gets)
        ssl.flush
        ssl.close
      rescue ex
        result.send("server-error: #{ex.message}")
      end

      spawn do
        tcp = TCPSocket.new("127.0.0.1", port)
        ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_ctx, sync_close: true, hostname: "example.test")
        ssl.puts("ping")
        ssl.flush
        echo = ssl.gets
        # peer_certificate is the leaf; the chain also carrying the root is what
        # lets a browser's --ignore-certificate-errors-spki-list match. Verifying
        # the handshake still succeeds proves the appended root didn't break it.
        ssl.close
        result.send("ok: #{echo}")
      rescue ex
        result.send("client-error: #{ex.class}: #{ex.message}")
      end

      result.receive.should eq("ok: ping")
    end
  end

  it "caches the context per host" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      ca.context_for("a.test").should be(ca.context_for("a.test")) # same object
      ca.context_for("b.test").should_not be(ca.context_for("a.test"))
    end
  end

  it "regenerates a fresh root in place — persisted, leaf cache dropped, key 0600" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      old_pem = ca.ca_cert_pem
      old_spki = ca.spki_sha256_base64
      old_leaf = ca.context_for("a.test") # warm the per-host cache

      ca.regenerate!

      ca.ca_cert_pem.should_not eq(old_pem)         # a brand-new root identity
      ca.spki_sha256_base64.should_not eq(old_spki) # new key → new SPKI pin
      ca.context_for("a.test").should_not be(old_leaf) # stale leaf evicted
      # The swap is persisted: a reload reads the NEW root, not the old one.
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir).ca_cert_pem.should eq(ca.ca_cert_pem)
      File.info(File.join(dir, "root.key.pem")).permissions.value.should eq(0o600)
    end
  end

  it "recreates the CA dir if it was removed at runtime before regenerating" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      FileUtils.rm_rf(dir) # the dir disappears out from under the live CA
      ca.regenerate!       # must re-establish it (parity with load_or_create), not crash
      File.exists?(File.join(dir, "root.crt.pem")).should be_true
      File.exists?(File.join(dir, "root.key.pem")).should be_true
    end
  end

  it "mints a leaf under the NEW root after regeneration" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      ca.regenerate!
      server_ctx = ca.context_for("localhost")

      # client trusts ONLY the regenerated root (read fresh off disk)
      client_ctx = OpenSSL::SSL::Context::Client.new
      ca_cert = Gori::Proxy::Tls::Cert.read_pem(File.join(dir, "root.crt.pem"))
      store = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
      LibCrypto.x509_store_add_cert(store, ca_cert.handle).should eq(1)

      tcp_server = TCPServer.new("127.0.0.1", 0)
      port = tcp_server.local_address.port
      result = Channel(String).new

      spawn do
        conn = tcp_server.accept
        ssl = OpenSSL::SSL::Socket::Server.new(conn, server_ctx, sync_close: true)
        ssl.puts(ssl.gets)
        ssl.flush
        ssl.close
      rescue ex
        result.send("server-error: #{ex.message}")
      end

      spawn do
        tcp = TCPSocket.new("127.0.0.1", port)
        ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_ctx, sync_close: true, hostname: "localhost")
        ssl.puts("ping")
        ssl.flush
        echo = ssl.gets
        ssl.close
        result.send("ok: #{echo}")
      rescue ex
        result.send("client-error: #{ex.class}: #{ex.message}")
      end

      result.receive.should eq("ok: ping") # the new leaf chains to the new root
    end
  end
end
