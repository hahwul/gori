require "./spec_helper"

# Issue #1247 — the web cache DECEPTION verdict. `CacheDeception.classify` turns a finished
# `Authorize::Target` (the engine it borrows) into a headline, reading the ONE fact Authorize
# does not: the anonymous response's cache status. Pure, so it is pinned here without a socket.
private alias CD = Gori::CacheDeception
private alias AZ = Gori::Authorize

# A trial with a chosen response head (so the classifier can read its cache headers) and status.
private def cd_trial(name : String, baseline : Bool, status : Int32,
                     verdict : AZ::Verdict, cache_lines : Array(String) = [] of String) : AZ::Trial
  head = ("HTTP/1.1 #{status} OK\r\n" + cache_lines.map { |l| "#{l}\r\n" }.join + "\r\n").to_slice
  meta = Gori::Repeater::ExchangeMeta.of(status, 40_i64, 1_000_i64, nil)
  summary = AZ::ResponseSummary.new(status, 40_i64, 0_u64)
  AZ::Trial.new(name, baseline, meta, verdict, baseline ? nil : "Δ", summary,
    "req".to_slice, head, "body".to_slice)
end

private def errored_trial(name : String, baseline : Bool) : AZ::Trial
  meta = Gori::Repeater::ExchangeMeta.of(nil, nil, 0_i64, "connection refused")
  summary = AZ::ResponseSummary.new(nil, nil, 0_u64, error: "connection refused")
  AZ::Trial.new(name, baseline, meta, baseline ? AZ::Verdict::Baseline : AZ::Verdict::Error,
    nil, summary, "req".to_slice, nil, nil)
end

private def target(authed : AZ::Trial, anon : AZ::Trial, control : AZ::Trial? = nil, *,
                   blocked : Int64 = 0, reason : String? = nil) : AZ::Target
  trials = [authed, anon]
  trials << control if control
  AZ::Target.new(1_i64, "GET", "https://h.test/account", trials, blocked, reason)
end

private class CacheDeceptionBackend < Gori::Fuzz::Backend
  getter sent = [] of Bytes

  def initialize(@origin : Gori::Fuzz::Origin, @cache_hit : Bool = true)
  end

  def origin : Gori::Fuzz::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes
    text = String.new(bytes)
    headers = @cache_hit && !text.includes?("__gori_cache_bust=") ? "X-Cache: HIT\r\nAge: 30\r\n" : ""
    head = "HTTP/1.1 200 OK\r\n#{headers}Content-Length: 23\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, "private account content".to_slice, nil, 1_000_i64)
  end
end

