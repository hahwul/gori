require "../spec_helper"
require "../support/probe_harness"

describe "Gori::Probe::Active::CorsReflection" do
  probe = Gori::Probe::Active::CorsReflection.new

  it "only probes CORS endpoints (response carried ACAO) with a safe method" do
    with_store do |store|
      # No ACAO on the captured response → nothing to probe.
      plain = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api", content_type: nil)
      probe.plan(plain).should be_nil
      # A POST is never probed even if it does CORS.
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://a.test\r\n\r\n",
        target: "/api", method: "POST", content_type: nil)
      probe.plan(post).should be_nil
      # A GET whose response did CORS → a probe is built.
      cors = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://a.test\r\n\r\n",
        target: "/api", content_type: nil)
      probe.plan(cors).should_not be_nil
    end
  end

  it "sends a single synthetic Origin header (replacing any the browser sent)" do
    with_store do |store|
      cors = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n\r\n",
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
      cors = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n\r\n",
        scheme: "http", host: "target.com", target: "http://target.com/api?x=1", content_type: nil)
      plan = probe.plan(cors).not_nil!
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /api?x=1 ")
      line.should_not contain("http://target.com")
    end
  end

  it "flags High only when the probe origin is reflected WITH credentials" do
    with_store do |store|
      cors = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://real.test\r\n\r\n",
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
      ok = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin", status: 200, content_type: nil)
      probe.plan(ok).should be_nil
      # 404/5xx are not access-control denials.
      missing = probe_capture_flow(store, "HTTP/1.1 404 Not Found\r\n\r\n", target: "/admin", status: 404, content_type: nil)
      probe.plan(missing).should be_nil
      # A denied GET/HEAD → a probe is built.
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
      probe.plan(forbidden).should_not be_nil
      unauth = probe_capture_flow(store, "HTTP/1.1 401 Unauthorized\r\n\r\n", target: "/admin", status: 401, content_type: nil)
      probe.plan(unauth).should_not be_nil
      # A POST is never probed (no auto state mutation) even when denied…
      post = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
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
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
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
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
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
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", scheme: "http", host: "target.com",
        target: "http://target.com/admin?x=1", status: 403, content_type: nil)
      plan = probe.plan(forbidden).not_nil!
      line = String.new(plan.request).each_line.first
      line.should start_with("GET /admin?x=1 ")
      line.should_not contain("http://target.com")
    end
  end

  it "dedup_key distinguishes ACTIVE from AGGRESSIVE so the wider header set is not suppressed" do
    with_store do |store|
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
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
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
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
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403, content_type: nil)
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
      forbidden = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403,
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
        d = probe_capture_flow(store, "HTTP/1.1 #{c[:status]} X\r\n\r\n", scheme: "http", host: "t.example",
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
    probe_capture_flow(store, "HTTP/1.1 #{status} OK\r\n\r\n", target: "/dashboard", status: status,
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
        d = probe_capture_flow(store, "HTTP/1.1 #{c[:status]} X\r\n\r\n", scheme: "http", host: "t.example",
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
      css = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/main.css",
        status: 200, content_type: "text/css")
      probe.plan(css).should_not be_nil

      # HTML baseline is skipped (a SPA catch-all would byte-match the traversal probe with no bug).
      html = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/app/index",
        status: 200, content_type: "text/html")
      probe.plan(html).should be_nil
      # A non-2xx resource has nothing to re-fetch.
      missing = probe_capture_flow(store, "HTTP/1.1 404 Not Found\r\n\r\n", target: "/static/x.js",
        status: 404, content_type: "application/javascript")
      probe.plan(missing).should be_nil
      # Single-segment / directory paths have no resource under a location to fold `..` after.
      root = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/favicon.ico",
        status: 200, content_type: "image/x-icon")
      probe.plan(root).should be_nil
      dir = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/",
        status: 200, content_type: "text/css")
      probe.plan(dir).should be_nil
      # HEAD is excluded — the confirmation compares bodies and HEAD returns none.
      head = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/main.css",
        status: 200, method: "HEAD", content_type: "text/css")
      probe.plan(head).should be_nil
    end
  end

  it "folds `..` after the leading segment, keeping the query, and stays origin-form" do
    with_store do |store|
      css = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/static/js/app.js?v=3",
        status: 200, content_type: "application/javascript")
      plan = probe.plan(css).not_nil!
      String.new(plan.request).each_line.first.should start_with("GET /static../static/js/app.js?v=3 ")

      # A forward-proxy absolute-form flow is normalized to origin-form before the fold.
      abs = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "t.example",
        target: "http://t.example/assets/style.css", status: 200, content_type: "text/css")
      line = String.new(probe.plan(abs).not_nil!.request).each_line.first
      line.should start_with("GET /assets../assets/style.css ")
      line.should_not contain("http://t.example")
    end
  end

  it "flags High only when the folded path returns byte-identical content" do
    with_store do |store|
      css = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\n\r\n",
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
        d = probe_capture_flow(store, "HTTP/1.1 #{c[:status]} X\r\n\r\n", scheme: "http", host: "t.example",
          target: c[:target], method: c[:method], status: c[:status], content_type: c[:ct])
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key)),
          "nginx_alias_traversal #{c[:target]} #{c[:method]} #{c[:status]} #{c[:ct]}"
      end
    end
  end

  it "widens to non-GET body methods under allow_unsafe, but never HEAD" do
    with_store do |store|
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "t.example",
        target: "/static/main.css", method: "POST", status: 200, content_type: "text/css")
      probe.plan(post).should be_nil             # GET-only by default
      probe.plan(post, unsafe).should_not be_nil # body-differential still works on a POST
      probe.dedup_key(post, unsafe).should eq(probe.plan(post, unsafe).try(&.dedup_key))
      # HEAD has no body to diff — excluded even with allow_unsafe.
      head = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: "http", host: "t.example",
        target: "/static/main.css", method: "HEAD", status: 200, content_type: "text/css")
      probe.plan(head, unsafe).should be_nil
    end
  end
