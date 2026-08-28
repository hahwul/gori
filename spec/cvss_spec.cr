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

  # The two enums have the same five bands with one member renamed, and the mapping used to
  # ride on their ordinals lining up. Assert the pairs, not the numbers.
  it "maps every CVSS rating onto a store severity" do
    Gori::Cvss.severity_of(::CVSS::Severity::None).should eq(Gori::Store::Severity::Info)
    Gori::Cvss.severity_of(::CVSS::Severity::Low).should eq(Gori::Store::Severity::Low)
    Gori::Cvss.severity_of(::CVSS::Severity::Medium).should eq(Gori::Store::Severity::Medium)
    Gori::Cvss.severity_of(::CVSS::Severity::High).should eq(Gori::Store::Severity::High)
    Gori::Cvss.severity_of(::CVSS::Severity::Critical).should eq(Gori::Store::Severity::Critical)
  end

  # `valid?` is the gate every write path asks before storing an operator's or an agent's
  # cvss — blank is NOT valid here, because "clear it" is its own intent the caller spells.
  it "answers valid? for anything it can score, and for nothing else" do
    Gori::Cvss.valid?("9.8").should be_true
    Gori::Cvss.valid?("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H").should be_true
    Gori::Cvss.valid?("cvss:3.1/av:n/ac:l/pr:n/ui:n/s:u/c:h/i:h/a:h").should be_true
    Gori::Cvss.valid?("").should be_false
    Gori::Cvss.valid?("  ").should be_false
    Gori::Cvss.valid?("high").should be_false
    Gori::Cvss.valid?("11").should be_false
    Gori::Cvss.valid?("CVSS:3.1/AV:X").should be_false
  end

  it "reports the parsed vector's version, and nothing for a bare score" do
    Gori::Cvss.parse("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H").try(&.version).should eq("3.1")
    Gori::Cvss.parse("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N").try(&.version).should eq("4.0")
    Gori::Cvss.parse("9.8").should be_nil
    Gori::Cvss.parse("").should be_nil
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
