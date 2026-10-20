require "../spec_helper"

# `Repeater::UrlRequest` — the typed half of the URL-built send, shared by MCP `send_request`
# and `gori run send` (#1116). The MCP argument shapes around it are pinned in
# spec/mcp/request_builder_spec.cr; this pins what the CLI reaches directly.
describe Gori::Repeater::UrlRequest do
  it "builds the request line from the URL's path and query, with Host and Content-Length" do
    t = Gori::Repeater::UrlRequest.target("https://api.example.test:8443/v1/items/42?lang=en")
    {t.scheme, t.host, t.port}.should eq({"https", "api.example.test", 8443})
    built = Gori::Repeater::UrlRequest.structured(t, "post", [{"Accept", "application/json"}], %({"a":1}).to_slice)
    String.new(built.bytes).should eq(
      "POST /v1/items/42?lang=en HTTP/1.1\r\nAccept: application/json\r\nHost: api.example.test:8443\r\n" \
      "Content-Length: 7\r\n\r\n{\"a\":1}")
  end

  it "upper-cases the method unless expand is off" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    none = [] of {String, String}
    String.new(Gori::Repeater::UrlRequest.structured(t, "get", none, nil).bytes).should start_with("GET / HTTP/1.1\r\n")
    String.new(Gori::Repeater::UrlRequest.structured(t, "get", none, nil, expand: false).bytes)
      .should start_with("get / HTTP/1.1\r\n")
  end

  # `gori run send --verbatim`: a token the operator typed in a header value is the payload.
  it "leaves a header value's $ENV token literal with expand: false" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    built = Gori::Repeater::UrlRequest.structured(t, nil, [{"X-T", "$ENV.NOT_A_VAR"}], nil, expand: false)
    String.new(built.bytes).should contain("X-T: $ENV.NOT_A_VAR\r\n")
  end

  it "refuses a header that would split into two, and a URL with no host" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    expect_raises(Gori::Error, /CR\/LF\/NUL/) do
      Gori::Repeater::UrlRequest.structured(t, nil, [{"X", "a\r\nY: b"}], nil)
    end
    expect_raises(Gori::Error, /include a scheme/) { Gori::Repeater::UrlRequest.target("h.test:80/x") }
    expect_raises(Gori::Error, /only http\/https/) { Gori::Repeater::UrlRequest.target("ftp://h.test/") }
  end

  # #1690: curl sends a URL's `user:pass@` as Basic auth; the send dropped it without a word.
  it "encodes URL userinfo as Basic auth, percent-decoded, unless a header states Authorization" do
    t = Gori::Repeater::UrlRequest.target("http://us%40er:p%3Ass@h.test:8080/creds")
    {t.host, t.port}.should eq({"h.test", 8080})
    none = [] of {String, String}
    sent = String.new(Gori::Repeater::UrlRequest.structured(t, nil, none, nil).bytes)
    sent.should eq("GET /creds HTTP/1.1\r\nHost: h.test:8080\r\n" \
                   "Authorization: Basic #{Base64.strict_encode("us@er:p:ss")}\r\n\r\n")
    mine = String.new(Gori::Repeater::UrlRequest.structured(t, nil, [{"authorization", "Bearer x"}], nil).bytes)
    mine.should contain("authorization: Bearer x\r\n")
    mine.should_not contain("Basic")
    # A user with no password is an empty password, as curl sends it.
    only = Gori::Repeater::UrlRequest.target("http://only@h.test/")
    String.new(Gori::Repeater::UrlRequest.structured(only, nil, none, nil).bytes)
      .should contain("Authorization: Basic #{Base64.strict_encode("only:")}\r\n")
    # The raw shape is the operator's bytes: nothing is added.
    String.new(Gori::Repeater::UrlRequest.raw(t, "GET / HTTP/1.1\r\n\r\n", true).bytes).should_not contain("Authorization")
  end

  it "sends a raw request byte-exact under verbatim, and CRLF-promotes only its head otherwise" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    raw = "GET / HTTP/1.1\nHost: h\n\nbody\nline"
    String.new(Gori::Repeater::UrlRequest.raw(t, raw, true).bytes).should eq(raw)
    String.new(Gori::Repeater::UrlRequest.raw(t, raw, false).bytes).should eq("GET / HTTP/1.1\r\nHost: h\r\n\r\nbody\nline")
  end
end

