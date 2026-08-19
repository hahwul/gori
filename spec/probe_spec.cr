require "./spec_helper"

# A Fuzz::Backend that never touches the network — it just counts sends and returns a
# benign OK response — so a scope test can distinguish "blocked before the socket" (sent
# == 0) from "sent but the response failed a check".
private class CountingBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin
  getter sent = 0

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "ok".to_slice, nil, 1_i64)
  end
end

# A backend that returns one fixed response for every probe, so an Active.analyze integration test
# can drive the full plan → send → detections dispatch without a socket.
private class FixedBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin

  def initialize(@origin : Gori::Fuzz::Origin, @head : String, @body : String = "")
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(@head.to_slice, @body.empty? ? Bytes.empty : @body.to_slice, nil, 1_i64)
  end
end

# A backend whose send ALWAYS raises — the "a rule blew up on this input" case. Before
# Active.analyze isolated each rule, one of these aborted the entire scan: every rule after it
# AND (through Scan.scan_flows) every remaining flow, discarding findings already collected.
private class RaisingBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin
  getter sent = 0

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    raise "backend exploded"
  end
end

# Raises on the FIRST send only, then answers every later probe with a CORS response echoing the
# probe origin — so a rule that runs AFTER the one that died can be shown to still produce its
# finding, which is the actual promise of per-rule isolation.
private class FlakyCorsBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin
  getter sent = 0

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    raise "first probe exploded" if @sent == 1
    head = "HTTP/1.1 200 OK\r\n" \
           "Access-Control-Allow-Origin: #{Gori::Probe::Active::CorsReflection::PROBE_ORIGIN}\r\n" \
           "Access-Control-Allow-Credentials: true\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, Bytes.empty, nil, 1_i64)
  end
end

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

# Flip one built-in probe rule on/off the way the Rules sub-tab does. `Probe.set_rule_enabled`
# (never a bare add/delete) is the single place the DEFAULT-OFF flip lives.
private def set_probe_rule_enabled(store, id : String, enabled : Bool) : Nil
  dis = store.probe_disabled_rules
  Gori::Probe.set_rule_enabled(dis, id, enabled)
  store.set_probe_disabled_rules(dis)
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

  # `canary_pairs`/`canary_json` rebuild the BODY THE PROBE SENDS, only ever generating a
  # FRESH value for the param they canary — every other byte in the body (a bare flag with no
  # `=`, another param's NAME, an untouched JSON field) is carried through from the captured
  # request. A `.scrub` before that rebuild corrupted invalid UTF-8 anywhere in it, so a probe
  # for an unrelated field sent the origin `U+FFFD` where the capture had a raw byte. Raw
  # fixture, searched byte-wise.
  it "sends a form-body probe with an untouched non-UTF-8 field byte-exact" do
    with_store do |store|
      buf = IO::Memory.new
      buf.write(Bytes[0x66_u8, 0x6c_u8, 0xff_u8, 0x67_u8]) # "fl" 0xFF "g" — no '=', never touched
      buf << "&a=1"
      req_body = String.new(buf.to_slice)
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/submit", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: req_body,
        content_type: nil)
      plan = Gori::Probe::Active::ReflectedParam.new.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true)).not_nil!
      plan.request.hexstring.should contain(Bytes[0x66_u8, 0x6c_u8, 0xff_u8, 0x67_u8].hexstring)
    end
  end

  it "sends a JSON-body probe with an untouched non-UTF-8 nested string byte-exact" do
    with_store do |store|
      buf = IO::Memory.new
      buf << %({"a":"s","b":{"x":")
      buf.write_byte(0xff_u8)
      buf << %("}})
      req_body = String.new(buf.to_slice)
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/j", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: req_body, content_type: nil)
      plan = Gori::Probe::Active::ReflectedParam.new.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true)).not_nil!
      # `"x":"<0xFF>"` must survive as one raw byte, not the three-byte U+FFFD `efbfbd`.
      plan.request.hexstring.should contain(Bytes[0x22_u8, 0xff_u8, 0x22_u8].hexstring)
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

  # The equivalence invariant must hold PER-opts: threading allow_unsafe/aggressive into plan and
  # dedup_key together keeps them from drifting, and the widened method gate / raised caps make the
  # previously-nil POST + over-cap flows non-nil (so both paths must agree on the SAME non-nil key).
  it "dedup_key equals plan.dedup_key under allow_unsafe / aggressive opts (both rules)" do
    with_store do |store|
      cors_resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://app.example\r\n\r\n"
      plain_resp = "HTTP/1.1 200 OK\r\n\r\n"
      many = (0..50).map { |i| "p#{i}=v" }.join("&") # 51 params: > MAX_PARAMS, < MAX_PARAMS_AGGRESSIVE
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      aggr = Gori::Probe::Active::Options.new(allow_unsafe: true, aggressive: true)

      reflected = Gori::Probe::Active::ReflectedParam.new
      cors = Gori::Probe::Active::CorsReflection.new

      post = capture_flow(store, plain_resp, host: "t.example", target: "/a?x=1&y=2", method: "POST")
      put = capture_flow(store, cors_resp, host: "t.example", target: "/cors", method: "PUT")
      wide = capture_flow(store, plain_resp, host: "t.example", target: "/many?#{many}", method: "POST")

      # allow_unsafe widens the method gate: a POST/PUT is now planned, and both paths agree.
      reflected.plan(post, unsafe).should_not be_nil
      reflected.dedup_key(post, unsafe).should eq(reflected.plan(post, unsafe).try(&.dedup_key))
      cors.plan(put, unsafe).should_not be_nil
      cors.dedup_key(put, unsafe).should eq(cors.plan(put, unsafe).try(&.dedup_key))

      # A 51-param POST: nil under allow_unsafe alone (over MAX_PARAMS), non-nil under aggressive.
      reflected.plan(wide, unsafe).should be_nil
      reflected.plan(wide, aggr).should_not be_nil
      reflected.dedup_key(wide, aggr).should eq(reflected.plan(wide, aggr).try(&.dedup_key))

      # Default opts leave the POST unprobed (automatic-pipeline behaviour unchanged).
      reflected.plan(post).should be_nil
      cors.plan(put).should be_nil
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

  # The disabled-rule list is the ONLY thing between a disabled active rule and a real request.
  # `store.probe_disabled_rules` used to swallow a store/parse failure into an empty set — read
  # as "nothing is disabled" — so a corrupt value made ACTIVE probing send everything. The
  # commit that added the `degraded` flag could never fire because of that swallow.
  it "fails closed on active probing when the disabled-rule list cannot be read" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        target: "/reflect?q=hi", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      detail = store.recent_flows(1).first.try { |r| store.get_flow(r.id) }.not_nil!

      # Sanity: a readable (empty) disabled list estimates at least one active rule for this flow.
      feed = Channel(Gori::Store::FlowEvent).new(8)
      ok = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Active, true)
      ok.active_estimate(detail).should_not be_empty

      # Corrupt the stored value to a truncated JSON blob — probe_disabled_rules now RAISES.
      store.@db.exec("INSERT OR REPLACE INTO settings (key, value) VALUES ('probe_disabled_rules', '[\"reflected')")
      expect_raises(JSON::ParseException) { store.probe_disabled_rules_strict } # active-send read raises
      store.probe_disabled_rules.should be_empty                                # display read degrades

      # An analyzer built on the corrupt store is degraded → estimates NOTHING (sends nothing).
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      degraded = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Active, true)
      degraded.active_estimate(detail).should be_empty
    end
  end

  # AGGRESSIVE drives the SAME automatic pipeline as ACTIVE (probes_actively?), but with widened
  # Options (unsafe methods + raised caps). It stays scope-gated. No network assert — the queue may
  # drop and sends to acme.test won't resolve; this verifies the pipeline re-arms and persists the
  # mode without raising over an in-scope unsafe-method (POST) flow.
  it "AGGRESSIVE mode re-arms the pipeline + persists over an in-scope POST flow" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        target: "/submit?q=hi", method: "POST", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")

      # start already in AGGRESSIVE (persisted project) — backfill path over the POST
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Aggressive, true)
      a.start
      sleep 50.milliseconds
      a.stop

      # ACTIVE → AGGRESSIVE transition mid-session re-arms and persists the new mode.
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      b = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Active, true)
      b.start
      b.set_mode(Gori::Probe::Mode::Aggressive)
      store.probe_mode.should eq(Gori::Probe::Mode::Aggressive)
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

  # The WS high-water mark must never advance over frames no rule READ. With ws_payloads off the
  # rescan still paged the buffer and moved the mark, so re-enabling the built-in could never
  # reach the frames captured while it was off — they were permanently invisible.
  it "detects a WS secret while ws_payloads is enabled (control for the disabled-rule case)" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      store.probe_disabled_rules_strict.includes?("ws_payloads").should be_false
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      store.insert_ws_message(fid, "in", 1, "token=AKIAIOSFODNN7EXAMPLE".to_slice)
      feed.send(Gori::Store::FlowEvent.new(fid, :updated))
      sleep 200.milliseconds
      a.stop
      store.probe_issues.find(&.code.== "secret_in_ws").should_not be_nil
    end
  end

  it "re-enabling ws_payloads still scans the frames captured while it was off" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      # Rule OFF before Analyzer.new — initialize reads the disabled set once.
      set_probe_rule_enabled(store, "ws_payloads", false)
      store.probe_disabled_rules_strict.includes?("ws_payloads").should be_true

      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start

      # The secret rides a frame captured while the rule was OFF — nothing reads it.
      store.insert_ws_message(fid, "in", 1, "token=AKIAIOSFODNN7EXAMPLE".to_slice)
      feed.send(Gori::Store::FlowEvent.new(fid, :updated))
      sleep 200.milliseconds
      store.probe_issues.find(&.code.== "secret_in_ws").should be_nil # rule is off — expected

      # Operator re-enables the built-in; the TUI calls reload_rule_config.
      set_probe_rule_enabled(store, "ws_payloads", true)
      a.reload_rule_config
      # Recovery is driven by the NEXT rescan_ws, not by reload_rule_config itself. No NEW
      # ws_message: the secret exists only in the frame written while the rule was off.
      feed.send(Gori::Store::FlowEvent.new(fid, :updated))
      sleep 200.milliseconds
      a.stop

      store.probe_issues.find(&.code.== "secret_in_ws").should_not be_nil
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
    Gori::Probe::Mode.from_setting("aggressive").should eq(Gori::Probe::Mode::Aggressive)
    Gori::Probe::Mode::Off.cycle.should eq(Gori::Probe::Mode::Passive)
    # OFF → PASSIVE → ACTIVE → AGGRESSIVE → OFF
    Gori::Probe::Mode::Active.cycle.should eq(Gori::Probe::Mode::Aggressive)
    Gori::Probe::Mode::Aggressive.cycle.should eq(Gori::Probe::Mode::Off)
  end

  it "persists and reloads Aggressive" do
    with_store do |store|
      store.set_probe_mode(Gori::Probe::Mode::Aggressive)
      store.probe_mode.should eq(Gori::Probe::Mode::Aggressive)
    end
  end

  it "probes_actively? covers Active and Aggressive only" do
    Gori::Probe::Mode::Off.probes_actively?.should be_false
    Gori::Probe::Mode::Passive.probes_actively?.should be_false
    Gori::Probe::Mode::Active.probes_actively?.should be_true
    Gori::Probe::Mode::Aggressive.probes_actively?.should be_true
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

  # The keyword tests were `includes?`, so any source merely CONTAINING the word scored the
  # whole policy weak — an allowlisted host or path is not a keyword.
  it "does not read an allowlisted host/path that merely contains a keyword as that keyword" do
    with_store do |store|
      ["script-src 'self' https://unsafe-evaluation.example",
       "script-src 'self' https://cdn.example.com/unsafe-inline.js",
       "script-src 'self' https://unsafe-inline-demo.example"].each do |policy|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: #{policy}\r\n\r\n",
          content_type: "text/html")
        codes_of(dets).should_not contain("weak_csp"), policy
      end
    end
  end

  # …while the real keywords still fire, quoted (per spec) or bare (as seen in the wild).
  it "flags the real keywords whether or not they are quoted" do
    with_store do |store|
      ["script-src 'self' 'unsafe-eval'", "script-src 'self' unsafe-eval",
       "script-src 'self' 'unsafe-inline'", "script-src 'self' unsafe-inline"].each do |policy|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: #{policy}\r\n\r\n",
          content_type: "text/html")
        codes_of(dets).should contain("weak_csp"), policy
      end
      # An unquoted strict-dynamic must still nullify 'unsafe-inline', like the quoted form.
      lenient = analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                          "script-src 'self' strict-dynamic 'unsafe-inline'\r\n\r\n",
        content_type: "text/html")
      codes_of(lenient).should_not contain("weak_csp")
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

  # The fingerprint's content-type gate was `json`, so a GraphQL request under the raw-document
  # type or as a urlencoded body was not GraphQL to it — the two shapes a JSON-content-type
  # filter is bypassed with, on an endpoint whose path does not say `/graphql`.
  it "fingerprints GraphQL under the content-types the JSON gate excluded" do
    with_store do |store|
      doc = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/gw",
        method: "POST", req_headers: "Content-Type: application/graphql\r\n",
        req_body: "query Me { me { id } }", content_type: nil)
      codes_of(doc).should contain("tech_graphql")

      form = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/gw",
        method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "query=query+Me+%7B+me+%7D&variables=%7B%7D", content_type: nil)
      codes_of(form).should contain("tech_graphql")
    end
  end

  it "keeps an ordinary form POST out of the GraphQL fingerprint" do
    with_store do |store|
      login = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/login",
        method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "user=a&pass=b", content_type: nil)
      codes_of(login).should_not contain("tech_graphql")
      search = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/search",
        method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "query=shoes&page=2", content_type: nil) # a `query=` param is not a document
      codes_of(search).should_not contain("tech_graphql")
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
    # The risk is a cache serving ONE user's data to another, so every case here authenticates.
    authed = "Cookie: sid=abc\r\n"

    it "flags application/json without Cache-Control (sensitive data may be stored)" do
      with_store do |store|
        dets = analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"token":"x"}), req_headers: authed)
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
            body: "{}", req_headers: authed)).should contain("cacheable_json")
        end
      end
    end

    # A public endpoint has nothing user-specific for a cache to leak, and leaving it cacheable is
    # a performance decision. Without this gate the rule fired on most 2xx JSON on most servers.
    it "does not flag an UNAUTHENTICATED response" do
      with_store do |store|
        codes_of(analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"public":true}))).should_not contain("cacheable_json")
      end
    end

    it "counts an Authorization request header or a Set-Cookie response as authenticated" do
      with_store do |store|
        codes_of(analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"me":1}),
          req_headers: "Authorization: Bearer x\r\n")).should contain("cacheable_json")
        codes_of(analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: sid=new\r\n\r\n",
          content_type: "application/json", body: %({"me":1}))).should contain("cacheable_json")
        # An empty Cookie header is not authentication.
        codes_of(analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"me":1}),
          req_headers: "Cookie:  \r\n")).should_not contain("cacheable_json")
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
          body: %({"title":"err"}), req_headers: authed)).should contain("cacheable_json")
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
      # A POST is never probed (no auto state mutation) even when denied…
      post = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
        method: "POST", content_type: nil)
      probe.plan(post).should be_nil
      # …unless the caller opts into unsafe methods (manual per-flow scan / AGGRESSIVE mode).
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      probe.plan(post, unsafe).should_not be_nil
      probe.dedup_key(post, unsafe).should eq(probe.plan(post, unsafe).try(&.dedup_key))
    end
  end

  it "uses the wider bypass-header set under aggressive opts (still one probe + one control)" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      base = String.new(probe.plan(forbidden).not_nil!.request)
      aggr = String.new(probe.plan(forbidden, Gori::Probe::Active::Options.new(aggressive: true)).not_nil!.request)
      # The extra headers appear only in the aggressive probe; the base set is present in both.
      Gori::Probe::Active::ForbiddenBypass::BYPASS_HEADERS_EXTRA.each do |name|
        base.should_not contain("\r\n#{name}: ")
        aggr.scan("\r\n#{name}: 127.0.0.1").size.should eq(1), "expected exactly one #{name} (aggressive)"
      end
      # A wider header SET, not more probes: still exactly one control follow-up.
      probe.plan(forbidden, Gori::Probe::Active::Options.new(aggressive: true)).not_nil!.followups.size.should eq(1)
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

  it "dedup_key distinguishes ACTIVE from AGGRESSIVE so the wider header set is not suppressed" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      base_key = probe.dedup_key(forbidden, Gori::Probe::Active::Options::DEFAULT).not_nil!
      aggr_opts = Gori::Probe::Active::Options.new(allow_unsafe: true, aggressive: true)
      aggr_key = probe.dedup_key(forbidden, aggr_opts).not_nil!
      base_key.should_not eq(aggr_key)
      base_key.should contain("|base")
      aggr_key.should contain("|aggr")
      # plan and dedup_key stay identical for each mode.
      probe.plan(forbidden).not_nil!.dedup_key.should eq(base_key)
      probe.plan(forbidden, aggr_opts).not_nil!.dedup_key.should eq(aggr_key)
    end
  end

  it "flags a possible bypass (Medium) only when the probe flips to 2xx and the control still denies" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      denied = Gori::Repeater::Result.new("HTTP/1.1 403 Forbidden\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)

      dets = probe.detections_all(plan, [ok, denied], forbidden)
      dets.size.should eq(1)
      dets.first.code.should eq("forbidden_bypass")
      # Two adjacent requests can't rule out disagreeing backends → Medium "possible", not High.
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      dets.first.evidence.not_nil!.should contain("control without the headers still 403")

      # Still denied WITH the headers → the gate held → not flagged.
      probe.detections_all(plan, [denied, denied], forbidden).should be_empty
      # A redirect (e.g. to login) is ambiguous → not flagged.
      redirect = Gori::Repeater::Result.new("HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections_all(plan, [redirect, denied], forbidden).should be_empty
      # A send failure never flags.
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan, [errored, denied], forbidden).should be_empty
    end
  end

  # The control leg is the point of the rule: a 403 that had already cleared on its own answers
  # 2xx WITHOUT the spoofed headers too, and must not be reported as a header-driven bypass.
  it "does not flag when the control also succeeds (the gate simply opened)" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections_all(plan, [ok, ok], forbidden).should be_empty
      # A missing or errored control is no attribution either — never fall back to the captured status.
      probe.detections_all(plan, [ok], forbidden).should be_empty
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan, [ok, errored], forbidden).should be_empty
    end
  end

  # The two legs must differ in exactly one thing: our forged values. Both drop whatever the
  # browser sent, so a difference can never come from the browser's own X-Forwarded-For.
  it "builds a control that is the same request WITHOUT the spoofed headers" do
    with_store do |store|
      forbidden = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
        req_headers: "X-Forwarded-For: 9.9.9.9\r\n", content_type: nil)
      control = String.new(probe.plan(forbidden).not_nil!.followups.first)
      control.should start_with("GET /admin ")
      control.should_not contain("127.0.0.1") # none of our forged values
      control.should_not contain("9.9.9.9")   # nor the browser's own, dropped on both legs
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

