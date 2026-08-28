require "./spec_helper"

describe Gori::Cvss do
  it "resolves CVSS v3.1 vector string" do
    res = Gori::Cvss.resolve("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    res.should_not be_nil
    score, sev, canonical = res.not_nil!
    score.should eq(9.8)
    sev.should eq(Gori::Store::Severity::Critical)
    canonical.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
  end

  it "resolves CVSS v4.0 vector string" do
    res = Gori::Cvss.resolve("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N")
    res.should_not be_nil
    score, sev, canonical = res.not_nil!
    score.should eq(9.3)
    sev.should eq(Gori::Store::Severity::Critical)
    canonical.should start_with("CVSS:4.0/")
  end

  it "resolves CVSS v2.0 vector string" do
    res = Gori::Cvss.resolve("AV:N/AC:L/Au:N/C:P/I:P/A:P")
    res.should_not be_nil
    score, sev, canonical = res.not_nil!
    score.should eq(7.5)
    sev.should eq(Gori::Store::Severity::High)
  end

  it "resolves numeric scores across severity bands" do
    Gori::Cvss.severity_for("0.0").should eq(Gori::Store::Severity::Info)
    Gori::Cvss.severity_for("0").should eq(Gori::Store::Severity::Info)
    Gori::Cvss.severity_for("3.5").should eq(Gori::Store::Severity::Low)
    Gori::Cvss.severity_for("5.5").should eq(Gori::Store::Severity::Medium)
    Gori::Cvss.severity_for("7.5").should eq(Gori::Store::Severity::High)
    Gori::Cvss.severity_for("9.8").should eq(Gori::Store::Severity::Critical)
    Gori::Cvss.severity_for("10.0").should eq(Gori::Store::Severity::Critical)
  end

  it "resolves lowercase CVSS vector string into canonical uppercase vector" do
    res = Gori::Cvss.resolve("cvss:3.1/av:n/ac:l/pr:n/ui:n/s:u/c:h/i:h/a:h")
    res.should_not be_nil
    score, sev, canonical = res.not_nil!
    score.should eq(9.8)
    sev.should eq(Gori::Store::Severity::Critical)
    canonical.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
  end

  it "returns nil for empty or invalid input" do
    Gori::Cvss.resolve("").should be_nil
    Gori::Cvss.resolve("   ").should be_nil
    Gori::Cvss.resolve("garbage").should be_nil
    Gori::Cvss.resolve("-1.0").should be_nil
    Gori::Cvss.resolve("10.5").should be_nil
    Gori::Cvss.resolve("NaN").should be_nil
    Gori::Cvss.resolve("Infinity").should be_nil
    Gori::Cvss.resolve("-Infinity").should be_nil
  end
end
