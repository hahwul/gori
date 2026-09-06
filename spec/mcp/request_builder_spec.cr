require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::RequestBuilder do
  # `normalize_raw` exists so a hand-typed request still frames, but a bare-LF header
  # terminator is a standard front-end/back-end desync primitive — promoting it removed a
  # whole payload class from this surface while the TUI's byte modes could always send it.
  it "promotes a bare LF in the head by default" do
    raw = "GET /v HTTP/1.1\r\nHost: h.test\nX-B: lf\n\r\n"
    args = JSON.parse({"url" => "http://h.test/", "raw" => raw}.to_json).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes)
      .should eq("GET /v HTTP/1.1\r\nHost: h.test\r\nX-B: lf\r\n\r\n")
  end

  # An `as_h?`-only read answered nil for every non-object shape and the caller skipped the
  # loop, so the request went out with ZERO caller headers and still reported success —
  # discover_start echoes no request at all, so an authenticated crawl could run
  # unauthenticated with no signal anywhere. Accept the shapes an agent actually sends.
  it "accepts a stringified headers object" do
    args = JSON.parse({"url" => "http://h.test/x", "headers" => %({"Authorization":"Bearer T"})}.to_json).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should contain("Authorization: Bearer T\r\n")
  end

  it "accepts headers as an array of [name, value] pairs" do
    args = JSON.parse({"url" => "http://h.test/x", "headers" => [["Authorization", "Bearer T"]]}.to_json).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should contain("Authorization: Bearer T\r\n")
  end

  # BEHAVIOUR CHANGE, pinned deliberately: an unusable `headers` must RAISE, never vanish.
  # Silently dropping it is what made the bug invisible on both surfaces.
  it "raises rather than silently dropping an unusable headers value" do
    ["not-json-at-all", "42"].each do |bad|
      args = JSON.parse({"url" => "http://h.test/x", "headers" => bad}.to_json).as_h
      expect_raises(Gori::Error, /headers/) { Gori::MCP::RequestBuilder.build(args) }
    end
    args = JSON.parse({"url" => "http://h.test/x", "headers" => [["only-one"]]}.to_json).as_h
    expect_raises(Gori::Error, /headers/) { Gori::MCP::RequestBuilder.build(args) }
  end

  it "still treats an absent headers key as no headers" do
    args = JSON.parse({"url" => "http://h.test/x"}.to_json).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should eq("GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n")
  end

  it "keeps the bare LF byte-exact under verbatim" do
    raw = "GET /v HTTP/1.1\r\nHost: h.test\nX-B: lf\n\r\n"
    args = JSON.parse({"url" => "http://h.test/", "raw" => raw, "verbatim" => true}.to_json).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should eq(raw)
  end

  it "leaves a $VAR unexpanded under verbatim, for Plan.build to refuse" do
    raw = "GET /v HTTP/1.1\r\nHost: h.test\r\nX-T: $NOPE\r\n\r\n"
    args = JSON.parse({"url" => "http://h.test/", "raw" => raw, "verbatim" => true}.to_json).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should contain("$NOPE")
  end

  it "builds exact request bytes with Host + Content-Length" do
    args = JSON.parse(%({"url":"https://h.test:8443/a?b=1","method":"post","headers":{"X-Test":"y"},"body":"hi"})).as_h
    built = Gori::MCP::RequestBuilder.build(args)
    built.scheme.should eq("https")
    built.host.should eq("h.test")
    built.port.should eq(8443)
    String.new(built.bytes).should eq("POST /a?b=1 HTTP/1.1\r\nX-Test: y\r\nHost: h.test:8443\r\nContent-Length: 2\r\n\r\nhi")
  end

  it "omits the port from Host when it is the scheme default" do
    args = JSON.parse(%({"url":"http://h.test/"})).as_h
    built = Gori::MCP::RequestBuilder.build(args)
    built.port.should eq(80)
    String.new(built.bytes).should eq("GET / HTTP/1.1\r\nHost: h.test\r\n\r\n")
  end

  it "defaults an empty path to /" do
    args = JSON.parse(%({"url":"https://h.test"})).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should start_with("GET / HTTP/1.1\r\n")
  end

  it "passes a raw request through, normalising the header block's LFs to CRLF" do
    raw = "GET /x HTTP/1.1\nHost: h.test\n\n" # real LFs, as a JSON-parsed raw value carries
    args = {"url" => JSON::Any.new("http://h.test/"), "raw" => JSON::Any.new(raw)}
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should eq("GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n")
  end

  it "keeps the raw body byte-exact (bare LFs in the body are NOT rewritten)" do
    raw = "POST /x HTTP/1.1\nContent-Length: 5\n\na\nb\nc" # body 'a\nb\nc' = 5 bytes
    args = {"url" => JSON::Any.new("http://h.test/"), "raw" => JSON::Any.new(raw)}
    out = String.new(Gori::MCP::RequestBuilder.build(args).bytes)
    out.should eq("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\na\nb\nc") # head CRLF, body LFs intact
  end

  it "raises when the url has no host" do
    args = JSON.parse(%({"url":"/relative"})).as_h
    expect_raises(Gori::Error) { Gori::MCP::RequestBuilder.build(args) }
  end

  # JSON-RPC arguments are UTF-8 text, so `raw`/`body` reach the socket as their UTF-8
  # ENCODING: `é` went out as `\xc3\xa9` and a raw 0x00/0x80-0xFF byte was unreachable from
  # this surface entirely (with isError:false and an echo of the intended text, so the caller
  # never learned). base64 is the byte route.
  describe "base64 byte input" do
    it "puts the exact octets of raw_base64 on the wire" do
      wire = Bytes[0x47, 0x45, 0x54, 0x20, 0x2f, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31,
        0x0d, 0x0a, 0x58, 0x2d, 0x42, 0x3a, 0x20, 0x00, 0x80, 0xfe, 0xff, 0x0d, 0x0a, 0x0d, 0x0a]
      args = JSON.parse({"url" => "http://h.test/", "raw_base64" => Base64.strict_encode(wire)}.to_json).as_h
      Gori::MCP::RequestBuilder.build(args).bytes.should eq(wire)
    end

    it "does NOT promote a bare LF or expand a $VAR in raw_base64 (base64 IS verbatim)" do
      wire = "GET /v HTTP/1.1\nX-T: $NOPE\n\n".to_slice
      args = JSON.parse({"url" => "http://h.test/", "raw_base64" => Base64.strict_encode(wire)}.to_json).as_h
      Gori::MCP::RequestBuilder.build(args).bytes.should eq(wire)
      Gori::MCP::RequestBuilder.verbatim?(args).should be_true
    end

    it "sends body_base64 byte-exact with a matching Content-Length" do
      body = Bytes[0x00, 0x80, 0xff, 0xed, 0xa0, 0x80] # NUL, high bytes, a lone surrogate's UTF-8
      args = JSON.parse({"url" => "http://h.test/p", "method" => "POST",
                         "body_base64" => Base64.strict_encode(body)}.to_json).as_h
      built = Gori::MCP::RequestBuilder.build(args).bytes
      String.new(built).should start_with("POST /p HTTP/1.1\r\nHost: h.test\r\nContent-Length: 6\r\n\r\n")
      built[(built.size - 6)..].should eq(body)
    end

    it "prefers raw_base64 over raw and body_base64 over body" do
      args = JSON.parse({"url" => "http://h.test/", "raw" => "GET /text HTTP/1.1\r\n\r\n",
                         "raw_base64" => Base64.strict_encode("GET /bytes HTTP/1.1\r\n\r\n".to_slice)}.to_json).as_h
      String.new(Gori::MCP::RequestBuilder.build(args).bytes).should eq("GET /bytes HTTP/1.1\r\n\r\n")

      args = JSON.parse({"url" => "http://h.test/", "method" => "POST", "body" => "text",
                         "body_base64" => Base64.strict_encode("bytes".to_slice)}.to_json).as_h
      String.new(Gori::MCP::RequestBuilder.build(args).bytes).should end_with("\r\n\r\nbytes")
    end

    it "refuses invalid base64 instead of quietly sending different bytes" do
      args = JSON.parse(%({"url":"http://h.test/","raw_base64":"!!!not base64!!!"})).as_h
      expect_raises(Gori::Error, /raw_base64.*not valid base64/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "treats an empty/absent base64 argument as absent (the text route still works)" do
      args = JSON.parse(%({"url":"http://h.test/","raw_base64":"","raw":"GET /t HTTP/1.1\\r\\n\\r\\n"})).as_h
      String.new(Gori::MCP::RequestBuilder.build(args).bytes).should eq("GET /t HTTP/1.1\r\n\r\n")
      Gori::MCP::RequestBuilder.verbatim?(args).should be_false
    end
  end

  it "raises a clean Gori::Error (not a leaked URI::Error) for a malformed authority" do
    args = JSON.parse(%({"url":"https://h.test:abc/"})).as_h
    expect_raises(Gori::Error, /invalid url/) { Gori::MCP::RequestBuilder.build(args) }
  end

  it "rejects an out-of-range port instead of dialing a doomed connect" do
    args = JSON.parse(%({"url":"https://h.test:99999/"})).as_h
    expect_raises(Gori::Error, /invalid port/) { Gori::MCP::RequestBuilder.build(args) }
  end

  describe "structured-path injection guards" do
    it "rejects CR/LF in a header value (header injection)" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"X-Inj" => JSON::Any.new("a\r\nX-Evil: 1")})}
      expect_raises(Gori::Error, /header.*X-Inj/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a bare LF in a header value (lenient origins split on LF)" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"X-LF" => JSON::Any.new("a\nX-Evil: 1")})}
      expect_raises(Gori::Error) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects CR/LF in a header name" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"X-A\r\nX-S" => JSON::Any.new("1")})}
      expect_raises(Gori::Error, /header name/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects an empty header name" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"" => JSON::Any.new("v")})}
      expect_raises(Gori::Error, /empty/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a non-token char (':') in a header name (would emit a 2nd Content-Length)" do
      # "Content-Length:0" evades the case-insensitive dedup and is written as
      # `Content-Length:0: x` next to the auto Content-Length — two conflicting lines.
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "method"  => JSON::Any.new("POST"),
              "body"    => JSON::Any.new("hi"),
              "headers" => JSON::Any.new({"Content-Length:0" => JSON::Any.new("x")})}
      expect_raises(Gori::Error, /header name/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects whitespace/CRLF in the method (request-line forgery)" do
      args = {"url"    => JSON::Any.new("http://h.test/"),
              "method" => JSON::Any.new("GET /admin HTTP/1.1\r\nHost: a")}
      expect_raises(Gori::Error, /method/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a bare space in the request target (request-line forgery)" do
      # URI.parse keeps the literal space in the path; emitting it would forge
      # `GET /a b HTTP/1.1` — a lenient origin then reads target /a, version b.
      args = {"url" => JSON::Any.new("http://h.test/a b")}
      expect_raises(Gori::Error, /request target/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a whitespace-padded header name (framing-dedup evasion)" do
      # A leading space dodges the case-insensitive Content-Length dedup, so the
      # auto length would be appended too — two conflicting lengths on the wire.
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "method"  => JSON::Any.new("POST"),
              "body"    => JSON::Any.new("abc"),
              "headers" => JSON::Any.new({" Content-Length" => JSON::Any.new("0")})}
      expect_raises(Gori::Error, /header name/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "still allows a custom method and internal spaces in a header VALUE" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "method"  => JSON::Any.new("propfind"),
              "headers" => JSON::Any.new({"X-Note" => JSON::Any.new("hello world ok")})}
      out = String.new(Gori::MCP::RequestBuilder.build(args).bytes)
      out.should start_with("PROPFIND / HTTP/1.1\r\n")
      out.should contain("X-Note: hello world ok\r\n")
    end

    it "rejects a URL whose host carries a CR/LF (auto Host-header injection)" do
      # URI.parse keeps the CR/LF as part of the authority's host; left unchecked
      # it would be written verbatim into the generated Host header.
      args = {"url" => JSON::Any.new("http://h.com\r\nEvil:3/path")}
      expect_raises(Gori::Error, /host/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "leaves the raw path byte-exact (smuggling is the caller's explicit choice)" do
      raw = "GET /x HTTP/1.1\nX-Inj: a\r\nX-Evil: 1\n\n"
      args = {"url" => JSON::Any.new("http://h.test/"), "raw" => JSON::Any.new(raw)}
      # raw mode does NOT validate — it is byte-exact by contract.
      Gori::MCP::RequestBuilder.build(args).should_not be_nil
    end
  end
end
