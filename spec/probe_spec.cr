require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-probe", ".db")
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
private def analyze(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw))
end

private def codes_of(dets : Array(Gori::Probe::Detection)) : Array(String)
  dets.map(&.code)
end

private def make_issue(code, host = "acme.test") : Gori::Store::ProbeIssue
  Gori::Store::ProbeIssue.new(1_i64, code, "headers", host, "t",
    Gori::Store::Severity::Low, Gori::Store::Status::Open, 1_i64, [] of String, nil, nil, 1_i64, 1_i64)
end

private def codes(store) : Array(String)
  store.probe_issues.map(&.code)
end

describe Gori::Probe::Passive do
  it "flags missing security headers, cookie flags, and a server fingerprint" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.18.0\r\n" \
             "Set-Cookie: sid=abc\r\n\r\n"
      detail = capture_flow(store, head)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }

      found = codes(store)
      found.should contain("missing_hsts")
      found.should contain("missing_csp")
      found.should contain("missing_x_frame_options")
      found.should contain("missing_x_content_type_options")
      found.should contain("missing_referrer_policy")
      found.should contain("missing_permissions_policy")
      found.should contain("cookie_no_secure")
      found.should contain("cookie_no_httponly")
      found.should contain("cookie_no_samesite")
      found.should contain("tech_server")
    end
  end

  it "detects a GitHub fine-grained personal access token in a response body" do
    with_store do |store|
      body = %({"token":"github_pat_11ABCDEFGHIJKLMNOPQRSTUV_abcdefghijklmno"})
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: body)
      codes_of(dets).should contain("secret_in_body")
    end
  end

  it "does not flag a Spring class name in prose, but does flag a real Spring frame" do
    with_store do |store|
      prose = "See the JavaDoc at org.springframework.boot.SpringApplication for details."
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", body: prose))
        .should_not contain("error_stack_leak")
      frame = "err\n\tat org.springframework.aop.framework.CglibAopProxy.intercept(Native Method)"
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", body: frame))
        .should contain("error_stack_leak")
    end
  end

  it "does not treat a non-adjacent version word as version context for a private-IP leak" do
    with_store do |store|
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: "Our firmware serves 10.0.0.5 today")).should contain("private_ip_leak")
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: "File version 10.0.1.2 released")).should_not contain("private_ip_leak")
    end
  end

  it "flags cleartext Basic auth even behind a later duplicate Authorization header" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        scheme: "http", req_headers: "Authorization: Basic dXNlcjpwYXNz\r\nAuthorization: Bearer tok\r\n")
      codes_of(dets).should contain("insecure_basic_auth")
    end
  end

  it "does not flag CORS when the response carries duplicate ACAO headers (browser blocks it)" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Origin: https://x.test\r\n\r\n"
      codes_of(analyze(store, resp_head: head)).should_not contain("cors_wildcard")
    end
  end

  it "does not flag document headers when they are present" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Strict-Transport-Security: max-age=63072000\r\n" \
             "Content-Security-Policy: default-src 'self'\r\nX-Frame-Options: DENY\r\n" \
             "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n"
      detail = capture_flow(store, head)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      codes(store).should_not contain("missing_csp")
      codes(store).should_not contain("missing_hsts")
    end
  end

  it "fingerprints gRPC and surfaces it as a project technology" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: application/grpc\r\n\r\n"
      detail = capture_flow(store, head, content_type: "application/grpc")
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      codes(store).should contain("tech_grpc")
      store.probe_tech_summary.should contain("gRPC")
    end
  end

  it "fingerprints framework/version-disclosure headers and surfaces them as project tech" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nX-AspNet-Version: 4.0.30319\r\n" \
             "X-AspNetMvc-Version: 5.2\r\nX-Generator: Drupal 10 (https://www.drupal.org)\r\n\r\n"
      detail = capture_flow(store, head)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      found = codes(store)
      found.should contain("tech_aspnet")
      found.should contain("tech_aspnetmvc")
      found.should contain("tech_generator")
      summary = store.probe_tech_summary
      summary.should contain("ASP.NET")
      summary.should contain("ASP.NET MVC")
      summary.should contain("Drupal") # X-Generator value reduced to the product name
      # The exact version is kept in the issue evidence (the CVE-matching detail an analyst wants).
      store.probe_issues.find(&.code.==("tech_aspnet")).not_nil!.evidence.should eq("4.0.30319")
    end
  end

  it "flags a sensitive parameter in the URL as High" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?token=secret123&x=1", content_type: nil)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      issue = store.probe_issues.find(&.code.==("secret_in_url")).not_nil!
      issue.severity.should eq(Gori::Store::Severity::High)
      issue.evidence.should eq("token") # the NAME only — never the value
    end
  end

  it "groups the same issue type on one host (affected URLs accumulate, hit_count climbs)" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
      capture_flow(store, head, target: "/a").try { |d| Gori::Probe::Passive.analyze(d).each { |x| store.upsert_probe_issue(x) } }
      capture_flow(store, head, target: "/b").try { |d| Gori::Probe::Passive.analyze(d).each { |x| store.upsert_probe_issue(x) } }
      csp = store.probe_issues.find(&.code.==("missing_csp")).not_nil!
      csp.affected.size.should eq(2)
      csp.hit_count.should eq(2_i64)
      csp.affected.should contain("https://acme.test/a")
      csp.affected.should contain("https://acme.test/b")
    end
  end

  # A plaintext forward-proxy request is captured ABSOLUTE-form (the wire truth), so
  # FlowRow#target already carries the scheme+authority. The affected URL must be that
  # target verbatim — NOT "http://hosthttp://host:port/path" (the doubling a naive
  # "scheme://host + target" produced before FlowRow#url).
  it "does not double the scheme+host for an absolute-form (plain-HTTP) target" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        scheme: "http", host: "127.0.0.1", target: "http://127.0.0.1:8899/cors")
      urls = Gori::Probe::Passive.analyze(detail).map(&.url).uniq!
      urls.should eq(["http://127.0.0.1:8899/cors"])
      urls.first.should_not contain("127.0.0.1http://")
    end
  end
end

describe Gori::Store::FlowRow do
  it "#url builds an absolute URL: absolute-form verbatim, non-default port kept, IPv6 bracketed" do
    mk = ->(scheme : String, host : String, port : Int32, target : String) do
      Gori::Store::FlowRow.new(1_i64, 0_i64, scheme, "GET", host, port, target, 200,
        0_i64, Gori::Store::FlowState::Complete)
    end
    mk.call("https", "ex.com", 443, "/a").url.should eq("https://ex.com/a")       # default port omitted
    mk.call("https", "ex.com", 8443, "/a").url.should eq("https://ex.com:8443/a") # non-default port kept
    mk.call("http", "::1", 8080, "/a").url.should eq("http://[::1]:8080/a")       # IPv6 literal bracketed
    mk.call("http", "h", 80, "http://h:8899/x").url.should eq("http://h:8899/x")  # absolute-form verbatim
  end
end

