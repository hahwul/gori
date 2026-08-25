require "../spec_helper"
require "../../src/gori/authorize/engine"
require "../../src/gori/cli/output"

private alias Identity = Gori::Authorize::Identity
private alias Verdict = Gori::Authorize::Verdict

# A send backend that answers from a table keyed by a marker substring found in the request
# bytes (each identity stamps a distinctive `X-Id:` header; the baseline carries none, so it
# maps to "*"). Order-independent and explicit about which identity gets which response.
private class FakeBackend < Gori::Fuzz::Backend
  getter sent = [] of Bytes

  def initialize(@responses : Hash(String, Gori::Repeater::Result), @origin : Gori::Fuzz::Origin)
  end

  def origin : Gori::Fuzz::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes
    text = String.new(bytes)
    key = @responses.keys.find { |k| k != "*" && text.includes?(k) } || "*"
    @responses[key]
  end
end

private def ok_resp(status : Int32, body : String) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/plain\r\n\r\n".to_slice
  Gori::Repeater::Result.new(head, body.to_slice, nil, 1_000_i64)
end

private def err_resp : Gori::Repeater::Result
  Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "connection refused")
end

private def detail : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", "GET", "api.example.com", 443,
    "/admin", 200, 100_i64, Gori::Store::FlowState::Complete)
  head = "GET /admin HTTP/1.1\r\nHost: api.example.com\r\nCookie: session=ADMIN\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

private def engine(responses : Hash(String, Gori::Repeater::Result)) : Gori::Authorize::Engine
  origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
  fake = FakeBackend.new(responses, origin)
  Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
end

