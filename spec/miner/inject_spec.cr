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

# The bytes the returned spans actually cover, concatenated — the exact text a send seam would
# copy through verbatim (and NOT scan for a `$NAME`). Slices the FINAL bytes at each span, so a
# wrong offset (e.g. an unshifted Content-Length trap) shows up as the wrong text here.
private def covered(bytes : Bytes, spans : Array({Int32, Int32})) : String
  String.build { |s| spans.each { |(a, b)| s.write(bytes[a, b - a]) } }
end

# {request, body} for `{"q":"hi","bin":"<bin>"}` posted as application/json — the shape the
# JSON-location byte-safety examples below mine. Built through an IO because the body is NOT
# valid UTF-8 and must not pass through a String literal.
private def binary_json_request(bin : Bytes) : {Bytes, Bytes}
  b = IO::Memory.new
  b << %({"q":"hi","bin":")
  b.write(bin)
  b << %("})
  body = b.to_slice
  base = IO::Memory.new
  base << "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n" \
          "Content-Length: #{body.size}\r\n\r\n"
  base.write(body)
  {base.to_slice, body}
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

  # ── Json location over a body that is not valid UTF-8 ────────────────────────────────
  #
  # A captured `application/json` body may legitimately carry bytes that are not valid UTF-8
  # (a latin-1 field, a blob a lax server accepts inside a string). The Json location reached
  # `inject_json_text` through `String.new(body).scrub`, so the miner SENT three bytes of
  # U+FFFD for each of them — measured `ff fe 01 02` → `ef bf bd ef bf bd 01 02`, four captured
  # bytes becoming eight, under a Content-Length gori then re-synced to the corrupted size. The
  # Form location on the same shape was already byte-exact and is the control below.
  # Byte-wise assertions throughout: `String#includes?` would mangle the very bytes under test.

  it "keeps a non-UTF-8 JSON body byte-exact through the Json location" do
    bin = Bytes[0xff_u8, 0xfe_u8, 0x01_u8, 0x02_u8]
    request, body = binary_json_request(bin)
    res = M::Inject.apply(request, M::Location::Json, [{"p", "vCANARY"}])
    subseq?(res, bin).should be_true
    # No U+FFFD anywhere: that byte triple is what the scrub used to substitute.
    subseq?(res, Bytes[0xef_u8, 0xbf_u8, 0xbd_u8]).should be_false
    # Every byte after the `{` the pair was spliced behind survives contiguously.
    subseq?(res, body[1, body.size - 1]).should be_true
    subseq?(res, %("p":"vCANARY").to_slice).should be_true
    subseq?(res, "Content-Length: #{body.size + %("p":"vCANARY",).bytesize}".to_slice).should be_true
  end

  it "keeps a non-UTF-8 urlencoded body byte-exact through the Form location (the control)" do
    bin = Bytes[0xff_u8, 0xfe_u8, 0x01_u8, 0x02_u8]
    b = IO::Memory.new
    b << "q=hi&bin="
    b.write(bin)
    body = b.to_slice
    base = IO::Memory.new
    base << "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\n" \
            "Content-Length: #{body.size}\r\n\r\n"
    base.write(body)
    res = M::Inject.apply(base.to_slice, M::Location::Form, [{"p", "vCANARY"}])
    subseq?(res, body).should be_true
    subseq?(res, Bytes[0xef_u8, 0xbf_u8, 0xbd_u8]).should be_false
  end

  it "records the injected span in FINAL offsets on the byte-splice road" do
    bin = Bytes[0xff_u8, 0xfe_u8, 0x01_u8, 0x02_u8]
    request, _ = binary_json_request(bin)
    bytes, spans = M::Inject.apply_with_spans(request, M::Location::Json, [{"pMINE", "vCANARY"}])
    covered(bytes, spans).should eq(%("pMINE":"vCANARY"))
  end

  it "reports 0 injectable JSON nodes for a body that is not valid UTF-8" do
    # This is the gate Detect asks. It used to scrub before parsing, so for bytes whose
    # SCRUBBED form still parses it answered "yes, N nodes" about a body it had just rewritten
    # — which is how Json came to be auto-selected for traffic the miner could only corrupt.
    b = IO::Memory.new
    b << %({"q":"hi","bin":")
    b.write(Bytes[0xff_u8, 0xfe_u8, 0x41_u8, 0x42_u8]) # scrubs to a body that DOES parse
    b << %("})
    M::Inject.json_object_node_count(b.to_slice, M::Inject::MAX_JSON_NODES).should eq(0)
    M::Inject.json_object_node_count(%({"a":1}).to_slice, M::Inject::MAX_JSON_NODES).should eq(1)
  end

  it "keeps a valid-UTF-8 JSON body (Korean + emoji) mining exactly as before" do
    body = %({"q":"안녕","e":"🐙","n":{"deep":1}})
    base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n" \
           "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    res = M::Inject.apply(req(base), M::Location::Json, [{"p", "vCANARY"}])
    parsed = JSON.parse(text(body_of(res)))
    parsed["q"].as_s.should eq("안녕")
    parsed["e"].as_s.should eq("🐙")
    parsed.as_h.has_key?("p").should be_true      # root object
    parsed["n"].as_h.has_key?("p").should be_true # nested object, i.e. the PARSE road
    M::Inject.json_object_node_count(body.to_slice, M::Inject::MAX_JSON_NODES).should eq(2)
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

  # `apply_with_spans` must return the byte ranges of the INJECTED name/value in the FINAL
  # bytes so a send seam marks them verbatim (mirrors Fuzz::Job#payload_spans). If the spans
  # were wrong the covered text would not equal the injected content, and a `$NAME` in a
  # wordlist term would expand to a live session credential on the wire. Seed bytes must never
  # be covered. The Content-Length-syncing locations (form/json/multipart) deliberately cross a
  # digit boundary so the span-shift-across-sync path is exercised.
  describe "#apply_with_spans span coverage" do
    it "query: spans cover exactly the injected pair, seed excluded" do
      bytes, spans = M::Inject.apply_with_spans(
        req("GET /a?seedq=SEEDVAL HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Query, [{"pMINE", "vCANARY"}])
      spans.should_not be_empty
      covered(bytes, spans).should eq("pMINE=vCANARY")
    end

    it "form: spans cover the injected pair after Content-Length resync (digit shift)" do
      # body "x=1" (CL 3) → +"&pMINE=vCANARY" → CL "17": the 1→2 digit growth shifts every
      # body offset by one, which the span must follow.
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nx=1"
      bytes, spans = M::Inject.apply_with_spans(req(base), M::Location::Form, [{"pMINE", "vCANARY"}], add_cl_when_missing: false)
      text(bytes).should contain("Content-Length: 17")
      covered(bytes, spans).should eq("pMINE=vCANARY")
    end

    it "json: spans cover the injected key/value after reserialize + resync" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 9\r\n\r\n{\"a\":\"1\"}"
      bytes, spans = M::Inject.apply_with_spans(req(base), M::Location::Json, [{"pMINE", "vCANARY"}])
      spans.should_not be_empty
      covered(bytes, spans).should eq("\"pMINE\":\"vCANARY\"")
      cov = covered(bytes, spans)
      cov.should_not contain("\"a\"")
    end

    it "json: an injected key hitting every object node yields one span per node" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n{\"a\":{\"b\":1},\"c\":2}"
      bytes, spans = M::Inject.apply_with_spans(req(base), M::Location::Json, [{"pMINE", "vCANARY"}])
      spans.size.should eq(2) # root object + nested {"b":1}
      spans.each { |(a, b)| String.new(bytes[a, b - a]).should eq("\"pMINE\":\"vCANARY\"") }
    end

    it "multipart: spans cover the injected part (name and value), seed part excluded" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=BB\r\nContent-Length: 40\r\n\r\n--BB\r\nContent-Disposition: form-data; name=\"seedm\"\r\n\r\nSEEDVAL\r\n--BB--\r\n"
      bytes, spans = M::Inject.apply_with_spans(req(base), M::Location::Multipart, [{"pMINE", "vCANARY"}])
      spans.should_not be_empty
      cov = covered(bytes, spans)
      cov.should contain("name=\"pMINE\"")
      cov.should contain("vCANARY")
      cov.should_not contain("seedm")
      cov.should_not contain("SEEDVAL")
    end

    it "headers: spans cover the injected header line, not the seed head" do
      bytes, spans = M::Inject.apply_with_spans(
        req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Headers, [{"X-Mine", "vCANARY"}])
      covered(bytes, spans).should eq("X-Mine: vCANARY")
    end

    it "headers: one span per injected header, filtered names produce none" do
      bytes, spans = M::Inject.apply_with_spans(
        req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Headers,
        [{"X-One", "1"}, {"Content-Length", "9"}, {"X-Two", "2"}]) # CL is a forbidden name → dropped
      spans.size.should eq(2)
      covered(bytes, spans).should eq("X-One: 1X-Two: 2")
    end

    it "cookies: spans cover the appended cookie on an existing Cookie header" do
      bytes, spans = M::Inject.apply_with_spans(
        req("GET /a HTTP/1.1\r\nHost: h\r\nCookie: s=1\r\n\r\n"), M::Location::Cookies, [{"pMINE", "vCANARY"}])
      covered(bytes, spans).should eq("pMINE=vCANARY")
      text(bytes).should contain("Cookie: s=1; pMINE=vCANARY") # byte-exact, unchanged from before
    end

    it "cookies: spans cover a freshly added Cookie header's value" do
      bytes, spans = M::Inject.apply_with_spans(
        req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Cookies, [{"pMINE", "vCANARY"}])
      covered(bytes, spans).should eq("pMINE=vCANARY")
    end

    it "returns no spans when nothing is injected" do
      bytes, spans = M::Inject.apply_with_spans(
        req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n"), M::Location::Query, [] of {String, String})
      spans.should be_empty
    end
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

  it "does NOT offer json for an application/json body that is not valid UTF-8" do
    # `JSON::Any` cannot hold those bytes, so the location genuinely does not apply. Saying so
    # here is what makes `gori run mine` name it skipped (warn_mine_locations) for an operator
    # who asks for it with --locations, instead of the miner scrubbing the capture and sweeping
    # a request the operator never wrote.
    request, _ = binary_json_request(Bytes[0xff_u8, 0xfe_u8, 0x41_u8, 0x42_u8])
    appl = M::Detect.detect(request)
    appl.applicable.should_not contain(M::Location::Json)
    appl.default.should_not contain(M::Location::Json)
    appl.applicable.should contain(M::Location::Query)
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
