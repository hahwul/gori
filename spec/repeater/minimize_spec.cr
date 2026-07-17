require "../spec_helper"

private alias Min = Gori::Repeater::Minimize
private alias F = Gori::Fuzz

# A fake origin whose response depends on which request items are present, so the
# minimizer can discover which are load-bearing vs cosmetic:
#   - session cookie `sid`   REQUIRED → absent ⇒ 403 (status change)
#   - custom header `X-Keep` REQUIRED → absent ⇒ 400 (status change)
#   - param `id` / `keep`    REQUIRED → absent ⇒ a shorter body (length change)
#   - everything else (User-Agent, Accept-*, Sec-*, `theme` cookie, `utm_*`) is cosmetic.
private class FakeOrigin < F::Backend
  getter origin : F::Origin
  getter sent = 0

  def initialize(@origin : F::Origin = F::Origin.new("http", "h", 80))
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    req = String.new(bytes)
    reqline = req.lines.first? || ""
    body = req.includes?("\r\n\r\n") ? req.split("\r\n\r\n", 2)[1] : ""
    return resp(403, "forbidden") unless req.includes?("sid=abc123")     # session cookie
    return resp(400, "bad request") unless req.downcase.includes?("x-keep:") # required header
    # `id` (query) / `keep` (body) are the load-bearing params — checked WHERE they live so
    # the `sid=` cookie's "id=" substring can't masquerade as the query param.
    has_param = reqline.includes?("id=") || body.includes?("keep=")
    resp(200, has_param ? "the full user record body goes here" : "short")
  end

  private def resp(status : Int32, body : String) : Gori::Repeater::Result
    head = "HTTP/1.1 #{status} MSG\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    r = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, r, 1000_i64)
  end
end

# Returns a byte-identical response no matter what the request contains — so the minimizer
# will strip everything it is ALLOWED to. Used to prove the protected headers still survive.
private class StaticOrigin < F::Backend
  getter origin : F::Origin = F::Origin.new("http", "h", 80)

  def send(bytes : Bytes) : Gori::Repeater::Result
    head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
    r = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, "ok".to_slice, r, 1000_i64)
  end
end

# Baseline status flaps between calls — a non-deterministic origin the minimizer must
# refuse to work against.
private class FlappyOrigin < F::Backend
  getter origin : F::Origin = F::Origin.new("http", "h", 80)
  @n = 0

  def send(bytes : Bytes) : Gori::Repeater::Result
    @n += 1
    status = @n.odd? ? 200 : 500
    head = "HTTP/1.1 #{status} X\r\nContent-Length: 2\r\n\r\n".to_slice
    r = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, "hi".to_slice, r, 1000_i64)
  end
end

# A JSON API where the `keep` key is load-bearing (its absence shrinks the body).
private class JsonOrigin < F::Backend
  getter origin : F::Origin = F::Origin.new("http", "h", 80)

  def send(bytes : Bytes) : Gori::Repeater::Result
    req = String.new(bytes)
    body = req.includes?("\r\n\r\n") ? req.split("\r\n\r\n", 2)[1] : ""
    full = body.includes?("\"keep\"")
    payload = full ? "the full record body goes here" : "short"
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{payload.bytesize}\r\n\r\n".to_slice
    r = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, payload.to_slice, r, 1000_i64)
  end
end

# Every send errors (unreachable origin).
private class DeadOrigin < F::Backend
  getter origin : F::Origin = F::Origin.new("http", "h", 80)

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connect failed")
  end
end

# LF→CRLF wire form; the fake origins don't validate Content-Length, so no resync needed.
private RESOLVE = ->(t : String) { t.gsub("\n", "\r\n").to_slice }

private def minimize(backend : F::Backend, text : String, auto_cl : Bool = false) : Min::Report
  Min.run(text, auto_cl: auto_cl, resolve: RESOLVE, backend: backend) { |_| }
end

