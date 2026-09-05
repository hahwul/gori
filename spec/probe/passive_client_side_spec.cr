require "../spec_helper"
require "../support/probe_harness"

# Wrap a JS snippet in an HTML document so it reaches the client-side rules as an inline script.
private def html_with_script(js : String) : String
  "<!doctype html><html><head></head><body><script>#{js}</script></body></html>"
end

private def analyze_js(store, body : String)
  probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n\r\n",
    content_type: "application/javascript", body: body)
end

# Two statements, a string literal holding a sink and a comment holding a source, no
# trailing newline (the stripper must return the same size it was given).
private STRIP_SAMPLE = <<-JS.chomp
  a = "el.innerHTML=location.hash"; // note document.cookie
  b = location.search;
  JS

describe Gori::Probe::Passive::JsScan do
  it "blanks string literals and comments but keeps code" do
    stripped = Gori::Probe::Passive::JsScan.strip(STRIP_SAMPLE)
    # Tokens that lived inside a string or a comment are gone...
    stripped.includes?("el.innerHTML").should be_false
    stripped.includes?("document.cookie").should be_false
    # ...but real code (identifiers outside strings/comments) survives, offsets preserved.
    stripped.includes?("location.search").should be_true
    stripped.size.should eq(STRIP_SAMPLE.size)
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
      dets = probe_analyze_html(store, html_with_script("document.getElementById('o').innerHTML = location.hash;"))
      hit = dets.find(&.code.==("dom_xss")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::Medium)
      hit.category.should eq("client")
      hit.evidence.not_nil!.should contain("→")
    end
  end

  it "flags document.write / eval / setTimeout in a JS bundle" do
    with_store do |store|
      probe_codes_of(analyze_js(store, "document.write(location.search);")).should contain("dom_xss")
      probe_codes_of(analyze_js(store, "eval('x'+document.referrer);")).should contain("dom_xss")
    end
  end

  it "does not flag a sink inside a comment or a string, or a bare sink" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, html_with_script("// el.innerHTML = location.hash"))).should_not contain("dom_xss")
      probe_codes_of(probe_analyze_html(store, html_with_script(%(log("el.innerHTML = location.hash"))))).should_not contain("dom_xss")
      probe_codes_of(probe_analyze_html(store, html_with_script("el.innerHTML = 'static markup';"))).should_not contain("dom_xss")
    end
  end
end

describe Gori::Probe::Passive::DomClobbering do
  it "flags named HTMLCollection access and the window-global fallback idiom" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, html_with_script("var f = document.forms['login'];"))).should contain("dom_clobbering")
      probe_codes_of(probe_analyze_html(store, html_with_script("window.cfg = window.cfg || {};"))).should contain("dom_clobbering")
    end
  end

  it "does not flag ordinary DOM lookups" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, html_with_script("var a = document.getElementById('a');"))).should_not contain("dom_clobbering")
    end
  end
end

describe Gori::Probe::Passive::PrototypePollution do
  it "flags a prototype-key write and pollution-prone merge APIs" do
    with_store do |store|
      probe_codes_of(analyze_js(store, "obj.__proto__ = evil;")).should contain("prototype_pollution")
      probe_codes_of(analyze_js(store, "$.extend(true, target, src);")).should contain("prototype_pollution")
    end
  end

  it "flags a __proto__ parameter in the request" do
    with_store do |store|
      dets = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: "/api?__proto__[polluted]=1")
      probe_codes_of(dets).should contain("prototype_pollution_param")
    end
  end

  it "does not flag ordinary object code or a clean request" do
    with_store do |store|
      dets = analyze_js(store, "var o = {}; o.foo = 1;")
      probe_codes_of(dets).should_not contain("prototype_pollution")
      probe_codes_of(dets).should_not contain("prototype_pollution_param")
    end
  end
end

