require "../../spec_helper"
require "../../support/probe_harness"

describe Gori::Probe::Active::InsecureHttpMethods do
  probe = Gori::Probe::Active::InsecureHttpMethods.new

  it "sends an OPTIONS probe and a TRACE probe carrying a reflection canary" do
    with_store do |store|
      flow = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/app", content_type: nil)
      plan = probe.plan(flow).not_nil!
      String.new(plan.request).each_line.first.should start_with("OPTIONS /app ")
      plan.followups.size.should eq(1)
      trace = String.new(plan.followups.first)
      trace.each_line.first.should start_with("TRACE /app ")
      canary = plan.params.first.canary
      trace.should contain("X-Gori-Trace: #{canary}")
      probe.dedup_key(flow).should eq(plan.dedup_key)
    end
  end

  it "flags dangerous methods advertised in Allow and TRACE that echoes the request" do
    with_store do |store|
      flow = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/app", content_type: nil)
      plan = probe.plan(flow).not_nil!
      canary = plan.params.first.canary

      options = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nAllow: GET, POST, PUT, DELETE, OPTIONS\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      trace = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        "TRACE /app HTTP/1.1\r\nX-Gori-Trace: #{canary}\r\n".to_slice, nil, 1_i64)

      codes = probe.detections_all(plan, [options, trace], flow).map(&.code)
      codes.should contain("dangerous_methods_allowed")
      codes.should contain("trace_enabled")
    end
  end

  it "does not flag a safe Allow list or a TRACE the server rejected" do
    with_store do |store|
      flow = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/app", content_type: nil)
      plan = probe.plan(flow).not_nil!

      options = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nAllow: GET, HEAD, POST, OPTIONS\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      trace = Gori::Repeater::Result.new(
        "HTTP/1.1 405 Method Not Allowed\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections_all(plan, [options, trace], flow).should be_empty
    end
  end

  it "does not flag a TRACE 200 whose body does not echo our canary" do
    with_store do |store|
      flow = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/app", content_type: nil)
      plan = probe.plan(flow).not_nil!
      options = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nAllow: GET\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      trace = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\n\r\n".to_slice, "a generic 200 page, no echo".to_slice, nil, 1_i64)
      probe.detections_all(plan, [options, trace], flow).should be_empty
    end
  end
end