end

describe "Gori::Probe::Active::PathNormalizationBypass" do
  probe = Gori::Probe::Active::PathNormalizationBypass.new
  resp = ->(status : Int32) { Gori::Repeater::Result.new("HTTP/1.1 #{status} X\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64) }

  it "plans a deterministic set of normalization variants that resolve to the original path" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, Array.new(6) { resp.call(403) }, detail).should be_empty
      redir = [resp.call(302), resp.call(403), resp.call(403), resp.call(403), resp.call(403), resp.call(403)]
      probe.detections_all(plan, redir, detail).should be_empty
    end
  end

  it "widens the variant set under aggressive opts (still <= 7), with a distinct dedup key" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 403 Forbidden\r\n\r\n", target: "/admin", status: 403)
      aggr = Gori::Probe::Active::Options.new(aggressive: true)
      probe.plan(detail, aggr).not_nil!.params.size.should eq(6)
      # The aggressive key must differ so an ACTIVE->AGGRESSIVE re-arm actually sends the extra variant.
      probe.dedup_key(detail, aggr).should_not eq(probe.dedup_key(detail))
    end
  end

  it "gates on a safe method, a 401/403 status, and a non-root, non-degenerate path" do
    with_store do |store|
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/", status: 403)).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403, method: "POST")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/a/../b", status: 403)).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 401 F\r\n\r\n", target: "/admin", status: 401)).should_not be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/admin", "/admin?x=1", "/a/b/c", "http://acme.test/admin"].each do |t|
        d = probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: t, status: 403)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key))
      end
      ok = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")
      probe.dedup_key(ok).should be_nil
      probe.plan(ok).should be_nil
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
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
      detail = probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403)
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan,
        [resp.call(200, "HOME"), resp.call(200, "HOME"), resp.call(200, "HOME")], detail).should be_empty
      probe.detections_all(plan,
        [resp.call(403, "denied"), resp.call(200, "HOME"), resp.call(200, "HOME")], detail).should be_empty
    end
  end

  it "gates on a body-comparable method and a 401/403/404 non-root path" do
    with_store do |store|
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/", status: 403)).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403, method: "HEAD")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: "/admin", status: 403, method: "POST")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 404 NF\r\n\r\n", target: "/secret", status: 404)).should_not be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/admin", "/admin?x=1", "/a/b", "http://acme.test/admin"].each do |t|
        d = probe_capture_flow(store, "HTTP/1.1 403 F\r\n\r\n", target: t, status: 403)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key))
      end
      ok = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/admin")
      probe.dedup_key(ok).should be_nil
      probe.plan(ok).should be_nil
    end
  end
end