describe Gori::Probe::Active do
  it "builds a canary probe from existing query params and detects reflection" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/search?q=hello", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      plan.params.size.should eq(1)
      plan.params.first.name.should eq("q")
      canary = plan.params.first.canary
      String.new(plan.request).should contain("q=#{canary}") # original value replaced

      reflected = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\n\r\n".to_slice, "<p>you searched #{canary}</p>".to_slice, nil, 1_i64)
      dets = Gori::Probe::Active.detections(plan, reflected, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("reflected_param")

      not_reflected = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "<p>nothing</p>".to_slice, nil, 1_i64)
      Gori::Probe::Active.detections(plan, not_reflected, detail).should be_empty
    end
  end

  it "has no probe for a request without parameters" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/app.js", content_type: nil)
      Gori::Probe::Active.plan(detail).should be_nil
    end
  end

  it "sends an ORIGIN-FORM request line even for an absolute-form (forward-proxy) target" do
    with_store do |store|
      # A plaintext forward-proxy flow is captured absolute-form; the probe goes DIRECT to
      # the origin, so its request line must be origin-form (some origins reject absolute-form).
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "target.com",
        target: "http://target.com/search?q=hello", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /search?q=")
      line.should_not contain("http://target.com")
    end
  end

  # The analyzer now checks `rule.dedup_key(detail)` BEFORE building the full `plan`, to skip the
  # canary generation + request rebuild on a repeat surface. This is only correct if the cheap key
  # is IDENTICAL to `plan(detail).dedup_key` (and nil in exactly the same cases) — otherwise the
  # seen-set would re-probe or wrongly suppress. Assert that equivalence across a broad corpus.
  it "dedup_key equals plan.dedup_key across query/form/json/edge-case flows (both rules)" do
    with_store do |store|
      form_ct = "Content-Type: application/x-www-form-urlencoded\r\n"
      json_ct = "Content-Type: application/json\r\n"
      cors_resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://app.example\r\n\r\n"
      plain_resp = "HTTP/1.1 200 OK\r\n\r\n"
      many = (0..50).map { |i| "p#{i}=v" }.join("&") # 51 params → over MAX_PARAMS

      cases = [
        {target: "/search?q=hello&lang=en", method: "GET", rh: "", rb: nil, resp: plain_resp},
        {target: "/a?x=1&x=2", method: "GET", rh: "", rb: nil, resp: plain_resp},            # duplicate name
        {target: "/a?%6eame=v&z=2", method: "GET", rh: "", rb: nil, resp: plain_resp},       # URL-encoded name
        {target: "/a?flag&y=2&=nope&w=3", method: "GET", rh: "", rb: nil, resp: plain_resp}, # bare flag / empty name
        {target: "/nothing", method: "GET", rh: "", rb: nil, resp: plain_resp},              # no params → nil
        {target: "/a?x=1", method: "POST", rh: "", rb: nil, resp: plain_resp},               # unsafe method → nil
        {target: "/a?x=1", method: "HEAD", rh: "", rb: nil, resp: plain_resp},               # HEAD is safe
        {target: "/submit", method: "GET", rh: form_ct, rb: "user=alice&pass=x&token=", resp: plain_resp},
        {target: "/j", method: "GET", rh: json_ct, rb: %({"a":"s","b":2,"c":"t","d":null}), resp: plain_resp}, # str fields a,c
        {target: "/j", method: "GET", rh: json_ct, rb: %({"a":1,"b":2}), resp: plain_resp},                    # no string field → nil
        {target: "/j?q=1", method: "GET", rh: json_ct, rb: %({"a":1}), resp: plain_resp},                      # query only (json no str)
        {target: "/j?q=1", method: "GET", rh: "", rb: %({"a":"s"}), resp: plain_resp},                         # body but non-json/form ct
        {target: "/many?#{many}", method: "GET", rh: "", rb: nil, resp: plain_resp},                           # > MAX_PARAMS → nil
        {target: "http://target.com/s?q=hello", method: "GET", rh: "", rb: nil, resp: plain_resp},             # absolute-form
        {target: "/cors", method: "GET", rh: "", rb: nil, resp: cors_resp},                                    # CORS present
        {target: "/cors?q=1", method: "GET", rh: "", rb: nil, resp: cors_resp},                                # CORS + query
        {target: "/nocors", method: "GET", rh: "", rb: nil, resp: plain_resp},                                 # CORS absent → nil
        {target: "/cors", method: "POST", rh: "", rb: nil, resp: cors_resp},                                   # CORS unsafe method → nil
        {target: "/has space?q=1", method: "GET", rh: "", rb: nil, resp: plain_resp},                          # malformed start-line (space→4 parts) → nil, both paths
        {target: "/has space", method: "GET", rh: form_ct, rb: "a=1", resp: cors_resp},                        # malformed + body + CORS: fast path must still reject pre-body-parse
      ]

      reflected = Gori::Probe::Active::ReflectedParam.new
      cors = Gori::Probe::Active::CorsReflection.new
      cases.each do |c|
        d = capture_flow(store, c[:resp], scheme: "http", host: "t.example",
          target: c[:target], method: c[:method], req_headers: c[:rh], req_body: c[:rb], content_type: nil)
        reflected.dedup_key(d).should eq(reflected.plan(d).try(&.dedup_key)), "reflected_param #{c[:target]} #{c[:method]}"
        cors.dedup_key(d).should eq(cors.plan(d).try(&.dedup_key)), "cors #{c[:target]} #{c[:method]}"
      end
    end
  end

  it "normalizes an absolute-form target to origin-form, preserving a query on a PATHLESS URI" do
    # The authority ends at the first '/', '?' or '#': a pathless absolute-URI carrying a query
    # must keep it (was collapsed to "/", silently dropping the reflectable surface), and a '/'
    # that appears only inside the query must not be mistaken for the path.
    Gori::Probe::Active.origin_form("http://h/p?q=1").should eq("/p?q=1")
    Gori::Probe::Active.origin_form("http://h?q=1").should eq("/?q=1")
    Gori::Probe::Active.origin_form("https://h?a=1&b=2").should eq("/?a=1&b=2")
    Gori::Probe::Active.origin_form("http://h?next=/x").should eq("/?next=/x")
    Gori::Probe::Active.origin_form("http://h").should eq("/")
    Gori::Probe::Active.origin_form("/already?x=1").should eq("/already?x=1") # already origin-form
  end

  it "builds a reflected-param probe for a PATHLESS absolute-form target that carries a query" do
    with_store do |store|
      # Captured plaintext forward-proxy flow, absolute-form, empty path + query. Previously
      # origin_form dropped the query to "/", so plan() found no params and returned nil.
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "target.com",
        target: "http://target.com?name=hello", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["name"])
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /?name=")
      line.should_not contain("http://target.com")
    end
  end
end

describe Gori::Probe::Analyzer do
  # Active only processes live channel events unless backfill re-arms recent History.
  # Without that, switching Passive→Active (or reopening a project already on Active)
  # never probes flows that already completed passive analysis.
  it "set_mode Active and start(Active) re-arm without raising on stored flows" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      feed = Channel(Gori::Store::FlowEvent).new(8)

      # start while already Active (persisted project) — backfill path
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Active, true)
      a.start
      sleep 50.milliseconds # let the backfill fiber run (no network assert — queue may drop)
      a.stop

      # Passive → Active transition mid-session
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      b = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Passive, true)
      b.start
      b.set_mode(Gori::Probe::Mode::Active)
      sleep 50.milliseconds
      b.stop
    end
  end

  it "does not re-count a buffered WebSocket secret on every later frame (incremental rescan)" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      store.insert_ws_message(fid, "in", 1, "token=AKIAIOSFODNN7EXAMPLE".to_slice) # secret frame
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # initial full scan → detect once
      sleep 120.milliseconds
      store.probe_issues.find(&.code.== "secret_in_ws").not_nil!.hit_count.should eq(1_i64)
      # A later, secret-free frame must NOT re-scan the still-buffered secret frame.
      store.insert_ws_message(fid, "in", 1, "ping".to_slice)
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # rescan → only the new frame
      sleep 120.milliseconds
      store.probe_issues.find(&.code.== "secret_in_ws").not_nil!.hit_count.should eq(1_i64)
      a.stop
    end
  end

  it "pages a >WS_MSG_CAP WebSocket backlog without skipping a band (no missed secret)" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      store.insert_ws_message(fid, "in", 1, "hello".to_slice) # frame 1 (no secret) → sets hwm
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # initial scan; hwm = frame 1
      sleep 120.milliseconds
      # A burst of >WS_MSG_CAP(200) frames arrives with the secret in frame ~30 — the band a
      # last-200-window rescan would drop (window would be frames ~52..251).
      250.times do |k|
        payload = k == 28 ? "token=AKIAIOSFODNN7EXAMPLE" : "frame#{k}"
        store.insert_ws_message(fid, "in", 1, payload.to_slice)
      end
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # one rescan must page the whole backlog
      sleep 250.milliseconds
      store.probe_issues.count(&.code.== "secret_in_ws").should eq(1) # the banded secret was caught
      a.stop
    end
  end

  it "scans a WebSocket flow FIRST seen with a large backlog from its oldest frame" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      # A >WS_MSG_CAP backlog already exists before the FIRST scan (the live :updated was dropped
      # and catch_up picks it up late); the secret is in an OLD frame the last-window would skip.
      260.times do |k|
        payload = k == 20 ? "token=AKIAIOSFODNN7EXAMPLE" : "frame#{k}"
        store.insert_ws_message(fid, "in", 1, payload.to_slice)
      end
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # first scan pages the whole backlog from frame 1
      sleep 250.milliseconds
      store.probe_issues.count(&.code.== "secret_in_ws").should eq(1)
      a.stop
    end
  end

  it "bumps store.probe_generation on persist and honors session suppress after hard delete" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: x\r\n\r\n",
        target: "/", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      g0 = store.probe_generation

      a.scan_detail(detail)
      store.probe_generation.should be > g0
      before = store.count_probe_issues
      before.should be > 0

      # Simulate UI hard-delete + suppress of one issue (suppress first, like the TUI)
      issue = store.probe_issues.first
      a.suppress(issue.code, issue.host)
      store.delete_probe_issue(issue.id)
      store.count_probe_issues.should eq(before - 1)

      # Fresh flow on the same host: suppressed code must not resurrect
      d2 = capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: x\r\n\r\n",
        target: "/b", body: "<p>hi</p>")
      a.scan_detail(d2)
      store.probe_issues.count { |i| i.code == issue.code && i.host == issue.host }.should eq(0)
    end
  end

  # Regression: delete used to only mute for the current process. Project leave/re-open
  # built a new Analyzer (empty @suppressed) and Active backfill re-inserted the row.
  it "hard-delete survives a new Analyzer (project re-open) via durable suppressions" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx\r\n\r\n",
        target: "/", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.scan_detail(detail)
      issue = store.probe_issues.find(&.code.==("tech_server")).not_nil!
      code, host = issue.code, issue.host

      # TUI delete path: memory suppress + store delete (store also writes probe_suppressions)
      a.suppress(code, host)
      store.delete_probe_issue(issue.id)
      store.probe_suppressed?(code, host).should be_true
      store.count_probe_issues.should eq(store.probe_issues.size)

      # Simulate leave_project → open again: brand-new Analyzer loads durable suppressions
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      b = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Passive, true)
      b.start # load_suppressions
      d2 = capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx\r\n\r\n",
        target: "/again", body: "<p>hi</p>")
      b.scan_detail(d2)
      store.probe_issues.count { |i| i.code == code && i.host == host }.should eq(0)

      # Store-level gate alone (no analyzer suppress) also blocks direct upsert
      det = Gori::Probe::Detection.new(code, "tech", host, "https://#{host}/", "Server: nginx",
        Gori::Store::Severity::Info, "nginx", d2.row.id)
      store.upsert_probe_issue(det)
      store.probe_issues.count { |i| i.code == code && i.host == host }.should eq(0)

      b.stop
    end
  end

  it "clear_probe_issues drops durable suppressions so a full rescan can re-find" do
    with_store do |store|
      d = Gori::Probe::Detection.new("reflected_param", "active", "xss.test", "https://xss.test/",
        "Reflected parameter", Gori::Store::Severity::Medium, "q", 1_i64)
      store.upsert_probe_issue(d)
      id = store.probe_issues.first.id
      store.delete_probe_issue(id)
      store.probe_suppressed?("reflected_param", "xss.test").should be_true

      store.clear_probe_issues
      store.probe_suppressed?("reflected_param", "xss.test").should be_false
      store.upsert_probe_issue(d)
      store.count_probe_issues.should eq(1)
    end
  end
end

describe Gori::Probe::Mode do
  it "persists per-project and defaults to Passive" do
    with_store do |store|
      store.probe_mode.should eq(Gori::Probe::Mode::Passive) # default when unset
      store.set_probe_mode(Gori::Probe::Mode::Active)
      store.probe_mode.should eq(Gori::Probe::Mode::Active)
    end
  end

  it "round-trips its label and cycles" do
    Gori::Probe::Mode.from_setting("off").should eq(Gori::Probe::Mode::Off)
    Gori::Probe::Mode.from_setting(nil).should eq(Gori::Probe::Mode::Passive)
    Gori::Probe::Mode::Off.cycle.should eq(Gori::Probe::Mode::Passive)
    Gori::Probe::Mode::Active.cycle.should eq(Gori::Probe::Mode::Off)
  end
