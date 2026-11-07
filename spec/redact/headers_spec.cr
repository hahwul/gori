require "../spec_helper"
require "../../src/gori/redact/headers"

describe "Gori::Redact.sensitive_header?" do
  it "matches the credential header names in any casing, padding included" do
    %w[Authorization proxy-authorization COOKIE Set-Cookie x-api-key Api-Key X-Auth-Token].each do |n|
      Gori::Redact.sensitive_header?(n).should be_true
    end
    Gori::Redact.sensitive_header?(" Cookie ").should be_true
  end

  it "leaves every other header alone" do
    %w[Host Accept Content-Type X-Api-Keys Cookie2].each do |n|
      Gori::Redact.sensitive_header?(n).should be_false
    end
  end
end

describe "Gori::Redact.redacted_value" do
  it "withholds a credential header's whole value" do
    Gori::Redact.redacted_value("Authorization", "Bearer abc.def").should eq("[REDACTED]")
    Gori::Redact.redacted_value("Cookie", "sid=1; theme=dark").should eq("[REDACTED]")
  end

  it "keeps a Set-Cookie's name and attributes, never its value" do
    Gori::Redact.redacted_value("set-cookie", "session=9f2c; Path=/; Secure; HttpOnly; SameSite=Lax")
      .should eq("session=[REDACTED]; Path=/; Secure; HttpOnly; SameSite=Lax")
    Gori::Redact.redacted_value("Set-Cookie", "tracking_id=u-51; Max-Age=31536000; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
      .should eq("tracking_id=[REDACTED]; Max-Age=31536000; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
    Gori::Redact.redacted_value("Set-Cookie", "opaque").should eq("[REDACTED]")
  end

  it "redacts a segment that is not a known attribute, and a comma-folded second cookie" do
    out = Gori::Redact.redacted_value("Set-Cookie", "a=1; Path=/, b=secret2; HttpOnly; x-note=tok")
    out.should eq("a=[REDACTED]; Path=[REDACTED]; HttpOnly; [REDACTED]")
    out.should_not contain("secret2")
    out.should_not contain("tok")
  end
end