describe "Gori::Probe::Active::NextjsActionNoAuth" do
  probe = Gori::Probe::Active::NextjsActionNoAuth.new
  aid = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" # a 40-hex server-action id
  unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
  # A privileged-looking payload that reads like a successful action result, not a rejection.
  priv = %({"user":"alice","email":"alice@corp.test","role":"admin","balance":42000})
  # Raw request-header lines for a server-action invocation carrying a session cookie.
  action_headers = "Next-Action: #{aid}\r\nCookie: session=secret\r\nContent-Type: text/x-component\r\n"

  # Build a captured server-action POST (SUCCEEDED with credentials by default). A proc, not a
  # def — Crystal has no method definitions inside a spec block; this closes over capture_flow.
  action_flow = ->(store : Gori::Store, headers : String, status : Int32, body : String) do
    capture_flow(store, "HTTP/1.1 #{status} OK\r\n\r\n", target: "/dashboard", status: status,
      method: "POST", req_headers: headers, req_body: %(["x"]),
      body: body, content_type: "text/x-component")
  end

  it "only probes a credentialed, successful server-action invocation" do
    with_store do |store|
      # A POST server action is unsafe → not probed automatically…
      flow = action_flow.call(store, action_headers, 200, priv)
      probe.plan(flow).should be_nil
      # …but IS probed when the caller opts into unsafe methods (manual scan / AGGRESSIVE).
      probe.plan(flow, unsafe).should_not be_nil
      probe.dedup_key(flow, unsafe).should eq(probe.plan(flow, unsafe).try(&.dedup_key))

      # No Next-Action header → not a server-action invocation → nil.
      not_action = action_flow.call(store, "Cookie: session=secret\r\n", 200, priv)
      probe.plan(not_action, unsafe).should be_nil

      # No credential to strip → nothing to prove → nil.
      no_creds = action_flow.call(store, "Next-Action: #{aid}\r\n", 200, priv)
      probe.plan(no_creds, unsafe).should be_nil

      # The authenticated call itself failed → a matching failure without creds isn't a finding → nil.
      failed = action_flow.call(store, action_headers, 500, priv)
      probe.plan(failed, unsafe).should be_nil
    end
  end

  it "strips Cookie / Authorization but keeps Next-Action and the body" do
    with_store do |store|
      headers = "Next-Action: #{aid}\r\nCookie: session=secret\r\nAuthorization: Bearer tok\r\nContent-Type: text/x-component\r\n"
      flow = action_flow.call(store, headers, 200, priv)
      text = String.new(probe.plan(flow, unsafe).not_nil!.request)
      text.downcase.should_not contain("\r\ncookie:")
      text.downcase.should_not contain("\r\nauthorization:")
      text.should contain("Next-Action: #{aid}")
      text.should contain(%(["x"]))                               # body preserved
      probe.plan(flow, unsafe).not_nil!.followups.should be_empty # single request
    end
  end

  # RFC 7230 §3.2.4 obs-fold: a line beginning with SP/HTAB continues the header above it.
  # Testing lines independently dropped the `Cookie:` line and kept its continuation, which
  # then reads as a header line of its own — a head gori forged, sent to the origin as the
  # control request the entire finding rests on.
  it "drops an obs-folded credential header's continuation lines with it" do
    with_store do |store|
      headers = "Next-Action: #{aid}\r\nCookie: session=secret;\r\n more=alsosecret\r\nAccept: */*\r\n"
      flow = action_flow.call(store, headers, 200, priv)
      text = String.new(probe.plan(flow, unsafe).not_nil!.request)
      text.downcase.should_not contain("cookie:")
      text.should_not contain("alsosecret") # the folded continuation went with its header
      text.should contain("Next-Action: #{aid}")
      text.should contain("Accept: */*") # the header after the fold survives
    end
  end

  it "keeps an obs-folded NON-credential header whole" do
    with_store do |store|
      headers = "Next-Action: #{aid}\r\nCookie: session=secret\r\nX-Trace: one;\r\n\ttwo\r\nAccept: */*\r\n"
      flow = action_flow.call(store, headers, 200, priv)
      text = String.new(probe.plan(flow, unsafe).not_nil!.request)
      text.downcase.should_not contain("cookie:")
      text.should contain("X-Trace: one;")
      text.should contain("two") # its continuation is not collateral damage
    end
  end

  it "flags a possible missing-authorization (Medium) when the stripped request still returns a comparable 2xx" do
    with_store do |store|
      flow = action_flow.call(store, action_headers, 200, priv)
      plan = probe.plan(flow, unsafe).not_nil!

      # Credential-less re-send STILL returns the privileged payload → possible bypass.
      bypassed = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64)
      dets = probe.detections(plan, bypassed, flow)
      dets.size.should eq(1)
      dets.first.code.should eq("nextjs_action_no_auth")
      dets.first.category.should eq(Gori::Probe::Category::ACTIVE)
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      dets.first.evidence.not_nil!.should contain(aid[0, 8]) # short action id in the evidence
    end
  end

  it "does not flag when the control held or the response isn't clearly privileged" do
    with_store do |store|
      flow = action_flow.call(store, action_headers, 200, priv)
      plan = probe.plan(flow, unsafe).not_nil!

      # 401 without creds → the gate held.
      denied = Gori::Repeater::Result.new("HTTP/1.1 401 Unauthorized\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, denied, flow).should be_empty
      # 302 → login is not 2xx.
      redirect = Gori::Repeater::Result.new("HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, redirect, flow).should be_empty
      # A 200 whose body is an in-band "unauthorized" notice → not a bypass.
      inband = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, %({"error":"Unauthorized"}).to_slice, nil, 1_i64)
      probe.detections(plan, inband, flow).should be_empty
      # An empty 200 (no payload returned to the anonymous client).
      empty = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, empty, flow).should be_empty
      # A trimmed stub far smaller than the authenticated baseline.
      stub = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "ok".to_slice, nil, 1_i64)
      probe.detections(plan, stub, flow).should be_empty
      # A 2xx that bounced the anonymous caller to login in-band (Next.js redirect() header) → control held.
      to_login = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nX-Action-Redirect: /login\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64)
      probe.detections(plan, to_login, flow).should be_empty
      # …same via a plain Location to an auth route on a 2xx.
      loc_login = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nLocation: /auth/signin\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64)
      probe.detections(plan, loc_login, flow).should be_empty
      # A truncated (incomplete) probe response is untrusted → never flags, even if it looks privileged.
      partial = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64, nil, true)
      probe.detections(plan, partial, flow).should be_empty
      # A send failure never flags.
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections(plan, errored, flow).should be_empty
    end
  end

  # `Http1.parse_headers` builds a header VALUE with a bare `String.new`, so a non-UTF-8 byte in a
  # probe response's Location made `LOGIN_PATH.matches?` raise. That raise was caught by
  # `detections`' method-level rescue, which returns NO detections — so the whole rule went silent
  # on that host rather than crashing. Both directions are pinned: the suppression still works, and
  # a genuine bypass is still reported.
  it "still judges a redirect target carrying a non-UTF-8 byte" do
    with_store do |store|
      flow = action_flow.call(store, action_headers, 200, priv)
      plan = probe.plan(flow, unsafe).not_nil!

      # An auth route with a stray byte → control still held, still suppressed.
      bad_login = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nLocation: /auth/\xFFx\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64)
      probe.detections(plan, bad_login, flow).should be_empty

      # A non-auth Location with a stray byte → nothing suppresses, the bypass is reported.
      # This is the case that produced no detection at all before the scrub.
      bad_other = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nLocation: /assets/\xFF.bin\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64)
      dets = probe.detections(plan, bad_other, flow)
      dets.size.should eq(1)
      dets.first.code.should eq("nextjs_action_no_auth")
    end
  end

  it "does not flag when the authenticated baseline had no body to compare against" do
    with_store do |store|
      # An empty-bodied 200 (or a 204) authenticated action: there is no privileged payload to
      # match, so an arbitrary non-empty credential-less response must not produce a finding.
      flow = action_flow.call(store, action_headers, 200, "")
      plan = probe.plan(flow, unsafe).not_nil!
      answered = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, priv.to_slice, nil, 1_i64)
      probe.detections(plan, answered, flow).should be_empty
    end
  end

  it "dedup_key equals plan.dedup_key across gating cases (per-opts)" do
    with_store do |store|
      cases = [
        {headers: action_headers, status: 200, method: "POST"},                                       # credentialed success
        {headers: action_headers, status: 200, method: "GET"},                                        # rare GET action
        {headers: "Next-Action: #{aid}\r\n", status: 200, method: "POST"},                            # no creds → nil
        {headers: "Cookie: s=1\r\n", status: 200, method: "POST"},                                    # no Next-Action → nil
        {headers: action_headers, status: 500, method: "POST"},                                       # not 2xx → nil
        {headers: "Next-Action: #{aid}\r\nAuthorization: Bearer t\r\n", status: 204, method: "POST"}, # bearer + 2xx
      ]
      cases.each do |c|
        d = capture_flow(store, "HTTP/1.1 #{c[:status]} X\r\n\r\n", scheme: "http", host: "t.example",
          target: "/dashboard", method: c[:method], status: c[:status],
          req_headers: c[:headers], req_body: %(["x"]), content_type: nil)
        probe.dedup_key(d, unsafe).should eq(probe.plan(d, unsafe).try(&.dedup_key)),
          "nextjs_action_no_auth #{c[:method]} #{c[:status]}"
      end
    end
  end
