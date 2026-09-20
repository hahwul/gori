require "../../spec_helper"
require "../../support/probe_harness"

private def rl_result(status : String)
  Gori::Repeater::Result.new("HTTP/1.1 #{status}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
end

describe Gori::Probe::Active::RateLimitBypass do
  probe = Gori::Probe::Active::RateLimitBypass.new

  it "only probes originally rate-limited (429) responses with a safe method" do
    with_store do |store|
      ok = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api", status: 200, content_type: nil)
      probe.plan(ok).should be_nil
      denied = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/api", status: 403, content_type: nil)
      probe.plan(denied).should be_nil
      limited = probe_capture_flow(store, "HTTP/1.1 429 Too Many Requests\r\n\r\n", target: "/api", status: 429, content_type: nil)
      probe.plan(limited).should_not be_nil
      # A POST is never auto-probed unless the caller opts into unsafe methods.
      post = probe_capture_flow(store, "HTTP/1.1 429 Too Many Requests\r\n\r\n", target: "/api", status: 429,
        method: "POST", content_type: nil)
      probe.plan(post).should be_nil
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      probe.plan(post, unsafe).should_not be_nil
      probe.dedup_key(post, unsafe).should eq(probe.plan(post, unsafe).try(&.dedup_key))
    end
  end

  it "sends the spoofing headers on the probe and a clean control follow-up" do
    with_store do |store|
      limited = probe_capture_flow(store, "HTTP/1.1 429 Too Many Requests\r\n\r\n", target: "/api", status: 429, content_type: nil)
      plan = probe.plan(limited).not_nil!
      String.new(plan.request).should contain("X-Forwarded-For: 127.0.0.1")
      plan.followups.size.should eq(1)
      String.new(plan.followups.first).should_not contain("X-Forwarded-For")
    end
  end

  it "flags only when the spoofed probe was served AND the control is still 429" do
    with_store do |store|
      limited = probe_capture_flow(store, "HTTP/1.1 429 Too Many Requests\r\n\r\n", target: "/api", status: 429, content_type: nil)
      plan = probe.plan(limited).not_nil!

      dets = probe.detections_all(plan, [rl_result("200 OK"), rl_result("429 Too Many Requests")], limited)
      dets.size.should eq(1)
      dets.first.code.should eq("ratelimit_bypass")
      dets.first.severity.should eq(Gori::Store::Severity::Medium)

      # Probe still limited → no bypass.
      probe.detections_all(plan, [rl_result("429 Too Many Requests"), rl_result("429 Too Many Requests")], limited).should be_empty
      # Control also served → the window simply elapsed, not a header bypass.
      probe.detections_all(plan, [rl_result("200 OK"), rl_result("200 OK")], limited).should be_empty
    end
  end
end
