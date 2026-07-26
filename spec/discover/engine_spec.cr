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

# The bogus soft-404 probes an origin-root calibration sends: one path segment directly under
# "/", minus the two well-known paths seed_frontier queues by name. A path-scoped run's own
# brute-force probes are deeper (/app/…), so they never land in here.
private def root_calibration_probes(targets : Array(String)) : Array(String)
  targets.select { |t| t.matches?(%r{\A/[^/]+\z}) && t != "/robots.txt" && t != "/sitemap.xml" }
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

    it "drops robots.txt/sitemap.xml when Layer 2 excludes them, and keeps the seed" do
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      denied = Set{"http://t/robots.txt", "http://t/sitemap.xml"}
      sent = [] of String
      run_discover("http://t/", [] of String, cfg, DenyExact.new(denied)) do |t|
        sent << t
        t == "/" ? html("home, no links") : notfound
      end
      sent.should eq(["/"])
    end

    it "still fetches both when nothing denies them (the control for the case above)" do
      cfg = D::Config.new(spider: true, bruteforce: false, concurrency: 1, retries: 0)
      sent = [] of String
      run_discover("http://t/", [] of String, cfg) do |t|
        sent << t
        t == "/" ? html("home, no links") : notfound
      end
      sent.sort.should eq(["/", "/robots.txt", "/sitemap.xml"])
    end

    it "gates the origin calibration a path-scoped run queues to grade those two paths" do
      # The seed-only calibration is the LARGEST part of the trio's blast radius — one bogus
      # probe per calibrate_probes, at the origin root, on a run confined to /app/. Denying
      # the root dir alone leaves the seed and both well-known paths allowed, so what this
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
end
