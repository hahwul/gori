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
    return resp(403, "forbidden") unless req.includes?("sid=abc123")         # session cookie
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

# A JSON API where every authored key EXCEPT `drop` is load-bearing — its response shrinks
# unless the body still carries `keep`, BOTH `dup` occurrences, the `\/`-escaped `path`, and
# the `1.50` number. So the minimizer keeps them and we can assert they survived byte-for-byte,
# while `drop` (which the response ignores) is removed. If the candidate splice re-encoded the
# JSON, the probe body would read `a/b`/`1.5`/one `dup` and `drop` would look load-bearing.
private class JsonByteOrigin < F::Backend
  getter origin : F::Origin = F::Origin.new("http", "h", 80)

  def send(bytes : Bytes) : Gori::Repeater::Result
    req = String.new(bytes)
    body = req.includes?("\r\n\r\n") ? req.split("\r\n\r\n", 2)[1] : ""
    full = body.includes?(%("keep")) && body.includes?(%("dup")) &&
           body.includes?("a\\/b") && body.includes?("1.50")
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
  # The TUI feeds LF editor text (`TextArea#set_text` strips CR); the CLI and MCP feed the
  # STORED bytes, which are CRLF. `split_text` only looked for `"\n\n"`, which a CRLF request
  # does not contain, so `has_body` came back false and body-param candidates were never
  # enumerated at all — the SAME session minimized further from the TUI than from
  # `gori run repeater minimize`. Every session created from a flow is CRLF.
  it "minimizes a CRLF-stored request exactly as it does the LF editor form" do
    lines = [
      "POST /api?a=1&b=2 HTTP/1.1",
      "Host: h",
      "User-Agent: Mozilla/5.0",
      "Content-Type: application/x-www-form-urlencoded",
      "Content-Length: 11",
      "",
      "x=1&y=2&z=3",
    ]
    lf = minimize(StaticOrigin.new, lines.join("\n"), auto_cl: true)
    crlf = minimize(StaticOrigin.new, lines.join("\r\n"), auto_cl: true)

    # Body params are reached at all, and both forms remove exactly the same set.
    crlf.removed.map(&.kind).should contain(Gori::Repeater::Minimize::Kind::Param)
    crlf.removed.map { |r| {r.kind, r.label} }.sort_by!(&.[1])
      .should eq(lf.removed.map { |r| {r.kind, r.label} }.sort_by!(&.[1]))
    crlf.sends.should eq(lf.sends)
  end

  it "returns the report in the line endings the caller handed in" do
    lines = ["GET /api?a=1 HTTP/1.1", "Host: h", "User-Agent: Mozilla/5.0"]
    minimize(StaticOrigin.new, lines.join("\r\n")).minimized_text.should contain("\r\n")
    minimize(StaticOrigin.new, lines.join("\n")).minimized_text.should_not contain('\r')
  end

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

  it "strips cosmetic crumbs from a SECOND Cookie header even when the first is load-bearing" do
    # HTTP/2 splits cookies across multiple `cookie` field lines (RFC 9113 §8.2.2). The crumb
    # remover used to target the FIRST Cookie header only, so once a crumb there was load-bearing
    # (keeping that header un-emptied and un-deleted, hence perpetually "first"), every crumb in a
    # later Cookie header was silently unremovable — the minimizer under-minimized and said so.
    text = [
      "GET /p HTTP/1.1",
      "Host: h",
      "X-Keep: yes",
      "Cookie: sid=abc123",      # load-bearing → header 1 is never emptied/deleted
      "Cookie: junk=1; trash=2", # cosmetic → must still be reachable and removed
    ].join("\n")

    report = minimize(FakeOrigin.new, text)
    report.aborted.should be_false
    labels = report.removed.map(&.label)
    labels.should contain("junk")
    labels.should contain("trash")
    report.minimized_text.should contain("sid=abc123")
    report.minimized_text.should_not contain("junk")
    report.minimized_text.should_not contain("trash")
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

  # The gate was `ct.includes?("application/json")`, and that substring is absent from every
  # `+json` structured-syntax type — `application/graphql+json`, `application/vnd.api+json`.
  # The content-type being non-empty, the `looks_json?` fallback did not run either, so the
  # minimizer silently skipped the body of exactly the requests worth shrinking.
  it "minimizes a body under a `+json` structured-syntax content-type" do
    text = [
      "POST /j HTTP/1.1",
      "Host: h",
      "X-Keep: yes",
      "Cookie: sid=abc123",
      "Content-Type: application/graphql+json; charset=utf-8",
      "Content-Length: 19",
      "",
      %({"keep":1,"drop":2}),
    ].join("\n")

    report = minimize(JsonOrigin.new, text, auto_cl: true)
    report.aborted.should be_false
    report.removed.map(&.label).should contain("drop")
    report.minimized_text.should contain(%("keep":1))
  end

  it "byte-splices a JSON key without re-encoding: dup keys, `\\/`, and `1.50` survive verbatim" do
    # The old `JSON.parse(body).to_json` candidate canonicalized the operator's authored bytes
    # (collapsed the duplicate `dup`, unescaped `\/`→`/`, reformatted `1.50`→`1.5`) in BOTH the
    # probe requests and `--apply`'s stored `minimized_text` — corrupting the very framing/
    # encoding a smuggling or WAF-bypass probe tests. The splice must preserve every OTHER byte.
    body = %({"keep":1,"drop":2,"dup":3,"dup":4,"path":"a\\/b","num":1.50})
    text = [
      "POST /j HTTP/1.1",
      "Host: h",
      "Content-Type: application/json",
      "Content-Length: #{body.bytesize}",
      "",
      body,
    ].join("\n")

    report = minimize(JsonByteOrigin.new, text, auto_cl: true)
    report.aborted.should be_false
    # `drop` is removed — which, since the origin only reports "full" when the probe body still
    # reads `a\/b`/`1.50`/both `dup`s, also proves the PROBE candidate kept those bytes verbatim.
    report.removed.map(&.label).should contain("drop")
    report.minimized_text.should_not contain("drop")
    # Everything load-bearing survived, byte-for-byte, in the STORED text.
    report.minimized_text.should contain(%("keep":1))
    report.minimized_text.should contain(%("dup":3)) # the duplicate key is NOT collapsed…
    report.minimized_text.should contain(%("dup":4)) # …both occurrences remain
    report.minimized_text.should contain("a\\/b")    # `\/` is NOT unescaped to `/`
    report.minimized_text.should contain("1.50")     # `1.50` is NOT reformatted to `1.5`
    # And the drop splice took its trailing comma with it, leaving valid JSON.
    report.minimized_text.should contain(%({"keep":1,"dup":3))
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

# `gori run repeater minimize --verbatim`'s resolver.
#
# `repeater send` grew `--verbatim` precisely because a session can hold EVIDENCE; minimize
# is a search over that same request and had no such knob, so a session seeded from a capture
# was either refused outright (an OData `$top` in the head) or minimized against bytes that
# differ from what `repeater send --verbatim` puts on the wire ($where substituted, the CL
# re-framed 22 → 19). The resolver is the whole difference, so it is asserted directly.
#
# The catch this exists to pin: `Minimize.run` hands its `resolve` proc the request
# LF-NORMALIZED (its text helpers are written against that form) and restores the operator's
# terminator only on the REPORT — so a resolver that simply took the bytes put a CRLF-stored
# session on the wire bare-LF, inventing the very desync primitive the flag preserves, and one
# that blindly re-CRLF'd produced `\r\r\n` on the report call.
module Gori::CLI::Run
  def self.restore_head_crlf_for_spec(text : String) : Bytes
    restore_head_crlf(text)
  end

  def self.mixed_line_endings_for_spec?(text : String) : Bool
    mixed_line_endings?(text)
  end
end

describe "gori run repeater minimize --verbatim — the resolver" do
  it "puts CRLF back on the HEAD and leaves the body byte-exact" do
    lf = "POST /bk HTTP/1.1\nHost: h\nContent-Length: 22\n\n{\"q\":\"$where 1==1 ab\"}\n"
    String.new(Gori::CLI::Run.restore_head_crlf_for_spec(lf)).should eq(
      "POST /bk HTTP/1.1\r\nHost: h\r\nContent-Length: 22\r\n\r\n{\"q\":\"$where 1==1 ab\"}\n")
  end

  it "is idempotent, so the already-restored report text does not become \\r\\r\\n" do
    crlf = "POST /bk HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi"
    String.new(Gori::CLI::Run.restore_head_crlf_for_spec(crlf)).should eq(crlf)
  end

  it "does not substitute a $KEY, and does not re-frame the Content-Length" do
    saved = Gori::Settings.env_vars
    saved_x = Gori::Settings.env_prefix
    begin
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"where", "XX"}]
      out = String.new(Gori::CLI::Run.restore_head_crlf_for_spec(
        "POST /bk HTTP/1.1\nHost: h\nContent-Length: 22\n\n{\"q\":\"$where 1==1 ab\"}\n"))
      out.should contain("$where 1==1 ab")     # the capture, not the project's value
      out.should contain("Content-Length: 22") # over a 23-byte body: the CL-desync evidence
    ensure
      Gori::Settings.env_vars = saved || [] of {String, String}
      Gori::Settings.env_prefix = saved_x || "$"
    end
  end

  describe "the mixed-terminator notice" do
    it "fires only when the HEAD really mixes CRLF and bare LF" do
      Gori::CLI::Run.mixed_line_endings_for_spec?(
        "POST /m HTTP/1.1\r\nHost: h\nX: 1\r\n\r\nhi").should be_true
    end

    it "does not fire for an all-CRLF head, an all-LF head, or a body full of LFs" do
      Gori::CLI::Run.mixed_line_endings_for_spec?("GET / HTTP/1.1\r\nHost: h\r\n\r\n").should be_false
      Gori::CLI::Run.mixed_line_endings_for_spec?("GET / HTTP/1.1\nHost: h\n\n").should be_false
      # A raw 0x0A in a BODY is a byte, not a line ending — judging the whole request would
      # flag every binary upload.
      Gori::CLI::Run.mixed_line_endings_for_spec?(
        "POST / HTTP/1.1\r\nHost: h\r\n\r\nline1\nline2\n").should be_false
    end
  end
