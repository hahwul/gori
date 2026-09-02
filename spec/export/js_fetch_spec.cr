require "../spec_helper"

# `Gori::Export::JsFetch` — the request→`fetch()` serializer behind the TUI's "Copy as → fetch"
# row and `gori run show <id> --format fetch`.

private def js(wire : String, target : String) : String
  Gori::Export::JsFetch.text(wire, target).not_nil!
end

describe Gori::Export::JsFetch do
  # A `\xNN` per UTF-8 byte is one code unit each, and fetch encodes each of those to two bytes:
  # measured against a raw listener, a 6-byte Korean body went out as 12 bytes under a matching
  # Content-Length, so the endpoint received bytes the capture never sent.
  it "writes a non-ASCII body as characters, not as one \\xNN per UTF-8 byte" do
    code = js("POST /a HTTP/1.1\r\nHost: h.test\r\nContent-Type: text/plain\r\n\r\n\u{c548}\u{b155}", "https://h.test")
    code.should contain(%(body: "\u{c548}\u{b155}",))
    code.should_not contain("\\xec")
  end

  # The URL is text the JS URL parser percent-encodes from the STRING's UTF-8, the same trap one
  # field over: `/안` as three code units was fetched as `/%C3%AC%C2%95%C2%88`.
  it "percent-encodes a non-ASCII URL so the URL parser cannot re-encode it" do
    code = js("GET /\u{c548} HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
    code.should contain("fetch(\"https://h.test/%EC%95%88\", {")
  end

  # A `Headers` value IS a byte sequence — fetch puts each code unit on the wire as one byte — so
  # the byte-wise escape is right here and must not follow the body/URL.
  it "keeps a non-ASCII header value byte-wise" do
    code = js("GET /a HTTP/1.1\r\nHost: h.test\r\nX-K: \u{c548}\r\n\r\n", "https://h.test")
    code.should contain(%("X-K": "\\xec\\x95\\x88",))
  end

  it "emits a GET with method and no body" do
    code = js("GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
    code.should contain("fetch(\"https://h.test/a\", {")
    code.should contain(%(method: "GET",))
    code.should_not contain("body:")
  end

  it "emits a JSON POST with the body as a UTF-8 string and Content-Type kept" do
    code = js("POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n{\"a\":1}", "https://h.test")
    code.should contain(%("Content-Type": "application/json",))
    code.should contain(%(body: "{\\"a\\":1}",))
  end

  it "drops Content-Length and gori's h2 marker headers" do
    code = js("POST / HTTP/1.1\r\nHost: h.test\r\nContent-Length: 3\r\nX-Gori-Protocol: websocket\r\n\r\nabc", "https://h.test")
    code.should_not contain("Content-Length")
    code.should_not contain("X-Gori")
  end

  it "uses the array-of-pairs headers form to preserve a duplicate header name" do
    code = js("GET / HTTP/1.1\r\nHost: h.test\r\nX-Dup: a\r\nX-Dup: b\r\n\r\n", "https://h.test")
    # Not an object literal (which would collapse the duplicate) — an array of [name, value].
    code.should contain("headers: [")
    code.should contain(%(["X-Dup", "a"],))
    code.should contain(%(["X-Dup", "b"],))
  end

  it "sends a non-UTF-8 body as a Uint8Array (a string body would re-encode a high byte)" do
    io = IO::Memory.new
    io << "POST /u HTTP/1.1\r\nHost: h.test\r\n\r\n"
    io.write(Bytes[0xff_u8, 0xfe_u8, 0x41_u8])
    code = js(String.new(io.to_slice), "https://h.test")
    code.should contain("body: new Uint8Array([255, 254, 65]),")
    code.should contain("not valid UTF-8")
  end
  # `body` on a GET/HEAD is not ignored — the Request constructor THROWS, so the snippet sent
  # nothing at all. Measured on Node 26: `fetch(u, {method:"GET", body:"b"})` rejects with
  # `TypeError: Request with GET/HEAD method cannot have body.` A captured GET-with-a-body is a
  # real shape (curl reproduces it with -X GET --data-raw), so name the drop and stay runnable.
  describe "a GET or HEAD carrying a body" do
    it "omits the body and says why" do
      code = js("GET /g HTTP/1.1\r\nHost: h.test\r\nContent-Length: 9\r\n\r\nbody-here", "https://h.test")
      code.should_not contain("body: ")
      code.should contain("body omitted")
      code.should contain("GET/HEAD method cannot have body")
      code.should contain("--format curl")
    end

    it "covers HEAD and a lowercase method fetch would upcase" do
      js("HEAD /g HTTP/1.1\r\nHost: h.test\r\n\r\nb", "https://h.test").should contain("body omitted")
      js("get /g HTTP/1.1\r\nHost: h.test\r\n\r\nb", "https://h.test").should contain("body omitted")
    end

    it "still sends a POST body" do
      js("POST /g HTTP/1.1\r\nHost: h.test\r\n\r\nb", "https://h.test").should contain(%(body: "b",))
    end
  end

  it "leaves a non-ASCII authority alone — a host is IDNA-encoded, not percent-encoded" do
    code = js("GET /a HTTP/1.1\r\nHost: \u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}\r\n\r\n",
      "https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}")
    code.should contain("fetch(\"https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}/a\", {")
  end
end