end

describe "Gori::Probe::Active::NginxAliasTraversal" do
  probe = Gori::Probe::Active::NginxAliasTraversal.new

  it "only probes a 2xx non-HTML GET whose path is /<seg>/<more>" do
    with_store do |store|
      # The classic case: a static asset under a leading location segment.
      css = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/main.css",
        status: 200, content_type: "text/css")
      probe.plan(css).should_not be_nil

      # HTML baseline is skipped (a SPA catch-all would byte-match the traversal probe with no bug).
      html = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/app/index",
        status: 200, content_type: "text/html")
      probe.plan(html).should be_nil
      # A non-2xx resource has nothing to re-fetch.
      missing = capture_flow(store, "HTTP/1.1 404 Not Found\r\n\r\n", target: "/static/x.js",
        status: 404, content_type: "application/javascript")
      probe.plan(missing).should be_nil
      # Single-segment / directory paths have no resource under a location to fold `..` after.
      root = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/favicon.ico",
        status: 200, content_type: "image/x-icon")
      probe.plan(root).should be_nil
      dir = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/",
        status: 200, content_type: "text/css")
      probe.plan(dir).should be_nil
      # HEAD is excluded — the confirmation compares bodies and HEAD returns none.
      head = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/main.css",
        status: 200, method: "HEAD", content_type: "text/css")
      probe.plan(head).should be_nil
    end
  end

  it "folds `..` after the leading segment, keeping the query, and stays origin-form" do
    with_store do |store|
      css = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/js/app.js?v=3",
        status: 200, content_type: "application/javascript")
      plan = probe.plan(css).not_nil!
      String.new(plan.request).each_line.first.should start_with("GET /static../static/js/app.js?v=3 ")

      # A forward-proxy absolute-form flow is normalized to origin-form before the fold.
      abs = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "t.example",
        target: "http://t.example/assets/style.css", status: 200, content_type: "text/css")
      line = String.new(probe.plan(abs).not_nil!.request).each_line.first
      line.should start_with("GET /assets../assets/style.css ")
      line.should_not contain("http://t.example")
    end
  end

  it "flags High only when the folded path returns byte-identical content" do
    with_store do |store|
      css = capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\n\r\n",
        target: "/static/main.css", status: 200, content_type: "text/css", body: "body{color:red}")
      plan = probe.plan(css).not_nil!

      # Vulnerable: the same file comes back through the fold → confirmed.
      hit = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\n\r\n".to_slice, "body{color:red}".to_slice, nil, 1_i64)
      dets = probe.detections(plan, hit, css)
      dets.size.should eq(1)
      dets.first.code.should eq("nginx_alias_traversal")
      dets.first.severity.should eq(Gori::Store::Severity::High)

      # Not vulnerable: the folded path 404s → not flagged.
      not_found = Gori::Repeater::Result.new(
        "HTTP/1.1 404 Not Found\r\n\r\n".to_slice, "nope".to_slice, nil, 1_i64)
      probe.detections(plan, not_found, css).should be_empty
      # A 200 with a DIFFERENT body (e.g. a catch-all page) is not the same resource → not flagged.
      other = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\n\r\n".to_slice, "something else".to_slice, nil, 1_i64)
      probe.detections(plan, other, css).should be_empty
      # A send failure never flags.
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections(plan, errored, css).should be_empty
    end
  end

  it "dedup_key equals plan.dedup_key across eligible/ineligible flows" do
    with_store do |store|
      cases = [
        {target: "/static/main.css", method: "GET", status: 200, ct: "text/css"},        # eligible
        {target: "/static/main.css?v=1", method: "GET", status: 200, ct: "text/css"},    # query stripped in key
        {target: "/a/b/c.js", method: "GET", status: 200, ct: "application/javascript"}, # deep path
        {target: "/static/main.css", method: "GET", status: 200, ct: "text/html"},       # HTML → nil
        {target: "/static/main.css", method: "GET", status: 404, ct: "text/css"},        # non-2xx → nil
        {target: "/static/main.css", method: "HEAD", status: 200, ct: "text/css"},       # HEAD → nil
        {target: "/favicon.ico", method: "GET", status: 200, ct: "image/x-icon"},        # single segment → nil
        {target: "/has space", method: "GET", status: 200, ct: "text/css"},              # malformed → nil
      ]
      cases.each do |c|
        d = capture_flow(store, "HTTP/1.1 #{c[:status]} X\r\n\r\n", scheme: "http", host: "t.example",
          target: c[:target], method: c[:method], status: c[:status], content_type: c[:ct])
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key)),
          "nginx_alias_traversal #{c[:target]} #{c[:method]} #{c[:status]} #{c[:ct]}"
      end
    end
  end

  it "widens to non-GET body methods under allow_unsafe, but never HEAD" do
    with_store do |store|
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "t.example",
        target: "/static/main.css", method: "POST", status: 200, content_type: "text/css")
      probe.plan(post).should be_nil             # GET-only by default
      probe.plan(post, unsafe).should_not be_nil # body-differential still works on a POST
      probe.dedup_key(post, unsafe).should eq(probe.plan(post, unsafe).try(&.dedup_key))
      # HEAD has no body to diff — excluded even with allow_unsafe.
      head = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "t.example",
        target: "/static/main.css", method: "HEAD", status: 200, content_type: "text/css")
      probe.plan(head, unsafe).should be_nil
    end
  end
end

