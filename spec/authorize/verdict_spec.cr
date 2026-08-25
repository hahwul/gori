require "../spec_helper"
require "../../src/gori/authorize/verdict"

private alias Summary = Gori::Authorize::ResponseSummary
private alias Verdict = Gori::Authorize::Verdict
private alias Judge = Gori::Authorize::Judge
private alias FP = Gori::Discover::Fingerprint

# A summary with a fingerprint derived from real text, so distance/size are consistent.
private def summary(status : Int32?, text : String, error : String? = nil) : Summary
  return Summary.new(status, nil, 0_u64, error: error) if error
  body = text.to_slice
  Summary.new(status, body.size.to_i64, FP.simhash(body))
end

# A redirect: same shape as `summary`, plus the header that carries its whole meaning.
private def redirect(status : Int32, location : String, text : String = "") : Summary
  body = text.to_slice
  Summary.new(status, body.size.to_i64, FP.simhash(body), location: location)
end

describe Gori::Authorize::Judge do
  it "is Same when status class and content match the baseline" do
    doc = "Welcome admin, here is the full account dashboard with every setting exposed"
    base = summary(200, doc)
    other = summary(200, doc)
    Judge.verdict(base, other).should eq(Verdict::Same)
  end

  it "treats id/date-only differences as Same content (SimHash skips dynamic tokens)" do
    base = summary(200, "Welcome user 12345 on 2021-01-01 to the account dashboard overview panel here")
    other = summary(200, "Welcome user 98765 on 2024-09-09 to the account dashboard overview panel here")
    Judge.verdict(base, other).should eq(Verdict::Same)
  end

  it "is Different when the status class changes (200 baseline vs 403)" do
    base = summary(200, "the full admin dashboard content served to a privileged session here")
    other = summary(403, "Forbidden")
    Judge.verdict(base, other).should eq(Verdict::Different)
  end

  it "is Different for a redirect where the baseline served content" do
    base = summary(200, "the full admin dashboard content served to a privileged session here")
    other = summary(302, "")
    Judge.verdict(base, other).should eq(Verdict::Different)
  end

  it "is Review when the status matches but the body genuinely diverges" do
    base = summary(200, "the full administrative control panel with billing and every user record")
    other = summary(200, "you do not have permission to view this resource please contact support")
    Judge.verdict(base, other).should eq(Verdict::Review)
  end

  it "is Error when this identity's send failed" do
    base = summary(200, "anything at all rendered here for the baseline response body content")
    other = summary(nil, "", error: "connection refused")
    Judge.verdict(base, other).should eq(Verdict::Error)
  end

  it "is Review when the baseline itself errored (nothing to anchor against)" do
    base = summary(nil, "", error: "timeout")
    other = summary(200, "some page content that came back fine for this identity here now")
    Judge.verdict(base, other).should eq(Verdict::Review)
  end

  it "matches two empty-bodied same-class responses (a 204 with no entity)" do
    base = summary(204, "")
    other = summary(204, "")
    Judge.verdict(base, other).should eq(Verdict::Same)
  end

  # A redirect's whole content is its `Location`; the body is empty, so two 3xx replies
  # compared as identical no matter where they steered the client. That made the clearest
  # enforcement pattern there is — an authenticated `302 → /dashboard` against an anonymous
  # `302 → /login` — come back `Same`, i.e. painted red as a bypass.
  describe "two redirects" do
    it "is Different when they point somewhere else" do
      base = redirect(302, "/dashboard")
      other = redirect(302, "/login?next=%2Fdashboard")
      Judge.verdict(base, other).should eq(Verdict::Different)
    end

    it "is Same when they point to the same place" do
      base = redirect(302, "/dashboard")
      other = redirect(302, "/dashboard")
      Judge.verdict(base, other).should eq(Verdict::Same)
    end

    # Different codes inside 3xx are still one class: a 301 and a 302 to the same place are
    # the same answer, and the status alone was never what separated them.
    it "reads the header, not the code" do
      Judge.verdict(redirect(301, "/x"), redirect(302, "/x")).should eq(Verdict::Same)
    end

    # A per-session token in the URL sent BOTH identities into the protected area. Reading
    # that as `Different` aggregates the row to `enforced` and the finding disappears — the one
    # direction this tool must not fail in.
    it "is Review when they differ only in the query" do
      base = redirect(302, "/dashboard?sid=AAA")
      other = redirect(302, "/dashboard?sid=BBB")
      Judge.verdict(base, other).should eq(Verdict::Review)
    end

    it "is still Different when the path differs" do
      Judge.verdict(redirect(302, "/dashboard?next=1"), redirect(302, "/login?next=1"))
        .should eq(Verdict::Different)
    end

    it "is Different across hosts, even on the same path" do
      Judge.verdict(redirect(302, "https://app.acme.test/x"), redirect(302, "https://www.acme.test/x"))
        .should eq(Verdict::Different)
    end

    # No Location on one side and there is nothing to compare — fall back to the body, which
    # is what every non-redirect pair uses.
    it "falls back to the body when a Location is missing" do
      Judge.verdict(redirect(302, "/dashboard"), summary(302, "")).should eq(Verdict::Same)
    end

    # A 3xx that carries a body: the header still decides, because a "redirecting…" page is
    # boilerplate every redirect shares and says nothing about where this one goes.
    it "prefers the header over a matching boilerplate body" do
      base = redirect(302, "/dashboard", "Redirecting you, please follow the link in this page")
      other = redirect(302, "/login", "Redirecting you, please follow the link in this page")
      Judge.verdict(base, other).should eq(Verdict::Different)
    end
  end
