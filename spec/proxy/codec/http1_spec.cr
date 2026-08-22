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

  # The non-HTTP detector (#729). ONE signal: a binary first byte. Everything a tchar can start
  # is HTTP as far as this predicate goes — the malformed-request-line payloads below are the
  # reason (P7), and getting any of them wrong closes the connection on the operator's own test.
  describe ".looks_like_http_request?" do
    it "accepts complete HTTP requests and the h2 preface" do
      ["GET / HTTP/1.1\r\nHost: a\r\n\r\n", "POST /x HTTP/1.0\r\n\r\n",
       "CONNECT h:443 HTTP/1.1\r\n\r\n", "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
       "PROPFIND /dav HTTP/1.1\r\n"].each do |raw|
        Http1.looks_like_http_request?(bytes(raw)).should be_true
      end
    end

    # These are DELIBERATE payloads (version fuzzing, parser differentials, HTTP/0.9), and
    # `parse_request_head` keeps every one verbatim. The detector must not refuse them — an
    # earlier draft did, and closed the connection blaming `network.tls_passthrough`.
    it "accepts a malformed or unusual request line rather than calling it non-HTTP (P7)" do
      ["GET /x HTTP/1.10\r\n\r\n",                    # two-digit minor — version fuzzing
       "GET /x http/1.1\r\n\r\n",                     # lowercase version token
       "GET /index.html\r\n\r\n",                     # HTTP/0.9, two tokens, no version at all
       "GET\r\nHost: a\r\n\r\n",                      # single-token start line (specced elsewhere as malformed-but-kept)
       "GET  /a  HTTP/1.1\r\n\r\n",                   # doubled spaces
       "GET\t/a HTTP/1.1\r\n\r\n",                    # tab instead of space
       "GET /a b HTTP/1.1\r\n\r\n",                   # unencoded space in the target (R1-4)
       "GET / HTTP/1.1 \r\n\r\n",                     # trailing space after the version
       "\r\nGET / HTTP/1.1\r\n\r\n",                  # leading empty line (RFC 7230 §3.5)
       " GET /admin HTTP/1.1\r\n\r\n",                # leading SP — whitespace-before-request-line
       "\tGET /admin HTTP/1.1\r\n\r\n"].each do |raw| # leading HTAB, same probe
        Http1.looks_like_http_request?(bytes(raw)).should be_true
      end
    end

    it "treats an empty or still-arriving first line as undecided (true)" do
      Http1.looks_like_http_request?(Bytes.new(0)).should be_true            # nothing yet
      Http1.looks_like_http_request?(bytes("GET / HTTP/1.1")).should be_true # no CRLF yet
      Http1.looks_like_http_request?(bytes("GE")).should be_true             # first byte is a token char
      Http1.looks_like_http_request?(bytes("\r\n")).should be_true           # only a blank line so far
    end

    it "rejects a binary preface on the first byte" do
      Http1.looks_like_http_request?(Bytes[0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51]).should be_false # MQTT CONNECT
      Http1.looks_like_http_request?(Bytes[0x16, 0x03, 0x01, 0x00]).should be_false             # TLS ClientHello
      Http1.looks_like_http_request?(Bytes[0x00, 0x01, 0x02]).should be_false                   # AMQP / NUL
      Http1.looks_like_http_request?(Bytes[0x0d, 0x0a, 0x10, 0x0c]).should be_false             # after a blank line
    end

    # The stated gap: a TEXT banner is indistinguishable from a malformed request line on the
    # first line, so gori does not guess. SSH/SMTP through the HTTP port still wait out the head
    # deadline, exactly as before #729 — pinned so a future "improvement" has to argue with P7.
    it "does NOT try to classify a text banner (SSH/SMTP) — the known gap" do
      Http1.looks_like_http_request?(bytes("SSH-2.0-OpenSSH_9.6\r\n")).should be_true
      Http1.looks_like_http_request?(bytes("EHLO mail.example.com\r\n")).should be_true
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

  describe ".gate_target" do
    # The target the SCOPE gate reads. `parse_request_head`'s strict `split(' ')` must stay
    # strict (it feeds resolve_forward/rewrite_request_line, whose `version` is parts[2]), so
    # the leniency lives here — and ONLY here. See `Http1.gate_target`.

    it "returns the parsed target unchanged for a well-formed request line" do
      req = Http1.parse_request_head(bytes("GET /admin?q=1 HTTP/1.1\r\nHost: h\r\n\r\n"))
      req.malformed?.should be_false
      Http1.gate_target(req).should eq("/admin?q=1")
      # Same object identity as the parse: the common path allocates nothing new (P6).
      Http1.gate_target(req).should be(req.target)
    end

    it "recovers the target a DOUBLED SPACE hid from the strict parse" do
      # `split(' ')` yields ["GET", "", "/admin", "HTTP/1.1"] — size 4, so `malformed?`, and
      # `parts[1]?` is the EMPTY string. The gate then evaluated `http://host`, missing an
      # `exclude string:/admin` that an origin collapsing the whitespace still honours.
      req = Http1.parse_request_head(bytes("GET  /admin HTTP/1.1\r\nHost: h\r\n\r\n"))
      req.target.should eq("") # the strict parse is unchanged...
      req.malformed?.should be_true
      Http1.gate_target(req).should eq("/admin") # ...and the gate no longer reads it
    end

    it "recovers the target a TAB hid, which the strict parse turned into garbage" do
      # Nastier than the empty case: ["GET\t/admin", "HTTP/1.1"] makes `parts[1]?` the
      # VERSION, so the gate evaluated `http://hostHTTP/1.1` — a string a `string:` rule can
      # match in ways nobody intended, in either direction.
      req = Http1.parse_request_head(bytes("GET\t/admin HTTP/1.1\r\nHost: h\r\n\r\n"))
      req.target.should eq("HTTP/1.1")
      Http1.gate_target(req).should eq("/admin")
    end

    it "reads past LEADING BLANK LINES rather than gating an innocuous \"/\"" do
      # RFC 9112 §2.2 tells a recipient to ignore an empty line before the request-line, so the
      # real target reaches the origin while the first line the strict parse read was "".
      req = Http1.parse_request_head(bytes("\r\n\r\nGET /admin HTTP/1.1\r\nHost: h\r\n\r\n"))
      req.target.should eq("")
      Http1.gate_target(req).should eq("/admin")
    end

    it "degrades to \"/\" when the request line carries no target at all" do
      # Pinned, not incidental: `""` would make the scope URL `http://host` and `"/"` makes it
      # `http://host/`, which is a different answer for an anchored regex rule. `"/"` is the
      # value `Outbound.request_target` has always returned, and the two must not disagree.
      Http1.gate_target(Http1.parse_request_head(bytes("GET\r\nHost: h\r\n\r\n"))).should eq("/")
      Http1.gate_target(Http1.parse_request_head(bytes("\r\n\r\n"))).should eq("/")
    end

    it "answers identically to Outbound.request_target on every shape" do
      # One predicate, one home: `Outbound.request_target` delegates here, so an active send
      # (fuzz/mine/repeater) and the proxy gate can never grade the same bytes differently.
      {
        "GET /a HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET  /a HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET\t/a HTTP/1.1\r\nHost: h\r\n\r\n",
        "\r\nGET /a HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET\r\nHost: h\r\n\r\n",
      }.each do |raw|
        Http1.gate_target(Http1.parse_request_head(bytes(raw)))
          .should eq(Gori::Outbound.request_target(raw))
      end
    end
  end

  describe ".strip_header_lines" do
    it "drops the lines the block accepts and copies every other byte verbatim" do
      raw = bytes("HTTP/1.1 200 OK\r\nX-A: 1\r\nAlt-Svc: h3\r\nX-B: 2\r\n\r\n")
      seen = [] of String
      kept = Http1.strip_header_lines(raw, "alt-svc") do |value|
        seen << String.new(value)
        true
      end
      seen.should eq(["h3"])
      String.new(kept).should eq("HTTP/1.1 200 OK\r\nX-A: 1\r\nX-B: 2\r\n\r\n")
    end

    it "returns the INPUT slice when the block dropped nothing" do
      # Identity, not equality: this is what keeps a head the caller decided against editing on
      # the byte-exact forwarding path (P7) instead of shipping a copy of itself.
      raw = bytes("HTTP/1.1 200 OK\r\nAlt-Svc: h2\r\n\r\n")
      kept = Http1.strip_header_lines(raw, "alt-svc") { false }
      kept.to_unsafe.should eq(raw.to_unsafe)
    end

    it "never treats the start-line as a header line" do
      # A request target can contain a colon, and a status line always does. Matching the
      # start-line as `name: value` is how a strip would eat the message's first line.
      raw = bytes("alt-svc: /x HTTP/1.1\r\nHost: h\r\n\r\n")
      kept = Http1.strip_header_lines(raw, "alt-svc") { true }
      String.new(kept).should eq("alt-svc: /x HTTP/1.1\r\nHost: h\r\n\r\n")
    end
  end

  describe ".header_line_value" do
    it "matches the field-name exactly, case-insensitively, and trims OWS off the value" do
      Http1.header_line_value(bytes("Alt-Svc:  h3=\":443\"  \r\n"), "alt-svc")
        .try { |v| String.new(v) }.should eq("h3=\":443\"")
      Http1.header_line_value(bytes("ALT-SVC: h3\r\n"), "alt-svc").should_not be_nil
    end

    it "does not match a prefix, a suffix, or a colon-less line" do
      Http1.header_line_value(bytes("X-Alt-Svc: h3\r\n"), "alt-svc").should be_nil
      Http1.header_line_value(bytes("Alt-Svc-Extra: h3\r\n"), "alt-svc").should be_nil
      Http1.header_line_value(bytes("\r\n"), "alt-svc").should be_nil
    end

    it "returns an empty view for a valueless field rather than nil" do
      # "the field is present and says nothing" and "the field is absent" are different answers.
      Http1.header_line_value(bytes("Alt-Svc:\r\n"), "alt-svc").try(&.size).should eq(0)
    end

    it "returns a VIEW into the head, never a copy" do
      raw = bytes("Alt-Svc: h3\r\n")
      value = Http1.header_line_value(raw, "alt-svc").not_nil!
      value.to_unsafe.should eq(raw.to_unsafe + 9)
    end
  end
end
