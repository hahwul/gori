require "../spec_helper"

private alias M = Gori::Miner

private def req(s : String) : Bytes
  s.to_slice
end

private def text(bytes : Bytes) : String
  String.new(bytes)
end

describe Gori::Miner::Inject do
  it "appends a query param when there is no query string" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Query, [{"p", "v"}])
    text(res).should start_with("GET /a?p=v HTTP/1.1\r\n")
  end

  it "appends with & when a query already exists" do
    res = M::Inject.apply(req("GET /a?x=1 HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Query, [{"p", "v"}])
    text(res).should start_with("GET /a?x=1&p=v HTTP/1.1\r\n")
  end

  it "url-encodes names and values in the query" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Query, [{"a b", "c&d"}])
    text(res).should contain("a+b=c%26d")
  end

  it "appends to a form body and re-syncs Content-Length" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nx=1"
    res = M::Inject.apply(req(base), M::Location::Form, [{"p", "v"}], add_cl_when_missing: false)
    t = text(res)
    t.should contain("\r\n\r\nx=1&p=v")
    t.should contain("Content-Length: 7")
  end

  it "merges keys into a JSON object body" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    t = text(res)
    t.should contain(%("p":"v"))
    t.should contain(%("a":1))
  end

  it "leaves a non-object JSON root unchanged" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 5\r\n\r\n[1,2]"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    text(res).should eq(base)
  end

  it "adds header lines before the blank line" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Headers, [{"X-Test", "1"}])
    text(res).should eq("GET /a HTTP/1.1\r\nHost: h\r\nX-Test: 1\r\n\r\n")
  end

  it "rejects forbidden/invalid header names" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Headers,
      [{"Host", "evil"}, {"bad name", "x"}, {"Content-Length", "9"}])
    text(res).should eq("GET /a HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "extends an existing Cookie header" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\nCookie: s=1\r\n\r\n"), M::Location::Cookies, [{"p", "v"}])
    text(res).should contain("Cookie: s=1; p=v")
  end

  it "adds a Cookie header when none exists" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Cookies, [{"p", "v"}])
    text(res).should contain("Cookie: p=v")
  end

  it "strips CR/LF from injected header values (smuggling guard)" do
    res = M::Inject.apply(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Headers, [{"X-Test", "a\r\nEvil: 1"}])
    text(res).should eq("GET /a HTTP/1.1\r\nHost: h\r\nX-Test: aEvil: 1\r\n\r\n")
  end
end

describe Gori::Miner::Detect do
  it "offers json only for a JSON object body" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
    appl = M::Detect.detect(req(base))
    appl.applicable.should contain(M::Location::Json)
    appl.default.should contain(M::Location::Json)
    appl.default.should_not contain(M::Location::Headers)
  end

  it "offers form for a urlencoded body and not json" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nx=1"
    appl = M::Detect.detect(req(base))
    appl.applicable.should contain(M::Location::Form)
    appl.applicable.should_not contain(M::Location::Json)
  end

  it "offers only query/cookies/headers for a bodyless GET" do
    appl = M::Detect.detect(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"))
    appl.applicable.should eq([M::Location::Query, M::Location::Headers, M::Location::Cookies])
    appl.default.should eq([M::Location::Query, M::Location::Cookies])
  end
end