end

describe Gori::Authorize::ResponseSummary do
  it "parses the status from a response head" do
    Summary.status_of("HTTP/1.1 200 OK\r\n\r\n".to_slice).should eq(200)
    Summary.status_of("HTTP/2 404\r\n".to_slice).should eq(404)
    Summary.status_of(Bytes.empty).should be_nil
  end

  it "decodes the body before fingerprinting and reports the decoded size" do
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    body = "the quick brown fox jumps over the lazy dog several times over here".to_slice
    r = Gori::Repeater::Result.new(head, body, nil, 0_i64)
    s = Summary.of(r)
    s.status.should eq(200)
    s.size.should eq(body.size.to_i64)
    s.simhash.should_not eq(0_u64)
  end

  # From the PARSED response the send path hands back (`Repeater::Engine` fills `response` on
  # every reply it read), so the redirect verdict above is fed by something a real run produces
  # rather than by a hand-built summary.
  it "carries the Location of a redirect" do
    head = "HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    s = Summary.of(Gori::Repeater::Result.new(head, nil, resp, 0_i64))
    s.status.should eq(302)
    s.location.should eq("/login")
  end

  it "carries the error and no fingerprint when the send failed" do
    r = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "connection refused")
    s = Summary.of(r)
    s.error.should eq("connection refused")
    s.status.should be_nil
    s.simhash.should eq(0_u64)
  end
end

# ── the direction of a status-class change ──────────────────────────────────────────────
#
# A different status class was `Different` in BOTH directions, and `Different` is the verdict
# that aggregates a request to `enforced`. That word claims the identity under test got LESS
# than the baseline; when it got a 2xx and the baseline did not, the opposite happened.
describe Gori::Authorize::Judge do
  it "is Review, not Different, when the other identity was served a 2xx the baseline was denied" do
    base = summary(403, "Forbidden")
    other = summary(200, "the full salary export for every employee rendered in this response")
    # `Different` here would aggregate to `enforced` — a green run for an identity that was
    # handed a page the baseline could not see.
    Judge.verdict(base, other).should eq(Verdict::Review)
  end

  it "is Review when the baseline revalidated (304) and the other identity got the entity (200)" do
    base = Summary.new(304, 0_i64, 0_u64)
    other = summary(200, "the full salary export for every employee rendered in this response")
    Judge.verdict(base, other).should eq(Verdict::Review)
  end

  it "keeps a 2xx baseline turning into a denial as Different (enforcement, unchanged)" do
    base = summary(200, "the full administrative control panel with billing and every user record")
    Judge.verdict(base, summary(403, "Forbidden")).should eq(Verdict::Different)
    Judge.verdict(base, summary(500, "Internal Server Error")).should eq(Verdict::Different)
  end
end