describe "Gori::Probe::Active (safety + coverage)" do
  it "does not probe mutating methods (POST) by default, but opts-in widens it" do
    with_store do |store|
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/comment", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: "text=hi", content_type: nil)
      Gori::Probe::Active.plan(post).should be_nil # automatic pipeline (default opts) never mutates
      # The manual opt-in / AGGRESSIVE mode probes the reflectable form params on the POST.
      Gori::Probe::Active.plan(post, Gori::Probe::Active::Options.new(allow_unsafe: true)).should_not be_nil
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

  it "never sends an active probe when the scope EXCLUDES the target (ScopedBackend hard-block)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("exclude", "host", "acme.test")
      fake = CountingBackend.new(Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port))
      dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope), backend: fake)
      fake.sent.should eq(0) # blocked before the socket — proves scope, not a send failure
      dets.should be_empty
    end
  end

  it "caps active sends via active_limit but never truncates the passive scan (R1-5)" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/b?token=bbbbbbbb", content_type: nil)
      ids = Gori::Probe::Scan.flow_ids(store, nil)
      ids.size.should eq(2)
      passive = Gori::Probe::Scan.scan_flows(store, ids, active: false)
      # active:true with a 0 active budget → ZERO active sends (no network), and the
      # request-free passive scan must still cover BOTH flows — not be truncated with it.
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      capped = Gori::Probe::Scan.scan_flows(store, ids, active: true, scope: scope, active_limit: 0)
      capped.size.should eq(passive.size)
      capped.count { |d| d.code == "secret_in_url" }.should eq(2) # both flows' passive issue kept
    end
  end

  # `scan_repeaters` had no budget at all, so an MCP `probe_scan active:true` could send far
  # past its own PROBE_ACTIVE_MAX_FLOWS: repeater tabs are unbounded and the rule set costs 33
  # requests per tab (47 aggressive). The cap now covers the whole scan.
  it "spends ONE active budget across flows and repeater tabs" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      store.insert_repeater("http://acme.test/r", "GET /r?token=cccccccc HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      ids = Gori::Probe::Scan.flow_ids(store, nil)

      budget = Gori::Probe::Scan::Budget.new(0)
      Gori::Probe::Scan.scan_all(store, ids, active: true, scope: scope, active_budget: budget)
      # Nothing was sent, so the cap was reached — which is the question `active_flows_capped`
      # should answer, rather than `ids.size > limit` on a pre-filter count.
      budget.exhausted?.should be_true
    end
  end

  # The disabled-rule set is the only thing between an ACTIVE rule the operator switched off
  # and a real request. Its read used to degrade to an EMPTY set — "nothing is disabled" — on
  # a store error, which is a fail-OPEN on the half of this config that authorises traffic.
  it "skips ACTIVE probing when the disabled-rule list could not be read" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      ids = Gori::Probe::Scan.flow_ids(store, nil)
      degraded = Gori::Probe::Scan::RuleConfig.new(Set(String).new, [] of Gori::Probe::CustomRule, degraded: true)
      said = [] of String
      dets = Gori::Probe::Scan.scan_all(store, ids, active: true, scope: scope, rules: degraded,
        on_error: ->(where : String, ex : Exception) { said << "#{where}: #{ex.message}"; nil })[0]
      # It is NAMED, not silent — a scan that quietly stopped probing would read as clean.
      said.first.should contain("active probing was skipped")
      # …and the request-free passive half still ran.
      dets.count { |d| d.code == "secret_in_url" }.should eq(1)
    end
  end

  it "sends active probes when the scope ALLOWLISTS the target" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      fake = CountingBackend.new(Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port))
      Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope), backend: fake)
      fake.sent.should be > 0 # an include rule (no exclude, sandbox off) lets the probe through
    end
  end

  # --- per-rule error isolation (the headless path used to have none) ---------------------
  #
  # The TUI analyzer has always wrapped each rule in its own rescue (execute_active), so a rule
  # that raised was merely skipped there. Active.analyze — the CLI / MCP path — had no such
  # rescue, so the SAME rule killed a whole `gori run probe` batch. These pin the parity.

  it "isolates a rule that raises and keeps running the rest" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)
      backend = RaisingBackend.new(origin)
      failed = [] of String
      dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope),
        backend: backend, on_error: ->(where : String, _ex : Exception) { failed << where; nil })
      dets.should be_empty # nothing could be detected — every send blew up
      # ...but the loop did not abort on the first raise: more than one rule got to run and
      # report. Without the rescue this example never reaches an assertion at all.
      failed.size.should be > 1
      backend.sent.should eq(failed.size)
    end
  end

  it "still produces a later rule's finding after an earlier rule raises" do
    with_store do |store|
      # An ACAO on the captured response is cors_reflection's gate; reflected_param (RULES[0])
      # sends first and is the one that dies.
      detail = capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://app.acme.test\r\n\r\n",
        target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)
      failed = [] of String
      dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope),
        backend: FlakyCorsBackend.new(origin),
        on_error: ->(where : String, _ex : Exception) { failed << where; nil })
      # on_error carries the RULE id; the Detection carries its own finding CODE.
      failed.should eq(["reflected_param"])                    # the first rule died...
      dets.map(&.code).should contain("cors_arbitrary_origin") # ...a later rule still reported
    end
  end

  it "reports no scan errors on a clean Scan.scan_flows run" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      ids = Gori::Probe::Scan.flow_ids(store, nil)
      failed = [] of String
      dets = Gori::Probe::Scan.scan_flows(store, ids, active: false,
        on_error: ->(where : String, _ex : Exception) { failed << where; nil })
      failed.should be_empty
      dets.should_not be_empty
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

  # The canary carries a `"'<>` marker; the grade is decided by which of those characters came
  # back VERBATIM, not by "the value came back" (which is true of correctly-escaped output too).
  it "grades a reflection by which marker characters survived" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      raw = Gori::Probe::Active::ReflectedParam.probe_value(canary)
      html_head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
      res = ->(head : String, body : String) do
        Gori::Repeater::Result.new(head.to_slice, body.to_slice, nil, 1_i64)
      end

      # `<` came back raw in HTML → tag injection possible → the historic Medium.
      d = Gori::Probe::Active.detections(plan, res.call(html_head, "<p>#{raw}</p>"), detail).first
      d.severity.should eq(Gori::Store::Severity::Medium)
      d.title.should contain("unencoded")

      # Same raw echo in a JSON body: not an HTML sink → Low.
      json_head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
      Gori::Probe::Active.detections(plan, res.call(json_head, %({"q":"#{raw}"})), detail)
        .first.severity.should eq(Gori::Store::Severity::Low)

      # Quotes survived but `<` was escaped → attribute context only → Low.
      attr_echo = %(<a title="#{canary}"'&lt;&gt;">x</a>)
      d2 = Gori::Probe::Active.detections(plan, res.call(html_head, attr_echo), detail).first
      d2.severity.should eq(Gori::Store::Severity::Low)
      d2.title.should contain("attribute context")

      # Everything escaped → a reflection POINT, not a vulnerability → Info, not Medium.
      escaped = "<p>#{canary}&quot;&#39;&lt;&gt;</p>"
      d3 = Gori::Probe::Active.detections(plan, res.call(html_head, escaped), detail).first
      d3.severity.should eq(Gori::Store::Severity::Info)
      d3.title.should contain("escaped or filtered")
    end
  end

  # A value routinely lands in several places in one response, and the ESCAPED one is as likely
  # to come first as the raw one — a value is only as safe as its weakest sink.
  it "grades on the weakest sink when the value is reflected more than once" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      raw = Gori::Probe::Active::ReflectedParam.probe_value(canary)
      # Escaped in the page text FIRST, raw inside a later script block.
      body = "<p>#{canary}&quot;&#39;&lt;&gt;</p><script>var q=\"#{raw}\";</script>"
      d = Gori::Probe::Active.detections(plan,
        Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
          body.to_slice, nil, 1_i64), detail).first
      d.severity.should eq(Gori::Store::Severity::Medium)
      d.title.should contain("unencoded")
    end
  end

  # Same reasoning across the head/body split: a header echo must not mask a raw body echo.
  it "grades on the weakest sink across the response head and body" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      raw = Gori::Probe::Active::ReflectedParam.probe_value(canary)
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nX-Echo: #{canary}\r\n\r\n"
      d = Gori::Probe::Active.detections(plan,
        Gori::Repeater::Result.new(head.to_slice, "<p>#{raw}</p>".to_slice, nil, 1_i64), detail).first
      d.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  # The marker has to reach the server as real characters, and the canary must still be findable.
  it "sends the marker URL-encoded in the query and JSON-escaped in a body" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      req = String.new(plan.request)
      req.should contain("q=#{canary}%22%27%3C%3E")
      req.should_not contain("<") # nothing raw on the request line

      body_detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"q":"hi"}), content_type: nil)
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      jplan = Gori::Probe::Active::ReflectedParam.new.plan(body_detail, unsafe).not_nil!
      jc = jplan.params.first.canary
      String.new(jplan.request).should contain(%(#{jc}\\"'<>))
    end
  end

  it "skips active analysis safely when active probe target connection fails or yields no plan" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/no-params", content_type: nil)
      dets = Gori::Probe::Active.analyze(detail, outbound: ungated_outbound)
      dets.should be_empty
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
    end
  end

  # Binary frames used to be skipped, and a spec asserted that without recording why. protobuf /
  # msgpack / CBOR over WebSocket is the mainstream encoding for realtime APIs and a token rides
  # in such a frame as an ordinary ASCII string field, so skipping them was a plain false negative
  # on the transport this rule exists for. No deframing is involved: the patterns are ASCII vendor
  # prefixes, and the projection maps every non-printable byte to a space.
  it "flags a secret embedded in a BINARY WebSocket frame" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      secret = "AKIAIOSFODNN7EXAMPLE"
      # A protobuf-ish frame: field tags and lengths around an ASCII string field.
      payload = Bytes.new(secret.bytesize + 6)
      payload[0] = 0x0a_u8; payload[1] = secret.bytesize.to_u8
      secret.to_slice.copy_to(payload.to_unsafe + 2, secret.bytesize)
      payload[secret.bytesize + 2] = 0x10_u8
      payload[secret.bytesize + 3] = 0xff_u8 # invalid UTF-8, so the text path would have mangled it
      payload[secret.bytesize + 4] = 0x00_u8
      payload[secret.bytesize + 5] = 0x80_u8
      bin = [Gori::Store::WsMessage.new(2_i64, detail.row.id, nil, 1_i64, "in", 2, payload)]
      hit = Gori::Probe::Passive.analyze(detail, bin).find { |d| d.code == "secret_in_ws" }.not_nil!
      hit.evidence.should eq("AWS access key id")
      hit.evidence.not_nil!.should_not contain(secret)
    end
  end

  it "does not scan control frames or gori's own advisory rows" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      secret = "AKIAIOSFODNN7EXAMPLE"
      # opcode 8 = close: a control frame carries no application payload.
      close = [Gori::Store::WsMessage.new(3_i64, detail.row.id, nil, 1_i64, "in", 8, secret.to_slice)]
      Gori::Probe::Passive.analyze(detail, close).map(&.code).should_not contain("secret_in_ws")
    end
  end

  it "finds nothing in a binary frame that carries no credential shape" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      noise = Bytes.new(4096) { |i| ((i * 37) % 256).to_u8 }
      Gori::Probe::Passive.analyze(detail, [
        Gori::Store::WsMessage.new(4_i64, detail.row.id, nil, 1_i64, "in", 2, noise),
      ]).map(&.code).should_not contain("secret_in_ws")
    end
  end

  it "builds a FlowDetail from a RepeaterRecord and passive-scans it" do
    with_store do |store|
      req = "GET /api HTTP/1.1\r\nHost: repeater.test\r\n\r\n"
      resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.25\r\n\r\n"
      id = store.insert_repeater("https://repeater.test", req.to_slice, false, true, nil, 0)
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
      id = store.insert_repeater("http://acme.test", req.to_slice, false, false, nil, 0)
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
      id = store.insert_repeater("https://empty.test", "GET / HTTP/1.1\r\nHost: empty.test\r\n\r\n".to_slice,
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
      codes_of(dets).should contain("dom_xss")        # client_body_text path
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

  # The origin test used to run over the WHOLE fragment, so one unrelated `.origin` anywhere in a
  # bundle suppressed every finding in it — the rule detected nothing on real bundles.
  it "still flags an unchecked handler when an unrelated .origin exists elsewhere in the bundle" do
    with_store do |store|
      js = %(var o = location.origin + "/api";) + ("var pad#{1};" * 5) +
           %(window.addEventListener("message", function(e){ handle(e.data); });)
      codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "judges each handler separately — a checked one does not vouch for an unchecked one" do
    with_store do |store|
      checked = %(window.addEventListener("message", function(e){ if (e.origin === "https://x") a(e.data); });)
      unchecked = %(window.addEventListener("message", function(e){ b(e.data); });)
      codes_of(analyze_js(store, checked + unchecked)).should contain("postmessage_no_origin")
      codes_of(analyze_js(store, checked + checked)).should_not contain("postmessage_no_origin")
    end
  end

  # A handler passed by NAME has its body elsewhere, so no window around the call site can say
  # whether it checks the origin — guessing there would be a false positive.
  it "does not judge a handler passed by name (body not visible here)" do
    with_store do |store|
      js = %(function onMsg(e){ handle(e.data); } window.addEventListener("message", onMsg);)
      codes_of(analyze_js(store, js)).should_not contain("postmessage_no_origin")
    end
  end

  it "flags an arrow-function handler with no origin check" do
    with_store do |store|
      js = %(window.addEventListener("message", (e) => { handle(e.data); });)
      codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "does not flag an origin check that sits far past the handler window" do
    with_store do |store|
      js = %(window.onmessage = function(e){ ) + ("noop();" * 400) + %( if (e.origin) ok(); };)
      # The check is beyond HANDLER_WINDOW, so the handler reads as unchecked — the deliberate
      # cost of scoping the test to a window rather than the whole fragment.
      codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
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

  # ANCHOR_BLANK is /i, so it matches uppercase markup; the rel suppression must be too, or the
  # very attribute that makes the tag safe goes unrecognised.
  it "recognises rel=noopener/noreferrer regardless of case" do
    with_store do |store|
      [%(<a TARGET="_blank" REL="NOOPENER" href="/x">x</a>),
       %(<a Target="_blank" Rel="NoReferrer" href="/x">x</a>),
       %(<a target="_blank" rel="NOREFERRER NOOPENER" href="/x">x</a>)].each do |tag|
        codes_of(analyze_html(store, tag)).should_not contain("reverse_tabnabbing"), tag
      end
    end
  end

  # Browsers have defaulted target=_blank to noopener since 2021, so this is markup hygiene,
  # not a vulnerability — an external link is on nearly every page.
  it "reports reverse-tabnabbing at Info, not Low" do
    with_store do |store|
      d = analyze_html(store, %(<a target="_blank" href="http://x/">x</a>))
        .find(&.code.== "reverse_tabnabbing")
      d.not_nil!.severity.should eq(Gori::Store::Severity::Info)
    end
  end
end

describe "Gori::Probe::Passive::Secrets (client-side shapes)" do
  it "flags a Slack webhook embedded in a JS bundle" do
    with_store do |store|
      hook = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
      codes_of(analyze_js(store, "var w = '#{hook}';")).should contain("secret_in_body")
    end
  end

  # A JWT is the one shape in this family an app legitimately hands its own client, so it is
  # NOT a High secret_in_body — it gets its own Info code (see Secrets::JWT).
  it "reports a JWT as Info jwt_in_body, never as a High secret_in_body" do
    with_store do |store|
      dets = analyze_js(store, "var t = '#{JWT}';")
      codes_of(dets).should_not contain("secret_in_body")
      d = dets.find(&.code.== "jwt_in_body").not_nil!
      d.severity.should eq(Gori::Store::Severity::Info)
      d.category.should eq(Gori::Probe::Category::INFOLEAK)
    end
  end

  # The High tier must still fire on the shapes a server has no business sending a browser,
  # and a body carrying BOTH must report both — the JWT split must not swallow the real leak.
  it "still reports a High secret_in_body alongside the JWT note" do
    with_store do |store|
      dets = analyze_js(store, "var k='AKIAIOSFODNN7EXAMPLE',t='#{JWT}';")
      sec = dets.find(&.code.== "secret_in_body").not_nil!
      sec.severity.should eq(Gori::Store::Severity::High)
      sec.evidence.should eq("AWS access key id")
      codes_of(dets).should contain("jwt_in_body")
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
  it "requests_per_flow is a sane bounded range for every built-in active rule" do
    Gori::Probe::Active::RULES.each do |rule|
      r = rule.requests_per_flow
      r.begin.should be >= 1
      r.end.should be >= r.begin
      # Nothing floods a single flow with probes. The ONE exception is the OFF-BY-DEFAULT,
      # opt-in request-smuggling detector: it legitimately spends more (2 baselines + 3 variants
      # × 2 timing probes + a 2-member differential group) because it runs only when the operator
      # explicitly enables it AND opts into unsafe/aggressive — see Probe::DEFAULT_DISABLED_RULES.
      r.end.should be <= (rule.info.id == "request_smuggling" ? 10 : 8)
    end
    by_id = Gori::Probe::Active::RULES.to_h { |rule| {rule.info.id, rule.requests_per_flow} }
    # BackslashPowered: TWO baselines (the second proves the endpoint is stable enough to diff
    # against) plus a `\`/`\\` pair per param, capped at 3 params → 4..8.
    by_id["backslash_powered"].should eq(4..8)
    # The bypass family each carry a control leg, so none of them is a single request:
    # forbidden_bypass probe+control, url_rewrite_bypass probe+control+control2,
    # path_normalization_bypass 5-6 variants + the canonical-path control.
    by_id["forbidden_bypass"].should eq(2..2)
    by_id["url_rewrite_bypass"].should eq(3..3)
    by_id["path_normalization_bypass"].should eq(6..7)
    # The off-by-default request-smuggling detector: 2 baselines + 3 variants × 2 timing probes
    # (8), plus the 2-member differential group under aggressive+unsafe (10).
    by_id["request_smuggling"].should eq(8..10)
    ["reflected_param", "cors_reflection"].each { |id| by_id[id].should eq(1..1) }
  end

  it "estimate_label renders a fixed count and a range" do
    Gori::Probe::Active.estimate_label(1..1).should eq("1 req/flow")
    Gori::Probe::Active.estimate_label(1..3).should eq("1–3 req/flow")
  end

  it "estimates the applicable rules for a GET with a reflectable query param + CORS" do
    with_store do |store|
      detail = capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.test\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi", body: "<p>hi</p>")
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      est = a.active_estimate(detail)
      # reflected_param, cors_reflection, backslash_powered all apply — plus crlf_injection and ssti,
      # which reuse the same reflectable-query-param gate.
      est.map(&.info.id).sort.should eq(["backslash_powered", "cors_reflection", "crlf_injection", "reflected_param", "ssti"])
      # reflected_param (1) + cors_reflection (1) + backslash_powered (≤8) + crlf_injection (1) + ssti (2) = 13
      est.sum { |e| e.requests.end }.should eq(13)
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
      # RULES order (cors_reflection disabled): reflected_param, backslash_powered, then the other
      # reflectable-query-param rules crlf_injection and ssti.
      a.active_estimate(detail).map(&.info.id).should eq(["reflected_param", "backslash_powered", "crlf_injection", "ssti"])
    end
  end

  it "estimates zero for an unsafe-method / paramless / non-CORS flow" do
    with_store do |store|
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      # POST is never probed under the default (safe-only) estimate…
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/x?q=1", method: "POST")
      a.active_estimate(post).should be_empty
      # …but the allow_unsafe estimate (the run popup's opt-in) surfaces the reflectable-param check.
      unsafe_est = a.active_estimate(post, Gori::Probe::Active::Options.new(allow_unsafe: true))
      unsafe_est.map(&.info.id).should contain("reflected_param")
      # GET with no params + no ACAO has nothing to test, opt-in or not.
      bare = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/nothing")
      a.active_estimate(bare).should be_empty
      a.active_estimate(bare, Gori::Probe::Active::Options.new(allow_unsafe: true)).should be_empty
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
        # The unsafe-method opt-in path must also run without raising (a POST manual scan).
        post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/x?q=1", method: "POST")
        a.run_active_now(post, allow_unsafe: true)
        sleep 50.milliseconds
        a.stop
      end
    end
  end
end

describe "Gori::Probe::Active::BackslashPowered" do
  probe = Gori::Probe::Active::BackslashPowered.new
  # A probe response with a given status + optional body (bodies drive error-signature classing).
  resp = ->(status : Int32, body : String) do
    head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "plans a GET query param into a baseline + a `\\` / `\\\\` follow-up pair" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["q"])
      plan.followups.size.should eq(3)
      String.new(plan.request).should contain("/s?q=hi ")         # baseline: value unchanged
      String.new(plan.followups[0]).should contain("/s?q=hi ")    # baseline again (stability check)
      String.new(plan.followups[1]).should contain("q=hi%5C ")    # single: value\
      String.new(plan.followups[2]).should contain("q=hi%5C%5C ") # double: value\\
    end
  end

  it "caps the probed params at MAX_PROBE_PARAMS (in query order)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&b=2&c=3&d=4")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["a", "b", "c"])
      plan.followups.size.should eq(7)                               # 2nd baseline + 2 per probed param
      String.new(plan.request).should contain("/s?a=1&b=2&c=3&d=4 ") # every param kept in the baseline
    end
  end

  it "does not plan a POST, a HEAD, or a paramless GET" do
    with_store do |store|
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "HEAD")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
    end
  end

  it "plans a POST query param under allow_unsafe, but never HEAD (no body to diff)" do
    with_store do |store|
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.plan(post, unsafe).not_nil!.params.map(&.name).should eq(["q"])
      probe.dedup_key(post, unsafe).should eq(probe.plan(post, unsafe).try(&.dedup_key))
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "HEAD"), unsafe).should be_nil
      # A paramless request still has nothing to inject even under the opt-in.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s", method: "POST"), unsafe).should be_nil
    end
  end

  it "raises the param cap under aggressive opts" do
    with_store do |store|
      wide = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?" + (0...6).map { |i| "p#{i}=v" }.join("&"))
      # Default: capped at MAX_PROBE_PARAMS (3).
      probe.plan(wide).not_nil!.params.size.should eq(Gori::Probe::Active::BackslashPowered::MAX_PROBE_PARAMS)
      # Aggressive: all 6 params probed (< MAX_PROBE_PARAMS_AGGRESSIVE).
      probe.plan(wide, Gori::Probe::Active::Options.new(aggressive: true)).not_nil!.params.size.should eq(6)
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?q=1", "/s?a=1&b=2&c=3&d=4", "/s?flag&x=9", "/s"].each do |t|
        detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end

  it "flags a param whose lone `\\` breaks but doubled `\\\\` does not" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      dets = probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), resp.call(500, ""), resp.call(200, "")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("backslash_powered")
      dets.first.category.should eq(Gori::Probe::Category::ACTIVE)
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      dets.first.evidence.not_nil!.should contain("q")
    end
  end

  it "fires on an interpreter error surfaced only by the lone backslash (status unchanged)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      results = [resp.call(200, "welcome"), resp.call(200, "welcome"),
                 resp.call(200, "You have an error in your SQL syntax"), resp.call(200, "welcome")]
      dets = probe.detections_all(plan, results, detail)
      dets.size.should eq(1)
      dets.first.evidence.not_nil!.downcase.should contain("sql")
    end
  end

  it "does not fire when BOTH `\\` and `\\\\` change the response (generic rejection, not escaping)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), resp.call(500, ""), resp.call(500, "")], detail).should be_empty
    end
  end

  it "does not fire when nothing changed" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), resp.call(200, ""), resp.call(200, "")], detail).should be_empty
    end
  end

  it "skips a param whose probe leg failed to send (incomplete comparison)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), errored, resp.call(200, "")], detail).should be_empty
    end
  end

  it "flags only the affected param when several are probed" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&b=2")
      plan = probe.plan(detail).not_nil!
      # baseline, baseline2, a\, a\\, b\, b\\  — only `a` shows the escape asymmetry
      results = [resp.call(200, ""), resp.call(200, ""),
                 resp.call(500, ""), resp.call(200, ""), resp.call(200, ""), resp.call(200, "")]
      dets = probe.detections_all(plan, results, detail)
      dets.size.should eq(1)
      ev = dets.first.evidence.not_nil!
      ev.should contain("a")
      ev.should_not contain("b")
    end
  end

  # The whole rule is a difference test against the baseline, which assumes the endpoint answers
  # the same request the same way twice. When it does not, an asymmetry carries no information.
  it "declines when the two baselines disagree (endpoint is not stable enough to diff)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # Exactly the asymmetry the rule reports — but the endpoint already contradicted itself
      # on two identical requests, so the `\` leg's 500 proves nothing.
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(503, ""), resp.call(500, ""), resp.call(200, "")], detail).should be_empty
      # An error signature that appears on only one baseline is the same problem.
      probe.detections_all(plan,
        [resp.call(200, "welcome"), resp.call(200, "You have an error in your SQL syntax"),
         resp.call(500, ""), resp.call(200, "welcome")], detail).should be_empty
    end
  end

  # The technique's central signal is a body that CHANGED, which a {status, error-class}
  # fingerprint alone could not see: same 200, no recognised error string, completely different
  # page read as "identical". Body length joins the fingerprint only when the two baselines
  # proved the endpoint reproduces its own length.
  it "fires on a body that changed shape with no status flip and no error string" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # Both baselines are byte-identical → length is trustworthy → the `\` leg's shorter body
      # is a real difference, and the `\\` leg reverting to baseline is the escape asymmetry.
      dets = probe.detections_all(plan,
        [resp.call(200, "the full rendered page"), resp.call(200, "the full rendered page"),
         resp.call(200, "oops"), resp.call(200, "the full rendered page")], detail)
      dets.size.should eq(1)
      dets.first.evidence.not_nil!.should contain("body")
    end
  end

  # …but a length-jittery endpoint must NOT get the sharper comparison, or every page with a
  # timestamp in it becomes a finding. It falls back to status + error-class, not to nothing.
  it "falls back to the status/error fingerprint when the baseline length is not reproducible" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # Baselines differ ONLY in length → length is dropped from the fingerprint → a `\` leg that
      # differs only in length is no longer a difference.
      probe.detections_all(plan,
        [resp.call(200, "rendered at 10:00:00"), resp.call(200, "rendered at 10:00:01x"),
         resp.call(200, "short"), resp.call(200, "rendered at 10:00:02")], detail).should be_empty
      # The status flip still fires on that same jittery endpoint — the check is not lost.
      probe.detections_all(plan,
        [resp.call(200, "rendered at 10:00:00"), resp.call(200, "rendered at 10:00:01x"),
         resp.call(500, "boom"), resp.call(200, "rendered at 10:00:02")], detail).size.should eq(1)
    end
  end

  it "declines when the second baseline is missing or failed to send" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan, [resp.call(200, "")], detail).should be_empty
      probe.detections_all(plan,
        [resp.call(200, ""), errored, resp.call(500, ""), resp.call(200, "")], detail).should be_empty
    end
  end