end

describe "Gori::Probe::Passive (FP reduction)" do
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

  it "does not flag loopback 127.0.0.1 as a private IP but still flags an RFC 1918 address" do
    with_store do |store|
      # Loopback aids no recon and is ubiquitous in bundles/configs (a near-pure FP source).
      loopback = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<p>dev server on http://127.0.0.1:3000/</p>")
      codes_of(loopback).should_not contain("private_ip_leak")
      # A real internal (RFC 1918) address is still surfaced.
      internal = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<p>proxy 192.168.1.20</p>")
      internal.find(&.code.==("private_ip_leak")).not_nil!.evidence.should eq("192.168.1.20")
    end
  end

  it "does not flag document headers on a 3xx redirect (not rendered), but still on an error page" do
    with_store do |store|
      # A 302 with text/html (the ubiquitous "Redirecting…" body) is FOLLOWED, never rendered,
      # so its missing CSP/XFO/XCTO/Referrer are noise — the real target page is checked on its
      # own flow. HSTS still applies to the HTTPS redirect response.
      redirect = analyze(store, resp_head: "HTTP/1.1 302 Found\r\nLocation: /home\r\n\r\n",
        status: 302, content_type: "text/html")
      codes_of(redirect).should_not contain("missing_csp")
      codes_of(redirect).should_not contain("missing_x_frame_options")
      codes_of(redirect).should_not contain("missing_referrer_policy")
      codes_of(redirect).should contain("missing_hsts")
      # A 4xx/5xx error page IS a rendered document (framable / may reflect) — keep the checks.
      error = analyze(store, resp_head: "HTTP/1.1 404 Not Found\r\n\r\n",
        status: 404, content_type: "text/html")
      codes_of(error).should contain("missing_csp")
      codes_of(error).should contain("missing_x_frame_options")
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

  it "does not flag a nonce/hash/strict-dynamic CSP that keeps 'unsafe-inline' for CSP2 fallback" do
    with_store do |store|
      # CSP Level 3: a nonce (or hash, or strict-dynamic) makes browsers IGNORE 'unsafe-inline',
      # so this modern policy is SAFE and must not trip weak_csp (the common FP).
      nonce = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                        "script-src 'self' 'unsafe-inline' 'nonce-abc123'\r\n\r\n",
        content_type: "text/html")
      codes_of(nonce).should_not contain("weak_csp")
      hash = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                       "script-src 'unsafe-inline' 'sha256-abc123def456ghi789'\r\n\r\n",
        content_type: "text/html")
      codes_of(hash).should_not contain("weak_csp")
      # strict-dynamic also nullifies 'unsafe-inline' AND host/scheme sources (https:, *).
      strict = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                         "script-src 'strict-dynamic' 'nonce-x' 'unsafe-inline' https: *\r\n\r\n",
        content_type: "text/html")
      codes_of(strict).should_not contain("weak_csp")
    end
  end

  it "still flags 'unsafe-eval' and a 'data:' script source (neither is nullified by a nonce)" do
    with_store do |store|
      # 'unsafe-eval' executes regardless of nonces/strict-dynamic → always weak.
      eval_csp = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                           "script-src 'self' 'nonce-x' 'unsafe-eval'\r\n\r\n",
        content_type: "text/html")
      codes_of(eval_csp).should contain("weak_csp")
      # a 'data:' script source allows data-URI scripts (XSS) when strict-dynamic is absent.
      data_csp = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                           "script-src 'self' data:\r\n\r\n",
        content_type: "text/html")
      codes_of(data_csp).should contain("weak_csp")
    end
  end

  it "flags a bare https:/http: scheme source in script-src, but not a specific https host" do
    with_store do |store|
      # A bare 'https:' scheme source is an allowlist that permits ANY host over https to serve
      # scripts — effectively allow-all, and flagged by CSP evaluators as weak (was a FN here).
      scheme = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                         "script-src 'self' https:\r\n\r\n", content_type: "text/html")
      codes_of(scheme).should contain("weak_csp")
      http = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                       "default-src 'self'; script-src http:\r\n\r\n", content_type: "text/html")
      codes_of(http).should contain("weak_csp")
      # A SPECIFIC host over https is a distinct token — a normal, safe allowlist entry.
      host = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                       "script-src 'self' https://cdn.example.com\r\n\r\n", content_type: "text/html")
      codes_of(host).should_not contain("weak_csp")
    end
  end

  it "rates a wildcard CORS with credentials Medium (the combination is browser-rejected, not High)" do
    with_store do |store|
      dets = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n", content_type: nil)
      hit = dets.find(&.code.==("cors_wildcard")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "flags a Go panic dump and Stripe/SendGrid/npm secrets (type only, never the value)" do
    with_store do |store|
      go = analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html",
        body: "panic: runtime error\n\ngoroutine 1 [running]:\nmain.main()\n\t/app/main.go:10 +0x1d")
      codes_of(go).should contain("error_stack_leak")
      stripe = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: %({"key":"sk_live_ABCDEFGHIJKLMNOPQRSTUVWX"}))
      hit = stripe.find(&.code.==("secret_in_body")).not_nil!
      hit.evidence.should eq("Stripe secret key")
      hit.evidence.not_nil!.should_not contain("sk_live")
      sendgrid = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "SG.abcdefghijklmnop.qrstuvwxyz0123456789")
      sendgrid.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("SendGrid API key")
      npm = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "//registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwxyz0123456789")
      npm.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("npm access token")
      # a prose mention of "goroutine" (no `[state]:` header) must NOT trip.
      prose = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "Launch a goroutine to handle each request.")
      codes_of(prose).should_not contain("error_stack_leak")
    end
  end

  it "reports EVERY distinct secret and error type present in one body, not just the first" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html",
        body: "AKIAABCDEFGHIJKLMNOP ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa " \
              "sk_live_ABCDEFGHIJKLMNOPQRSTUV npm_abcdefghijklmnopqrstuvwxyz0123456789\n" \
              "java.lang.NullPointerException: boom\n\ngoroutine 7 [running]:\nmain.main()")
      secrets = dets.select(&.code.==("secret_in_body")).map(&.evidence)
      secrets.should contain("AWS access key id")
      secrets.should contain("GitHub token")
      secrets.should contain("Stripe secret key")
      secrets.should contain("npm access token") # every distinct type, was: only "AWS access key id"
      errors = dets.select(&.code.==("error_stack_leak")).map(&.evidence)
      errors.should contain("Java exception")
      errors.should contain("Go stack trace") # was: only "Java exception"
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

  it "does not fingerprint an ordinary JSON POST with no query field as GraphQL" do
    with_store do |store|
      plain = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/orders",
        method: "POST", req_headers: "Content-Type: application/json\r\n",
        req_body: %({"items":[{"id":1,"qty":2}],"note":"ship fast"}), content_type: nil)
      codes_of(plain).should_not contain("tech_graphql")
    end
  end
end

describe "Gori::Probe::Passive (secret in URL)" do
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

describe "Gori::Probe::Passive (new patterns)" do
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

  it "flags a CROSS-SCHEME/CROSS-PORT same-host credentialed reflection (not just cross-host)" do
    with_store do |store|
      # Page is https://acme.test (:443); the reflected Origin is the SAME host but a different
      # scheme — genuinely a different origin, and exploitable with credentials.
      cross_scheme = analyze(store, scheme: "https", host: "acme.test",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: http://acme.test\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: http://acme.test\r\n", content_type: nil)
      codes_of(cross_scheme).should contain("cors_reflected_origin")
      cross_port = analyze(store, scheme: "https", host: "acme.test",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://acme.test:8443\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://acme.test:8443\r\n", content_type: nil)
      codes_of(cross_port).should contain("cors_reflected_origin")
      # A bracketed IPv6 literal echoing its OWN origin is same-origin — not a false positive.
      ipv6_same = analyze(store, scheme: "https", host: "::1",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://[::1]\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://[::1]\r\n", content_type: nil)
      codes_of(ipv6_same).should_not contain("cors_reflected_origin")
    end
  end

  it "flags a CSP that restricts nothing about scripts (no script-src and no default-src)" do
    with_store do |store|
      # A CSP present but with neither script-src nor default-src leaves scripts fully
      # unrestricted, yet its mere presence suppresses missing_csp — it must trip weak_csp.
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: img-src 'self'\r\n\r\n",
        content_type: "text/html")
      codes_of(dets).should contain("weak_csp")
      codes_of(dets).should_not contain("missing_csp")
      # A restrictive default-src is NOT weak.
      ok = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self'\r\n\r\n",
        content_type: "text/html")
      codes_of(ok).should_not contain("weak_csp")
    end
  end

  it "does not flag ordinary docs/tutorial prose that merely NAMES error types" do
    with_store do |store|
      {
        %({"path":"config/routes.rb:15"}),           # a config path value, not a Ruby backtrace frame
        "See the ActiveRecord::Base guide.",         # a class name in prose, not a Rails error
        "Import org.springframework.boot to start.", # a package name, not a Spring trace frame
        "Throws System.ArgumentException on null.",  # a .NET type named in prose
        "Handle java.lang.IllegalStateException gracefully.",
      }.each do |prose|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html", body: prose)
        codes_of(dets).should_not contain("error_stack_leak")
      end
      # …but genuinely error-shaped disclosures still fire (incl. real Python/PHP frames and
      # an error-shaped ActiveRecord class the tightened patterns must still catch).
      {
        "java.lang.IllegalStateException: bad state\n\tat com.acme.Svc.handle(Svc.java:42)",
        "File \"/srv/app.py\", line 42, in handler",      # real CPython frame
        "#0 /var/www/app.php(42): Foo->bar()\n#1 {main}", # real PHP trace frame
        "ActiveRecord::RecordNotFound: Couldn't find User",
        "ActiveRecord::Rollback: transaction rolled back", # AR class the whitelist used to miss
      }.each do |leak|
        dets = analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
          content_type: "text/html", body: leak)
        codes_of(dets).should contain("error_stack_leak")
      end
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

  describe "cacheable JSON API responses" do
    it "flags application/json without Cache-Control (sensitive data may be stored)" do
      with_store do |store|
        dets = analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"token":"x"}))
        hit = dets.find(&.code.==("cacheable_json")).not_nil!
        hit.severity.should eq(Gori::Store::Severity::Medium)
        hit.title.should contain("missing Cache-Control")
      end
    end

    it "flags public / positive max-age / s-maxage without no-store" do
      with_store do |store|
        [
          "Cache-Control: public, max-age=60",
          "Cache-Control: max-age=3600",
          "Cache-Control: s-maxage=120, private",
        ].each do |cc|
          head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n#{cc}\r\n\r\n"
          codes_of(analyze(store, resp_head: head, content_type: "application/json",
            body: "{}")).should contain("cacheable_json")
        end
      end
    end

    it "does not flag when Cache-Control includes no-store" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
               "Cache-Control: no-store, no-cache, private, max-age=0\r\n\r\n"
        codes_of(analyze(store, resp_head: head, content_type: "application/json",
          body: %({"ok":true}))).should_not contain("cacheable_json")
      end
    end

    it "does not flag HTML documents or empty JSON bodies" do
      with_store do |store|
        html = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
          content_type: "text/html", body: "<html></html>")
        codes_of(html).should_not contain("cacheable_json")
        empty = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: nil)
        codes_of(empty).should_not contain("cacheable_json")
      end
    end

    it "covers application/*+json (e.g. problem+json)" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/problem+json\r\n\r\n"
        codes_of(analyze(store, resp_head: head, content_type: "application/problem+json",
          body: %({"title":"err"}))).should contain("cacheable_json")
      end
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

