require "../spec_helper"

# Repro: the body-differential active rules must not read an INCOMPLETE (truncated)
# response as a trustworthy body for their length / signature comparison. A response the
# origin cut short — or that hit the capture ceiling — comes back `ok? == true` but
# `incomplete? == true` (Repeater::Result). Treating its short body as real turns a
# transient truncation on one leg into a differential the rule reports as a finding.
# NextjsActionNoAuth already guards this; its siblings (backslash_powered,
# url_rewrite_bypass, error_based_sqli) must too.

private def capture_flow(store, resp_head : String, *, target = "/", status = 200,
                         content_type : String? = "text/html", method = "GET") : Gori::Store::FlowDetail
  head = "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: nil,
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# A response result; `incomplete:` marks it as an origin-truncated / capped body.
private def result(status : Int32, body : String, incomplete = false) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
  Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice,
    nil, 1_i64, nil, incomplete)
end

describe "Gori::Probe::Active body-differential incomplete-response guard" do
  it "BackslashPowered: an incomplete `\\` leg is not a body-length asymmetry" do
    with_store do |store|
      probe = Gori::Probe::Active::BackslashPowered.new
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # baseline, baseline2 (both complete, stable) ; single truncated ; double complete==baseline.
      results = [result(200, "welcome"), result(200, "welcome"),
                 result(200, "welco", incomplete: true), result(200, "welcome")]
      probe.detections_all(plan, results, detail).should be_empty
    end
  end

  it "BackslashPowered: an incomplete baseline cannot anchor the comparison" do
    with_store do |store|
      probe = Gori::Probe::Active::BackslashPowered.new
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      results = [result(200, "welcome", incomplete: true), result(200, "welcome"),
                 result(500, ""), result(200, "welcome")]
      probe.detections_all(plan, results, detail).should be_empty
    end
  end

  it "UrlRewriteBypass: an incomplete probe body is not a bypass size-diff" do
    with_store do |store|
      probe = Gori::Probe::Active::UrlRewriteBypass.new
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      # probe 200 but TRUNCATED; the two root controls agree (stable) at a different size.
      results = [result(200, "AAAAAAAAAA", incomplete: true), result(200, "root"), result(200, "root")]
      probe.detections_all(plan, results, detail).should be_empty
    end
  end

  it "ErrorBasedSqli: a truncated baseline cannot establish 'signature absent'" do
    with_store do |store|
      probe = Gori::Probe::Active::ErrorBasedSqli.new
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=1")
      plan = probe.plan(detail).not_nil!
      # Both baselines truncated BEFORE the always-present DB error; the probe (complete)
      # carries it. Without an incomplete guard this reads as an induced error.
      results = [result(200, "prefix", incomplete: true), result(200, "prefix", incomplete: true),
                 result(200, "prefix You have an error in your SQL syntax near ...")]
      probe.detections_all(plan, results, detail).should be_empty
    end
  end

  # Positive controls: the guards must not suppress a genuine finding on COMPLETE responses.

  it "BackslashPowered: still fires on a complete `\\`-only asymmetry" do
    with_store do |store|
      probe = Gori::Probe::Active::BackslashPowered.new
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      results = [result(200, "welcome"), result(200, "welcome"),
                 result(500, ""), result(200, "welcome")]
      probe.detections_all(plan, results, detail).size.should eq(1)
    end
  end

  it "UrlRewriteBypass: still fires when a complete probe differs from a stable root" do
    with_store do |store|
      probe = Gori::Probe::Active::UrlRewriteBypass.new
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      results = [result(200, "SECRET ADMIN PANEL"), result(200, "root"), result(200, "root")]
      probe.detections_all(plan, results, detail).size.should eq(1)
    end
  end

  it "ErrorBasedSqli: still fires on a complete baseline + induced signature" do
    with_store do |store|
      probe = Gori::Probe::Active::ErrorBasedSqli.new
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=1")
      plan = probe.plan(detail).not_nil!
      results = [result(200, "welcome home"), result(200, "welcome home"),
                 result(200, "You have an error in your SQL syntax near '\"'")]
      probe.detections_all(plan, results, detail).size.should eq(1)
    end
  end
end