end

# JsScan lexes an all-ASCII script through a zero-allocation AsciiChars view and anything else
# through String#chars. The two must stay byte-identical — the fast path is an optimisation, not
# a behaviour change, and a silent divergence here is a missed finding, not a crash.
describe "Gori::Probe::Passive::JsScan (ASCII fast path)" do
  samples = [
    %(var a = "hello"; // comment here\nfoo.innerHTML = location.hash;),
    %(/* block\n comment */ eval("x" + location.search);),
    %(const t = `pre ${location.hash} post`; el.innerHTML = t;),
    %(s = 'it\\'s escaped'; u = "http://x/y//z"; document.write(u);),
    %(a = `outer ${ `inner ${x}` } end`;),
    %(o = {"__proto__": 1}; window.addEventListener("message", function(e){ el.innerHTML = e.data; });),
    %(x = 1 / 2; y = a // trailing\n + b;),
    %(`unterminated template),
    %("unterminated string),
    %(/* unterminated block),
  ]

  it "produces identical output on both paths" do
    samples.each do |src|
      src.ascii_only?.should be_true # these drive the fast path

      # Appending a non-ASCII char forces the chars path; compare the shared prefix.
      forced_strip = Gori::Probe::Passive::JsScan.strip(src + "é")
      forced_comments = Gori::Probe::Passive::JsScan.strip_comments(src + "é")

      Gori::Probe::Passive::JsScan.strip(src).should eq(forced_strip[0, src.size])
      Gori::Probe::Passive::JsScan.strip_comments(src).should eq(forced_comments[0, src.size])
    end
  end

  it "preserves char count on both paths" do
    (samples + ["日本語 = \"文字列\"; // コメント\nel.innerHTML = location.hash;"]).each do |src|
      Gori::Probe::Passive::JsScan.strip(src).size.should eq(src.size)
      Gori::Probe::Passive::JsScan.strip_comments(src).size.should eq(src.size)
    end
  end

  it "still correlates source to sink, and still ignores commented-out code" do
    code = Gori::Probe::Passive::JsScan.strip(
      "el.innerHTML = location.hash;\n// el.innerHTML = document.cookie;\n")
    Gori::Probe::Passive::JsScan.source_sink_pairs(code)
      .should eq([{"location.hash", "innerHTML"}])
  end
end

describe "Gori::Probe::Active.url_authority" do
  ua = ->(s : String) { Gori::Probe::Active.url_authority(s) }

  it "parses an absolute URL's host (and port), lower-cased" do
    ua.call("https://gori-redir-probe.example").should eq({"gori-redir-probe.example", nil})
    ua.call("https://gori-redir-probe.example/x?y=1").should eq({"gori-redir-probe.example", nil})
    ua.call("https://gori-redir-probe.example:8443/x").should eq({"gori-redir-probe.example", 8443})
    ua.call("http://HOST.TEST/").should eq({"host.test", nil})
    ua.call("//scheme-relative.test/x").should eq({"scheme-relative.test", nil})
    ua.call("http://[::1]:9000/").should eq({"::1", 9000})
  end

  it "returns the host AFTER userinfo (rejects the user@host redirect trick)" do
    ua.call("https://gori-redir-probe.example@evil.test/").should eq({"evil.test", nil})
    ua.call("https://gori-redir-probe.example:pass@evil.test:81/").should eq({"evil.test", 81})
  end

  it "is nil for a relative value — even one carrying :// inside the query" do
    ua.call("/go?next=https://evil.test").should be_nil
    ua.call("relative/path").should be_nil
    ua.call("/account").should be_nil
    ua.call("").should be_nil
  end
end

describe "Gori::Probe::Active::GraphqlIntrospection" do
  probe = Gori::Probe::Active::GraphqlIntrospection.new
  resp = ->(status : Int32, ct : String, body : String) do
    head = "HTTP/1.1 #{status} X\r\nContent-Type: #{ct}\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "re-POSTs a read-only introspection body when the captured flow was a GraphQL POST" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"query":"{me{id}}"}))
      plan = probe.plan(detail).not_nil!
      req = String.new(plan.request)
      req.should contain("POST /graphql ")
      req.should contain("Content-Type: application/json")
      req.should contain(%({"query":"{__schema{queryType{name}}}"}))
      req.should_not contain("{me{id}}") # NEVER replays the captured body
    end
  end

  it "strips Transfer-Encoding from a chunked source so the POST probe is well-framed" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "POST",
        req_headers: "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n", req_body: "1\r\nx\r\n0\r\n\r\n")
      req = String.new(probe.plan(detail).not_nil!.request)
      req.downcase.should_not contain("transfer-encoding")
      req.should contain("Content-Length:")
      req.should contain(%({"query":"{__schema{queryType{name}}}"}))
    end
  end

  it "sends a GET introspection query for a GET graphql endpoint" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql?x=1", method: "GET")
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain("GET /graphql?query=%7B__schema")
      req.should_not contain("x=1") # the original query is replaced, not appended
    end
  end

  it "detects introspection from the `\"__schema\":{` result envelope" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"query":"{me{id}}"}))
      plan = probe.plan(detail).not_nil!
      body = %({"data":{"__schema":{"queryType":{"name":"Query"}}}})
      dets = probe.detections(plan, resp.call(200, "application/json", body), detail)
      dets.size.should eq(1)
      dets.first.code.should eq("graphql_introspection")
      dets.first.category.should eq(Gori::Probe::Category::INFOLEAK)
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not fire on a disabled-introspection error, nor on a query echo" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql?x=1", method: "GET")
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, resp.call(200, "application/json",
        %({"errors":[{"message":"introspection is disabled"}]})), detail).should be_empty
      # A response that merely echoes the query has `__schema` UNQUOTED — the anchor rejects it.
      probe.detections(plan, resp.call(200, "application/json",
        %({"data":null,"query":"{ __schema { queryType { name } } }"})), detail).should be_empty
    end
  end

  it "plans nothing for a non-GraphQL flow" do
    with_store do |store|
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api/users")).should be_nil
      # A POST with a non-GraphQL JSON body (query is an object, not a string) is not GraphQL.
      es = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/search", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"query":{"match_all":{}}}))
      probe.plan(es).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      [{"/graphql", "GET"}, {"/graphql?x=1", "GET"}, {"/api/graphql", "POST"}, {"/graphql", "HEAD"},
       {"http://acme.test/graphql", "GET"}, {"/users", "GET"}].each do |(t, m)|
        detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, method: m)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      # GET and HEAD both probe with GET → the SAME dedup key (folded).
      g = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "GET")
      h = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "HEAD")
      probe.dedup_key(g).should eq(probe.dedup_key(h))
    end
  end
end

describe "Gori::Probe::Active::LfiParamTraversal" do
  probe = Gori::Probe::Active::LfiParamTraversal.new
  resp = ->(status : Int32, body : String) do
    head = "HTTP/1.1 #{status} X\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "plans a fold + encoded-fold + control for a path-like parameter" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "X")
      plan = probe.plan(detail).not_nil!
      plan.followups.size.should eq(2)
      String.new(plan.request).should contain("file=x/../doc.pdf")
      String.new(plan.followups[0]).should contain("file=x/%2e%2e/doc.pdf")
      String.new(plan.followups[1]).should contain("file=x/zzznope/doc.pdf")
    end
  end

  it "flags High when a folded `..` returns byte-identical content and the control differs" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      dets = probe.detections_all(plan, [resp.call(200, "PDFDATA"), resp.call(200, "PDFDATA"), resp.call(404, "nope")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("lfi_param_traversal")
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.evidence.not_nil!.should contain("file")
    end
  end

  it "fires on the encoded-fold variant when the literal fold is blocked" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, [resp.call(403, "blocked"), resp.call(200, "PDFDATA"), resp.call(404, "nope")], detail)
        .size.should eq(1)
    end
  end

  it "does not fire on a catch-all where the control also matches the baseline" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, [resp.call(200, "PDFDATA"), resp.call(200, "PDFDATA"), resp.call(200, "PDFDATA")], detail)
        .should be_empty
    end
  end

  it "does not fire when the folded value returns different content" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, [resp.call(200, "OTHER"), resp.call(200, "OTHER"), resp.call(404, "nope")], detail)
        .should be_empty
    end
  end

  it "gates on a path-like param, 2xx, a body, and a safe method" do
    with_store do |store|
      # Not path-like (no `/`, no extension, unknown name).
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", body: "X")).should be_nil
      # A known file-ish name qualifies even without an extension.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=secret", body: "X")).should_not be_nil
      # Captured non-2xx / no body / value already traversing / unsafe method → nil.
      probe.plan(capture_flow(store, "HTTP/1.1 404 NF\r\n\r\n", target: "/dl?file=doc.pdf", body: "X", status: 404)).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=../etc/passwd", body: "X")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "X", method: "POST")).should be_nil
    end
  end

  # The name list is checked REGARDLESS of the value, so an everyday application parameter in it
  # sent three probes at a large share of all traffic for nothing.
  it "does not treat ordinary application parameters as file parameters" do
    with_store do |store|
      ["/u?name=John", "/l?view=grid", "/l?page=2", "/l?load=more", "/go?url=alpha"].each do |t|
        probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, body: "X")).should be_nil, t
      end
      # A bare identifier under a real file param is an id, not a filename.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/d?doc=1234", body: "X")).should be_nil
      # …but a file-SHAPED value still qualifies under ANY name, so nothing is lost.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/l?page=home.html", body: "X")).should_not be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/go?url=a/b", body: "X")).should_not be_nil
    end
  end

  # `includes?(".js")` fired inside `.json`, and `.md` inside `.mdx`.
  it "requires a real extension boundary, not a substring of a longer one" do
    with_store do |store|
      # `data.jsonp` / `notes.mdx` are not the .js / .md files the old substring test saw — and
      # neither name is a file param, so nothing else qualifies them.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?q=data.jsonp", body: "X")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?q=notes.mdx", body: "X")).should be_nil
      # The real extensions still qualify.
      ["/a?q=app.js", "/a?q=data.json", "/a?q=notes.md"].each do |t|
        probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, body: "X")).should_not be_nil, t
      end
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/dl?file=doc.pdf", "/dl?file=secret", "/s?q=hi", "/dl?file=../x",
       "/p?page=home.html&x=1", "http://acme.test/dl?file=a.pdf"].each do |t|
        detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, body: "X")
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "X", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end
end