describe Gori::Authorize::Engine do
  it "judges a low-priv identity that sees baseline content as Same (a likely bypass)" do
    dashboard = "the full admin dashboard with billing and every user record and control panel here"
    responses = {
      "*"          => ok_resp(200, dashboard), # baseline (as-captured admin session)
      "X-Id: user" => ok_resp(200, dashboard), # low-priv sees the SAME page → bypass
      "X-Id: anon" => ok_resp(403, "Forbidden"),
    }
    ids = [
      Identity.new("admin", baseline: true),
      Identity.new("user", set_headers: [{"X-Id", "user"}, {"Cookie", "session=USER"}]),
      Identity.new("anon", remove_headers: ["Cookie"], set_headers: [{"X-Id", "anon"}]),
    ]
    target = engine(responses).run(detail, ids).not_nil!

    target.trials.size.should eq(3)
    target.trials[0].identity.should eq("admin")
    target.trials[0].verdict.should eq(Verdict::Baseline)
    target.trials[0].delta.should be_nil

    user = target.trials.find { |t| t.identity == "user" }.not_nil!
    user.verdict.should eq(Verdict::Same)
    user.delta.should_not be_nil

    anon = target.trials.find { |t| t.identity == "anon" }.not_nil!
    anon.verdict.should eq(Verdict::Different)

    target.same_count.should eq(1)
  end

  it "reports a send failure for that identity as Error without aborting the run" do
    responses = {
      "*"          => ok_resp(200, "baseline body content that is perfectly fine and served here"),
      "X-Id: user" => err_resp,
    }
    ids = [
      Identity.new("admin", baseline: true),
      Identity.new("user", set_headers: [{"X-Id", "user"}]),
    ]
    target = engine(responses).run(detail, ids).not_nil!
    user = target.trials.find { |t| t.identity == "user" }.not_nil!
    user.verdict.should eq(Verdict::Error)
  end

  # REGRESSION: a flow captured through the proxy stores an ABSOLUTE-FORM request line. Sent
  # verbatim to an origin dialed directly, that whole URL reads as the path, so every identity
  # gets the origin's catch-all page and the verdicts describe a request nobody made. Caught in
  # a live run where a properly-protected /orders came back "same" for the anonymous identity.
  it "rewrites an absolute-form request line to origin-form before sending" do
    row = Gori::Store::FlowRow.new(1_i64, 0_i64, "http", "GET", "127.0.0.1", 19311,
      "http://127.0.0.1:19311/orders", 200, 100_i64, Gori::Store::FlowState::Complete)
    head = "GET http://127.0.0.1:19311/orders HTTP/1.1\r\nHost: 127.0.0.1:19311\r\nCookie: s=1\r\n\r\n".to_slice
    captured = Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)

    origin = Gori::Fuzz::Origin.new("http", "127.0.0.1", 19311)
    fake = FakeBackend.new({"*" => ok_resp(200, "ok")}, origin)
    eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
    eng.run(captured, [Identity.as_captured, Identity.new("anon", remove_headers: ["Cookie"])])

    fake.sent.size.should eq(2)
    fake.sent.each do |bytes|
      String.new(bytes).lines.first.should eq("GET /orders HTTP/1.1")
    end
    # and the overlay still applied on top of the rewritten line
    String.new(fake.sent[1]).includes?("Cookie:").should be_false
  end

  it "anchors on the first identity when none is marked baseline" do
    responses = {"*" => ok_resp(200, "some page")}
    target = engine(responses).run(detail, [Identity.new("only")]).not_nil!
    target.trials.size.should eq(1)
    target.trials[0].baseline?.should be_true
    target.baseline.should_not be_nil
  end

  # A run that compared NOTHING must not be readable as a run that found nothing. Every
  # surface builds its headline out of `same_count` and the review tally, both of which are
  # zero when every send failed — so the fact has to live on the Target itself.
  describe "a request nothing answered" do
    it "is `uncompared?` when every non-baseline send errored" do
      responses = {"*" => ok_resp(200, "page"), "X-Id: anon" => err_resp}
      target = engine(responses).run(detail, [
        Identity.new("admin", baseline: true),
        Identity.new("anon", set_headers: [{"X-Id", "anon"}]),
      ]).not_nil!
      target.uncompared?.should be_true
      target.unanswered?.should be_true
      target.same_count.should eq(0) # …which is why the count alone reads as "enforced"
      Gori::CLI::Output.authorize_verdict(target).should eq(:error)
    end

    it "is not `uncompared?` while one identity still answered" do
      responses = {
        "*"          => ok_resp(200, "page"),
        "X-Id: anon" => err_resp,
        "X-Id: user" => ok_resp(403, "no"),
      }
      target = engine(responses).run(detail, [
        Identity.new("admin", baseline: true),
        Identity.new("anon", set_headers: [{"X-Id", "anon"}]),
        Identity.new("user", set_headers: [{"X-Id", "user"}]),
      ]).not_nil!
      target.uncompared?.should be_false
      target.unanswered?.should be_false
    end

    # The gate refusing to send is the more specific fact, and the one an operator fixes with
    # a scope rule rather than a route — so `fully_blocked?` keeps it and `unanswered?` yields.
    it "defers to fully_blocked? when the refusal came from the gate" do
      trials = [] of Gori::Authorize::Trial
      blocked = Gori::Authorize::Target.new(1_i64, "GET", "https://acme.test/a", trials, 2_i64, "sandbox")
      blocked.fully_blocked?.should be_true
      blocked.unanswered?.should be_false
    end
  end

  # An identity IS a `SessionSlot`, and a run whose set claims no baseline gets one PROMOTED.
  it "promotes the first identity when nothing claims the baseline" do
    responses = {"*" => ok_resp(200, "page")}
    ids = [Identity.new("admin", set_headers: [{"Cookie", "session=A"}], rules: ["SESSION"]),
           Identity.new("anon", remove_headers: ["Cookie"])]
    target = engine(responses).run(detail, ids).not_nil!
    target.trials[0].identity.should eq("admin")
    target.trials[0].baseline?.should be_true
    ids[0].baseline?.should be_false # the caller's list is not mutated
  end

  # …and a SOURCE guard for what that promotion must not lose. `Trial` carries the identity's
  # NAME and nothing else, so no behavioural assertion here can see `rules` — the field that
  # decides which binding table this identity's `$NAME` resolves out of, and which a
  # hand-rolled `Identity.new(name, set, remove, baseline: true)` drops in silence. The same
  # copy-by-hand bug hit the TUI form (`AuthorizeController#apply_identity`); the rule is that
  # the struct owns its copies, so a sixth field cannot be forgotten in either place.
  #
  # The rule is about COPYING an operator's identity, which is why the pattern is `Identity.new`
  # carrying a `baseline:` — every hand-rolled copy in this engine is one that moves the flag.
  # A literal overlay built from nothing (`drop_cache_validators`' header-strip slot) copies no
  # operator field and cannot drop one; it is not what this guards against.
  it "copies a slot through with_baseline rather than rebuilding it field by field" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "authorize", "engine.cr"))
    src.should_not match(/Identity\.new\([^\n]*baseline:/)
    src.should contain("with_baseline(true)")
  end

  # A stop has to land BETWEEN IDENTITIES, not only between requests: with several identities
  # configured, honouring it only at the request boundary still puts the remaining identities'
  # requests on a target the operator asked gori to leave alone (P4).
  describe "the stop predicate" do
    it "sends no further identities once it fires, and claims no Target" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "page")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      ids = [Identity.new("a", baseline: true), Identity.new("b"), Identity.new("c")]

      # Stop after the first identity has gone out.
      sent = 0
      result = eng.run(detail, ids, -> { (sent += 1) > 1 })

      fake.sent.size.should eq(1) # b and c never left
      result.should be_nil        # a partial run must not claim a verdict
    end

    it "returns the Target normally when it never fires" do
      responses = {"*" => ok_resp(200, "page")}
      target = engine(responses).run(detail, [Identity.new("only")], -> { false }).not_nil!
      target.trials.size.should eq(1)
    end

    it "still completes when the predicate only fires after the last identity" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "page")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      polls = 0
      target = eng.run(detail, [Identity.new("a", baseline: true), Identity.new("b")],
        -> { (polls += 1) > 2 })
      fake.sent.size.should eq(2)
      target.should_not be_nil # every identity ran, so the result stands
    end
  end
