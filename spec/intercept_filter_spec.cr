require "./spec_helper"

private def req(method = "GET", host = "acme.test", target = "/login", scheme = "http")
  Gori::InterceptFilter::Subject.new(method: method, host: host, target: target, scheme: scheme)
end

private def res(status : Int32, method = "GET", host = "acme.test", target = "/login", scheme = "http")
  Gori::InterceptFilter::Subject.new(method: method, host: host, target: target, scheme: scheme, status: status)
end

describe Gori::InterceptFilter do
  it "an empty filter matches everything" do
    f = Gori::InterceptFilter::EMPTY
    f.blank?.should be_true
    f.matches?(req).should be_true
    f.matches?(res(200)).should be_true
  end

  it "matches host as a substring (case-insensitive)" do
    f = Gori::InterceptFilter.new("host:ACME")
    f.matches?(req(host: "api.acme.test")).should be_true
    f.matches?(req(host: "evil.test")).should be_false
  end

  it "matches method exactly (case-insensitive)" do
    f = Gori::InterceptFilter.new("method:post")
    f.matches?(req(method: "POST")).should be_true
    f.matches?(req(method: "GET")).should be_false
  end

  it "matches path as a substring of the target" do
    f = Gori::InterceptFilter.new("path:/api")
    f.matches?(req(target: "/api/v1/users?id=1")).should be_true
    f.matches?(req(target: "/login")).should be_false
  end

  it "matches scheme exactly" do
    Gori::InterceptFilter.new("scheme:https").matches?(req(scheme: "https")).should be_true
    Gori::InterceptFilter.new("scheme:https").matches?(req(scheme: "http")).should be_false
  end

  it "status: only matches a response, never a request (request has no status)" do
    f = Gori::InterceptFilter.new("status:500")
    f.matches?(res(500)).should be_true
    f.matches?(res(404)).should be_false
    f.matches?(req).should be_false # a request can't satisfy a status term
  end

  it "supports status comparisons and classes" do
    Gori::InterceptFilter.new("status:>=500").matches?(res(503)).should be_true
    Gori::InterceptFilter.new("status:>=500").matches?(res(404)).should be_false
    Gori::InterceptFilter.new("status:5xx").matches?(res(500)).should be_true
    Gori::InterceptFilter.new("status:5xx").matches?(res(499)).should be_false
    Gori::InterceptFilter.new("status:<400").matches?(res(200)).should be_true
  end

  it "ANDs terms within a group, ORs across OR" do
    f = Gori::InterceptFilter.new("method:POST host:acme")
    f.matches?(req(method: "POST", host: "acme.test")).should be_true
    f.matches?(req(method: "POST", host: "other.test")).should be_false

    g = Gori::InterceptFilter.new("host:acme OR host:shop")
    g.matches?(req(host: "acme.test")).should be_true
    g.matches?(req(host: "shop.test")).should be_true
    g.matches?(req(host: "other.test")).should be_false
  end

  it "negates a term with a leading -" do
    f = Gori::InterceptFilter.new("-host:acme")
    f.matches?(req(host: "acme.test")).should be_false
    f.matches?(req(host: "evil.test")).should be_true
  end

  it "treats a bare word as free text over method/host/target" do
    f = Gori::InterceptFilter.new("login")
    f.matches?(req(target: "/login")).should be_true
    f.matches?(req(target: "/home")).should be_false
  end

  it "drops empty-valued terms (so `host:` while typing matches all)" do
    Gori::InterceptFilter.new("host:").blank?.should be_true
    Gori::InterceptFilter.new("host:").matches?(req).should be_true
  end
end
