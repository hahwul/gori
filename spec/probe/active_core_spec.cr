require "../spec_helper"
require "../support/probe_harness"

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

describe Gori::Probe::Active do
  it "builds a canary probe from existing query params and detects reflection" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/search?q=hello", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/submit", method: "POST",
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/j", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: req_body, content_type: nil)
      plan = Gori::Probe::Active::ReflectedParam.new.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true)).not_nil!
      # `"x":"<0xFF>"` must survive as one raw byte, not the three-byte U+FFFD `efbfbd`.
      plan.request.hexstring.should contain(Bytes[0x22_u8, 0xff_u8, 0x22_u8].hexstring)
    end
  end

  it "has no probe for a request without parameters" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/app.js", content_type: nil)
      Gori::Probe::Active.plan(detail).should be_nil
    end
  end

  it "sends an ORIGIN-FORM request line even for an absolute-form (forward-proxy) target" do
    with_store do |store|
      # A plaintext forward-proxy flow is captured absolute-form; the probe goes DIRECT to
      # the origin, so its request line must be origin-form (some origins reject absolute-form).
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "target.com",
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
        d = probe_capture_flow(store, c[:resp], scheme: "http", host: "t.example",
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

      post = probe_capture_flow(store, plain_resp, host: "t.example", target: "/a?x=1&y=2", method: "POST")
      put = probe_capture_flow(store, cors_resp, host: "t.example", target: "/cors", method: "PUT")
      wide = probe_capture_flow(store, plain_resp, host: "t.example", target: "/many?#{many}", method: "POST")

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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "target.com",
        target: "http://target.com?name=hello", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["name"])
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /?name=")
      line.should_not contain("http://target.com")
    end
  end
end

