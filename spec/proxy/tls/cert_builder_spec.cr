require "../../spec_helper"
require "socket"
require "file_utils"
require "digest/sha1"

private def with_tmp_dir(&)
  dir = File.tempname("gori-certb")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def ext_text(cert : Gori::Proxy::Tls::Cert, dir : String, exts : String) : String
  path = File.join(dir, "c#{Random.rand(1_000_000)}.pem")
  cert.write_pem(path)
  `openssl x509 -in #{path} -noout -ext #{exts} 2>&1`
end

# The hex after an extension's header line, e.g. "AB:CD:…" — what `openssl x509 -ext` prints
# for a subject/authority key identifier.
private def key_id(text : String, header : String) : String
  text[/#{header}:\s*\n\s*(?:keyid:)?([0-9A-F:]+)/, 1]
end

# A root in the shape gori minted before #1168 (or an operator imports): basicConstraints
# only — no SKI, no AKI, no keyUsage. `none` keeps OpenSSL 3's req from adding the key
# identifiers it would otherwise add by default.
private def legacy_root(dir : String, extra : String = "") : {String, String}
  cfg = File.join(dir, "legacy.cnf")
  File.write(cfg, <<-CNF)
    [req]
    distinguished_name = dn
    [dn]
    [v3]
    basicConstraints = critical,CA:TRUE
    subjectKeyIdentifier = none
    authorityKeyIdentifier = none
    #{extra}
    CNF
  cert = File.join(dir, "legacy.crt.pem")
  key = File.join(dir, "legacy.key.pem")
  ok = Process.run("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                               "-nodes", "-subj", "/CN=legacy root", "-days", "30", "-config", cfg,
                               "-extensions", "v3", "-keyout", key, "-out", cert]).success?
  raise "openssl req failed" unless ok
  {cert, key}
end

private def strict_handshake(ca : Gori::Proxy::Tls::CertAuthority, root_pem : String, host : String) : String
  server_ctx = ca.context_for(host)
  client_ctx = OpenSSL::SSL::Context::Client.new
  client_ctx.add_x509_verify_flags(OpenSSL::SSL::X509VerifyFlags::X509_STRICT)
  store = LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, Gori::Proxy::Tls::Cert.read_pem(root_pem).handle)

  tcp_server = TCPServer.new("127.0.0.1", 0)
  port = tcp_server.local_address.port
  result = Channel(String).new
  spawn do
    conn = tcp_server.accept
    ssl = OpenSSL::SSL::Socket::Server.new(conn, server_ctx, sync_close: true)
    ssl.puts(ssl.gets)
    ssl.flush
    ssl.close
  rescue
    # the client reports the verdict
  end
  spawn do
    tcp = TCPSocket.new("127.0.0.1", port)
    ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_ctx, sync_close: true, hostname: host)
    ssl.puts("ping")
    ssl.flush
    echo = ssl.gets
    ssl.close
    result.send("ok: #{echo}")
  rescue ex
    result.send("client-error: #{ex.message}")
  end
  verdict = result.receive
  tcp_server.close
  verdict
end

