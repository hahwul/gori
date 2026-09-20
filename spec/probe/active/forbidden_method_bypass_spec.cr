require "../../spec_helper"
require "../../support/probe_harness"

private def fm_result(status : String)
  Gori::Repeater::Result.new("HTTP/1.1 #{status}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
end

describe Gori::Probe::Active::ForbiddenMethodBypass do
  probe = Gori::Probe::Active::ForbiddenMethodBypass.new

  it "only probes originally-denied (401/403) responses with a safe method" do
    with_store do |store|
      ok = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin", status: 200, content_type: nil)
      probe.plan(ok).should be_nil
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      probe.plan(forbidden).should_not be_nil
      probe.dedup_key(forbidden).should eq(probe.plan(forbidden).try(&.dedup_key))
    end
  end

  it "sends a method case-variant leg by default, plus a control" do
    with_store do |store|
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      plan.params.map(&.name).should eq(["case"])
      # The case-variant flips the first letter of the method; a case-sensitive ACL misses it.
      String.new(plan.request).each_line.first.should start_with("gET /admin ")
      # followups = [control]; the control is the captured request (GET) unchanged.
      plan.followups.size.should eq(1)
      String.new(plan.followups[0]).each_line.first.should start_with("GET /admin ")
    end
  end

  it "adds alternate verbs and a method-override leg only under allow_unsafe" do
    with_store do |store|
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      plan = probe.plan(forbidden, Gori::Probe::Active::Options.new(allow_unsafe: true)).not_nil!
      plan.params.map(&.name).should eq(["case", "POST", "PUT", "override"])
      # The override leg carries an allowed wire verb (POST) with the DENIED method in the headers.
      override = String.new(plan.followups[2]) # [POST, PUT, override, control]
      override.each_line.first.should start_with("POST /admin ")
      override.should contain("X-HTTP-Method-Override: GET")
    end
  end

  it "flags the leg that flipped to 2xx only when the control is still denied" do
    with_store do |store|
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      # [case(200), control(403)] → the case variant bypassed.
      dets = probe.detections_all(plan, [fm_result("200 OK"), fm_result("403 Forbidden")], forbidden)
      dets.size.should eq(1)
      dets.first.code.should eq("forbidden_method_bypass")
      dets.first.evidence.not_nil!.should contain("case")

      # Control served too → gate simply open, not a bypass.
      probe.detections_all(plan, [fm_result("200 OK"), fm_result("200 OK")], forbidden).should be_empty
      # No leg flipped → nothing.
      probe.detections_all(plan, [fm_result("403 Forbidden"), fm_result("403 Forbidden")], forbidden).should be_empty
    end
  end
end