end

# A captured flow with arbitrary head bytes — the conditional-GET headers a browser capture
# almost always carries are the point of the block below.
private def detail_with(method : String, extra : String) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", method, "api.example.com", 443,
    "/report", 200, 100_i64, Gori::Store::FlowState::Complete)
  head = "#{method} /report HTTP/1.1\r\nHost: api.example.com\r\nCookie: session=ADMIN\r\n#{extra}\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

private def head_resp(status : Int32, extra : String) : Gori::Repeater::Result
  Gori::Repeater::Result.new("HTTP/1.1 #{status} X\r\n#{extra}\r\n".to_slice, nil, nil, 1_000_i64)
end

# A server that evaluates the conditional request headers for real, in RFC 9110 §13.2.2 order,
# so the specs below can watch what a REPLAY of them actually asks.
#
# The one property that makes any of this matter: the ETag is PER-IDENTITY. That is not exotic
# — it is what any resource rendered per role, or cached per session, or tagged `W/"<user>-<mtime>"`
# already does — and it is the whole reason a conditional header cannot be replayed under
# several identities and still be asking one question. The BODY here is identical for everyone
# (this endpoint leaks: the bypass the run is supposed to find), so every difference the specs
# below observe is manufactured by the precondition and by nothing else.
private class ConditionalOrigin < Gori::Fuzz::Backend
  getter sent = [] of Bytes

  ENTITY = "the full salary export for every employee rendered in this response body here"

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def origin : Gori::Fuzz::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes
    text = String.new(bytes)
    etag = text.includes?("Cookie: session=ADMIN") ? "\"v1\"" : "\"v2\""

    if m = req_header(text, "If-Match")
      return ok_resp(412, "precondition failed") unless m == "*" || m == etag
    end
    if inm = req_header(text, "If-None-Match")
      return Gori::Repeater::Result.new(
        "HTTP/1.1 304 Not Modified\r\nETag: #{etag}\r\n\r\n".to_slice, nil, nil, 1_000_i64
      ) if inm == "*" || inm == etag
    end
    if rng = req_header(text, "Range")
      # §13.1.5: an If-Range whose validator no longer matches makes the server IGNORE the
      # Range and send the whole entity — the 206-vs-200 split, decided per identity.
      ifr = req_header(text, "If-Range")
      return ok_resp(200, ENTITY) if ifr && ifr != etag
      from = rng.lchop("bytes=").split('-').first.to_i
      return ok_resp(206, ENTITY[from..]? || "")
    end
    ok_resp(200, ENTITY)
  end

  private def req_header(text : String, name : String) : String?
    text.each_line do |ln|
      ci = ln.index(':')
      next unless ci
      return ln[(ci + 1)..].strip.presence if ln[0, ci].strip.downcase == name.downcase
    end
    nil
  end
