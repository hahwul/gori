require "../spec_helper"

# `Gori::Export::GoHttp` — the request→Go `net/http` serializer behind the TUI's "Copy as → Go"
# row and `gori run show <id> --format go`.

private def go(wire : String, target : String) : String
  Gori::Export::GoHttp.text(wire, target).not_nil!
end

describe Gori::Export::GoHttp do
  it "emits a GET program with no body reader and only fmt/io/net/http imported" do
    code = go("GET /a HTTP/1.1\r\nHost: h.test\r\nAccept: */*\r\n\r\n", "https://h.test")
    code.should contain(%(http.NewRequest("GET", "https://h.test/a", nil)))
    code.should contain(%(req.Header.Add("Accept", "*/*")))
    code.should_not contain("strings")
    code.should_not contain("bytes")
  end

  it "emits a text body via strings.NewReader and imports strings" do
    code = go("POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n{\"a\":1}", "https://h.test")
    code.should contain(%("strings"))
    code.should contain(%(body := strings.NewReader("{\\"a\\":1}")))
    code.should contain(%(http.NewRequest("POST", "https://h.test/api", body)))
  end

  it "emits a binary body via bytes.NewReader([]byte{…}) and imports bytes" do
    io = IO::Memory.new
    io << "POST /u HTTP/1.1\r\nHost: h.test\r\n\r\n"
    io.write(Bytes[0xff_u8, 0x00_u8])
    code = go(String.new(io.to_slice), "https://h.test")
    code.should contain(%("bytes"))
    code.should contain("bytes.NewReader([]byte{0xff, 0x00})")
  end

  it "sets a mismatched Host via req.Host (net/http ignores a Host header entry)" do
    code = go("GET / HTTP/1.1\r\nHost: evil.test\r\n\r\n", "https://h.test")
    code.should contain(%(req.Host = "evil.test"))
    code.should_not contain("req.Header.Add(\"Host\"")
  end
  # net/http escapes `URL.Path` on its way to the request line but writes `RawQuery` VERBATIM,
  # so a captured `/한?q=한` went out with the path encoded and the query's high bytes raw — a
  # request-target no other generated client sends. Pre-encoding settles it: measured against a
  # raw listener, curl / httpie / requests / fetch / net-http all send `GET /%ED%95%9C?q=%ED%95%9C`.
  it "percent-encodes a non-ASCII path and query" do
    code = go("GET /\u{d55c}?q=\u{d55c} HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
    code.should contain(%(http.NewRequest("GET", "https://h.test/%ED%95%9C?q=%ED%95%9C", nil)))
  end

  it "leaves a non-ASCII authority alone — a host is IDNA-encoded, not percent-encoded" do
    code = go("GET /a HTTP/1.1\r\nHost: \u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}\r\n\r\n",
      "https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}")
    code.should contain(%("https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}/a"))
  end
end
