require "../spec_helper"

# `Gori::Export::PythonRequests` — the request→Python `requests` serializer behind the TUI's
# "Copy as → Python" row and `gori run show <id> --format python`. Surface-neutral, the same
# shape as `Export::Curl`; these specs pin the escaping and the header/body drop decisions.

private def py(wire : String, target : String) : String
  Gori::Export::PythonRequests.text(wire, target).not_nil!
end

describe Gori::Export::PythonRequests do
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
end