describe "Gori::Probe::Passive (cookie deletion + prefixes)" do
  it "suppresses hygiene issues for a cookie being cleared (empty value + deletion marker)" do
    with_store do |store|
      # A logout/reset cookie carries no secret — its missing flags are noise, not an issue.
      maxage = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=; Max-Age=0\r\n\r\n",
        content_type: "text/html")
      codes_of(maxage).should_not contain("cookie_no_secure")
      codes_of(maxage).should_not contain("cookie_no_httponly")
      codes_of(maxage).should_not contain("cookie_no_samesite")
      expired = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=; expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n",
        content_type: "text/html")
      codes_of(expired).should_not contain("cookie_no_httponly")
      # …but a LIVE empty cookie (no deletion marker) is still ordinary hygiene.
      live = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: foo=bar\r\n\r\n",
        content_type: "text/html")
      codes_of(live).should contain("cookie_no_secure")
    end
  end

  it "flags __Host-/__Secure- prefix violations and suppresses the duplicate no-secure issue" do
    with_store do |store|
      # __Host- requires Secure, Path=/, and no Domain — this one is missing Path=/.
      host_bad = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-sid=x; Secure\r\n\r\n",
        content_type: "text/html")
      hit = host_bad.find(&.code.==("cookie_prefix_violation")).not_nil!
      hit.evidence.not_nil!.should contain("Path=/")
      # A correctly-formed __Host- cookie is clean.
      host_ok = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-sid=x; Secure; Path=/\r\n\r\n",
        content_type: "text/html")
      codes_of(host_ok).should_not contain("cookie_prefix_violation")
      # A __Host- cookie with a Domain attribute is rejected by the browser.
      host_dom = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-sid=x; Secure; Path=/; Domain=acme.test\r\n\r\n",
        content_type: "text/html")
      host_dom.find(&.code.==("cookie_prefix_violation")).not_nil!.evidence.not_nil!.should contain("Domain")
      # __Secure- missing Secure trips the prefix violation but NOT the generic cookie_no_secure.
      sec_bad = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Secure-sid=x\r\n\r\n",
        content_type: "text/html")
      codes_of(sec_bad).should contain("cookie_prefix_violation")
      codes_of(sec_bad).should_not contain("cookie_no_secure")
    end
  end
end

describe "Gori::Probe::Passive (GraphQL introspection)" do
  it "flags a response carrying an introspection result (full schema exposed)" do
    with_store do |store|
      introspection = analyze(store, target: "/graphql", method: "POST",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", content_type: "application/json",
        body: %({"data":{"__schema":{"queryType":{"name":"Query"},"types":[{"name":"User"}]}}}))
      codes_of(introspection).should contain("graphql_introspection")
      hit = introspection.find(&.code.==("graphql_introspection")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not flag ordinary GraphQL data or a stray __schema mention" do
    with_store do |store|
      # A normal query result has neither introspection marker.
      normal = analyze(store, target: "/graphql", method: "POST",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", content_type: "application/json",
        body: %({"data":{"me":{"id":"1","name":"a"}}}))
      codes_of(normal).should_not contain("graphql_introspection")
      # "__schema" alone (no queryType) is insufficient — keeps a docs/registry blob out.
      partial = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: %({"note":"see the __schema field docs"}))
      codes_of(partial).should_not contain("graphql_introspection")
    end
  end
end

describe "Gori::Probe::Passive (insecure form action)" do
  it "flags a form on an HTTPS page that submits to a cleartext http:// action" do
    with_store do |store|
      insecure = analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<form action="http://acme.test/login" method="post"><input name=pw></form>))
      codes_of(insecure).should contain("insecure_form_action")
      # An https:// action (or a same-page relative action) is fine.
      secure = analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<form action="https://acme.test/login"><input name=pw></form><form action="/x"></form>))
      codes_of(secure).should_not contain("insecure_form_action")
    end
  end
end

describe "Gori::Probe::Passive (round-2 detection fixes)" do
  it "does not flag a data-src lazy-loading placeholder as active mixed content" do
    with_store do |store|
      # A hyphenated data-* attribute is not the real src attribute; `\b` alone treated
      # the hyphen as a word boundary and false-matched `data-src="http://…"`.
      lazy = analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<iframe data-src="http://cdn.acme.test/lazy" src="https://cdn.acme.test/ok"></iframe>))
      codes_of(lazy).should_not contain("mixed_content")
      # …a genuine active http:// sub-resource still trips it.
      real = analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<script src="http://cdn.acme.test/evil.js"></script>))
      codes_of(real).should contain("mixed_content")
    end
  end

  it "does not flag a data-action attribute as an insecure form action" do
    with_store do |store|
      lazy = analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<form data-action="http://acme.test/track" action="https://acme.test/login"></form>))
      codes_of(lazy).should_not contain("insecure_form_action")
    end
  end

  it "treats a cookie cleared with a non-empty sentinel value and a past Expires as a deletion" do
    with_store do |store|
      # `auth=deleted; Expires=<past>` (no Max-Age, non-empty value) is a logout clear —
      # its missing flags are noise, not hygiene issues.
      cleared = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: auth=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n",
        content_type: "text/html")
      codes_of(cleared).should_not contain("cookie_no_secure")
      codes_of(cleared).should_not contain("cookie_no_httponly")
    end
  end

  it "flags a present-but-ineffective X-Frame-Options value (obsolete ALLOW-FROM)" do
    with_store do |store|
      ineffective = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nX-Frame-Options: ALLOW-FROM https://x.test\r\n\r\n")
      codes_of(ineffective).should contain("missing_x_frame_options")
      # DENY / SAMEORIGIN actually restrict framing → no issue.
      deny = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nX-Frame-Options: DENY\r\n\r\n")
      codes_of(deny).should_not contain("missing_x_frame_options")
    end
  end

  it "flags CSP-Report-Only without an enforcing CSP as csp_report_only (not missing_csp)" do
    with_store do |store|
      only_ro = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy-Report-Only: default-src 'self'\r\n\r\n")
      codes_of(only_ro).should contain("csp_report_only")
      codes_of(only_ro).should_not contain("missing_csp")
      # Enforcing CSP present → no report-only-only finding (even if R-O is also sent).
      both = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self'\r\n" \
                   "Content-Security-Policy-Report-Only: default-src 'self'\r\n\r\n")
      codes_of(both).should_not contain("csp_report_only")
      codes_of(both).should_not contain("missing_csp")
    end
  end

  it "flags Referrer-Policy: unsafe-url as weak, not a strong policy" do
    with_store do |store|
      weak = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nReferrer-Policy: unsafe-url\r\n\r\n")
      codes_of(weak).should contain("weak_referrer_policy")
      codes_of(weak).should_not contain("missing_referrer_policy")
      ok = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nReferrer-Policy: strict-origin-when-cross-origin\r\n\r\n")
      codes_of(ok).should_not contain("weak_referrer_policy")
      codes_of(ok).should_not contain("missing_referrer_policy")
      # Browser default is ubiquitous — do not flag as weak.
      defaultish = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nReferrer-Policy: no-referrer-when-downgrade\r\n\r\n")
      codes_of(defaultish).should_not contain("weak_referrer_policy")
    end
  end

  it "flags missing Permissions-Policy and high-risk features allowed for all origins" do
    with_store do |store|
      missing = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n")
      codes_of(missing).should contain("missing_permissions_policy")
      # Restrictive modern policy → neither missing nor weak.
      ok = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nPermissions-Policy: camera=(), geolocation=(self)\r\n\r\n")
      codes_of(ok).should_not contain("missing_permissions_policy")
      codes_of(ok).should_not contain("weak_permissions_policy")
      # camera=* (and Feature-Policy geolocation *) → weak, with feature names as evidence.
      weak_pp = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nPermissions-Policy: camera=*, microphone=()\r\n\r\n")
      hit = weak_pp.find(&.code.==("weak_permissions_policy")).not_nil!
      hit.evidence.should eq("camera")
      weak_fp = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nFeature-Policy: geolocation *; camera 'none'\r\n\r\n")
      codes_of(weak_fp).should contain("weak_permissions_policy")
      weak_fp.find(&.code.==("weak_permissions_policy")).not_nil!.evidence.should eq("geolocation")
      # Document-only: a 302 must not fire missing Permissions-Policy.
      redirect = analyze(store, content_type: "text/html", status: 302,
        resp_head: "HTTP/1.1 302 Found\r\nLocation: /home\r\n\r\n")
      codes_of(redirect).should_not contain("missing_permissions_policy")
    end
  end

  it "flags HSTS max-age under 1 day as short_hsts but not as missing" do
    with_store do |store|
      short = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=60\r\n\r\n",
        content_type: "text/html")
      codes_of(short).should contain("short_hsts")
      codes_of(short).should_not contain("missing_hsts")
      short.find(&.code.==("short_hsts")).not_nil!.evidence.should eq("max-age=60")
      long = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=31536000\r\n\r\n",
        content_type: "text/html")
      codes_of(long).should_not contain("short_hsts")
      codes_of(long).should_not contain("missing_hsts")
      # max-age=0 remains missing/disabled, not short.
      disabled = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=0\r\n\r\n",
        content_type: "text/html")
      codes_of(disabled).should contain("missing_hsts")
      codes_of(disabled).should_not contain("short_hsts")
    end
  end
