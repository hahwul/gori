require "../../spec_helper"

# Roots an enterprise CA or a hostile file can hand `gori ca import`, certificates only:
# `openssl req -x509` with `string_mask = default` (BMPString for the Korean O and CN), and a
# CN carrying an ESC byte.
private BMP_SUBJECT_PEM = <<-PEM
  -----BEGIN CERTIFICATE-----
  MIIBkjCCATigAwIBAgIUFg40iXpDYeQjtJFDxw38n7i4mOYwCgYIKoZIzj0EAwIw
  JjENMAsGA1UECh4E1VytbTEVMBMGA1UEAx4M0UzCpNK4ACAAQwBBMCAXDTI2MTEx
  MjE0MDAxOFoYDzIxMjYxMDE5MTQwMDE4WjAmMQ0wCwYDVQQKHgTVXK1tMRUwEwYD
  VQQDHgzRTMKk0rgAIABDAEEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARdh7nO
  CarfE2zy2Q+jMqQu99RZ8gg40mdhwbG/+GGo7ZOaBYGzrKj0yaHItbxcDgSO+xzw
  MSccGG3hZ1Rpt18ro0IwQDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIB
  BjAdBgNVHQ4EFgQUfnnRFF2a2yydMQIyr7O73y1OG68wCgYIKoZIzj0EAwIDSAAw
  RQIhAJO1lxI61fH7Q/V5qR0kGoiW7WAfc0FKE4LEYgpEtZliAiBx/V3MDGWtZ/lH
  dmMF0haDgN7D3sZPQdksWt86yYZcSA==
  -----END CERTIFICATE-----
  PEM

private ESC_SUBJECT_PEM = <<-PEM
  -----BEGIN CERTIFICATE-----
  MIIBdDCCARqgAwIBAgIUOASfNejfzRlxQPphTabVZcBkTTEwCgYIKoZIzj0EAwIw
  FzEVMBMGA1UEAxQMZXZpbBtbMzFtcmVkMCAXDTI2MTExMjE0MDAxOFoYDzIxMjYx
  MDE5MTQwMDE4WjAXMRUwEwYDVQQDFAxldmlsG1szMW1yZWQwWTATBgcqhkjOPQIB
  BggqhkjOPQMBBwNCAARdh7nOCarfE2zy2Q+jMqQu99RZ8gg40mdhwbG/+GGo7ZOa
  BYGzrKj0yaHItbxcDgSO+xzwMSccGG3hZ1Rpt18ro0IwQDAPBgNVHRMBAf8EBTAD
  AQH/MA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQUfnnRFF2a2yydMQIyr7O73y1O
  G68wCgYIKoZIzj0EAwIDSAAwRQIgUvhuYuQqsFqbHhZzdQS+D6cBcfcdBhnjuMQ3
  05NYFckCIQDTISFZ1nsiQjIVuSlK7Af9jEe8HcdrjuKKkDOz4vuAtg==
  -----END CERTIFICATE-----
  PEM

private def cert_from_pem(pem : String) : Gori::Proxy::Tls::Cert
  path = File.tempname("gori-cert", ".pem")
  File.write(path, pem + "\n")
  Gori::Proxy::Tls::Cert.read_pem(path)
ensure
  File.delete?(path) if path
end

describe Gori::Proxy::Tls::Cert do
  cert, _ = Gori::Proxy::Tls::CertBuilder.build_root("gori Spec CA")

  it "reports the SHA-256 fingerprint the way openssl and the OS viewers print it" do
    fp = cert.sha256_fingerprint
    fp.should match(/\A(?:[0-9A-F]{2}:){31}[0-9A-F]{2}\z/)
    fp.should eq(Digest::SHA256.digest(cert.to_der).join(':') { |b| "%02X" % b })
  end

  it "names the subject" do
    cert.subject.should eq("CN=gori Spec CA")
  end

  it "prints a BMPString subject as UTF-8, in the certificate's order" do
    subject = cert_from_pem(BMP_SUBJECT_PEM).subject
    subject.should eq("O=한국, CN=테스트 CA")
    subject.valid_encoding?.should be_true
  end

  it "escapes a control byte in an imported subject instead of passing it to the terminal" do
    subject = cert_from_pem(ESC_SUBJECT_PEM).subject
    subject.should_not contain('\e')
    subject.should eq("CN=evil\\1B[31mred")
  end

  it "reads the validity window around now" do
    now = Time.utc
    cert.not_before.should be <= now
    cert.not_after.should be > now + 365.days
    cert.not_after.should be > cert.not_before
  end
end