describe Gori::CacheDeception do
  it "reports CACHED when the anonymous re-request got the authenticated body FROM a cache" do
    authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
    anon = cd_trial("anonymous", false, 200, AZ::Verdict::Same, ["X-Cache: HIT", "Age: 30"])
    control = cd_trial("anonymous-cache-busted", false, 403, AZ::Verdict::Different)
    report = CD.classify(target(authed, anon, control))
    report.verdict.should eq(CD::Verdict::Cached)
    report.verdict.deception?.should be_true
    report.cache.should eq(Gori::CacheStatus::Signal::Hit)
  end

  it "reports SERVED when a cache-busted anonymous control also gets the same content" do
    authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
    anon = cd_trial("anonymous", false, 200, AZ::Verdict::Same, ["X-Cache: HIT"])
    control = cd_trial("anonymous-cache-busted", false, 200, AZ::Verdict::Same)
    report = CD.classify(target(authed, anon, control))
    report.verdict.should eq(CD::Verdict::Served)
    report.verdict.deception?.should be_false
    report.cache.should eq(Gori::CacheStatus::Signal::Hit)
  end

  it "does not report CACHED without a completed cache-busted control" do
    authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
    anon = cd_trial("anonymous", false, 200, AZ::Verdict::Same, ["X-Cache: HIT"])
    CD.classify(target(authed, anon)).verdict.should eq(CD::Verdict::Review)
  end

  it "reports PROTECTED when the anonymous re-request got a different response" do
    authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
    anon = cd_trial("anonymous", false, 403, AZ::Verdict::Different, ["X-Cache: MISS"])
    CD.classify(target(authed, anon)).verdict.should eq(CD::Verdict::Protected)
  end

  it "reports REVIEW when the anonymous response was similar but not identical" do
    authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
    anon = cd_trial("anonymous", false, 200, AZ::Verdict::Review, ["X-Cache: HIT"])
    CD.classify(target(authed, anon)).verdict.should eq(CD::Verdict::Review)
  end

  it "reports ERRORED when the anonymous send failed (nothing was compared)" do
    authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
    CD.classify(target(authed, errored_trial("anonymous", false))).verdict.should eq(CD::Verdict::Errored)
  end

  it "reports ERRORED when the authenticated baseline send failed" do
    anon = cd_trial("anonymous", false, 200, AZ::Verdict::Same, ["X-Cache: HIT"])
    control = cd_trial("anonymous-cache-busted", false, 403, AZ::Verdict::Different)
    CD.classify(target(errored_trial("as-captured", true), anon, control)).verdict.should eq(CD::Verdict::Errored)
  end

  it "sends an anonymous cache-busted control through the shared replay engine" do
    origin = Gori::Fuzz::Origin.new("https", "h.test", 443)
    backend = CacheDeceptionBackend.new(origin)
    engine = AZ::Engine.new(->(_origin : Gori::Fuzz::Origin, _http2 : Bool) {
      backend.as(Gori::Fuzz::Backend)
    })
    row = Gori::Store::FlowRow.new(1_i64, 1_i64, "https", "GET", "h.test", 443,
      "/account?from=history", 200, 100_i64, Gori::Store::FlowState::Complete)
    request = "GET /account?from=history HTTP/1.1\r\nHost: h.test\r\n" \
              "Cookie: session=secret\r\nAuthorization: Bearer secret\r\n\r\n".to_slice
    detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", request, nil, nil, nil)

    report = CD.check(engine, detail).not_nil!
    report.verdict.should eq(CD::Verdict::Served)
    backend.sent.size.should eq(3)
    control = String.new(backend.sent.last)
    control.should contain("GET /account?from=history&__gori_cache_bust=")
    control.should_not contain("Cookie:")
    control.should_not contain("Authorization:")
  end

  it "skips the control when the anonymous response has no cache-hit evidence" do
    origin = Gori::Fuzz::Origin.new("https", "h.test", 443)
    backend = CacheDeceptionBackend.new(origin, cache_hit: false)
    engine = AZ::Engine.new(->(_origin : Gori::Fuzz::Origin, _http2 : Bool) {
      backend.as(Gori::Fuzz::Backend)
    })
    row = Gori::Store::FlowRow.new(1_i64, 1_i64, "https", "GET", "h.test", 443,
      "/account", 200, 100_i64, Gori::Store::FlowState::Complete)
    request = "GET /account HTTP/1.1\r\nHost: h.test\r\nCookie: session=secret\r\n\r\n".to_slice
    detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", request, nil, nil, nil)

    report = CD.check(engine, detail).not_nil!
    report.verdict.should eq(CD::Verdict::Served)
    backend.sent.size.should eq(2)
    report.control.should be_nil
  end

  it "reports BLOCKED when gori refused every send before the socket" do
    authed = errored_trial("as-captured", true)
    anon = errored_trial("anonymous", false)
    t = target(authed, anon, blocked: 2_i64, reason: "sandbox")
    report = CD.classify(t)
    report.verdict.should eq(CD::Verdict::Blocked)
    report.blocked_reason.should eq("sandbox")
  end

  describe "skip_reason (reuses Authorize::Passive's rules)" do
    it "declines an unsafe method unless asked, and names it Passive's way" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "POST", target: "/x", http_version: "HTTP/1.1",
          head: "POST /x HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil,
          source: Gori::FlowSource::Kind::Proxy))
        store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
        store.flush
        detail = store.get_flow(id).not_nil!
        CD.skip_reason(detail, false).should eq(:unsafe_method)
        CD.skip_reason(detail, true).should be_nil # --unsafe-methods lifts it
        CD.reason_label(:unsafe_method).should eq("not a safe method to repeat")
      end
    end
  end

  it "fixes the priming identities to as-captured (baseline) then anonymous" do
    ids = CD.identities
    ids.size.should eq(2)
    ids.first.baseline?.should be_true
    ids.last.name.should eq("anonymous")
    ids.last.remove_headers.should eq(["Cookie", "Authorization"])
  end
end