end

describe "Gori::Probe::Passive (insecure Basic auth)" do
  it "flags request Basic credentials over cleartext HTTP as High" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", scheme: "http",
        req_headers: "Authorization: Basic dXNlcjpwYXNz\r\n", content_type: nil)
      hit = dets.find(&.code.==("insecure_basic_auth")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.not_nil!.should_not contain("dXNlcjpwYXNz") # never the credential itself
    end
  end

  it "flags a WWW-Authenticate: Basic challenge over cleartext HTTP as Medium" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\n\r\n",
        status: 401, scheme: "http", content_type: nil)
      hit = dets.find(&.code.==("insecure_basic_auth")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not flag Basic auth over HTTPS (transport-protected) or non-Basic schemes" do
    with_store do |store|
      https = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", scheme: "https",
        req_headers: "Authorization: Basic dXNlcjpwYXNz\r\n", content_type: nil)
      codes_of(https).should_not contain("insecure_basic_auth")
      bearer = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", scheme: "http",
        req_headers: "Authorization: Bearer token123\r\n", content_type: nil)
      codes_of(bearer).should_not contain("insecure_basic_auth")
    end
  end
end

describe "Gori::Probe::Passive (Round-1 hardening)" do
  it "resolves duplicate CSP directives first-wins (matches browser enforcement)" do
    with_store do |store|
      # First script-src is safe; the duplicate must be IGNORED, so this is not weak.
      safe = analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n" \
                                                                  "Content-Security-Policy: script-src 'self'; script-src 'unsafe-inline'\r\n\r\n")
      codes_of(safe).should_not contain("weak_csp")
      # First script-src is unsafe-inline; a later 'self' duplicate must not mask it.
      weak = analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n" \
                                                                  "Content-Security-Policy: script-src 'unsafe-inline'; script-src 'self'\r\n\r\n")
      codes_of(weak).should contain("weak_csp")
    end
  end

  it "suppresses hygiene for sentinel-value and negative-Max-Age deletion cookies" do
    with_store do |store|
      # PHP clears cookies with the literal value "deleted" (not empty) + Max-Age=0.
      php = analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n" \
                                                                 "Set-Cookie: PHPSESSID=deleted; Max-Age=0; expires=Thu, 01-Jan-1970 00:00:00 GMT; path=/\r\n\r\n")
      codes_of(php).should_not contain("cookie_no_secure")
      codes_of(php).should_not contain("cookie_no_httponly")
      neg = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=; Max-Age=-1\r\n\r\n")
      codes_of(neg).should_not contain("cookie_no_samesite")
      # …but a live cookie with a positive Max-Age is still scored.
      live = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc; Max-Age=3600\r\n\r\n")
      codes_of(live).should contain("cookie_no_secure")
    end
  end

  it "flags a Basic challenge listed after another scheme in one WWW-Authenticate header" do
    with_store do |store|
      dets = analyze(store, scheme: "http", content_type: nil, status: 401,
        resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Negotiate, Basic realm=\"x\"\r\n\r\n")
      dets.find(&.code.==("insecure_basic_auth")).not_nil!.severity.should eq(Gori::Store::Severity::Medium)
      none = analyze(store, scheme: "http", content_type: nil, status: 401,
        resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Negotiate, Digest realm=\"x\"\r\n\r\n")
      codes_of(none).should_not contain("insecure_basic_auth")
    end
  end

  it "flags PGP and PKCS#8-encrypted private key blocks (not just RSA/EC)" do
    with_store do |store|
      pgp = analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF...\n-----END PGP PRIVATE KEY BLOCK-----")
      pgp.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("private key block")
      enc = analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF...\n-----END ENCRYPTED PRIVATE KEY-----")
      codes_of(enc).should contain("secret_in_body")
    end
  end

  it "does not flag a 4-part software version as a private IP but still catches a real leak" do
    with_store do |store|
      json = analyze(store, content_type: "application/json",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n", body: %({"version":"10.0.0.0"}))
      codes_of(json).should_not contain("private_ip_leak")
      htmlv = analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n", body: "<span>File version 10.0.1.2</span>")
      codes_of(htmlv).should_not contain("private_ip_leak")
      # a genuine private IP after a version-shaped token is still surfaced (scan, not first-match).
      mixed = analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "<p>build version 10.0.1.2</p><p>backend at 192.168.1.5</p>")
      mixed.find(&.code.==("private_ip_leak")).not_nil!.evidence.should eq("192.168.1.5")
    end
  end

  it "anchors GraphQL introspection on the result envelope, not raw substrings" do
    with_store do |store|
      # An echoed introspection QUERY string carries both tokens but is not a result -> no FP.
      echoed = analyze(store, content_type: "application/json",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        body: %({"data":{"savedQuery":"query IntrospectionQuery { __schema { queryType { name } } }"}}))
      codes_of(echoed).should_not contain("graphql_introspection")
      # A real introspection envelope is flagged even when queryType is absent from the prefix.
      env = analyze(store, content_type: "application/json",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        body: %({"data":{"__schema":{"types":[{"name":"User"}]}}}))
      codes_of(env).should contain("graphql_introspection")
    end
  end
end

describe "Gori::Probe::Active::CorsReflection" do
  probe = Gori::Probe::Active::CorsReflection.new

  it "only probes CORS endpoints (response carried ACAO) with a safe method" do
    with_store do |store|
      # No ACAO on the captured response → nothing to probe.
      plain = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api", content_type: nil)
      probe.plan(plain).should be_nil
      # A POST is never probed even if it does CORS.
      post = capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://a.test\r\n\r\n",
        target: "/api", method: "POST", content_type: nil)
      probe.plan(post).should be_nil
      # A GET whose response did CORS → a probe is built.
      cors = capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://a.test\r\n\r\n",
        target: "/api", content_type: nil)
      probe.plan(cors).should_not be_nil
    end
  end

  it "sends a single synthetic Origin header (replacing any the browser sent)" do
    with_store do |store|
      cors = capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n\r\n",
        target: "/api", req_headers: "Origin: https://real.test\r\n", content_type: nil)
      plan = probe.plan(cors).not_nil!
      text = String.new(plan.request)
      text.scan(/Origin:/i).size.should eq(1) # exactly one Origin header
      text.should contain("Origin: #{Gori::Probe::Active::CorsReflection::PROBE_ORIGIN}")
      text.should_not contain("https://real.test") # the browser's Origin was dropped
    end
  end

  it "sends an ORIGIN-FORM request line even for an absolute-form (forward-proxy) CORS flow" do
    with_store do |store|
      # Plaintext forward-proxy CORS flow is captured absolute-form; the probe goes DIRECT to the
      # origin, so its request line must be origin-form or some origins reject it (false negative).
      cors = capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n\r\n",
        scheme: "http", host: "target.com", target: "http://target.com/api?x=1", content_type: nil)
      plan = probe.plan(cors).not_nil!
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /api?x=1 ")
      line.should_not contain("http://target.com")
    end
  end

  it "flags High only when the probe origin is reflected WITH credentials" do
    with_store do |store|
      cors = capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n\r\n",
        target: "/api", content_type: nil)
      plan = probe.plan(cors).not_nil!
      origin = Gori::Probe::Active::CorsReflection::PROBE_ORIGIN

      reflected = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: #{origin}\r\n" \
        "Access-Control-Allow-Credentials: true\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      dets = probe.detections(plan, reflected, cors)
      dets.size.should eq(1)
      dets.first.code.should eq("cors_arbitrary_origin")
      dets.first.severity.should eq(Gori::Store::Severity::High)

      # Reflected but NO credentials → not exploitable → not flagged.
      no_creds = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: #{origin}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, no_creds, cors).should be_empty

      # A correctly-behaving allowlist rejects the probe origin (echoes its own) → not flagged.
      allowlisted = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n" \
        "Access-Control-Allow-Credentials: true\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, allowlisted, cors).should be_empty

      # A wildcard is handled by the passive check, not proven here.
      wildcard = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, wildcard, cors).should be_empty
    end
  end
end

