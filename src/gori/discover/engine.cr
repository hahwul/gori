require "./types"
require "./url"
require "./fingerprint"
require "./extract"
require "./calibrate"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../proxy/codec/content_decode"

module Gori::Discover
  # Injected scope policy — keeps the engine Store-free. `allowed?` is the excludes/sandbox
  # gate applied in EVERY containment mode; `boundary?` is the include-allowlist used only
  # for scope-aware containment; `configured?` gates the scope-aware → same-origin fallback.
  abstract class ScopePolicy
    abstract def allowed?(url : String, host : String) : Bool
    abstract def boundary?(url : String, host : String) : Bool
    abstract def configured? : Bool
  end

  # Default policy (specs / unconfigured scope): nothing blocked, no include boundary.
  class OpenScope < ScopePolicy
    def allowed?(url : String, host : String) : Bool
      true
    end

    def boundary?(url : String, host : String) : Bool
      true
    end

    def configured? : Bool
      false
    end
  end

  # The send seam. Multi-origin (a crawl derives URLs on possibly several in-scope hosts),
  # so unlike Fuzz::Sender it dials the URL's OWN origin per fetch. Swappable so specs drive
  # the engine deterministically without a socket.
  abstract class Backend
    abstract def fetch(scheme : String, host : String, port : Int32, target : String) : Repeater::Result
  end

  # Production backend over the Repeater engine (fresh connection per send). GET only.
  class Sender < Backend
    @header_block : String

    def initialize(@verify : Bool, @timeout : Time::Span? = nil, @http2 : Bool = false,
                   headers : Array({String, String}) = [] of {String, String})
      # Merge the user headers over the defaults once — the block is identical for
      # every send (only Host varies, per target). Host + Connection are emitted
      # separately in build_get and never come from user input.
      @header_block = Headers.merge(headers).map { |name, value| "#{name}: #{value}\r\n" }.join
    end

    def fetch(scheme : String, host : String, port : Int32, target : String) : Repeater::Result
      req = build_get(scheme, host, port, target)
      if @http2
        Repeater::H2Engine.send(req, scheme: scheme, host: host, port: port,
          verify_upstream: @verify, timeout: @timeout)
      else
        Repeater::Engine.send(req, scheme: scheme, host: host, port: port,
          verify_upstream: @verify, timeout: @timeout)
      end
    end

    private def build_get(scheme : String, host : String, port : Int32, target : String) : Bytes
      default = scheme == "https" ? 443 : 80
      hostline = port == default ? host : "#{host}:#{port}"
      "GET #{target} HTTP/1.1\r\nHost: #{hostline}\r\n#{@header_block}Connection: close\r\n\r\n".to_slice
    end
  end

  # Enforces a HARD ceiling on total real sends (max_requests) across crawl, calibration,
  # and brute probes — past the cap it returns a benign error WITHOUT touching the network.
  class CappedBackend < Backend
    CAP_ERROR = "max-requests cap reached"

    getter sent : Int64 = 0_i64

    def initialize(@inner : Backend, @cap : Int64?)
    end

    def cap_reached? : Bool
      (c = @cap) && c > 0 ? @sent >= c : false
    end

    def fetch(scheme : String, host : String, port : Int32, target : String) : Repeater::Result
      return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, CAP_ERROR) if cap_reached?
      @sent += 1
      @inner.fetch(scheme, host, port, target)
    end
  end

  # A unit of work owned by the orchestrator frontier.
  private enum TaskKind
    Crawl     # GET a page, extract links
    Fetch     # GET robots.txt / sitemap.xml, extract seeds
    Calibrate # build a DirBaseline for a directory (K bogus probes)
    Probe     # brute-force one wordlist entry against a calibrated dir
  end

  private record Task,
    kind : TaskKind,
    url : String,
    depth : Int32,
    source : Source,
    dir : String? = nil,
    baseline : Calibrate::DirBaseline? = nil

  private record RawLink, href : String, source : Source

  # Worker → orchestrator. One per received Task, so the orchestrator's @pending balances.
  private record Outcome,
    task : Task,
    fetched : Calibrate::Fetched?,
    links : Array(RawLink),
    baseline : Calibrate::DirBaseline?,
    hit : Bool,
    confidence : Float64

  # The spider + brute-force engine. Single-threaded fiber scheduler (no -Dpreview_mt), so
  # the ORCHESTRATOR fiber owns all bookkeeping state (frontier/seen/templates/dirs/clusters)
  # with zero locks; N worker fibers only do network I/O + CPU (decode/extract/fingerprint)
  # and feed Outcomes back over a channel. Mirrors the Fuzz/Miner lifecycle shape.
  class Engine
    EVENT_BUFFER    =  256
    MAX_CONCURRENCY =  500
    MAX_BODY        = 2 * 1024 * 1024 # decoded body cap (matches Extract::MAX_SCAN)

    enum State : UInt8
      Running
      Paused
      Stopped
    end

    getter events : Channel(Event)

    EMPTY_LINKS = [] of RawLink

    @setup_error : String?
    @seed_parts : Url::Parts
    @confine_path : String?
    @capped : CappedBackend
    @concurrency : Int32
    @state : State
    @wake : Channel(Nil)
    @jobs : Channel(Task)
    @discovered : Channel(Outcome)
    @finished : Channel(Nil)
    @frontier : Deque(Task)
    @seen : Set(String)
    @templates : Hash(String, Int32)
    @dirs : Set(String)
    @found_urls : Set(String)
    @clusters : ClusterMap
    @pending : Int32
    @found : Int32
    @errors : Int64
    @pages : Int32
    @crawl_enqueued : Int32
    @calibrated_out : Int32
    @dedup_suppressed : Int32
    @template_suppressed : Int32
    @cluster_suppressed : Int32
    @uncalibratable : Int32
    @conf_hist : Array(Int32)
    @last_dispatch : Time::Instant
    @phase : Phase

    def initialize(seed_url : String, @words : Array(String), backend : Backend,
                   @config : Config, @scope : ScopePolicy = OpenScope.new)
      sp = Url.parse(seed_url)
      @setup_error = sp ? nil : "invalid seed url: #{seed_url}"
      @seed_parts = sp || Url::Parts.new("http", "invalid.invalid", 80, "/", nil)
      # A path-scoped run (seed path deeper than "/") confines discovery to that subtree.
      @confine_path = @seed_parts.path == "/" ? nil : @seed_parts.path
      @capped = CappedBackend.new(backend, @config.max_requests)
      conc = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @concurrency = conc
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @jobs = Channel(Task).new(conc)
      @discovered = Channel(Outcome).new(conc * 2)
      @finished = Channel(Nil).new(conc)
      @events = Channel(Event).new(EVENT_BUFFER)
      @frontier = Deque(Task).new
      @seen = Set(String).new
      @templates = Hash(String, Int32).new
      @dirs = Set(String).new
      @found_urls = Set(String).new
      @clusters = ClusterMap.new
      @pending = 0
      @found = 0
      @errors = 0_i64
      @pages = 0
      @crawl_enqueued = 0
      @calibrated_out = 0
      @dedup_suppressed = 0
      @template_suppressed = 0
      @cluster_suppressed = 0
      @uncalibratable = 0
      @conf_hist = [0, 0, 0, 0]
      @last_dispatch = Time.instant
      @phase = Phase::Seeding
    end

    def start : Nil
      if err = @setup_error
        # ErrorEvent is the sole terminal event on failure — a trailing DoneEvent would let
        # consumers settle a "0 found" success over the error (double job-finish, masked error).
        @events.send(ErrorEvent.new(err))
        @events.close
        return
      end
      spawn(name: "discover-orch") { orchestrate }
      @concurrency.times { |i| spawn(name: "discover-worker-#{i}") { worker_loop } }
    end

    # Blocking drain — for synchronous consumers (CLI, the MCP background fiber).
    def run(& : Event ->) : Nil
      start
      while ev = @events.receive?
        yield ev
      end
    end

    def stop : Nil
      @state = State::Stopped
      poke
    end

    def pause : Nil
      @state = State::Paused
    end

    def resume : Nil
      @state = State::Running
      poke
    end

    def stopped? : Bool
      @state == State::Stopped
    end

    # ── orchestrator (single owner of all bookkeeping) ──────────────────────────────

    private def orchestrate : Nil
      seed_frontier
      @phase = Phase::Crawling
      interval = pace_interval
      loop do
        break if @state == State::Stopped
        if job = @frontier.first?
          park_if_paused
          break if @state == State::Stopped || @capped.cap_reached?
          # select so we never block solely on send while a worker blocks solely on
          # @discovered.send — either side makes progress.
          select
          when @jobs.send(job)
            @frontier.shift
            @pending += 1
            pace(interval)
          when oc = @discovered.receive
            handle(oc)
            @pending -= 1
          end
        else
          break if @pending == 0 # frontier empty AND nothing in flight ⇒ no more work
          handle(@discovered.receive)
          @pending -= 1
        end
        emit_progress
      end
      drain_pending
      @jobs.close
      @concurrency.times { @finished.receive }
      @events.send(DoneEvent.new(progress_snapshot, run_stats, @state == State::Stopped))
      @events.close
    rescue ex
      # ErrorEvent is terminal (no trailing DoneEvent) so consumers don't mask the error
      # with a success Done — see the setup-error path above.
      @events.send(ErrorEvent.new(ex.message || "discover error")) rescue nil
      @events.close rescue nil
    end

    # Receive the outcomes of every dispatched-but-unhandled task before closing @jobs, so
    # no finding is lost and no worker blocks on @discovered.send after the loop exits.
    private def drain_pending : Nil
      @phase = Phase::Draining
      while @pending > 0
        handle(@discovered.receive)
        @pending -= 1
      end
    end

    private def seed_frontier : Nil
      @seen << Url.visit_key(@seed_parts)
      if @config.spider?
        @crawl_enqueued += 1
        @frontier << Task.new(TaskKind::Crawl, Url.normalize(@seed_parts), 0, Source::Seed)
        root = Url.origin(@seed_parts)
        @frontier << Task.new(TaskKind::Fetch, "#{root}/robots.txt", 0, Source::Robots)
        @frontier << Task.new(TaskKind::Fetch, "#{root}/sitemap.xml", 0, Source::Sitemap)
      end
      enqueue_dir(Url.dir_of(@seed_parts), 0) if @config.bruteforce?
    end

    private def handle(oc : Outcome) : Nil
      case oc.task.kind
      in TaskKind::Calibrate         then handle_calibrate(oc)
      in TaskKind::Probe             then handle_probe(oc)
      in TaskKind::Crawl, TaskKind::Fetch then handle_crawl(oc)
      end
    end

    private def handle_crawl(oc : Outcome) : Nil
      task = oc.task
      @pages += 1 if task.kind == TaskKind::Crawl
      fetched = oc.fetched
      return unless fetched
      if fetched.error
        @errors += 1
        return
      end
      record_page(task, fetched)
      count = @clusters.observe(fetched.simhash, @config.simhash_distance)
      if count > @config.cluster_saturation
        @cluster_suppressed += oc.links.size # a template/listing trap — stop expanding it
      else
        oc.links.each { |lnk| consider_link(task, lnk) }
      end
      if @config.follow_redirects? && (loc = fetched.redirect_to)
        consider_link(task, RawLink.new(loc, Source::Redirect))
      end
    end

    private def handle_calibrate(oc : Outcome) : Nil
      bl = oc.baseline
      return unless bl
      @uncalibratable += 1 if bl.kind.uncalibratable?
      @events.send(BaselineEvent.new(bl.dir, bl.kind.label, nil))
      enqueue_probes(oc.task, bl)
    end

    private def handle_probe(oc : Outcome) : Nil
      fetched = oc.fetched
      return unless fetched
      if fetched.error
        @errors += 1 unless fetched.error == CappedBackend::CAP_ERROR
        return
      end
      if oc.hit && oc.confidence >= @config.confidence_floor
        record_finding(Finding.new(oc.task.url, "GET", fetched.status, fetched.length,
          fetched.content_type, Source::Bruteforced, oc.task.depth, oc.confidence, nil))
        s = fetched.status
        if s && s >= 200 && s < 300 && oc.task.depth < @config.max_depth
          enqueue_dir_from_url(oc.task.url, oc.task.depth + 1) # a hit that's a container → recurse
        end
      else
        @calibrated_out += 1
      end
    end

    # Record a crawled/declared page as a finding (skip 404/5xx noise; 401/403 are kept —
    # they exist but gate access).
    private def record_page(task : Task, fetched : Calibrate::Fetched) : Nil
      s = fetched.status
      return unless s && (s < 400 || s == 401 || s == 403)
      conf = crawl_confidence(task.source, s)
      record_finding(Finding.new(task.url, "GET", s, fetched.length, fetched.content_type,
        task.source, task.depth, conf, nil))
    end

    private def crawl_confidence(source : Source, status : Int32) : Float64
      if source.robots? || source.sitemap?
        status < 400 ? 0.9 : 0.7
      elsif status >= 200 && status < 300
        0.95
      else
        0.85
      end
    end

    private def record_finding(f : Finding) : Nil
      return unless @found_urls.add?(f.url)
      @found += 1
      bump_conf_hist(f.confidence)
      @events.send(FindingEvent.new(f))
    end

    private def bump_conf_hist(c : Float64) : Nil
      idx = c >= 0.95 ? 3 : (c >= 0.85 ? 2 : (c >= 0.7 ? 1 : 0))
      @conf_hist[idx] += 1
    end

    # Resolve a discovered link against its page, dedup, template-fold, bound-check, then
    # enqueue a crawl (spider) and derive a directory (brute).
    private def consider_link(task : Task, link : RawLink) : Nil
      base = Url.parse(task.url)
      return unless base
      abs = Url.resolve(base, link.href)
      return unless abs
      p = Url.parse(abs)
      return unless p
      key = Url.visit_key(p)
      if @seen.includes?(key)
        @dedup_suppressed += 1
        return
      end
      tkey = Url.template_key(p)
      tc = (@templates[tkey]? || 0) + 1
      @templates[tkey] = tc
      if tc > @config.template_saturation
        @template_suppressed += 1
        return
      end
      return unless within_bounds?(p)
      @seen << key
      if @config.spider? && task.depth < @config.max_depth && @crawl_enqueued < @config.max_pages
        @crawl_enqueued += 1
        @frontier << Task.new(TaskKind::Crawl, Url.normalize(p), task.depth + 1, link.source)
      end
      enqueue_dir(Url.dir_of(p), task.depth) if @config.bruteforce?
    end

    private def enqueue_dir_from_url(url : String, depth : Int32) : Nil
      p = Url.parse(url)
      return unless p
      dir = Url.normalize(p)
      dir += "/" unless dir.ends_with?('/')
      enqueue_dir(dir, depth)
    end

    private def enqueue_dir(dir : String, depth : Int32) : Nil
      return unless @config.bruteforce?
      return if depth > @config.max_depth
      return if @dirs.includes?(dir)
      dp = Url.parse(dir)
      return unless dp && within_bounds?(dp)
      @dirs << dir
      @frontier << Task.new(TaskKind::Calibrate, dir, depth, Source::Bruteforced, dir: dir)
    end

    private def enqueue_probes(task : Task, bl : Calibrate::DirBaseline) : Nil
      cap = @config.per_dir_cap
      count = 0
      @words.each do |w|
        break if @capped.cap_reached?
        candidates = [w]
        @config.extensions.each { |ext| candidates << "#{w}.#{ext}" }
        candidates.each do |cand|
          break if cap > 0 && count >= cap
          p = Url.parse("#{bl.dir}#{cand}")
          next unless p
          key = Url.visit_key(p)
          next if @seen.includes?(key)
          @seen << key
          count += 1
          @frontier << Task.new(TaskKind::Probe, Url.normalize(p), task.depth,
            Source::Bruteforced, dir: bl.dir, baseline: bl)
        end
        break if cap > 0 && count >= cap
      end
    end

    # Containment (origin/subdomain/scope-aware) + the injected scope policy + path confine.
    private def within_bounds?(p : Url::Parts) : Bool
      if cp = @confine_path
        return false unless p.path.starts_with?(cp)
      end
      url = Url.normalize(p)
      return false unless @scope.allowed?(url, p.host) # excludes/sandbox — every mode
      case @config.containment
      in Containment::SameOrigin        then same_origin?(p)
      in Containment::HostAndSubdomains then same_or_subdomain?(p)
      in Containment::ScopeAware        then @scope.configured? ? @scope.boundary?(url, p.host) : same_origin?(p)
      end
    end

    private def same_origin?(p : Url::Parts) : Bool
      p.scheme == @seed_parts.scheme && p.host == @seed_parts.host && p.port == @seed_parts.port
    end

    private def same_or_subdomain?(p : Url::Parts) : Bool
      p.host == @seed_parts.host || p.host.ends_with?(".#{@seed_parts.host}")
    end

    # ── worker fibers ───────────────────────────────────────────────────────────────

    private def worker_loop : Nil
      while task = @jobs.receive?
        # Every received task MUST yield exactly one Outcome, or @pending never balances and
        # the orchestrator hangs. On stop, a stub (no send). On an unexpected raise inside
        # process, an error Outcome — never let the exception escape and drop the task.
        oc =
          begin
            @state == State::Stopped ? Outcome.new(task, nil, EMPTY_LINKS, nil, false, 0.0) : process(task)
          rescue ex
            Outcome.new(task, Calibrate::Fetched.new(nil, 0_i64, nil, 0_u64, nil, ex.message || "worker error"),
              EMPTY_LINKS, nil, false, 0.0)
          end
        @discovered.send(oc)
      end
    ensure
      @finished.send(nil)
    end

    private def process(task : Task) : Outcome
      case task.kind
      in TaskKind::Crawl, TaskKind::Fetch then process_fetch(task)
      in TaskKind::Calibrate              then process_calibrate(task)
      in TaskKind::Probe                  then process_probe(task)
      end
    end

    private def process_fetch(task : Task) : Outcome
      raw = send_with_retries(task.url)
      body = decode_body(raw)
      fetched = distill(raw, body)
      links = raw.error.nil? ? extract_links(task, fetched, body) : EMPTY_LINKS
      Outcome.new(task, fetched, links, nil, false, 0.0)
    end

    # Pick the link extractor from the RESPONSE, not from how the URL was found. Only the
    # well-known robots.txt (fetched by role at its fixed path) is parsed by label — it is
    # plain text and never sniffable. Everything else defers to the body: a <loc>-bearing
    # payload is a sitemap (the well-known /sitemap.xml, a <sitemapindex> child, OR a
    # robots.txt `Sitemap:` URL at any path), and only genuine HTML is parsed as HTML. This
    # stops a non-standard-path sitemap from being wrongly parsed as HTML and lost.
    private def extract_links(task : Task, fetched : Calibrate::Fetched, body : Bytes) : Array(RawLink)
      if task.kind.fetch? && task.source.robots?
        return Extract.from_robots(body).map { |h| RawLink.new(h, Source::Robots) }
      end
      if Extract.sitemap_body?(body)
        Extract.from_sitemap(body).map { |h| RawLink.new(h, Source::Sitemap) }
      elsif html_like?(fetched.content_type)
        Extract.from_html(body).map { |h| RawLink.new(h, Source::Crawled) }
      else
        EMPTY_LINKS
      end
    end

    private def process_calibrate(task : Task) : Outcome
      dir = task.dir || task.url
      probes = [] of Calibrate::Fetched
      @config.calibrate_probes.times do
        break if @capped.cap_reached?
        probes << distill_only("#{dir}#{bogus_name}")
      end
      @config.extensions.each do |ext|
        break if @capped.cap_reached?
        probes << distill_only("#{dir}#{bogus_name}.#{ext}")
      end
      baseline = Calibrate.build(dir, probes, @config.simhash_distance)
      Outcome.new(task, nil, EMPTY_LINKS, baseline, false, 0.0)
    end

    private def process_probe(task : Task) : Outcome
      fetched = distill_only(task.url)
      bl = task.baseline
      if bl
        hit, conf = Calibrate.hit?(bl, fetched)
        Outcome.new(task, fetched, EMPTY_LINKS, nil, hit, conf)
      else
        Outcome.new(task, fetched, EMPTY_LINKS, nil, false, 0.0)
      end
    end

    private def send_with_retries(url : String) : Repeater::Result
      p = Url.parse(url)
      return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "unparseable url") unless p
      target = p.query ? "#{p.path}?#{p.query}" : p.path
      attempts = 0
      loop do
        raw = @capped.fetch(p.scheme, p.host, p.port, target)
        if raw.error && raw.error != CappedBackend::CAP_ERROR && attempts < @config.retries
          attempts += 1
          sleep @config.retry_pause
          next
        end
        return raw
      end
    end

    private def distill_only(url : String) : Calibrate::Fetched
      raw = send_with_retries(url)
      distill(raw, decode_body(raw))
    end

    private def distill(raw : Repeater::Result, body : Bytes) : Calibrate::Fetched
      status = raw.response.try(&.status)
      ct = raw.response.try(&.headers.get?("content-type"))
      loc = raw.response.try(&.headers.get?("location"))
      Calibrate::Fetched.new(status, body.size.to_i64, ct, Fingerprint.simhash(body), loc, raw.error)
    end

    private def decode_body(raw : Repeater::Result) : Bytes
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body)
      body = decoded || raw.body || Bytes.new(0)
      body.size > MAX_BODY ? body[0, MAX_BODY] : body
    end

    private def html_like?(ct : String?) : Bool
      return true unless ct
      c = ct.downcase
      c.includes?("html") || c.includes?("xml") || c.includes?("xhtml") || c.empty?
    end

    private def bogus_name : String
      Random::Secure.hex(8)
    end

    # ── pacing / lifecycle (orchestrator-local clock → no cross-fiber race) ──────────

    private def pace_interval : Time::Span?
      if (rps = @config.rps) && rps > 0
        (1.0 / rps).seconds
      elsif (t = @config.throttle_ms) && t > 0
        t.milliseconds
      else
        nil
      end
    end

    private def pace(interval : Time::Span?) : Nil
      if interval
        now = Time.instant
        target = @last_dispatch + interval
        sleep(target - now) if now < target
        @last_dispatch = Time.instant
      end
      sleep(rand(@config.jitter_ms).milliseconds) if @config.jitter_ms > 0
    end

    private def park_if_paused : Nil
      while @state == State::Paused
        @wake.receive
      end
    end

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end

    private def emit_progress : Nil
      ev = ProgressEvent.new(progress_snapshot)
      select
      when @events.send(ev)
      else
      end
    end

    private def progress_snapshot : Progress
      Progress.new(@capped.sent, est_total, @found, @errors, @frontier.size + @pending, @phase)
    end

    # A moving estimate that RISES as directories calibrate and pages are visited — a live
    # crawl has no stable denominator, so frontends render counts, not a hard percent.
    private def est_total : Int64?
      return nil if @capped.sent == 0
      per_dir = @words.size.to_i64 * (1 + @config.extensions.size)
      brute = @config.bruteforce? ? @dirs.size.to_i64 * per_dir : 0_i64
      crawl = @pages.to_i64 + @frontier.size.to_i64
      brute + crawl
    end

    private def run_stats : RunStats
      RunStats.new(@capped.sent, @found, @calibrated_out, @dedup_suppressed,
        @template_suppressed, @cluster_suppressed, @uncalibratable, @conf_hist.dup)
    end
  end
end