describe "Gori::Probe::Active::OpenRedirect" do
  probe = Gori::Probe::Active::OpenRedirect.new
  resp = ->(status : Int32, location : String) do
    head = location.empty? ? "HTTP/1.1 #{status} X\r\n\r\n" : "HTTP/1.1 #{status} X\r\nLocation: #{location}\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, Bytes.empty, nil, 1_i64)
  end

  it "plans a probe replacing the redirect-driving parameter with the probe host" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["next"])
      String.new(plan.request).should contain("next=https%3A%2F%2Fgori-redir-probe.example")
    end
  end

  it "mirrors the captured value's encoding (literal :// gets a literal probe URL)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https://acme.test/cb", status: 302)
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain("next=https://gori-redir-probe.example")
    end
  end

  it "flags High when the probe Location follows to the probe host" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      plan = probe.plan(detail).not_nil!
      dets = probe.detections(plan, resp.call(302, "https://gori-redir-probe.example/cb"), detail)
      dets.size.should eq(1)
      dets.first.code.should eq("open_redirect")
      dets.first.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "does not fire on a relative Location, the userinfo trick, or a non-redirect" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, resp.call(302, "/dashboard"), detail).should be_empty
      probe.detections(plan, resp.call(302, "https://gori-redir-probe.example@evil.test/"), detail).should be_empty
      probe.detections(plan, resp.call(200, ""), detail).should be_empty
    end
  end

  it "gates on a 3xx whose Location authority a parameter drives" do
    with_store do |store|
      # Captured 200 → not a redirect.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb")).should be_nil
      # Redirect to a relative Location → no absolute target for a param to drive.
      probe.plan(capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /home\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)).should be_nil
      # Redirect present but no parameter matches its authority.
      probe.plan(capture_flow(store, "HTTP/1.1 302 F\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?foo=bar", status: 302)).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/login?next=https%3A%2F%2Facme.test%2Fcb", "/go?u=https%3A%2F%2Facme.test%2Fx&t=1",
       "/login?foo=bar"].each do |t|
        detail = capture_flow(store, "HTTP/1.1 302 F\r\nLocation: https://acme.test/cb\r\n\r\n",
          target: t, status: 302)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      plain = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/login?next=https%3A%2F%2Facme.test%2Fcb")
      probe.dedup_key(plain).should be_nil
    end
  end

  it "surfaces through the full Active.analyze dispatch (plan → send → detections)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      backend = FixedBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443),
        "HTTP/1.1 302 Found\r\nLocation: https://gori-redir-probe.example/cb\r\n\r\n")
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, backend: backend).map(&.code).should contain("open_redirect")
    end
  end
end

describe "Gori::Probe::Active::HostHeaderInjection" do
  probe = Gori::Probe::Active::HostHeaderInjection.new
  body_resp = ->(body : String) do
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice, nil, 1_i64)
  end
  loc_resp = ->(location : String) do
    Gori::Repeater::Result.new("HTTP/1.1 302 F\r\nLocation: #{location}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
  end

  it "plans one authoritative X-Forwarded-Host, dropping any the browser sent" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n",
        target: "/page", req_headers: "X-Forwarded-Host: original.test\r\n")
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain("X-Forwarded-Host: gori-host-probe.example")
      req.should_not contain("original.test")
    end
  end

  it "flags Medium when the probe host is reflected as an absolute-URL authority" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n", target: "/page")
      plan = probe.plan(detail).not_nil!
      dets = probe.detections(plan, body_resp.call("<a href='https://gori-host-probe.example/reset?token=abc'>x</a>"), detail)
      dets.size.should eq(1)
      dets.first.code.should eq("host_header_injection")
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      probe.detections(plan, loc_resp.call("https://gori-host-probe.example/x"), detail).size.should eq(1)
    end
  end

  it "survives a Cache-Control max-age past Int32 (hand-rolled accumulator overflowed)" do
    # `positive_max_age?` accumulated digits into an Int32 with checked arithmetic, so a
    # 10-digit delta-seconds (here a 100-year max-age, which RFC 9111 §1.2.2 says to clamp)
    # raised OverflowError out of `gate`. Nothing rescues between there and the TUI event
    # loop, so the `A` keypress took the whole process down. No "public" token, so the
    # `||` cannot short-circuit before the accumulator runs.
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: max-age=3153600000\r\n\r\n", target: "/page")
      probe.plan(detail).should_not be_nil
    end
  end

  it "does not fire on a bare mention, a path segment, or a longer hostname" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public\r\n\r\n", target: "/page")
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, body_resp.call("see /gori-host-probe.example/ and gori-host-probe.example.evil.com"), detail)
        .should be_empty
    end
  end

  it "gates on a host-reflection-prone captured response" do
    with_store do |store|
      # Cacheable → prone.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n", target: "/p")).should_not be_nil
      # Self-referential (body reflects own Host as an authority) → prone.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/p", body: "<a href='https://acme.test/x'>x</a>")).should_not be_nil
      # Neither cacheable nor self-referential → nil.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\n\r\n", target: "/p", body: "no urls")).should be_nil
      # A cacheable NON-HTML asset (JS/CSS/image) is not a host-reflection surface → not probed.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n", target: "/app.js", content_type: "application/javascript")).should be_nil
      # A redirect that reflects its own Host is prone regardless of content type.
      probe.plan(capture_flow(store, "HTTP/1.1 302 F\r\nLocation: https://acme.test/next\r\n\r\n", target: "/r", status: 302, content_type: nil)).should_not be_nil
      # Unsafe method not probed by default.
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public\r\n\r\n", target: "/p", method: "POST")).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/page", "/a?x=1", "http://acme.test/b"].each do |t|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public\r\n\r\n", target: t)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key))
      end
      none = capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\n\r\n", target: "/p", body: "nope")
      probe.dedup_key(none).should be_nil
      probe.plan(none).should be_nil
    end
  end
end

describe "Gori::Probe::Active::CrlfInjection" do
  probe = Gori::Probe::Active::CrlfInjection.new

  it "injects an encoded CRLF + per-parameter canary into every query value" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi&r=yo")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["q", "r"])
      req = String.new(plan.request)
      req.should contain("q=hi%0d%0aGori-Probe:%20gq")
      req.should contain("r=yo%0d%0aGori-Probe:%20gq")
    end
  end

  it "flags only the parameter whose canary comes back as a real response header" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi&r=yo")
      plan = probe.plan(detail).not_nil!
      qc = plan.params.find { |p| p.name == "q" }.not_nil!.canary
      result = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nGori-Probe: #{qc}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      dets = probe.detections(plan, result, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("crlf_injection")
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.evidence.not_nil!.should eq("q")
    end
  end

  it "matches a canary reflected with a trailing suffix (mid-header reflection)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      qc = plan.params.first.canary
      # The param was reflected mid-header, so the split header carries the canary + a suffix.
      result = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nGori-Probe: #{qc}/dashboard\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, result, detail).size.should eq(1)
    end
  end

  it "does not fire on a missing or a static (non-canary) Gori-Probe header" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64), detail).should be_empty
      probe.detections(plan, Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nGori-Probe: 1\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64), detail).should be_empty
    end
  end

  it "gates on a safe method with at least one query parameter" do
    with_store do |store|
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?q=1", "/s?a=1&b=2", "/s?flag&x=9", "/s"].each do |t|
        detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end
end

describe "Gori::Probe::Active::PathNormalizationBypass" do
  probe = Gori::Probe::Active::PathNormalizationBypass.new
  resp = ->(status : Int32) { Gori::Repeater::Result.new("HTTP/1.1 #{status} X\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64) }

  it "plans a deterministic set of normalization variants that resolve to the original path" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      plan.params.size.should eq(5)
      plan.followups.size.should eq(5) # 4 remaining variants + the canonical-path control
      # The control is LAST and asks for the canonical path verbatim.
      String.new(plan.followups.last).should contain("GET /admin ")
      String.new(plan.request).should contain("/admin/..;/admin ")
      # None of the variants collapse to the bare `/admin/` (a known false-positive vector).
      plan.params.map(&.name).should_not contain("double-slash")
      req_all = ([plan.request] + plan.followups).map { |b| String.new(b) }.join
      req_all.should_not contain("/admin// ")
      req_all.should_not contain("/admin/. ")
    end
  end

  it "flags Medium and names the trick when a variant flips to 2xx" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      # Variant index 1 is `leading-dot-slash`; the last entry is the canonical-path control.
      results = [resp.call(403), resp.call(200), resp.call(403), resp.call(403), resp.call(403), resp.call(403)]
      dets = probe.detections_all(plan, results, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("path_normalization_bypass")
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      dets.first.evidence.not_nil!.should contain("leading-dot-slash")
      dets.first.evidence.not_nil!.should contain("canonical path still denied")
    end
  end

  # Without the control, a 403 that cleared on its own made EVERY variant look like a bypass.
  it "does not fire when the canonical path is served too (the gate simply opened)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      all_open = [resp.call(200), resp.call(200), resp.call(200), resp.call(200), resp.call(200), resp.call(200)]
      probe.detections_all(plan, all_open, detail).should be_empty
      # A missing or errored control is no attribution either.
      probe.detections_all(plan, [resp.call(403), resp.call(200), resp.call(403), resp.call(403), resp.call(403)],
        detail).should be_empty
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan, [resp.call(403), resp.call(200), resp.call(403), resp.call(403), resp.call(403), errored],
        detail).should be_empty
    end
  end

  it "does not fire when every variant stays denied, or a variant is 3xx" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, Array.new(6) { resp.call(403) }, detail).should be_empty
      redir = [resp.call(302), resp.call(403), resp.call(403), resp.call(403), resp.call(403), resp.call(403)]
      probe.detections_all(plan, redir, detail).should be_empty
    end
  end

  it "widens the variant set under aggressive opts (still <= 7), with a distinct dedup key" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      aggr = Gori::Probe::Active::Options.new(aggressive: true)
      probe.plan(detail, aggr).not_nil!.params.size.should eq(6)
      # The aggressive key must differ so an ACTIVE->AGGRESSIVE re-arm actually sends the extra variant.
      probe.dedup_key(detail, aggr).should_not eq(probe.dedup_key(detail))
    end
  end

  it "gates on a safe method, a 401/403 status, and a non-root, non-degenerate path" do
    with_store do |store|
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/", status: 403)).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403, method: "POST")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/a/../b", status: 403)).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 401 F\r\n\r\n", target: "/admin", status: 401)).should_not be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/admin", "/admin?x=1", "/a/b/c", "http://acme.test/admin"].each do |t|
        d = capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: t, status: 403)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key))
      end
      ok = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")
      probe.dedup_key(ok).should be_nil
      probe.plan(ok).should be_nil
    end
  end
end

describe "Gori::Probe::Active::Ssti" do
  probe = Gori::Probe::Active::Ssti.new
  resp = ->(body : String) { Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice, nil, 1_i64) }

  it "plans two canary-wrapped polyglot probes (49 and 56), URL-encoded" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["q"])
      plan.followups.size.should eq(1)
      req_a = String.new(plan.request)
      req_a.should contain(plan.params.first.canary)
      req_a.should_not contain("{{")                     # the markers are URL-encoded
      req_a.should_not eq(String.new(plan.followups[0])) # A (7*7) and B (7*8) differ
    end
  end

  it "flags High only when BOTH products evaluate inside the parameter's canary region" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      c = plan.params.first.canary
      dets = probe.detections_all(plan, [resp.call("x#{c}49#{c}y"), resp.call("x#{c}56#{c}y")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("ssti")
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.evidence.not_nil!.should eq("q")
    end
  end

  it "does not fire on verbatim reflection, a single product, or a stray number outside the region" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      c = plan.params.first.canary
      # Verbatim echo: the region carries the literal markers, never the products.
      probe.detections_all(plan, [resp.call("#{c}{{7*7}}#{c}"), resp.call("#{c}{{7*8}}#{c}")], detail).should be_empty
      # Only 49 evaluated (B lacks 56) → not confirmed.
      probe.detections_all(plan, [resp.call("#{c}49#{c}"), resp.call("#{c}{{7*8}}#{c}")], detail).should be_empty
      # 49/56 present only OUTSIDE the canary region → ignored.
      probe.detections_all(plan, [resp.call("49 56 #{c}safe#{c} 49"), resp.call("49 56 #{c}safe#{c} 56")], detail).should be_empty
    end
  end

  it "gates on a body-comparable method with query params (POST only under allow_unsafe)" do
    with_store do |store|
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "HEAD")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")).should be_nil
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST"), unsafe).should_not be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?q=1", "/s?a=1&b=2", "/s?flag&x=9", "/s"].each do |t|
        detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end
