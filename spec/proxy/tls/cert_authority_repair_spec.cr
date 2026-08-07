require "../../spec_helper"
require "file_utils"

# `gori ca regenerate` / `gori ca import` used to go through load_or_create, which REFUSES a
# half-present pair — the exact state whose error message says to "run `gori ca regenerate`".
# regenerate_at/import_at drop that requirement, and usability_error names the two ways a CA
# that loads fine still cannot serve. See CertAuthority.

private def with_ca_dir(&)
  dir = File.tempname("gori-ca")
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

private def external_pair(dir : String, cn : String = "external ca") : {String, String}
  Dir.mkdir_p(dir)
  cert, key = Gori::Proxy::Tls::CertBuilder.build_root(cn)
  cert_path = File.join(dir, "#{cn.gsub(' ', '_')}.crt.pem")
  key_path = File.join(dir, "#{cn.gsub(' ', '_')}.key.pem")
  cert.write_pem(cert_path)
  key.write_pem(key_path)
  {cert_path, key_path}
end

# A real Ed25519 root (CA:TRUE, valid to 2126), embedded because gori's FFI cannot generate
# one and shelling out to `openssl` would make the spec depend on the host's binary. It passes
# X509_check_private_key AND X509_check_ca, yet gori can never sign a leaf with it — the pair
# that imported "successfully" and then broke every interception with "X509_sign failed".
ED25519_ROOT_CERT = <<-PEM
  -----BEGIN CERTIFICATE-----
  MIIBWTCCAQugAwIBAgIUDVwOa2f2v0LRPJN78U3SAkEt4ZcwBQYDK2VwMCExHzAd
  BgNVBAMMFmdvcmkgc3BlYyBlZDI1NTE5IHJvb3QwIBcNMjYwODA3MTIyOTU0WhgP
  MjEyNjA3MTQxMjI5NTRaMCExHzAdBgNVBAMMFmdvcmkgc3BlYyBlZDI1NTE5IHJv
  b3QwKjAFBgMrZXADIQB3h8qlXAmB2uCrph4p/tKzA7j1XGOIGMUuubFW+QXroKNT
  MFEwHQYDVR0OBBYEFKuWNqaeik7qBVxJnEqyZvq6VLFPMB8GA1UdIwQYMBaAFKuW
  Nqaeik7qBVxJnEqyZvq6VLFPMA8GA1UdEwEB/wQFMAMBAf8wBQYDK2VwA0EAfuSl
  BDlelpXc17yy6OdPG+hS2WyX3EdMl7fdrTPg52XhLMIsfV8h8TPJL0VPw58hipYX
  2dp/ZtQufnoO8J8LDA==
  -----END CERTIFICATE-----
  PEM

ED25519_ROOT_KEY = <<-PEM
  -----BEGIN PRIVATE KEY-----
  MC4CAQAwBQYDK2VwBCIEIByvzJMRghllBU28Ck7K0B4EA4CMLsaqiYuml7CKQ7nj
  -----END PRIVATE KEY-----
  PEM

private def ed25519_pair(dir : String) : {String, String}
  Dir.mkdir_p(dir)
  cert_path = File.join(dir, "ed.crt.pem")
  key_path = File.join(dir, "ed.key.pem")
  File.write(cert_path, ED25519_ROOT_CERT + "\n")
  File.write(key_path, ED25519_ROOT_KEY + "\n")
  {cert_path, key_path}
end

describe "Gori::Proxy::Tls::CertAuthority — repairing a broken CA dir" do
  it "regenerate_at mints a fresh root where the pair is half-present" do
    with_ca_dir do |dir|
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      File.delete(File.join(dir, "root.key.pem")) # the state load_or_create refuses

      expect_raises(Gori::Error, /CA pair broken/) do
        Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      end

      path = Gori::Proxy::Tls::CertAuthority.regenerate_at(dir)
      path.should eq(File.join(dir, "root.crt.pem"))
      # Repaired for real: the dir loads again, and the restored key is owner-only.
      reloaded = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      reloaded.usability_error.should be_nil
      File.info(File.join(dir, "root.key.pem")).permissions.value.should eq(0o600)
    end
  end

  it "regenerate_at works on an empty dir and on a dir that does not exist yet" do
    with_ca_dir do |dir|
      nested = File.join(dir, "deep", "ca")
      Gori::Proxy::Tls::CertAuthority.regenerate_at(nested).should eq(File.join(nested, "root.crt.pem"))
      Gori::Proxy::Tls::CertAuthority.load_or_create(nested).usability_error.should be_nil
    end
  end

  it "import_at adopts an external root where the pair is half-present" do
    with_ca_dir do |dir|
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      File.delete(File.join(dir, "root.crt.pem")) # the other half of the broken state

      with_ca_dir do |src|
        cert_path, key_path = external_pair(src)
        path, warning = Gori::Proxy::Tls::CertAuthority.import_at(dir, cert_path, key_path)
        warning.should be_nil
        path.should eq(File.join(dir, "root.crt.pem"))
        File.read(path).should eq(File.read(cert_path)) # THEIR root, not a gori-minted one
      end
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir).usability_error.should be_nil
    end
  end

  it "import_at leaves no CA behind when the pair is rejected" do
    with_ca_dir do |dir|
      with_ca_dir do |src|
        cert_path, _ = external_pair(src, "cert one")
        _, other_key = external_pair(src, "cert two")
        expect_raises(Gori::Error, /does not match/) do
          Gori::Proxy::Tls::CertAuthority.import_at(dir, cert_path, other_key)
        end
      end
      # A failed import must not mint a surprise gori root — the operator asked for THEIRS.
      File.exists?(File.join(dir, "root.crt.pem")).should be_false
    end
  end
