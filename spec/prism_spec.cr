require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-prism", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Insert a flow + response and return its full FlowDetail (what the analyzer feeds Passive).
private def capture_flow(store, resp_head : String, *, scheme = "https", host = "acme.test",
                         target = "/", status = 200, content_type : String? = "text/html",
                         body : String? = nil) : Gori::Store::FlowDetail
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def codes(store) : Array(String)
  store.prism_issues.map(&.code)
end

describe Gori::Prism::Passive do
  it "flags missing security headers, cookie flags, and a server fingerprint" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.18.0\r\n" \
             "Set-Cookie: sid=abc\r\n\r\n"
      detail = capture_flow(store, head)
      Gori::Prism::Passive.analyze(detail).each { |d| store.upsert_prism_issue(d) }

      found = codes(store)
      found.should contain("missing_hsts")
      found.should contain("missing_csp")
      found.should contain("missing_x_frame_options")
      found.should contain("missing_x_content_type_options")
      found.should contain("missing_referrer_policy")
      found.should contain("cookie_no_secure")
      found.should contain("cookie_no_httponly")
      found.should contain("cookie_no_samesite")
      found.should contain("tech_server")
    end
  end

  it "does not flag document headers when they are present" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Strict-Transport-Security: max-age=63072000\r\n" \
             "Content-Security-Policy: default-src 'self'\r\nX-Frame-Options: DENY\r\n" \
             "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n"
      detail = capture_flow(store, head)
      Gori::Prism::Passive.analyze(detail).each { |d| store.upsert_prism_issue(d) }
      codes(store).should_not contain("missing_csp")
      codes(store).should_not contain("missing_hsts")
    end
  end

  it "fingerprints gRPC and surfaces it as a project technology" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: application/grpc\r\n\r\n"
      detail = capture_flow(store, head, content_type: "application/grpc")
      Gori::Prism::Passive.analyze(detail).each { |d| store.upsert_prism_issue(d) }
      codes(store).should contain("tech_grpc")
      store.prism_tech_summary.should contain("gRPC")
    end
  end

  it "flags a sensitive parameter in the URL as High" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?token=secret123&x=1", content_type: nil)
      Gori::Prism::Passive.analyze(detail).each { |d| store.upsert_prism_issue(d) }
      issue = store.prism_issues.find(&.code.==("secret_in_url")).not_nil!
      issue.severity.should eq(Gori::Store::Severity::High)
      issue.evidence.should eq("token") # the NAME only — never the value
    end
  end

  it "groups the same issue type on one host (affected URLs accumulate, hit_count climbs)" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
      capture_flow(store, head, target: "/a").try { |d| Gori::Prism::Passive.analyze(d).each { |x| store.upsert_prism_issue(x) } }
      capture_flow(store, head, target: "/b").try { |d| Gori::Prism::Passive.analyze(d).each { |x| store.upsert_prism_issue(x) } }
      csp = store.prism_issues.find(&.code.==("missing_csp")).not_nil!
      csp.affected.size.should eq(2)
      csp.hit_count.should eq(2_i64)
      csp.affected.should contain("https://acme.test/a")
      csp.affected.should contain("https://acme.test/b")
    end
  end
end

describe Gori::Prism::Active do
  it "builds a canary probe from existing query params and detects reflection" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/search?q=hello", content_type: nil)
      plan = Gori::Prism::Active.plan(detail).not_nil!
      plan.params.size.should eq(1)
      plan.params.first.name.should eq("q")
      canary = plan.params.first.canary
      String.new(plan.request).should contain("q=#{canary}") # original value replaced

      reflected = Gori::Replay::Result.new(
        "HTTP/1.1 200 OK\r\n\r\n".to_slice, "<p>you searched #{canary}</p>".to_slice, nil, 1_i64)
      dets = Gori::Prism::Active.detections(plan, reflected, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("reflected_param")

      not_reflected = Gori::Replay::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "<p>nothing</p>".to_slice, nil, 1_i64)
      Gori::Prism::Active.detections(plan, not_reflected, detail).should be_empty
    end
  end

  it "has no probe for a request without parameters" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/app.js", content_type: nil)
      Gori::Prism::Active.plan(detail).should be_nil
    end
  end
end

describe Gori::Prism::Mode do
  it "persists per-project and defaults to Passive" do
    with_store do |store|
      store.prism_mode.should eq(Gori::Prism::Mode::Passive) # default when unset
      store.set_prism_mode(Gori::Prism::Mode::Active)
      store.prism_mode.should eq(Gori::Prism::Mode::Active)
    end
  end

  it "round-trips its label and cycles" do
    Gori::Prism::Mode.from_setting("off").should eq(Gori::Prism::Mode::Off)
    Gori::Prism::Mode.from_setting(nil).should eq(Gori::Prism::Mode::Passive)
    Gori::Prism::Mode::Off.cycle.should eq(Gori::Prism::Mode::Passive)
    Gori::Prism::Mode::Active.cycle.should eq(Gori::Prism::Mode::Off)
  end
end
