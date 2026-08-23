require "../../spec_helper"

# --- file-local harness (mirrors spec/probe/passive/jwt_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-sec-hdr-rule", ".db")
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

private def capture_flow(store, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n", *,
                         scheme = "https", host = "acme.test", target = "/", status = 200,
                         content_type : String? = "text/html", body : String? = nil,
                         method = "GET", req_headers = "") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Only the SecurityHeaders rule's detections, taken straight off the rule (not the whole
# registry) so an unrelated rule's code can never satisfy or spoil an assertion here.
private def sec(store, **kw) : Array(Gori::Probe::Detection)
  detail = capture_flow(store, **kw)
  acc = [] of Gori::Probe::Detection
  Gori::Probe::Passive::SecurityHeaders.new.check(Gori::Probe::Passive::Context.new(detail), acc)
  acc
end

private def codes(dets) : Array(String)
  dets.map(&.code)
end

describe Gori::Probe::Passive::SecurityHeaders do
  describe "missing_coop" do
    it "flags an HTML 200 with no Cross-Origin-Opener-Policy" do
      with_store do |store|
        dets = sec(store)
        codes(dets).should contain("missing_coop")
        d = dets.find { |x| x.code == "missing_coop" }.not_nil!
        d.title.should eq("Missing Cross-Origin-Opener-Policy")
        d.severity.should eq(Gori::Store::Severity::Info)
        d.category.should eq(Gori::Probe::Category::HEADERS)
      end
    end

    it "does not flag when Cross-Origin-Opener-Policy: same-origin is set" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n"
        codes(sec(store, resp_head: head)).should_not contain("missing_coop")
      end
    end

    it "treats any COOP value as present (unsafe-none is the default, not a finding)" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nCross-Origin-Opener-Policy: unsafe-none\r\n\r\n"
        codes(sec(store, resp_head: head)).should_not contain("missing_coop")
      end
    end

    it "does not flag a missing COEP/CORP on their own" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n"
        codes(sec(store, resp_head: head)).each do |c|
          c.should_not contain("coep")
          c.should_not contain("corp")
        end
      end
    end
  end

  describe "csp_missing_base_uri" do
    it "flags an enforcing CSP that has no base-uri directive" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self'\r\n\r\n"
        dets = sec(store, resp_head: head)
        codes(dets).should contain("csp_missing_base_uri")
        d = dets.find { |x| x.code == "csp_missing_base_uri" }.not_nil!
        d.title.should eq("CSP without base-uri (base-tag hijacking)")
        d.severity.should eq(Gori::Store::Severity::Low)
        d.category.should eq(Gori::Probe::Category::HEADERS)
      end
    end

    it "does not flag a CSP that declares base-uri 'self'" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\n" \
               "Content-Security-Policy: default-src 'self'; base-uri 'self'\r\n\r\n"
        codes(sec(store, resp_head: head)).should_not contain("csp_missing_base_uri")
      end
    end

    it "matches base-uri case-insensitively (parse_csp downcases directive names)" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\n" \
               "Content-Security-Policy: default-src 'self'; BASE-URI 'none'\r\n\r\n"
        codes(sec(store, resp_head: head)).should_not contain("csp_missing_base_uri")
      end
    end

    it "does not fire when no CSP is present at all (missing_csp covers that)" do
      with_store do |store|
        dets = sec(store)
        codes(dets).should contain("missing_csp")
        codes(dets).should_not contain("csp_missing_base_uri")
      end
    end

    it "does not fire on a report-only-only response" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\n" \
               "Content-Security-Policy-Report-Only: default-src 'self'\r\n\r\n"
        dets = sec(store, resp_head: head)
        codes(dets).should contain("csp_report_only")
        codes(dets).should_not contain("csp_missing_base_uri")
      end
    end

    it "still fires when the enforcing CSP is also weak (both codes, independent axes)" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\n" \
               "Content-Security-Policy: default-src 'self' 'unsafe-inline'\r\n\r\n"
        c = codes(sec(store, resp_head: head))
        c.should contain("weak_csp")
        c.should contain("csp_missing_base_uri")
      end
    end

    it "does not fire on a transport/frame-only CSP (no script source to bypass)" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\n" \
               "Content-Security-Policy: upgrade-insecure-requests; frame-ancestors 'none'\r\n\r\n"
        # No script-src/default-src/object-src allowlist for a rebased <base> to walk around, so
        # base-uri is moot — CSP Evaluator only flags the gap in that context.
        codes(sec(store, resp_head: head)).should_not contain("csp_missing_base_uri")
      end
    end
  end

  describe "document gating" do
    it "emits neither code on a 3xx redirect (never rendered)" do
      with_store do |store|
        head = "HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n"
        c = codes(sec(store, resp_head: head, status: 302))
        c.should_not contain("missing_coop")
        c.should_not contain("csp_missing_base_uri")
      end
    end

    it "emits neither code on a non-HTML response" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
        c = codes(sec(store, resp_head: head, content_type: "application/json"))
        c.should_not contain("missing_coop")
        c.should_not contain("csp_missing_base_uri")
      end
    end

    it "still emits both on a 4xx error page (a rendered document)" do
      with_store do |store|
        head = "HTTP/1.1 404 Not Found\r\nContent-Security-Policy: default-src 'self'\r\n\r\n"
        c = codes(sec(store, resp_head: head, status: 404))
        c.should contain("missing_coop")
        c.should contain("csp_missing_base_uri")
      end
    end
  end

  it "surfaces both new codes through the registered Passive.analyze pipeline" do
    with_store do |store|
      detail = capture_flow(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self'\r\n\r\n")
      c = Gori::Probe::Passive.analyze(detail).map(&.code)
      c.should contain("missing_coop")
      c.should contain("csp_missing_base_uri")
    end
  end
end
