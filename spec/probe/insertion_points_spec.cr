require "../spec_helper"
require "../../src/gori/probe/active/insertion_points"
require "../../src/gori/probe/active/reflected_param"
require "../../src/gori/probe/active/ssti"
require "../../src/gori/probe/active/error_based_sqli"
require "../../src/gori/probe/active/backslash_powered"
require "../../src/gori/probe/active/lfi_param_traversal"

private alias IP = Gori::Probe::Active::InsertionPoints
private alias Loc = Gori::Miner::Location

# ── store + flow helpers (copied from probe_spec.cr — this codebase duplicates these per file) ──

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
    head: head.to_slice, body: req_body.try(&.to_slice), source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def resp(body : String, status : Int32 = 200) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
  Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
end

private def unsafe
  Gori::Probe::Active::Options.new(allow_unsafe: true)
end

private def aggressive
  Gori::Probe::Active::Options.new(allow_unsafe: true, aggressive: true)
end

describe "Gori::Probe::Active::InsertionPoints" do
  describe ".enumerate" do
    it "enumerates query params in order" do
      with_store do |store|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&flag&b=2")
        s = IP.enumerate(d, Gori::Probe::Active::Options::DEFAULT, [Loc::Query]).not_nil!
        s.method.should eq("GET")
        s.path.should eq("/s")
        s.slots.map(&.name).should eq(["a", "b"]) # bare flag skipped
        s.slots.map(&.loc.label).uniq.should eq(["query"])
      end
    end

    it "enumerates form + JSON body params on a body-bearing request" do
      with_store do |store|
        form = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/p", method: "POST",
          req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: "u=bob&pw=x")
        IP.enumerate(form, Gori::Probe::Active::Options::DEFAULT, [Loc::Query, Loc::Form, Loc::Json])
          .not_nil!.slots.map { |s| {s.loc.label, s.name} }.should eq([{"form", "u"}, {"form", "pw"}])

        js = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/p", method: "POST",
          req_headers: "Content-Type: application/json\r\n", req_body: %({"id":"42","n":7}))
        IP.enumerate(js, Gori::Probe::Active::Options::DEFAULT, [Loc::Query, Loc::Form, Loc::Json])
          .not_nil!.slots.map { |s| {s.loc.label, s.name} }.should eq([{"json", "id"}]) # only string field
      end
    end

    it "enumerates headers + cookies only under aggressive, skipping forbidden + request-critical" do
      with_store do |store|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/", method: "POST",
          req_headers: "User-Agent: curl\r\nAuthorization: Bearer t\r\n" \
                       "Content-Type: application/json\r\nCookie: sid=abc; theme=dark\r\n",
          req_body: %({"x":"y"}))
        locs = [Loc::Query, Loc::Headers, Loc::Cookies]
        IP.enumerate(d, Gori::Probe::Active::Options::DEFAULT, locs).not_nil!.slots.should be_empty
        got = IP.enumerate(d, aggressive, locs).not_nil!.slots.map { |s| {s.loc.label, s.name} }
        got.should contain({"headers", "User-Agent"})
        got.should contain({"cookies", "sid"})
        got.should contain({"cookies", "theme"})
        names = got.map { |(_, n)| n.downcase }
        names.should_not contain("host")          # forbidden/framing header excluded
        names.should_not contain("authorization") # request-critical: mutating it breaks the request
        names.should_not contain("content-type")  # request-critical: changes body interpretation
      end
    end

    it "returns nil only for a malformed request line" do
      with_store do |store|
        # A HEAD/no-param flow is NOT nil here (the method gate + cap live in the rule); enumerate
        # nils only on a malformed start line, which capture_flow can't produce, so assert the
        # non-nil, empty-slot shape instead.
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")
        IP.enumerate(d, Gori::Probe::Active::Options::DEFAULT, [Loc::Query]).not_nil!.slots.should be_empty
      end
    end
  end

  describe ".build" do
    it "REPLACE URL-encodes a query value; empty changes reproduce the request line" do
      with_store do |store|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&b=2")
        s = IP.enumerate(d, Gori::Probe::Active::Options::DEFAULT, [Loc::Query]).not_nil!
        base = String.new(IP.build(d, [] of {IP::Slot, IP::Change}))
        base.should contain("/s?a=1&b=2 ")
        req = String.new(IP.build(d, [{s.slots[0], IP::Change.new(replace: "x y")}]))
        req.should contain("/s?a=x%20y&b=2 ") # space_to_plus:false, other param verbatim
      end
    end

    it "RAW suffix is not re-encoded (single-encoded payload survives)" do
      with_store do |store|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?id=42")
        s = IP.enumerate(d, Gori::Probe::Active::Options::DEFAULT, [Loc::Query]).not_nil!
        String.new(IP.build(d, [{s.slots[0], IP::Change.new(suffix: "%27%22")}]))
          .should contain("id=42%27%22 ")
      end
    end

    it "REPLACE rewrites a header by name (a non-UTF-8 header before it can't desync it)" do
      with_store do |store|
        # A binary/non-UTF-8 header sits BEFORE the injectable one. Name-addressing means build
        # finds User-Agent by matching, not by a positional index the byte-safe walk skipped.
        head = "GET / HTTP/1.1\r\nHost: acme.test\r\nX-Bin: \xff\xfe\r\nUser-Agent: curl\r\n\r\n"
        req = Gori::Store::CapturedRequest.new(created_at: 1_i64, scheme: "https", host: "acme.test",
          port: 443, method: "GET", target: "/", http_version: "HTTP/1.1",
          head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
        id = store.insert_flow(req)
        store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: nil, reason: "OK",
          content_type: "text/html", duration_us: 1_i64))
        d = store.get_flow(id).not_nil!
        s = IP.enumerate(d, aggressive, [Loc::Headers]).not_nil!
        ua = s.slots.find { |x| x.name == "User-Agent" }.not_nil!
        out = String.new(IP.build(d, [{ua, IP::Change.new(replace: "CANARY")}]))
        out.should contain("User-Agent: CANARY\r\n") # the right header was rewritten
      end
    end

    it "rewrites cookie crumbs by name, preserving the `; ` separator" do
      with_store do |store|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/",
          req_headers: "Cookie: sid=abc; theme=dark\r\n")
        s = IP.enumerate(d, aggressive, [Loc::Cookies]).not_nil!
        theme = s.slots.find { |x| x.name == "theme" }.not_nil!
        String.new(IP.build(d, [{theme, IP::Change.new(replace: "C")}]))
          .should contain("Cookie: sid=abc; theme=C\r\n")
      end
    end

    it "REPLACE re-serializes a JSON string field and resyncs an existing Content-Length" do
      with_store do |store|
        d = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/p", method: "POST",
          req_headers: "Content-Type: application/json\r\nContent-Length: 17\r\n",
          req_body: %({"id":"42","n":7}))
        s = IP.enumerate(d, Gori::Probe::Active::Options::DEFAULT, [Loc::Json]).not_nil!
        req = String.new(IP.build(d, [{s.slots[0], IP::Change.new(replace: "CANARY")}]))
        req.should contain(%("id":"CANARY"))
        req.should contain(%("n":7))                 # untouched field carried through
        req.should contain("Content-Length: 21\r\n") # 17 → 21, resynced to the new body
      end
    end
  end
