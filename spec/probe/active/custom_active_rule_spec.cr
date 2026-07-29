require "../../spec_helper"

# --- file-local harness ----------------------------------------------------------------------

private def with_store(&)
  path = File.tempname("gori-customactive", ".db")
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

private def capture_flow(store, *, target = "/s?q=hi", method = "GET", status = 200,
                         req_headers = "", req_body : String? = nil,
                         host = "acme.test") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: req_body.try(&.to_slice))
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice, body: nil,
    reason: "OK", content_type: nil, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# A backend that reflects the DIFFERENTIAL: a request carrying `needle` gets a response body
# containing `marker`, everything else gets a clean body. Keyed on the request content rather than
# on send order, so the built-in rules (which run first and send their own probes) can't consume
# the responses meant for the custom rule's probe/control pair.
private class DifferentialBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin
  getter sent = 0

  def initialize(@origin : Gori::Fuzz::Origin, @needle : String, @marker : String)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    body = String.new(bytes).includes?(@needle) ? @marker : "clean"
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice, nil, 1_i64)
  end
end

private def rule(*, inject = "query", header_name = "", payload = "PAYLOAD",
                 match_kind = "string", match_pattern = "MATCH", match_region = "body",
                 severity = Gori::Store::Severity::High, scope = "project",
                 enabled = true, id = "1", title = "my rule",
                 description = "") : Gori::Probe::Active::CustomActiveRule
  Gori::Probe::Active::CustomActiveRule.new(id, title, description, inject, header_name, payload,
    match_kind, match_pattern, match_region, severity, scope, enabled)
end

private def probe_and_control(r : Gori::Probe::Active::CustomActiveRule, detail,
                              opts = Gori::Probe::Active::Options::DEFAULT)
  r.to_rule.plan(detail, opts).not_nil!
end