describe "Gori::Probe::Active::ForbiddenBypass" do
  probe = Gori::Probe::Active::ForbiddenBypass.new

  it "only probes originally-denied (401/403) responses with a safe method" do
    with_store do |store|
      # A normally-served endpoint has no gate to bypass.
      ok = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin", status: 200, content_type: nil)
      probe.plan(ok).should be_nil
      # 404/5xx are not access-control denials.
      missing = capture_flow(store, "HTTP/1.1 404 Not Found\r\n\r\n", target: "/admin", status: 404, content_type: nil)
      probe.plan(missing).should be_nil
      # A denied GET/HEAD → a probe is built.
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      probe.plan(forbidden).should_not be_nil
      unauth = capture_flow(store, "HTTP/1.1 401 Unauthorized\r\n\r\n", target: "/admin", status: 401, content_type: nil)
      probe.plan(unauth).should_not be_nil
      # A POST is never probed (no auto state mutation) even when denied.
      post = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
        method: "POST", content_type: nil)
      probe.plan(post).should be_nil
    end
  end

  it "inserts the full IP-spoof header set once each, dropping any the browser sent" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
        req_headers: "X-Forwarded-For: 9.9.9.9\r\n", content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      text = String.new(plan.request)
      Gori::Probe::Active::ForbiddenBypass::BYPASS_HEADERS.each do |name|
        # Anchor to the CRLF + exact value so a shorter name (Client-IP) isn't counted inside a
        # longer one (X-Client-IP).
        text.scan("\r\n#{name}: 127.0.0.1").size.should eq(1), "expected exactly one #{name}"
      end
      text.should_not contain("9.9.9.9") # the browser's original X-Forwarded-For was replaced
    end
  end

  it "sends an ORIGIN-FORM request line even for an absolute-form (forward-proxy) flow" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", scheme: "http", host: "target.com",
        target: "http://target.com/admin?x=1", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /admin?x=1 ")
      line.should_not contain("http://target.com")
    end
  end

  it "flags a possible bypass (Medium) only when the denied response flips to 2xx" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!

      bypassed = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      dets = probe.detections(plan, bypassed, forbidden)
      dets.size.should eq(1)
      dets.first.code.should eq("forbidden_bypass")
      # Single-shot flip vs the captured baseline (no control re-send) → Medium "possible", not High.
      dets.first.severity.should eq(Gori::Store::Severity::Medium)

      # Still denied → the gate held → not flagged.
      still_denied = Gori::Repeater::Result.new("HTTP/1.1 403 Forbidden\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, still_denied, forbidden).should be_empty
      # A redirect (e.g. to login) is ambiguous → not flagged.
      redirect = Gori::Repeater::Result.new("HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, redirect, forbidden).should be_empty
      # A send failure never flags.
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections(plan, errored, forbidden).should be_empty
    end
  end

  it "dedup_key equals plan.dedup_key across denied/allowed/method/absolute-form flows" do
    with_store do |store|
      cases = [
        {target: "/admin", method: "GET", status: 403},                 # denied GET
        {target: "/admin?id=1", method: "GET", status: 403},            # denied GET + query (stripped in key)
        {target: "/admin", method: "HEAD", status: 401},                # denied HEAD is safe
        {target: "/admin", method: "GET", status: 200},                 # allowed → nil
        {target: "/admin", method: "GET", status: 404},                 # not a denial → nil
        {target: "/admin", method: "POST", status: 403},                # unsafe method → nil
        {target: "http://t.example/admin", method: "GET", status: 403}, # absolute-form
        {target: "/has space", method: "GET", status: 403},             # malformed start-line → nil
      ]
      cases.each do |c|
        d = capture_flow(store, "HTTP/1.1 #{c[:status]} X\r\n\r\n", scheme: "http", host: "t.example",
          target: c[:target], method: c[:method], status: c[:status], content_type: nil)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key)), "forbidden_bypass #{c[:target]} #{c[:method]} #{c[:status]}"
      end
    end
  end
end

describe "Gori::Probe::Active (safety + coverage)" do
  it "does not probe mutating methods (POST), only safe ones (GET)" do
    with_store do |store|
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/comment", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: "text=hi", content_type: nil)
      Gori::Probe::Active.plan(post).should be_nil
      get = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      Gori::Probe::Active.plan(get).should_not be_nil
    end
  end

  it "keys the dedup signature by method and parameter location" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      key = Gori::Probe::Active.plan(detail).not_nil!.dedup_key
      key.should contain("GET")
      key.should contain("q@query")
    end
  end

  it "detects a canary reflected ONLY in a response header (e.g. Location)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/go?url=here", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      result = Gori::Repeater::Result.new(
        "HTTP/1.1 302 Found\r\nLocation: https://site/?url=#{canary}\r\n\r\n".to_slice,
        Bytes.empty, nil, 1_i64)
      dets = Gori::Probe::Active.detections(plan, result, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("reflected_param")
    end
  end

  it "rates an HTML reflection Medium and a non-HTML (JSON) reflection Low" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      html = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
        "<p>#{canary}</p>".to_slice, nil, 1_i64)
      Gori::Probe::Active.detections(plan, html, detail).first.severity.should eq(Gori::Store::Severity::Medium)
      json = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
        %({"q":"#{canary}"}).to_slice, nil, 1_i64)
      Gori::Probe::Active.detections(plan, json, detail).first.severity.should eq(Gori::Store::Severity::Low)
    end
  end
end

describe "Gori::Probe::Filter (incomplete terms)" do
  it "treats a mid-typed negated field term as a no-op (does not blank the list)" do
    issues = [make_issue("missing_csp"), make_issue("missing_hsts")]
    Gori::Probe::Filter.parse("-host:").apply(issues).size.should eq(2)
    Gori::Probe::Filter.parse("host:").apply(issues).size.should eq(2)
    # a complete negated term still filters
    Gori::Probe::Filter.parse("-code:csp").apply(issues).map(&.code).should eq(["missing_hsts"])
  end

  it "reports whether the query explicitly constrains status (drives the open-only lens)" do
    Gori::Probe::Filter.parse("host:api").has_status_term?.should be_false
    Gori::Probe::Filter.parse("").has_status_term?.should be_false
    Gori::Probe::Filter.parse("status:fp host:api").has_status_term?.should be_true
    Gori::Probe::Filter.parse("-st:open").has_status_term?.should be_true
  end
end

describe Gori::Probe do
  describe ".group" do
    it "folds detections exactly like Store#upsert_probe_issue (severity/hit_count/affected/evidence)" do
      with_store do |store|
        det = ->(code : String, host : String, url : String, s : Gori::Store::Severity, ev : String?) do
          Gori::Probe::Detection.new(code, "headers", host, url, "t", s, ev)
        end
        low = Gori::Store::Severity::Low
        medium = Gori::Store::Severity::Medium
        dets = [
          det.call("missing_csp", "a.test", "https://a.test/1", low, nil),
          det.call("missing_csp", "a.test", "https://a.test/2", medium, "x"), # severity rises, url accumulates
          det.call("missing_csp", "a.test", "https://a.test/1", low, "y"),    # dup url (no add); evidence already set
          det.call("missing_hsts", "b.test", "https://b.test/1", low, nil),
        ]
        dets.each { |d| store.upsert_probe_issue(d) }
        stored = store.probe_issues.to_h { |i| {"#{i.code}@#{i.host}", i} }
        grouped = Gori::Probe.group(dets).to_h { |g| {"#{g.code}@#{g.host}", g} }

        grouped.size.should eq(stored.size)
        grouped.each do |key, g|
          s = stored[key]
          g.severity.should eq(s.severity)
          g.hit_count.to_i64.should eq(s.hit_count)
          g.affected.sort.should eq(s.affected.sort)
          g.evidence.should eq(s.evidence) # first non-nil wins (COALESCE)
          g.title.should eq(s.title)       # title tracks the same (highest-severity) observation
        end

        csp = grouped["missing_csp@a.test"]
        csp.severity.should eq(medium)                                   # max seen
        csp.hit_count.should eq(3)                                       # every observation
        csp.affected.should eq(["https://a.test/1", "https://a.test/2"]) # de-duplicated
        csp.evidence.should eq("x")                                      # first non-nil, not "y"
      end
    end

    it "sorts by severity desc and caps the affected list at PROBE_AFFECTED_CAP (hit_count still climbs)" do
      cap = Gori::Store::PROBE_AFFECTED_CAP
      dets = [] of Gori::Probe::Detection
      (cap + 10).times do |i|
        dets << Gori::Probe::Detection.new("missing_csp", "headers", "a.test",
          "https://a.test/#{i}", "t", Gori::Store::Severity::Low)
      end
      dets << Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test",
        "https://a.test/x", "t", Gori::Store::Severity::High)
      groups = Gori::Probe.group(dets)
      groups.first.code.should eq("secret_in_body") # High sorts above Low
      csp = groups.find!(&.code.==("missing_csp"))
      csp.hit_count.should eq(cap + 10) # every observation counted
      csp.affected.size.should eq(cap)  # but the URL list is capped
    end

    it "accumulates distinct secret/error types for one (code, host) group (not first-wins)" do
      dets = [
        Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test", "https://a.test/1", "t", Gori::Store::Severity::High, "AWS access key id"),
        Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test", "https://a.test/2", "t", Gori::Store::Severity::High, "GitHub token"),
        Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test", "https://a.test/1", "t", Gori::Store::Severity::High, "AWS access key id"),
      ]
      g = Gori::Probe.group(dets).find!(&.code.==("secret_in_body"))
      g.evidence.not_nil!.should contain("AWS access key id")
      g.evidence.not_nil!.should contain("GitHub token") # was masked by COALESCE-first-wins
      g.hit_count.should eq(3)
      # a non-type-labeled code still keeps the first sample (evidence is a one-off value)
      ip = [
        Gori::Probe::Detection.new("private_ip_leak", "infoleak", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low, "10.0.0.1"),
        Gori::Probe::Detection.new("private_ip_leak", "infoleak", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low, "192.168.0.1"),
      ]
      Gori::Probe.group(ip).find!(&.code.==("private_ip_leak")).evidence.should eq("10.0.0.1")
    end

    it "adopts the higher-severity title on escalation, staying consistent with the store" do
      with_store do |store|
        low = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/api",
          "Reflected parameter (non-HTML context)", Gori::Store::Severity::Low, "q")
        high = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/page",
          "Reflected parameter", Gori::Store::Severity::Medium, "name")
        dets = [low, high] # non-HTML first, then HTML escalates
        g = Gori::Probe.group(dets).find!(&.code.== "reflected_param")
        g.severity.should eq(Gori::Store::Severity::Medium)
        g.title.should eq("Reflected parameter") # not frozen at "(non-HTML context)"
        # and the headless group matches what the store persists for the same detections
        dets.each { |d| store.upsert_probe_issue(d) }
        stored = store.probe_issues.find!(&.code.== "reflected_param")
        g.title.should eq(stored.title)
        g.severity.should eq(stored.severity)
      end
    end

    it "tags the same code on different hosts as separate groups" do
      dets = [
        Gori::Probe::Detection.new("missing_hsts", "headers", "a.test", "https://a.test/", "t", Gori::Store::Severity::Low),
        Gori::Probe::Detection.new("missing_hsts", "headers", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low),
      ]
      Gori::Probe.group(dets).map(&.host).sort!.should eq(["a.test", "b.test"])
    end
  end
