require "../spec_helper"
require "../support/probe_harness"

describe Gori::Probe::Passive::ExposedConfig do
  private_plain = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
  private_html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"

  it "flags a served .git/config" do
    with_store do |store|
      body = "[core]\n\trepositoryformatversion = 0\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n"
      dets = probe_analyze(store, resp_head: private_plain, content_type: "text/plain", body: body)
      hit = dets.find(&.code.==("exposed_config")).not_nil!
      hit.evidence.should eq(".git/config")
      hit.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "flags a served .env but not an HTML page documenting the same keys" do
    with_store do |store|
      env = "APP_ENV=production\nDB_PASSWORD=s3cr3t-value\nMAIL_PASSWORD=hunter2\n"
      probe_codes_of(probe_analyze(store, resp_head: private_plain, content_type: "text/plain", body: env))
        .should contain("exposed_config")
      # The same key names inside a deployment guide are documentation, not the file.
      doc = "<html><body><pre>DB_PASSWORD=your-password-here</pre><p>Set these in .env</p></body></html>"
      probe_codes_of(probe_analyze(store, resp_head: private_html, content_type: "text/html", body: doc))
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
        hit = probe_analyze(store, resp_head: head, content_type: ct, body: body).find(&.code.==("exposed_config"))
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
        probe_codes_of(probe_analyze(store, resp_head: private_html, content_type: "text/html", body: prose))
          .should_not contain("exposed_config")
      end
    end
  end

  it "ignores a non-2xx page that echoes the requested path" do
    with_store do |store|
      body = "[core]\n\trepositoryformatversion = 0\n"
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\n",
        content_type: "text/plain", body: body, status: 404)).should_not contain("exposed_config")
    end
  end

  it "accumulates every artifact a host serves rather than pinning to the first" do
    with_store do |store|
      git = probe_analyze(store, resp_head: private_plain, content_type: "text/plain",
        target: "/.git/config", body: "[core]\n\trepositoryformatversion = 0\n")
      env = probe_analyze(store, resp_head: private_plain, content_type: "text/plain",
        target: "/.env", body: "DB_PASSWORD=s3cr3t-value\n")
      (git + env).each { |d| store.upsert_probe_issue(d) }
      ev = store.probe_issues.find(&.code.==("exposed_config")).not_nil!.evidence.not_nil!
      ev.should contain(".git/config")
      ev.should contain(".env file")
    end
  end
end

describe Gori::Probe::Passive::SerializedObject do
  html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"

  it "flags a Java serialized object carried in a request cookie (Medium)" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: html,
        req_headers: "Cookie: session=rO0ABXNyEXAMPLEabcdef\r\n")
      hit = dets.find(&.code.==("serialized_object")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
      hit.evidence.not_nil!.should eq("Java serialized object in cookie 'session'")
    end
  end

  it "flags a .NET BinaryFormatter blob in a query parameter (Medium)" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: html, target: "/p?state=AAEAAAD/////AQAAAAAAAAAM")
      hit = dets.find(&.code.==("serialized_object")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
      hit.evidence.not_nil!.should eq(".NET BinaryFormatter object in parameter 'state'")
    end
  end

  it "flags an unencrypted ASP.NET ViewState hidden field in the response (Low)" do
    with_store do |store|
      body = %(<form><input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="/wEPDwUKLTEyMzQ1Njc4ZGQ=" /></form>)
      hit = probe_analyze(store, resp_head: html, body: body).find(&.code.==("serialized_object")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Low)
      hit.evidence.not_nil!.should eq("ASP.NET ViewState (unencrypted) in __VIEWSTATE field")
    end
  end

  it "flags a PHP serialized object in a percent-encoded form body (Medium)" do
    with_store do |store|
      body = "data=O%3A4%3A%22User%22%3A1%3A%7Bs%3A2%3A%22id%22%3Bi%3A1%3B%7D"
      dets = probe_analyze(store, resp_head: html, method: "POST", req_body: body,
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n")
      hit = dets.find(&.code.==("serialized_object")).not_nil!
      hit.evidence.not_nil!.should eq("PHP serialized object in parameter 'data'")
    end
  end

  it "does not flag ordinary base64 or path values that merely resemble a marker" do
    with_store do |store|
      # A lowercase /web path (not the /wE ViewState marker) and an unrelated base64 token.
      probe_codes_of(probe_analyze(store, resp_head: html,
        req_headers: "Cookie: theme=/web/home; token=YWJjZGVmZ2hpamtsbW5vcA==\r\n"))
        .should_not contain("serialized_object")
    end
  end

  # The field name in the evidence must come from the tag that MATCHED, not from a whole-body
  # substring test: a page can mention the JSF field in a script while the input actually
  # carrying the blob is the ASP.NET one, and the finding then names the wrong framework.
  it "labels the ViewState field from the matching tag, not from elsewhere in the body" do
    with_store do |store|
      body = %(<script>var k = "javax.faces.ViewState";</script>) \
             %(<form><input type="hidden" name="__VIEWSTATE" value="/wEPDwUKLTEyMzQ1Njc4ZGQ=" /></form>)
      hit = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        content_type: "text/html", body: body).find(&.code.==("serialized_object")).not_nil!
      hit.evidence.not_nil!.should contain("__VIEWSTATE field")
      hit.evidence.not_nil!.should_not contain("javax.faces")
    end
  end

  # The gate is /i so a lowercase field is still seen, but it names the FIELDS rather than a
  # bare `viewstate` substring — `viewState` is an everyday React/deck.gl prop name, and
  # matching it would walk every such bundle through the backtracking tag scan.
  it "sees a lowercase __viewstate field but ignores a plain viewState identifier" do
    with_store do |store|
      lower = %(<form><input type="hidden" name="__viewstate" value="/wEPDwUKLTEyMzQ1Njc4ZGQ=" /></form>)
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        content_type: "text/html", body: lower)).should contain("serialized_object")
      spa = %(<html><body><script>const {viewState} = props; setViewState(viewState);</script></body></html>)
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        content_type: "text/html", body: spa)).should_not contain("serialized_object")
    end
  end

  it "does not flag an ENCRYPTED ViewState (opaque base64 that is not /wE — encryption is the fix)" do
    with_store do |store|
      body = %(<form><input type="hidden" name="__VIEWSTATE" value="AbCdEf0123456789+/xyz=" /></form>)
      probe_codes_of(probe_analyze(store, resp_head: html, body: body)).should_not contain("serialized_object")
    end
  end

  it "accumulates every serialized surface a host exposes, keeping the higher severity" do
    with_store do |store|
      req = probe_analyze(store, resp_head: html, target: "/a",
        req_headers: "Cookie: s=rO0ABXNyEXAMPLE\r\n")
      resp = probe_analyze(store, resp_head: html, target: "/b",
        body: %(<input name="__VIEWSTATE" value="/wEPDwUKLTEyMzQ1Njc4" />))
      (req + resp).each { |d| store.upsert_probe_issue(d) }
      issue = store.probe_issues.find(&.code.==("serialized_object")).not_nil!
      issue.severity.should eq(Gori::Store::Severity::Medium) # request-side wins
      ev = issue.evidence.not_nil!
      ev.should contain("Java serialized object in cookie 's'")
      ev.should contain("ASP.NET ViewState (unencrypted) in __VIEWSTATE field")
    end
  end