# ── a body the protocol forbade is not a body that matched ──────────────────────────────
#
# HEAD and 304 describe an entity they deliberately do not send. "Both bodies were empty" is
# true of every such pair, and reading it as a content match made `Same` — and so BYPASS —
# the automatic answer for the whole family. HEAD is in `Passive::SAFE_METHODS`, so passive
# replay painted ordinary endpoints red with nobody pressing a key.
private def head_reply(status : Int32, length : Int64?, etag : String? = nil) : Summary
  Summary.new(status, 0_i64, 0_u64, content_length: length, etag: etag, head_request: true)
end

describe Gori::Authorize::Judge do
  it "does not call two bodyless HEAD replies Same on their status alone" do
    # Same status, no body on either side, and the heads describe nothing else: there is no
    # evidence here, and `Review` is the verdict whose meaning is "the operator judges".
    Judge.verdict(head_reply(200, nil), head_reply(200, nil)).should eq(Verdict::Review)
  end

  it "is not Same when two HEAD replies declare different entity sizes" do
    Judge.verdict(head_reply(200, 4096_i64), head_reply(200, 12_i64)).should eq(Verdict::Review)
  end

  it "is Same when two HEAD replies declare the same entity" do
    Judge.verdict(head_reply(200, 4096_i64), head_reply(200, 4096_i64)).should eq(Verdict::Same)
  end

  it "reads the ETag ahead of the length — a different representation is not a match" do
    a = head_reply(200, 4096_i64, etag: %("v1-admin"))
    b = head_reply(200, 4096_i64, etag: %("v1-anon"))
    Judge.verdict(a, b).should eq(Verdict::Review)
    same = head_reply(200, 4096_i64, etag: %("v1-admin"))
    Judge.verdict(a, same).should eq(Verdict::Same)
  end

  it "does not call two 304s Same for having no body" do
    a = Summary.new(304, 0_i64, 0_u64, etag: %("admin-copy"))
    b = Summary.new(304, 0_i64, 0_u64, etag: %("anon-copy"))
    Judge.verdict(a, b).should eq(Verdict::Review)
  end

  # THE REGRESSION GUARD for this fix. A `204` and a `Content-Length: 0` 200 are not a
  # suppressed entity — the emptiness IS the resource, and an identity served the same empty
  # success is the same finding it always was. Turning those into `Review` would trade a
  # systematic false positive for a missed bypass, which is the wrong direction.
  it "still calls a genuine empty entity a match (204, and a Content-Length: 0 200)" do
    Judge.verdict(Summary.new(204, 0_i64, 0_u64), Summary.new(204, 0_i64, 0_u64))
      .should eq(Verdict::Same)
    Judge.verdict(Summary.new(200, 0_i64, 0_u64, content_length: 0_i64),
      Summary.new(200, 0_i64, 0_u64, content_length: 0_i64)).should eq(Verdict::Same)
  end
end

describe Gori::Authorize::ResponseSummary do
  it "carries what the head declares about an entity it did not send" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nETag: \"v1\"\r\n\r\n".to_slice
    s = Summary.of(Gori::Repeater::Result.new(head, nil, nil, 0_i64), head_request: true)
    s.content_length.should eq(4096_i64)
    s.etag.should eq(%("v1"))
    s.head_request?.should be_true
    s.entity_suppressed?.should be_true
  end

  # Read off the RAW head, not only off a parsed `RawResponse`: a result built without a parse
  # still has its bytes, and reading only the parsed half left every field above silently nil.
  it "reads those headers off the raw head when nothing parsed it" do
    head = "HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\n\r\n".to_slice
    s = Summary.of(Gori::Repeater::Result.new(head, nil, nil, 0_i64))
    s.location.should eq("/login")
    s.content_length.should eq(0_i64)
  end

  it "treats a 304 as an entity it did not send, whatever the request method was" do
    head = "HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\n\r\n".to_slice
    s = Summary.of(Gori::Repeater::Result.new(head, nil, nil, 0_i64))
    s.entity_suppressed?.should be_true
    s.head_request?.should be_false
  end

  it "does not treat an ordinary 200 body as suppressed" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
    s = Summary.of(Gori::Repeater::Result.new(head, "ok".to_slice, nil, 0_i64))
    s.entity_suppressed?.should be_false
  end
end
