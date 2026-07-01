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
# `req_headers` is raw extra request-header lines (each ending \r\n); `req_body` the request body.
private def capture_flow(store, resp_head : String, *, scheme = "https", host = "acme.test",
                         target = "/", status = 200, content_type : String? = "text/html",
                         body : String? = nil, method = "GET", req_headers = "",
                         req_body : String? = nil) : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: req_body.try(&.to_slice))
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Run passive analysis on one flow and return the detections (ungrouped).
private def analyze(store, **kw) : Array(Gori::Prism::Detection)
  Gori::Prism::Passive.analyze(capture_flow(store, **kw))
end

private def codes_of(dets : Array(Gori::Prism::Detection)) : Array(String)
  dets.map(&.code)
end

private def make_issue(code, host = "acme.test") : Gori::Store::PrismIssue
  Gori::Store::PrismIssue.new(1_i64, code, "headers", host, "t",
    Gori::Store::Severity::Low, Gori::Store::Status::Open, 1_i64, [] of String, nil, nil, 1_i64, 1_i64)
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

describe "Gori::Prism::Passive (FP reduction)" do
  it "does not flag a dotted version string in a JS bundle as a private IP" do
    with_store do |store|
      js = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "application/javascript", body: "const VERSION='10.15.2.3';")
      codes_of(js).should_not contain("private_ip_leak")
      # ...but a genuine private IP in an HTML body IS flagged.
      html = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<p>backend at 10.0.0.5</p>")
      html.find(&.code.==("private_ip_leak")).not_nil!.evidence.should eq("10.0.0.5")
    end
  end

  it "does not treat a 5-segment version (10.1.2.3.4) as a private IP" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<span>build 10.1.2.3.4 ok</span>")
      codes_of(dets).should_not contain("private_ip_leak")
    end
  end

  it "does not flag prose containing a bare '.rb:' but flags a real backtrace frame" do
    with_store do |store|
      prose = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "Edit the helper.rb: add a method.")
      codes_of(prose).should_not contain("error_stack_leak")
      trace = analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html", body: "app/models/user.rb:42:in `save'")
      codes_of(trace).should contain("error_stack_leak")
    end
  end

  it "does not flag unsafe-inline confined to style-src, but does for script-src" do
    with_store do |store|
      safe = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                       "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'\r\n\r\n",
        content_type: "text/html")
      codes_of(safe).should_not contain("weak_csp")
      weak = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                       "default-src 'self'; script-src 'self' 'unsafe-inline'\r\n\r\n",
        content_type: "text/html")
      codes_of(weak).should contain("weak_csp")
    end
  end

  it "still demands X-Frame-Options when CSP frame-ancestors is permissive (*)" do
    with_store do |store|
      permissive = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                             "default-src 'self'; frame-ancestors *\r\n\r\n",
        content_type: "text/html")
      codes_of(permissive).should contain("missing_x_frame_options")
      restrictive = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                              "default-src 'self'; frame-ancestors 'self'\r\n\r\n",
        content_type: "text/html")
      codes_of(restrictive).should_not contain("missing_x_frame_options")
    end
  end

  it "does not fingerprint an Elasticsearch query-DSL body as GraphQL" do
    with_store do |store|
      es = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/search",
        method: "POST", req_headers: "Content-Type: application/json\r\n",
        req_body: %({"query":{"match":{"name":"x"}}}), content_type: nil)
      codes_of(es).should_not contain("tech_graphql")
      gql = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/gw",
        method: "POST", req_headers: "Content-Type: application/json\r\n",
        req_body: %({"query":"{ me { id } }"}), content_type: nil)
      codes_of(gql).should contain("tech_graphql")
    end
  end
end

describe "Gori::Prism::Passive (secret in URL)" do
  it "matches hyphen/underscore/case variants and benign-named JWT values" do
    with_store do |store|
      hyphen = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        target: "/cb?access-token=abc", content_type: nil)
      hit = hyphen.find(&.code.==("secret_in_url")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.should eq("access-token")

      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sigsigsig"
      under_benign = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        target: "/p?t=#{jwt}", content_type: nil)
      under_benign.find(&.code.==("secret_in_url")).not_nil!
        .severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "rates signed-URL params Low and ignores benign code/key params" do
    with_store do |store|
      sig = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?sig=xyz", content_type: nil)
      sig.find(&.code.==("secret_in_url")).not_nil!.severity.should eq(Gori::Store::Severity::Low)
      benign = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        target: "/list?code=42&key=pubMapsKey&page=2", content_type: nil)
      codes_of(benign).should_not contain("secret_in_url")
    end
  end
end

describe "Gori::Prism::Passive (new patterns)" do
  it "flags reflected-origin CORS with credentials as High but stays quiet without them" do
    with_store do |store|
      reflected = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.example\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://evil.example\r\n", content_type: nil)
      hit = reflected.find(&.code.==("cors_reflected_origin")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)

      no_creds = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.example\r\n\r\n",
        req_headers: "Origin: https://evil.example\r\n", content_type: nil)
      codes_of(no_creds).should_not contain("cors_reflected_origin")

      # A server echoing its OWN origin (same host) with credentials is legitimate — not flagged.
      same_origin = analyze(store, host: "acme.test",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://acme.test\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://acme.test\r\n", content_type: nil)
      codes_of(same_origin).should_not contain("cors_reflected_origin")
    end
  end

  it "flags the null CORS origin" do
    with_store do |store|
      dets = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: null\r\n\r\n", content_type: nil)
      codes_of(dets).should contain("cors_null_origin")
    end
  end

  it "flags a credential leaked in the response body (type only, never the value)" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: %({"aws":"AKIAIOSFODNN7EXAMPLE"}))
      hit = dets.find(&.code.==("secret_in_body")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.should eq("AWS access key id")
      hit.evidence.not_nil!.should_not contain("AKIA") # never the secret itself
    end
  end

  it "treats HSTS max-age=0 as disabled but a long max-age as present" do
    with_store do |store|
      disabled = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=0\r\n\r\n",
        content_type: "text/html")
      codes_of(disabled).should contain("missing_hsts")
      present = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=31536000\r\n\r\n",
        content_type: "text/html")
      codes_of(present).should_not contain("missing_hsts")
    end
  end

  it "flags SameSite=None cookies missing Secure" do
    with_store do |store|
      insecure = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=x; SameSite=None\r\n\r\n",
        content_type: "text/html")
      codes_of(insecure).should contain("cookie_samesite_none_insecure")
      ok = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=x; SameSite=None; Secure\r\n\r\n",
        content_type: "text/html")
      codes_of(ok).should_not contain("cookie_samesite_none_insecure")
      codes_of(ok).should_not contain("cookie_no_samesite")
    end
  end

  it "still flags a cookie literally named 'samesite' as missing the attribute" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: samesite=1; Path=/\r\n\r\n",
        content_type: "text/html")
      hit = dets.find(&.code.==("cookie_no_samesite")).not_nil!
      hit.evidence.should eq("samesite")
    end
  end
end

describe "Gori::Prism::Active (safety + coverage)" do
  it "does not probe mutating methods (POST), only safe ones (GET)" do
    with_store do |store|
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/comment", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: "text=hi", content_type: nil)
      Gori::Prism::Active.plan(post).should be_nil
      get = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      Gori::Prism::Active.plan(get).should_not be_nil
    end
  end

  it "keys the dedup signature by method and parameter location" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      key = Gori::Prism::Active.plan(detail).not_nil!.dedup_key
      key.should contain("GET")
      key.should contain("q@query")
    end
  end

  it "detects a canary reflected ONLY in a response header (e.g. Location)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/go?url=here", content_type: nil)
      plan = Gori::Prism::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      result = Gori::Replay::Result.new(
        "HTTP/1.1 302 Found\r\nLocation: https://site/?url=#{canary}\r\n\r\n".to_slice,
        Bytes.empty, nil, 1_i64)
      dets = Gori::Prism::Active.detections(plan, result, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("reflected_param")
    end
  end

  it "rates an HTML reflection Medium and a non-HTML (JSON) reflection Low" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Prism::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      html = Gori::Replay::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
        "<p>#{canary}</p>".to_slice, nil, 1_i64)
      Gori::Prism::Active.detections(plan, html, detail).first.severity.should eq(Gori::Store::Severity::Medium)
      json = Gori::Replay::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
        %({"q":"#{canary}"}).to_slice, nil, 1_i64)
      Gori::Prism::Active.detections(plan, json, detail).first.severity.should eq(Gori::Store::Severity::Low)
    end
  end
end

describe "Gori::Prism::Filter (incomplete terms)" do
  it "treats a mid-typed negated field term as a no-op (does not blank the list)" do
    issues = [make_issue("missing_csp"), make_issue("missing_hsts")]
    Gori::Prism::Filter.parse("-host:").apply(issues).size.should eq(2)
    Gori::Prism::Filter.parse("host:").apply(issues).size.should eq(2)
    # a complete negated term still filters
    Gori::Prism::Filter.parse("-code:csp").apply(issues).map(&.code).should eq(["missing_hsts"])
  end

  it "reports whether the query explicitly constrains status (drives the open-only lens)" do
    Gori::Prism::Filter.parse("host:api").has_status_term?.should be_false
    Gori::Prism::Filter.parse("").has_status_term?.should be_false
    Gori::Prism::Filter.parse("status:fp host:api").has_status_term?.should be_true
    Gori::Prism::Filter.parse("-st:open").has_status_term?.should be_true
  end
end

describe Gori::Prism do
  describe ".group" do
    it "folds detections exactly like Store#upsert_prism_issue (severity/hit_count/affected/evidence)" do
      with_store do |store|
        det = ->(code : String, host : String, url : String, s : Gori::Store::Severity, ev : String?) do
          Gori::Prism::Detection.new(code, "headers", host, url, "t", s, ev)
        end
        low = Gori::Store::Severity::Low
        medium = Gori::Store::Severity::Medium
        dets = [
          det.call("missing_csp", "a.test", "https://a.test/1", low, nil),
          det.call("missing_csp", "a.test", "https://a.test/2", medium, "x"), # severity rises, url accumulates
          det.call("missing_csp", "a.test", "https://a.test/1", low, "y"),    # dup url (no add); evidence already set
          det.call("missing_hsts", "b.test", "https://b.test/1", low, nil),
        ]
        dets.each { |d| store.upsert_prism_issue(d) }
        stored = store.prism_issues.to_h { |i| {"#{i.code}@#{i.host}", i} }
        grouped = Gori::Prism.group(dets).to_h { |g| {"#{g.code}@#{g.host}", g} }

        grouped.size.should eq(stored.size)
        grouped.each do |key, g|
          s = stored[key]
          g.severity.should eq(s.severity)
          g.hit_count.to_i64.should eq(s.hit_count)
          g.affected.sort.should eq(s.affected.sort)
          g.evidence.should eq(s.evidence) # first non-nil wins (COALESCE)
        end

        csp = grouped["missing_csp@a.test"]
        csp.severity.should eq(medium)                                   # max seen
        csp.hit_count.should eq(3)                                       # every observation
        csp.affected.should eq(["https://a.test/1", "https://a.test/2"]) # de-duplicated
        csp.evidence.should eq("x")                                      # first non-nil, not "y"
      end
    end

    it "sorts by severity desc and caps the affected list at PRISM_AFFECTED_CAP (hit_count still climbs)" do
      cap = Gori::Store::PRISM_AFFECTED_CAP
      dets = [] of Gori::Prism::Detection
      (cap + 10).times do |i|
        dets << Gori::Prism::Detection.new("missing_csp", "headers", "a.test",
          "https://a.test/#{i}", "t", Gori::Store::Severity::Low)
      end
      dets << Gori::Prism::Detection.new("secret_in_body", "infoleak", "a.test",
        "https://a.test/x", "t", Gori::Store::Severity::High)
      groups = Gori::Prism.group(dets)
      groups.first.code.should eq("secret_in_body") # High sorts above Low
      csp = groups.find!(&.code.==("missing_csp"))
      csp.hit_count.should eq(cap + 10) # every observation counted
      csp.affected.size.should eq(cap)  # but the URL list is capped
    end

    it "tags the same code on different hosts as separate groups" do
      dets = [
        Gori::Prism::Detection.new("missing_hsts", "headers", "a.test", "https://a.test/", "t", Gori::Store::Severity::Low),
        Gori::Prism::Detection.new("missing_hsts", "headers", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low),
      ]
      Gori::Prism.group(dets).map(&.host).sort!.should eq(["a.test", "b.test"])
    end
  end
end

describe "Store bulk Prism dismiss" do
  it "mutes only OPEN issues matching the code/host, leaving already-triaged rows untouched" do
    with_store do |store|
      det = ->(code : String, host : String, url : String) do
        Gori::Prism::Detection.new(code, "headers", host, url, "t", Gori::Store::Severity::Low)
      end
      store.upsert_prism_issue(det.call("missing_hsts", "a.test", "https://a.test/"))
      store.upsert_prism_issue(det.call("missing_csp", "a.test", "https://a.test/"))
      store.upsert_prism_issue(det.call("missing_hsts", "b.test", "https://b.test/"))

      # Promote one to confirmed: a bulk dismiss must NOT clobber an already-triaged row.
      hsts_a = store.prism_issues.find { |i| i.code == "missing_hsts" && i.host == "a.test" }.not_nil!
      store.update_prism_issue_status(hsts_a.id, Gori::Store::Status::Confirmed)

      store.dismiss_prism_by_code("missing_hsts")
      by_key = store.prism_issues.to_h { |i| {"#{i.code}@#{i.host}", i.status} }
      by_key["missing_hsts@a.test"].should eq(Gori::Store::Status::Confirmed)     # triaged → untouched
      by_key["missing_hsts@b.test"].should eq(Gori::Store::Status::FalsePositive) # open → muted
      by_key["missing_csp@a.test"].should eq(Gori::Store::Status::Open)           # other code → untouched

      store.dismiss_prism_by_host("a.test")
      after = store.prism_issues.to_h { |i| {"#{i.code}@#{i.host}", i.status} }
      after["missing_csp@a.test"].should eq(Gori::Store::Status::FalsePositive) # open on host → muted
      after["missing_hsts@a.test"].should eq(Gori::Store::Status::Confirmed)    # still untouched
    end
  end
end
