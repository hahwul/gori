require "../spec_helper"

# `Gori::Export::Curl` — the curl serializer that used to live inside `Tui::CopyMenu` and now
# backs BOTH the TUI's "Copy as → cURL" row and `gori run show <id> --format curl`. The point
# of the move is that there is one of it; these specs pin what it emits, and
# spec/tui/copy_menu_spec.cr pins that the menu still offers exactly that text.

private def curl_of(wire : String, target : String) : String
  Gori::Export::Curl.text(wire, target).not_nil!
end

describe Gori::Export::Curl do
  describe ".text" do
    it "drops Host and Content-Length — curl derives both from the URL and the body" do
      cmd = curl_of("POST /api/login HTTP/1.1\r\nHost: example.com\r\n" \
                    "Content-Length: 14\r\nX-Key: k\r\n\r\n{\"user\":\"neo\"}",
        "https://example.com")
      cmd.should contain("curl 'https://example.com/api/login'")
      cmd.should contain("-H 'X-Key: k'")
      cmd.should_not contain("-H 'Host:")
      cmd.should_not contain("Content-Length")
    end

    it "keeps the query string on the URL and does not re-emit it anywhere else" do
      cmd = curl_of("GET /search?q=a%20b&page=2 HTTP/1.1\r\nHost: h.test\r\n\r\n", "https://h.test")
      cmd.should contain("curl 'https://h.test/search?q=a%20b&page=2'")
    end

    it "omits -X for a plain bodyless GET (curl's default) and emits it for anything else" do
      curl_of("GET /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should_not contain("-X")
      curl_of("DELETE /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should contain("-X 'DELETE'")
    end

    # The METHOD is a captured token, not gori's text: `parse_request_head` refuses only
    # SP/CTL/DEL on the request line and `Import::Builder.reject_inject!` only CR/LF/NUL, so
    # every shell metacharacter reaches this serializer from a client on the wire or from an
    # imported HAR. Unquoted, `-X GET;curl|sh` ran a second command in the operator's shell on
    # paste. Pinned per metacharacter rather than as one example: this is the ONE argument that
    # was ever spliced raw, and a future "shell-safe method names are fine, skip the quotes"
    # shortcut has to fail on each of them, not just on the one that got written down.
    it "quotes a captured method, so a shell metacharacter in it cannot end the command" do
      {";curl|sh", "`id`", "$(id)", "&&id", ">out"}.each do |tail|
        cmd = curl_of("GET#{tail} /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
        cmd.should contain("-X 'GET#{tail}'")
        # …and nothing outside the quotes for a shell to read as syntax.
        cmd.lines.last.should eq("  -X 'GET#{tail}'")
      end
    end

    # The one byte quoting cannot rescue, on the same command `data_argument` already refuses it
    # for. bash truncates an argv element at a NUL, so `-X 'GET<NUL>x'` would have LOOKED right
    # on screen and sent `GET`. Nothing validates the method (see `command`); the proxy path can
    # carry a NUL through, the import path refuses it.
    it "refuses -X for a method holding a NUL instead of emitting one bash would truncate" do
      cmd = curl_of("GET\u0000x /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
      # Not `should_not contain("-X ")` — the note itself says "-X omitted". What must be
      # absent is the ARGUMENT: no line whose own first token is -X.
      cmd.lines.any? { |l| l.lstrip.starts_with?("-X ") }.should be_false
      cmd.should contain("# -X omitted")
      # LAST line: a `#` comment swallows the ` \` that continues the command, so the note has
      # to sit where there is nothing left for it to truncate.
      cmd.lines.last.should start_with("  # -X omitted")
    end

    # A `'` cannot be carried inside '…' — `shell_quote` closes, escapes, reopens. The method
    # goes through the same rewrite as every other argument, so the token stays one word.
    it "escapes a single quote in a captured method instead of breaking out of the quoting" do
      curl_of("GE'T /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
        .should contain(%q(-X 'GE'\''T'))
    end

    it "keeps -X GET when a GET carries a body, which curl would otherwise promote to POST" do
      cmd = curl_of("GET /a HTTP/1.1\r\nHost: h\r\n\r\nq=1", "http://h")
      cmd.should contain("-X 'GET'")
      cmd.should contain("--data-raw 'q=1'")
    end

    it "sends a JSON body verbatim through --data-raw, quotes and all" do
      cmd = curl_of("POST /api HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n\r\n" \
                    "{\"user\":\"neo\",\"note\":\"it's fine\"}", "https://h")
      cmd.should contain("-H 'Content-Type: application/json'")
      # POSIX single-quote: the body's own ' becomes '\'' and the rest rides through as typed.
      cmd.should contain(%q(--data-raw '{"user":"neo","note":"it'\''s fine"}'))
    end

    it "resolves an absolute-form request line (a plain-HTTP forward proxy capture) as-is" do
      curl_of("GET http://plain.test/x HTTP/1.1\r\nHost: plain.test\r\n\r\n", "http://plain.test")
        .should contain("curl 'http://plain.test/x'")
    end

    it "returns nil when there is no URL to build — nothing runnable to hand over" do
      Gori::Export::Curl.text("", "").should be_nil
    end
  end

  # An h2 capture is stored as the SYNTHESIZED h1 head `Proxy::H2::HeadCodec.synth_request`
  # writes: an `HTTP/2` request line, a `Host:` standing in for `:authority`, and — capture-side
  # only — gori's own marker lines about the exchange. Both halves matter to a command that
  # claims to reproduce the request.
  describe "an HTTP/2 capture" do
    it "asserts h2 over TLS with --http2 (ALPN does the rest)" do
      cmd = curl_of("GET /a HTTP/2\r\nHost: h2.test\r\naccept: */*\r\n\r\n", "https://h2.test")
      cmd.should contain("--http2")
      cmd.should_not contain("--http2-prior-knowledge")
    end

    it "asserts cleartext h2c with --http2-prior-knowledge, which has no ALPN to negotiate" do
      curl_of("GET /a HTTP/2\r\nHost: h2c.test\r\n\r\n", "http://h2c.test:8080")
        .should contain("--http2-prior-knowledge")
    end

    it "leaves HTTP/1.1 alone — it is curl's default" do
      curl_of("GET /a HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should_not contain("--http")
    end

    # These three lines are gori speaking ABOUT the exchange (which fields arrived in a
    # trailing HEADERS block, that the ORIGIN invented this request in a PUSH_PROMISE, an
    # RFC 8441 `:protocol`). No client put them on a wire, so a reproduction must not send them.
    it "does not send gori's own marker lines back to the origin" do
      cmd = curl_of("GET /a HTTP/2\r\nHost: h2.test\r\n" \
                    "#{Gori::Proxy::H2::HeadCodec::TRAILER_MARKER}: grpc-status\r\n" \
                    "#{Gori::Proxy::H2::HeadCodec::PUSHED_MARKER}: server push promised on stream 3\r\n" \
                    "#{Gori::Proxy::H2::HeadCodec::PROTOCOL_MARKER}: websocket\r\n" \
                    "x-real: kept\r\n\r\n", "https://h2.test")
      cmd.should_not contain("X-Gori-")
      cmd.should contain("-H 'x-real: kept'")
    end
  end

  # The two arguments this file did NOT already refuse a NUL for. `shell_quote` says it in its
  # own comment: every byte rides inside '…' except 0x00, and an argv is NUL-terminated. Measured
  # with `curl` replaced by `/bin/echo` so execve's argv is visible: zsh (macOS's default shell)
  # truncates SILENTLY at the NUL — `curl 'https://acme.test/pa<NUL>th'` requests `/pa` — and
  # bash refuses the whole line. Neither says why, and a command that quietly requests a
  # DIFFERENT path than the capture is the exact failure `nul_method_note` and `data_argument`
  # already exist to prevent.
  describe "a URL or header no shell argument can carry" do
    it "refuses the whole command when the captured URL holds a NUL" do
      cmd = curl_of("GET /pa\u0000th HTTP/1.1\r\nHost: acme.test\r\n\r\n", "https://acme.test")
      # Not a curl line at all: there is no fallback for the one argument the command is FOR,
      # so the paste must do nothing rather than fetch a different path.
      cmd.lines.each { |l| l.lstrip.should start_with("#") }
      cmd.should contain("# no command")
      cmd.should contain("--format raw")
      cmd.should_not contain("\u0000")
    end

    it "omits a NUL-bearing header and names it, instead of emitting one a shell truncates" do
      cmd = curl_of("GET /a HTTP/1.1\r\nHost: acme.test\r\nX-Nul: be\u0000fore\r\nX-Ok: 1\r\n\r\n",
        "https://acme.test")
      cmd.should_not contain("-H 'X-Nul")
      cmd.should contain("-H 'X-Ok: 1'")
      cmd.should contain("# -H omitted")
      cmd.should contain("X-Nul")
      # The note is a comment on the operator's terminal; it must not carry the byte it is
      # ABOUT (a raw NUL would truncate the note itself).
      cmd.should_not contain("\u0000")
      cmd.lines.last.should start_with("  # -H omitted")
    end
  end

  # A stored request body is WIRE bytes, chunk framing and all. curl frames `--data-raw` itself,
  # so handing it a chunked body under a `Transfer-Encoding: chunked` header made the origin
  # decode 14 bytes where the capture sent 5 — the one runnable artifact of the three
  # (`--format json` and SARIF both de-chunk) sending a different request than the capture.
  describe "a chunked request body" do
    it "de-chunks the body and drops the chunked coding curl re-applies itself" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" \
                    "5\r\nhello\r\n0\r\n\r\n", "https://h")
      cmd.should contain("--data-raw 'hello'")
      cmd.should_not contain("-H 'Transfer-Encoding: chunked'")
      cmd.should contain("# body de-chunked")
    end

    # Only the FINAL `chunked` is framing. A compressing coding under it is content the origin
    # still has to decode, so the layer stays on the command and the bytes stay compressed —
    # de-chunking is not decompressing (`Content-Encoding` is untouched for the same reason).
    it "peels only the final chunked coding, leaving a compressing one on the command" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip, chunked\r\n\r\n" \
                    "4\r\nabcd\r\n0\r\n\r\n", "https://h")
      cmd.should contain("-H 'Transfer-Encoding: gzip'")
      cmd.should contain("--data-raw 'abcd'")
    end

    # A head that declares chunked over a body that is not chunk-framed — a hand-authored
    # Repeater request, an import that stored the entity. `dechunk` is tolerant and recovers
    # NOTHING from one, so peeling would have dropped the operator's body without a word.
    it "hands over a body the head only CLAIMS is chunked, rather than dropping it" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\nplain body",
        "https://h")
      cmd.should contain("--data-raw 'plain body'")
      cmd.should contain("# body sent as captured")
      cmd.should_not contain("de-chunked")
    end

    # A chunked stream cut at the capture cap still de-chunks to what it carried; the command
    # says the capture itself is short rather than pretending the entity is whole.
    it "names a chunked stream that never reached its 0-chunk" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
        "https://h")
      cmd.should contain("--data-raw 'hel'")
      cmd.should contain("never reached its terminating 0-chunk")
    end

    it "leaves a body alone when nothing declares chunked framing" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\n\r\n5\r\nhello\r\n0\r\n\r\n", "https://h")
      cmd.should contain("--data-raw '5")
      cmd.should_not contain("de-chunked")
    end
  end

  # RFC 9112 §5.2: a line starting with SP/HTAB continues the PREVIOUS field's value. `strip`ping
  # the name made a continuation that happens to carry a colon indistinguishable from a header of
  # its own, so the command SENT a header the wire never carried and truncated the value of the
  # one it did — while `--format json` (whose parser does not strip the name) reported a third
  # header set for the same head. A reproduction of a header-parsing difference must not have one
  # of its own.
  describe "an obs-fold continuation" do
    it "folds the continuation into the field above it instead of inventing a header" do
      cmd = curl_of("GET /a HTTP/1.1\r\nHost: h\r\nX-Long: part1\r\n  X-Fake: part2\r\nX-Last: z\r\n\r\n",
        "https://h")
      cmd.should contain("-H 'X-Long: part1 X-Fake: part2'")
      cmd.should_not contain("-H 'X-Fake")
      cmd.should contain("-H 'X-Last: z'")
    end

    it "folds a HTAB continuation, and a colon-less one, the same way" do
      cmd = curl_of("GET /a HTTP/1.1\r\nHost: h\r\nX-Csp: default-src 'self';\r\n\tscript-src 'none'\r\n\r\n",
        "https://h")
      cmd.should contain(%q(-H 'X-Csp: default-src '\''self'\''; script-src '\''none'\'''))
    end
  end

  # `Host` is dropped because curl derives it from the URL — which is only the same header when
  # the capture's Host IS the URL's authority. A Host-header-injection capture is by definition
  # the case where it is not, and that is a test this proxy exists to make possible.
  describe "the Host header" do
    it "keeps a Host that disagrees with the connection authority" do
      cmd = curl_of("GET /x HTTP/1.1\r\nHost: evil.example\r\n\r\n", "https://acme.test")
      cmd.should contain("curl 'https://acme.test/x'")
      cmd.should contain("-H 'Host: evil.example'")
    end

    it "still drops the Host that only repeats the URL, default port spelled out or not" do
      curl_of("GET /x HTTP/1.1\r\nHost: acme.test:443\r\n\r\n", "https://acme.test")
        .should_not contain("-H 'Host:")
      curl_of("GET /x HTTP/1.1\r\nHost: ACME.test\r\n\r\n", "https://acme.test")
        .should_not contain("-H 'Host:")
      curl_of("GET /x HTTP/1.1\r\nHost: acme.test:8080\r\n\r\n", "http://acme.test:8080")
        .should_not contain("-H 'Host:")
    end
  end

  # An empty head has no request line, so there is nothing to reproduce — but `resolve_url` falls
  # back to the target base and the command came out `curl 'https://acme.test'`, a request the
  # capture never made, offered as if it were the capture.
  it "returns nil for a head with no request line rather than inventing GET /" do
    Gori::Export::Curl.text("", "https://acme.test").should be_nil
    Gori::Export::Curl.text("\r\n\r\n", "https://acme.test").should be_nil
  end

  # A curl `-H` with nothing after the colon REMOVES the header (it is how you suppress one of
  # curl's own defaults), so `-H 'X-Empty: '` sent no such field — measured against a raw
  # listener on curl 8.7.1, the request went out with X-Empty absent while the Go, Python and
  # fetch serializers of the same capture all put the empty field on the wire.
  it "sends an empty-valued header with curl's `Name;` form instead of dropping it" do
    cmd = curl_of("GET /x HTTP/1.1\r\nHost: h\r\nX-Empty:\r\nX-Blank:   \r\nX-Full: v\r\n\r\n", "http://h")
    cmd.should contain("-H 'X-Empty;'")
    cmd.should contain("-H 'X-Blank;'")
    cmd.should_not contain("X-Empty: ")
    cmd.should contain("-H 'X-Full: v'")
  end

  # curl expands `[a-b]` and `{x,y}` in the URL argument by default, which for a URL gori
  # RESOLVED is never what the operator meant. Measured against a raw listener, curl 8.7.1, one
  # command each: `?f=[1-3]` sent THREE requests (f=1, f=2, f=3), `?g={a,b}` sent two, and
  # `?fields[item]=id` — a JSON:API sparse fieldset, one of which sits in gori's own demo
  # project — died with `curl: (3) bad range in URL position 32` having sent nothing.
  describe "a URL curl would read as a glob" do
    it "adds --globoff when the URL holds a bracket or a brace" do
      curl_of("GET /q?f=[1-3] HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should contain("--globoff")
      curl_of("GET /q?g={a,b} HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should contain("--globoff")
      curl_of("GET /q?fields[item]=id HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should contain("--globoff")
    end

    it "leaves an ordinary URL without the flag" do
      curl_of("GET /q?a=1 HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").should_not contain("--globoff")
    end

    # The one bracket that is legitimate. Harmless: curl parses a bracketed authority before
    # globbing, so the flag changes nothing on the wire — measured against an AF_INET6 listener,
    # `GET /p` / `Host: [::1]:9143` either way.
    it "fires on an IPv6 literal authority, which curl handles anyway" do
      cmd = curl_of("GET /p HTTP/1.1\r\nHost: [::1]:9143\r\n\r\n", "http://[::1]:9143")
      cmd.should contain("curl 'http://[::1]:9143/p'")
      cmd.should contain("--globoff")
    end

    it "keeps the URL itself literal — the flag is what disarms it, not an escape" do
      cmd = curl_of("GET /q?f=[1-3] HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
      cmd.lines.first.should eq("curl 'http://h/q?f=[1-3]' \\")
    end
  end

  # The URL is the one field every generated client re-reads, and left raw they split three
  # ways: curl lowercases the path escape and leaves the QUERY's high bytes alone, Go escapes
  # the path and writes RawQuery verbatim, requests/fetch/httpie encode both. Pre-encoding says
  # which bytes to ask for once — measured against a raw listener, all five then send
  # `GET /%ED%95%9C/caf%C3%A9?q=%ED%95%9C`.
  describe "a non-ASCII URL" do
    it "percent-encodes the path and query" do
      cmd = curl_of("GET /\u{d55c}?q=\u{d55c} HTTP/1.1\r\nHost: h\r\n\r\n", "http://h")
      cmd.should contain("curl 'http://h/%ED%95%9C?q=%ED%95%9C'")
    end

    it "leaves a non-ASCII authority alone for curl's own IDNA to handle" do
      cmd = curl_of("GET /a HTTP/1.1\r\nHost: \u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}\r\n\r\n",
        "https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}")
      cmd.should contain("curl 'https://\u{c1fc}\u{d551}\u{bab0}.\u{d55c}\u{ad6d}/a'")
    end
  end

  describe "a body no shell argument can carry" do
    it "refuses a NUL-bearing body in a comment rather than sending a SHORTER one" do
      cmd = curl_of("POST /a HTTP/1.1\r\nHost: h\r\n\r\nab\u{0}cd", "http://h")
      cmd.should_not contain("--data-raw")
      cmd.should contain("# body omitted")
      cmd.should contain("--data-binary @FILE")
    end
  end
end
