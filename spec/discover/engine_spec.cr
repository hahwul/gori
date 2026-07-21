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

private def run_discover(seed : String, words : Array(String), cfg : D::Config, &route : String -> R) : {Array(D::Finding), D::RunStats}
  backend = RouteBackend.new(route)
  engine = D::Engine.new(seed, words, backend, cfg)
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
end
