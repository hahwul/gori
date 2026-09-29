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
  spans = [{"GET /?q=".bytesize, payload.bytesize}]
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

  it "reads a long body's head and tail window, and its size class" do
    filler = "<p>row</p>\n" * 10_000 # ~110 KB, past SCAN_HEAD + SCAN_TAIL
    base = shape("<h1>Welcome</h1>#{filler}<footer>ok</footer>")
    shape("<h1>Denied!!</h1>#{filler}<footer>ok</footer>").should_not eq(base)
    shape("<h1>Welcome</h1>#{filler}<footer>no</footer>").should_not eq(base)
    shape("<h1>Welcome</h1>#{filler * 3}<footer>ok</footer>").should_not eq(base)
  end

  it "does not mask a payload too short to be told from the page's own text" do
    # `a` and `b` masked everywhere would make two identical bodies hash differently.
    shape("banana", "a").should eq(shape("banana", "b"))
  end

  it "is stable across processes: a fixed input has a fixed id" do
    # FNV-1a over a versioned normalization, never the per-process seeded `#hash`. A change
    # here is a change to every persisted id — bump `Shape::VERSION` with it.
    F::Shape.hex(shape("<p>hello</p>")).should eq(F::Shape.hex(shape("<p>hello</p>")))
    F::Shape.hex(shape("<p>hello</p>")).should eq("31f349134549627f")
  end

  it "round-trips its printed id" do
    id = shape("x")
    F::Shape.parse_hex?(F::Shape.hex(id)).should eq(id)
    F::Shape.parse_hex?("nope").should be_nil
    F::Shape.parse_hex?(F::Shape.hex(id).upcase).should eq(id)
  end
end