end

describe "Gori::Probe::Active::UrlRewriteBypass" do
  probe = Gori::Probe::Active::UrlRewriteBypass.new
  resp = ->(status : Int32, body : String) do
    Gori::Repeater::Result.new("HTTP/1.1 #{status} X\r\n\r\n".to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "plans a `GET /` probe (with rewrite headers) plus a clean control" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      req = String.new(plan.request)
      req.should contain("GET / ")
      req.should contain("X-Original-URL: /admin")
      req.should contain("X-Rewrite-URL: /admin")
      plan.followups.size.should eq(2) # control + a second control (root-stability check)
      plan.followups.each { |f| String.new(f).should_not contain("X-Original-URL") }
      String.new(plan.followups[0]).should eq(String.new(plan.followups[1]))
    end
  end

  it "flags Medium when the probe serves different content than the root control" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      dets = probe.detections_all(plan,
        [resp.call(200, "ADMINPAGE"), resp.call(404, "nf"), resp.call(404, "nf")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("url_rewrite_bypass")
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  # The finding rests entirely on "probe differs from root". A root whose body length moves
  # between requests (a varying CSRF token, a timestamp) made EVERY 401/403/404 path differ.
  it "declines when the two root controls disagree (root is not stable enough to diff)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      # Same status, body length jitters by one byte between the two identical root requests.
      probe.detections_all(plan,
        [resp.call(200, "ADMINPAGE"), resp.call(200, "HOME"), resp.call(200, "HOME2")], detail).should be_empty
      # A status that flaps is the same problem.
      probe.detections_all(plan,
        [resp.call(200, "ADMINPAGE"), resp.call(200, "HOME"), resp.call(503, "HOME")], detail).should be_empty
      # A missing or errored second control means the stability question was never answered.
      probe.detections_all(plan, [resp.call(200, "ADMINPAGE"), resp.call(404, "nf")], detail).should be_empty
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan,
        [resp.call(200, "ADMINPAGE"), resp.call(404, "nf"), errored], detail).should be_empty
    end
  end

  it "does not fire when the header is ignored (probe == root) or stays denied" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan,
        [resp.call(200, "HOME"), resp.call(200, "HOME"), resp.call(200, "HOME")], detail).should be_empty
      probe.detections_all(plan,
        [resp.call(403, "denied"), resp.call(200, "HOME"), resp.call(200, "HOME")], detail).should be_empty
    end
  end

  it "gates on a body-comparable method and a 401/403/404 non-root path" do
    with_store do |store|
      probe.plan(capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/", status: 403)).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403, method: "HEAD")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403, method: "POST")).should be_nil
      probe.plan(capture_flow(store, "HTTP/1.1 404 NF\r\n\r\n", target: "/secret", status: 404)).should_not be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/admin", "/admin?x=1", "/a/b", "http://acme.test/admin"].each do |t|
        d = capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: t, status: 403)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key))
      end
      ok = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")
      probe.dedup_key(ok).should be_nil
      probe.plan(ok).should be_nil
    end
  end
end

# The headless scan orchestrator (`gori run probe` + MCP probe_scan) must honour the SAME
# Rules sub-tab config the TUI Analyzer does — disabled built-ins stay off, custom rules run.
# Before this, Scan called Passive.analyze/Active.analyze with neither, so a headless scan
# silently re-reported rules the operator had turned off and never ran a custom rule at all.
describe "Gori::Probe::Scan rules config parity" do
  it "honours the operator's disabled built-ins in a headless passive scan" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      ids = Gori::Probe::Scan.flow_ids(store, nil)

      before = Gori::Probe::Scan.scan_flows(store, ids, active: false)
      before.count { |d| d.code == "secret_in_url" }.should eq(1)

      store.set_probe_disabled_rules(Set{"secret_in_url"})
      after = Gori::Probe::Scan.scan_flows(store, ids, active: false)
      after.count { |d| d.code == "secret_in_url" }.should eq(0)
    end
  end

  # `probe_disabled_rules` stores the operator's DEVIATION FROM DEFAULT, so membership FLIPS
  # meaning for `DEFAULT_DISABLED_RULES` ids — which is why `Probe.rule_disabled?` exists and why
  # issue.cr claims the flip lives in exactly ONE place. `Passive.analyze` and `analyze_ws` had
  # drifted to a bare `disabled.includes?`. It was inert only because every default-OFF id today is
  # an ACTIVE rule, so no passive rule ever reached the branch where the two disagree; the first
  # default-OFF passive rule would have shipped silently dead for the operator who enabled it.
  #
  # No behavioural spec can pin this while `DEFAULT_DISABLED_RULES` has no passive member, so the
  # pin is structural — the same shape as spec/tui/color_semantics_spec.cr, which re-derives a rule
  # by grepping source rather than by exercising a case that does not exist yet.
  it "gates every probe rule through Probe.rule_disabled?, never a bare set lookup" do
    root = File.join(__DIR__, "..", "src", "gori", "probe")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next if line.lstrip.starts_with?('#') # a comment may name the old shape; code may not
        next unless line.matches?(/\bdisabled\.includes\?\(/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "runs the operator's custom match rules in a headless passive scan" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a",
        content_type: "text/html", body: "leak sk_live_abc")
      ids = Gori::Probe::Scan.flow_ids(store, nil)

      Gori::Probe::Scan.scan_flows(store, ids, active: false)
        .any?(&.title.includes?("stripe key")).should be_false

      store.insert_probe_custom_rule("stripe key", "d", "response", "body", "regex",
        "sk_live_[a-z]+", Gori::Store::Severity::High)
      dets = Gori::Probe::Scan.scan_flows(store, ids, active: false)
      hit = dets.find(&.title.includes?("stripe key")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "honours disabled built-ins for ACTIVE rules too (no probe is even planned)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)

      baseline = CountingBackend.new(origin)
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, backend: baseline)
      baseline.sent.should be > 0

      # Disabling every active rule must stop the sends at the source, not just drop findings.
      all_ids = Gori::Probe::Active::RULES.map(&.info.id).to_set
      muted = CountingBackend.new(origin)
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, backend: muted, disabled: all_ids)
      muted.sent.should eq(0)
    end
  end

  it "scans Repeater tabs under the same rules config as History flows" do
    with_store do |store|
      capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      ids = Gori::Probe::Scan.flow_ids(store, nil)
      store.set_probe_disabled_rules(Set{"secret_in_url"})

      dets, _ = Gori::Probe::Scan.scan_all(store, ids, active: false)
      dets.count { |d| d.code == "secret_in_url" }.should eq(0)
    end
  end
end

# Probe::Triage is the ONE promotion/dismiss implementation the TUI, `gori run probe`, and the
# MCP probe_* tools all call — so a finding triaged from any surface lands in the same state.
describe "Gori::Probe::Triage" do
  it "promotes once, marking the source Confirmed so a repeat cannot duplicate" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "secret_in_url", category: "infoleak", host: "acme.test", title: "token in URL",
        severity: Gori::Store::Severity::High, url: "https://acme.test/x", evidence: "tok"))
      issue = store.probe_issues.first

      res = Gori::Probe::Triage.promote(store, issue)
      res.promoted?.should be_true
      created = store.get_issue(res.issue_id.not_nil!).not_nil!
      created.title.should eq(issue.title)
      created.severity.should eq(Gori::Store::Severity::High)
      store.get_probe_issue(issue.id).not_nil!.status.confirmed?.should be_true

      # Re-read (the in-memory `issue` still holds the pre-promotion status). A second call
      # reports AlreadyPromoted — distinct from Failed, which means nothing was written and
      # a retry IS correct.
      again = store.get_probe_issue(issue.id).not_nil!
      second = Gori::Probe::Triage.promote(store, again)
      second.promoted?.should be_false
      second.outcome.already_promoted?.should be_true
      second.issue_id.should be_nil
      store.issues.size.should eq(1)
    end
  end

  it "dismisses only an OPEN finding and re-opens anything else" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "secret_in_url", category: "infoleak", host: "acme.test", title: "t",
        severity: Gori::Store::Severity::High, url: "https://acme.test/x"))
      issue = store.probe_issues.first

      Gori::Probe::Triage.toggle_dismiss(store, issue).false_positive?.should be_true
      Gori::Probe::Triage.toggle_dismiss(store, store.get_probe_issue(issue.id).not_nil!).open?.should be_true

      # A Confirmed (promoted) finding re-opens rather than being dismissed — the asymmetry
      # the TUI's `c` has always had, now shared.
      store.update_probe_issue_status(issue.id, Gori::Store::Status::Confirmed)
      Gori::Probe::Triage.toggle_dismiss(store, store.get_probe_issue(issue.id).not_nil!).open?.should be_true
    end
  end
end

# The in-memory fold (`gori run probe`, MCP probe_scan) and the SQL upsert (TUI/capture) must
# agree on which codes accumulate their evidence. They did not: Group kept its own three-code
# copy of the list while Store's had grown to five, so a headless scan reported ONE of a host's
# third-party hosts and dropped the rest. Both now read Store::ACCUMULATING_EVIDENCE_CODES.
describe "Store#upsert_probe_issues (batched ↔ sequential parity)" do
  # `upsert_probe_issues` exists to collapse N writer round-trips into one, so its whole licence
  # is that it replays the SAME statements in the SAME order — no folding. That is only worth
  # anything if it is checked against the sequential path it replaced, on the cases where a fold
  # WOULD have diverged: composition onto a row that already exists (the Group parity specs below
  # only cover an empty store), an accumulating-evidence code, a severity raise that drags the
  # title with it, affected-URL dedup, and a suppression landing mid-batch.
  det = ->(code : String, host : String, url : String, sev : Gori::Store::Severity, title : String, evidence : String?) do
    Gori::Probe::Detection.new(code, "headers", host, url, title, sev, evidence)
  end

  # Everything but the id and the timestamps: the batch shares one now_us by design, and two
  # stores are opened microseconds apart, so times cannot be compared across the two runs.
  shape = ->(i : Gori::Store::ProbeIssue) do
    {i.code, i.category, i.host, i.title, i.severity, i.status,
     i.hit_count, i.affected, i.evidence, i.sample_flow_id}
  end

  run_both = ->(seed : Array(Gori::Probe::Detection), batch : Array(Gori::Probe::Detection), suppress : Array({String, String})) do
    out = [] of Array({String, String, String, String, Gori::Store::Severity, Gori::Store::Status, Int64, Array(String), String?, Int64?})
    2.times do |mode|
      with_store do |store|
        seed.each { |d| store.upsert_probe_issue(d) } # the pre-existing rows, same either way
        # A durable suppression is only ever created by a hard delete, so make one the real way.
        suppress.each do |(code, host)|
          store.upsert_probe_issue(det.call(code, host, "https://#{host}/seed",
            Gori::Store::Severity::Low, "t", nil))
          row = store.probe_issues.find { |i| i.code == code && i.host == host }.not_nil!
          store.delete_probe_issue(row.id)
        end
        if mode == 0
          batch.each { |d| store.upsert_probe_issue(d) } # sequential: one commit per detection
        else
          store.upsert_probe_issues(batch) # batched: one commit for all of them
        end
        out << store.probe_issues.map { |i| shape.call(i) }
      end
    end
    out
  end

  it "writes the same rows as the per-detection loop it replaced" do
    seed = [
      det.call("missing_sri", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "SRI", "cdn.a.test"),
      det.call("weak_csp", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "CSP", "first"),
    ]
    batch = [
      # accumulating code, new label → evidence must UNION, not overwrite and not concatenate blobs
      det.call("missing_sri", "acme.test", "https://acme.test/b", Gori::Store::Severity::Low, "SRI", "cdn.b.test"),
      # …and a third, so the batch composes onto its own earlier write, not just onto the seed
      det.call("missing_sri", "acme.test", "https://acme.test/c", Gori::Store::Severity::Low, "SRI", "cdn.c.test"),
      # same affected URL again → must dedup, hit_count still climbs
      det.call("missing_sri", "acme.test", "https://acme.test/b", Gori::Store::Severity::Low, "SRI", "cdn.b.test"),
      # non-accumulating code → first-wins evidence survives
      det.call("weak_csp", "acme.test", "https://acme.test/b", Gori::Store::Severity::Low, "CSP", "second"),
      # severity raise → title must be adopted with it
      det.call("weak_csp", "acme.test", "https://acme.test/c", Gori::Store::Severity::High, "CSP (worse)", "third"),
      # a brand-new (code, host) inside the batch → INSERT branch
      det.call("cors_wildcard", "other.test", "https://other.test/x", Gori::Store::Severity::Medium, "CORS", nil),
    ]
    seq, bat = run_both.call(seed, batch, [] of {String, String})
    bat.should eq(seq)
    # and the fold actually happened, so the comparison above is not two empty lists
    sri = bat.find { |r| r[0] == "missing_sri" }.not_nil!
    sri[8].not_nil!.should contain("cdn.c.test")
  end

  it "honours a suppression that lands mid-batch exactly as the sequential path did" do
    seed = [] of Gori::Probe::Detection
    batch = [
      det.call("missing_sri", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "SRI", "cdn.a.test"),
      det.call("weak_csp", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "CSP", "first"),
    ]
    seq, bat = run_both.call(seed, batch, [{"weak_csp", "acme.test"}])
    bat.should eq(seq)
    bat.map(&.[](0)).should eq(["missing_sri"]) # the suppressed code never lands
  end
end