end

describe Gori::Probe::Passive::DebugModeExposed do
  it "flags the Symfony profiler via the X-Debug-Token header regardless of content type" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Debug-Token: 7c1f9a\r\n\r\n"
      hit = probe_analyze(store, resp_head: head, content_type: "application/json",
        body: "{}").find(&.code.==("debug_mode_exposed")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
      hit.evidence.not_nil!.should eq("Symfony profiler (X-Debug-Token header)")
    end
  end

  # The one prefilter this rule keeps must be case-INSENSITIVE, because the pattern behind it
  # is: a case-sensitive gate silently drops uppercased markup and loses a High RCE finding.
  it "flags a Rails web-console page whose markup is uppercased" do
    with_store do |store|
      body = %(<HTML><BODY><DIV ID="CONSOLE-9F2A"></DIV></BODY></HTML>)
      hit = probe_analyze(store, resp_head: "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n",
        status: 500, body: body).find(&.code.==("debug_mode_exposed")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.not_nil!.should eq("Rails web-console")
    end
  end

  it "flags a Werkzeug interactive debugger as High (it is an RCE console)" do
    with_store do |store|
      body = "<html><head><title>Error // Werkzeug Debugger</title></head><body>Traceback</body></html>"
      hit = probe_analyze(store, resp_head: "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n",
        status: 500, body: body).find(&.code.==("debug_mode_exposed")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.not_nil!.should eq("Werkzeug interactive debugger")
    end
  end

  it "flags a Django DEBUG=True technical error page (Medium)" do
    with_store do |store|
      body = "<html><body><table><tr><th>Django Version:</th><td>4.2.1</td></tr></table></body></html>"
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n",
        status: 500, body: body)).should contain("debug_mode_exposed")
    end
  end

  it "flags an ASP.NET DETAILED error but not the safe remote page that hides them" do
    with_store do |store|
      detailed = "<html><body><h2>Server Error in '/' Application.</h2>Stack Trace: at App.Foo()</body></html>"
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n",
        status: 500, body: detailed)).should contain("debug_mode_exposed")
      safe = "<html><body><h2>Server Error in '/' Application.</h2>Runtime Error. The current custom " \
             "error settings for this application prevent the details of the application error from " \
             "being viewed remotely.</body></html>"
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n",
        status: 500, body: safe)).should_not contain("debug_mode_exposed")
    end
  end

  it "does not flag prose that merely names a framework, nor a non-HTML body" do
    with_store do |store|
      prose = "<html><body>We build on the Werkzeug library and the Django framework.</body></html>"
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", body: prose))
        .should_not contain("debug_mode_exposed")
      # A JSON API body carrying the same string is not a rendered debug page.
      json = %({"note":"Django Version: 4.2 required"})
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: json)).should_not contain("debug_mode_exposed")
    end
  end
end
