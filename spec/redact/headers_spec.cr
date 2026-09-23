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

  it "is the list MCP::Serialize redacts with" do
    Gori::MCP::Serialize::SENSITIVE_HEADERS.should eq(Gori::Redact::SENSITIVE_HEADERS)
  end
end