describe "Gori::Probe::Active (safety + coverage)" do
  it "does not probe mutating methods (POST) by default, but opts-in widens it" do
    with_store do |store|
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/comment", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n", req_body: "text=hi", content_type: nil)
      Gori::Probe::Active.plan(post).should be_nil # automatic pipeline (default opts) never mutates
      # The manual opt-in / AGGRESSIVE mode probes the reflectable form params on the POST.
      Gori::Probe::Active.plan(post, Gori::Probe::Active::Options.new(allow_unsafe: true)).should_not be_nil
      get = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      Gori::Probe::Active.plan(get).should_not be_nil
    end
  end

  it "keys the dedup signature by method and parameter location" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      key = Gori::Probe::Active.plan(detail).not_nil!.dedup_key
      key.should contain("GET")
      key.should contain("q@query")
    end
  end

  it "never sends an active probe when the scope EXCLUDES the target (ScopedBackend hard-block)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("exclude", "host", "acme.test")
      fake = CountingBackend.new(Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port))
      dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope), overrides: nil, backend: fake)
      fake.sent.should eq(0) # blocked before the socket — proves scope, not a send failure
      dets.should be_empty
    end
  end

  it "caps active sends via active_limit but never truncates the passive scan (R1-5)" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/b?token=bbbbbbbb", content_type: nil)
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
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
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
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      fake = CountingBackend.new(Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port))
      Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope), overrides: nil, backend: fake)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)
      backend = RaisingBackend.new(origin)
      failed = [] of String
      dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope), overrides: nil,
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
      detail = probe_capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://app.acme.test\r\n\r\n",
        target: "/s?q=hi", content_type: nil)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)
      failed = [] of String
      dets = Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.interactive(scope), overrides: nil,
        backend: FlakyCorsBackend.new(origin),
        on_error: ->(where : String, _ex : Exception) { failed << where; nil })
      # on_error carries the RULE id; the Detection carries its own finding CODE.
      failed.should eq(["reflected_param"])                    # the first rule died...
      dets.map(&.code).should contain("cors_arbitrary_origin") # ...a later rule still reported
    end
  end

  it "reports no scan errors on a clean Scan.scan_flows run" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/go?url=here", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      plan = Gori::Probe::Active.plan(detail).not_nil!
      canary = plan.params.first.canary
      req = String.new(plan.request)
      req.should contain("q=#{canary}%22%27%3C%3E")
      req.should_not contain("<") # nothing raw on the request line

      body_detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"q":"hi"}), content_type: nil)
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      jplan = Gori::Probe::Active::ReflectedParam.new.plan(body_detail, unsafe).not_nil!
      jc = jplan.params.first.canary
      String.new(jplan.request).should contain(%(#{jc}\\"'<>))
    end
  end

  it "skips active analysis safely when active probe target connection fails or yields no plan" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/no-params", content_type: nil)
      dets = Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, overrides: nil)
      dets.should be_empty
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
      detail = probe_capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.test\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi", body: "<p>hi</p>")
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      est = a.active_estimate(detail)
      # reflected_param, cors_reflection, backslash_powered all apply — plus crlf_injection, ssti,
      # and sqli_error_based, which reuse the same reflectable-query-param gate.
      est.map(&.info.id).sort!.should eq(["backslash_powered", "cors_reflection", "crlf_injection", "reflected_param", "sqli_error_based", "ssti"])
      # reflected_param (1) + cors_reflection (1) + backslash_powered (≤8) + crlf_injection (1) + ssti (2) + sqli_error_based (≤5) = 18
      est.sum(&.requests.end).should eq(18)
    end
  end

  it "omits a disabled active rule from the estimate" do
    with_store do |store|
      store.set_probe_disabled_rules(Set{"cors_reflection"})
      detail = probe_capture_flow(store,
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.test\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi")
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      # RULES order (cors_reflection disabled): reflected_param, backslash_powered, sqli_error_based,
      # then the other reflectable-query-param rules crlf_injection and ssti.
      a.active_estimate(detail).map(&.info.id).should eq(["reflected_param", "backslash_powered", "sqli_error_based", "crlf_injection", "ssti"])
    end
  end

  it "estimates zero for an unsafe-method / paramless / non-CORS flow" do
    with_store do |store|
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      # POST is never probed under the default (safe-only) estimate…
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/x?q=1", method: "POST")
      a.active_estimate(post).should be_empty
      # …but the allow_unsafe estimate (the run popup's opt-in) surfaces the reflectable-param check.
      unsafe_est = a.active_estimate(post, Gori::Probe::Active::Options.new(allow_unsafe: true))
      unsafe_est.map(&.info.id).should contain("reflected_param")
      # GET with no params + no ACAO has nothing to test, opt-in or not.
      bare = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/nothing")
      a.active_estimate(bare).should be_empty
      a.active_estimate(bare, Gori::Probe::Active::Options.new(allow_unsafe: true)).should be_empty
    end
  end

  it "run_active_now runs regardless of mode / notify choice without raising" do
    with_store do |store|
      detail = probe_capture_flow(store,
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
        post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/x?q=1", method: "POST")
        a.run_active_now(post, allow_unsafe: true)
        sleep 50.milliseconds
        a.stop
      end
    end
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

# The headless scan orchestrator (`gori run probe` + MCP probe_scan) must honour the SAME
# Rules sub-tab config the TUI Analyzer does — disabled built-ins stay off, custom rules run.
# Before this, Scan called Passive.analyze/Active.analyze with neither, so a headless scan
# silently re-reported rules the operator had turned off and never ran a custom rule at all.
describe "Gori::Probe::Scan rules config parity" do
  it "honours the operator's disabled built-ins in a headless passive scan" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
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
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a",
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", content_type: nil)
      origin = Gori::Fuzz::Origin.new(detail.row.scheme, detail.row.host, detail.row.port)

      baseline = CountingBackend.new(origin)
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, overrides: nil, backend: baseline)
      baseline.sent.should be > 0

      # Disabling every active rule must stop the sends at the source, not just drop findings.
      all_ids = Gori::Probe::Active::RULES.map(&.info.id).to_set
      muted = CountingBackend.new(origin)
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, overrides: nil, backend: muted, disabled: all_ids)
      muted.sent.should eq(0)
    end
  end

  it "scans Repeater tabs under the same rules config as History flows" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?token=aaaaaaaa", content_type: nil)
      ids = Gori::Probe::Scan.flow_ids(store, nil)
      store.set_probe_disabled_rules(Set{"secret_in_url"})

      dets, _ = Gori::Probe::Scan.scan_all(store, ids, active: false)
      dets.count { |d| d.code == "secret_in_url" }.should eq(0)
    end
  end
end