end

describe Gori::Probe, "WebSocket + Repeater sources" do
  it "fingerprints a WebSocket upgrade and includes the path in evidence" do
    with_store do |store|
      req_headers = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: chat\r\n"
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = capture_flow(store, head, target: "/ws/chat", status: 101, content_type: nil,
        req_headers: req_headers)
      codes = codes_of(Gori::Probe::Passive.analyze(detail))
      codes.should contain("tech_websocket")
      det = Gori::Probe::Passive.analyze(detail).find!(&.code.==("tech_websocket"))
      det.evidence.not_nil!.should contain("WebSocket")
      det.evidence.not_nil!.should contain("/ws/chat")
      det.evidence.not_nil!.should contain("chat")
      store.upsert_probe_issue(det)
      store.probe_tech_summary.should contain("WebSocket")
    end
  end

  it "flags secrets in captured WebSocket text messages (type only, never the value)" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      secret = "AKIAIOSFODNN7EXAMPLE"
      msgs = [
        Gori::Store::WsMessage.new(1_i64, detail.row.id, nil, 1_i64, "in", 1, "token=#{secret}".to_slice),
      ]
      dets = Gori::Probe::Passive.analyze(detail, msgs)
      hit = dets.find { |d| d.code == "secret_in_ws" }.not_nil!
      hit.evidence.should eq("AWS access key id")
      hit.evidence.not_nil!.should_not contain(secret)
      # binary frames are ignored
      bin = [Gori::Store::WsMessage.new(2_i64, detail.row.id, nil, 1_i64, "in", 2, secret.to_slice)]
      Gori::Probe::Passive.analyze(detail, bin).map(&.code).should_not contain("secret_in_ws")
    end
  end

  it "builds a FlowDetail from a RepeaterRecord and passive-scans it" do
    with_store do |store|
      req = "GET /api HTTP/1.1\r\nHost: repeater.test\r\n\r\n"
      resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.25\r\n\r\n"
      id = store.insert_repeater("https://repeater.test", req, false, true, nil, 0)
      store.update_repeater_response(id, resp.to_slice, "<html/>".to_slice, nil, 12_i64)
      rec = store.get_repeater(id).not_nil!
      # get_repeater may not load response blobs — use full repeaters list
      rec = store.repeaters.find!(&.id.== id)
      detail = Gori::Probe.detail_from_repeater(rec).not_nil!
      detail.row.host.should eq("repeater.test")
      detail.row.method.should eq("GET")
      detail.row.status.should eq(200)
      dets = Gori::Probe::Passive.analyze(detail).map { |d|
        Gori::Probe.with_source(d, repeater_id: id)
      }
      dets.map(&.code).should contain("tech_server")
      dets.map(&.code).should contain("missing_csp")
      dets.each { |d| store.upsert_probe_issue(d) }
      issue = store.probe_issues.find!(&.code.==("tech_server"))
      issue.sample_repeater_id.should eq(id)
      issue.sample_flow_id.should be_nil
    end
  end

  it "parses request headers from an LF-joined Repeater request (normalizes the head to CRLF)" do
    with_store do |store|
      # The Repeater editor serializes request text with BARE-LF line endings; without CRLF
      # normalization Http1.parse_headers returns an empty list and every request-side rule
      # (CORS Origin, Basic auth, request tech) silently misses.
      req = "POST /login HTTP/1.1\nHost: acme.test\nAuthorization: Basic dXNlcjpwYXNz\n" \
            "Origin: https://evil.example\n"
      resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.example\r\n" \
             "Access-Control-Allow-Credentials: true\r\n\r\n"
      id = store.insert_repeater("http://acme.test", req, false, false, nil, 0)
      store.update_repeater_response(id, resp.to_slice, "{}".to_slice, nil, 5_i64)
      rec = store.repeaters.find!(&.id.== id)
      detail = Gori::Probe.detail_from_repeater(rec).not_nil!
      detail.row.method.should eq("POST")
      codes = Gori::Probe::Passive.analyze(detail).map(&.code)
      codes.should contain("insecure_basic_auth")   # Authorization header now visible over http
      codes.should contain("cors_reflected_origin") # Origin header now visible
    end
  end

  it "skips Repeater tabs with no response head" do
    with_store do |store|
      id = store.insert_repeater("https://empty.test", "GET / HTTP/1.1\r\nHost: empty.test\r\n\r\n",
        false, true, nil, 0)
      rec = store.repeaters_meta.find!(&.id.== id)
      Gori::Probe.detail_from_repeater(rec).should be_nil
    end
  end
end

describe "Store bulk Probe dismiss" do
  it "mutes only OPEN issues matching the code/host, leaving already-triaged rows untouched" do
    with_store do |store|
      det = ->(code : String, host : String, url : String) do
        Gori::Probe::Detection.new(code, "headers", host, url, "t", Gori::Store::Severity::Low)
      end
      store.upsert_probe_issue(det.call("missing_hsts", "a.test", "https://a.test/"))
      store.upsert_probe_issue(det.call("missing_csp", "a.test", "https://a.test/"))
      store.upsert_probe_issue(det.call("missing_hsts", "b.test", "https://b.test/"))

      # Promote one to confirmed: a bulk dismiss must NOT clobber an already-triaged row.
      hsts_a = store.probe_issues.find { |i| i.code == "missing_hsts" && i.host == "a.test" }.not_nil!
      store.update_probe_issue_status(hsts_a.id, Gori::Store::Status::Confirmed)

      store.dismiss_probe_by_code("missing_hsts")
      by_key = store.probe_issues.to_h { |i| {"#{i.code}@#{i.host}", i.status} }
      by_key["missing_hsts@a.test"].should eq(Gori::Store::Status::Confirmed)     # triaged → untouched
      by_key["missing_hsts@b.test"].should eq(Gori::Store::Status::FalsePositive) # open → muted
      by_key["missing_csp@a.test"].should eq(Gori::Store::Status::Open)           # other code → untouched

      store.dismiss_probe_by_host("a.test")
      after = store.probe_issues.to_h { |i| {"#{i.code}@#{i.host}", i.status} }
      after["missing_csp@a.test"].should eq(Gori::Store::Status::FalsePositive) # open on host → muted
      after["missing_hsts@a.test"].should eq(Gori::Store::Status::Confirmed)    # still untouched
    end
  end
end

describe "Store#upsert_probe_issue (title stays consistent with severity)" do
  # A code whose title is severity-dependent (reflected_param: HTML ⇒ Medium "Reflected
  # parameter" vs non-HTML ⇒ Low "…(non-HTML context)") merges into one (code, host) group.
  # The title must track the HIGHEST-severity observation, not stay frozen at first-insert —
  # otherwise the escalated badge (MED) sits next to a non-HTML (non-exploitable) title.
  it "adopts the higher-severity title when a group's severity escalates" do
    with_store do |store|
      low = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/api",
        "Reflected parameter (non-HTML context)", Gori::Store::Severity::Low, "q")
      high = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/page",
        "Reflected parameter", Gori::Store::Severity::Medium, "name")
      store.upsert_probe_issue(low)  # non-HTML seen first
      store.upsert_probe_issue(high) # HTML on same host escalates the group
      row = store.probe_issues.find!(&.code.== "reflected_param")
      row.severity.should eq(Gori::Store::Severity::Medium)
      row.title.should eq("Reflected parameter") # was frozen at "(non-HTML context)"
    end
  end

  it "does not downgrade the title when a later, lower-severity observation merges in" do
    with_store do |store|
      high = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/page",
        "Reflected parameter", Gori::Store::Severity::Medium, "name")
      low = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/api",
        "Reflected parameter (non-HTML context)", Gori::Store::Severity::Low, "q")
      store.upsert_probe_issue(high)
      store.upsert_probe_issue(low) # lower severity must not clobber the escalated title
      row = store.probe_issues.find!(&.code.== "reflected_param")
      row.severity.should eq(Gori::Store::Severity::Medium)
      row.title.should eq("Reflected parameter")
    end
  end

  it "keeps a fixed-title code's title stable across regroups" do
    with_store do |store|
      d1 = Gori::Probe::Detection.new("missing_csp", "headers", "a.test", "https://a.test/1",
        "Missing Content-Security-Policy", Gori::Store::Severity::Low, nil)
      d2 = Gori::Probe::Detection.new("missing_csp", "headers", "a.test", "https://a.test/2",
        "Missing Content-Security-Policy", Gori::Store::Severity::Low, nil)
      store.upsert_probe_issue(d1)
      store.upsert_probe_issue(d2)
      store.probe_issues.find!(&.code.== "missing_csp").title.should eq("Missing Content-Security-Policy")
    end
  end
end

describe "Gori::Probe.tech_summary" do
  it "does not raise on invalid-UTF-8 evidence (a hostile Server header byte)" do
    # tech_summary runs on the TUI render fiber (project_view / probe_view); a value-tech
    # evidence with a raw 0x80-0xFF byte would make the PCRE split raise and crash the whole
    # TUI. The `.scrub` keeps the first token instead. Byte 0x80 → U+FFFD, dropped by the split.
    rows = [{"tech_server", String.new(Bytes[0x6e, 0x67, 0x69, 0x6e, 0x78, 0x80])}] of {String, String?}
    out = Gori::Probe.tech_summary(rows)
    out.size.should eq(1)
    out[0].starts_with?("nginx").should be_true
    out[0].valid_encoding?.should be_true
  end
end

# A valid, long JWT used across several tests (all three segments well over the length gate).
JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

# Wrap a JS snippet in an HTML document so it reaches the client-side rules as an inline script.
private def html_with_script(js : String) : String
  "<!doctype html><html><head></head><body><script>#{js}</script></body></html>"
end

private def analyze_html(store, body : String)
  analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
    content_type: "text/html", body: body)
end

private def analyze_js(store, body : String)
  analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n\r\n",
    content_type: "application/javascript", body: body)
