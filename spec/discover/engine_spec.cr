require "../spec_helper"

private alias D = Gori::Discover
private alias R = Gori::Repeater::Result

# A backend that routes crafted responses by request target (path+query). Unknown paths —
# including the random bogus paths the soft-404 calibrator sends — fall through to `default`.
private class RouteBackend < D::Backend
  def initialize(@route : String -> R)
  end

  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    @route.call(target)
  end
end

# Records the HOST of every fetch, not just the target — the only way to see what would have
# gone onto a CONNECT line (`Upstream.dial_via_proxy` builds it from this argument).
private class HostRecordingBackend < D::Backend
  def initialize(@hosts : Array(String), @route : String -> R)
  end

  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    @hosts << host
    @route.call(target)
  end
end

# Drive an engine to completion and return {terminal event kinds, error messages}. The KINDS
# list is what distinguishes a terminal error from an error followed by a success Done.
private def terminal_of(engine : D::Engine) : {Array(Symbol), Array(String)}
  kinds = [] of Symbol
  messages = [] of String
  engine.run do |ev|
    case ev
    when D::ErrorEvent then kinds << :error; messages << ev.message
    when D::DoneEvent  then kinds << :done
    end
  end
  {kinds, messages}
end

private def make(status : Int32, body : String, ctype : String? = "text/html", location : String? = nil) : R
  head = String.build do |s|
    s << "HTTP/1.1 " << status << " X\r\n"
    s << "Content-Type: " << ctype << "\r\n" if ctype
    s << "Location: " << location << "\r\n" if location
    s << "Content-Length: " << body.bytesize << "\r\n\r\n"
  end.to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  R.new(head, body.to_slice, resp, 1000_i64)
end

private def html(body : String) : R
  make(200, body)
end

# A backend whose every fetch raises — exercises the worker's rescue path (Bug A): a raise
# must become an error Outcome, never drop the task and hang the run.
private class RaisingBackend < D::Backend
  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    raise "backend boom"
  end
end

private def notfound : R
  make(404, "not found here")
end

# Allows every url but records the exact string each Layer-2 gate is asked about — so a spec
# can assert the seed and its derived paths are gated on the PORT-LESS form (#407).
private class RecordingScope < D::ScopePolicy
  def initialize(@asked : Array(String))
  end

  def allowed?(url : String, host : String) : Bool
    @asked << url
    true
  end

  def boundary?(url : String, host : String) : Bool
    true
  end

  def configured? : Bool
    false
  end
end

# A ScopePolicy that denies an exact URL set — the shape `StoreScope#allowed?` takes for a
# regex EXCLUDE rule, or for Sandbox with the host off the allowlist. `configured?` is false
# so ScopeAware containment falls back to same-origin and only `allowed?` (Layer 2) is under
# test here.
private class DenyExact < D::ScopePolicy
  def initialize(@deny : Set(String))
  end

  def allowed?(url : String, host : String) : Bool
    !@deny.includes?(url)
  end

  def boundary?(url : String, host : String) : Bool
    true
  end

  def configured? : Bool
    false
  end
end

# A ScopePolicy that allows ONLY an exact URL set — the shape a `regex` include anchored with
# `$` takes under Sandbox, and the one the issue-#391 table calls non-monotone: a directory can
# be allowlisted while every child under it is not.
private class AllowExact < D::ScopePolicy
  def initialize(@allow : Set(String))
  end

  def allowed?(url : String, host : String) : Bool
    @allow.includes?(url)
  end

  def boundary?(url : String, host : String) : Bool
    true
  end

  def configured? : Bool
    false
  end
end

# Allows a URL the first time it is asked and denies it afterwards — the shape a live scope
# takes when the operator adds an EXCLUDE mid-run (the TUI shares the Scope object with the
# engine's policy). Every Crawl/Fetch URL is asked once at enqueue and once at send.
private class DenyAfterFirstAsk < D::ScopePolicy
  def initialize
    @asked = Set(String).new
  end

  def allowed?(url : String, host : String) : Bool
    @asked.add?(url)
  end

  def boundary?(url : String, host : String) : Bool
    true
  end

  def configured? : Bool
    false
  end
end

# Every path `seed_frontier` queues by name at the origin, in order.
private WELL_KNOWN_PATHS = Gori::Discover::Engine::WELL_KNOWN.map { |path, _| path }.to_a

# The bogus soft-404 probes an origin-root calibration sends: one path segment directly under
# "/", minus the well-known paths seed_frontier queues by name. Derived from the constant, so
# adding a single-segment well-known document cannot silently turn it into a "calibration
# probe" here. A path-scoped run's own brute-force probes are deeper (/app/…), so they never
# land in here.
private def root_calibration_probes(targets : Array(String)) : Array(String)
  targets.select { |t| t.matches?(%r{\A/[^/]+\z}) && !WELL_KNOWN_PATHS.includes?(t) }
end

# A rate limiter that trips PARTWAY THROUGH a directory's sweep: an ordinary 404 origin for
# the first `until_drift` sends, then one uniform 429 for everything. The shape a stale
# baseline turns into 300 confidence-1.0 findings.
private def limiter_route(until_drift : Int32) : Proc(String, R)
  sent = 0
  ->(t : String) do
    sent += 1
    if sent <= until_drift
      t == "/admin" ? html("REAL ADMIN PANEL") : notfound
    else
      make(429, "<html>Too Many Requests. Slow down.</html>")
    end
  end
end

private def run_discover(seed : String, words : Array(String), cfg : D::Config,
                         scope : D::ScopePolicy = D::OpenScope.new,
                         &route : String -> R) : {Array(D::Finding), D::RunStats}
  backend = RouteBackend.new(route)
  engine = D::Engine.new(seed, words, backend, cfg, scope)
  findings = [] of D::Finding
  stats = nil.as(D::RunStats?)
  engine.run do |ev|
    case ev
    when D::FindingEvent then findings << ev.finding
    when D::DoneEvent    then stats = ev.stats
    end
  end
  {findings, stats.not_nil!}
end