describe Gori::Repeater::Minimize do
  it "drops cosmetic headers, cookie crumbs and query params but keeps load-bearing ones" do
    text = [
      "GET /api?id=5&utm_source=nl HTTP/1.1",
      "Host: h",
      "User-Agent: Mozilla/5.0",
      "Accept-Encoding: gzip, deflate",
      "Accept-Language: en-US",
      "Sec-Fetch-Mode: cors",
      "X-Keep: yes",
      "Cookie: sid=abc123; theme=dark",
    ].join("\n")

    report = minimize(FakeOrigin.new, text)
    report.aborted.should be_false
    m = report.minimized_text

    # load-bearing items survive
    m.should contain("Host: h")
    m.should contain("X-Keep: yes")
    m.should contain("sid=abc123")
    m.should contain("id=5")
    # cosmetic items are stripped
    m.should_not contain("User-Agent")
    m.should_not contain("Accept-Encoding")
    m.should_not contain("Accept-Language")
    m.should_not contain("Sec-Fetch-Mode")
    m.should_not contain("theme=dark")
    m.should_not contain("utm_source")

    labels = report.removed.map(&.label)
    labels.should contain("theme")
    labels.should contain("utm_source")
    labels.should_not contain("sid")
    report.sends.should be > 0
  end

  it "removes an unused body param and re-lengths, keeping a load-bearing one (auto-CL on)" do
    text = [
      "POST /submit HTTP/1.1",
      "Host: h",
      "X-Keep: yes",
      "Cookie: sid=abc123",
      "Content-Type: application/x-www-form-urlencoded",
      "Content-Length: 13",
      "",
      "keep=1&drop=2",
    ].join("\n")

    report = minimize(FakeOrigin.new, text, auto_cl: true)
    report.aborted.should be_false
    report.minimized_text.should contain("keep=1")
    report.minimized_text.should_not contain("drop=2")
    report.removed.map(&.label).should contain("drop")
  end

  it "removes an unused top-level JSON key, keeping a load-bearing one" do
    text = [
      "POST /j HTTP/1.1",
      "Host: h",
      "X-Keep: yes",
      "Cookie: sid=abc123",
      "Content-Type: application/json",
      "Content-Length: 19",
      "",
      %({"keep":1,"drop":2}),
    ].join("\n")

    report = minimize(JsonOrigin.new, text, auto_cl: true)
    report.aborted.should be_false
    report.minimized_text.should contain(%("keep":1))
    report.minimized_text.should_not contain("drop")
    report.removed.map(&.label).should contain("drop")
  end

  it "leaves body params alone when Auto-Content-Length is off (can't safely re-length)" do
    text = [
      "POST /submit HTTP/1.1",
      "Host: h",
      "X-Keep: yes",
      "Cookie: sid=abc123",
      "Content-Type: application/x-www-form-urlencoded",
      "",
      "keep=1&drop=2",
    ].join("\n")

    report = minimize(FakeOrigin.new, text, auto_cl: false)
    report.minimized_text.should contain("drop=2") # untouched — no body-param candidates
  end

  it "never removes the Host header, even when the response never changes" do
    text = [
      "GET /api?id=5 HTTP/1.1",
      "Host: keep.example",
      "User-Agent: x",
      "Accept-Encoding: gzip",
    ].join("\n")

    report = minimize(StaticOrigin.new, text) # identical response ⇒ strips everything allowed
    report.aborted.should be_false
    report.minimized_text.should contain("Host: keep.example")
    report.removed.map(&.label).map(&.downcase).should_not contain("host")
    # everything the minimizer IS allowed to drop is gone
    report.minimized_text.should_not contain("User-Agent")
    report.minimized_text.should_not contain("Accept-Encoding")
    report.minimized_text.should_not contain("id=5")
  end

  it "reports nothing removable (0 sends) when there are no candidates" do
    text = ["GET / HTTP/1.1", "Host: h", "Authorization: Bearer tok"].join("\n")
    report = minimize(FakeOrigin.new, text)
    report.aborted.should be_false
    report.removed.should be_empty
    report.sends.should eq(0)
    report.minimized_text.should eq(text)
  end

  it "aborts, leaving the request untouched, when the baseline status is unstable" do
    text = ["GET / HTTP/1.1", "Host: h", "User-Agent: x"].join("\n")
    report = minimize(FlappyOrigin.new, text)
    report.aborted.should be_true
    report.removed.should be_empty
    report.minimized_text.should eq(text)
  end

  it "aborts when the origin is unreachable" do
    text = ["GET / HTTP/1.1", "Host: h", "User-Agent: x"].join("\n")
    report = minimize(DeadOrigin.new, text)
    report.aborted.should be_true
    report.minimized_text.should eq(text)
  end

  it "returns a partial result (never over-sends) once the send cap is hit" do
    text = [
      "GET / HTTP/1.1", "Host: h",
      "User-Agent: a", "Accept-Encoding: b", "Accept-Language: c", "Sec-Fetch-Mode: d",
    ].join("\n")
    capped = F::CappedBackend.new(FakeOrigin.new, 3_i64) # 3 calibration sends, then no budget
    report = Min.run(text, auto_cl: false, resolve: RESOLVE, backend: capped) { |_| }
    report.note.should contain("cap")
    capped.sent.should eq(3)
  end
end