end

# ── widened-coverage integration: the differential rules now reach form / JSON body params ──

describe "insertion-point coverage (body params)" do
  it "error-based SQLi fires on a JSON body param (under allow_unsafe)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"id":"42"}))
      rule = Gori::Probe::Active::ErrorBasedSqli.new
      plan = rule.plan(detail, unsafe).not_nil!
      plan.params.map { |p| {p.location, p.name} }.should eq([{"json", "id"}])
      String.new(plan.followups[1]).should contain(%("id":"42'\\"")) # value + '"  (JSON-escaped)
      dets = rule.detections_all(plan,
        [resp(%({"ok":true})), resp(%({"ok":true})),
         resp("You have an error in your SQL syntax; check the manual")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("sqli_error_based")
      dets.first.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "error-based SQLi fires on a form body param (under allow_unsafe)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/login", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: "user=bob")
      rule = Gori::Probe::Active::ErrorBasedSqli.new
      plan = rule.plan(detail, unsafe).not_nil!
      plan.params.map { |p| {p.location, p.name} }.should eq([{"form", "user"}])
      String.new(plan.followups[1]).should contain("user=bob%27%22")
      dets = rule.detections_all(plan,
        [resp("ok"), resp("ok"), resp("Unclosed quotation mark after the character string")], detail)
      dets.size.should eq(1)
    end
  end

  it "SSTI reaches a JSON body param (under allow_unsafe)" do
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/render", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"tpl":"hi"}))
      rule = Gori::Probe::Active::Ssti.new
      plan = rule.plan(detail, unsafe).not_nil!
      plan.params.map { |p| {p.location, p.name} }.should eq([{"json", "tpl"}])
      c = plan.params.first.canary
      dets = rule.detections_all(plan, [resp("x#{c}49#{c}y"), resp("x#{c}56#{c}y")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("ssti")
    end
  end

  it "reflected-param does NOT mutate header/cookie in its single batched probe (deferred)" do
    # Header/cookie injection needs a per-slot multi-probe model (mutating Authorization/Cookie in
    # the one batched request would break every other param's reflection). Until that lands, the
    # value-injection rules stay on the body surfaces even under aggressive.
    with_store do |store|
      detail = capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/?q=1",
        req_headers: "User-Agent: curl\r\nCookie: sid=abc\r\n")
      rule = Gori::Probe::Active::ReflectedParam.new
      plan = rule.plan(detail, aggressive).not_nil!
      plan.params.map(&.location).uniq.should eq(["query"])
    end
  end
end
