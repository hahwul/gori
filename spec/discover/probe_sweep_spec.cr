require "../spec_helper"

private alias D = Gori::Discover
private alias R = Gori::Repeater::Result

# The brute-force frontier: WHICH candidates a calibrated directory sends, in WHAT order, and
# how the dedup rule, the scope gate, `per_dir_cap` and `max_requests` bound them. Pinned as
# the exact request sequence, so a change to how the frontier holds a directory's probes (it
# used to hold every one as its own Task from the moment the directory calibrated) has to
# reproduce the same traffic.

# Records every target in order and answers from a route; anything unrouted is a 404 soft
# enough that the calibrator settles on it (the bogus probes land there too).
private class RecordingBackend < D::Backend
  getter targets = [] of String

  def initialize(@route : String -> R?)
  end

  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    @targets << target
    @route.call(target) || page(404, "nothing here at all, a plain not-found page")
  end
end

# Denies one path, so the scope gate (`probe_allowed?`) has something to refuse.
private class DenyPolicy < D::ScopePolicy
  def initialize(@deny : String)
  end

  def allowed?(url : String, host : String, exclude_url : String?) : Bool
    !url.includes?(@deny)
  end

  def boundary?(url : String, host : String) : Bool
    true
  end

  def configured? : Bool
    false
  end
end

private def page(status : Int32, body : String) : R
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
  R.new(head, body.to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1000_i64)
end

# The seed links one wordlist entry (`/beta`, crawled first, so its probe is a duplicate) and a
# page in a second directory (`/sub/`, which then calibrates and gets its own sweep). `/gamma`
# is a real endpoint: its hit names `/zeta` and makes `/gamma/` a directory of its own, so work
# lands in the frontier WHILE the other directories' probes are still waiting in it.
private def route(target : String) : R?
  case target
  when "/"         then page(200, %(<html><a href="/beta">b</a> <a href="/sub/page">p</a></html>))
  when "/beta"     then page(200, "<html>beta page, a real one</html>")
  when "/sub/page" then page(200, "<html>sub page</html>")
  when "/gamma"    then page(200, %(<html>gamma is real <a href="/zeta">z</a></html>))
  end
end

# The targets a run sent, in order, that a wordlist entry or the `/gamma` hit names. The seed
# crawl, the well-known fetches, the linked pages and the calibrator's 16-hex bogus names are
# not brute-force candidates; `/beta` is the linked page, crawled once.
private def probes_of(targets : Array(String)) : Array(String)
  targets.select(&.matches?(/\A(\/sub|\/gamma)?\/(alpha|beta|admin|gamma|blocked|zeta)/))
    .reject { |t| t == "/beta" || t.matches?(/\/[0-9a-f]{16}(\.\w+)?\z/) }
end

private WORDS = ["alpha", "beta", "admin.php", "gamma", "alpha", "blocked"]

private def run(cfg : D::Config, policy : D::ScopePolicy = D::OpenScope.new) : Array(String)
  backend = RecordingBackend.new(->route(String))
  D::Engine.new("http://t.test/", WORDS, backend, cfg, policy).run { |_| }
  backend.targets
end

private def config(**opts) : D::Config
  D::Config.new(**opts, concurrency: 1, retries: 0, extensions: ["php", "bak"], max_depth: 2,
    containment: D::Containment::SameOrigin, keep_alive: false)
end

private def sweep(dir : String, skip : Array(String) = [] of String) : Array(String)
  ["alpha", "alpha.php", "alpha.bak", "beta", "beta.php", "beta.bak", "admin.php",
   "admin.php.bak", "gamma", "gamma.php", "gamma.bak", "blocked", "blocked.php",
   "blocked.bak"].reject { |c| skip.includes?(c) }.map { |c| "#{dir}#{c}" }
end

describe "Discover brute-force frontier" do
  # The exact sequence at concurrency 1: each directory's candidates in wordlist order —
  # `beta` already crawled at the root, `admin.php.php` a redundant extension, the second
  # `alpha` a duplicate — and `/zeta` (found by the `/gamma` hit) behind every probe that was
  # already waiting when it was found, ahead of the `/gamma/` sweep calibrated after it.
  it "sends every candidate once, in the order the directories calibrated" do
    probes_of(run(config)).should eq(
      sweep("/", ["beta"]) + sweep("/sub/") + ["/zeta"] + sweep("/gamma/"))
  end

  it "applies the scope gate to each candidate" do
    probes = probes_of(run(config, DenyPolicy.new("/blocked")))
    probes.none?(&.includes?("blocked")).should be_true
    probes.should contain("/gamma.bak")
  end

  it "stops a directory at per_dir_cap" do
    probes = probes_of(run(config(per_dir_cap: 4)))
    probes.reject(&.starts_with?("/sub/")).should eq(["/alpha", "/alpha.php", "/alpha.bak", "/beta.php"])
    probes.select(&.starts_with?("/sub/")).should eq(["/sub/alpha", "/sub/alpha.php", "/sub/alpha.bak", "/sub/beta"])
  end

  # The cap cuts the SAME sequence short: a capped run sends exactly the uncapped run's first
  # N requests (bogus calibration names masked — they are random), and says it stopped short.
  it "stops at max_requests on the same sequence, and reports the budget as exhausted" do
    mask = ->(ts : Array(String)) { ts.map(&.gsub(/[0-9a-f]{16}/, "BOGUS")) }
    full = mask.call(run(config))
    [20, 40, full.size - 10].each do |n|
      backend = RecordingBackend.new(->route(String))
      engine = D::Engine.new("http://t.test/", WORDS, backend, config(max_requests: n.to_i64))
      done = nil.as(D::DoneEvent?)
      engine.run { |ev| done = ev if ev.is_a?(D::DoneEvent) }
      mask.call(backend.targets).should eq(full[0, n])
      done.should_not be_nil
      done.not_nil!.budget_exhausted.should be_true
    end
  end

  # `queued` counts every probe still waiting, however the frontier holds them. The series
  # this run emits was recorded against the one-Task-per-probe frontier and is unchanged; its
  # peak is the root and `/sub/` sweeps waiting at once.
  it "counts undispatched probes in the progress queue" do
    backend = RecordingBackend.new(->route(String))
    engine = D::Engine.new("http://t.test/", WORDS, backend, config)
    series = [] of Int32
    engine.run { |ev| series << ev.progress.queued if ev.is_a?(D::ProgressEvent) }
    series.max.should eq(27)
    series.last.should eq(0)
  end
end
