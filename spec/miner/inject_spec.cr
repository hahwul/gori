require "../spec_helper"

private alias M = Gori::Miner

private def req(s : String) : Bytes
  s.to_slice
end

private def text(bytes : Bytes) : String
  String.new(bytes)
end

# True when `needle` appears as a contiguous byte subsequence of `hay` (for asserting a binary
# part survived injection byte-exact — String matching would mangle non-UTF-8 bytes).
private def subseq?(hay : Bytes, needle : Bytes) : Bool
  return true if needle.empty?
  return false if needle.size > hay.size
  (0..hay.size - needle.size).any? { |i| hay[i, needle.size] == needle }
end

# The body (bytes after the first blank line) of a request.
private def body_of(bytes : Bytes) : Bytes
  s = text(bytes)
  i = s.index("\r\n\r\n")
  i ? bytes[i + 4, bytes.size - (i + 4)] : Bytes.empty
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

  # Regression for a CLI-only bug: `--locations=form` forced onto a request with no existing
  # urlencoded-form body used to splice a bare body on with no Content-Length AND no
  # Content-Type header at all — a framing-broken request the tool reported as "0 errors".
  # inject_form must be a no-op (like inject_multipart/inject_json already are) when Form
  # isn't applicable, matching Detect's own applicability test.
  it "does not inject into a bodyless request (no framing-broken body)" do
    base = "GET /a HTTP/1.1\r\nHost: h\r\n\r\n"
    res = M::Inject.apply(req(base), M::Location::Form, [{"p", "v"}], add_cl_when_missing: false)
    text(res).should eq(base)
  end

  it "does not inject form params into a body whose Content-Type isn't urlencoded" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
    res = M::Inject.apply(req(base), M::Location::Form, [{"p", "v"}], add_cl_when_missing: false)
    text(res).should eq(base)
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

  it "injects a candidate key into a NESTED JSON object as well as the root" do
    # Parse the result and assert BOTH nodes carry the key — a `contain(%("p":"v"))` check would
    # pass even if nested injection were broken, because the root always gets the key.
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"data\":{\"a\":1}}"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    parsed = JSON.parse(text(body_of(res)))
    parsed.as_h.has_key?("p").should be_true         # root object
    parsed["data"].as_h.has_key?("p").should be_true # nested object
    parsed["data"]["p"].as_s.should eq("v")
  end

  it "injects into each object element of a JSON array root" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n[{\"a\":1},{\"b\":2}]"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    parsed = JSON.parse(text(body_of(res))).as_a
    parsed.size.should eq(2)
    parsed.all? { |e| e.as_h.has_key?("p") }.should be_true
  end

  it "leaves an array of scalars unchanged (no object node)" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n[1,2,3]"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    text(res).should eq(base)
  end

  it "leaves a scalar JSON root unchanged" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 3\r\n\r\n\"x\""
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    text(res).should eq(base)
  end

  it "caps JSON injection at MAX_JSON_NODES object nodes (BFS shallow-first)" do
    cap = M::Inject::MAX_JSON_NODES
    elems = Array.new(cap + 8) { |i| %({"i":#{i}}) }.join(',')
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n\r\n[#{elems}]"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "v"}])
    parsed = JSON.parse(text(body_of(res))).as_a
    parsed.count { |e| e.as_h.has_key?("p") }.should eq(cap)
  end

  it "splices a field into an existing multipart body before the close delimiter" do
    body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    res = M::Inject.apply(req(base), M::Location::Multipart, [{"p", "v"}])
    expected = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" \
               "--B\r\nContent-Disposition: form-data; name=\"p\"\r\n\r\nv\r\n" \
               "--B--\r\n"
    text(body_of(res)).should eq(expected)
    text(res).should contain("Content-Length: #{expected.bytesize}")
  end

  it "preserves an epilogue after the multipart close delimiter" do
    body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\nEPILOGUE"
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    res = M::Inject.apply(req(base), M::Location::Multipart, [{"p", "v"}])
    nb = text(body_of(res))
    nb.should contain(%(name="p"))
    nb.should end_with("--B--\r\nEPILOGUE")
    nb.index(%(name="p")).not_nil!.should be < nb.index("--B--").not_nil!
  end

  it "preserves a binary file part byte-exact" do
    marker = Bytes[0xff_u8, 0xfe_u8, 0x00_u8, 0x10_u8]
    b = IO::Memory.new
    b << "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"
    b.write(marker)
    b << "\r\n--B--\r\n"
    body = b.to_slice
    base = IO::Memory.new
    base << "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.size}\r\n\r\n"
    base.write(body)
    res = M::Inject.apply(base.to_slice, M::Location::Multipart, [{"p", "v"}])
    subseq?(res, marker).should be_true
    text(res).scrub.should contain(%(name="p"))
  end

  it "synthesises a well-formed multipart body when the original is empty" do
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: 0\r\n\r\n"
    res = M::Inject.apply(req(base), M::Location::Multipart, [{"p", "v"}])
    expected = "--B\r\nContent-Disposition: form-data; name=\"p\"\r\n\r\nv\r\n--B--\r\n"
    text(body_of(res)).should eq(expected)
    text(res).should contain("Content-Length: #{expected.bytesize}")
  end

  it "appends a close delimiter when the multipart body has none" do
    body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n"
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    res = M::Inject.apply(req(base), M::Location::Multipart, [{"p", "v"}])
    nb = text(body_of(res))
    nb.should contain(%(name="a"))
    nb.should contain(%(name="p"))
    nb.should end_with("--B--\r\n")
  end

  it "does not inject multipart when the Content-Type has no boundary" do
    body = "raw-body-without-boundary"
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    res = M::Inject.apply(req(base), M::Location::Multipart, [{"p", "v"}])
    text(res).should_not contain(%(name="p"))
  end

  it "rejects invalid multipart field names" do
    body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    res = M::Inject.apply(req(base), M::Location::Multipart,
      [{"ok", "v"}, {"bad\"", "v"}, {"bad;", "v"}, {"a\r\nb", "v"}, {"", "v"}])
    nb = text(body_of(res))
    nb.should contain(%(name="ok"))
    nb.should_not contain("bad")
    nb.scan(/Content-Disposition/).size.should eq(2) # original `a` + injected `ok`
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
    appl.default.should eq([M::Location::Query])
  end

  it "offers multipart (applicable, default OFF) for a multipart/form-data body" do
    body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    appl = M::Detect.detect(req(base))
    appl.applicable.should contain(M::Location::Multipart)
    appl.default.should_not contain(M::Location::Multipart)
    appl.applicable.should_not contain(M::Location::Form)
    appl.applicable.should_not contain(M::Location::Json)
  end

  it "does not offer multipart without an extractable boundary" do
    base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data\r\nContent-Length: 3\r\n\r\nabc"
    M::Detect.detect(req(base)).applicable.should_not contain(M::Location::Multipart)
  end

  it "offers json for a JSON array-of-objects body" do
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 9\r\n\r\n[{\"a\":1}]"
    M::Detect.detect(req(base)).applicable.should contain(M::Location::Json)
  end

  it "does not offer json for an array of scalars or a scalar root" do
    scalars = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n[1,2,3]"
    M::Detect.detect(req(scalars)).applicable.should_not contain(M::Location::Json)
    scalar = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 3\r\n\r\n\"x\""
    M::Detect.detect(req(scalar)).applicable.should_not contain(M::Location::Json)
  end
end
