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
end