describe "Gori::Repeater::UrlRequest $ENV expansion" do
  # #1668: the env pass changes the body's length, so Content-Length follows it — as the send
  # seam's `$GEN` pass and a session replay already did. A token-free body keeps its CL.
  it "re-frames a raw request's Content-Length only when the env pass changed the body" do
    Gori::Settings.env_vars = [{"TOKEN", "abc123"}, {"UNI", "héllo wörld!!"}]
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      t = Gori::Repeater::UrlRequest.target("http://h.test/")
      head = "POST /raw HTTP/1.1\r\nHost: h\r\n"
      shorter = Gori::Repeater::UrlRequest.raw(t, "#{head}Content-Length: 15\r\n\r\nbody=$ENV.TOKEN", false)
      String.new(shorter.bytes).should eq("#{head}Content-Length: 11\r\n\r\nbody=abc123")
      longer = Gori::Repeater::UrlRequest.raw(t, "#{head}Content-Length: 14\r\n\r\nb=$ENV.UNI&z=1", false)
      String.new(longer.bytes).should eq("#{head}Content-Length: 21\r\n\r\nb=héllo wörld!!&z=1")
      # A deliberate CL mismatch over a token-free body, and anything under verbatim, is as typed.
      probe = "#{head}Content-Length: 99\r\n\r\nab"
      String.new(Gori::Repeater::UrlRequest.raw(t, probe, false).bytes).should eq(probe)
      typed = "#{head}Content-Length: 15\r\n\r\nbody=$ENV.TOKEN"
      String.new(Gori::Repeater::UrlRequest.raw(t, typed, true).bytes).should eq(typed)
    end
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end

  # #1666: an `$ENV.KEY` that resolves to nothing is refused, in a raw request and a header.
  it "refuses an unresolved $ENV.KEY in a raw request and a header value, never under verbatim" do
    Gori::Settings.env_vars = [] of {String, String}
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      t = Gori::Repeater::UrlRequest.target("http://h.test/")
      ex = expect_raises(Gori::Repeater::PlanError) do
        Gori::Repeater::UrlRequest.raw(t, "GET / HTTP/1.1\r\nX: $ENV.NOPE\r\n\r\n", false)
      end
      ex.detail.should eq("$ENV.NOPE")
      expect_raises(Gori::Repeater::PlanError) do
        Gori::Repeater::UrlRequest.structured(t, nil, [{"X", "$ENV.NOPE"}], nil)
      end
      expect_raises(Gori::Repeater::PlanError) { Gori::Repeater::UrlRequest.expand("b=$ENV.NOPE") }
      String.new(Gori::Repeater::UrlRequest.raw(t, "GET / HTTP/1.1\r\nX: $ENV.NOPE\r\n\r\n", true).bytes)
        .should contain("X: $ENV.NOPE")
      # The URL's path and query become the request line, so a token there is refused too —
      # but not by `target` alone, which a field-native send resolves its origin through.
      q = Gori::Repeater::UrlRequest.target("http://h.test/p?q=$ENV.NOPE")
      expect_raises(Gori::Repeater::PlanError, /\$ENV\.NOPE/) do
        Gori::Repeater::UrlRequest.structured(q, nil, [] of {String, String}, nil)
      end
      String.new(Gori::Repeater::UrlRequest.structured(q, nil, [] of {String, String}, nil, expand: false).bytes)
        .should start_with("GET /p?q=$ENV.NOPE ")
      # ONE refusal over the URL, every header and a text body, so it names every token.
      all = expect_raises(Gori::Repeater::PlanError) do
        Gori::Repeater::UrlRequest.structured(q, nil, [{"X", "$ENV.A1"}, {"Y", "$ENV.B2"}], "b=$ENV.C3")
      end
      all.detail.should eq("$ENV.NOPE, $ENV.A1, $ENV.B2, $ENV.C3")
      # A bare `$name` is GraphQL/Mongo text and still goes out as typed.
      String.new(Gori::Repeater::UrlRequest.structured(t, nil, [{"X", "$ne"}], nil).bytes).should contain("X: $ne\r\n")
    end
  end
end

describe "Gori::Repeater::UrlRequest.structured body text" do
  it "expands a text body with the headers and frames it, and keeps bytes as they are" do
    Gori::Settings.env_vars = [{"TOKEN", "abc123"}]
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      t = Gori::Repeater::UrlRequest.target("http://h.test/")
      sent = String.new(Gori::Repeater::UrlRequest.structured(t, "POST", [] of {String, String}, "b=$ENV.TOKEN").bytes)
      sent.should end_with("Content-Length: 8\r\n\r\nb=abc123")
      raw = String.new(Gori::Repeater::UrlRequest.structured(t, "POST", [] of {String, String}, "b=$ENV.TOKEN".to_slice).bytes)
      raw.should end_with("\r\n\r\nb=$ENV.TOKEN")
      literal = String.new(Gori::Repeater::UrlRequest.structured(t, "POST", [] of {String, String}, "b=$ENV.TOKEN", expand: false).bytes)
      literal.should end_with("\r\n\r\nb=$ENV.TOKEN")
    end
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end
end
