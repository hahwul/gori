require "../spec_helper"
require "../support/probe_harness"

describe Gori::Probe::Passive do
  it "flags missing security headers, cookie flags, and a server fingerprint" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.18.0\r\n" \
             "Set-Cookie: sid=abc\r\n\r\n"
      detail = probe_capture_flow(store, head)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }

      found = probe_codes(store)
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
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: body)
      probe_codes_of(dets).should contain("secret_in_body")
    end
  end

  it "does not flag a Spring class name in prose, but does flag a real Spring frame" do
    with_store do |store|
      prose = "See the JavaDoc at org.springframework.boot.SpringApplication for details."
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", body: prose))
        .should_not contain("error_stack_leak")
      frame = "err\n\tat org.springframework.aop.framework.CglibAopProxy.intercept(Native Method)"
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", body: frame))
        .should contain("error_stack_leak")
    end
  end

  it "does not treat a non-adjacent version word as version context for a private-IP leak" do
    with_store do |store|
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: "Our firmware serves 10.0.0.5 today")).should contain("private_ip_leak")
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: "File version 10.0.1.2 released")).should_not contain("private_ip_leak")
    end
  end

  it "flags cleartext Basic auth even behind a later duplicate Authorization header" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        scheme: "http", req_headers: "Authorization: Basic dXNlcjpwYXNz\r\nAuthorization: Bearer tok\r\n")
      probe_codes_of(dets).should contain("insecure_basic_auth")
    end
  end

  it "does not flag CORS when the response carries duplicate ACAO headers (browser blocks it)" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Origin: https://x.test\r\n\r\n"
      probe_codes_of(probe_analyze(store, resp_head: head)).should_not contain("cors_wildcard")
    end
  end

  it "does not flag document headers when they are present" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Strict-Transport-Security: max-age=63072000\r\n" \
             "Content-Security-Policy: default-src 'self'\r\nX-Frame-Options: DENY\r\n" \
             "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n"
      detail = probe_capture_flow(store, head)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      probe_codes(store).should_not contain("missing_csp")
      probe_codes(store).should_not contain("missing_hsts")
    end
  end

  it "fingerprints gRPC and surfaces it as a project technology" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: application/grpc\r\n\r\n"
      detail = probe_capture_flow(store, head, content_type: "application/grpc")
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      probe_codes(store).should contain("tech_grpc")
      store.probe_tech_summary.should contain("gRPC")
    end
  end

  it "fingerprints framework/version-disclosure headers and surfaces them as project tech" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nX-AspNet-Version: 4.0.30319\r\n" \
             "X-AspNetMvc-Version: 5.2\r\nX-Generator: Drupal 10 (https://www.drupal.org)\r\n\r\n"
      detail = probe_capture_flow(store, head)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      found = probe_codes(store)
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?token=secret123&x=1", content_type: nil)
      Gori::Probe::Passive.analyze(detail).each { |d| store.upsert_probe_issue(d) }
      issue = store.probe_issues.find(&.code.==("secret_in_url")).not_nil!
      issue.severity.should eq(Gori::Store::Severity::High)
      issue.evidence.should eq("token") # the NAME only — never the value
    end
  end

  it "groups the same issue type on one host (affected URLs accumulate, hit_count climbs)" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
      probe_capture_flow(store, head, target: "/a").try { |d| Gori::Probe::Passive.analyze(d).each { |x| store.upsert_probe_issue(x) } }
      probe_capture_flow(store, head, target: "/b").try { |d| Gori::Probe::Passive.analyze(d).each { |x| store.upsert_probe_issue(x) } }
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
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        scheme: "http", host: "127.0.0.1", target: "http://127.0.0.1:8899/cors")
      urls = Gori::Probe::Passive.analyze(detail).map(&.url).uniq!
      urls.should eq(["http://127.0.0.1:8899/cors"])
      urls.first.should_not contain("127.0.0.1http://")
    end
  end
end