describe "Gori::Probe evidence accumulation (Group ↔ Store parity)" do
  # Build N detections of one code on one host, each carrying a different evidence label.
  private_labels = ->(code : String, labels : Array(String)) do
    labels.map_with_index do |label, i|
      Gori::Probe::Detection.new(code, "headers", "acme.test", "https://acme.test/#{i}",
        "t", Gori::Store::Severity::Low, label)
    end
  end

  it "accumulates missing_sri third-party hosts in a headless fold, not just the first" do
    dets = private_labels.call("missing_sri", ["cdn.a.test", "cdn.b.test", "cdn.c.test"])
    g = Gori::Probe.group(dets)
    g.size.should eq(1)
    ev = g.first.evidence.not_nil!
    ev.should contain("cdn.a.test")
    ev.should contain("cdn.b.test")
    ev.should contain("cdn.c.test")
  end

  it "accumulates cookie names so a host with several unflagged cookies names them all" do
    dets = private_labels.call("cookie_no_httponly", ["sid", "csrf", "pref"])
    ev = Gori::Probe.group(dets).first.evidence.not_nil!
    %w[sid csrf pref].each { |n| ev.should contain(n) }
  end

  it "folds evidence identically in memory and in the DB" do
    with_store do |store|
      dets = private_labels.call("missing_sri", ["cdn.a.test", "cdn.b.test"])
      dets.each { |d| store.upsert_probe_issue(d) }
      stored = store.probe_issues.find(&.code.==("missing_sri")).not_nil!
      stored.evidence.should eq(Gori::Probe.group(dets).first.evidence)
    end
  end

  it "keeps a first-wins sample for a code that is NOT in the accumulating set" do
    dets = private_labels.call("weak_csp", ["first", "second"])
    ev = Gori::Probe.group(dets).first.evidence.not_nil!
    ev.should eq("first")
  end

  # merge_evidence dedups by splitting the stored string on ", ", so a per-cookie requirement
  # list joined the same way would be torn into fragments that read as other cookies' evidence.
  it "joins one cookie's unmet prefix requirements with ' + ' so the merge cannot split them" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Set-Cookie: __Host-sid=a; Domain=acme.test\r\n\r\n"
      hit = analyze(store, resp_head: head).find(&.code.==("cookie_prefix_violation")).not_nil!
      ev = hit.evidence.not_nil!
      ev.should contain("Secure + Path=/ + no Domain")
      # Two violating cookies on one host merge into two whole labels, not five fragments.
      other = Gori::Probe::Detection.new("cookie_prefix_violation", "cookies", "acme.test",
        "https://acme.test/2", "t", Gori::Store::Severity::Medium, "__Secure-tok: needs Secure")
      merged = Gori::Probe.group([hit, other]).first.evidence.not_nil!
      merged.split(", ").size.should eq(2)
    end
  end
end

# The tag-shaped HTML sink checks share their subject with Sri — the tags of one document — so
# they must share its reach. They used to read the 64 KiB body_text while Sri read the 256 KiB
# client_body_text, which on a large page reported the unhashed third-party script and stayed
# silent about the cleartext one beside it.
describe "Gori::Probe::Passive::BodyLeaks (HTML sinks reach the client body cap)" do
  # An HTML document whose interesting tag sits PAST the 64 KiB body_text prefix but inside
  # the 256 KiB client_body_text one.
  padded = ->(tag : String) do
    String.build do |io|
      io << "<html><body>"
      io << ("<p>filler filler filler</p>" * 4000) # ~104 KiB, past BODY_CAP
      io << tag << "</body></html>"
    end
  end

  it "finds active mixed content past the 64 KiB prefix" do
    with_store do |store|
      body = padded.call(%(<script src="http://cdn.acme.test/a.js"></script>))
      body.bytesize.should be > Gori::Probe::Passive::Context::BODY_CAP
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: body)).should contain("mixed_content")
    end
  end

  it "finds an insecure form action past the 64 KiB prefix" do
    with_store do |store|
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: padded.call(%(<form action="http://acme.test/login">)))).should contain("insecure_form_action")
    end
  end

  # The prefilters are ASCII case-INSENSITIVE byte scans; a case-sensitive includes? would have
  # silently stopped matching the uppercase markup the /i regexes were written to catch.
  it "still matches uppercase markup through the literal prefilters" do
    with_store do |store|
      found = codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<A TARGET="_BLANK" HREF="/x">x</A><IMG SRC="HTTP://acme.test/i.png">)))
      found.should contain("reverse_tabnabbing")
      found.should contain("mixed_passive")
    end
  end
end

describe "Gori::Probe.cwe" do
  # A CWE key that no rule emits is dead metadata nobody would ever notice — a typo'd code
  # ("secret_in_urls") maps forever and shows up nowhere. REMEDIATION is the de-facto registry
  # of emitted codes, so every CWE key must appear there.
  it "maps only codes that findings actually carry" do
    stray = Gori::Probe::CWE.keys.reject { |c| Gori::Probe::REMEDIATION.has_key?(c) }
    stray.should be_empty
  end

  # The inverse: a documented code with no CWE must be one of the deliberate exclusions, so a
  # newly added rule cannot quietly ship unclassified. Update this list ONLY with the reason.
  it "leaves exactly the deliberately unmapped codes without a CWE" do
    unmapped = Gori::Probe::REMEDIATION.keys.reject { |c| Gori::Probe::CWE.has_key?(c) }
    # jwt_in_body/jwt_in_ws are Info notes on where tokens flow — handing the client its own
    # token is the design, not a weakness (see Passive::Secrets::JWT).
    unmapped.sort.should eq(["jwt_in_body", "jwt_in_ws"])
  end

  it "renders the canonical CWE-<id> identifier and name" do
    Gori::Probe.cwe_id("dom_xss").should eq("CWE-79")
    Gori::Probe.cwe_name("cookie_no_httponly").should eq("Sensitive Cookie Without 'HttpOnly' Flag")
    Gori::Probe.cwe_id("tech_server").should be_nil
    Gori::Probe.cwe_id("custom_p_1").should be_nil
  end

  it "emits cwe fields in the shared JSON shape, and omits them when unmapped" do
    mapped = Gori::Probe::Detection.new("dom_xss", "client", "acme.test", "https://acme.test/",
      "t", Gori::Store::Severity::Medium)
    json = Gori::CLI::Output.probe_group_json(Gori::Probe.group([mapped]).first)
    JSON.parse(json)["cwe"].as_s.should eq("CWE-79")
    JSON.parse(json)["cwe_name"].as_s.should contain("Cross-site Scripting")

    tech = Gori::Probe::Detection.new("tech_server", "tech", "acme.test", "https://acme.test/",
      "t", Gori::Store::Severity::Info)
    parsed = JSON.parse(Gori::CLI::Output.probe_group_json(Gori::Probe.group([tech]).first))
    parsed.as_h.has_key?("cwe").should be_false
    parsed.as_h.has_key?("cwe_name").should be_false
  end
end

describe "Gori::Probe::Passive::Secrets (provider shapes)" do
  private_hit = ->(s : String) do
    Gori::Probe::Passive::Secrets::PATTERNS.select { |(re, _)| re.matches?(s) }.map { |(_, l)| l }
  end

  it "matches the added provider key shapes" do
    private_hit.call("sk-ant-api03-#{"a" * 95}").should contain("Anthropic API key")
    private_hit.call("sk-proj-#{"B" * 60}").should contain("OpenAI project key")
    private_hit.call("xapp-1-A01BCDEFG-1234567890123-#{"0123456789abcdef" * 4}").should contain("Slack app-level token")
    private_hit.call("shpat_#{"0" * 32}").should contain("Shopify access token")
    private_hit.call("123456789:AA#{"F" * 33}").should contain("Telegram bot token")
    private_hit.call("AccountKey=#{"A" * 86}==").should contain("Azure Storage account key")
  end

  it "flags a database URI carrying real inline credentials" do
    private_hit.call("mongodb+srv://root:S3cretPassw0rd@cluster0.abcd.mongodb.net")
      .should contain("database URI with inline credentials")
  end

  # The docs/tutorial shape is what a naive scheme://user:pass@host pattern would drown in:
  # a placeholder password, a loopback host, or a reserved example domain.
  it "does not flag a documentation-style connection string" do
    ["postgres://user:pass@localhost:5432/dev",
     "postgres://user:password@db.example.com/app",
     "redis://admin:changeme@127.0.0.1:6379",
     "our keys start with sk-ant- as a prefix"].each do |s|
      private_hit.call(s).should be_empty
    end
  end

  it "reaches the response body through BodyLeaks" do
    with_store do |store|
      body = %({"db":"postgres://svc:Hunter2Hunter2@db.internal.acme:5432/main"})
      codes_of(analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: body)).should contain("secret_in_body")
    end
  end
end

describe "Gori::Probe::Passive::JsScan (navigation + parsing sinks)" do
  private_pairs = ->(src : String) do
    Gori::Probe::Passive::JsScan.source_sink_pairs(Gori::Probe::Passive::JsScan.strip(src))
  end

  # The window is searched as the two sides AROUND the sink, never across the sink's own text.
  # Without that, `location.href =` (a sink) pairs with `location.href` (a source) matched in
  # those very bytes, and every ordinary SPA redirect reports a DOM-XSS lead against itself.
  it "does not pair a navigation sink with its own text" do
    private_pairs.call(%(location.href = "/dashboard";)).should be_empty
    private_pairs.call(%(window.location = "/login";)).should be_empty
    private_pairs.call(%(if (location.href === x) { go(); })).should be_empty
  end

  it "pairs a navigation sink with a real taint source" do
    private_pairs.call(%(location.href = document.referrer;)).should_not be_empty
    private_pairs.call(%(location.replace(location.hash.slice(1));)).should_not be_empty
    private_pairs.call(%(window.open(location.search, "_blank");)).should_not be_empty
    private_pairs.call(%(window.open("/help", "_blank");)).should be_empty
  end

  it "pairs the HTML-parsing sinks" do
    private_pairs.call(%(el.appendChild(r.createContextualFragment(location.hash));)).should_not be_empty
    private_pairs.call(%(new DOMParser().parseFromString(document.URL, "text/html");)).should_not be_empty
  end

  # The split must not regress the sinks that predate it, including the one whose source sits
  # INSIDE the sink's arguments (that source is on the POST side, which is still searched).
  it "keeps the pre-existing pairs" do
    private_pairs.call(%(o.innerHTML = location.hash;)).should_not be_empty
    private_pairs.call(%(document.write(document.URL);)).should_not be_empty
    private_pairs.call(%(o.innerHTML = "<b>static</b>";)).should be_empty
  end
end

describe Gori::Probe::Passive::ExposedConfig do
  private_plain = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
  private_html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"

  it "flags a served .git/config" do
    with_store do |store|
      body = "[core]\n\trepositoryformatversion = 0\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n"
      dets = analyze(store, resp_head: private_plain, content_type: "text/plain", body: body)
      hit = dets.find(&.code.==("exposed_config")).not_nil!
      hit.evidence.should eq(".git/config")
      hit.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "flags a served .env but not an HTML page documenting the same keys" do
    with_store do |store|
      env = "APP_ENV=production\nDB_PASSWORD=s3cr3t-value\nMAIL_PASSWORD=hunter2\n"
      codes_of(analyze(store, resp_head: private_plain, content_type: "text/plain", body: env))
        .should contain("exposed_config")
      # The same key names inside a deployment guide are documentation, not the file.
      doc = "<html><body><pre>DB_PASSWORD=your-password-here</pre><p>Set these in .env</p></body></html>"
      codes_of(analyze(store, resp_head: private_html, content_type: "text/html", body: doc))
        .should_not contain("exposed_config")
    end
  end

  it "flags phpinfo(), .htpasswd, wp-config credentials, and actuator env" do
    with_store do |store|
      [
        {"<html><head><title>phpinfo()</title></head><body>PHP Version 8.2.1</body></html>", "text/html", "phpinfo() output"},
        {"admin:$apr1$abcd1234$0123456789abcdefghijkl\n", "text/plain", ".htpasswd credentials"},
        {"<?php define('DB_PASSWORD', 'p4ssw0rd'); ?>", "text/plain", "wp-config.php credentials"},
        {"{\"activeProfiles\":[\"prod\"],\"propertySources\":[{\"name\":\"systemEnvironment\"}]}",
         "application/json", "Spring actuator env"},
      ].each do |(body, ct, label)|
        head = "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n\r\n"
        hit = analyze(store, resp_head: head, content_type: ct, body: body).find(&.code.==("exposed_config"))
        hit.not_nil!.evidence.should eq(label)
      end
    end
  end

  # The FP that actually matters: a page that TALKS ABOUT the artifact. Each signature is
  # anchored on the artifact's own structure, so prose naming it must not match.
  it "does not flag documentation that merely names these artifacts" do
    with_store do |store|
      [
        "Run phpinfo() to inspect your build; see the phpinfo() docs for details.",
        "Edit the [core] section of your repository configuration to set autocrlf.",
        "Generate a .htpasswd with htpasswd -c, then point AuthUserFile at it.",
        "The propertySources concept in Spring lets you layer configuration.",
      ].each do |prose|
        codes_of(analyze(store, resp_head: private_html, content_type: "text/html", body: prose))
          .should_not contain("exposed_config")
      end
    end
  end

  it "ignores a non-2xx page that echoes the requested path" do
    with_store do |store|
      body = "[core]\n\trepositoryformatversion = 0\n"
      codes_of(analyze(store, resp_head: "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\n",
        content_type: "text/plain", body: body, status: 404)).should_not contain("exposed_config")
    end
  end

  it "accumulates every artifact a host serves rather than pinning to the first" do
    with_store do |store|
      git = analyze(store, resp_head: private_plain, content_type: "text/plain",
        target: "/.git/config", body: "[core]\n\trepositoryformatversion = 0\n")
      env = analyze(store, resp_head: private_plain, content_type: "text/plain",
        target: "/.env", body: "DB_PASSWORD=s3cr3t-value\n")
      (git + env).each { |d| store.upsert_probe_issue(d) }
      ev = store.probe_issues.find(&.code.==("exposed_config")).not_nil!.evidence.not_nil!
      ev.should contain(".git/config")
      ev.should contain(".env file")
    end
  end
end