describe Gori::Probe::Passive::PostMessage do
  it "flags a message handler with no origin check" do
    with_store do |store|
      js = %(window.addEventListener("message", function(e){ handle(e.data); });)
      probe_codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "does not flag a handler that validates the origin" do
    with_store do |store|
      js = %(window.addEventListener("message", function(e){ if (e.origin === "https://x") handle(e.data); });)
      probe_codes_of(analyze_js(store, js)).should_not contain("postmessage_no_origin")
    end
  end

  # The origin test used to run over the WHOLE fragment, so one unrelated `.origin` anywhere in a
  # bundle suppressed every finding in it — the rule detected nothing on real bundles.
  it "still flags an unchecked handler when an unrelated .origin exists elsewhere in the bundle" do
    with_store do |store|
      js = %(var o = location.origin + "/api";) + ("var pad1;" * 5) +
           %(window.addEventListener("message", function(e){ handle(e.data); });)
      probe_codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "judges each handler separately — a checked one does not vouch for an unchecked one" do
    with_store do |store|
      checked = %(window.addEventListener("message", function(e){ if (e.origin === "https://x") a(e.data); });)
      unchecked = %(window.addEventListener("message", function(e){ b(e.data); });)
      probe_codes_of(analyze_js(store, checked + unchecked)).should contain("postmessage_no_origin")
      probe_codes_of(analyze_js(store, checked + checked)).should_not contain("postmessage_no_origin")
    end
  end

  # A handler passed by NAME has its body elsewhere, so no window around the call site can say
  # whether it checks the origin — guessing there would be a false positive.
  it "does not judge a handler passed by name (body not visible here)" do
    with_store do |store|
      js = %(function onMsg(e){ handle(e.data); } window.addEventListener("message", onMsg);)
      probe_codes_of(analyze_js(store, js)).should_not contain("postmessage_no_origin")
    end
  end

  it "flags an arrow-function handler with no origin check" do
    with_store do |store|
      js = %(window.addEventListener("message", (e) => { handle(e.data); });)
      probe_codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "does not flag an origin check that sits far past the handler window" do
    with_store do |store|
      js = %(window.onmessage = function(e){ ) + ("noop();" * 400) + %( if (e.origin) ok(); };)
      # The check is beyond HANDLER_WINDOW, so the handler reads as unchecked — the deliberate
      # cost of scoping the test to a window rather than the whole fragment.
      probe_codes_of(analyze_js(store, js)).should contain("postmessage_no_origin")
    end
  end

  it "flags a wildcard target origin and document.domain relaxation" do
    with_store do |store|
      probe_codes_of(analyze_js(store, %(parent.postMessage(payload, "*");))).should contain("postmessage_wildcard")
      probe_codes_of(analyze_js(store, %(document.domain = "example.com";))).should contain("document_domain_set")
    end
  end
end

describe "Gori::Probe::Passive::BodyLeaks (client-side HTML sinks)" do
  it "flags a javascript: URL but not the void(0) no-op" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, %(<a href="javascript:alert(1)">x</a>))).should contain("inline_js_uri")
      probe_codes_of(probe_analyze_html(store, %(<a href="javascript:void(0)">x</a>))).should_not contain("inline_js_uri")
    end
  end

  it "flags passive mixed content and reverse-tabnabbing links" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, %(<img src="http://cdn.example/x.png">))).should contain("mixed_passive")
      probe_codes_of(probe_analyze_html(store, %(<a target="_blank" href="http://x/">x</a>))).should contain("reverse_tabnabbing")
      probe_codes_of(probe_analyze_html(store, %(<a target="_blank" rel="noopener" href="http://x/">x</a>))).should_not contain("reverse_tabnabbing")
    end
  end

  # ANCHOR_BLANK is /i, so it matches uppercase markup; the rel suppression must be too, or the
  # very attribute that makes the tag safe goes unrecognised.
  it "recognises rel=noopener/noreferrer regardless of case" do
    with_store do |store|
      [%(<a TARGET="_blank" REL="NOOPENER" href="/x">x</a>),
       %(<a Target="_blank" Rel="NoReferrer" href="/x">x</a>),
       %(<a target="_blank" rel="NOREFERRER NOOPENER" href="/x">x</a>)].each do |tag|
        probe_codes_of(probe_analyze_html(store, tag)).should_not contain("reverse_tabnabbing"), tag
      end
    end
  end

  # Browsers have defaulted target=_blank to noopener since 2021, so this is markup hygiene,
  # not a vulnerability — an external link is on nearly every page.
  it "reports reverse-tabnabbing at Info, not Low" do
    with_store do |store|
      d = probe_analyze_html(store, %(<a target="_blank" href="http://x/">x</a>))
        .find(&.code.== "reverse_tabnabbing")
      d.not_nil!.severity.should eq(Gori::Store::Severity::Info)
    end
  end
