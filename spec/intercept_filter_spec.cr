require "./spec_helper"

private def req(method = "GET", host = "acme.test", target = "/login", scheme = "http")
  Gori::InterceptFilter::Subject.new(method: method, host: host, target: target, scheme: scheme)
end

private def res(status : Int32, method = "GET", host = "acme.test", target = "/login", scheme = "http")
  Gori::InterceptFilter::Subject.new(method: method, host: host, target: target, scheme: scheme, status: status)
end

# A held WebSocket message: the handshake's identity plus the payload in hand at the gate.
private def ws(payload = %({"op":"subscribe","ch":"trades"}), host = "acme.test", target = "/ws")
  Gori::InterceptFilter::Subject.new(method: "GET", host: host, target: target, scheme: "http",
    proto: Gori::Proto::Kind::Ws, payload: payload.to_slice)
end

# A gated HTTP message WITH its head — what `ClientConn` and the h2 stream gate now pass.
private def headed(head : String, method = "POST", host = "acme.test", target = "/login",
                   scheme = "http", status : Int32? = nil, body : String? = nil)
  Gori::InterceptFilter::Subject.new(method: method, host: host, target: target, scheme: scheme,
    status: status, head: head.to_slice, payload: body.try(&.to_slice))
end

describe Gori::InterceptFilter do
  it "an empty filter matches everything" do
    f = Gori::InterceptFilter::EMPTY
    f.blank?.should be_true
    f.matches?(req).should be_true
    f.matches?(res(200)).should be_true
  end

  it "matches host as a substring (case-insensitive)" do
    f = Gori::InterceptFilter.new("host:ACME")
    f.matches?(req(host: "api.acme.test")).should be_true
    f.matches?(req(host: "evil.test")).should be_false
  end

  it "matches method exactly (case-insensitive)" do
    f = Gori::InterceptFilter.new("method:post")
    f.matches?(req(method: "POST")).should be_true
    f.matches?(req(method: "GET")).should be_false
  end

  # `header:` reads whatever head the caller had in hand. Every gate has one; the bytes were
  # simply never passed, so the term answered false against a head sitting in the argument list.
  it "matches header: against the head bytes in hand" do
    f = Gori::InterceptFilter.new("header:x-trace")
    head = "POST /login HTTP/1.1\r\nHost: acme.test\r\nX-Trace: abc123\r\n\r\n"
    f.matches?(headed(head)).should be_true # case-insensitive
    f.matches?(headed("POST /login HTTP/1.1\r\n\r\n")).should be_false
    f.matches?(req).should be_false # no head passed ⇒ no match
    # NUL-transparent, like the store-side `header:` — the head is bytes, not a C string.
    f.matches?(headed("POST / HTTP/1.1\r\nA: b\u{0}\r\nX-Trace: 1\r\n\r\n")).should be_true
  end

  it "matches url: against scheme://host + target" do
    f = Gori::InterceptFilter.new("url:acme.test/adm")
    f.matches?(req(host: "acme.test", target: "/admin")).should be_true
    f.matches?(req(host: "acme.test", target: "/login")).should be_false
    # An absolute-form target already carries its authority and must not be doubled.
    f.matches?(req(host: "acme.test", target: "http://acme.test/admin")).should be_true
  end

  describe "~ regex" do
    # `~` used to be a character with no meaning here, so `host~^api\.` was free text and matched
    # nothing real. It is QL's operator on QL's five fields, so a pattern means the same thing in
    # the intercept bar as in the History bar.
    it "applies to host, path, url, header and body" do
      Gori::InterceptFilter.new("host~^api\\.").matches?(req(host: "api.acme.test")).should be_true
      Gori::InterceptFilter.new("host~^api\\.").matches?(req(host: "x.api.test")).should be_false
      Gori::InterceptFilter.new("path~/v\\d+/").matches?(req(target: "/v2/users")).should be_true
      Gori::InterceptFilter.new("url~^https://").matches?(req(scheme: "https")).should be_true
      Gori::InterceptFilter.new("header~(?i)x-trace:\\s*\\w+")
        .matches?(headed("GET / HTTP/1.1\r\nX-Trace: abc\r\n\r\n")).should be_true
      Gori::InterceptFilter.new("body~subscr\\w+").matches?(ws).should be_true
      Gori::InterceptFilter.new("body~unsubscr\\w+").matches?(ws).should be_false
    end

    # A `~` on a field QL does not offer it on free-texts the whole token, exactly as
    # `QL.regex_cond` does — so the two backends never disagree about what is a regex.
    it "free-texts a ~ on a field that has no regex form" do
      Gori::InterceptFilter.new("method~POST").matches?(req(method: "POST")).should be_false
      Gori::InterceptFilter.new("method~POST").matches?(req(target: "/method~post")).should be_true
    end

    # An invalid pattern must not raise onto the proxy path. It becomes a never-match term,
    # mirroring QL's never-match clause; the surfaces that let one be SAVED refuse it instead.
    it "never-matches an uncompilable pattern instead of raising" do
      f = Gori::InterceptFilter.new("host~[bad")
      f.blank?.should be_false
      f.matches?(req).should be_false
      Gori::InterceptFilter.new("-host~[bad").matches?(req).should be_true # negation still flips
    end

    # PCRE2 RAISES on invalid UTF-8 rather than not matching, and a target is bytes off the wire.
    # A raise here would kill the connection fiber at a hold gate.
    it "survives an invalid-UTF-8 haystack" do
      f = Gori::InterceptFilter.new("path~admin")
      f.matches?(req(target: String.new(Bytes[0x2F, 0xFF, 0xFE, 0x61]))).should be_false
      f.matches?(req(target: String.new(Bytes[0x2F, 0xFF, 0x61, 0x64, 0x6D, 0x69, 0x6E]))).should be_true
    end
  end

  # What a caller deciding whether to BUFFER a body has to ask. It descends into NOT where
  # `mentions_ws?` does not, and that asymmetry is the point: with nothing buffered `-body:x`
  # evaluates false and negates to a match on everything.
  it "reports whether a condition reads a body, negation included" do
    Gori::InterceptFilter.new("body:secret").mentions_body?.should be_true
    Gori::InterceptFilter.new("-body:secret").mentions_body?.should be_true
    Gori::InterceptFilter.new("NOT (host:a AND body~x)").mentions_body?.should be_true
    Gori::InterceptFilter.new("host:a OR body:b").mentions_body?.should be_true
    Gori::InterceptFilter.new("host:a status:5xx").mentions_body?.should be_false
    Gori::InterceptFilter::EMPTY.mentions_body?.should be_false
  end

  it "matches path as a substring of the target" do
    f = Gori::InterceptFilter.new("path:/api")
    f.matches?(req(target: "/api/v1/users?id=1")).should be_true
    f.matches?(req(target: "/login")).should be_false
  end

  it "matches scheme exactly" do
    Gori::InterceptFilter.new("scheme:https").matches?(req(scheme: "https")).should be_true
    Gori::InterceptFilter.new("scheme:https").matches?(req(scheme: "http")).should be_false
  end

  it "status: only matches a response, never a request (request has no status)" do
    f = Gori::InterceptFilter.new("status:500")
    f.matches?(res(500)).should be_true
    f.matches?(res(404)).should be_false
    f.matches?(req).should be_false # a request can't satisfy a status term
  end

  it "supports status comparisons and classes" do
    Gori::InterceptFilter.new("status:>=500").matches?(res(503)).should be_true
    Gori::InterceptFilter.new("status:>=500").matches?(res(404)).should be_false
    Gori::InterceptFilter.new("status:5xx").matches?(res(500)).should be_true
    Gori::InterceptFilter.new("status:5xx").matches?(res(499)).should be_false
    # status_match? tests a literal lowercase 'x', so an upcased class used to match nothing.
    Gori::InterceptFilter.new("status:5XX").matches?(res(500)).should be_true
    Gori::InterceptFilter.new("status:<400").matches?(res(200)).should be_true
  end

  it "ANDs terms within a group, ORs across OR" do
    f = Gori::InterceptFilter.new("method:POST host:acme")
    f.matches?(req(method: "POST", host: "acme.test")).should be_true
    f.matches?(req(method: "POST", host: "other.test")).should be_false

    g = Gori::InterceptFilter.new("host:acme OR host:shop")
    g.matches?(req(host: "acme.test")).should be_true
    g.matches?(req(host: "shop.test")).should be_true
    g.matches?(req(host: "other.test")).should be_false
  end

  it "negates a term with a leading -" do
    f = Gori::InterceptFilter.new("-host:acme")
    f.matches?(req(host: "acme.test")).should be_false
    f.matches?(req(host: "evil.test")).should be_true
  end

  it "treats a bare word as free text over method/host/target" do
    f = Gori::InterceptFilter.new("login")
    f.matches?(req(target: "/login")).should be_true
    f.matches?(req(target: "/home")).should be_false
  end

  it "drops empty-valued terms (so `host:` while typing matches all)" do
    Gori::InterceptFilter.new("host:").blank?.should be_true
    Gori::InterceptFilter.new("host:").matches?(req).should be_true
  end

  describe ".suggestions" do
    it "completes field names, then that field's values" do
      Gori::InterceptFilter.suggestions("me", 2).should eq(["method:"])
      Gori::InterceptFilter.suggestions("s", 1).should eq(["scheme:", "status:"])
      Gori::InterceptFilter.suggestions("method:P", 8).should eq(["method:POST", "method:PUT", "method:PATCH"])
      Gori::InterceptFilter.suggestions("scheme:h", 8).should eq(["scheme:http", "scheme:https"])
      Gori::InterceptFilter.suggestions("status:4", 8).should contain("status:4xx")
    end

    it "only offers fields this parser understands (no History-only size:/dur:)" do
      # The list is what a LIVE message can answer. `body:` joined with #500 step 2 (a held WS
      # message carries its payload); `header:`/`url:` joined when the gates began passing the
      # head they already had. What is still missing needs an exchange that has FINISHED —
      # `size:`/`respsize:`/`dur:` — or a capture decision not yet made (`stub:`).
      Gori::InterceptFilter::FIELDS.should eq(%w(host path url method scheme status proto header body))
      Gori::InterceptFilter.suggestions("s", 1).should eq(["scheme:", "status:"]) # not size:
      Gori::InterceptFilter.suggestions("d", 1).should be_empty
      Gori::InterceptFilter.suggestions("he", 2).should eq(["header:"])
      # `path:`/`header:`/`body:` complete the field but have no value pool — all unbounded.
      Gori::InterceptFilter.suggestions("pa", 2).should eq(["path:"])
      Gori::InterceptFilter.suggestions("path:/ap", 8).should be_empty
      Gori::InterceptFilter.suggestions("body:tra", 8).should be_empty
      Gori::InterceptFilter.suggestions("header:x-", 9).should be_empty
    end

    it "offers only the proto values a hold gate can ever answer (no grpc/sse)" do
      # A gate knows its leg — Ws for a held WebSocket message, Http for everything else — and
      # `grpc`/`sse` are read off a CAPTURED response's Content-Type, which does not exist yet
      # when the message is being held. Completing them handed the operator a condition that
      # silently holds nothing, which reads as intercept being broken.
      Gori::InterceptFilter.suggestions("proto:", 6).should eq(["proto:ws", "proto:http"])
      Gori::InterceptFilter.suggestions("proto:g", 7).should be_empty
      Gori::InterceptFilter.suggestions("proto:s", 7).should be_empty
    end

    it "takes host values from the injected pool and preserves a leading -" do
      hosts = ["api.acme.test", "app.acme.test"]
      Gori::InterceptFilter.suggestions("host:ap", 7, hosts).should eq(["host:api.acme.test", "host:app.acme.test"])
      Gori::InterceptFilter.suggestions("-host:ap", 8, hosts).should eq(["-host:api.acme.test", "-host:app.acme.test"])
      Gori::InterceptFilter.suggestions("-me", 3).should eq(["-method:"])
    end

    it "completes the token under the caret, not the whole query" do
      # Caret sits inside "me" (offset 15), with a trailing term after it.
      q = "host:acme.test me path:/x"
      Gori::InterceptFilter.suggestions(q, 17).should eq(["method:"])
      cur = Gori::FilterAst.token_at(q, 17)
      {cur.core, cur.start, cur.stop}.should eq({"me", 15, 17})
    end

    it "carries an opening paren through the completion" do
      # Grouping punctuation must survive Tab, or completing inside `(host:a OR (me`
      # would silently drop the group the user just opened.
      Gori::InterceptFilter.suggestions("(me", 3).should eq(["(method:"])
      Gori::InterceptFilter.suggestions("(-me", 4).should eq(["(-method:"])
      hosts = ["api.acme.test"]
      Gori::InterceptFilter.suggestions("host:a OR (host:ap", 18, hosts).should eq(["(host:api.acme.test"])
    end

    it "completes through a half-typed opening quote" do
      hosts = ["api.acme.test"]
      Gori::InterceptFilter.suggestions(%(host:"ap), 8, hosts).should eq(["host:api.acme.test"])
    end

    it "stays quiet on blank space and on an unmatched free-text word" do
      Gori::InterceptFilter.suggestions("", 0).should be_empty
      Gori::InterceptFilter.suggestions("host:acme ", 10).should be_empty
      Gori::InterceptFilter.suggestions("login", 5).should be_empty
    end
  end

  describe "the WebSocket terms (#500 step 2)" do
    it "matches proto: against the subject's protocol, canonicalising the alias" do
      Gori::InterceptFilter.new("proto:ws").matches?(ws).should be_true
      Gori::InterceptFilter.new("proto:WebSocket").matches?(ws).should be_true
      Gori::InterceptFilter.new("proto:ws").matches?(req).should be_false
      # An HTTP hold gate has no status to classify with, so `proto:` resolves to Http
      # there — which is why `proto:ws` never matches the 101 handshake REQUEST itself.
      Gori::InterceptFilter.new("proto:http").matches?(req).should be_true
    end

    it "matches body: over the raw payload, ASCII-case-insensitively" do
      Gori::InterceptFilter.new("body:SUBSCRIBE").matches?(ws(payload: %({"op":"subscribe"}))).should be_true
      Gori::InterceptFilter.new("body:unsubscribe").matches?(ws(payload: %({"op":"subscribe"}))).should be_false
    end

    it "searches body: WITHOUT decoding, so a non-UTF-8 payload still matches" do
      # The point of the byte scan: `String.new(payload)` would turn 0xFF into U+FFFD and
      # both allocate a copy per message and mangle what it is searching.
      payload = Bytes[0xFF, 0x00, 'h'.ord.to_u8, 'i'.ord.to_u8, 0xFE]
      s = Gori::InterceptFilter::Subject.new(method: "GET", host: "acme.test", target: "/ws",
        scheme: "http", proto: Gori::Proto::Kind::Ws, payload: payload)
      Gori::InterceptFilter.new("body:hi").matches?(s).should be_true
      Gori::InterceptFilter.new("body:no").matches?(s).should be_false
    end

    it "never matches body: at an HTTP gate, where the raw bytes do not exist yet" do
      Gori::InterceptFilter.new("body:anything").matches?(req).should be_false
      Gori::InterceptFilter.new("body:anything").matches?(res(200)).should be_false
    end
  end

  describe "#mentions_ws? — the hold's opt-in, not a narrowing term" do
    it "is false for a blank filter, which is the exact inverse of the HTTP default" do
      # A blank filter matches EVERYTHING (`blank?` is true), and still arms nothing on WS.
      Gori::InterceptFilter::EMPTY.blank?.should be_true
      Gori::InterceptFilter::EMPTY.mentions_ws?.should be_false
    end

    it "is false for an ordinary HTTP condition, however permissive" do
      Gori::InterceptFilter.new("host:acme").mentions_ws?.should be_false
      Gori::InterceptFilter.new("host:acme OR method:POST").mentions_ws?.should be_false
      Gori::InterceptFilter.new("proto:grpc").mentions_ws?.should be_false
    end

    it "is true for an explicit proto:ws, through AND, OR and the alias" do
      Gori::InterceptFilter.new("proto:ws").mentions_ws?.should be_true
      Gori::InterceptFilter.new("host:acme proto:ws").mentions_ws?.should be_true
      Gori::InterceptFilter.new("proto:ws OR host:acme").mentions_ws?.should be_true
      Gori::InterceptFilter.new("proto:websocket").mentions_ws?.should be_true
    end

    it "is false when the term is negated — `-proto:ws` asks to leave WS alone" do
      Gori::InterceptFilter.new("-proto:ws").mentions_ws?.should be_false
      Gori::InterceptFilter.new("NOT proto:ws").mentions_ws?.should be_false
      Gori::InterceptFilter.new("host:acme AND NOT (proto:ws)").mentions_ws?.should be_false
    end
  end

  describe "completion" do
    it "offers the two new fields and the proto: value pool" do
      Gori::InterceptFilter.suggestions("pro", 3).should eq(["proto:"])
      Gori::InterceptFilter.suggestions("bo", 2).should eq(["body:"])
      Gori::InterceptFilter.suggestions("proto:w", 7).should eq(["proto:ws"])
    end
  end
end
