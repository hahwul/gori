require "../spec_helper"
require "../support/probe_harness"
require "../../src/gori/probe/active/time_based_sqli"

private alias P = Gori::Probe

# A hand-built Repeater::Result whose LATENCY (duration_us) is what the time-based rule reads.
# `error` set ⇒ ok? false (an errored / timed-out leg the rule must skip).
private def tresp(duration_us : Int64, status : Int32 = 200, error : String? = nil) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
  body = error ? nil : "ok".to_slice
  Gori::Repeater::Result.new(head.to_slice, body, nil, duration_us, error)
end

private T0 = 100_000_i64 # baseline latency, 0.1 s

describe "Gori::Probe::Active::TimeBlindSqli" do
  rule = Gori::Probe::Active::TimeBlindSqli.new

  it "ships OFF by default (opt-in), so a fresh project never plans it automatically" do
    P.rule_disabled?("sqli_time_based", Set(String).new).should be_true
    P.rule_enabled?("sqli_time_based", Set(String).new).should be_false
    # Present in the stored deviation set ⇒ ENABLED (the default-OFF flip).
    P.rule_enabled?("sqli_time_based", Set{"sqli_time_based"}).should be_true
  end

  it "plans two baselines + two increasing delays per query param per family (MySQL by default)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["id"])
      plan.followups.size.should eq(5)                                                    # 2nd baseline + 2 families × (short, long)
      String.new(plan.request).should contain("/s?id=42 ")                                # baseline: no delay
      String.new(plan.followups[0]).should contain("/s?id=42 ")                           # 2nd baseline: no delay
      String.new(plan.followups[1]).should contain("id=42%20AND%20SLEEP%282%29--%20-")    #  AND SLEEP(2)
      String.new(plan.followups[2]).should contain("id=42%20AND%20SLEEP%284%29--%20-")    #  AND SLEEP(4)
      String.new(plan.followups[3]).should contain("id=42%27%20AND%20SLEEP%282%29--%20-") # ' AND SLEEP(2)
    end
  end

  it "fires Critical when the latency scales across the two delays" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # Layout: base1, base2, [mysql-num short, mysql-num long, mysql-str short, mysql-str long].
      # Numeric legs don't land (no delay); the string family scales: +2.1 s then +4.1 s.
      results = [tresp(T0), tresp(T0),
                 tresp(T0), tresp(T0),                         # mysql-numeric: no delay
                 tresp(T0 + 2_100_000), tresp(T0 + 4_100_000)] # mysql-string: scales
      dets = rule.detections_all(plan, results, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("sqli_time_based")
      dets.first.severity.should eq(Gori::Store::Severity::Critical)
      dets.first.title.should contain("Time-based blind SQL injection")
      dets.first.evidence.not_nil!.should contain("id")
      dets.first.evidence.not_nil!.should contain("mysql-string") # names the confirming family
    end
  end

  it "does NOT fire on a uniformly slow endpoint (delays do not scale)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # Every leg is ~5 s: above the absolute floors, but the long/short increment is ~0, so the
      # scaling check — the whole point of two increasing delays — rejects it.
      slow = 5_000_000_i64
      results = [tresp(T0), tresp(T0), tresp(slow), tresp(slow), tresp(slow), tresp(slow)]
      rule.detections_all(plan, results, detail).should be_empty
    end
  end

  it "does NOT fire when only the long leg is slow (a single latency spike)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # The short leg answered at baseline speed, so the short-delta floor fails: a one-off spike on
      # the long leg alone is not an injected delay.
      results = [tresp(T0), tresp(T0), tresp(T0), tresp(T0 + 4_100_000), tresp(T0), tresp(T0 + 4_100_000)]
      rule.detections_all(plan, results, detail).should be_empty
    end
  end

  it "declines on a high-variance baseline (its own jitter could satisfy the thresholds)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      # The two baselines disagree by ≥ MIN_SHORT_DELTA (2 s) — the endpoint's nominal latency swings
      # as much as the smallest delay we inject — so even scaling-looking legs are declined.
      results = [tresp(T0), tresp(T0 + 2_000_000),
                 tresp(T0), tresp(T0),
                 tresp(T0 + 2_100_000), tresp(T0 + 4_100_000)]
      rule.detections_all(plan, results, detail).should be_empty
    end
  end

  it "skips a family whose leg errored and still confirms via another family" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      results = [tresp(T0), tresp(T0),
                 tresp(0, error: "reset"), tresp(0, error: "reset"), # mysql-numeric: errored legs
                 tresp(T0 + 2_100_000), tresp(T0 + 4_100_000)]       # mysql-string: scales
      rule.detections_all(plan, results, detail).size.should eq(1)
    end
  end

  it "declines when either baseline is missing or errored" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      plan = rule.plan(detail).not_nil!
      rule.detections_all(plan, [] of Gori::Repeater::Result, detail).should be_empty
      # First baseline errored.
      b1 = [tresp(0, error: "dns"), tresp(T0), tresp(T0), tresp(T0), tresp(T0 + 2_100_000), tresp(T0 + 4_100_000)]
      rule.detections_all(plan, b1, detail).should be_empty
      # Second baseline errored.
      b2 = [tresp(T0), tresp(0, error: "dns"), tresp(T0), tresp(T0), tresp(T0 + 2_100_000), tresp(T0 + 4_100_000)]
      rule.detections_all(plan, b2, detail).should be_empty
    end
  end

  it "aggressive raises the family set to all backends and the param cap" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
      agg = rule.plan(detail, P::Active::Options.new(aggressive: true)).not_nil!
      agg.followups.size.should eq(13) # 2nd baseline + 6 families × (short, long), one param
      joined = agg.followups.map { |b| String.new(b) }.join(" ")
      joined.should contain("PG_SLEEP")
      joined.should contain("WAITFOR")
      wide = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?" + (0...6).map { |i| "p#{i}=v" }.join("&"))
      rule.plan(wide).not_nil!.params.size.should eq(P::Active::TimeBlindSqli::MAX_PROBE_PARAMS)
      rule.plan(wide, P::Active::Options.new(aggressive: true)).not_nil!.params.size.should eq(5)
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
      ["/s?id=42", "/s?a=1&b=2&c=3", "/s?flag&x=9", "/s"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        rule.dedup_key(detail).should eq(rule.plan(detail).try(&.dedup_key))
      end
      none = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")
      rule.dedup_key(none).should be_nil
      rule.plan(none).should be_nil
    end
  end

  it "requests_per_flow is bounded at 6..10 (default posture)" do
    rule.requests_per_flow.should eq(6..10)
  end
end