end

describe "Gori::Probe::Passive::Secrets (client-side shapes)" do
  it "flags a Slack webhook embedded in a JS bundle" do
    with_store do |store|
      hook = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
      probe_codes_of(analyze_js(store, "var w = '#{hook}';")).should contain("secret_in_body")
    end
  end

  # A JWT is the one shape in this family an app legitimately hands its own client, so it is
  # NOT a High secret_in_body — it gets its own Info code (see Secrets::JWT).
  it "reports a JWT as Info jwt_in_body, never as a High secret_in_body" do
    with_store do |store|
      dets = analyze_js(store, "var t = '#{PROBE_JWT}';")
      probe_codes_of(dets).should_not contain("secret_in_body")
      d = dets.find(&.code.== "jwt_in_body").not_nil!
      d.severity.should eq(Gori::Store::Severity::Info)
      d.category.should eq(Gori::Probe::Category::INFOLEAK)
    end
  end

  # The High tier must still fire on the shapes a server has no business sending a browser,
  # and a body carrying BOTH must report both — the JWT split must not swallow the real leak.
  it "still reports a High secret_in_body alongside the JWT note" do
    with_store do |store|
      dets = analyze_js(store, "var k='#{PROBE_AWS_KEY_ID}',t='#{PROBE_JWT}';")
      sec = dets.find(&.code.== "secret_in_body").not_nil!
      sec.severity.should eq(Gori::Store::Severity::High)
      sec.evidence.should eq("AWS access key id")
      probe_codes_of(dets).should contain("jwt_in_body")
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
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: body)).should contain("mixed_content")
    end
  end

  it "finds an insecure form action past the 64 KiB prefix" do
    with_store do |store|
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: padded.call(%(<form action="http://acme.test/login">)))).should contain("insecure_form_action")
    end
  end

  # The prefilters are ASCII case-INSENSITIVE byte scans; a case-sensitive includes? would have
  # silently stopped matching the uppercase markup the /i regexes were written to catch.
  it "still matches uppercase markup through the literal prefilters" do
    with_store do |store|
      found = probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        body: %(<A TARGET="_BLANK" HREF="/x">x</A><IMG SRC="HTTP://acme.test/i.png">)))
      found.should contain("reverse_tabnabbing")
      found.should contain("mixed_passive")
    end
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
      probe_codes_of(probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: body)).should contain("secret_in_body")
    end
  end

  # The Google fixtures below are ASSEMBLED from parts rather than written as one literal.
  # They are invented values, but GitHub's push protection matches the shapes on sight and
  # rejects the push; splitting them keeps the raw file free of a contiguous match while the
  # runtime strings the patterns see are exactly what a real response would carry.
  private_google_client_id = "123456789012-" + ("abcdefghij0123456789abcdefghij01" + ".apps.googleusercontent.com")
  private_google_secret = "GOCSPX" + "-" + "abcdefghijklmnopqrstuvwxyz12"

  # Membership in PATTERNS means "a server has no business sending this to a browser". Two
  # shapes that a site is SUPPOSED to publish were in it, and each fired High on every site
  # using the product — the same failure the JWT split fixed one tier up.
  it "does not flag shapes a site publishes to its own client on purpose" do
    # A Google OAuth client id rides in the authorization URL of every Google Sign-In redirect.
    private_hit.call(%(client_id: "#{private_google_client_id}")).should be_empty
    # Mapbox `pk.` is the public token, documented as safe to embed in client-side JS.
    private_hit.call("mapboxgl.accessToken = 'pk.eyJ1IjoiYWNtZXRlc3RpbmciLCJhIjoiY20wMDAwMDAwIn0.Zm9vYmFyYmF6cXV4MTIzNA';")
      .should be_empty
  end

  # Dropping the public client id must not drop the pair's actual credential.
  it "flags the Google OAuth client SECRET" do
    private_hit.call(private_google_secret).should contain("Google OAuth client secret")
  end

  it "still flags the Mapbox SECRET token" do
    private_hit.call("sk.eyJ1IjoiYWNtZXRlc3RpbmciLCJhIjoiY20wMDAwMDAwIn0.Zm9vYmFyYmF6cXV4MTIzNA")
      .should contain("Mapbox secret token")
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

  # `source_spans` no longer runs one scan per SOURCES entry: the nine entries sharing a
  # `location.` / `document.` prefix are found by two factored scans and bucketed by their
  # capture. Every label must still be reachable and still be reported under its own name —
  # a mis-wired bucket would silently relabel a finding (or drop a source entirely) while the
  # coarse "is it empty" assertions above stayed green.
  it "reports every taint source under its own label" do
    {
      "location.hash"        => %(location.hash),
      "location.search"      => %(location.search),
      "location.href"        => %(location.href),
      "document.URL"         => %(document.URL),
      "document.documentURI" => %(document.documentURI),
      "document.baseURI"     => %(document.baseURI),
      "document.referrer"    => %(document.referrer),
      "document.cookie"      => %(document.cookie),
      "document.location"    => %(document.location),
      "window.name"          => %(window.name),
      "history.state"        => %(history.state),
      "postMessage data"     => %(evt.data),
      "web storage"          => %(localStorage.getItem("k")),
    }.each do |label, expr|
      pairs = private_pairs.call(%(o.innerHTML = #{expr};))
      pairs.map(&.[0]).should contain(label)
    end
    # `location.pathname` shares the `location.href` bucket by design.
    private_pairs.call(%(o.innerHTML = location.pathname;)).map(&.[0]).should contain("location.href")
  end

  # The factored scan splits SOURCES between SOURCE_SCANS (bucketed by capture) and
  # SOLO_SOURCES (scanned individually). SOLO_SOURCES is derived, so this pins the invariant
  # that makes deriving it correct: the two together cover every entry exactly once. A gap
  # here is silent — the uncovered source's bucket just stays empty forever.
  it "covers every SOURCES entry exactly once across the factored and solo scans" do
    factored = [] of Int32
    Gori::Probe::Passive::JsScan::SOURCE_SCANS.each do |(_, slots)|
      slots.each_value { |i| factored << i }
    end
    covered = (factored + Gori::Probe::Passive::JsScan::SOLO_SOURCES).uniq.sort!
    covered.should eq((0...Gori::Probe::Passive::JsScan::SOURCES.size).to_a)
    (factored & Gori::Probe::Passive::JsScan::SOLO_SOURCES).should be_empty
  end

  # SOURCES order is the priority with which a statement carrying several sources is labelled,
  # and factoring must not quietly reorder it: `document.URL` (entry 4) outranks
  # `document.cookie` (entry 8) no matter which one appears first in the text.
  it "keeps SOURCES order as the label priority when a statement carries several sources" do
    private_pairs.call(%(o.innerHTML = document.cookie + document.URL;))
      .map(&.[0]).should contain("document.URL")
  end
end
