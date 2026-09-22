require "../spec_helper"
require "../support/probe_harness"
require "../../src/gori/probe/active/boolean_sqli"

private alias P = Gori::Probe

# A hand-built Repeater::Result for a probe/baseline response (status + body). duration is
# irrelevant to the boolean rule (it reads bodies, not latency), so a constant stands in.
private def resp(body : String, status : Int32 = 200) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
  Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
end

# Two bodies with DISJOINT alphabetic token sets, so their SimHashes are far apart (> the
# SIMHASH_DISTANCE of 3) — the shape a boolean FALSE leg takes when the injected clause empties
# the result set. Long enough that the fingerprint is stable.
private BASELINE_BODY = "<html><body><h1>Search results</h1><ul>" \
                        "<li>alpha bravo charlie</li><li>delta echo foxtrot</li>" \
                        "<li>golf hotel india</li><li>juliet kilo lima</li>" \
                        "<li>mike november oscar</li></ul></body></html>"
private EMPTY_BODY = "<html><body><h1>No matching records</h1>" \
                     "<p>Your query returned zero rows; please refine the terms.</p></body></html>"

describe "Gori::Probe::Active::BooleanBlindSqli" do
  rule = Gori::Probe::Active::BooleanBlindSqli.new

  it "plans two baselines + a true/false pair per query param (string breakout by default)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["id"])
      plan.followups.size.should eq(3)                                                # 2nd baseline + (true, false)
      String.new(plan.request).should contain("/s?id=42 ")                            # baseline unchanged
      String.new(plan.followups[0]).should contain("/s?id=42 ")                       # 2nd baseline unchanged
      String.new(plan.followups[1]).should contain("id=42%27%20AND%20%271%27%3D%271") # ' AND '1'='1
      String.new(plan.followups[2]).should contain("id=42%27%20AND%20%271%27%3D%272") # ' AND '1'='2
    end
  end

  it "fires Critical/ACTIVE when the true leg matches the baseline and the false leg diverges" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # base1, base2, true≈baseline, false=empty-result page.
      results = [resp(BASELINE_BODY), resp(BASELINE_BODY), resp(BASELINE_BODY), resp(EMPTY_BODY)]
      dets = rule.detections_all(plan, results, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("sqli_boolean_based")
      dets.first.category.should eq(P::Category::ACTIVE)
      dets.first.severity.should eq(Gori::Store::Severity::Critical)
      dets.first.title.should contain("Boolean-based blind SQL injection")
      dets.first.evidence.not_nil!.should contain("id")
    end
  end

  it "fires when the false leg only changes STATUS (same body shape)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      results = [resp(BASELINE_BODY), resp(BASELINE_BODY), resp(BASELINE_BODY), resp(BASELINE_BODY, status: 404)]
      rule.detections_all(plan, results, detail).size.should eq(1)
    end
  end

  it "does NOT fire when the false leg also matches the baseline (inert parameter)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # An inert param: appending either predicate changes nothing, so both legs equal the baseline.
      results = [resp(BASELINE_BODY), resp(BASELINE_BODY), resp(BASELINE_BODY), resp(BASELINE_BODY)]
      rule.detections_all(plan, results, detail).should be_empty
    end
  end

  it "does NOT fire on reflection (the true leg diverges from the baseline)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # A reflecting endpoint renders the payload, so the always-true leg no longer matches the
      # baseline — the guard that separates injection from reflection. Here the true leg is the
      # empty-shaped body and the false leg matches the baseline: "true≈baseline" is false → decline.
      results = [resp(BASELINE_BODY), resp(BASELINE_BODY), resp(EMPTY_BODY), resp(BASELINE_BODY)]
      rule.detections_all(plan, results, detail).should be_empty
    end
  end

  it "declines when the two baselines disagree (self-varying endpoint)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # base1 and base2 are already different pages → no stable reference → decline, even though
      # the true/false legs below would otherwise look like a clean oracle.
      results = [resp(BASELINE_BODY), resp(EMPTY_BODY), resp(BASELINE_BODY), resp(EMPTY_BODY)]
      rule.detections_all(plan, results, detail).should be_empty
    end
  end

  it "declines when the second baseline is missing (no stable reference)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      rule.detections_all(plan, [resp(BASELINE_BODY)], detail).should be_empty
    end
  end

  it "aggressive adds the numeric breakout and raises the param cap" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      agg = rule.plan(detail, P::Active::Options.new(aggressive: true)).not_nil!
      # One param × two breakouts × (true, false) = 4 legs, after the second baseline → 5 followups.
      agg.followups.size.should eq(5)
      String.new(agg.followups[3]).should contain("id=42%20AND%201%3D1") #  AND 1=1 (numeric true)
      String.new(agg.followups[4]).should contain("id=42%20AND%201%3D2") #  AND 1=2 (numeric false)
      # Cap: default 3 params, aggressive 10.
      wide = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?" + (0...6).map { |i| "p#{i}=v" }.join("&"))
      rule.plan(wide).not_nil!.params.size.should eq(P::Active::BooleanBlindSqli::MAX_PROBE_PARAMS)
      rule.plan(wide, P::Active::Options.new(aggressive: true)).not_nil!.params.size.should eq(6)
    end
  end

  it "fires via the numeric breakout under aggressive when the string breakout does not land" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail, P::Active::Options.new(aggressive: true)).not_nil!
      # Layout: base1, base2, [string-true, string-false, numeric-true, numeric-false].
      # String breakout errors in a numeric column (true diverges) → its pair declines; the numeric
      # breakout confirms.
      results = [resp(BASELINE_BODY), resp(BASELINE_BODY),
                 resp(EMPTY_BODY), resp(EMPTY_BODY),    # string legs: both error-shaped, no oracle
                 resp(BASELINE_BODY), resp(EMPTY_BODY)] # numeric legs: true≈baseline, false diverges
      rule.detections_all(plan, results, detail).size.should eq(1)
    end
  end

  it "gates unsafe methods: POST nil by default, non-nil under allow_unsafe; HEAD always out" do
    with_store do |store|
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42", method: "POST")
      rule.plan(post).should be_nil
      rule.plan(post, P::Active::Options.new(allow_unsafe: true)).should_not be_nil
      head = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42", method: "HEAD")
      rule.plan(head, P::Active::Options.new(allow_unsafe: true)).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?id=42", "/s?a=1&b=2&c=3&d=4", "/s?flag&x=9", "/s"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        rule.dedup_key(detail).should eq(rule.plan(detail).try(&.dedup_key))
      end
      none = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")
      rule.dedup_key(none).should be_nil
      rule.plan(none).should be_nil
    end
  end

  it "requests_per_flow is bounded at 4..8 (default posture)" do
    rule.requests_per_flow.should eq(4..8)
  end
end
