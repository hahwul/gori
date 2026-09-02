require "../spec_helper"

# `Gori::Export::PythonRequests` — the request→Python `requests` serializer behind the TUI's
# "Copy as → Python" row and `gori run show <id> --format python`. Surface-neutral, the same
# shape as `Export::Curl`; these specs pin the escaping and the header/body drop decisions.

private def py(wire : String, target : String) : String
  Gori::Export::PythonRequests.text(wire, target).not_nil!
end

describe Gori::Export::PythonRequests do
  # requests takes the URL as TEXT and percent-encodes the str's UTF-8, so a `\xNN` per captured
  # byte was re-encoded: measured against a raw listener, `/안` went out as
  # `/%C3%AC%C2%95%C2%88` while curl, Go and httpie all sent `/%EC%95%88` — a different resource
  # than the capture's, from four surfaces that must agree.
  it "percent-encodes a non-ASCII URL so requests cannot re-encode it" do
    code = py("GET /\u{c548} HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
    code.should contain(%(url = "https://h.test/%EC%95%88"))
  end

  # The headers stay byte-wise: requests encodes a header str latin-1, so one code unit is one
  # byte on the wire — measured correct, and the reason the URL is the only field that moved.
  it "keeps a non-ASCII header value byte-wise" do
    code = py("GET /a HTTP/1.1\r\nHost: h.test\r\nX-K: \u{c548}\r\n\r\n", "https://h.test")
    code.should contain(%("X-K": "\\xec\\x95\\x88",))
  end

  it "emits a runnable GET with the resolved URL and no body" do
    code = py("GET /search?q=1 HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
    code.should contain("import requests")
    code.should contain(%(url = "https://h.test/search?q=1"))
    code.should contain(%q{requests.request("GET", url)})
    code.should_not contain("data =")
  end

  it "emits a JSON POST with the body as a bytes literal and the Content-Type kept" do
    code = py("POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n" \
              "Content-Length: 14\r\n\r\n{\"user\":\"neo\"}", "https://h.test")
    code.should contain(%("Content-Type": "application/json"))
    # The double quotes inside the JSON body are escaped; the body rides as `b"…"`.
    code.should contain(%(data = b"{\\"user\\":\\"neo\\"}"))
    code.should contain(%(requests.request("POST", url, headers=headers, data=data)))
  end

  it "drops Host (matches URL authority), Content-Length, and gori's h2 marker headers" do
    code = py("GET / HTTP/1.1\r\nHost: h.test\r\nContent-Length: 0\r\n" \
              "X-Gori-Trailers: te\r\nX-Gori-Pushed: 3\r\nX-Real: keep\r\n\r\n", "https://h.test")
    code.should_not contain("Host")
    code.should_not contain("Content-Length")
    code.should_not contain("X-Gori")
    code.should contain(%("X-Real": "keep"))
  end

  it "keeps a Host that disagrees with the URL (a Host-header test rides)" do
    code = py("GET / HTTP/1.1\r\nHost: evil.test\r\n\r\n", "https://h.test")
    code.should contain(%("Host": "evil.test"))
  end

  it "escapes a newline in a header value and a backslash, byte-losslessly" do
    # A value with a literal backslash and control byte survives as \\ and \xNN.
    code = py("GET / HTTP/1.1\r\nHost: h.test\r\nX-Odd: a\\b\tc\r\n\r\n", "https://h.test")
    code.should contain(%("X-Odd": "a\\\\b\\tc"))
  end

  it "notes a duplicate header name the dict cannot represent (last value wins)" do
    code = py("GET / HTTP/1.1\r\nHost: h.test\r\nX-Dup: a\r\nX-Dup: b\r\n\r\n", "https://h.test")
    code.should contain("# note: X-Dup appeared more than once")
    # Both still appear in the dict text (the reader sees them), and the note is honest that
    # requests will send only the last.
    code.should contain(%("X-Dup": "a",))
    code.should contain(%("X-Dup": "b",))
  end

  it "keeps a binary body byte-exact in the bytes literal" do
    io = IO::Memory.new
    io << "POST /u HTTP/1.1\r\nHost: h.test\r\n\r\n"
    io.write(Bytes[0xff_u8, 0x00_u8, 0x22_u8])
    code = py(String.new(io.to_slice), "https://h.test")
    code.should contain(%(data = b"\\xff\\x00\\""))
  end
  # The encoding stops at the authority. A host is IDNA-encoded, not percent-encoded, and
  # urllib3 does NOT decode one back: measured on the demo project's `https://쇼핑몰.한국/…`,
  # `urllib3.util.parse_url` answers `xn--352bl7khqr.xn--3e0b707e` for the raw URL and the
  # literal `%ec%87%bc%ed%95%91%eb%aa%b0.%ed%95%9c%ea%b5%ad` for the encoded one — a name no
  # resolver answers, so the script could not reach the captured host at all.
  it "leaves a non-ASCII authority raw so requests can IDNA-encode it" do
    code = py("GET /api/\u{c8fc}\u{bb38} HTTP/1.1\r\nHost: \u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}\r\n\r\n",
      "https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}")
    code.should contain(%(url = "https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}/api/%EC%A3%BC%EB%AC%B8"))
  end
end
