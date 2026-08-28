require "./spec_helper"
require "../src/gori/issues_query"

include Gori

private def fnd(title : String, severity : Store::Severity, status : Store::Status = Store::Status::Open,
                host : String? = nil) : Store::Issue
  Store::Issue.new(1_i64, 0_i64, 0_i64, title, severity, host, nil, "", status)
end

private def filtered(query : String, list : Array(Store::Issue)) : Array(Store::Issue)
  Issues::Filter.parse(query).apply(list)
end

describe Gori::Issues::Filter do
  list = [
    fnd("Reflected XSS in search", Store::Severity::High, Store::Status::Open, "app.example.com"),
    fnd("SQL injection in login", Store::Severity::Critical, Store::Status::Confirmed, "api.example.com"),
    fnd("Verbose error page", Store::Severity::Low, Store::Status::Resolved, "app.example.com"),
    fnd("Missing security header", Store::Severity::Info, Store::Status::FalsePositive, "cdn.example.net"),
  ]

  it "passes everything for an empty query" do
    filtered("", list).size.should eq(4)
    Issues::Filter.parse("").empty?.should be_true
  end

  it "filters by exact triage status" do
    filtered("status:open", list).map(&.title).should eq(["Reflected XSS in search"])
    filtered("st:confirmed", list).size.should eq(1)
    filtered("status:fp", list).size.should eq(1)
  end

  it "treats status:closed as any non-open state" do
    filtered("status:closed", list).map(&.severity)
      .should eq([Store::Severity::Critical, Store::Severity::Low, Store::Severity::Info])
  end

  it "compares severity ordinally" do
    filtered("sev:>=high", list).map(&.title).should eq(["Reflected XSS in search", "SQL injection in login"])
    filtered("severity:critical", list).size.should eq(1)
    filtered("sev:<medium", list).size.should eq(2) # low + info
    filtered("sev:crit", list).size.should eq(1)    # abbreviation
  end

  it "matches host and title substrings, case-insensitively" do
    filtered("host:api", list).size.should eq(1)
    filtered("title:XSS", list).size.should eq(1)
    filtered("example.com", list).size.should eq(3) # free text over host; the .net row is excluded
  end

  it "negates a field term with a leading -" do
    filtered("-status:open", list).size.should eq(3)
    filtered("-host:example.com", list).map(&.host).should eq(["cdn.example.net"])
  end

  it "ANDs multiple terms" do
    filtered("status:open sev:>=high", list).size.should eq(1)
    filtered("host:example.com severity:critical", list).map(&.title).should eq(["SQL injection in login"])
  end

  it "falls back to free text for an unknown field" do
    filtered("login", list).size.should eq(1)
    filtered("nope:zzz", list).size.should eq(0)
  end

  it "matches all for an empty field value (incremental typing), respecting negation" do
    filtered("status:", list).size.should eq(4) # mid-type — don't blank the list
    filtered("sev:>=", list).size.should eq(4)
    filtered("host:", list).size.should eq(4)
    filtered("-status:", list).size.should eq(0) # negated empty → match none
  end

  cvss_list = [
    Store::Issue.new(1_i64, 0_i64, 0_i64, "Crit Issue", Store::Severity::Critical, "api.test", nil, "", Store::Status::Open, "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"),
    Store::Issue.new(2_i64, 0_i64, 0_i64, "High Issue", Store::Severity::High, "app.test", nil, "", Store::Status::Open, "7.5"),
    Store::Issue.new(3_i64, 0_i64, 0_i64, "Med Issue", Store::Severity::Medium, "app.test", nil, "", Store::Status::Open, "5.0"),
    Store::Issue.new(4_i64, 0_i64, 0_i64, "No CVSS", Store::Severity::Low, "cdn.test", nil, "", Store::Status::Open, nil),
  ]

  it "filters by CVSS numeric comparisons" do
    filtered("cvss:>=7.0", cvss_list).map(&.title).should eq(["Crit Issue", "High Issue"])
    filtered("cvss:>9.0", cvss_list).map(&.title).should eq(["Crit Issue"])
    filtered("cvss:<=5.0", cvss_list).map(&.title).should eq(["Med Issue"])
    filtered("cvss:<5.0", cvss_list).should be_empty
  end

  it "matches CVSS vector substring or exact score" do
    filtered("cvss:3.1", cvss_list).map(&.title).should eq(["Crit Issue"])
    filtered("cvss:7.5", cvss_list).map(&.title).should eq(["High Issue"])
  end

  it "supports negative CVSS filters" do
    filtered("-cvss:>=7.0", cvss_list).map(&.title).should eq(["Med Issue", "No CVSS"])
  end
end