end

describe "Gori::Proxy::Tls::CertAuthority — a CA key gori cannot sign with" do
  it "rejects an Ed25519 root on import, leaving the current CA intact" do
    with_ca_dir do |dir|
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      before = ca.ca_cert_pem
      with_ca_dir do |src|
        cert_path, key_path = ed25519_pair(src)
        # It passes both older checks — this is why the functional probe had to exist.
        cert = Gori::Proxy::Tls::Cert.read_pem(cert_path)
        key = Gori::Proxy::Tls::KeyPair.read_pem(key_path)
        LibCrypto.x509_check_private_key(cert.handle, key.handle).should eq(1)
        LibCrypto.x509_check_ca(cert.handle).should_not eq(0)

        expect_raises(Gori::Error, /cannot sign certificates with this CA key/) do
          ca.import!(cert_path, key_path)
        end
        expect_raises(Gori::Error, /cannot sign certificates with this CA key/) do
          Gori::Proxy::Tls::CertAuthority.validate_pem_pair(cert_path, key_path)
        end
      end
      ca.ca_cert_pem.should eq(before)
      ca.context_for("still.works").should_not be_nil
    end
  end

  it "usability_error names an already-installed Ed25519 root (a pre-fix import)" do
    with_ca_dir do |dir|
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      # Install it the way the pre-fix `gori ca import` did — straight onto the root paths.
      File.write(File.join(dir, "root.crt.pem"), ED25519_ROOT_CERT + "\n")
      File.write(File.join(dir, "root.key.pem"), ED25519_ROOT_KEY + "\n")

      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir) # loads fine; that is the problem
      ca.usability_error.should match(/cannot sign leaf certificates/)
      # And the way out is available even though nothing can be signed.
      Gori::Proxy::Tls::CertAuthority.regenerate_at(dir)
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir).usability_error.should be_nil
    end
  end
end

describe "Gori::Proxy::Tls::CertAuthority#usability_error" do
  it "is nil for a healthy CA" do
    with_ca_dir do |dir|
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir).usability_error.should be_nil
    end
  end

  it "names a key that does not match the cert (the rename-gap / hand-copy state)" do
    with_ca_dir do |dir|
      Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      with_ca_dir do |src|
        _, other_key = external_pair(src, "someone elses ca")
        File.copy(other_key, File.join(dir, "root.key.pem"))
      end

      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
      ca.key_matches_cert?.should be_false
      ca.usability_error.should match(/does not match/)
    end
  end
end

describe "Gori::Proxy::Tls::CertAuthority.read_external_pair" do
  it "says what is wrong with an operator-named path instead of naming an OpenSSL call" do
    with_ca_dir do |dir|
      cert_path, key_path = external_pair(dir)

      expect_raises(Gori::Error, /certificate file not found: .*nope\.pem/) do
        Gori::Proxy::Tls::CertAuthority.read_external_pair(File.join(dir, "nope.pem"), key_path)
      end
      # A directory OPENS fine, so this used to die as "PEM_read_bio_X509 failed".
      expect_raises(Gori::Error, /certificate path is a directory/) do
        Gori::Proxy::Tls::CertAuthority.read_external_pair(dir, key_path)
      end
      junk = File.join(dir, "junk.txt")
      File.write(junk, "not a pem at all\n")
      expect_raises(Gori::Error, /is not a PEM certificate/) do
        Gori::Proxy::Tls::CertAuthority.read_external_pair(junk, key_path)
      end
      expect_raises(Gori::Error, /is not a PEM private key/) do
        Gori::Proxy::Tls::CertAuthority.read_external_pair(cert_path, junk)
      end
      expect_raises(Gori::Error, /private key file not found/) do
        Gori::Proxy::Tls::CertAuthority.read_external_pair(cert_path, File.join(dir, "gone.pem"))
      end
    end
  end
end