# #1168: Python 3.13+ turns on X509_V_FLAG_X509_STRICT in ssl.create_default_context(), which
# rejects a leaf without an AKI and a CA without an SKI + keyUsage. gori minted neither.
describe Gori::Proxy::Tls::CertBuilder do
  it "gives the root an SKI, a matching AKI and a critical keyUsage" do
    with_tmp_dir do |dir|
      root, _ = Gori::Proxy::Tls::CertBuilder.build_root("gori test CA")
      text = ext_text(root, dir, "subjectKeyIdentifier,authorityKeyIdentifier,keyUsage")
      ski = key_id(text, "Subject Key Identifier")
      ski.split(':').size.should eq(20) # SHA-1, RFC 5280 §4.2.1.2 method (1)
      key_id(text, "Authority Key Identifier").should eq(ski)
      text.should match(/Key Usage: critical\s*\n\s*Digital Signature, Certificate Sign, CRL Sign/)
    end
  end

  it "gives a leaf the issuer's key id as its AKI, plus serverAuth usage" do
    with_tmp_dir do |dir|
      root, root_key = Gori::Proxy::Tls::CertBuilder.build_root("gori test CA")
      leaf, _ = Gori::Proxy::Tls::CertBuilder.build_leaf("api.example.test", root, root_key)
      root_ski = key_id(ext_text(root, dir, "subjectKeyIdentifier"), "Subject Key Identifier")
      text = ext_text(leaf, dir, "subjectKeyIdentifier,authorityKeyIdentifier,keyUsage,extendedKeyUsage")
      key_id(text, "Authority Key Identifier").should eq(root_ski)
      key_id(text, "Subject Key Identifier").should_not eq(root_ski)
      text.should match(/Key Usage: critical\s*\n\s*Digital Signature/)
      text.should match(/Extended Key Usage:\s*\n\s*TLS Web Server Authentication/)
    end
  end

  # A root's keyUsage must not stop it serving as a self-signed end-entity certificate, which
  # is what it was before #1168 gave it one (no keyUsage allows every usage): an ECDSA server
  # cert on TLS 1.2 and a TLS client cert both need digitalSignature.
  it "leaves the root usable as a self-signed server and client certificate" do
    cert, key = Gori::Proxy::Tls::CertBuilder.build_root("origin.test")
    server_ctx = Gori::Proxy::Tls::ContextFactory.server_context(cert, key, advertise_h2: false)
    server_ctx.verify_mode = OpenSSL::SSL::VerifyMode::PEER
    store = LibSSL.ssl_ctx_get_cert_store(server_ctx.to_unsafe)
    LibCrypto.x509_store_add_cert(store, cert.handle) # trusts the same cert presented as client
    client_ctx = OpenSSL::SSL::Context::Client.insecure
    client_ctx.add_options(OpenSSL::SSL::Options::NO_TLS_V1_3) # TLS 1.2: the ECDSA usage check
    LibSSL.ssl_ctx_use_certificate(client_ctx.to_unsafe, cert.handle)
    LibSSL.ssl_ctx_use_privatekey(client_ctx.to_unsafe, key.handle)

    tcp_server = TCPServer.new("127.0.0.1", 0)
    port = tcp_server.local_address.port
    seen = Channel(String).new(2)
    spawn do
      ssl = OpenSSL::SSL::Socket::Server.new(tcp_server.accept, server_ctx, sync_close: true)
      seen.send(ssl.peer_certificate ? "client cert accepted" : "no client cert")
      ssl.close
    rescue ex
      seen.send("server-error: #{ex.message}")
    end
    begin
      ssl = OpenSSL::SSL::Socket::Client.new(TCPSocket.new("127.0.0.1", port), context: client_ctx, sync_close: true)
      ssl.tls_version.should eq("TLSv1.2")
      ssl.close rescue nil
    rescue ex
      seen.send("client-error: #{ex.message}")
    end
    seen.receive.should eq("client cert accepted")
    tcp_server.close
  end

  # A CA already on disk is not re-issued, so the leaf's AKI must match THAT key. Without an
  # SKI to copy, it is the hash of the CA's public key — what an SKI would have held.
  it "derives the AKI from the key of a root that has no SKI" do
    with_tmp_dir do |dir|
      cert_path, key_path = legacy_root(dir)
      root = Gori::Proxy::Tls::Cert.read_pem(cert_path)
      ext_text(root, dir, "subjectKeyIdentifier").should_not contain("Subject Key Identifier")
      leaf, _ = Gori::Proxy::Tls::CertBuilder.build_leaf("a.test", root, Gori::Proxy::Tls::KeyPair.read_pem(key_path))

      spki = `openssl x509 -in #{cert_path} -noout -pubkey | openssl pkey -pubin -outform DER`.to_slice
      # P-256 SPKI: the BIT STRING's 65-byte uncompressed point is the tail of the DER.
      want = Digest::SHA1.hexdigest(spki[-65..]).upcase.scan(/../).map(&.[0]).join(':')
      key_id(ext_text(leaf, dir, "authorityKeyIdentifier"), "Authority Key Identifier").should eq(want)
    end
  end

  # ...and a root that HAS one, minted by some other method, is copied rather than recomputed:
  # OpenSSL compares the leaf's AKI against the CA's SKI byte-for-byte.
  it "copies an imported root's own SKI even when it is not the key hash" do
    with_tmp_dir do |dir|
      cert_path, key_path = legacy_root(dir, "subjectKeyIdentifier = 0102030405060708\nkeyUsage = critical,keyCertSign,cRLSign")
      root = Gori::Proxy::Tls::Cert.read_pem(cert_path)
      leaf, _ = Gori::Proxy::Tls::CertBuilder.build_leaf("a.test", root, Gori::Proxy::Tls::KeyPair.read_pem(key_path))
      key_id(ext_text(leaf, dir, "authorityKeyIdentifier"), "Authority Key Identifier").should eq("01:02:03:04:05:06:07:08")
    end
  end
end

describe "Gori::Proxy::Tls::CertAuthority under strict verification" do
  it "serves a leaf an X509_STRICT client accepts" do
    with_tmp_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(dir, "ca"))
      strict_handshake(ca, ca.ca_cert_path, "example.test").should eq("ok: ping")
      ca.strict_verify_gaps.should be_empty
    end
  end

  # A root in a strict verifier's accepted shape that gori did not mint: the leaf is the only
  # thing gori controls, and it now passes.
  it "serves a strict-valid leaf under an imported root with a non-hash SKI" do
    with_tmp_dir do |dir|
      cert_path, key_path = legacy_root(dir, "subjectKeyIdentifier = 0102030405060708\nkeyUsage = critical,keyCertSign,cRLSign")
      ca_dir = File.join(dir, "ca")
      Gori::Proxy::Tls::CertAuthority.import_at(ca_dir, cert_path, key_path)[1].should be_nil
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
      strict_handshake(ca, ca.ca_cert_path, "example.test").should eq("ok: ping")
    end
  end

  # An existing pre-#1168 root cannot be fixed without re-trusting it, so gori names it.
  it "names what an old-shape root lacks, and warns when one is imported" do
    with_tmp_dir do |dir|
      cert_path, key_path = legacy_root(dir)
      ca_dir = File.join(dir, "ca")
      _, warning = Gori::Proxy::Tls::CertAuthority.import_at(ca_dir, cert_path, key_path)
      warning.should eq("the root CA has no subjectKeyIdentifier or keyUsage extension, so strict " \
                        "TLS clients (Python 3.13+, `openssl verify -x509_strict`) reject its certificates")
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
      ca.strict_verify_gaps.should eq(["subjectKeyIdentifier", "keyUsage"])
      strict_handshake(ca, ca.ca_cert_path, "example.test").should start_with("client-error")
    end
  end
end
