require "../spec_helper"
require "../support/probe_harness"
# The rule is not wired into Active::RULES / active.cr yet (the orchestrator does registration
# separately), so require the file directly to load the class for these unit tests.
require "../../src/gori/probe/active/error_based_sqli"

private alias P = Gori::Probe

# ── flow helpers (probe_capture_flow comes from spec/support/probe_harness.cr) ──

# Insert a flow + response and return its full FlowDetail (what the analyzer feeds an active rule).
# A hand-built Repeater::Result for a probe/baseline response (status 200 + body).
private def resp(body : String, status : Int32 = 200) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
  Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
end

describe "Gori::Probe::Active::ErrorBasedSqli" do
  rule = Gori::Probe::Active::ErrorBasedSqli.new

  it "plans a baseline + one payload-appended probe per query param" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["id"])
      plan.followups.size.should eq(2)                             # 2nd baseline + one probe
      String.new(plan.request).should contain("/s?id=42 ")         # baseline: value unchanged
      String.new(plan.followups[0]).should contain("/s?id=42 ")    # 2nd baseline: value unchanged
      String.new(plan.followups[1]).should contain("id=42%27%22 ") # probe: id=42'"
    end
  end

  it "caps probed params at MAX_PROBE_PARAMS (in query order); aggressive raises it" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&b=2&c=3&d=4")
      rule.plan(detail).not_nil!.params.map(&.name).should eq(["a", "b", "c"])
      wide = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?" + (0...6).map { |i| "p#{i}=v" }.join("&"))
      rule.plan(wide).not_nil!.params.size.should eq(P::Active::ErrorBasedSqli::MAX_PROBE_PARAMS)
      rule.plan(wide, P::Active::Options.new(aggressive: true)).not_nil!.params.size.should eq(6)
    end
  end

  it "fires High/ACTIVE when a MySQL error appears only in the probe" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      results = [resp("<p>ok</p>"), resp("<p>ok</p>"),
                 resp("You have an error in your SQL syntax; check the manual")]
      dets = rule.detections_all(plan, results, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("sqli_error_based")
      dets.first.category.should eq(P::Category::ACTIVE)
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.title.should eq("Error-based SQL injection (database error induced)")
      dets.first.evidence.not_nil!.should contain("id")
    end
  end

  it "does NOT fire when the same error is present in the baseline too (permanently-broken endpoint)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      err = "You have an error in your SQL syntax; check the manual"
      rule.detections_all(plan, [resp(err), resp(err), resp(err)], detail).should be_empty
    end
  end

  it "declines when the DB error is present in the SECOND baseline (self-varying endpoint)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      err = "You have an error in your SQL syntax; check the manual"
      # baseline1 clean, baseline2 already shows the error (endpoint jitter), probe shows it too:
      # absent-from-BOTH-baselines is not satisfied, so we decline rather than false-fire.
      rule.detections_all(plan, [resp("<p>ok</p>"), resp(err), resp(err)], detail).should be_empty
    end
  end

  it "declines when the second baseline is missing (no stable reference)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # Only one baseline came back — decline rather than diff against a single sample.
      rule.detections_all(plan, [resp("<p>ok</p>")], detail).should be_empty
    end
  end

  it "does NOT fire on a bare reflection of the payload with no DB error" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # The probe echoes the '" payload but shows no database diagnostic.
      rule.detections_all(plan, [resp("<p>searched for 42</p>"), resp("<p>searched for 42</p>"), resp("<p>searched for 42'\"</p>")], detail).should be_empty
    end
  end

  it "fires on an Oracle ORA-##### diagnostic (regex)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      dets = rule.detections_all(plan, [resp("<p>ok</p>"), resp("<p>ok</p>"), resp("ORA-00933: SQL command not properly ended")], detail)
      dets.size.should eq(1)
      dets.first.evidence.not_nil!.should contain("id")
    end
  end

  it "returns nil plan for a flow with no query params" do
    with_store do |store|
      rule.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
    end
  end

  it "gates unsafe methods: POST nil by default, non-nil under allow_unsafe" do
    with_store do |store|
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42", method: "POST")
      rule.plan(post).should be_nil
      rule.plan(post, P::Active::Options.new(allow_unsafe: true)).should_not be_nil
      # HEAD stays out even under the opt-in (no body to diff).
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
      # A no-param flow → both nil.
      none = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")
      rule.dedup_key(none).should be_nil
      rule.plan(none).should be_nil
    end
  end

  it "requests_per_flow begins at >= 3 (two baselines + at least one probe)" do
    (rule.requests_per_flow.begin >= 3).should be_true
  end

  it "adds an ORA word boundary so a larger token does not false-match" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # 'aurora-12345' contains 'ora-12345' but is not an Oracle diagnostic — must NOT fire.
      rule.detections_all(plan, [resp("<p>ok</p>"), resp("<p>ok</p>"), resp("region aurora-12345 ready")], detail).should be_empty
    end
  end
end
