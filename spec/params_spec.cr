require "./spec_helper"

private alias L = Gori::Miner::Location

private def params_of(head : String, body : (String | Bytes)? = nil, all_headers = false) : Array({L, String, String})
  b = case body
      when String then body.to_slice
      else             body
      end
  out = [] of {L, String, String}
  Gori::Params.each(head.to_slice, b, all_headers) { |p| out << {p.loc, p.name, p.value} }
  out
end

describe Gori::Params do
  it "reads query pairs, URL-decoded, keeping a valueless flag and dropping a nameless pair" do
    ps = params_of("GET /s?q=a%20b&v%2Fx=1&debug&=nokey HTTP/1.1\r\nHost: h\r\n\r\n")
    ps.should eq([{L::Query, "q", "a b"}, {L::Query, "v/x", "1"}, {L::Query, "debug", ""}])
  end

  it "reads an urlencoded form body, and not a JSON body as a form" do
    body = "user=jay&role=admin"
    ps = params_of("POST /f HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n", body)
    ps.should eq([{L::Form, "user", "jay"}, {L::Form, "role", "admin"}])
  end

  it "reads multipart fields, with a file part carried as a note and never as its content" do
    body = "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhi there\r\n" \
           "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\n\r\nSECRETBYTES\r\n--B--\r\n"
    got = [] of Gori::Params::Param
    Gori::Params.each("POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n".to_slice,
      body.to_slice) { |p| got << p }
    got.map { |p| {p.loc, p.name, p.value} }.should eq([{L::Multipart, "note", "hi there"}, {L::Multipart, "f", ""}])
    got[1].note.not_nil!.should contain("x.bin")
    got[1].note.not_nil!.should_not contain("SECRETBYTES")
  end

  # Only a part's HEADER names a field: a part whose CONTENT is a pasted request carries its
  # own Content-Disposition line, and reading that would invent an `admin` input. A part with
  # no name at all is not an input either (FormData labels it "(unnamed)" for its own pane).
  it "reads multipart names from part headers only, and skips a nameless part" do
    body = "--B\r\nContent-Disposition: form-data; name=\"report\"\r\n\r\n" \
           "here is the request I captured:\r\n" \
           "Content-Disposition: form-data; name=\"admin\"\r\n" \
           "\r\n--B\r\nContent-Disposition: form-data\r\n\r\nanon\r\n--B--\r\n"
    ps = params_of("POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n", body)
    ps.map(&.[1]).should eq(["report"])
  end

  it "walks JSON to every scalar leaf, collapsing array indices to []" do
    body = %({"user":{"email":"a@b.c","age":30},"items":[{"id":1},{"id":2}],"tags":["x"],"ok":true,"n":null})
    ps = params_of("POST /j HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n\r\n", body)
    ps.should eq([
      {L::Json, "user.email", "a@b.c"}, {L::Json, "user.age", "30"},
      {L::Json, "items[].id", "1"}, {L::Json, "items[].id", "2"},
      {L::Json, "tags[]", "x"}, {L::Json, "ok", "true"}, {L::Json, "n", "null"},
    ])
  end

  it "bracket-quotes a key that would read as path syntax, and reads a root array" do
    ps = params_of("POST /j HTTP/1.1\r\nContent-Type: application/json\r\n\r\n", %([{"a.b":{"c":"v"}}]))
    ps.should eq([{L::Json, %([]["a.b"].c), "v"}])
  end

  # The literal text, never converted: `JSON.parse` raises on an integer past Int64, and one
  # such field elsewhere in the body must not cost the whole document.
  it "reads a number past Int64 as its text" do
    ps = params_of("POST /j HTTP/1.1\r\nContent-Type: application/json\r\n\r\n",
      %({"big":123456789012345678901234567890,"f":1.0e2}))
    ps.should eq([{L::Json, "big", "123456789012345678901234567890"}, {L::Json, "f", "1.0e2"}])
  end

  it "yields nothing for a JSON-typed body that is not JSON" do
    params_of("POST /j HTTP/1.1\r\nContent-Type: application/json\r\n\r\n", "not json").should be_empty
  end

  it "bounds a deep JSON nest instead of recursing through it" do
    deep = "[" * 200 + "1" + "]" * 200
    params_of("POST /j HTTP/1.1\r\nContent-Type: application/json\r\n\r\n", deep).should be_empty
  end

  it "skips standard headers by default, and reads them all on request" do
    head = "GET / HTTP/1.1\r\nHost: h\r\nUser-Agent: ua\r\nSec-Fetch-Mode: cors\r\nAccept-Language: en\r\n" \
           "X-Api-Key: k1\r\nX-Tenant: acme\r\n\r\n"
    params_of(head).should eq([{L::Headers, "x-api-key", "k1"}, {L::Headers, "x-tenant", "acme"}])
    params_of(head, all_headers: true).map(&.[1]).should eq(
      ["host", "user-agent", "sec-fetch-mode", "accept-language", "x-api-key", "x-tenant"])
  end

  it "splits the Cookie header into crumbs, names verbatim" do
    ps = params_of("GET / HTTP/1.1\r\nHost: h\r\nCookie: sid=abc; Theme=dark; flag\r\n\r\n")
    ps.should eq([{L::Cookies, "sid", "abc"}, {L::Cookies, "Theme", "dark"}])
  end

  # An obs-fold continuation carries VALUE bytes before its first colon; reading it as a header
  # would invent an input named after part of the previous header's value.
  it "does not read an obs-fold continuation line as a header" do
    ps = params_of("GET / HTTP/1.1\r\nHost: h\r\nX-Note: a\r\n redirect=https://x/\r\n\r\n")
    ps.should eq([{L::Headers, "x-note", "a"}])
  end

  it "still reads the head and body behind a malformed request line" do
    ps = params_of("GET /a b?q=1 HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nX-Id: 7\r\n\r\n",
      %({"k":"v"}))
    ps.should eq([{L::Json, "k", "v"}, {L::Headers, "x-id", "7"}])
  end

  it "reads a gzip'd JSON body through its entity" do
    io = IO::Memory.new
    Compress::Gzip::Writer.open(io) { |gz| gz << %({"k":"v"}) }
    ps = params_of("POST /j HTTP/1.1\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n\r\n", io.to_slice)
    ps.should eq([{L::Json, "k", "v"}])
  end

  it "survives invalid UTF-8 in a value" do
    body = Bytes[0x6b, 0x3d, 0xff, 0xfe] # k=\xff\xfe
    ps = params_of("POST /f HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n", body)
    ps.map(&.[1]).should eq(["k"])
  end

  describe ".json_leaf" do
    it "names the member a Miner Json injection would write" do
      Gori::Params.json_leaf("user.email").should eq("email")
      Gori::Params.json_leaf("items[].id").should eq("id")
      Gori::Params.json_leaf("q").should eq("q")
      Gori::Params.json_leaf(%(a["b.c"])).should eq("b.c")
      Gori::Params.json_leaf("tags[]").should be_nil
    end
  end
end
