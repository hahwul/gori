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
end