describe Gori::Discover::Engine do
  it "crawls and records linked pages" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 3, concurrency: 2, retries: 0)
    findings, _ = run_discover("http://t/", %w(), cfg) do |t|
      case t
      when "/"        then html(%(<a href="/about">a</a> <a href="/contact">c</a> <a href="/about">dup</a>))
      when "/about"   then html("the about page body")
      when "/contact" then html("the contact page body")
      else                 notfound
      end
    end
    urls = findings.map(&.url)
    urls.should contain("http://t/about")
    urls.should contain("http://t/contact")
    # crawled findings carry high confidence (they exist by construction)
    findings.select { |f| f.source.crawled? }.all? { |f| f.confidence >= 0.85 }.should be_true
  end

  it "brute-forces an unlinked path against a clean 404 baseline" do
    cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 2, concurrency: 1,
      retries: 0, confidence_floor: 0.4)
    findings, _ = run_discover("http://t/", ["admin", "nope"], cfg) do |t|
      t == "/admin" ? html("ADMIN CONTROL PANEL") : notfound
    end
    bf = findings.select(&.source.bruteforced?).map(&.url)
    bf.should contain("http://t/admin")
    bf.should_not contain("http://t/nope")
  end

  it "suppresses false positives on a 200-everything (wildcard) server" do
    cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1, retries: 0)
    findings, stats = run_discover("http://t/", ["admin", "secret"], cfg) do |_t|
      html("THE SAME SOFT-404 PAGE FOR EVERY SINGLE PATH ON THIS SERVER")
    end
    findings.select(&.source.bruteforced?).should be_empty
    stats.calibrated_out.should be > 0
  end

  it "escapes a 302-everything login funnel and only keeps the diverging path" do
    cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
      retries: 0, follow_redirects: false, confidence_floor: 0.3)
    findings, _ = run_discover("http://t/", ["admin", "other"], cfg) do |t|
      t == "/admin" ? html("REAL ADMIN CONTENT") : make(302, "", location: "/login")
    end
    bf = findings.select(&.source.bruteforced?).map(&.url)
    bf.should contain("http://t/admin")
    bf.should_not contain("http://t/other")
  end

  # A redirect `Location` is the ONE link source that reaches `Url.resolve` unscrubbed — the
  # other four all come out of `Extract`, which scrubs before anything meets PCRE2. `resolve`
  # tested the scheme with a Regex, and PCRE2 raises ArgumentError on invalid UTF-8, so a
  # Latin-1 relative Location unwound the ORCHESTRATOR fiber: the run ended on a terminal
  # "Regex match error" with no Done, discarding every outcome still in flight.
  it "finishes a run whose redirect Location is a relative, not-valid-UTF-8 path" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 2, concurrency: 1, retries: 0)
    loc = String.new(Bytes[0x63, 0x61, 0x66, 0xe9, 0x2f, 0x78]) # "caf\xE9/x"
    backend = RouteBackend.new(->(t : String) do
      t == "/" ? make(302, "", location: loc) : html("an ordinary page")
    end)
    kinds, messages = terminal_of(D::Engine.new("http://t/", [] of String, backend, cfg))
    messages.should be_empty
    kinds.last.should eq(:done)
  end

  it "stops a /user/{n} link farm via template folding" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 5, max_pages: 1000,
      template_saturation: 20, concurrency: 2, retries: 0)
    links = (1..30).map { |i| %(<a href="/user/#{i}">u</a>) }.join(" ")
    _, stats = run_discover("http://t/", %w(), cfg) do |t|
      if t == "/"
        html(links)
      elsif t.starts_with?("/user/")
        html("user profile page for #{t}")
      else
        notfound
      end
    end
    stats.template_suppressed.should eq(10) # 30 links, first 20 pass, 10 frozen
  end

  it "stops a near-duplicate listing trap via content clustering" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 5, max_pages: 1000,
      cluster_saturation: 15, template_saturation: 1000, concurrency: 1, retries: 0)
    # The distinguishing number sits in its OWN path segment (/list/N), which the fingerprint
    # correctly skips — so every listing page has an identical content fingerprint and they
    # collapse into one cluster (a real faceted-listing / pagination trap).
    plinks = (1..20).map { |i| %(<a href="/list/#{i}">row</a>) }.join(" ")
    _, stats = run_discover("http://t/", %w(), cfg) do |t|
      if t == "/"
        html("HOME PAGE " + plinks)
      elsif t.starts_with?("/list/")
        n = t.lchop("/list/")
        html(%(LISTING PAGE <a href="/item/#{n}">view item</a>)) # identical kept-token shape per page
      else
        notfound
      end
    end
    stats.cluster_suppressed.should eq(5) # /list/16../list/20 links frozen after the cluster saturates
  end

  it "hard-caps total sends at max_requests" do
    cfg = D::Config.new(spider: false, bruteforce: true, max_requests: 5_i64, calibrate_probes: 2,
      concurrency: 1, retries: 0)
    words = (1..50).map { |i| "path#{i}" }
    _, stats = run_discover("http://t/", words, cfg) { |_t| notfound }
    stats.sent.should be <= 5
  end

  # …and SAYS it stopped short. Fuzz and mine let a consumer derive this (`sent < total`,
  # `names_done < names_total`); discover's only denominator is `est_total`, a moving estimate
  # that RISES as the crawl proceeds, so nothing downstream could tell a capped run from a
  # complete one — `status:"done", job_complete:true, has_more:false` came back with 275 of
  # 283 wordlist tasks unsent, and both the CLI and an agent read that as a finished sweep.
  describe "budget_exhausted" do
    it "is set when the cap left queued work behind" do
      cfg = D::Config.new(spider: false, bruteforce: true, max_requests: 5_i64, calibrate_probes: 2,
        concurrency: 1, retries: 0)
      words = (1..50).map { |i| "path#{i}" }
      done = nil.as(D::DoneEvent?)
      D::Engine.new("http://t/", words, RouteBackend.new(->(_t : String) { notfound }), cfg)
        .run { |ev| done = ev if ev.is_a?(D::DoneEvent) }
      d = done.not_nil!
      d.budget_exhausted.should be_true
      d.progress.queued.should be > 0
    end

    # The complement, and the reason this is not just `cap_reached?`: a run with NO cap, and a
    # run whose cap was never binding, both finished — saying "budget exhausted" there would
    # send the operator after a flag that was not the reason for anything.
    it "is NOT set for an uncapped run, nor for a cap the run never reached" do
      words = ["admin", "login"]
      {nil.as(Int64?), 500_i64}.each do |cap|
        cfg = D::Config.new(spider: false, bruteforce: true, max_requests: cap, calibrate_probes: 1,
          concurrency: 1, retries: 0)
        done = nil.as(D::DoneEvent?)
        D::Engine.new("http://t/", words, RouteBackend.new(->(_t : String) { notfound }), cfg)
          .run { |ev| done = ev if ev.is_a?(D::DoneEvent) }
        done.not_nil!.budget_exhausted.should be_false
        done.not_nil!.progress.queued.should eq(0)
      end
    end
  end

  # Mine's `mine_all_refused?` backstop, brought over. A target that accepts TCP and then
  # answers nothing, under a budget small enough that only CALIBRATION probes ever ran,
  # reported `done · 0 found · 9 sent · 0 errors` and exit 0: nine requests went out, nine got
  # no response, and `handle_calibrate` — unlike `handle_probe`/`handle_crawl` — never recorded
  # a reason, so `wholly_refused_reason` had nothing to name.
  it "names the reason when the whole budget went on failing CALIBRATION probes" do
    cfg = D::Config.new(spider: false, bruteforce: true, max_requests: 3_i64, calibrate_probes: 3,
      concurrency: 1, retries: 2)
    dead = R.new(Bytes.new(0), nil, nil, 0_i64, "no response from t:80")
    engine = D::Engine.new("http://t/", ["admin", "login"], RouteBackend.new(->(_t : String) { dead }), cfg)
    kinds, messages = terminal_of(engine)
    kinds.should eq([:error]) # terminal — no Done for a consumer to settle "0 found" over
    messages.first.should contain("no response from t:80")
  end

  # The complement of `successful_sends == 0`: a target that ANSWERED is not a failed run even
  # when it held nothing, so a stray later error must not turn "found nothing" into an error.
  it "still ends Done when the target answered but nothing was found" do
    cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1, concurrency: 1, retries: 0)
    seen = 0
    backend = RouteBackend.new(->(_t : String) do
      seen += 1
      seen > 3 ? R.new(Bytes.new(0), nil, nil, 0_i64, "no response from t:80") : notfound
    end)
    kinds, _ = terminal_of(D::Engine.new("http://t/", ["admin", "login"], backend, cfg))
    kinds.last.should eq(:done)
  end

  it "survives a backend that raises without hanging (worker rescue keeps @pending balanced)" do
    cfg = D::Config.new(spider: true, bruteforce: true, concurrency: 2, retries: 0, calibrate_probes: 1)
    engine = D::Engine.new("http://t/", ["admin"], RaisingBackend.new, cfg)
    done = false
    findings = [] of D::Finding
    engine.run do |ev|
      findings << ev.finding if ev.is_a?(D::FindingEvent)
      done = true if ev.is_a?(D::DoneEvent)
    end
    done.should be_true # terminated cleanly instead of blocking forever
    findings.should be_empty
  end

  it "emits a single terminal ErrorEvent (no masking Done) on an invalid seed" do
    engine = D::Engine.new("not a url", [] of String, RouteBackend.new(->(_t : String) { notfound }), D::Config.new)
    kinds = [] of Symbol
    engine.run do |ev|
      kinds << :error if ev.is_a?(D::ErrorEvent)
      kinds << :done if ev.is_a?(D::DoneEvent)
    end
    kinds.should contain(:error)
    kinds.should_not contain(:done) # a trailing Done would let a consumer settle "0 found" over the error
  end

  it "follows a robots.txt Sitemap: URL at a non-standard path and extracts its <loc>s" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 5, concurrency: 1, retries: 0)
    findings, _ = run_discover("http://t/", %w(), cfg) do |t|
      case t
      when "/"            then html("home, no links")
      when "/robots.txt"  then make(200, "User-agent: *\nSitemap: http://t/custom/sm.xml\n", "text/plain")
      when "/sitemap.xml" then notfound # the well-known path is absent; only robots knows the real one
      when "/custom/sm.xml"
        make(200, %(<?xml version="1.0"?><urlset><url><loc>http://t/only-in-sitemap</loc></url></urlset>), "application/xml")
      when "/only-in-sitemap" then html("the page only the sitemap knew about")
      else                         notfound
      end
    end
    # Under source-label parsing the custom sitemap was parsed as robots (no <loc>s) and this
    # URL was lost; content-aware parsing recovers it.
    findings.map(&.url).should contain("http://t/only-in-sitemap")
  end

  it "calibrates robots.txt/sitemap.xml against the origin's soft-404 baseline (no FP on a wildcard-200 server)" do
    cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 3, concurrency: 2, retries: 0)
    findings, stats = run_discover("http://t/", ["admin", "secret"], cfg) do |_t|
      html("THE SAME SOFT-404 PAGE FOR EVERY SINGLE PATH ON THIS SERVER")
    end
    # robots.txt/sitemap.xml are guessed well-known paths, exactly like a brute-forced wordlist
    # entry — a server that 200s everything must not get to report them as "findings".
    findings.select { |f| f.source.robots? || f.source.sitemap? }.should be_empty
    findings.select(&.source.bruteforced?).should be_empty
    stats.calibrated_out.should be > 0
  end

  it "still records a genuine robots.txt/sitemap.xml on a server with a real 404 baseline" do
    cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 2, concurrency: 2, retries: 0)
    findings, _ = run_discover("http://t/", %w(), cfg) do |t|
      case t
      when "/robots.txt"  then make(200, "User-agent: *\nDisallow: /admin\n", "text/plain")
      when "/sitemap.xml" then make(200, %(<?xml version="1.0"?><urlset><url><loc>http://t/x</loc></url></urlset>), "application/xml")
      when "/"            then html("home")
      else                     notfound
      end
    end
    urls = findings.map(&.url)
    urls.should contain("http://t/robots.txt")
    urls.should contain("http://t/sitemap.xml")
  end

  # ── the `.well-known/` registry, and the bodies it hands back ───────────────────────────
  #
  # `.well-known` and `.well-known/security.txt` do ship in the built-in wordlist, but that
  # only probes them once per calibrated DIRECTORY (so never at the origin on a path-confined
  # run) and reads nothing they say. These are fetched at the origin like robots.txt, and
  # their bodies are parsed for further endpoints.
  it "fetches the whole well-known registry at the origin, not just robots/sitemap" do
    cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 2, retries: 0)
    sent = [] of String
    run_discover("http://t/", [] of String, cfg) do |t|
      sent << t
      t == "/" ? html("home, no links") : notfound
    end
    sent.should contain("/.well-known/openid-configuration")
    sent.should contain("/.well-known/security.txt")
    sent.should contain("/sitemap_index.xml")
  end

  # The highest-yield document there is: one 200 hands over authorize/token/userinfo/jwks as
  # absolute URLs. It is JSON, so before `Extract.from_text` existed the response was fetched,
  # decoded, fingerprinted — and every endpoint in it dropped for not being html-like.
  it "crawls the endpoints an OIDC discovery document declares" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 2, concurrency: 2, retries: 0)
    oidc = %({"issuer":"http://t","token_endpoint":"http://t/oauth2/token",\
"userinfo_endpoint":"http://t/oauth2/userinfo"})
    findings, _ = run_discover("http://t/", [] of String, cfg) do |t|
      case t
      when "/.well-known/openid-configuration" then make(200, oidc, "application/json")
      when "/oauth2/token"                     then make(200, "token endpoint", "application/json")
      when "/oauth2/userinfo"                  then make(200, "userinfo endpoint", "application/json")
      when "/"                                 then html("home, nothing linked")
      else                                          notfound
      end
    end
    urls = findings.map(&.url)
    urls.should contain("http://t/oauth2/token")
    urls.should contain("http://t/oauth2/userinfo")
    # A guessed document and everything it declares carry the well-known source, which is what
    # routes both through the soft-404 baseline instead of `record_page`'s raw-status trust.
    findings.find { |f| f.url == "http://t/oauth2/token" }.not_nil!.source.well_known?.should be_true
  end

  # …and it stops there. `WellKnown` inherits for ONE hop; a page an OIDC-named endpoint links
  # to is an ordinary `<a href>`, not a path gori guessed, so it must come back `Crawled`.
  it "does not inherit the well-known source past the document's own links" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 2, retries: 0)
    oidc = %({"token_endpoint":"http://t/oauth2/token"})
    findings, _ = run_discover("http://t/", [] of String, cfg) do |t|
      case t
      when "/.well-known/openid-configuration" then make(200, oidc, "application/json")
      when "/oauth2/token"                     then html(%(<a href="/deep/page">deep</a>))
      when "/deep/page"                        then html("an ordinary page")
      when "/"                                 then html("home, nothing linked")
      else                                          notfound
      end
    end
    findings.find { |f| f.url == "http://t/oauth2/token" }.not_nil!.source.well_known?.should be_true
    findings.find { |f| f.url == "http://t/deep/page" }.not_nil!.source.crawled?.should be_true
  end

  # The harm the hop limit prevents, on the run shape that shows it: an origin answering 401 to
  # unknown paths. A crawled page's 401 is a FINDING (`record_page` keeps 401/403 — an
  # auth-protected endpoint is the point); judged against that origin's own soft-404 baseline it
  # diverges in nothing and is dropped. Reaching the SAME page by the SAME link from `/` is the
  # control: whatever the run does to it there, it must do here.
  it "keeps a 401 page linked from a well-known endpoint, as if linked from the root" do
    route = ->(t : String) do
      case t
      when "/.well-known/openid-configuration"
        make(200, %({"token_endpoint":"http://t/oauth2/token"}), "application/json")
      when "/oauth2/token" then html(%(<a href="/deep/page">deep</a>))
      when "/deep/page"    then make(401, "Unauthorized")
      when "/"             then html("home")
      else                      make(401, "Unauthorized")
      end
    end
    cfg = D::Config.new(spider: true, bruteforce: true, max_depth: 4, concurrency: 2,
      retries: 0, calibrate_probes: 3)
    findings, _ = run_discover("http://t/", [] of String, cfg) { |t| route.call(t) }
    deep = findings.find { |f| f.url == "http://t/deep/page" }
    deep.not_nil!.source.crawled?.should be_true
  end

  # A path-confined run still checks the origin's well-known documents — they only ever live
  # there — and the endpoints they declare are then bounded like any other derived URL.
  it "still fetches the well-known registry on a path-confined run" do
    cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 2, retries: 0)
    sent = [] of String
    run_discover("http://t/app/", [] of String, cfg) do |t|
      sent << t
      t == "/app/" ? html("app root") : notfound
    end
    sent.should contain("/.well-known/security.txt")
  end

  # ── the script-bundle branch ────────────────────────────────────────────────────────────
  it "extracts API routes from a crawled script bundle" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 3, concurrency: 2, retries: 0)
    bundle = %(var a=1;fetch("/api/v2/orders");axios.get("/api/v2/invoices");)
    findings, _ = run_discover("http://t/", [] of String, cfg) do |t|
      case t
      when "/"                then html(%(<script src="/app.js"></script>))
      when "/app.js"          then make(200, bundle, "application/javascript")
      when "/api/v2/orders"   then make(200, "[]", "application/json")
      when "/api/v2/invoices" then make(200, "[]", "application/json")
      else                         notfound
      end
    end
    urls = findings.map(&.url)
    # Nothing on the site LINKS to either — they exist only as string literals in the bundle.
    urls.should contain("http://t/api/v2/orders")
    urls.should contain("http://t/api/v2/invoices")
  end

  # ── what an INFERRED link may spend ─────────────────────────────────────────────────────
  # Seeding a directory sweep costs the whole wordlist. `consider_link` spends it on a link the
  # target DECLARED; a literal recovered from text has to be confirmed first. These three pin the
  # three outcomes that rule produces.
  describe "brute-force directories derived from links" do
    # The saving. A bundle of i18n/asset/vendor paths that resolve to nothing must not each buy a
    # sweep of their own directory: measured against a live origin, seeding on faith turned one
    # response into 38,929 requests for 2 findings.
    it "does not sweep a directory named only by a script literal that 404s" do
      cfg = D::Config.new(spider: true, bruteforce: true, max_depth: 3, concurrency: 2,
        retries: 0, calibrate_probes: 2)
      bundle = %(var T={"a":"/locales/ns7/messages.json","b":"/assets/chunk3/style.css"};)
      sent = [] of String
      run_discover("http://t/", %w[admin secret], cfg) do |t|
        sent << t
        case t
        when "/"       then html(%(<script src="/app.js"></script>))
        when "/app.js" then make(200, bundle, "application/javascript")
        else                notfound
        end
      end
      # The literals themselves are still FETCHED — that is how they get confirmed or not.
      sent.should contain("/locales/ns7/messages.json")
      # …but nothing in those directories is brute-forced, because nothing there answered.
      sent.should_not contain("/locales/ns7/admin")
      sent.should_not contain("/assets/chunk3/secret")
    end

    # The coverage that must survive it: a route the bundle names which DOES answer earns its
    # directory a sweep, one round-trip later than before.
    it "sweeps the directory of a script literal that turns out to be real" do
      cfg = D::Config.new(spider: true, bruteforce: true, max_depth: 3, concurrency: 2,
        retries: 0, calibrate_probes: 2)
      sent = [] of String
      run_discover("http://t/", %w[admin], cfg) do |t|
        sent << t
        case t
        when "/"              then html(%(<script src="/app.js"></script>))
        when "/app.js"        then make(200, %(fetch("/api/v2/orders")), "application/javascript")
        when "/api/v2/orders" then make(200, "[]", "application/json")
        else                       notfound
        end
      end
      sent.should contain("/api/v2/admin")
    end

    # And the case that separates this from "confirm everything": a DECLARED link is the target's
    # own statement, so its directory is swept even when the link itself is stale. A robots.txt
    # naming a file that is gone is a classic reason to look at what else is in that directory.
    it "still sweeps the directory of a declared link that 404s" do
      cfg = D::Config.new(spider: true, bruteforce: true, max_depth: 3, concurrency: 2,
        retries: 0, calibrate_probes: 2)
      sent = [] of String
      run_discover("http://t/", %w[admin], cfg) do |t|
        sent << t
        case t
        when "/" then html(%(<a href="/backup/db.sql.gz">old</a>))
        else          notfound
        end
      end
      sent.should contain("/backup/admin")
    end
  end

  # The other half of `text_like?`: a crawl follows `<img src>` like any other link, so binary
  # responses are the common case here. Scanning one costs `Extract.text` a full `String#scrub`
  # (a second walk that rebuilds the whole body) to feed a regex no image can match.
  it "does not scan a binary response body for endpoints" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 3, concurrency: 2, retries: 0)
    findings, _ = run_discover("http://t/", [] of String, cfg) do |t|
      case t
      when "/"           then html(%(<img src="/logo.png">))
      when "/logo.png"   then make(200, %(PNG\u{0}\u{0}"/api/hidden"), "image/png")
      when "/api/hidden" then make(200, "should never be reached", "application/json")
      else                    notfound
      end
    end
    findings.map(&.url).should_not contain("http://t/api/hidden")
  end

  # ── drift: the baseline is a snapshot, and origins change their mind ────────────────────
  #
  # A `DirBaseline` is measured once, before a directory's ~315 probes, and never revisited.
  # An origin whose rate limiter trips (or WAF, or a 5xx meltdown) then answers every
  # remaining probe with one uniform response that diverges from the stale baseline in status
  # AND length AND content — so it is not merely reported, it is reported at confidence 1.0.
  describe "a baseline that goes stale mid-sweep" do
    it "stops reporting once the origin answers everything the same way" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      words = (1..80).map { |i| "w#{i}" }
      findings, stats = run_discover("http://t/", words, cfg, &limiter_route(6))
      limited = findings.select { |f| f.status == 429 }
      # The FIRST member of a uniform run is indistinguishable from a real finding at the
      # moment it arrives, so one gets through by design; every later one is held and then
      # dropped. Before the guard this was the whole rest of the wordlist, at confidence 1.0.
      limited.size.should be <= 1
      stats.drift_suppressed.should be > 0
    end

    it "re-measures the directory instead of only muting it" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      words = (1..80).map { |i| "w#{i}" }
      backend = RouteBackend.new(limiter_route(6))
      engine = D::Engine.new("http://t/", words, backend, cfg, D::OpenScope.new)
      kinds = [] of String
      engine.run { |ev| kinds << ev.kind if ev.is_a?(D::BaselineEvent) }
      # The first calibration, the drift declaration, and the re-calibration it queued — a
      # guard that only suppressed would show the first two and stop.
      kinds.should contain("drifted")
      kinds.size.should be >= 3
    end

    it "keeps a SHORT run of look-alike hits, which is an ordinary directory" do
      # Several endpoints answering identically is normal (one SPA shell behind several
      # routes); it only means drift when it does not stop. These are held while the run is
      # alive and released the moment a miss breaks it — DRIFT_RUN sits far above this.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      alike = %w[alpha bravo charlie delta]
      findings, _ = run_discover("http://t/", alike + %w[zulu], cfg) do |t|
        alike.any? { |w| t == "/#{w}" } ? html("ONE SHELL FOR EVERY REAL ROUTE HERE") : notfound
      end
      findings.map(&.url).size.should eq(alike.size)
    end

    it "releases a run still open when the sweep ends" do
      # The wordlist ends on a run of look-alike hits, so nothing is coming to break it.
      # Without the drain-time release the second one would be held for the lifetime of the
      # process and never reported. The bogus calibration names must fall to `notfound` here —
      # routing them to the shell instead would make the shell the BASELINE and there would be
      # no hits at all, which is a green test measuring nothing.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
        retries: 0, confidence_floor: 0.4, max_depth: 0)
      findings, _ = run_discover("http://t/", %w[alpha bravo], cfg) do |t|
        t == "/alpha" || t == "/bravo" ? html("ONE SHELL FOR EVERY REAL ROUTE HERE") : notfound
      end
      findings.map(&.url).sort!.should eq(["http://t/alpha", "http://t/bravo"])
    end
  end

  # The echo test rides on the calibration probes themselves — each searches its own body for
  # its own name — so it costs no extra request. It has to be a byte search: `bogus_name` is
  # 16 hex characters and `Fingerprint.dynamic?` skips all-hex runs of 12 or more, which makes
  # the reflected name invisible to the very hash the reflection would show up in.
  describe "an origin that quotes the requested path back" do
    it "does not turn every wordlist entry into a finding" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      filler = "lorem ipsum dolor sit amet consectetur " * 12
      findings, _ = run_discover("http://t/", %w[admin api/v2/orders swagger/v1/swagger.json], cfg) do |t|
        if t == "/admin"
          html("<h1>the real admin panel</h1>#{filler}#{filler}")
        else
          html("<h1>Nothing found at #{t} on this server</h1>#{filler}")
        end
      end
      urls = findings.map(&.url)
      urls.should contain("http://t/admin")
      # These exist only as the echo of their own request.
      urls.should_not contain("http://t/api/v2/orders")
      urls.should_not contain("http://t/swagger/v1/swagger.json")
    end
  end

  it "confines a path-scoped run to the seed subtree" do
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 1, retries: 0)
    findings, _ = run_discover("http://t/app/", %w(), cfg) do |t|
      case t
      when "/app/"      then html(%(<a href="/app/inner">in</a> <a href="/outside">out</a>))
      when "/app/inner" then html("inner app page")
      when "/outside"   then html("outside the subtree")
      else                   notfound
      end
    end
    urls = findings.map(&.url)
    urls.should contain("http://t/app/inner")
    urls.should_not contain("http://t/outside")
  end

  it "confines on path-SEGMENT boundaries, not a raw string prefix (no sibling-prefix bypass)" do
    # Seed /api (no trailing slash). The old confine used p.path.starts_with?("/api"), so a
    # SIBLING like /api-internal (which merely shares the string prefix) leaked into scope. The
    # segment-boundary check keeps /api and /api/… in-subtree while excluding /api-internal/….
    cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 1, retries: 0)
    findings, _ = run_discover("http://t/api", %w(), cfg) do |t|
      case t
      when "/api"                 then html(%(<a href="/api/inner">in</a> <a href="/api-internal/secret">sibling</a>))
      when "/api/inner"           then html("inside the api subtree")
      when "/api-internal/secret" then html("a sibling that only shares the string prefix")
      else                             notfound
      end
    end
    urls = findings.map(&.url)
    urls.should contain("http://t/api")                     # the seed path itself (== base) stays in-subtree
    urls.should contain("http://t/api/inner")               # a genuine child under base/
    urls.should_not contain("http://t/api-internal/secret") # sibling prefix — must be excluded
  end

  # Issue #395. The brute-force base came from `Url.dir_of(seed)` while the confine came from
  # the seed's full path, and for a file-shaped seed the two disagreed: `dir_of("http://t/api")`
  # is the origin root, which `@confine_path` of "/api" then refuses. The seed's own subtree
  # was never probed, and with --no-spider that was the entire run.
  describe "a file-shaped seed" do
    it "brute-forces its own subtree rather than nothing" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 2, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      sent = [] of String
      findings, _ = run_discover("http://t/api", ["admin"], cfg) do |t|
        sent << t
        t == "/api/admin" ? html("a real admin page under the api subtree") : notfound
      end
      # Calibration probes + the wordlist entry, all under /api/ — never at the origin root,
      # which is outside what the operator typed.
      sent.should_not be_empty
      sent.should contain("/api/admin")
      sent.all?(&.starts_with?("/api/")).should be_true
      findings.map(&.url).should contain("http://t/api/admin")
    end

    it "brute-forces a seed whose path ends in a bare dot" do
      # `/api/.` is the one dot-segment shape `Url.parse` used to leave alone, which made
      # `@confine_path` unsatisfiable — nothing derived can equal `/api/.`, so the run went
      # back to sending nothing. Normalizing it at parse is what keeps #395 true for this
      # shape too.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1, concurrency: 1, retries: 0)
      sent = [] of String
      run_discover("http://t/api/.", ["admin"], cfg) { |t| sent << t; notfound }
      sent.should contain("/api/admin")
    end

    it "drops a crawled link whose HOST carries a space, before it can reach a CONNECT line" do
      # The sweep's chain for the #394 class: `<a href="http://ac me.acme.test/x">` passes
      # `Headers.safe_url?` (a space is not CR/LF) and `same_or_subdomain?` containment, so on
      # the way to the wire it would have reached `Upstream.dial_via_proxy`, which writes
      # `CONNECT ac me.acme.test:80 HTTP/1.1` with no validation of its own. `Url.parse`
      # refusing the host is what makes that unreachable; the byte-level half is in
      # sender_spec's "with an upstream proxy configured".
      cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 1,
        retries: 0, containment: D::Containment::HostAndSubdomains)
      hosts = [] of String
      backend = HostRecordingBackend.new(hosts, ->(t : String) {
        t == "/" ? html(%(<a href="http://ac me.acme.test/x">spaced host</a> <a href="http://ok.acme.test/y">ok</a>)) : html("an ordinary page")
      })
      D::Engine.new("http://acme.test/", [] of String, backend, cfg).run { |_ev| }
      # The control: a sibling subdomain link on the same page WAS crawled, so this is a
      # verdict about the host guard and not about a crawl that never happened.
      hosts.should contain("ok.acme.test")
      hosts.none?(&.includes?(' ')).should be_true
    end

    it "keeps the brute-force base inside the confine for a deeper path and a query seed" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1, concurrency: 1, retries: 0)
      %w[http://t/a/b http://t/api?x=1 http://t:8080/api].each do |seed|
        sent = [] of String
        run_discover(seed, ["admin"], cfg) do |t|
          sent << t
          notfound
        end
        base = seed.includes?("/a/b") ? "/a/b/" : "/api/"
        sent.should_not be_empty
        sent.all?(&.starts_with?(base)).should be_true
      end
    end

    it "leaves a directory seed and an origin seed calibrating exactly where they did" do
      # The control: the two rows of the issue's matrix that already worked must not move.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1, concurrency: 1, retries: 0)
      {"http://t/api/" => "/api/", "http://t/" => "/"}.each do |seed, base|
        sent = [] of String
        run_discover(seed, ["admin"], cfg) { |t| sent << t; notfound }
        sent.should contain("#{base}admin")
        sent.all?(&.starts_with?(base)).should be_true
      end
    end
  end

  # Issue #395, the general half: a run that puts nothing on the wire must say so. The
  # condition is the SEND COUNTER, not an empty frontier — an empty frontier is only the
  # shape #395 found.
  describe "a run that sends nothing" do
    it "ends in a terminal ErrorEvent when seeding enqueued nothing" do
      # Brute-force only, with the seed's own subtree refused by Layer 2. The seed itself is
      # allowed, so SEED_BLOCKED does not fire — yet not one request would go out.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 2, concurrency: 4, retries: 0)
      sent = [] of String
      backend = RouteBackend.new(->(t : String) { sent << t; notfound })
      engine = D::Engine.new("http://t/api", ["admin"], backend, cfg,
        DenyExact.new(Set{"http://t/api/"}))
      kinds, messages = terminal_of(engine)
      kinds.should eq([:error])
      messages.first.should eq(D::Engine::NOTHING_TO_SEND)
      sent.should be_empty
      # The terminal event is emitted AFTER the ordinary shutdown, never by returning early:
      # with `concurrency: 4` an early return would leave four worker fibers parked on
      # `@jobs.receive?` forever. `engine.run` would still return (it only waits on @events),
      # so the leak is invisible unless the closed channel is asserted directly.
      engine.@jobs.closed?.should be_true
    end

    it "ends in a terminal ErrorEvent when the frontier had work but every send was refused" do
      # The half an empty-frontier test cannot see, and the one that became ordinary with #396:
      # the seed IS enqueued (its Layer-2 check at construction passes, so SEED_BLOCKED does
      # not fire) and then every send is refused per-URL in `send_with_retries`. This is
      # exactly the shape a mid-run EXCLUDE now produces. `SCOPE_REFUSED` is a benign error, so
      # `errors` stays 0 too — without the send-counter condition the run is completely silent.
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      sent = [] of String
      backend = RouteBackend.new(->(t : String) { sent << t; notfound })
      engine = D::Engine.new("http://t/api", [] of String, backend, cfg, DenyAfterFirstAsk.new)
      kinds, messages = terminal_of(engine)
      kinds.should eq([:error])
      messages.first.should eq(D::Engine::NOTHING_TO_SEND)
      sent.should be_empty
    end

    # The send counter is a BUDGET counter — `CappedBackend#fetch` charges the attempt BEFORE
    # the inner fetch, so a send refused before a socket (an unbound `$NAME`, an unsafe URL)
    # still increments it. That made this run take the Done branch with the reason nowhere:
    # `handle_crawl`/`handle_probe` had the sentence and dropped it. Miner and Sequencer
    # already carry `first_error` for exactly this (#491).
    it "names the reason when every send was refused at the backend" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 0, concurrency: 1, retries: 0)
      refused = R.new(Bytes.new(0), nil, nil, 0_i64, "$SESSION is declared by an extract rule but not bound yet")
      engine = D::Engine.new("http://t/api", ["admin", "login"], RouteBackend.new(->(_t : String) { refused }), cfg)
      kinds, messages = terminal_of(engine)
      kinds.should eq([:error]) # terminal, so a consumer cannot settle a "0 found" success over it
      messages.first.should contain("not bound yet")
      engine.first_error.should_not be_nil
    end

    # …but a run that DID get an answer keeps its results, however many later sends were
    # refused. Turning that into a terminal error would hide what it found.
    it "still ends Done when a page was read, even with later refusals" do
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      backend = RouteBackend.new(->(t : String) do
        # The seed answers with a link; everything it leads to is refused.
        t == "/api" ? make(200, %(<a href="/api/next">n</a>)) : R.new(Bytes.new(0), nil, nil, 0_i64, "refused")
      end)
      kinds, _ = terminal_of(D::Engine.new("http://t/api", [] of String, backend, cfg))
      kinds.last.should eq(:done)
    end

    it "still emits a normal Done as soon as ONE request goes out (the control)" do
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1, concurrency: 1, retries: 0)
      sent = [] of String
      backend = RouteBackend.new(->(t : String) { sent << t; notfound })
      kinds, _ = terminal_of(D::Engine.new("http://t/api", ["admin"], backend, cfg))
      kinds.should eq([:done])
      sent.should_not be_empty
    end
  end

  # Issue #364 / DESIGN.md §7: the seed and its two derived well-known paths waive Layer 1,
  # the containment mode and the path confine — but never Layer 2 (Sandbox + EXCLUDE).
  describe "the Layer-2 gate on the seed trio" do
    it "refuses the whole run, terminally and without a single send, when Layer 2 blocks the seed" do
      sent = [] of String
      backend = RouteBackend.new(->(t : String) { sent << t; notfound })
      cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 2, concurrency: 1, retries: 0)
      engine = D::Engine.new("http://t/", ["admin"], backend, cfg, DenyExact.new(Set{"http://t/"}))
      kinds = [] of Symbol
      messages = [] of String
      engine.run do |ev|
        if ev.is_a?(D::ErrorEvent)
          kinds << :error
          messages << ev.message
        end
        kinds << :done if ev.is_a?(D::DoneEvent)
      end
      # A silent 0-finding Done would read as "there is nothing there" rather than "gori sent
      # nothing", which is the whole reason this is a setup error and not a skipped enqueue.
      kinds.should eq([:error])
      messages.first.should contain(D::Engine::SEED_BLOCKED)
      sent.should be_empty
    end

    it "drops every well-known path when Layer 2 excludes them, and keeps the seed" do
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      denied = WELL_KNOWN_PATHS.map { |p| "http://t#{p}" }.to_set
      sent = [] of String
      run_discover("http://t/", [] of String, cfg, DenyExact.new(denied)) do |t|
        sent << t
        t == "/" ? html("home, no links") : notfound
      end
      sent.should eq(["/"])
    end

    it "still fetches them all when nothing denies them (the control for the case above)" do
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      sent = [] of String
      run_discover("http://t/", [] of String, cfg) do |t|
        sent << t
        t == "/" ? html("home, no links") : notfound
      end
      sent.sort.should eq((["/"] + WELL_KNOWN_PATHS).sort)
    end

    it "gates the origin calibration a path-scoped run queues to grade those paths" do
      # The seed-only calibration is the LARGEST part of the blast radius — one bogus
      # probe per calibrate_probes, at the origin root, on a run confined to /app/. Denying
      # the root dir alone leaves the seed and every well-known path allowed, so what this
      # asserts on is the calibration and nothing else.
      cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 3, max_depth: 1,
        concurrency: 1, retries: 0)
      route = ->(t : String) { t == "/app/" ? html("app root, no links") : notfound }

      gated = [] of String
      run_discover("http://t/app/", ["admin"], cfg, DenyExact.new(Set{"http://t/"})) do |t|
        gated << t
        route.call(t)
      end
      root_calibration_probes(gated).should be_empty
      gated.should contain("/robots.txt") # the deny was narrow: only the calibration is gone
      gated.should contain("/sitemap.xml")

      # Control run — without it, the assertion above would pass just as happily against an
      # engine that never calibrates the origin at all.
      open = [] of String
      run_discover("http://t/app/", ["admin"], cfg) do |t|
        open << t
        route.call(t)
      end
      # calibrate_probes, and no more: the echo test rides ON these probes (it searches each
      # body for that probe's own name) rather than costing a request of its own.
      root_calibration_probes(open).size.should eq(3)
    end

    it "does not downgrade robots.txt/sitemap.xml to raw-status trust when that calibration is gated" do
      # Gating the calibration must not also drop the routing that sends a robots/sitemap
      # outcome through the soft-404 baseline: with no baseline they have to go UNCOUNTED
      # ("no baseline, no claim"), not fall back to record_page — which on a 200-everything
      # server reports both as findings, the exact false positive the calibration exists to
      # stop. An earlier draft of this fix skipped the routing and did precisely that.
      cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 3, max_depth: 1,
        concurrency: 1, retries: 0)
      findings, _ = run_discover("http://t/app/", ["admin"], cfg, DenyExact.new(Set{"http://t/"})) do |_t|
        html("THE SAME SOFT-404 PAGE FOR EVERY SINGLE PATH ON THIS SERVER")
      end
      findings.select { |f| f.source.robots? || f.source.sitemap? }.should be_empty
    end
  end

  # Issue #390. `Extract::ATTR`'s `[^"]` matches CR and LF, `Url.resolve` strips only the ends,
  # and `URI.parse` keeps an interior CR/LF verbatim in host, path AND query — so a crawled
  # `<a href>` reached `Sender#build_get` intact and spliced a second, fully attacker-chosen
  # request onto the connection. The byte-level proof lives in sender_spec; this pins the
  # engine half: such a link is dropped before it is ever queued.
  describe "a crawled link carrying a raw CRLF" do
    it "is dropped silently and never reaches the backend" do
      cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 1, retries: 0)
      poison = "/p\r\nX-Injected: 1\r\n\r\nGET http://evil.test/pwned HTTP/1.1\r\nHost: evil.test\r\n\r\n"
      sent = [] of String
      findings, _ = run_discover("http://t/", [] of String, cfg) do |t|
        sent << t
        case t
        when "/"      then html(%(<a href="#{poison}">poison</a> <a href="/clean">ok</a>))
        when "/clean" then html("an ordinary sibling link on the same page")
        else               notfound
        end
      end
      # The control: the page WAS crawled and its links WERE extracted, so "nothing poisoned
      # went out" is a verdict about the guard and not about a crawl that never happened.
      findings.map(&.url).should contain("http://t/clean")
      sent.should contain("/clean")

      sent.none?(&.includes?('\r')).should be_true
      sent.none?(&.includes?('\n')).should be_true
      sent.none?(&.includes?("evil.test")).should be_true
      findings.map(&.url).none?(&.includes?("evil.test")).should be_true
    end

    # Issue #394, the other half of the same octet class. A raw SPACE is NOT dropped: it is
    # what handwritten HTML actually contains, so dropping it would silently shrink coverage
    # and lose a real endpoint. It is percent-encoded at parse, which gives the URL one
    # spelling for the wire, the scope question, the finding and the Sitemap row alike.
    it "percent-encodes a crawled link carrying a raw space instead of dropping it" do
      cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 1, retries: 0)
      sent = [] of String
      findings, _ = run_discover("http://t/", [] of String, cfg) do |t|
        sent << t
        t == "/" ? html(%(<a href="/my file.pdf">doc</a> <a href="/rep ort?q=a b">q</a>)) : html("a real document body")
      end
      sent.should contain("/my%20file.pdf")
      sent.should contain("/rep%20ort?q=a%20b")
      sent.none?(&.includes?(' ')).should be_true
      # The finding — and therefore the Sitemap row `Persist` writes from it — carries the
      # same encoded spelling, so a byte-exact Repeater re-send reproduces a valid request.
      findings.map(&.url).should contain("http://t/my%20file.pdf")
    end

    it "is dropped when the CRLF sits in the QUERY rather than the path" do
      # `URI.parse("http://t/a?q=1\r\nX: 1").query` keeps the CR/LF, and send_with_retries
      # rebuilds the target as "#{path}?#{query}" — so a path-only check would miss this.
      cfg = D::Config.new(spider: true, bruteforce: false, max_depth: 4, concurrency: 1, retries: 0)
      sent = [] of String
      run_discover("http://t/", [] of String, cfg) do |t|
        sent << t
        t == "/" ? html(%(<a href="/ok?q=1\r\nX-Injected: 1">q</a> <a href="/clean">ok</a>)) : notfound
      end
      sent.should contain("/clean")
      sent.should_not contain("/ok?q=1")
      sent.none? { |t| t.includes?('\r') || t.includes?('\n') }.should be_true
    end
  end

  # Issue #391 / DESIGN.md §7. Brute-force and calibration probes were authorised by their
  # DIRECTORY: one `allowed?` answer about the dir stood in for ~278 real requests under it,
  # and the path confine never applied to them at all.
  describe "probes are authorised per URL, not by their directory" do
    it "skips a wordlist entry an EXCLUDE denies while its directory is allowed" do
      # The issue's repro. `logout` is line 41 of the built-in wordlist, and an exclude on it
      # is the canonical "do not touch destructive endpoints" rule — silently ignored, because
      # the only question ever asked was about "http://t/".
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 2, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      sent = [] of String
      findings, _ = run_discover("http://t/", ["logout", "admin"], cfg,
        DenyExact.new(Set{"http://t/logout"})) do |t|
        sent << t
        t == "/logout" || t == "/admin" ? html("A REAL PAGE THAT WOULD BE REPORTED") : notfound
      end
      sent.should_not contain("/logout")
      # The control: the sibling probe under the very same directory DID go out, so this is a
      # verdict about the gate and not about a brute-forcer that never ran.
      sent.should contain("/admin")
      findings.map(&.url).should contain("http://t/admin")
      findings.map(&.url).should_not contain("http://t/logout")
    end

    it "skips the calibration probes when the scope allows the directory but not its children" do
      # process_calibrate builds "#{dir}#{bogus_name}" inside a WORKER at send time, so these
      # are the sends no enqueue-time gate can ever see — only the send chokepoint can.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 3, concurrency: 1,
        retries: 0)
      gated = [] of String
      backend = RouteBackend.new(->(t : String) { gated << t; notfound })
      engine = D::Engine.new("http://t/", ["admin"], backend, cfg, AllowExact.new(Set{"http://t/"}))
      errors = 0_i64
      engine.run { |ev| errors = ev.progress.errors if ev.is_a?(D::DoneEvent) }
      gated.should be_empty
      # A refusal is a decision the operator asked for, not a failure — it must not inflate
      # the error count every surface renders.
      errors.should eq(0)

      open = [] of String
      run_discover("http://t/", ["admin"], cfg) do |t|
        open << t
        notfound
      end
      open.size.should eq(4) # control: 3 calibration probes + the one wordlist entry
    end

    it "keeps a traversal wordlist entry inside the seed's path confine" do
      # `bl.dir + cand` is re-parsed by Url.parse, whose normalize_path collapses "..", so
      # `../admin` under an /app/-confined run resolved to /admin. @confine_path lived only
      # inside bounded_url, which probes never reached.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 2, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      sent = [] of String
      findings, _ = run_discover("http://t/app/", ["../admin", "inner"], cfg) do |t|
        sent << t
        t == "/admin" || t == "/app/inner" ? html("A REAL PAGE THAT WOULD BE REPORTED") : notfound
      end
      sent.should_not contain("/admin")
      sent.should contain("/app/inner") # control: an ordinary entry in the same list still probes
      findings.map(&.url).should_not contain("http://t/admin")
    end
  end

  # Issue #393. `enqueue_seed_only_calibration` used to be skipped whenever the origin root WAS
  # the seed's own brute-force directory, on the assumption that `enqueue_dir` had already
  # queued a Calibrate for it. But `enqueue_dir` goes through `bounded_url`, which applies the
  # path confine — and the confine refuses the origin root on a single-segment seed with no
  # trailing slash. So no baseline ever arrived, and robots.txt/sitemap.xml were fetched for
  # real and then parked forever.
  describe "the origin calibration that grades robots.txt/sitemap.xml" do
    # Every seed shape from the issue's table, including the three that already worked — the
    # bug was one shape out of four, so pinning only the broken one would not show that the fix
    # left the others alone.
    {"http://t/api", "http://t/api/", "http://t/", "http://t/a/b"}.each do |seed|
      it "records both well-known findings for a seed of #{seed}" do
        cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 2, concurrency: 2,
          retries: 0)
        fetched = [] of String
        findings, _ = run_discover(seed, [] of String, cfg) do |t|
          fetched << t
          case t
          when "/robots.txt"  then make(200, "User-agent: *\nDisallow: /admin\n", "text/plain")
          when "/sitemap.xml" then make(200, %(<?xml version="1.0"?><urlset><url><loc>http://t/x</loc></url></urlset>), "application/xml")
          else                     notfound
          end
        end
        # Both were always SENT; what the bug lost was the recording of their outcomes.
        fetched.count("/robots.txt").should eq(1)
        fetched.count("/sitemap.xml").should eq(1)
        urls = findings.map(&.url)
        urls.should contain("http://t/robots.txt")
        urls.should contain("http://t/sitemap.xml")
      end
    end

    it "still brute-forces the origin when it IS the seed's own directory" do
      # The regression guard for dropping the `unless root_dir == bf_dir` short-circuit: a
      # seed_only Calibrate never feeds enqueue_probes, so if it displaced the ordinary one
      # instead of deduping against it, brute-force would go silently dead at the origin.
      cfg = D::Config.new(spider: true, bruteforce: true, calibrate_probes: 2, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      findings, _ = run_discover("http://t/", ["admin"], cfg) do |t|
        t == "/admin" ? html("ADMIN CONTROL PANEL") : notfound
      end
      findings.select(&.source.bruteforced?).map(&.url).should contain("http://t/admin")
    end
  end

  # Review findings on the four fixes above.
  describe "the Layer-2 gate string" do
    it "asks the scope in the port-less form every other consumer uses" do
      # `Url.normalize` appends `:port` off the defaults, but gori's scope model has no port
      # dimension: `Scope.request_url` is "scheme://host/target" and the proxy splits the port
      # off before asking. So on :8080 discover asked about "http://t:8080/logout" while a rule
      # was written against "http://t/logout", and a host-qualified string/regex EXCLUDE — the
      # exact rule #391 is about — silently failed open.
      cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 2, concurrency: 1,
        retries: 0, confidence_floor: 0.4)
      sent = [] of String
      run_discover("http://t:8080/", ["logout", "admin"], cfg,
        DenyExact.new(Set{"http://t/logout"})) do |t|
        sent << t
        notfound
      end
      sent.should_not contain("/logout")
      sent.should contain("/admin") # control: the sibling probe on the same port still goes out
    end

    it "keeps the port on the crawled url and the finding" do
      # Only the gate question drops the port — the resource's own identity keeps it.
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      findings, _ = run_discover("http://t:8080/", [] of String, cfg) do |t|
        t == "/" ? html(%(<a href="/kept">k</a>)) : html("an ordinary page body here")
      end
      findings.map(&.url).should contain("http://t:8080/kept")
    end
  end

  describe "the error count" do
    it "does not count the max-requests cap as an error on the crawl path" do
      # handle_probe already excluded CAP_ERROR; handle_crawl excluded nothing. With
      # max_requests set the orchestrator fills the @jobs buffer before any worker increments
      # @capped.sent, so every over-dispatched crawl came back CAP_ERROR and was counted —
      # `--max-requests 5` at default concurrency reported dozens of "errors" that were the
      # cap working as designed.
      # The frontier must hold more jobs than the cap at the moment of dispatch: `@jobs` is
      # buffered to `concurrency`, so the orchestrator pushes all three seed tasks (the seed
      # crawl + robots.txt + sitemap.xml) before any worker increments `@capped.sent`. The
      # third then comes back CAP_ERROR.
      cfg = D::Config.new(spider: true, bruteforce: false, max_requests: 2_i64,
        concurrency: 8, retries: 0)
      backend = RouteBackend.new(->(_t : String) { html("an ordinary page body here") })
      engine = D::Engine.new("http://t/", [] of String, backend, cfg)
      errors = 0_i64
      sent = 0_i64
      engine.run do |ev|
        if ev.is_a?(D::DoneEvent)
          errors = ev.progress.errors
          sent = ev.progress.sent
        end
      end
      sent.should eq(2)
      errors.should eq(0)
    end

    it "does not count a Layer-2 refusal as an error on the crawl path" do
      # Every Crawl/Fetch URL is asked twice — once at enqueue, once at send. In the TUI the
      # Scope object is shared live, so an EXCLUDE added mid-run turns queued crawls into
      # refusals at send; those are decisions the operator asked for, not failures.
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      backend = RouteBackend.new(->(_t : String) { notfound })
      engine = D::Engine.new("http://t/", [] of String, backend, cfg, DenyAfterFirstAsk.new)
      errors = 0_i64
      engine.run { |ev| errors = ev.progress.errors if ev.is_a?(D::DoneEvent) }
      errors.should eq(0)
    end
  end

  it "refuses a probe candidate carrying an interior CR from a hostile wordlist" do
    # Wordlist.load strips only the ends of a line, so an interior lone CR survives into
    # `bl.dir + cand`. The wire seam would catch it, but only after the candidate had been
    # enqueued, retried and counted as an error — bounded_url refuses its equivalent, so the
    # probe gate does too.
    cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1, concurrency: 1,
      retries: 0)
    sent = [] of String
    run_discover("http://t/", ["ad\rmin", "clean"], cfg) do |t|
      sent << t
      notfound
    end
    sent.should contain("/clean")
    sent.none?(&.includes?('\r')).should be_true
  end

  # #407: gori's scope model has no port dimension (Scope.request_url is "scheme://host/target"),
  # so every Layer-2 gate must ask the PORT-LESS url. The seed check, enqueue_well_known and
  # enqueue_seed_only_calibration used Url.normalize/origin, which append :port on a non-default
  # port — so a host-qualified string/regex include falsely denied the seed and an exclude failed
  # open. This records every url handed to the scope and proves none carries the port.
  it "asks the scope the port-less url for the seed and its derived paths (#407)" do
    asked = [] of String
    scope = RecordingScope.new(asked)
    cfg = D::Config.new(spider: true, bruteforce: false, retries: 0, max_depth: 1)
    # A non-default port on the seed — the exact case that regressed.
    engine = D::Engine.new("http://acme.test:8443/", [] of String, RouteBackend.new(->(_t : String) { notfound }), cfg, scope)
    engine.run { |_ev| }
    asked.should_not be_empty
    asked.select(&.includes?("8443")).should eq([] of String) # never the port-bearing form
    asked.all?(&.starts_with?("http://acme.test/")).should be_true
  end

  # Calibration is the only task that fans out into many sends, so `worker_loop`'s stop check
  # — which runs once per RECEIVED task — did not cover it: a worker already inside the batch
  # kept firing every remaining bogus probe after `stop`. At the shipped defaults that is
  # 20 workers x 3 probes x (1 + 1 retry) reaching a third party AFTER the operator stopped.
  it "stops firing calibration probes as soon as the run is stopped" do
    cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 8, concurrency: 1,
      retries: 0)
    bogus = 0
    engine = uninitialized D::Engine
    backend = RouteBackend.new(->(t : String) do
      # The calibrator's bogus paths are a 16-hex name at the directory root.
      if t.matches?(/\A\/[0-9a-f]{16}\z/)
        bogus += 1
        engine.stop # the operator presses stop during the first probe of the batch
      end
      notfound
    end)
    engine = D::Engine.new("http://t/", ["admin", "secret"], backend, cfg, D::OpenScope.new)
    engine.run { }

    # One probe was in flight when stop was requested; the remaining seven must not go out.
    bogus.should eq(1)
  end
end
