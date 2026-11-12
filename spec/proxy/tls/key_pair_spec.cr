require "../../spec_helper"

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

  it "reads the validity window around now" do
    now = Time.utc
    cert.not_before.should be <= now
    cert.not_after.should be > now + 365.days
    cert.not_after.should be > cert.not_before
  end
end