end

describe "Gori::Probe::Passive (shared body decode)" do
  it "decodes a compressed HTML body once yet feeds both body_text and the client rules" do
    with_store do |store|
      # An HTML document with a body-text finding (leaked AWS key → BodyLeaks, uses body_text)
      # AND a client-rule finding (source→sink in an inline script → DomXss, uses client_body_text).
      # Both must still fire when the body is gzip-encoded, proving the single shared inflate
      # (Context#decoded_body) feeds both getters correctly.
      plain = "<html><script>document.write(location.hash)</script>" \
              "<p>key AKIAIOSFODNN7EXAMPLE here</p></html>"
      gz = IO::Memory.new
      Compress::Gzip::Writer.open(gz) { |w| w.write(plain.to_slice) }
      dets = analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
        content_type: "text/html", body: String.new(gz.to_slice))
      codes_of(dets).should contain("secret_in_body") # body_text path
      codes_of(dets).should contain("dom_xss")         # client_body_text path
    end
  end
end

describe Gori::Probe::Passive::JsScan do
  it "blanks string literals and comments but keeps code" do
    stripped = Gori::Probe::Passive::JsScan.strip(%q{a = "el.innerHTML=location.hash"; // note document.cookie
b = location.search;})
    # Tokens that lived inside a string or a comment are gone...
    stripped.includes?("el.innerHTML").should be_false
    stripped.includes?("document.cookie").should be_false
    # ...but real code (identifiers outside strings/comments) survives, offsets preserved.
    stripped.includes?("location.search").should be_true
    stripped.size.should eq(%q{a = "el.innerHTML=location.hash"; // note document.cookie
b = location.search;}.size)
  end

  it "correlates a source and a sink only in the same statement" do
    same = Gori::Probe::Passive::JsScan.source_sink_pairs("el.innerHTML = location.hash;")
    same.map(&.[1]).should contain("innerHTML")
    # Split across two statements (no taint tracking) -> no pair.
    split = Gori::Probe::Passive::JsScan.source_sink_pairs("var x = location.hash; el.innerHTML = y;")
    split.empty?.should be_true
  end
end

describe Gori::Probe::Passive::DomXss do
  it "flags a source flowing into a sink in one statement (HTML inline script)" do
    with_store do |store|
      dets = analyze_html(store, html_with_script("document.getElementById('o').innerHTML = location.hash;"))
      hit = dets.find(&.code.==("dom_xss")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
      hit.category.should eq("client")
      hit.evidence.not_nil!.should contain("→")
    end
  end

  it "flags document.write / eval / setTimeout in a JS bundle" do
    with_store do |store|
      codes_of(analyze_js(store, "document.write(location.search);")).should contain("dom_xss")
      codes_of(analyze_js(store, "eval('x'+document.referrer);")).should contain("dom_xss")
    end
  end

  it "does not flag a sink inside a comment or a string, or a bare sink" do
    with_store do |store|
      codes_of(analyze_html(store, html_with_script("// el.innerHTML = location.hash"))).should_not contain("dom_xss")
      codes_of(analyze_html(store, html_with_script(%(log("el.innerHTML = location.hash"))))).should_not contain("dom_xss")
      codes_of(analyze_html(store, html_with_script("el.innerHTML = 'static markup';"))).should_not contain("dom_xss")
    end
  end
end

describe Gori::Probe::Passive::DomClobbering do
  it "flags named HTMLCollection access and the window-global fallback idiom" do
    with_store do |store|
      codes_of(analyze_html(store, html_with_script("var f = document.forms['login'];"))).should contain("dom_clobbering")
      codes_of(analyze_html(store, html_with_script("window.cfg = window.cfg || {};"))).should contain("dom_clobbering")
    end
  end

  it "does not flag ordinary DOM lookups" do
    with_store do |store|
      codes_of(analyze_html(store, html_with_script("var a = document.getElementById('a');"))).should_not contain("dom_clobbering")
    end
  end
end

describe Gori::Probe::Passive::PrototypePollution do
  it "flags a prototype-key write and pollution-prone merge APIs" do
    with_store do |store|
      codes_of(analyze_js(store, "obj.__proto__ = evil;")).should contain("prototype_pollution")
      codes_of(analyze_js(store, "$.extend(true, target, src);")).should contain("prototype_pollution")
    end
  end

  it "flags a __proto__ parameter in the request" do
    with_store do |store|
      dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api?__proto__[polluted]=1")
      codes_of(dets).should contain("prototype_pollution_param")
    end
  end

  it "does not flag ordinary object code or a clean request" do
    with_store do |store|
      dets = analyze_js(store, "var o = {}; o.foo = 1;")
      codes_of(dets).should_not contain("prototype_pollution")
      codes_of(dets).should_not contain("prototype_pollution_param")
    end
  end
end

describe Gori::Probe::Passive::PostMessage do
  it "flags a message handler with no origin check" do
    with_store do |store|
      js = %(window.addEventListener("message", function(e){ handle(e.data); });)
      codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "does not flag a handler that validates the origin" do
    with_store do |store|
      js = %(window.addEventListener("message", function(e){ if (e.origin === "https://x") handle(e.data); });)
      codes_of(analyze_js(store, js)).should_not contain("postmessage_no_origin")
    end
  end

  it "flags a wildcard target origin and document.domain relaxation" do
    with_store do |store|
      codes_of(analyze_js(store, %(parent.postMessage(payload, "*");))).should contain("postmessage_wildcard")
      codes_of(analyze_js(store, %(document.domain = "example.com";))).should contain("document_domain_set")
    end
  end
end

describe "Gori::Probe::Passive::Tech (framework fingerprints)" do
  it "fingerprints React from the response body" do
    with_store do |store|
      codes_of(analyze_html(store, %(<html><body data-reactroot=""><div id="root"></div></body></html>))).should contain("tech_react")
    end
  end

  it "fingerprints jQuery and captures its version" do
    with_store do |store|
      dets = analyze_html(store, %(<html><head><script src="/assets/jquery-3.4.1.min.js"></script></head></html>))
      hit = dets.find(&.code.==("tech_jquery")).not_nil!
      hit.evidence.should eq("3.4.1")
    end
  end
end

describe "Gori::Probe::Passive::BodyLeaks (client-side HTML sinks)" do
  it "flags a javascript: URL but not the void(0) no-op" do
    with_store do |store|
      codes_of(analyze_html(store, %(<a href="javascript:alert(1)">x</a>))).should contain("inline_js_uri")
      codes_of(analyze_html(store, %(<a href="javascript:void(0)">x</a>))).should_not contain("inline_js_uri")
    end
  end

  it "flags passive mixed content and reverse-tabnabbing links" do
    with_store do |store|
      codes_of(analyze_html(store, %(<img src="http://cdn.example/x.png">))).should contain("mixed_passive")
      codes_of(analyze_html(store, %(<a target="_blank" href="http://x/">x</a>))).should contain("reverse_tabnabbing")
      codes_of(analyze_html(store, %(<a target="_blank" rel="noopener" href="http://x/">x</a>))).should_not contain("reverse_tabnabbing")
    end
  end
end

describe "Gori::Probe::Passive::Secrets (client-side shapes)" do
  it "flags a JWT and a Slack webhook embedded in a JS bundle" do
    with_store do |store|
      codes_of(analyze_js(store, "var t = '#{JWT}';")).should contain("secret_in_body")
      hook = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
      codes_of(analyze_js(store, "var w = '#{hook}';")).should contain("secret_in_body")
    end
  end
end

describe "Gori::Probe::Passive::SecretInUrl (JWT tightening)" do
  it "still flags a full JWT in the query but not a short dotted value" do
    with_store do |store|
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?tok=#{JWT}")).should contain("secret_in_url")
      # Long first two segments but a 1-char signature: the old `[...]+` tail false-matched this.
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?data=eyJhbGciOiJIUzI1.eyJzdWIiOiIx.z")).should_not contain("secret_in_url")
    end
  end
end

describe "Gori::Probe::Active (manual run estimate)" do
  it "requests_per_flow is 1..1 for every built-in active rule" do
    Gori::Probe::Active::RULES.each(&.requests_per_flow.should(eq(1..1)))
  end

  it "estimate_label renders a fixed count and a range" do
    Gori::Probe::Active.estimate_label(1..1).should eq("1 req/flow")
    Gori::Probe::Active.estimate_label(1..3).should eq("1–3 req/flow")
  end

  it "estimates one request per applicable rule (reflected param + CORS = 2)" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.test\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi", body: "<p>hi</p>")
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      est = a.active_estimate(detail)
      est.map(&.info.id).sort.should eq(["cors_reflection", "reflected_param"])
      est.sum { |e| e.requests.end }.should eq(2)
    end
  end

  it "omits a disabled active rule from the estimate" do
    with_store do |store|
      store.set_probe_disabled_rules(Set{"cors_reflection"})
      detail = capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.test\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi")
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      a.active_estimate(detail).map(&.info.id).should eq(["reflected_param"])
    end
  end

  it "estimates zero for an unsafe-method / paramless / non-CORS flow" do
    with_store do |store|
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      # POST is never probed (no safe method).
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/x?q=1", method: "POST")
      a.active_estimate(post).should be_empty
      # GET with no params + no ACAO has nothing to test.
      bare = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/nothing")
      a.active_estimate(bare).should be_empty
    end
  end

  it "run_active_now runs regardless of mode / notify choice without raising" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.test\r\n\r\n",
        target: "/search?q=hi")
      scope = Gori::Scope.load(store)
      {Gori::Probe::Mode::Passive, Gori::Probe::Mode::Off}.each do |mode|
        a = Gori::Probe::Analyzer.new(store, scope, Channel(Gori::Store::FlowEvent).new(1), mode, true)
        a.start
        # Every notify mode; sends to acme.test won't resolve, so the error is swallowed and the
        # Always completion is suppressed (errored run — verified by not raising).
        Gori::Miner::NotifyMode.values.each { |n| a.run_active_now(detail, notify: n) }
        sleep 50.milliseconds
        a.stop
      end
    end
  end
end