end

# The REPORT is the third form (after "what was sent" and "what was printed"), and it is the
# one that is kept: `gori run repeater minimize --apply` and `minimize_repeater{apply:true}`
# both store `minimized_text` back over the session, and `minimized_source` /
# `minimized_request` print it.
#
# `Minimize` used to LF-normalize the whole request on the way in and blanket
# `gsub("\n", "\r\n")` it on the way out. Both halves corrupt a BODY: the way in flattened a
# multipart body's own CRLF boundaries, the way out promoted a body's bare LF, so a captured
# body ending in one came back a byte longer under a Content-Length that no longer described
# it. In a head a 0x0A is a line ending; in a body it is a byte — head-only is the rule every
# other site on this branch follows (`Env.expand_wire`, `gori run intercept edit`).
describe "Gori::Repeater::Minimize — body bytes on the round trip" do
  it "keeps a body's trailing bare LF out of the report — the CL-desync evidence" do
    text = "POST /bk HTTP/1.1\r\nHost: h\r\nUser-Agent: Mozilla/5.0\r\n" \
           "Content-Length: 22\r\n\r\n{\"q\":\"$where 1==1 ab\"}\n"
    report = minimize(StaticOrigin.new, text)
    body = report.minimized_text.split("\r\n\r\n", 2)[1]
    body.should eq("{\"q\":\"$where 1==1 ab\"}\n") # 23 bytes, exactly as handed in
    body.should_not contain("\r\n")
    # The head is still restored to the terminator the caller used.
    report.minimized_text.should start_with("POST /bk HTTP/1.1\r\nHost: h\r\n")
    # ...and the cosmetic header really was removed, so this is the minimize path, not a
    # short-circuit through the "nothing removable" branch.
    report.removed.map(&.label).should contain("User-Agent")
  end

  it "keeps a multipart body's OWN CRLF boundaries intact" do
    body = "--B\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--B--\r\n"
    text = "POST /up HTTP/1.1\r\nHost: h\r\nUser-Agent: Mozilla/5.0\r\n" \
           "Content-Type: multipart/form-data; boundary=B\r\n" \
           "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    report = minimize(StaticOrigin.new, text)
    report.minimized_text.split("\r\n\r\n", 2)[1].should eq(body)
  end

  it "leaves a binary body byte-for-byte, including a lone CR and a NUL" do
    body = String.new(Bytes[0x0A, 0x00, 0x0D, 0xEF, 0x0A])
    text = "POST /b HTTP/1.1\r\nHost: h\r\nAccept: */*\r\nContent-Length: 5\r\n\r\n#{body}"
    report = minimize(StaticOrigin.new, text)
    report.minimized_text.to_slice[-5..].to_a.should eq([0x0A, 0x00, 0x0D, 0xEF, 0x0A])
  end

  it "asks about the HEAD's terminators, not a CRLF that only appears in the body" do
    text = "POST /b HTTP/1.1\nHost: h\nAccept: */*\n\nline1\r\nline2"
    report = minimize(StaticOrigin.new, text)
    # An LF head stays an LF head even though the body carries a CRLF pair.
    report.minimized_text.split("\n\n", 2)[0].should_not contain('\r')
    report.minimized_text.should end_with("line1\r\nline2")
  end
end