describe Gori::Probe::Active::CustomActiveRule do
  describe ".valid?" do
    it "accepts a well-formed string and regex rule" do
      rule.valid?.should be_true
      rule(match_kind: "regex", match_pattern: "root:.:0:").valid?.should be_true
    end

    it "accepts every supported inject target" do
      %w[query header body cookie path].each do |loc|
        hn = loc == "header" ? "X-H" : ""
        rule(inject: loc, header_name: hn).valid?.should be_true, loc
      end
    end

    it "rejects an unknown inject target, an empty payload, and an empty pattern" do
      rule(inject: "referer").valid?.should be_false
      rule(payload: "").valid?.should be_false
      rule(match_pattern: "").valid?.should be_false
    end

    it "rejects a header rule with no header name, and an uncompilable regex" do
      rule(inject: "header", header_name: "  ").valid?.should be_false
      rule(match_kind: "regex", match_pattern: "(unclosed").valid?.should be_false
    end
  end

  describe "#code" do
    it "namespaces by scope so a global and a project rule with the same id never collide" do
      rule(scope: "project", id: "7").code.should eq("customactive_p_7")
      rule(scope: "global", id: "7").code.should eq("customactive_g_7")
    end
  end

  describe "the probe/control plan" do
    it "injects the payload into every query value and leaves the control unchanged" do
      with_store do |store|
        detail = capture_flow(store, target: "/s?a=1&b=2")
        plan = probe_and_control(rule(inject: "query", payload: "X'\"<>"), detail)
        probe = String.new(plan.request)
        probe.should contain("a=1X%27%22%3C%3E") # payload URL-encoded, appended to the value
        probe.should contain("b=2X%27%22%3C%3E")
        plan.followups.size.should eq(1)
        control = String.new(plan.followups.first)
        control.should contain("/s?a=1&b=2 ") # verbatim query, origin-form request line
        control.should_not contain("X%27")
      end
    end

    it "sets the named header on the probe and drops any the browser sent" do
      with_store do |store|
        detail = capture_flow(store, req_headers: "X-Test: browser\r\n")
        plan = probe_and_control(rule(inject: "header", header_name: "X-Test", payload: "forged"), detail)
        probe = String.new(plan.request)
        probe.scan("X-Test: forged").size.should eq(1)
        probe.should_not contain("X-Test: browser")
        String.new(plan.followups.first).should_not contain("X-Test: forged")
      end
    end

    it "appends the payload to the body and resyncs Content-Length" do
      with_store do |store|
        detail = capture_flow(store, method: "POST", req_headers: "Content-Type: text/plain\r\n",
          req_body: "orig")
        plan = probe_and_control(rule(inject: "body", payload: "-EVIL"), detail,
          Gori::Probe::Active::Options.new(allow_unsafe: true))
        probe = String.new(plan.request)
        probe.should contain("orig-EVIL")
        probe.should contain("Content-Length: 9")               # "orig-EVIL"
        String.new(plan.followups.first).should contain("orig") # control body unchanged
        String.new(plan.followups.first).should_not contain("EVIL")
      end
    end

    it "appends the RAW payload to every cookie value and leaves the control unchanged" do
      with_store do |store|
        detail = capture_flow(store, req_headers: "Cookie: sid=abc; theme=dark\r\n")
        plan = probe_and_control(rule(inject: "cookie", payload: "'||1"), detail)
        probe = String.new(plan.request)
        # raw (not URL-encoded — a cookie value isn't URL-decoded server-side), every value, one line
        probe.should contain("Cookie: sid=abc'||1; theme=dark'||1")
        probe.scan("Cookie:").size.should eq(1)
        String.new(plan.followups.first).should contain("Cookie: sid=abc; theme=dark")
        String.new(plan.followups.first).should_not contain("'||1")
      end
    end

    it "appends the RAW payload to the path, preserving the query, control unchanged" do
      with_store do |store|
        detail = capture_flow(store, target: "/files/report?fmt=pdf")
        plan = probe_and_control(rule(inject: "path", payload: "..%2f..%2fetc%2fpasswd"), detail)
        line = String.new(plan.request).each_line.first
        # raw payload kept (traversal must survive), query preserved after it
        line.should start_with("GET /files/report..%2f..%2fetc%2fpasswd?fmt=pdf ")
        String.new(plan.followups.first).each_line.first.should start_with("GET /files/report?fmt=pdf ")
      end
    end
  end

  describe "the differential confirmation" do
    it "fires when the pattern is in the probe but NOT the control" do
      with_store do |store|
        detail = capture_flow(store, target: "/s?q=hi")
        r = rule(match_pattern: "MATCH", match_region: "body")
        plan = probe_and_control(r, detail)
        dets = r.to_rule.detections_all(plan, [
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "MATCH here".to_slice, nil, 1_i64),
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "clean".to_slice, nil, 1_i64),
        ], detail)
        dets.size.should eq(1)
        dets.first.code.should eq(r.code)
        dets.first.severity.should eq(Gori::Store::Severity::High)
        dets.first.category.should eq(Gori::Probe::Category::CUSTOM)
      end
    end

    it "does NOT fire when the pattern is already in the control (the page, not the payload)" do
      with_store do |store|
        detail = capture_flow(store, target: "/s?q=hi")
        r = rule(match_pattern: "MATCH")
        plan = probe_and_control(r, detail)
        both = "MATCH here"
        r.to_rule.detections_all(plan, [
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, both.to_slice, nil, 1_i64),
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, both.to_slice, nil, 1_i64),
        ], detail).should be_empty
      end
    end

    it "refuses when the control failed to send (no attribution)" do
      with_store do |store|
        detail = capture_flow(store, target: "/s?q=hi")
        r = rule(match_pattern: "MATCH")
        plan = probe_and_control(r, detail)
        errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
        r.to_rule.detections_all(plan, [
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "MATCH".to_slice, nil, 1_i64),
          errored,
        ], detail).should be_empty
        # …and a missing control leg is refused the same way.
        r.to_rule.detections_all(plan, [
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "MATCH".to_slice, nil, 1_i64),
        ], detail).should be_empty
      end
    end

    it "matches a regex pattern and honours the header region" do
      with_store do |store|
        detail = capture_flow(store, target: "/s?q=hi")
        r = rule(match_kind: "regex", match_pattern: "Set-Cookie: sess=[a-f0-9]+", match_region: "header")
        plan = probe_and_control(r, detail)
        r.to_rule.detections_all(plan, [
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nSet-Cookie: sess=deadbeef\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64),
          Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64),
        ], detail).size.should eq(1)
      end
    end
  end

  describe "gating" do
    it "does not plan an unsafe method by default, but does under allow_unsafe" do
      with_store do |store|
        post = capture_flow(store, target: "/s?q=hi", method: "POST")
        rule.to_rule.plan(post).should be_nil
        rule.to_rule.plan(post, Gori::Probe::Active::Options.new(allow_unsafe: true)).should_not be_nil
      end
    end

    it "does not plan when the injection target is absent" do
      with_store do |store|
        # query rule but no query
        rule(inject: "query").to_rule.plan(capture_flow(store, target: "/s")).should be_nil
        # body rule but no body
        rule(inject: "body").to_rule.plan(
          capture_flow(store, method: "GET", target: "/s")).should be_nil
        # cookie rule but no Cookie header (or a blank one)
        rule(inject: "cookie").to_rule.plan(capture_flow(store, target: "/s")).should be_nil
        rule(inject: "cookie").to_rule.plan(
          capture_flow(store, target: "/s", req_headers: "Cookie:  \r\n")).should be_nil
        # path rule always applies — a path is always present
        rule(inject: "path").to_rule.plan(capture_flow(store, target: "/s")).should_not be_nil
      end
    end

    it "keeps dedup_key equal to plan.dedup_key (equivalence invariant)" do
      with_store do |store|
        ["/s?q=1", "/s", "/a?x=1&y=2"].each do |t|
          detail = capture_flow(store, target: t)
          r = rule(inject: "query").to_rule
          r.dedup_key(detail).should eq(r.plan(detail).try(&.dedup_key))
        end
        # header rules apply even without a query, so their key is present on a bare path
        hr = rule(inject: "header", header_name: "X-Y").to_rule
        detail = capture_flow(store, target: "/s")
        hr.dedup_key(detail).should eq(hr.plan(detail).try(&.dedup_key))
      end
    end
  end

  describe "Active.analyze wiring" do
    it "runs enabled custom rules through the same send/confirm loop and skips disabled ones" do
      with_store do |store|
        detail = capture_flow(store, target: "/s?q=hi")
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)
        # A request carrying the payload comes back with MATCH; the control (no payload) does not.
        backend = DifferentialBackend.new(origin, "INJX", "MATCH")
        enabled = rule(id: "1", payload: "INJX", match_pattern: "MATCH")
        disabled = rule(id: "2", enabled: false, payload: "INJX", match_pattern: "MATCH")
        dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope),
          backend: backend, custom: [enabled, disabled])
        codes = dets.map(&.code)
        codes.should contain("customactive_p_1")
        codes.should_not contain("customactive_p_2") # disabled → never sent
      end
    end
  end
end
