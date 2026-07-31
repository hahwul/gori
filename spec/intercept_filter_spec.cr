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

    it "only offers fields this parser understands (no History-only header:/dur:)" do
      # `body:` joined the list with #500 step 2 — a held WebSocket message carries its
      # payload to the gate, so the "no row to query" reason no longer applies to it.
      # `header:`/`size:`/`dur:` still have nothing to match against.
      Gori::InterceptFilter::FIELDS.should eq(%w(host path method scheme status proto body))
      Gori::InterceptFilter.suggestions("he", 2).should be_empty
      Gori::InterceptFilter.suggestions("d", 1).should be_empty
      # `path:`/`body:` complete the field but have no value pool — both are unbounded.
      Gori::InterceptFilter.suggestions("pa", 2).should eq(["path:"])
      Gori::InterceptFilter.suggestions("path:/ap", 8).should be_empty
      Gori::InterceptFilter.suggestions("body:tra", 8).should be_empty
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
