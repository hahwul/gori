require "../../spec_helper"
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

# Build an "externally-created" root CA (or, with is_ca: false, a leaf) and write
# its cert + key to PEM files under `dir`, returning their paths — the input a
# `gori ca import` caller supplies.
private def external_pair(dir : String, cn : String = "external ca") : {String, String}
  Dir.mkdir_p(dir)
  cert, key = Gori::Proxy::Tls::CertBuilder.build_root(cn)
  cert_path = File.join(dir, "#{cn.gsub(' ', '_')}.crt.pem")
  key_path = File.join(dir, "#{cn.gsub(' ', '_')}.key.pem")
  cert.write_pem(cert_path)
  key.write_pem(key_path)
  {cert_path, key_path}
end

describe "Gori::Proxy::Tls::CertAuthority#import!" do
  it "adopts an external root in place — persisted, replaces the old root, key 0600" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      auto_pem = ca.ca_cert_pem
      ca.context_for("a.test") # warm the per-host leaf cache

      with_ca_dir do |src|
        cert_path, key_path = external_pair(src)
        imported_pem = File.read(cert_path)

        ca.import!(cert_path, key_path).should be_nil # no time warning for a fresh root

        ca.ca_cert_pem.should_not eq(auto_pem) # the auto-generated root is gone
        ca.ca_cert_pem.should eq(imported_pem) # ...replaced by the imported one
        # The swap is persisted: a reload reads the IMPORTED root off disk.
        Gori::Proxy::Tls::CertAuthority.load_or_create(dir).ca_cert_pem.should eq(imported_pem)
        File.info(File.join(dir, "root.key.pem")).permissions.value.should eq(0o600)
      end
    end
  end

  it "mints a leaf a client verifies under the IMPORTED root over a real handshake" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      with_ca_dir do |src|
        cert_path, key_path = external_pair(src)
        ca.import!(cert_path, key_path)
      end
      server_ctx = ca.context_for("localhost")

      # The client trusts ONLY the imported root, read fresh off disk.
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
        result.send(echo || "nil")
      rescue ex
        result.send("client-error: #{ex.message}")
      end

      result.receive.should eq("ping") # handshake + echo succeeded under the imported root
      tcp_server.close
    end
  end

  it "rejects a private key that does not match the certificate (CA untouched)" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      before = ca.ca_cert_pem
      with_ca_dir do |src|
        cert_path, _ = external_pair(src, "cert one")
        _, other_key = external_pair(src, "cert two") # a DIFFERENT pair's key

        expect_raises(Gori::Error, /does not match/) do
          ca.import!(cert_path, other_key)
        end
      end
      ca.ca_cert_pem.should eq(before) # the working CA is left intact
    end
  end

  it "rejects a certificate that is not a CA (basicConstraints CA:FALSE)" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      before = ca.ca_cert_pem
      with_ca_dir do |src|
        # A leaf cert (CA:FALSE) plus its own key: a matching pair, but not a CA.
        root_cert, root_key = Gori::Proxy::Tls::CertBuilder.build_root("signing root")
        leaf_cert, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("leaf.example", root_cert, root_key)
        cert_path = File.join(src, "leaf.crt.pem")
        key_path = File.join(src, "leaf.key.pem")
        Dir.mkdir_p(src)
        leaf_cert.write_pem(cert_path)
        leaf_key.write_pem(key_path)

        expect_raises(Gori::Error, /not a CA/) do
          ca.import!(cert_path, key_path)
        end
      end
      ca.ca_cert_pem.should eq(before)
    end
  end

  it "validate_pem_pair accepts a good pair and rejects a bad one without writing" do
    with_ca_dir do |src|
      cert_path, key_path = external_pair(src, "good ca")
      Gori::Proxy::Tls::CertAuthority.validate_pem_pair(cert_path, key_path).should be_nil

      _, other_key = external_pair(src, "other ca")
      expect_raises(Gori::Error, /does not match/) do
        Gori::Proxy::Tls::CertAuthority.validate_pem_pair(cert_path, other_key)
      end
    end
  end
end
