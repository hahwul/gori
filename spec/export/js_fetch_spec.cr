require "../spec_helper"

# `Gori::Export::JsFetch` — the request→`fetch()` serializer behind the TUI's "Copy as → fetch"
# row and `gori run show <id> --format fetch`.

private def js(wire : String, target : String) : String
  Gori::Export::JsFetch.text(wire, target).not_nil!
end

describe Gori::Export::JsFetch do
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
end