end

private def conditional_engine(fake : ConditionalOrigin) : Gori::Authorize::Engine
  Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
end

# ── conditional GET ─────────────────────────────────────────────────────────────────────
#
# Replaying `If-None-Match` verbatim asks a question about a CACHE, not about access control:
# the baseline revalidates into a bodyless 304 while an identity whose ETag the capture never
# held is handed the whole entity. Same request, opposite answers, for a reason that has
# nothing to do with authorization — and the row read `Different`, so a run in which an
# anonymous client walked off with the response aggregated to `enforced`.
describe Gori::Authorize::Engine do
  describe "conditional headers" do
    it "drops If-None-Match / If-Modified-Since from a safe request's replay" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "page content here for both identities alike")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      seed = detail_with("GET", "If-None-Match: \"v1\"\r\nIf-Modified-Since: Mon, 01 Jan 2024 00:00:00 GMT\r\n")

      eng.run(seed, [Identity.new("a", baseline: true), Identity.new("b", remove_headers: ["Cookie"])])

      fake.sent.size.should eq(2)
      fake.sent.each do |bytes|
        text = String.new(bytes)
        text.downcase.should_not contain("if-none-match")
        text.downcase.should_not contain("if-modified-since")
        text.should contain("Host: api.example.com") # nothing else moved
      end
      # …and the drop is on the SHARED base, so the baseline asks the identical unconditional
      # question rather than being the only row that revalidated.
      String.new(fake.sent[0]).should contain("Cookie: session=ADMIN")
    end

    # On an unsafe method these are PRECONDITIONS, not cache hints: `If-None-Match: *` on a PUT
    # means "create only if absent". Dropping one turns a refused write into a real one, once
    # per identity. --unsafe-methods already replays side effects; it must not disarm them too.
    it "keeps them on an unsafe method, where they guard the write" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "written")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      seed = detail_with("PUT", "If-None-Match: *\r\n")

      eng.run(seed, [Identity.new("a", baseline: true), Identity.new("b", remove_headers: ["Cookie"])])

      fake.sent.each { |bytes| String.new(bytes).should contain("If-None-Match: *") }
    end

    # END TO END for the false negative this fixes: with the validator gone, both identities
    # get the same 200 page and the anonymous row is the BYPASS it always was. (With it in
    # place the baseline came back 304 and the row read `different` → `enforced`.)
    it "lets a real bypass through where the conditional GET hid it as enforced" do
      page = "the full salary export for every employee rendered in this response body here"
      responses = {
        "*"          => ok_resp(200, page),
        "X-Id: anon" => ok_resp(200, page),
      }
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new(responses, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      seed = detail_with("GET", "If-None-Match: \"v1\"\r\n")

      target = eng.run(seed, [
        Identity.new("as-captured", baseline: true),
        Identity.new("anonymous", remove_headers: ["Cookie"], set_headers: [{"X-Id", "anon"}]),
      ]).not_nil!

      target.same_count.should eq(1)
      Gori::CLI::Output.authorize_verdict(target).should eq(:bypass)
    end

    # The other THREE. `If-None-Match`/`If-Modified-Since` are the pair a browser sends, so
    # they were the pair the strip started with — but every conditional header hands the
    # server a precondition, and the split this drop exists to remove is a property of the
    # precondition and not of which two headers a browser happens to like.
    it "drops If-Match / If-Unmodified-Since / If-Range too, and keeps Range" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "page content here for both identities alike")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      seed = detail_with("GET",
        "If-Match: \"v1\"\r\nIf-Unmodified-Since: Mon, 01 Jan 2024 00:00:00 GMT\r\n" \
        "Range: bytes=1024-\r\nIf-Range: \"v1\"\r\n")

      eng.run(seed, [Identity.new("a", baseline: true), Identity.new("b", remove_headers: ["Cookie"])])

      fake.sent.size.should eq(2)
      fake.sent.each do |bytes|
        text = String.new(bytes).downcase
        text.should_not contain("if-match")
        text.should_not contain("if-unmodified-since")
        text.should_not contain("if-range")
        # …and `Range` SURVIVES. It is not conditional: every identity carries the identical
        # one off the shared base, so it cannot make two of them disagree for a reason that is
        # not authorization. Dropping it would pull the whole entity once per identity on
        # exactly the captures that carry one.
        text.should contain("range: bytes=1024-")
      end
    end

    # END TO END for `If-Range`, against an origin that evaluates it. A resumed download's
    # capture carries `Range` + `If-Range`, the recorded validator still matches the ADMIN
    # rendering and no longer matches the anonymous one, so the server honours the range for
    # the baseline (`206`, 17 bytes) and IGNORES it for the identity under test (`200`, the
    # whole entity) — RFC 9110 §13.1.5, working exactly as specified. Both are 2xx, so the
    # judge falls to the body, the two sizes are nowhere near each other, and the row reads
    # `review`: a run whose answer was decided by a precondition, over an endpoint that handed
    # its salary export to an anonymous client.
    it "stops If-Range deciding the run, and the surviving Range still asks for the range" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = ConditionalOrigin.new(origin)
      seed = detail_with("GET", "Range: bytes=60-\r\nIf-Range: \"v1\"\r\n")

      target = conditional_engine(fake).run(seed, [
        Identity.new("as-captured", baseline: true),
        Identity.new("anonymous", remove_headers: ["Cookie"]),
      ]).not_nil!

      # Both identities got the SAME 17-byte tail, which is the honest answer: the endpoint
      # does not enforce anything. (With `If-Range` replayed: 206/17 against 200/77 → review.)
      target.trials.map(&.summary.status).should eq([206, 206])
      target.trials.map(&.summary.size).should eq([17_i64, 17_i64])
      target.same_count.should eq(1)
      Gori::CLI::Output.authorize_verdict(target).should eq(:bypass)

      # 206 on BOTH rows is the assertion that pins the design decision above: had `Range`
      # gone out with `If-Range`, every row here would read 200 and the full 77-byte entity.
      fake.sent.each { |b| String.new(b).should contain("Range: bytes=60-") }
    end

    # END TO END for `If-Match`, the same origin. The captured validator matches the ADMIN
    # rendering and not the anonymous one, so replaying it answers the identity under test
    # `412 Precondition Failed` — 4xx against the baseline's 2xx, which is the exact shape a
    # working access control makes. The run called it `enforced` about an endpoint that serves
    # the export to anyone who asks unconditionally. (Mirror the ETags and it lands on
    # `review` instead, by the one-directional 2xx rule; neither answer is about authorization.)
    it "stops If-Match reporting a precondition as enforcement" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = ConditionalOrigin.new(origin)
      seed = detail_with("GET", "If-Match: \"v1\"\r\n")

      target = conditional_engine(fake).run(seed, [
        Identity.new("as-captured", baseline: true),
        Identity.new("anonymous", remove_headers: ["Cookie"]),
      ]).not_nil!

      target.trials.map(&.summary.status).should eq([200, 200])
      target.same_count.should eq(1)
      Gori::CLI::Output.authorize_verdict(target).should eq(:bypass)
    end

    # The unsafe half of the widening. `If-Match` on a DELETE is the lost-update guard in its
    # textbook form — "delete this only if it is still the thing I read" — and stripping it
    # turns a delete the server would have REFUSED into one it performs, once per identity.
    it "keeps all five on an unsafe method, where they guard the write" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(204, "")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      seed = detail_with("DELETE", "If-Match: \"v1\"\r\nIf-Unmodified-Since: Mon, 01 Jan 2024 00:00:00 GMT\r\n")

      eng.run(seed, [Identity.new("a", baseline: true), Identity.new("b", remove_headers: ["Cookie"])])

      fake.sent.size.should eq(2)
      fake.sent.each do |bytes|
        text = String.new(bytes)
        text.should contain("If-Match: \"v1\"")
        text.should contain("If-Unmodified-Since: Mon, 01 Jan 2024 00:00:00 GMT")
      end
    end
  end

  # ── HEAD ──────────────────────────────────────────────────────────────────────────────
  #
  # A HEAD reply never carries a body, so "both bodies were empty" is true of every pair of
  # them. The engine has to say which method it replayed, or the judge cannot tell that
  # emptiness apart from a genuine empty entity. HEAD is in `Passive::SAFE_METHODS`, so this
  # is what passive replay does unattended.
  describe "a HEAD replay" do
    it "is not a bypass just because neither reply had a body" do
      responses = {
        "*"          => head_resp(200, "Content-Length: 4096\r\n"),
        "X-Id: anon" => head_resp(200, "Content-Length: 12\r\n"), # a different resource
      }
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new(responses, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })

      target = eng.run(detail_with("HEAD", ""), [
        Identity.new("as-captured", baseline: true),
        Identity.new("anonymous", remove_headers: ["Cookie"], set_headers: [{"X-Id", "anon"}]),
      ]).not_nil!

      target.same_count.should eq(0)
      Gori::CLI::Output.authorize_verdict(target).should eq(:review)
    end

    it "is a bypass when both replies describe the SAME entity" do
      responses = {
        "*"          => head_resp(200, "Content-Length: 4096\r\n"),
        "X-Id: anon" => head_resp(200, "Content-Length: 4096\r\n"),
      }
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new(responses, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })

      target = eng.run(detail_with("HEAD", ""), [
        Identity.new("as-captured", baseline: true),
        Identity.new("anonymous", remove_headers: ["Cookie"], set_headers: [{"X-Id", "anon"}]),
      ]).not_nil!

      target.same_count.should eq(1)
    end
  end

  # ── one baseline, always ──────────────────────────────────────────────────────────────
  describe "a set where two identities claim the baseline" do
    it "demotes the second, so the run still compares something" do
      responses = {"*" => ok_resp(200, "the same page served to everyone who asks for it here")}
      ids = [Identity.new("a", baseline: true),
             Identity.new("b", baseline: true, remove_headers: ["Cookie"])]
      target = engine(responses).run(detail, ids).not_nil!

      target.trials.map(&.baseline?).should eq([true, false])
      target.uncompared?.should be_false
      ids[1].baseline?.should be_true # the caller's own list is untouched
    end
  end

  # `uncompared?` is an exclusive split — a request either produced a comparison or it did not
  # — so it is decided by the SUM of the comparisons and not by first counting rows. With NO
  # non-baseline trial there are zero comparisons and zero rows, and the row count answered
  # "false": MCP's headline then fell past every arm to `enforced`, the strongest clean bill of
  # health this tool gives, for a request that compared nothing at all.
  describe "Target#uncompared?" do
    it "is true when there is no non-baseline trial at all" do
      responses = {"*" => ok_resp(200, "a page")}
      target = engine(responses).run(detail, [Identity.new("only", baseline: true)]).not_nil!
      target.trials.size.should eq(1)
      target.uncompared?.should be_true
      target.unanswered?.should be_true
      Gori::CLI::Output.authorize_verdict(target).should eq(:error)
    end
  end
end

# The strip runs on EVERY safe-method replay, so a request carrying no validator must come out
# byte for byte the way it went in — mixed CRLF/LF framing and a body that is not valid UTF-8
# included. The overlay path rebuilds the head from split lines, and "no such header" has to be
# a true no-op or the tool would be reframing captures on its way to the wire.
describe Gori::Authorize::Engine do
  it "leaves a request with no cache validator untouched, byte for byte" do
    io = IO::Memory.new
    io << "GET /p HTTP/1.1\r\nHost: api.example.com\nX-Weird: \xff\xfe\r\nCookie: s=1\r\n\r\n"
    io.write(Bytes[0xff, 0x00, 0xfe, 0x41])
    wire = io.to_slice

    row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", "GET", "api.example.com", 443,
      "/p", 200, 100_i64, Gori::Store::FlowState::Complete)
    seed = Gori::Store::FlowDetail.new(row, "HTTP/1.1", wire[0, wire.size - 4], wire[(wire.size - 4)..],
      nil, nil)

    origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
    fake = FakeBackend.new({"*" => ok_resp(200, "page")}, origin)
    eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
    eng.run(seed, [Identity.as_captured])

    fake.sent[0].should eq(wire)
  end
end
