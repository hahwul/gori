require "../spec_helper"

private alias F = Gori::Fuzz

# One row built the way the engine builds every row: `Matcher#build` over a Repeater result.
private def row(body : String, payload : String = "p", *,
                head : String = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
                error : String? = nil, incomplete : Bool = false, timed_out : Bool = false,
                index : Int64 = 0_i64) : F::Result
  response = head.empty? ? nil : Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
  raw = Gori::Repeater::Result.new(head.to_slice, body.to_slice, response, 1000_i64, error,
    incomplete, timed_out: timed_out)
  request = "GET /?q=#{payload} HTTP/1.1\r\nHost: t\r\n\r\n"
  spans = [{"GET /?q=".bytesize, "GET /?q=".bytesize + payload.bytesize}]
  job = F::Job.new(index, [payload], 0, request.to_slice, spans)
  F::Matcher.new(keep_bodies: :none).build(job, raw)
end

private def shape(body : String, payload : String = "p", **opts) : Int64
  row(body, payload, **opts).shape.not_nil!
end

private def failed(error : String) : Int64
  shape("", head: "", error: error)
end

describe Gori::Fuzz::Shape do
  it "is recorded on every built row" do
    row("hello").shape.should_not be_nil
  end

  it "separates two bodies with the same status and the same length" do
    a = row("<p>Invalid password</p>")
    b = row("<p>Invalid username</p>")
    a.length.should eq(b.length)
    a.shape.should_not eq(b.shape)
  end

  it "keeps reflected payloads of different lengths in one shape" do
    a = row("<p>No results for 'apple'</p>", "apple")
    b = row("<p>No results for 'a-much-longer-query'</p>", "a-much-longer-query")
    a.length.should_not eq(b.length)
    a.shape.should eq(b.shape)
  end

  it "masks the HTML-escaped and percent-encoded echo of a payload" do
    raw = shape("<p>You searched &lt;svg&gt;</p>", "<svg>")
    other = shape("<p>You searched &lt;img src=x&gt;</p>", "<img src=x>")
    raw.should eq(other)
    shape("<a href=\"/s?q=a%20b%20c\">", "a b c").should eq(shape("<a href=\"/s?q=x%20y%20zz\">", "x y zz"))
  end

  it "masks the quote spellings of PHP, Python, Go and XML escapers, not only its own" do
    {"&#039;", "&#x27;", "&#39;", "&apos;"}.each do |q|
      a = shape("<p>No results for 1#{q} OR 1=1--</p>", %(1' OR 1=1--))
      b = shape("<p>No results for admin#{q}--</p>", %(admin'--))
      a.should eq(b), q
    end
    go1 = shape("<p>No results for &#34;a&#34;</p>", %("a"))
    go2 = shape("<p>No results for &#34;bcd&#34;</p>", %("bcd"))
    go1.should eq(go2)
  end

  it "collapses timestamps, uuids, hex tokens and csrf nonces" do
    a = shape(%({"ts":1727600000,"id":"550e8400-e29b-41d4-a716-446655440000","csrf":"f3a9c1d2e4b5a6f7"}))
    b = shape(%({"ts":1727600999,"id":"123e4567-e89b-12d3-a456-426614174000","csrf":"0b1c2d3e4f5a6b7c"}))
    a.should eq(b)
  end

  it "folds a random hex id that happens to be all digits like any other id" do
    shape("<!-- req 5397ae9c4b977308 -->").should eq(shape("<!-- req 1201083555725435 -->"))
  end

  it "ignores volatile headers and their values, but not a cookie being set" do
    plain = "HTTP/1.1 200 OK\r\nDate: Mon, 01 Jan 2024 00:00:00 GMT\r\nX-Request-Id: abc\r\n\r\n"
    later = "HTTP/1.1 200 OK\r\nDate: Tue, 02 Jan 2024 09:09:09 GMT\r\nContent-Length: 2\r\n\r\n"
    shape("ok", head: plain).should eq(shape("ok", head: later))
    cookie = "HTTP/1.1 200 OK\r\nSet-Cookie: s=1\r\n\r\n"
    shape("ok", head: cookie).should_not eq(shape("ok", head: plain))
  end

  it "keys a redirect on its Location, with the payload masked out of it" do
    a = shape("", head: "HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n")
    b = shape("", head: "HTTP/1.1 302 Found\r\nLocation: /dashboard\r\n\r\n")
    a.should_not eq(b)
    open1 = shape("", "evil.example", head: "HTTP/1.1 302 Found\r\nLocation: https://evil.example/\r\n\r\n")
    open2 = shape("", "attacker.test", head: "HTTP/1.1 302 Found\r\nLocation: https://attacker.test/\r\n\r\n")
    open1.should eq(open2)
  end

  it "gives each error class its own shape, none of them an empty 200" do
    empty_ok = shape("")
    errors = [
      failed("connect: Connection refused"),
      failed("Read timed out"),
      failed("TLS handshake failed: certificate verify failed"),
      failed("Connection reset by peer"),
      failed(Gori::Outbound::SANDBOX_SWEEP_ERROR),
      failed(F::CappedBackend::CAP_ERROR),
    ]
    errors.uniq.size.should eq(errors.size)
    errors.should_not contain(empty_ok)
    # The host/port/timing in the text is not part of the key.
    failed("connect to 10.0.0.1:8080: Connection refused").should eq(failed("connect to 10.0.0.2:443: Connection refused"))
  end

  it "pins the gate and budget refusals to their classes" do
    F::Shape.error_class(Gori::Outbound::SANDBOX_SWEEP_ERROR).should eq(F::Shape::ErrorClass::Blocked)
    F::Shape.error_class(Gori::Outbound::EXCLUDE_SWEEP_ERROR).should eq(F::Shape::ErrorClass::Blocked)
    F::Shape.error_class(F::CappedBackend::CAP_ERROR).should eq(F::Shape::ErrorClass::Budget)
    F::Shape.error_class("#{F::REDIRECT_HOP_REFUSED}boom").should eq(F::Shape::ErrorClass::RedirectRefused)
    # An unsent macro row embeds the step's own failure. That wording must not file it under
    # a network class. The prefix is matched as text so `shape.cr` need not require the macro.
    Gori::RequestMacro::ERROR_PREFIX.should start_with("macro:")
    refused = "#{Gori::RequestMacro::ERROR_PREFIX}failed at step 1 (login → connection refused) — the candidate was not sent"
    F::Shape.error_class(refused).should eq(F::Shape::ErrorClass::Other)
    F::Shape.error_class("#{Gori::RequestMacro::ERROR_PREFIX}failed at step 1 (login → timed out)").should eq(F::Shape::ErrorClass::Other)
  end

  # Spans are `{start, end}` (`Template#render_spans`). Each example puts on the wire bytes the
  # generated payload is not, the way a `¦chain` does, so the span is the only needle that
  # masks them (#1422).
  it "masks exactly the spliced bytes of a position in the front half of the request" do
    raw, spans = F::Template.parse("GET /?q=§x§&tail=1 HTTP/1.1\r\nHost: t\r\n\r\n").render_spans(["WIRE"])
    needles = F::Shape.needles(F::Job.new(0_i64, ["generated"], 0, raw, spans))
    needles.should contain("WIRE".to_slice)
    needles.none? { |n| String.new(n).includes?("&tail") }.should be_true
  end

  it "masks the spliced bytes of a position in the back half of the request" do
    raw, spans = F::Template.parse("POST / HTTP/1.1\r\nHost: t\r\n\r\nq=§x§").render_spans(["WIRE"])
    F::Shape.needles(F::Job.new(0_i64, ["generated"], 0, raw, spans)).should contain("WIRE".to_slice)
  end

  it "masks the spliced bytes of a WebSocket frame position" do
    template = F::Template.parse("hello §x§ world")
    payload, spans = template.render_spans(["WIRE"])
    frame = F::WsFrame.new(1, payload, Gori::Proxy::WS::Shape::DEFAULT, payload_spans: spans)
    job = F::Job.new(0_i64, ["generated"], 0, "GET / HTTP/1.1\r\nHost: t\r\n\r\n".to_slice, ws_frames: [frame])
    needles = F::Shape.needles(job)
    needles.should contain("WIRE".to_slice)
    needles.none? { |n| String.new(n).includes?("world") }.should be_true
  end

  it "keeps echoes of a late, transformed payload in one shape" do
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
    template = F::Template.parse("POST / HTTP/1.1\r\nHost: t\r\n\r\nq=§x§")
    shapes = {"B" => "QQ==", "9" => "OQ==", "long" => "bG9uZ3Bhc3N3b3Jk"}.map do |payload, wire|
      raw, spans = template.render_spans([wire])
      job = F::Job.new(0_i64, [payload], 0, raw, spans)
      result = Gori::Repeater::Result.new(head.to_slice, "<p>You sent #{wire}</p>".to_slice,
        Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice), 1000_i64, nil, false)
      F::Matcher.new(keep_bodies: :none).build(job, result).shape
    end
    shapes.uniq.size.should eq(1)
  end

  it "ignores empty needles without crashing or changing the shape" do
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    body = "needle appears here".to_slice
    no_needles = F::Shape.compute(200_i32, nil, nil, false, false, head, body)
    empty_only = F::Shape.compute(200_i32, nil, nil, false, false, head, body, [Bytes.empty])
    mixed = F::Shape.compute(200_i32, nil, nil, false, false, head, body,
      [Bytes.empty, "needle".to_slice])
    empty_only.should eq(no_needles)
    mixed.should_not eq(no_needles)
  end

  it "separates a truncated body from a complete one" do
    shape("<p>partial").should_not eq(shape("<p>partial", incomplete: true))
    shape("<p>partial", incomplete: true).should_not eq(shape("<p>partial", incomplete: true, timed_out: true))
  end

  it "separates gRPC outcomes that share :status 200" do
    ok = "HTTP/2 200\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n\r\n"
    denied = "HTTP/2 200\r\ncontent-type: application/grpc\r\ngrpc-status: 7\r\n\r\n"
    a = row("", head: ok)
    b = row("", head: denied)
    a.grpc_status.should eq(0)
    b.grpc_status.should eq(7)
    a.shape.should_not eq(b.shape)
  end

  it "separates WebSocket close codes that share the 101 handshake" do
    base = row("hi", head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")
    normal = base.with_ws(F::WsOutcome.new(1000, 1, nil, nil))
    policy = base.with_ws(F::WsOutcome.new(1008, 1, nil, nil))
    normal.shape.should_not eq(policy.shape)
    base.with_ws(F::WsOutcome.failed).shape.should eq(base.shape)
  end

  it "reads a long body's first BODY_UNITS units, and whether it went on" do
    filler = "<p>row</p>\n" * 10_000 # ~90k units, well past the window
    base = shape("<h1>Welcome</h1>#{filler}")
    shape("<h1>Denied!!</h1>#{filler}").should_not eq(base)
    # Past the window only "the body went on" is kept: a short page with the same start differs,
    shape("<h1>Welcome</h1><p>row</p>\n").should_not eq(base)
    # but a difference far below the window does not split the answer.
    shape("<h1>Welcome</h1>#{filler}<footer>no</footer>").should eq(base)
  end

  it "keeps a long page that echoes the payload near its top in one shape" do
    # Search and result pages are the big ones, and they echo the query first.
    filler = "<p>row</p>\n" * 10_000
    shape("<h1>You searched apple</h1>#{filler}", "apple")
      .should eq(shape("<h1>You searched banana-split-sundae</h1>#{filler}", "banana-split-sundae"))
  end

  it "masks a payload echoed JSON-escaped" do
    a = shape(%({"error":"no such user: \\"o'hara\\""}), %(o'hara"))
    b = shape(%({"error":"no such user: \\"x\\" OR 1=1--\\""}), %(x" OR 1=1--"))
    a.should eq(b)
    go1 = shape(%({"q":"\\u003cscript\\u003e"}), "<script>")
    go2 = shape(%({"q":"\\u003cimg src=x\\u003e"}), "<img src=x>")
    go1.should eq(go2)
  end

  it "does not mask a payload too short to be told from the page's own text" do
    # `a` and `b` masked everywhere would make two identical bodies hash differently.
    shape("banana", "a").should eq(shape("banana", "b"))
  end

  it "is stable across processes: a fixed input has a fixed id" do
    # FNV-1a over a versioned normalization, never the per-process seeded `#hash`. A change
    # here is a change to every persisted id — bump `Shape::VERSION` with it.
    F::Shape.hex(shape("<p>hello</p>")).should eq(F::Shape.hex(shape("<p>hello</p>")))
    F::Shape.hex(shape("<p>hello</p>")).should eq("29c7a9bebbb25c1a")
  end

  it "round-trips its printed id" do
    id = shape("x")
    F::Shape.parse_hex?(F::Shape.hex(id)).should eq(id)
    F::Shape.parse_hex?("nope").should be_nil
    F::Shape.parse_hex?(F::Shape.hex(id).upcase).should eq(id)
  end
end
