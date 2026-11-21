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

describe "Gori::Redact.credential_start_line?" do
  it "recognizes a credential in place of the start line without mistaking a URL or a later header for one" do
    Gori::Redact.credential_start_line?(" cOoKiE : sid=value\r\n".to_slice).should be_true
    Gori::Redact.credential_start_line?("Cookie http://h/path HTTP/1.1\r\n".to_slice).should be_false
    Gori::Redact.credential_start_line?("GET / HTTP/1.1\nAuthorization: Bearer token".to_slice).should be_false
  end
end

describe "Gori::Redact.redact_head" do
  it "reports a withheld field even when its captured value already looks redacted" do
    head = "X-Public: visible\r\n Authorization: [REDACTED]\r\n\r\n"
    Gori::Redact.redact_head_with_status(head, false).should eq({head, true})
    Gori::Redact.redact_head_with_status(head, true).should eq({head, false})
  end

  it "withholds incomplete Set-Cookie attributes when the displayed head is capped" do
    head = "Set-Cookie: sid=value; Path=/, second"
    Gori::Redact.redact_head(head, truncated: true).should eq("Set-Cookie: [REDACTED]")
    Gori::Redact.redact_head(head, include_sensitive: true, truncated: true).should eq(head)
  end
end