describe "Gori::Probe::Passive (FP reduction)" do
  it "does not flag a dotted version string in a JS bundle as a private IP" do
    with_store do |store|
      js = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "application/javascript", body: "const VERSION='10.15.2.3';")
      probe_codes_of(js).should_not contain("private_ip_leak")
      # ...but a genuine private IP in an HTML body IS flagged.
      html = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<p>backend at 10.0.0.5</p>")
      html.find(&.code.==("private_ip_leak")).not_nil!.evidence.should eq("10.0.0.5")
    end
  end

  it "does not treat a 5-segment version (10.1.2.3.4) as a private IP" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<span>build 10.1.2.3.4 ok</span>")
      probe_codes_of(dets).should_not contain("private_ip_leak")
    end
  end

  it "does not flag loopback 127.0.0.1 as a private IP but still flags an RFC 1918 address" do
    with_store do |store|
      # Loopback aids no recon and is ubiquitous in bundles/configs (a near-pure FP source).
      loopback = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<p>dev server on http://127.0.0.1:3000/</p>")
      probe_codes_of(loopback).should_not contain("private_ip_leak")
      # A real internal (RFC 1918) address is still surfaced.
      internal = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "<p>proxy 192.168.1.20</p>")
      internal.find(&.code.==("private_ip_leak")).not_nil!.evidence.should eq("192.168.1.20")
    end
  end

  it "does not flag document headers on a 3xx redirect (not rendered), but still on an error page" do
    with_store do |store|
      # A 302 with text/html (the ubiquitous "Redirecting…" body) is FOLLOWED, never rendered,
      # so its missing CSP/XFO/XCTO/Referrer are noise — the real target page is checked on its
      # own flow. HSTS still applies to the HTTPS redirect response.
      redirect = probe_analyze(store, resp_head: "HTTP/1.1 302 Found\r\nLocation: /home\r\n\r\n",
        status: 302, content_type: "text/html")
      probe_codes_of(redirect).should_not contain("missing_csp")
      probe_codes_of(redirect).should_not contain("missing_x_frame_options")
      probe_codes_of(redirect).should_not contain("missing_referrer_policy")
      probe_codes_of(redirect).should contain("missing_hsts")
      # A 4xx/5xx error page IS a rendered document (framable / may reflect) — keep the checks.
      error = probe_analyze(store, resp_head: "HTTP/1.1 404 Not Found\r\n\r\n",
        status: 404, content_type: "text/html")
      probe_codes_of(error).should contain("missing_csp")
      probe_codes_of(error).should contain("missing_x_frame_options")
    end
  end

  it "does not flag prose containing a bare '.rb:' but flags a real backtrace frame" do
    with_store do |store|
      prose = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        content_type: "text/html", body: "Edit the helper.rb: add a method.")
      probe_codes_of(prose).should_not contain("error_stack_leak")
      trace = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html", body: "app/models/user.rb:42:in `save'")
      probe_codes_of(trace).should contain("error_stack_leak")
    end
  end

  it "does not flag prose that merely NAMES a Python traceback, but flags a real one" do
    with_store do |store|
      # A tutorial ABOUT tracebacks reproduces the header in prose. Every other entry in
      # ERROR_SIGNATURES already screens that shape; this one used to be the exception.
      prose = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "<h2>Reading a Traceback (most recent call last)</h2>" \
              "<p>This tutorial explains Python tracebacks.</p>")
      probe_codes_of(prose).should_not contain("error_stack_leak")
      # Nor does the header JOIN to an unrelated example frame far down the page. (The page
      # still trips the sibling `File "….py", line N` signature on its own — a separate,
      # pre-existing pattern — so this asserts on the evidence label, not the code.)
      far = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "Traceback (most recent call last) is the header Python prints. #{"x" * 200} " +
              %(For example File "demo.py", line 3 shows a frame.))
      far.select(&.code.==("error_stack_leak")).map(&.evidence).should_not contain("Python traceback")
      # A real CPython dump — header plus its File/line frame — still fires.
      trace = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html",
        body: %(Traceback (most recent call last):\n  File "/app/main.py", line 42, in <module>\n) +
              "    boom()\nZeroDivisionError: division by zero")
      trace.select(&.code.==("error_stack_leak")).map(&.evidence).should contain("Python traceback")
      # …including the `File "<stdin>", line N` form, which the sibling `.py`-only frame
      # pattern does not cover, and the JSON-escaped form an API error response embeds.
      stdin = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html",
        body: %(Traceback (most recent call last):\n  File "<stdin>", line 1, in <module>\nNameError: x))
      stdin.select(&.code.==("error_stack_leak")).map(&.evidence).should contain("Python traceback")
      json = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "application/json",
        body: %({"error":"Traceback (most recent call last):\\n  File \\"/srv/api/views.py\\", line 88"}))
      json.select(&.code.==("error_stack_leak")).map(&.evidence).should contain("Python traceback")
    end
  end

  it "does not flag AWS's own published example key id, but flags a realistic one" do
    with_store do |store|
      # AWS ships this exact pair through its SigV4/CLI docs, so a page reproducing them is
      # documenting AWS, not leaking a key — the same screen the Google client id and the
      # Mapbox `pk.` token got. (Split so secret-scanning push protection lets the fixture by.)
      example_id = "AKIA" + "IOSFODNN7EXAMPLE"
      example_secret = "wJalrXUtnFEMI/K7MDENG/" + "bPxRfiCYEXAMPLEKEY"
      docs = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "<pre>aws_access_key_id = #{example_id}\naws_secret_access_key = #{example_secret}</pre>")
      probe_codes_of(docs).should_not contain("secret_in_body")
      # The IAM guide's second placeholder, and the ASIA temporary-credential twin.
      iam = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "key id: " + "AKIA" + "I44QH8DHBEXAMPLE")
      probe_codes_of(iam).should_not contain("secret_in_body")
      temp = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "key id: " + "ASIA" + "IOSFODNN7EXAMPLE")
      probe_codes_of(temp).should_not contain("secret_in_body")
      # A key id that is NOT one of those placeholders is still a High.
      real = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "aws_access_key_id = " + "AKIA" + "3ZQF7XKPL2WVNB6D")
      real.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("AWS access key id")
    end
  end

  it "does not flag unsafe-inline confined to style-src, but does for script-src" do
    with_store do |store|
      safe = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                             "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(safe).should_not contain("weak_csp")
      weak = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                             "default-src 'self'; script-src 'self' 'unsafe-inline'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(weak).should contain("weak_csp")
    end
  end

  it "still demands X-Frame-Options when CSP frame-ancestors is permissive (*)" do
    with_store do |store|
      permissive = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                                   "default-src 'self'; frame-ancestors *\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(permissive).should contain("missing_x_frame_options")
      restrictive = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                                    "default-src 'self'; frame-ancestors 'self'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(restrictive).should_not contain("missing_x_frame_options")
    end
  end

  it "does not flag a nonce/hash/strict-dynamic CSP that keeps 'unsafe-inline' for CSP2 fallback" do
    with_store do |store|
      # CSP Level 3: a nonce (or hash, or strict-dynamic) makes browsers IGNORE 'unsafe-inline',
      # so this modern policy is SAFE and must not trip weak_csp (the common FP).
      nonce = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                              "script-src 'self' 'unsafe-inline' 'nonce-abc123'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(nonce).should_not contain("weak_csp")
      hash = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                             "script-src 'unsafe-inline' 'sha256-abc123def456ghi789'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(hash).should_not contain("weak_csp")
      # strict-dynamic also nullifies 'unsafe-inline' AND host/scheme sources (https:, *).
      strict = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                               "script-src 'strict-dynamic' 'nonce-x' 'unsafe-inline' https: *\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(strict).should_not contain("weak_csp")
    end
  end

  it "still flags 'unsafe-eval' and a 'data:' script source (neither is nullified by a nonce)" do
    with_store do |store|
      # 'unsafe-eval' executes regardless of nonces/strict-dynamic → always weak.
      eval_csp = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                                 "script-src 'self' 'nonce-x' 'unsafe-eval'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(eval_csp).should contain("weak_csp")
      # a 'data:' script source allows data-URI scripts (XSS) when strict-dynamic is absent.
      data_csp = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                                 "script-src 'self' data:\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(data_csp).should contain("weak_csp")
    end
  end

  it "flags a bare https:/http: scheme source in script-src, but not a specific https host" do
    with_store do |store|
      # A bare 'https:' scheme source is an allowlist that permits ANY host over https to serve
      # scripts — effectively allow-all, and flagged by CSP evaluators as weak (was a FN here).
      scheme = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                               "script-src 'self' https:\r\n\r\n", content_type: "text/html")
      probe_codes_of(scheme).should contain("weak_csp")
      http = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                             "default-src 'self'; script-src http:\r\n\r\n", content_type: "text/html")
      probe_codes_of(http).should contain("weak_csp")
      # A SPECIFIC host over https is a distinct token — a normal, safe allowlist entry.
      host = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                             "script-src 'self' https://cdn.example.com\r\n\r\n", content_type: "text/html")
      probe_codes_of(host).should_not contain("weak_csp")
    end
  end

  # The keyword tests were `includes?`, so any source merely CONTAINING the word scored the
  # whole policy weak — an allowlisted host or path is not a keyword.
  it "does not read an allowlisted host/path that merely contains a keyword as that keyword" do
    with_store do |store|
      ["script-src 'self' https://unsafe-evaluation.example",
       "script-src 'self' https://cdn.example.com/unsafe-inline.js",
       "script-src 'self' https://unsafe-inline-demo.example"].each do |policy|
        dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: #{policy}\r\n\r\n",
          content_type: "text/html")
        probe_codes_of(dets).should_not contain("weak_csp"), policy
      end
    end
  end

  # …while the real keywords still fire, quoted (per spec) or bare (as seen in the wild).
  it "flags the real keywords whether or not they are quoted" do
    with_store do |store|
      ["script-src 'self' 'unsafe-eval'", "script-src 'self' unsafe-eval",
       "script-src 'self' 'unsafe-inline'", "script-src 'self' unsafe-inline"].each do |policy|
        dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: #{policy}\r\n\r\n",
          content_type: "text/html")
        probe_codes_of(dets).should contain("weak_csp"), policy
      end
      # An unquoted strict-dynamic must still nullify 'unsafe-inline', like the quoted form.
      lenient = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: " \
                                                "script-src 'self' strict-dynamic 'unsafe-inline'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(lenient).should_not contain("weak_csp")
    end
  end

  it "rates a wildcard CORS with credentials Medium (the combination is browser-rejected, not High)" do
    with_store do |store|
      dets = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n", content_type: nil)
      hit = dets.find(&.code.==("cors_wildcard")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "flags a Go panic dump and Stripe/SendGrid/npm secrets (type only, never the value)" do
    with_store do |store|
      go = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
        content_type: "text/html",
        body: "panic: runtime error\n\ngoroutine 1 [running]:\nmain.main()\n\t/app/main.go:10 +0x1d")
      probe_codes_of(go).should contain("error_stack_leak")
      stripe = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: %({"key":"sk_live_ABCDEFGHIJKLMNOPQRSTUVWX"}))
      hit = stripe.find(&.code.==("secret_in_body")).not_nil!
      hit.evidence.should eq("Stripe secret key")
      hit.evidence.not_nil!.should_not contain("sk_live")
      sendgrid = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "SG.abcdefghijklmnop.qrstuvwxyz0123456789")
      sendgrid.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("SendGrid API key")
      npm = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "//registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwxyz0123456789")
      npm.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("npm access token")
      # a prose mention of "goroutine" (no `[state]:` header) must NOT trip.
      prose = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: "Launch a goroutine to handle each request.")
      probe_codes_of(prose).should_not contain("error_stack_leak")
    end
  end

  it "reports EVERY distinct secret and error type present in one body, not just the first" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
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
      es = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/search",
        method: "POST", req_headers: "Content-Type: application/json\r\n",
        req_body: %({"query":{"match":{"name":"x"}}}), content_type: nil)
      probe_codes_of(es).should_not contain("tech_graphql")
      gql = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/gw",
        method: "POST", req_headers: "Content-Type: application/json\r\n",
        req_body: %({"query":"{ me { id } }"}), content_type: nil)
      probe_codes_of(gql).should contain("tech_graphql")
    end
  end

  # The fingerprint's content-type gate was `json`, so a GraphQL request under the raw-document
  # type or as a urlencoded body was not GraphQL to it — the two shapes a JSON-content-type
  # filter is bypassed with, on an endpoint whose path does not say `/graphql`.
  it "fingerprints GraphQL under the content-types the JSON gate excluded" do
    with_store do |store|
      doc = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/gw",
        method: "POST", req_headers: "Content-Type: application/graphql\r\n",
        req_body: "query Me { me { id } }", content_type: nil)
      probe_codes_of(doc).should contain("tech_graphql")

      form = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/gw",
        method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "query=query+Me+%7B+me+%7D&variables=%7B%7D", content_type: nil)
      probe_codes_of(form).should contain("tech_graphql")
    end
  end

  it "keeps an ordinary form POST out of the GraphQL fingerprint" do
    with_store do |store|
      login = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/login",
        method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "user=a&pass=b", content_type: nil)
      probe_codes_of(login).should_not contain("tech_graphql")
      search = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/search",
        method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "query=shoes&page=2", content_type: nil) # a `query=` param is not a document
      probe_codes_of(search).should_not contain("tech_graphql")
    end
  end

  it "does not fingerprint an ordinary JSON POST with no query field as GraphQL" do
    with_store do |store|
      plain = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api/orders",
        method: "POST", req_headers: "Content-Type: application/json\r\n",
        req_body: %({"items":[{"id":1,"qty":2}],"note":"ship fast"}), content_type: nil)
      probe_codes_of(plain).should_not contain("tech_graphql")
    end
  end
end

describe "Gori::Probe::Passive (secret in URL)" do
  it "matches hyphen/underscore/case variants and benign-named JWT values" do
    with_store do |store|
      hyphen = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        target: "/cb?access-token=abc", content_type: nil)
      hit = hyphen.find(&.code.==("secret_in_url")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.should eq("access-token")

      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sigsigsig"
      under_benign = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        target: "/p?t=#{jwt}", content_type: nil)
      under_benign.find(&.code.==("secret_in_url")).not_nil!
        .severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "rates signed-URL params Low and ignores benign code/key params" do
    with_store do |store|
      sig = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?sig=xyz", content_type: nil)
      sig.find(&.code.==("secret_in_url")).not_nil!.severity.should eq(Gori::Store::Severity::Low)
      benign = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        target: "/list?code=42&key=pubMapsKey&page=2", content_type: nil)
      probe_codes_of(benign).should_not contain("secret_in_url")
    end
  end
end

describe "Gori::Probe::Passive (new patterns)" do
  it "flags reflected-origin CORS with credentials as High but stays quiet without them" do
    with_store do |store|
      reflected = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.example\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://evil.example\r\n", content_type: nil)
      hit = reflected.find(&.code.==("cors_reflected_origin")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)

      no_creds = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.example\r\n\r\n",
        req_headers: "Origin: https://evil.example\r\n", content_type: nil)
      probe_codes_of(no_creds).should_not contain("cors_reflected_origin")

      # A server echoing its OWN origin (same host) with credentials is legitimate — not flagged.
      same_origin = probe_analyze(store, host: "acme.test",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://acme.test\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://acme.test\r\n", content_type: nil)
      probe_codes_of(same_origin).should_not contain("cors_reflected_origin")
    end
  end

  it "flags a CROSS-SCHEME/CROSS-PORT same-host credentialed reflection (not just cross-host)" do
    with_store do |store|
      # Page is https://acme.test (:443); the reflected Origin is the SAME host but a different
      # scheme — genuinely a different origin, and exploitable with credentials.
      cross_scheme = probe_analyze(store, scheme: "https", host: "acme.test",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: http://acme.test\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: http://acme.test\r\n", content_type: nil)
      probe_codes_of(cross_scheme).should contain("cors_reflected_origin")
      cross_port = probe_analyze(store, scheme: "https", host: "acme.test",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://acme.test:8443\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://acme.test:8443\r\n", content_type: nil)
      probe_codes_of(cross_port).should contain("cors_reflected_origin")
      # A bracketed IPv6 literal echoing its OWN origin is same-origin — not a false positive.
      ipv6_same = probe_analyze(store, scheme: "https", host: "::1",
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://[::1]\r\n" \
                   "Access-Control-Allow-Credentials: true\r\n\r\n",
        req_headers: "Origin: https://[::1]\r\n", content_type: nil)
      probe_codes_of(ipv6_same).should_not contain("cors_reflected_origin")
    end
  end

  it "flags a CSP that restricts nothing about scripts (no script-src and no default-src)" do
    with_store do |store|
      # A CSP present but with neither script-src nor default-src leaves scripts fully
      # unrestricted, yet its mere presence suppresses missing_csp — it must trip weak_csp.
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: img-src 'self'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(dets).should contain("weak_csp")
      probe_codes_of(dets).should_not contain("missing_csp")
      # A restrictive default-src is NOT weak.
      ok = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self'\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(ok).should_not contain("weak_csp")
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
        dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html", body: prose)
        probe_codes_of(dets).should_not contain("error_stack_leak")
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
        dets = probe_analyze(store, resp_head: "HTTP/1.1 500 Server Error\r\n\r\n", status: 500,
          content_type: "text/html", body: leak)
        probe_codes_of(dets).should contain("error_stack_leak")
      end
    end
  end

  it "flags the null CORS origin" do
    with_store do |store|
      dets = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: null\r\n\r\n", content_type: nil)
      probe_codes_of(dets).should contain("cors_null_origin")
    end
  end

  it "flags a credential leaked in the response body (type only, never the value)" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", content_type: "text/html",
        body: %({"aws":"#{PROBE_AWS_KEY_ID}"}))
      hit = dets.find(&.code.==("secret_in_body")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.should eq("AWS access key id")
      hit.evidence.not_nil!.should_not contain("AKIA") # never the secret itself
    end
  end

  it "treats HSTS max-age=0 as disabled but a long max-age as present" do
    with_store do |store|
      disabled = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=0\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(disabled).should contain("missing_hsts")
      present = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=31536000\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(present).should_not contain("missing_hsts")
    end
  end

  describe "cacheable JSON API responses" do
    # The risk is a cache serving ONE user's data to another, so every case here authenticates.
    authed = "Cookie: sid=abc\r\n"

    it "flags application/json without Cache-Control (sensitive data may be stored)" do
      with_store do |store|
        dets = probe_analyze(store,
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
          probe_codes_of(probe_analyze(store, resp_head: head, content_type: "application/json",
            body: "{}", req_headers: authed)).should contain("cacheable_json")
        end
      end
    end

    # A public endpoint has nothing user-specific for a cache to leak, and leaving it cacheable is
    # a performance decision. Without this gate the rule fired on most 2xx JSON on most servers.
    it "does not flag an UNAUTHENTICATED response" do
      with_store do |store|
        probe_codes_of(probe_analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"public":true}))).should_not contain("cacheable_json")
      end
    end

    it "counts an Authorization request header or a Set-Cookie response as authenticated" do
      with_store do |store|
        probe_codes_of(probe_analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"me":1}),
          req_headers: "Authorization: Bearer x\r\n")).should contain("cacheable_json")
        probe_codes_of(probe_analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: sid=new\r\n\r\n",
          content_type: "application/json", body: %({"me":1}))).should contain("cacheable_json")
        # An empty Cookie header is not authentication.
        probe_codes_of(probe_analyze(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"me":1}),
          req_headers: "Cookie:  \r\n")).should_not contain("cacheable_json")
      end
    end

    it "does not flag when Cache-Control includes no-store" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
               "Cache-Control: no-store, no-cache, private, max-age=0\r\n\r\n"
        probe_codes_of(probe_analyze(store, resp_head: head, content_type: "application/json",
          body: %({"ok":true}), req_headers: authed)).should_not contain("cacheable_json")
      end
    end

    it "combines repeated Cache-Control fields instead of trusting the last one" do
      with_store do |store|
        vetoed = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Cache-Control: no-store\r\nCache-Control: public\r\n\r\n"
        probe_codes_of(probe_analyze(store, resp_head: vetoed, content_type: "application/json",
          body: %({"me":1}), req_headers: authed)).should_not contain("cacheable_json")

        cacheable = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                    "Cache-Control: public\r\nCache-Control: extension=value\r\n\r\n"
        probe_codes_of(probe_analyze(store, resp_head: cacheable, content_type: "application/json",
          body: %({"me":1}), req_headers: authed)).should contain("cacheable_json")
      end
    end

    it "does not read no-store from quoted extension data" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
               "Cache-Control: note=\"safe, no-store\", public\r\n\r\n"
        probe_codes_of(probe_analyze(store, resp_head: head, content_type: "application/json",
          body: %({"me":1}), req_headers: authed)).should contain("cacheable_json")
      end
    end

    it "does not flag HTML documents or empty JSON bodies" do
      with_store do |store|
        html = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
          content_type: "text/html", body: "<html></html>")
        probe_codes_of(html).should_not contain("cacheable_json")
        empty = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: nil)
        probe_codes_of(empty).should_not contain("cacheable_json")
      end
    end

    it "covers application/*+json (e.g. problem+json)" do
      with_store do |store|
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/problem+json\r\n\r\n"
        probe_codes_of(probe_analyze(store, resp_head: head, content_type: "application/problem+json",
          body: %({"title":"err"}), req_headers: authed)).should contain("cacheable_json")
      end
    end

    it "does not treat an arbitrary media type containing json as JSON" do
      with_store do |store|
        ["application/notjson", "text/jsonp", "image/json-icon"].each do |content_type|
          head = "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n\r\n"
          probe_codes_of(probe_analyze(store, resp_head: head, content_type: content_type,
            body: %({"me":1}), req_headers: authed)).should_not contain("cacheable_json")
        end
      end
    end
  end

  it "flags SameSite=None cookies missing Secure" do
    with_store do |store|
      insecure = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=x; SameSite=None\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(insecure).should contain("cookie_samesite_none_insecure")
      ok = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=x; SameSite=None; Secure\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(ok).should_not contain("cookie_samesite_none_insecure")
      probe_codes_of(ok).should_not contain("cookie_no_samesite")
    end
  end

  it "still flags a cookie literally named 'samesite' as missing the attribute" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: samesite=1; Path=/\r\n\r\n",
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
      maxage = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=; Max-Age=0\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(maxage).should_not contain("cookie_no_secure")
      probe_codes_of(maxage).should_not contain("cookie_no_httponly")
      probe_codes_of(maxage).should_not contain("cookie_no_samesite")
      expired = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=; expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(expired).should_not contain("cookie_no_httponly")
      # …but a LIVE empty cookie (no deletion marker) is still ordinary hygiene.
      live = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: foo=bar\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(live).should contain("cookie_no_secure")
    end
  end

  it "flags __Host-/__Secure- prefix violations and suppresses the duplicate no-secure issue" do
    with_store do |store|
      # __Host- requires Secure, Path=/, and no Domain — this one is missing Path=/.
      host_bad = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-sid=x; Secure\r\n\r\n",
        content_type: "text/html")
      hit = host_bad.find(&.code.==("cookie_prefix_violation")).not_nil!
      hit.evidence.not_nil!.should contain("Path=/")
      # A correctly-formed __Host- cookie is clean.
      host_ok = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-sid=x; Secure; Path=/\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(host_ok).should_not contain("cookie_prefix_violation")
      # A __Host- cookie with a Domain attribute is rejected by the browser.
      host_dom = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-sid=x; Secure; Path=/; Domain=acme.test\r\n\r\n",
        content_type: "text/html")
      host_dom.find(&.code.==("cookie_prefix_violation")).not_nil!.evidence.not_nil!.should contain("Domain")
      # __Secure- missing Secure trips the prefix violation but NOT the generic cookie_no_secure.
      sec_bad = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: __Secure-sid=x\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(sec_bad).should contain("cookie_prefix_violation")
      probe_codes_of(sec_bad).should_not contain("cookie_no_secure")
    end
  end
end

describe "Gori::Probe::Passive (GraphQL introspection)" do
  it "flags a response carrying an introspection result (full schema exposed)" do
    with_store do |store|
      introspection = probe_analyze(store, target: "/graphql", method: "POST",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", content_type: "application/json",
        body: %({"data":{"__schema":{"queryType":{"name":"Query"},"types":[{"name":"User"}]}}}))
      probe_codes_of(introspection).should contain("graphql_introspection")
      hit = introspection.find(&.code.==("graphql_introspection")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not flag ordinary GraphQL data or a stray __schema mention" do
    with_store do |store|
      # A normal query result has neither introspection marker.
      normal = probe_analyze(store, target: "/graphql", method: "POST",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", content_type: "application/json",
        body: %({"data":{"me":{"id":"1","name":"a"}}}))
      probe_codes_of(normal).should_not contain("graphql_introspection")
      # "__schema" alone (no queryType) is insufficient — keeps a docs/registry blob out.
      partial = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: %({"note":"see the __schema field docs"}))
      probe_codes_of(partial).should_not contain("graphql_introspection")
    end
  end
end

describe "Gori::Probe::Passive (insecure form action)" do
  it "flags a form on an HTTPS page that submits to a cleartext http:// action" do
    with_store do |store|
      insecure = probe_analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<form action="http://acme.test/login" method="post"><input name=pw></form>))
      probe_codes_of(insecure).should contain("insecure_form_action")
      # An https:// action (or a same-page relative action) is fine.
      secure = probe_analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<form action="https://acme.test/login"><input name=pw></form><form action="/x"></form>))
      probe_codes_of(secure).should_not contain("insecure_form_action")
    end
  end
end

describe "Gori::Probe::Passive (round-2 detection fixes)" do
  it "does not flag a data-src lazy-loading placeholder as active mixed content" do
    with_store do |store|
      # A hyphenated data-* attribute is not the real src attribute; `\b` alone treated
      # the hyphen as a word boundary and false-matched `data-src="http://…"`.
      lazy = probe_analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<iframe data-src="http://cdn.acme.test/lazy" src="https://cdn.acme.test/ok"></iframe>))
      probe_codes_of(lazy).should_not contain("mixed_content")
      # …a genuine active http:// sub-resource still trips it.
      real = probe_analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<script src="http://cdn.acme.test/evil.js"></script>))
      probe_codes_of(real).should contain("mixed_content")
    end
  end

  it "does not flag a data-action attribute as an insecure form action" do
    with_store do |store|
      lazy = probe_analyze(store, scheme: "https", content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<form data-action="http://acme.test/track" action="https://acme.test/login"></form>))
      probe_codes_of(lazy).should_not contain("insecure_form_action")
    end
  end

  it "treats a cookie cleared with a non-empty sentinel value and a past Expires as a deletion" do
    with_store do |store|
      # `auth=deleted; Expires=<past>` (no Max-Age, non-empty value) is a logout clear —
      # its missing flags are noise, not hygiene issues.
      cleared = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: auth=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(cleared).should_not contain("cookie_no_secure")
      probe_codes_of(cleared).should_not contain("cookie_no_httponly")
    end
  end

  it "flags a present-but-ineffective X-Frame-Options value (obsolete ALLOW-FROM)" do
    with_store do |store|
      ineffective = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nX-Frame-Options: ALLOW-FROM https://x.test\r\n\r\n")
      probe_codes_of(ineffective).should contain("missing_x_frame_options")
      # DENY / SAMEORIGIN actually restrict framing → no issue.
      deny = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nX-Frame-Options: DENY\r\n\r\n")
      probe_codes_of(deny).should_not contain("missing_x_frame_options")
    end
  end

  it "flags CSP-Report-Only without an enforcing CSP as csp_report_only (not missing_csp)" do
    with_store do |store|
      only_ro = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy-Report-Only: default-src 'self'\r\n\r\n")
      probe_codes_of(only_ro).should contain("csp_report_only")
      probe_codes_of(only_ro).should_not contain("missing_csp")
      # Enforcing CSP present → no report-only-only finding (even if R-O is also sent).
      both = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src 'self'\r\n" \
                   "Content-Security-Policy-Report-Only: default-src 'self'\r\n\r\n")
      probe_codes_of(both).should_not contain("csp_report_only")
      probe_codes_of(both).should_not contain("missing_csp")
    end
  end

  it "flags Referrer-Policy: unsafe-url as weak, not a strong policy" do
    with_store do |store|
      weak = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nReferrer-Policy: unsafe-url\r\n\r\n")
      probe_codes_of(weak).should contain("weak_referrer_policy")
      probe_codes_of(weak).should_not contain("missing_referrer_policy")
      ok = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nReferrer-Policy: strict-origin-when-cross-origin\r\n\r\n")
      probe_codes_of(ok).should_not contain("weak_referrer_policy")
      probe_codes_of(ok).should_not contain("missing_referrer_policy")
      # Browser default is ubiquitous — do not flag as weak.
      defaultish = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nReferrer-Policy: no-referrer-when-downgrade\r\n\r\n")
      probe_codes_of(defaultish).should_not contain("weak_referrer_policy")
    end
  end

  it "flags missing Permissions-Policy and high-risk features allowed for all origins" do
    with_store do |store|
      missing = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n")
      probe_codes_of(missing).should contain("missing_permissions_policy")
      # Restrictive modern policy → neither missing nor weak.
      ok = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nPermissions-Policy: camera=(), geolocation=(self)\r\n\r\n")
      probe_codes_of(ok).should_not contain("missing_permissions_policy")
      probe_codes_of(ok).should_not contain("weak_permissions_policy")
      # camera=* (and Feature-Policy geolocation *) → weak, with feature names as evidence.
      weak_pp = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nPermissions-Policy: camera=*, microphone=()\r\n\r\n")
      hit = weak_pp.find(&.code.==("weak_permissions_policy")).not_nil!
      hit.evidence.should eq("camera")
      weak_fp = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nFeature-Policy: geolocation *; camera 'none'\r\n\r\n")
      probe_codes_of(weak_fp).should contain("weak_permissions_policy")
      weak_fp.find(&.code.==("weak_permissions_policy")).not_nil!.evidence.should eq("geolocation")
      # Document-only: a 302 must not fire missing Permissions-Policy.
      redirect = probe_analyze(store, content_type: "text/html", status: 302,
        resp_head: "HTTP/1.1 302 Found\r\nLocation: /home\r\n\r\n")
      probe_codes_of(redirect).should_not contain("missing_permissions_policy")
    end
  end

  it "flags HSTS max-age under 1 day as short_hsts but not as missing" do
    with_store do |store|
      short = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=60\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(short).should contain("short_hsts")
      probe_codes_of(short).should_not contain("missing_hsts")
      short.find(&.code.==("short_hsts")).not_nil!.evidence.should eq("max-age=60")
      long = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=31536000\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(long).should_not contain("short_hsts")
      probe_codes_of(long).should_not contain("missing_hsts")
      # max-age=0 remains missing/disabled, not short.
      disabled = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=0\r\n\r\n",
        content_type: "text/html")
      probe_codes_of(disabled).should contain("missing_hsts")
      probe_codes_of(disabled).should_not contain("short_hsts")
    end
  end
end

describe "Gori::Probe::Passive (insecure Basic auth)" do
  it "flags request Basic credentials over cleartext HTTP as High" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", scheme: "http",
        req_headers: "Authorization: Basic dXNlcjpwYXNz\r\n", content_type: nil)
      hit = dets.find(&.code.==("insecure_basic_auth")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.not_nil!.should_not contain("dXNlcjpwYXNz") # never the credential itself
    end
  end

  it "flags a WWW-Authenticate: Basic challenge over cleartext HTTP as Medium" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\n\r\n",
        status: 401, scheme: "http", content_type: nil)
      hit = dets.find(&.code.==("insecure_basic_auth")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not flag Basic auth over HTTPS (transport-protected) or non-Basic schemes" do
    with_store do |store|
      https = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", scheme: "https",
        req_headers: "Authorization: Basic dXNlcjpwYXNz\r\n", content_type: nil)
      probe_codes_of(https).should_not contain("insecure_basic_auth")
      bearer = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", scheme: "http",
        req_headers: "Authorization: Bearer token123\r\n", content_type: nil)
      probe_codes_of(bearer).should_not contain("insecure_basic_auth")
    end
  end
end

describe "Gori::Probe::Passive (Round-1 hardening)" do
  it "resolves duplicate CSP directives first-wins (matches browser enforcement)" do
    with_store do |store|
      # First script-src is safe; the duplicate must be IGNORED, so this is not weak.
      safe = probe_analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n" \
                                                                        "Content-Security-Policy: script-src 'self'; script-src 'unsafe-inline'\r\n\r\n")
      probe_codes_of(safe).should_not contain("weak_csp")
      # First script-src is unsafe-inline; a later 'self' duplicate must not mask it.
      weak = probe_analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n" \
                                                                        "Content-Security-Policy: script-src 'unsafe-inline'; script-src 'self'\r\n\r\n")
      probe_codes_of(weak).should contain("weak_csp")
    end
  end

  it "suppresses hygiene for sentinel-value and negative-Max-Age deletion cookies" do
    with_store do |store|
      # PHP clears cookies with the literal value "deleted" (not empty) + Max-Age=0.
      php = probe_analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n" \
                                                                       "Set-Cookie: PHPSESSID=deleted; Max-Age=0; expires=Thu, 01-Jan-1970 00:00:00 GMT; path=/\r\n\r\n")
      probe_codes_of(php).should_not contain("cookie_no_secure")
      probe_codes_of(php).should_not contain("cookie_no_httponly")
      neg = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=; Max-Age=-1\r\n\r\n")
      probe_codes_of(neg).should_not contain("cookie_no_samesite")
      # …but a live cookie with a positive Max-Age is still scored.
      live = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc; Max-Age=3600\r\n\r\n")
      probe_codes_of(live).should contain("cookie_no_secure")
    end
  end

  it "flags a Basic challenge listed after another scheme in one WWW-Authenticate header" do
    with_store do |store|
      dets = probe_analyze(store, scheme: "http", content_type: nil, status: 401,
        resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Negotiate, Basic realm=\"x\"\r\n\r\n")
      dets.find(&.code.==("insecure_basic_auth")).not_nil!.severity.should eq(Gori::Store::Severity::Medium)
      none = probe_analyze(store, scheme: "http", content_type: nil, status: 401,
        resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Negotiate, Digest realm=\"x\"\r\n\r\n")
      probe_codes_of(none).should_not contain("insecure_basic_auth")
    end
  end

  it "flags PGP and PKCS#8-encrypted private key blocks (not just RSA/EC)" do
    with_store do |store|
      pgp = probe_analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF...\n-----END PGP PRIVATE KEY BLOCK-----")
      pgp.find(&.code.==("secret_in_body")).not_nil!.evidence.should eq("private key block")
      enc = probe_analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF...\n-----END ENCRYPTED PRIVATE KEY-----")
      probe_codes_of(enc).should contain("secret_in_body")
    end
  end

  it "does not flag a 4-part software version as a private IP but still catches a real leak" do
    with_store do |store|
      json = probe_analyze(store, content_type: "application/json",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n", body: %({"version":"10.0.0.0"}))
      probe_codes_of(json).should_not contain("private_ip_leak")
      htmlv = probe_analyze(store, content_type: "text/html",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n", body: "<span>File version 10.0.1.2</span>")
      probe_codes_of(htmlv).should_not contain("private_ip_leak")
      # a genuine private IP after a version-shaped token is still surfaced (scan, not first-match).
      mixed = probe_analyze(store, content_type: "text/html", resp_head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "<p>build version 10.0.1.2</p><p>backend at 192.168.1.5</p>")
      mixed.find(&.code.==("private_ip_leak")).not_nil!.evidence.should eq("192.168.1.5")
    end
  end

  it "anchors GraphQL introspection on the result envelope, not raw substrings" do
    with_store do |store|
      # An echoed introspection QUERY string carries both tokens but is not a result -> no FP.
      echoed = probe_analyze(store, content_type: "application/json",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        body: %({"data":{"savedQuery":"query IntrospectionQuery { __schema { queryType { name } } }"}}))
      probe_codes_of(echoed).should_not contain("graphql_introspection")
      # A real introspection envelope is flagged even when queryType is absent from the prefix.
      env = probe_analyze(store, content_type: "application/json",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        body: %({"data":{"__schema":{"types":[{"name":"User"}]}}}))
      probe_codes_of(env).should contain("graphql_introspection")
    end
  end
end

describe "Gori::Probe::Passive (shared body decode)" do
  it "decodes a compressed HTML body once yet feeds both body_text and the client rules" do
    with_store do |store|
      # An HTML document with a body-text finding (leaked AWS key → BodyLeaks, uses body_text)
      # AND a client-rule finding (source→sink in an inline script → DomXss, uses client_body_text).
      # Both must still fire when the body is gzip-encoded, proving the single shared inflate
      # (Context#decoded_body) feeds both getters correctly.
      plain = "<html><script>document.write(location.hash)</script>" \
              "<p>key #{PROBE_AWS_KEY_ID} here</p></html>"
      gz = IO::Memory.new
      Compress::Gzip::Writer.open(gz) { |w| w.write(plain.to_slice) }
      dets = probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
        content_type: "text/html", body: String.new(gz.to_slice))
      probe_codes_of(dets).should contain("secret_in_body") # body_text path
      probe_codes_of(dets).should contain("dom_xss")        # client_body_text path
    end
  end
end

describe "Gori::Probe::Passive::Tech (framework fingerprints)" do
  it "fingerprints React from the response body" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, %(<html><body data-reactroot=""><div id="root"></div></body></html>))).should contain("tech_react")
    end
  end

  it "fingerprints jQuery and captures its version" do
    with_store do |store|
      dets = probe_analyze_html(store, %(<html><head><script src="/assets/jquery-3.4.1.min.js"></script></head></html>))
      hit = dets.find(&.code.==("tech_jquery")).not_nil!
      hit.evidence.should eq("3.4.1")
    end
  end
end

describe "Gori::Probe::Passive::SecretInUrl (JWT tightening)" do
  it "still flags a full JWT in the query but not a short dotted value" do
    with_store do |store|
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?tok=#{PROBE_JWT}")).should contain("secret_in_url")
      # Long first two segments but a 1-char signature: the old `[...]+` tail false-matched this.
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/cb?data=eyJhbGciOiJIUzI1.eyJzdWIiOiIx.z")).should_not contain("secret_in_url")
    end
  end
end
