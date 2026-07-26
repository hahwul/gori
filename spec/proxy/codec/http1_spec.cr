require "../../spec_helper"

include Gori::Proxy::Codec

private def bytes(str : String) : Bytes
  str.to_slice
end

describe Gori::Proxy::Codec::Http1 do
  describe ".parse_request_head" do
    it "parses request-line and headers as projections" do
      raw = bytes("GET /search?q=test HTTP/1.1\r\nHost: acme.test\r\nAccept: */*\r\n\r\n")
      req = Http1.parse_request_head(raw)

      req.method.should eq("GET")
      req.target.should eq("/search?q=test")
      req.version.should eq("HTTP/1.1")
      req.host?.should eq("acme.test")
      req.headers.get?("accept").should eq("*/*") # case-insensitive lookup
      req.malformed?.should be_false
    end

    it "preserves byte-exact raw_head (P7) so serialize == original" do
      raw = bytes("POST /api HTTP/1.1\r\nHost: x\r\nX-Weird:  spaced  \r\nContent-Length: 0\r\n\r\n")
      req = Http1.parse_request_head(raw)

      req.raw_head.should eq(raw)
      Http1.serialize_head(req).should eq(raw)
    end

    it "preserves header order and original casing in the projection" do
      raw = bytes("GET / HTTP/1.1\r\nHost: a\r\nX-Foo: 1\r\nx-foo: 2\r\n\r\n")
      req = Http1.parse_request_head(raw)

      names = req.headers.entries.map(&.name)
      names.should eq(["Host", "X-Foo", "x-foo"])
      req.headers.get_all("X-Foo").should eq(["1", "2"]) # both, wire order
      req.headers.get?("x-foo").should eq("2")           # last wins
    end

    it "captures-not-rejects a malformed request-line (P7)" do
      raw = bytes("GET\r\nHost: a\r\n\r\n") # only one token on the start line
      req = Http1.parse_request_head(raw)

      req.malformed?.should be_true
      req.raw_head.should eq(raw) # truth preserved regardless
    end

    it "exposes the verbatim request-line via #request_line for a mis-sliced line (R1-4)" do
      raw = bytes("GET /a b HTTP/1.1\r\nHost: a\r\n\r\n") # unencoded space => 4 tokens
      req = Http1.parse_request_head(raw)

      req.malformed?.should be_true
      req.target.should eq("/a") # split(' ') mis-slices target/version
      req.version.should eq("b")
      req.request_line.should eq("GET /a b HTTP/1.1")                                                    # honest whole line, trailing CR stripped
      Http1.parse_request_head(bytes("GET / HTTP/1.1\r\n\r\n")).request_line.should eq("GET / HTTP/1.1") # common path
    end

    it "flags the RFC 7540 h2 client preface as malformed despite its well-formed 3-token shape" do
      # "PRI * HTTP/2.0" splits into exactly 3 tokens like a normal request-line, so the
      # generic `parts.size != 3` rule alone would accept it. This is the exact literal an
      # h2/gRPC client sends first — forced onto this HTTP/1.1 parser by the deliberate
      # ALPN downgrade while Intercept/Sandbox/Match&Replace is active (Tunnel#intercept) —
      # and must be recognized so the caller can reject the connection instead of treating
      # it as a real "PRI *" request.
      raw = bytes("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      req = Http1.parse_request_head(raw)

      req.method.should eq("PRI")
      req.target.should eq("*")
      req.version.should eq("HTTP/2.0")
      req.malformed?.should be_true
      Http1.h2_preface?(req).should be_true
    end

    it "does not flag an ordinary request as the h2 preface" do
      raw = bytes("GET / HTTP/2.0\r\nHost: a\r\n\r\n")
      req = Http1.parse_request_head(raw)

      req.malformed?.should be_false
      Http1.h2_preface?(req).should be_false
    end
  end

  describe ".parse_request_line" do
    it "mirrors parse_request_head's malformed verdict for the h2 preface" do
      raw = bytes("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      method, target, malformed = Http1.parse_request_line(raw)

      method.should eq("PRI")
      target.should eq("*")
      malformed.should be_true
    end
  end

  describe ".parse_response_head" do
    it "parses status-line and headers" do
      raw = bytes("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\n")
      resp = Http1.parse_response_head(raw)

      resp.version.should eq("HTTP/1.1")
      resp.status.should eq(404)
      resp.reason.should eq("Not Found")
      resp.headers.get?("content-length").should eq("9")
      resp.malformed?.should be_false
    end

    it "handles an empty reason phrase" do
      raw = bytes("HTTP/1.1 204 \r\n\r\n")
      resp = Http1.parse_response_head(raw)
      resp.status.should eq(204)
      resp.reason.should eq("")
    end
  end

  describe ".read_head" do
    it "reads exactly up to and including CRLFCRLF, leaving the body unread" do
      io = IO::Memory.new("GET / HTTP/1.1\r\nHost: a\r\n\r\nBODYBYTES")
      head = Http1.read_head(io).not_nil!

      String.new(head).should eq("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
      io.gets_to_end.should eq("BODYBYTES") # nothing over-read
    end

    it "returns nil on clean EOF" do
      Http1.read_head(IO::Memory.new("")).should be_nil
    end
  end

  # The rule for text gori SYNTHESIZES into a request line. Its callers are the ones that build
  # a request out of something a remote chose: `Fuzz::Engine`'s redirect follower (#397) and
  # `MCP::RequestBuilder`'s method / target / host / header-name checks.
  describe ".request_token_safe?" do
    it "accepts an ordinary request target, including the punctuation a URL needs" do
      Http1.request_token_safe?("/a/b?x=1&y=2#f").should be_true
      Http1.request_token_safe?("*").should be_true
      Http1.request_token_safe?("http://host:8080/p%20q").should be_true
      Http1.request_token_safe?("GET").should be_true
    end

    it "rejects every octet that can break a request line into more tokens" do
      # SP and TAB forge the line (`GET /a b HTTP/1.1` reads as target `/a`, version `b`);
      # CR and LF splice a second request onto the connection; NUL and DEL are the remaining
      # members of the same class and are never legal here either.
      {" ", "\t", "\r", "\n", "\0", "\u007F"}.each do |c|
        Http1.request_token_safe?("/a#{c}b").should be_false
        Http1.request_token_safe?("/a#{c}").should be_false
        Http1.request_token_safe?("#{c}/a").should be_false
      end
    end

    it "accepts an empty string" do
      # Emptiness is the caller's business (MCP raises its own "must not be empty" first);
      # this predicate answers only "does it contain a line-breaking octet".
      Http1.request_token_safe?("").should be_true
    end

    it "does not reject a non-ASCII target for being non-ASCII" do
      # Every octet of a multi-byte UTF-8 sequence is >= 0x80, so none of them can trip the
      # <= 0x20 test. Deliberately NOT claimed here: that a byte-wise scan and a char-wise one
      # differ. They do not — 0x00-0x20 and 0x7F can never appear as UTF-8 continuation octets,
      # so the two agree on every input, valid or invalid. The byte-wise form is preferred for
      # being decode-free, not for a behaviour difference, and no example can pin that choice.
      Http1.request_token_safe?("/검색?q=값").should be_true
      Http1.request_token_safe?("/검색 ?q=값").should be_false
    end
  end
end
