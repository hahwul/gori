require "./types"
require "./url"
require "./headers"
require "./fingerprint"
require "./extract"
require "./calibrate"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/conn_pool"
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

    # Release any transport the backend is holding open (the keep-alive pools' parked
    # sockets). Called once when a run ends — including a stopped or failed one, or the
    # sockets sit open until GC. A no-op by default so the spec doubles stay three-line
    # classes, matching `Fuzz::Backend#close`.
    def close : Nil
    end
  end

  # What a run's transport actually cost, summed over every origin's keep-alive pool.
  # `dialed ≈ sent` means the origins closed after every response (or refused reuse), which
  # is the one thing that explains a slow run the request counts do not.
  record PoolStats,
    dialed : Int64,
    reused : Int64,
    stale_retries : Int64,
    pooling : Bool

  # Production backend over the Repeater engine. GET only.
  class Sender < Backend
    # A send refused because the URL cannot be framed. `target` and `host` are spliced
    # verbatim into the request line and the `Host` header by `build_get`, so a raw CR/LF in
    # either splices a SECOND, fully attacker-chosen request (method, absolute-form request
    # line, and Host) onto the same connection. The victim is the ORIGIN gori dialled: an
    # upstream proxy cannot be made to route the injected absolute-form line elsewhere,
    # because `Upstream.dial` always CONNECT-tunnels (`proxy/upstream.cr`) rather than
    # forwarding in absolute form. Returned as a benign error Result rather than raised: the
    # caller's contract is one Result per fetch, and one poisoned link must not end the run.
    #
    # The refusal covers the whole `Codec::Http1.request_token_safe?` class, not just CR/LF: a
    # bare SP forges the line just as effectively (`GET /a b HTTP/1.1` — a lenient origin reads
    # target `/a`, version `b`), which is what #394 found after #390. Nothing legitimate is
    # lost by refusing the repairable half here, because `Url.parse` has already
    # percent-encoded it upstream — this line only ever sees a target no repair applies to.
    UNSAFE_URL = "url contains whitespace or a control character"

    # How many origins may hold a keep-alive pool at once. A crawl is overwhelmingly
    # single-origin (same-origin containment, or scope-aware with the seed's host), but
    # host+subdomains and a multi-host include boundary can spread it, and each pool parks its
    # own sockets — so an unbounded map is an unbounded file-descriptor count. Past the cap a
    # new origin simply dials per send, which is what every origin did before.
    MAX_POOLS = 4

    # Ceiling on the sockets ONE origin's pool may park, applied on top of the run's
    # concurrency. Unlike `Fuzz::Sender` (one origin, so concurrency IS the ceiling), here the
    # worst case is every worker having touched every pooled origin — MAX_POOLS × concurrency
    # sockets alive at once. At the default concurrency of 20 this changes nothing; it only
    # bites the wide runs (the TUI offers 80, `--concurrency` more), where it trades some
    # reuse for a bounded descriptor count.
    MAX_IDLE_PER_POOL = 32

    @header_block : String
    @pools : Hash(String, Repeater::ConnPool)?
    @keep_alive : Bool
    @idle_conns : Int32

    # `keep_alive` reuses one HTTP/1.1 connection across many sends per origin (see
    # `Repeater::ConnPool`). It is the single largest cost of a run against a remote origin:
    # a brute-force pass is ~278 sends PER DIRECTORY, and dial-per-send paid a TCP — and on
    # https a TLS — handshake for every one of them. `idle_conns` bounds the sockets one
    # origin may park and should be the run's concurrency (one per worker fiber is the most
    # that can ever be checked out at once), capped at MAX_IDLE_PER_POOL.
    def initialize(@verify : Bool, @timeout : Time::Span? = nil, @http2 : Bool = false,
                   headers : Array({String, String}) = [] of {String, String},
                   @overrides : Gori::HostOverrides? = nil,
                   keep_alive : Bool = false, idle_conns : Int32 = 0)
      # Merge the user headers over the defaults once — the block is identical for
      # every send (only Host varies, per target). Host + Connection are emitted
      # separately in build_get and never come from user input.
      @header_block = Headers.merge(headers).map { |name, value| "#{name}: #{value}\r\n" }.join
      # h2 is excluded for the reason Fuzz::Sender excludes it: H2Engine frames its own
      # connection per send, and multiplexing it is a separate change with its own
      # stream-state rules.
      @keep_alive = keep_alive && !@http2
      @idle_conns = idle_conns.clamp(1, MAX_IDLE_PER_POOL)
      @pools = @keep_alive ? Hash(String, Repeater::ConnPool).new : nil
    end

    # Handshake accounting summed over every origin's pool. Nil when keep-alive is off — the
    # question "how many handshakes did this run pay" has no pool to ask.
    def pool_stats : PoolStats?
      pools = @pools
      return nil unless pools
      dialed = 0_i64
      reused = 0_i64
      stale = 0_i64
      pooling = true
      pools.each_value do |p|
        dialed += p.dialed
        reused += p.reused
        stale += p.stale_retries
        pooling = false unless p.pooling?
      end
      PoolStats.new(dialed, reused, stale, pooling)
    end

    def fetch(scheme : String, host : String, port : Int32, target : String) : Repeater::Result
      # The wire seam's own invariant, not a duplicate of the engine's gate: `Engine#bounded_url`
      # drops a poisoned URL before it is ever queued and `Url.parse` repairs a spaced one, but
      # this is the only line every send provably passes, so the guarantee "a Discover run
      # never puts a malformed or doubled request line on a connection" is stated where it can
      # actually be enforced (see UNSAFE_URL).
      unless Proxy::Codec::Http1.request_token_safe?(target) && Proxy::Codec::Http1.request_token_safe?(host)
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, UNSAFE_URL)
      end
      req = build_get(scheme, host, port, target)
      if @http2
        Repeater::H2Engine.send(req, scheme: scheme, host: host, port: port,
          verify_upstream: @verify, timeout: @timeout, overrides: @overrides)
      elsif pool = pool_for(scheme, host, port)
        pool.send(req)
      else
        Repeater::Engine.send(req, scheme: scheme, host: host, port: port,
          verify_upstream: @verify, timeout: @timeout, overrides: @overrides)
      end
    end

    def close : Nil
      @pools.try(&.each_value(&.close_all))
    end

    # The pool for one origin, created on first use. Nil when keep-alive is off or the
    # origin arrived after MAX_POOLS were already taken — both mean "dial per send".
    #
    # N worker fibers call this concurrently, and the lookup-then-insert below is not atomic
    # in general. It is here: the scheduler is single-threaded (no `-Dpreview_mt`) and nothing
    # between the `[]?` and the store yields — `ConnPool.new` only allocates — so no worker
    # can observe the map mid-insert or race a second pool onto the same origin. Same argument
    # the pool itself relies on for its idle list.
    private def pool_for(scheme : String, host : String, port : Int32) : Repeater::ConnPool?
      pools = @pools
      return nil unless pools
      key = "#{scheme}://#{host}:#{port}"
      if existing = pools[key]?
        return existing
      end
      return nil if pools.size >= MAX_POOLS
      pool = Repeater::ConnPool.new(scheme, host, port, @verify, nil, @timeout,
        @overrides, @idle_conns)
      pools[key] = pool
      pool
    end

    private def build_get(scheme : String, host : String, port : Int32, target : String) : Bytes
      default = scheme == "https" ? 443 : 80
      hostline = port == default ? host : "#{host}:#{port}"
      # `Connection: close` only when NOT pooling. It is what made every send single-use, and
      # `ConnPool.reusable_request?` refuses to park a socket that carried it — so leaving it
      # in would turn keep-alive into a silent no-op. Omitting it is not a request for
      # keep-alive so much as the absence of a request to close: HTTP/1.1's default is
      # persistent, and an origin that disagrees says so in its own `Connection` header,
      # which `reusable_response?` reads.
      conn = @keep_alive ? "" : "Connection: close\r\n"
      "GET #{target} HTTP/1.1\r\nHost: #{hostline}\r\n#{@header_block}#{conn}\r\n".to_slice
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

    def close : Nil
      @inner.close
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
    baseline : Calibrate::DirBaseline? = nil,
    # A Calibrate task queued ONLY to gate robots.txt/sitemap.xml against a soft-404
    # baseline (see enqueue_seed_only_calibration) — never feeds enqueue_probes, so it
    # can't expand the brute-force wordlist onto a directory outside the run's own scope.
    seed_only : Bool = false

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
    EVENT_BUFFER    = 256
    MAX_CONCURRENCY = 500
    MAX_BODY        = 2 * 1024 * 1024 # decoded body cap (matches Extract::MAX_SCAN)
    # Ceiling on the dedup/template bookkeeping (@seen + @templates). The network send
    # count is capped by @config.max_requests and crawl pages by max_pages, but @seen and
    # @templates grow once per CONSIDERED link — bounded by pages×links, not the request
    # cap — so a pathological target (a huge page of distinct-template links) could bloat
    # them far past any real crawl. Once @seen hits this, consider_link stops tracking and
    # enqueuing new links: the run keeps draining what's in flight but adds nothing new.
    MAX_SEEN = 250_000
    # Setup error for a seed the Layer-2 gate refuses. A constant because it is the one
    # engine error a spec (and a surface) wants to recognize rather than merely display.
    SEED_BLOCKED = "seed blocked by scope (Sandbox or an exclude rule)"
    # A send the per-URL Layer-2 gate refused, in the shape CappedBackend uses for the request
    # cap: a benign Result, no network, and NOT counted as an error — a scope refusal is a
    # decision the operator asked for, not a failure of the run.
    SCOPE_REFUSED = "blocked by scope (Sandbox or an exclude rule)"
    # The run reached its end without putting a single request on the wire, so a DoneEvent
    # would report "0 found" — which an operator reads as "there is nothing there" rather than
    # "gori sent nothing" (P4). Terminal for exactly the reason SEED_BLOCKED is.
    #
    # The condition is `@capped.sent == 0`, deliberately, and NOT "seeding enqueued nothing".
    # An empty frontier is only the shape #395 found; a frontier whose every task is refused
    # later by the per-URL Layer-2 gate in `send_with_retries` ends in the same silence, and
    # that state became ordinary the moment the gate started re-reading the scope mid-run
    # (#396). Anchoring on the send counter covers both, plus whatever comes next: if nothing
    # went out, the run says so.
    NOTHING_TO_SEND = "nothing to send: no crawl page or brute-force candidate survived the scope and containment gates"

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
    @seed_calibration_dir : String?
    @seed_baseline : Calibrate::DirBaseline?
    @pending_seed_fetches : Array({Task, Calibrate::Fetched})

    def initialize(seed_url : String, @words : Array(String), backend : Backend,
                   @config : Config, @scope : ScopePolicy = OpenScope.new)
      sp = Url.parse(seed_url)
      @setup_error =
        if sp.nil?
          "invalid seed url: #{seed_url}"
        else
          # Layer 2 (Sandbox + explicit EXCLUDE) is the ONE gate the operator's own seed does
          # not waive. Layer 1 is already waived FOR it, per surface (`Outbound.interactive`
          # in the TUI, `--allow-unscoped` elsewhere) because a human typed the target — but
          # "the operator chose this" was never an argument about Sandbox, whose documented
          # promise is unconditional (DESIGN.md §3, and the §7 entry for #364).
          #
          # Refused up front as a TERMINAL error rather than by quietly enqueuing nothing: a
          # blocked seed blocks everything derived from it, so the alternative is a run that
          # finishes with zero findings and no reason, which reads as "there is nothing
          # there" instead of "gori sent nothing" (P4).
          # `gate_url`, not `normalize`: gori's scope model has no port dimension, so a
          # port-bearing URL misses a host-qualified string/regex include/exclude and the
          # seed check both falsely denies a legitimate non-default-port target and fails
          # open on an exclude (#407). Report the normalized URL, but ASK the port-less one.
          seed_norm = Url.normalize(sp)
          @scope.allowed?(Url.gate_url(sp), sp.host) ? nil : "#{SEED_BLOCKED}: #{seed_norm}"
        end
      @seed_parts = sp || Url::Parts.new("http", "invalid.invalid", 80, "/", nil)
      # A path-scoped run (seed path deeper than "/") confines discovery to that subtree.
      # Store the base with any single trailing slash stripped so bounded_url can test
      # containment on PATH-SEGMENT boundaries. The old raw-string-prefix check let a sibling
      # like /api-internal leak into an /api-scoped run (they share the "/api" prefix); a
      # trailing-slash target already excluded it, proving the leak was prefix- not segment-based.
      @confine_path = @seed_parts.path == "/" ? nil : @seed_parts.path.rchop('/')
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
      @seed_calibration_dir = nil
      @seed_baseline = nil
      @pending_seed_fetches = [] of {Task, Calibrate::Fetched}
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
      # Every worker has exited, so nothing holds a checked-out socket: release the parked
      # ones now rather than leaving a run's worth of file descriptors to the GC. AFTER the
      # join, deliberately — closing while a worker is mid-exchange would only close the
      # sockets it is NOT using, but the join is already the point where "the run is over"
      # becomes true, and doing it in one place keeps that readable.
      @capped.close
      # A run that put nothing on the wire ends in a terminal ErrorEvent — no trailing
      # DoneEvent, so a consumer cannot settle a "0 found" success over it, the same shape
      # `start`'s setup-error path uses (see NOTHING_TO_SEND). Decided HERE rather than right
      # after `seed_frontier` for two reasons: the send counter is only final once the run is,
      # and the shutdown sequence above (close @jobs, join every worker) has to run either way
      # or the workers park on `@jobs.receive?` forever — the fiber + socket leak the rescue
      # clause below guards against.
      #
      # A run the operator STOPPED is exempt: stopping before the first send is a decision, not
      # a failure to have anything to do.
      if @capped.sent == 0 && @state != State::Stopped
        @events.send(ErrorEvent.new(NOTHING_TO_SEND))
      else
        @events.send(DoneEvent.new(progress_snapshot, run_stats, @state == State::Stopped))
      end
      @events.close
    rescue ex
      # ErrorEvent is terminal (no trailing DoneEvent) so consumers don't mask the error
      # with a success Done — see the setup-error path above.
      # Close @jobs too (the happy path does this at line ~285): otherwise the worker
      # fibers stay parked on @jobs.receive? forever — a fiber + socket leak. Closing it
      # makes each worker's receive? return nil, so they run their `ensure @finished.send`
      # and exit (their one in-flight outcome fits in @discovered's conc*2 buffer).
      @jobs.close rescue nil
      # Same reason: the parked sockets are nobody's, and this path does not join the workers,
      # so nothing else will ever close them. A socket a worker still holds is checked OUT and
      # therefore not in the pool's idle list, so this cannot pull one out from under it.
      @capped.close rescue nil
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
        # The seed itself needs no gate here — `initialize` already refused the whole run if
        # Layer 2 blocks it, so reaching this line means it passed.
        @crawl_enqueued += 1
        @frontier << Task.new(TaskKind::Crawl, Url.normalize(@seed_parts), 0, Source::Seed)
        root = Url.origin(@seed_parts)
        enqueue_well_known("#{root}/robots.txt", Source::Robots)
        enqueue_well_known("#{root}/sitemap.xml", Source::Sitemap)
      end
      bf_dir = bruteforce_root
      enqueue_dir(bf_dir, 0) if @config.bruteforce?
      # robots.txt/sitemap.xml are GUESSED well-known paths, not organically-linked ones — they
      # deserve the same soft-404 gate a brute-forced wordlist hit gets, not the "exists by
      # construction" trust record_page gives a crawled <a href>. Only wire this up when
      # bruteforce is on: that's the only mode with a calibration baseline to gate against.
      # The origin is calibrated separately — robots.txt/sitemap.xml always live there even on
      # a path-scoped run confined elsewhere — and `enqueue_seed_only_calibration`'s own @dirs
      # check reuses the bf_dir calibration when that dir IS the origin. Asking @dirs rather
      # than comparing `root_dir == bf_dir` is the whole fix for #393: the old comparison
      # assumed the `enqueue_dir` above had SUCCEEDED, but it goes through `bounded_url`, which
      # can still refuse it (Layer 2, or containment). No Calibrate task would be queued, yet
      # @seed_calibration_dir was set, so robots.txt and sitemap.xml were fetched for real and
      # then parked forever waiting on a baseline that never arrived: 2 real requests sent, 0
      # findings recorded, not even counted in calibrated_out. (The shape that first exposed
      # it — a file-shaped seed whose bf_dir fell outside its own confine — is gone with #395,
      # but the assumption it broke was never safe.)
      if @config.spider? && @config.bruteforce?
        root_dir = "#{Url.origin(@seed_parts)}/"
        # @seed_calibration_dir is set even when the Calibrate task below is refused, and that
        # is deliberate: it is what routes a robots/sitemap outcome to resolve_seed_finding
        # rather than record_page. With no baseline those outcomes park and are never counted
        # ("no baseline, no claim", see resolve_seed_finding) — whereas dropping the routing
        # would send them to record_page, which is exactly the raw-status trust that reports a
        # wildcard-200 server's robots.txt as a finding. Fail safe, not fail loud.
        @seed_calibration_dir = root_dir
        enqueue_seed_only_calibration(root_dir)
      end
    end

    # robots.txt / sitemap.xml are DERIVED, not typed: nothing but the run itself asked for
    # them, and they are anchored on the origin, so on a path-confined run they sit outside
    # the subtree by construction. They keep waiving Layer 1, containment and the path confine
    # for the calibration reason above — but not Layer 2, same as the seed (DESIGN.md §7,
    # #364). A blocked one is skipped silently rather than failing the run: unlike the seed,
    # the crawl is still meaningful without it.
    private def enqueue_well_known(url : String, source : Source) : Nil
      # `url` is built from Url.origin(@seed_parts), so its host IS the seed's host. Gate on the
      # PORT-LESS form (gate_url) — gori's scope has no port dimension, so a port-bearing URL
      # misses a host-qualified string/regex rule (#407). `url` keeps its port for the Fetch.
      gate = (p = Url.parse(url)) ? Url.gate_url(p) : url
      return unless @scope.allowed?(gate, @seed_parts.host)
      @frontier << Task.new(TaskKind::Fetch, url, 0, source)
    end

    # A Calibrate task queued ONLY to gate robots.txt/sitemap.xml (see seed_frontier) — unlike
    # enqueue_dir it never feeds enqueue_probes, so it can't brute-force the wordlist onto the
    # origin on a run confined to a deeper subtree. Bypasses the path confine and the
    # containment mode the same way the robots/sitemap Fetch tasks do (well-known paths are
    # always checked at the origin) — but not Layer 2: its bogus probes are real requests, and
    # `calibrate_probes + extensions.size` of them made this the largest single part of the
    # seed's formerly ungated blast radius (#364).
    private def enqueue_seed_only_calibration(dir : String) : Nil
      return if @dirs.includes?(dir)
      return unless p = Url.parse(dir)
      # Gate on the PORT-LESS form (#407), same as the seed and well-known checks.
      return unless @scope.allowed?(Url.gate_url(p), @seed_parts.host)
      @dirs << dir
      @frontier << Task.new(TaskKind::Calibrate, dir, 0, Source::Bruteforced, dir: dir, seed_only: true)
    end

    private def handle(oc : Outcome) : Nil
      case oc.task.kind
      in TaskKind::Calibrate              then handle_calibrate(oc)
      in TaskKind::Probe                  then handle_probe(oc)
      in TaskKind::Crawl, TaskKind::Fetch then handle_crawl(oc)
      end
    end

    private def handle_crawl(oc : Outcome) : Nil
      task = oc.task
      @pages += 1 if task.kind == TaskKind::Crawl
      fetched = oc.fetched
      return unless fetched
      if err = fetched.error
        @errors += 1 unless benign_error?(err)
        return
      end
      if @seed_calibration_dir && (task.source.robots? || task.source.sitemap?)
        resolve_seed_finding(task, fetched)
      else
        record_page(task, fetched)
      end
      expand_links(oc, task, fetched)
    end

    # The link-expansion half of handle_crawl: the page's own links unless its content cluster
    # has saturated, plus a followed redirect.
    private def expand_links(oc : Outcome, task : Task, fetched : Calibrate::Fetched) : Nil
      count = @clusters.observe(fetched.simhash, @config.simhash_distance)
      if count > @config.cluster_saturation
        @cluster_suppressed += oc.links.size # a template/listing trap — stop expanding it
      else
        # Parse the page's own URL ONCE for the whole link set: it is loop-invariant, and
        # consider_link used to re-run URI.parse (plus the host downcase and the scheme/path
        # substrings) for every href on the page.
        if base = Url.parse(task.url)
          oc.links.each { |lnk| consider_link(task, base, lnk) }
        end
      end
      if @config.follow_redirects? && (loc = fetched.redirect_to)
        if base = Url.parse(task.url)
          consider_link(task, base, RawLink.new(loc, Source::Redirect))
        end
      end
    end

    private def handle_calibrate(oc : Outcome) : Nil
      bl = oc.baseline
      return unless bl
      @uncalibratable += 1 if bl.kind.uncalibratable?
      @events.send(BaselineEvent.new(bl.dir, bl.kind.label, nil))
      if bl.dir == @seed_calibration_dir
        @seed_baseline = bl
        flush_pending_seed_fetches
      end
      enqueue_probes(oc.task, bl) unless oc.task.seed_only
    end

    private def handle_probe(oc : Outcome) : Nil
      fetched = oc.fetched
      return unless fetched
      if err = fetched.error
        @errors += 1 unless benign_error?(err)
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
    # A non-error "error": the engine's own budget or gate declining a send, not a failure
    # reaching the target. Neither is a fault the operator can act on, and both are decisions
    # they configured, so neither belongs in the error count every surface renders.
    #
    # `handle_probe` already excluded CAP_ERROR; `handle_crawl` excluded nothing, and with
    # max_requests set the orchestrator fills the @jobs buffer before any worker increments
    # @capped.sent — so `--max-requests 5` at the default concurrency reported dozens of
    # "errors" that were the cap working exactly as designed.
    private def benign_error?(err : String) : Bool
      err == CappedBackend::CAP_ERROR || err == SCOPE_REFUSED
    end

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

    # robots.txt/sitemap.xml are well-known GUESSES, not links a real page pointed at — gate
    # them through the same soft-404 baseline a brute-forced wordlist hit needs to clear,
    # instead of record_page's raw-status trust (a wildcard-200 server would otherwise report
    # both as "findings" even though it 200s literally everything). The baseline may not be
    # ready yet — its Calibrate task races this Fetch task — so an early arrival buffers here
    # until handle_calibrate delivers @seed_baseline; if the run stops before that ever
    # happens, the buffered entry is simply never counted (fail safe: no baseline, no claim).
    private def resolve_seed_finding(task : Task, fetched : Calibrate::Fetched) : Nil
      if bl = @seed_baseline
        record_seed_hit(task, fetched, bl)
      else
        @pending_seed_fetches << {task, fetched}
      end
    end

    private def flush_pending_seed_fetches : Nil
      return if @pending_seed_fetches.empty?
      return unless bl = @seed_baseline
      @pending_seed_fetches.each { |task, fetched| record_seed_hit(task, fetched, bl) }
      @pending_seed_fetches.clear
    end

    # Same hit/confidence gate handle_probe applies to a brute-forced wordlist entry.
    private def record_seed_hit(task : Task, fetched : Calibrate::Fetched, bl : Calibrate::DirBaseline) : Nil
      hit, conf = Calibrate.hit?(bl, fetched)
      if hit && conf >= @config.confidence_floor
        record_finding(Finding.new(task.url, "GET", fetched.status, fetched.length, fetched.content_type,
          task.source, task.depth, conf, nil))
      else
        @calibrated_out += 1
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
    private def consider_link(task : Task, base : Url::Parts, link : RawLink) : Nil
      # Bound the dedup/template bookkeeping: past MAX_SEEN, stop tracking + enqueuing new
      # links so @seen/@templates can't bloat on a pathological target (see MAX_SEEN). A URL
      # already in @seen is still cheap to skip below, so honour that first.
      abs = Url.resolve(base, link.href)
      return unless abs
      p = Url.parse(abs)
      return unless p
      key = Url.visit_key(p)
      return if @seen.size >= MAX_SEEN && !@seen.includes?(key)
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
      # One normalize for both the bound check and the enqueued Task (it was built twice).
      return unless norm = bounded_url(p)
      @seen << key
      if @config.spider? && task.depth < @config.max_depth && @crawl_enqueued < @config.max_pages
        @crawl_enqueued += 1
        @frontier << Task.new(TaskKind::Crawl, norm, task.depth + 1, link.source)
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
      return unless dp && bounded_url(dp)
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
          # @seen first: it is a hash lookup, while probe_allowed? walks every scope rule
          # under a mutex with PCRE2. Same verdict either way — this runs 275 words × dirs.
          key = Url.visit_key(p)
          next if @seen.includes?(key)
          next unless probe_allowed?(p)
          @seen << key
          count += 1
          @frontier << Task.new(TaskKind::Probe, Url.normalize(p), task.depth,
            Source::Bruteforced, dir: bl.dir, baseline: bl)
        end
        break if cap > 0 && count >= cap
      end
    end

    # Containment (origin/subdomain/scope-aware) + the injected scope policy + path confine.
    # Returns the normalized URL when `p` is in bounds, else nil. It has to build that string to
    # ask the scope anyway, and consider_link needs the same one for the Task it enqueues — so
    # hand it back rather than have the caller rebuild it. Still short-circuits on the path
    # confine before normalizing anything.
    private def bounded_url(p : Url::Parts) : String?
      # A crawled `<a href>` is the one input here that no gate downstream can make safe: the
      # extractor's `[^"]` matches CR and LF, `Url.resolve` only strips the ends, and
      # `URI.parse` keeps an interior CR/LF verbatim — so the href reaches the request line
      # intact (`Sender::UNSAFE_URL`). Same single rule the seed goes through in
      # `Discover::Plan`, applied here because this is where a DERIVED url is judged.
      #
      # DROPPED SILENTLY, not recorded: a Finding asserts "this endpoint exists", and this URL
      # is never requested, so there is no status, length, or content type to claim one with —
      # and `Persist` would then write the poisoned string into the Sitemap as a real flow.
      # It is refused for the same reason any out-of-bounds link is, and takes the same exit.
      #
      # Only the FRAMING half of the octet class gets this exit. The rest of it (SP, TAB, DEL,
      # the other C0) corrupts one request line without starting a second, and `<a href="/my
      # file.pdf">` is ordinary handwritten HTML — so `Url.parse` has already percent-encoded
      # those and nothing reaches here to drop (#394, and `Url.encode_unsafe` for why the two
      # halves are answered differently).
      return nil unless Headers.safe_url?(p)
      return nil unless confined?(p)
      url = Url.normalize(p)
      gate = Url.gate_url(p)                          # port-less, matching every other Layer-2 consumer (see gate_url)
      return nil unless @scope.allowed?(gate, p.host) # excludes/sandbox — every mode
      ok = case @config.containment
           in Containment::SameOrigin        then same_origin?(p)
           in Containment::HostAndSubdomains then same_or_subdomain?(p)
           in Containment::ScopeAware        then @scope.configured? ? @scope.boundary?(gate, p.host) : same_origin?(p)
           end
      ok ? url : nil
    end

    # Segment-boundary confinement for a path-scoped run: in-subtree iff the path IS the base
    # or sits under "base/". A bare starts_with?(base) would also admit sibling prefixes
    # (/api-internal for an /api seed, /prefix-test-evil for /prefix-test) — the scope bypass
    # this guards. Shared with `probe_allowed?`, which is the half `bounded_url` never saw.
    private def confined?(p : Url::Parts) : Bool
      return true unless cp = @confine_path
      p.path == cp || p.path.starts_with?("#{cp}/")
    end

    # The directory the brute-forcer starts from.
    #
    # `Url.dir_of` — everything up to the last '/' — is right only when the seed's path is
    # already a directory. For a FILE-SHAPED seed it returns the seed's CONTAINING directory,
    # which a path-confined run then refuses: on `http://t/api`, `dir_of` is `http://t/`,
    # whose path is neither `/api` nor under `/api/`, so `enqueue_dir`'s `bounded_url` dropped
    # it and the seed's own subtree was never probed at all. With `--no-spider` that was the
    # whole run — zero requests, a clean DoneEvent, no reason given (#395).
    #
    # The two derivations have to agree, and it is `confined?` that carries the operator's
    # intent: a seed path deeper than "/" means THE SUBTREE ROOTED HERE, so the brute-force
    # base is that subtree's root as a directory. It is `dir_of` for a seed already ending in
    # '/', and the seed's own path plus '/' otherwise — never anything the operator did not
    # type. Widening `@confine_path` to "/" instead would spray the built-in wordlist
    # (`admin`, `logout`, `.git/config`, `.env`) at the origin root of a run explicitly scoped
    # to `/api`, which is the bypass the confine exists to prevent.
    #
    # `@seed_parts.path` is already dot-segment- and slash-normalized by `Url.parse`, so the
    # rchop in `@confine_path` can only ever have removed one real trailing slash.
    private def bruteforce_root : String
      cp = @confine_path
      return Url.dir_of(@seed_parts) unless cp
      "#{Url.origin(@seed_parts)}#{cp}/"
    end

    # A brute-force candidate is `bl.dir` + a wordlist entry, and only the DIRECTORY was ever
    # authorised — one `allowed?` answer standing in for ~278 real requests with the defaults.
    # Two things do not survive that append:
    #
    #   * The path confine. `Url.parse` collapses dot-segments, so a wordlist entry like
    #     `../admin` re-parses to a path OUTSIDE the seed's subtree; the confine lived only in
    #     `bounded_url`, which probes never reached. Traversal entries are common in public
    #     wordlists.
    #   * Layer 2. Only `host` rules and `string` INCLUDEs are monotone under a path append —
    #     `string`/`regex` EXCLUDEs and the `regex` INCLUDEs Sandbox reads as its allowlist are
    #     not, so a child can be denied while its parent is allowed. An EXCLUDE on `logout` /
    #     `signout` / `shutdown`, the canonical "do not touch destructive endpoints" rule, was
    #     silently ignored by the brute-forcer even though `logout` ships in the built-in list.
    #
    # Containment / `boundary?` (Layer 1) is deliberately NOT re-asked here: it was answered
    # for the directory, which is what the crawl actually reached, and Layer 1 is the layer
    # DESIGN.md §3 says varies by surface. Layer 2 is the one that is identical everywhere.
    # Gating at enqueue as well as at `send_with_retries` keeps a refused candidate out of the
    # frontier and out of the per-directory cap entirely, rather than spending both on a send
    # that will be refused.
    #
    # `safe_url?` is here for symmetry with `bounded_url`: a hostile wordlist can carry an
    # interior lone CR (`Wordlist.load` strips only the ends of a line). The wire seam would
    # catch it, but only after the candidate had been enqueued, retried `retries + 1` times
    # and counted as an error — so refuse it at the same place every other derived URL is.
    private def probe_allowed?(p : Url::Parts) : Bool
      Headers.safe_url?(p) && confined?(p) && @scope.allowed?(Url.gate_url(p), p.host)
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
      # Layer 2, per URL, on the ONE line every send passes — the invariant §3 states for it
      # ("identical on every surface, and applied even when Layer 1 was waived"). Calibration
      # probes are `#{dir}#{bogus_name}` strings a worker builds at send time, so this is the
      # only place they can be judged at all; brute-force probes are pre-gated in
      # `enqueue_probes` and re-checked here so the two can never drift.
      #
      # `Url.gate_url`, not `Url.normalize`: the `dir + cand` concat is unnormalized, and the
      # scope must be asked in the port-less form every other Layer-2 consumer uses — see
      # `Url.gate_url`. The policy re-reads its rules on the schedule every other sweep uses
      # (`StoreScope#allowed?`, throttled to `Outbound::RELOAD_INTERVAL`), so a scope edit made
      # while the run is in flight stops it here within that window — on every surface, not
      # only in the TUI where the `Scope` object happens to be shared live (#396).
      unless @scope.allowed?(Url.gate_url(p), p.host)
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, SCOPE_REFUSED)
      end
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
      # Cap the INFLATE at MAX_BODY, not just the result. Without the cap ContentDecode expands a
      # compressed response up to its 32 MB anti-bomb ceiling and we then throw away everything
      # past 2 MB on the next line — so a highly-compressible response allocated and inflated up
      # to 30 MB per request, on a path multiplied by the whole wordlist.
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body, MAX_BODY)
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
