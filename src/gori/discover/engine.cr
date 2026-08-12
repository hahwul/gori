require "./types"
require "./url"
require "./headers"
require "./fingerprint"
require "./extract"
require "./calibrate"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/conn_pool"
require "../env"
require "../proxy/codec/content_decode"
require "../pacing"

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

    # The bytes `fetch` puts on the wire for this target — the REQUEST half of the exchange a
    # finding is kept with. A hook rather than a second return value from `fetch` for the
    # reason `Sender#binding_headers` spells out: this backend BUILDS its request from
    # (scheme, host, port, target) instead of being handed one, so the request is a pure
    # function of those four plus the run's fixed header block, and `Sender` overrides this
    # with the very call `fetch` makes. The default below is the minimal GET the contract
    # implies, which is exactly what a backend that frames nothing (a spec double) stands for.
    #
    # One caveat, since this is called just after the send rather than during it: a `$NAME`
    # header REBOUND between the two resolves to its new value here. `Env.binding_rev` only
    # moves when the operator edits a binding, and the window is the length of one `fetch`, so
    # the stored request can differ from the sent one by a header value in exactly that case.
    def request_head(scheme : String, host : String, port : Int32, target : String) : Bytes
      default = scheme == "https" ? 443 : 80
      hostline = port == default ? host : "#{host}:#{port}"
      "GET #{target} HTTP/1.1\r\nHost: #{hostline}\r\n\r\n".to_slice
    end

    # The name this backend presents in the ClientHello, or nil for the dialed host's own name.
    # It belongs on the send seam for the reason `Sender#sni` gives (the backend owns the wire
    # decision), and it has to reach the STORE: `Repeater::FlowRequest.build` seeds a re-send
    # from `FlowDetail#sni`, so a flow persisted without it re-sends to a name-based vhost
    # under the wrong name — which is precisely the sweep `--sni` exists to express.
    def sni : String?
      nil
    end

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
    # a brute-force pass is ~315 sends PER DIRECTORY, and dial-per-send paid a TCP — and on
    # https a TLS — handshake for every one of them. `idle_conns` bounds the sockets one
    # origin may park and should be the run's concurrency (one per worker fiber is the most
    # that can ever be checked out at once), capped at MAX_IDLE_PER_POOL.
    # `sni` overrides the name in the ClientHello (and, under verify, the name the certificate
    # is checked against) without changing the dialed host:port — `Repeater::Engine`'s own
    # rule, threaded here so an IP-direct sweep of a name-based vhost is expressible. It is
    # the ORIGIN's name, so every pool and every dial this Sender makes carries the same one.
    def initialize(@verify : Bool, @timeout : Time::Span? = nil, @http2 : Bool = false,
                   headers : Array({String, String}) = [] of {String, String},
                   @overrides : Gori::HostOverrides? = nil,
                   keep_alive : Bool = false, idle_conns : Int32 = 0,
                   @sni : String? = nil)
      # Merge the user headers over the defaults once — the block is identical for
      # every send (only Host varies, per target). Host + Connection are emitted
      # separately in build_get and never come from user input.
      @header_block = Headers.merge(headers).map { |name, value| "#{name}: #{value}\r\n" }.join
      # Whether ANY `$` survives in the block. When none does — the overwhelming case — every
      # fetch skips the binding path entirely and reuses the constructed block verbatim.
      @header_tokens = !Settings.env_prefix.empty? && !@header_block.byte_index(Settings.env_prefix).nil?
      @header_resolved = nil.as(String?)
      @header_rev = 0_u64
      # h2 is excluded for the reason Fuzz::Sender excludes it: H2Engine frames its own
      # connection per send, and multiplexing it is a separate change with its own
      # stream-state rules.
      @keep_alive = keep_alive && !@http2
      @idle_conns = idle_conns.clamp(1, MAX_IDLE_PER_POOL)
      @pools = @keep_alive ? Hash(String, Repeater::ConnPool).new : nil
    end

    # The name this sender presents in the ClientHello, and whether it frames HTTP/2. Exposed
    # for the same reason `pool_stats` is: `Plan` hands the Sender out, and these are the parts
    # of the wire decision nothing else on the plan can show.
    getter sni : String?
    getter? http2 : Bool

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
      req = request_head(scheme, host, port, target)
      if @http2
        Repeater::H2Engine.send(req, scheme: scheme, host: host, port: port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
      elsif pool = pool_for(scheme, host, port)
        pool.send(req)
      else
        Repeater::Engine.send(req, scheme: scheme, host: host, port: port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
      end
    end

    # The real thing, not an approximation of it: `fetch` sends exactly these bytes (it calls
    # this method), so the request a finding is stored with is the request that was made.
    def request_head(scheme : String, host : String, port : Int32, target : String) : Bytes
      build_get(scheme, host, port, target, binding_headers)
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
      # NOT an LRU. Evicting the least-recently-used pool to make room looks like the obvious
      # fix for the cliff below, and it was tried and reverted: `close_all` runs SSL_shutdown
      # on a parked TLS socket, which is a WRITE and so a fiber yield point — landing one
      # between this lookup and the insert below, which the whole method depends on not
      # having (see the note above). It also orphans any socket a worker has checked OUT,
      # since eviction can only drain the idle list, and with several origins interleaved
      # across up to 80 workers it thrashes: every new-origin send evicts the pool the next
      # send needs, so origins that used to keep their sockets pay a close plus a redial.
      # Doing it properly needs ConnPool to report in-flight checkouts.
      #
      # So past the cap a new origin dials per send, which is what every origin did before
      # keep-alive existed. The cost is real (a crawl crossing a host+subdomains or multi-host
      # boundary loses pooling for the origins past the fourth) and is the price of the fd
      # bound MAX_POOLS exists to hold.
      return nil if pools.size >= MAX_POOLS
      pool = Repeater::ConnPool.new(scheme, host, port, @verify, @sni, @timeout,
        @overrides, @idle_conns)
      pools[key] = pool
      pool
    end

    # The header block with session bindings (#501) resolved, or nil when one of them is
    # declared and unbound (the caller then refuses, naming it).
    #
    # **This is the one injection seam that is not a byte rewrite, and the asymmetry is
    # real.** `Fuzz::Backend#send`, `Repeater::Sender#send` and `Rules#apply_rule` all
    # receive final wire bytes and substitute into them. `fetch` receives
    # `(scheme, host, port, target)` and BUILDS the request here, so there are no bytes to
    # rewrite until after this method has run — hence a header hook rather than a byte pass.
    # Stated rather than papered over, because it is exactly the shape of omission that lets
    # one surface silently miss a feature every other surface has.
    #
    # Consequences worth being explicit about: the crawler's injection surface is the
    # OPERATOR-SUPPLIED HEADERS ALONE. Not the request target — a crawl derives its targets
    # from the responses it reads, so a token in one has no meaning — and not the body,
    # since `build_get` is GET-only. `Discover::Headers.expand` already ran `Env.expand` over
    # these values once at plan-build, so what survives here is exactly the declared binding
    # names, resolved now instead of then.
    #
    # Recomputed only when the binding table moves: a brute-force pass is ~315 sends per
    # directory, and the block is identical for every one of them.
    private def binding_headers : String
      return @header_block unless @header_tokens
      rev = Gori::Env.binding_rev
      cached = @header_resolved
      if cached.nil? || rev != @header_rev
        @header_rev = rev
        # A declared-but-unbound `$NAME` used to make this nil and refuse the fetch. It now
        # resolves to the literal token, `Env.unbound`'s policy everywhere: a `--header`
        # block is operator-authored text and `$` is a legal byte in one.
        cached = Gori::Env.expand_bindings(@header_block)
        @header_resolved = cached
      end
      cached
    end

    private def build_get(scheme : String, host : String, port : Int32, target : String,
                          header_block : String) : Bytes
      default = scheme == "https" ? 443 : 80
      hostline = port == default ? host : "#{host}:#{port}"
      # `Connection: close` only when NOT pooling. It is what made every send single-use, and
      # `ConnPool.reusable_request?` refuses to park a socket that carried it — so leaving it
      # in would turn keep-alive into a silent no-op. Omitting it is not a request for
      # keep-alive so much as the absence of a request to close: HTTP/1.1's default is
      # persistent, and an origin that disagrees says so in its own `Connection` header,
      # which `reusable_response?` reads.
      conn = @keep_alive ? "" : "Connection: close\r\n"
      "GET #{target} HTTP/1.1\r\nHost: #{hostline}\r\n#{header_block}#{conn}\r\n".to_slice
    end
  end

  # Enforces a HARD ceiling on total real sends (max_requests) across crawl, calibration,
  # and brute probes — past the cap it returns a benign error WITHOUT touching the network.
  class CappedBackend < Backend
    CAP_ERROR = "max-requests cap reached"

    getter sent : Int64 = 0_i64

    def initialize(@inner : Backend, @cap : Int64?)
    end

    # Fetches the cap DENIED. Distinct from `cap_reached?`, which is also true for a run that
    # happened to finish exactly on its budget: a non-zero count here is proof that work the
    # run wanted to do did not happen. See `Engine#budget_exhausted?`.
    getter refused : Int64 = 0_i64

    def cap_reached? : Bool
      (c = @cap) && c > 0 ? @sent >= c : false
    end

    def fetch(scheme : String, host : String, port : Int32, target : String) : Repeater::Result
      if cap_reached?
        @refused += 1
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, CAP_ERROR)
      end
      @sent += 1
      @inner.fetch(scheme, host, port, target)
    end

    def request_head(scheme : String, host : String, port : Int32, target : String) : Bytes
      @inner.request_head(scheme, host, port, target)
    end

    def sni : String?
      @inner.sni
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

  # A directory's live brute-force state, shared BY REFERENCE with every Probe task that
  # directory queued. A record would be wrong here, and that is the whole point:
  # `enqueue_probes` fills the frontier with hundreds of tasks at once, so the only way a
  # RE-MEASURED baseline can reach the ones that have not run yet is for them to hold a
  # mutable reference rather than a copy.
  #
  # Owned by the ORCHESTRATOR — every field is written only there. Workers READ `baseline` in
  # `process_probe`, and on the single-threaded scheduler (no -Dpreview_mt) nothing yields
  # between that read and its use, so no worker can observe a half-applied swap.
  private class DirState
    property baseline : Calibrate::DirBaseline
    # Bumped on every baseline SWAP. A probe reads the baseline and this together at judgement
    # time and carries the pair back, so an outcome scored against a snapshot that has since
    # been replaced is recognisable as stale instead of being believed — see
    # `Engine#handle_probe`. `drifted` cannot express that: it covers the window between the
    # drift being declared and the re-measurement landing, and is CLEARED by the very swap
    # that strands the probes still in flight.
    property generation : Int32 = 0
    # The current run of consecutive CLEARED-AND-ALIKE probe outcomes, and what they look
    # like. This is the drift signal: a directory of real endpoints does not answer a dozen
    # unrelated wordlist entries with one identical response, and a rate limiter, a WAF block
    # page and a 5xx meltdown all do exactly that. See `Engine#admit_hit`.
    property run : Int32 = 0
    property run_fp : UInt64 = 0_u64
    property run_status : Int32? = nil
    # Findings held back because they are the second and later members of such a run — kept
    # until it either BREAKS (they were real divergence after all, and are emitted) or reaches
    # `Engine::DRIFT_RUN` (they were the origin's new uniform answer, and are dropped).
    getter held : Array({Finding, Exchange?}) = [] of {Finding, Exchange?}
    property? drifted : Bool = false
    property recalibrations : Int32 = 0

    def initialize(@baseline : Calibrate::DirBaseline)
    end
  end

  private record Task,
    kind : TaskKind,
    url : String,
    depth : Int32,
    source : Source,
    dir : String? = nil,
    # The directory this Probe belongs to, LIVE — see `DirState`. Nil for every other kind.
    state : DirState? = nil,
    # A Calibrate task queued ONLY to gate robots.txt/sitemap.xml against a soft-404
    # baseline (see enqueue_seed_only_calibration) — never feeds enqueue_probes, so it
    # can't expand the brute-force wordlist onto a directory outside the run's own scope.
    seed_only : Bool = false

  # `declared` — did the response NAME this as a link (an attribute, a `<meta refresh>`, a
  # robots.txt value, a sitemap `<loc>`), or did the endpoint pass infer it from a quoted string
  # in the body's text? Defaults true, so the sources that are declared by construction —
  # robots, sitemap, a followed redirect — construct unchanged. See `Extract::Found` for why the
  # bit exists and `consider_link` for what it gates.
  private record RawLink, href : String, source : Source, declared : Bool = true

  # Worker → orchestrator. One per received Task, so the orchestrator's @pending balances.
  # `exchange` is the wire bytes kept for an outcome that can still become a finding; the
  # orchestrator drops it with the Outcome when the outcome is suppressed instead.
  private record Outcome,
    task : Task,
    fetched : Calibrate::Fetched?,
    links : Array(RawLink),
    baseline : Calibrate::DirBaseline?,
    hit : Bool,
    confidence : Float64,
    exchange : Exchange? = nil,
    # The `DirState#generation` the verdict above was reached under. Probes only.
    generation : Int32 = 0

  # The spider + brute-force engine. Single-threaded fiber scheduler (no -Dpreview_mt), so
  # the ORCHESTRATOR fiber owns all bookkeeping state (frontier/seen/templates/dirs/clusters)
  # with zero locks; N worker fibers only do network I/O + CPU (decode/extract/fingerprint)
  # and feed Outcomes back over a channel. Mirrors the Fuzz/Miner lifecycle shape.
  class Engine
    # Outbound rate limiting (rps / throttle_ms / jitter_ms) over `@last_dispatch`.
    include Gori::Pacing

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

    # How many consecutive cleared-AND-identical probe outcomes in one directory mean the
    # baseline no longer describes the origin.
    #
    # A `DirBaseline` is a SNAPSHOT, measured once before the directory's ~315 probes and never
    # revisited, and a target that changes its mind halfway through is the ordinary case, not
    # the exotic one: a rate limiter trips, a WAF starts serving a block page, the origin falls
    # over. Every remaining probe then diverges from the stale baseline in status AND length
    # AND content — 0.50 + 0.25 + 0.35 — so it is not merely reported, it is reported at
    # confidence 1.0. Measured against an origin whose limiter tripped on the 8th request:
    # 320 findings, of which 310 were the limiter.
    #
    # Deliberately generous, because the number costs almost nothing to raise: the false
    # positives a drift can leak are bounded by the HOLD (see `admit_hit`), not by this, so
    # 12 is chosen to sit far above a real cluster of same-content endpoints (a docs SPA
    # serving one shell for several routes) rather than close to it. Raising it only spends a
    # few more requests before the guard fires; lowering it would start eating real findings.
    DRIFT_RUN = 12

    # How many times ONE directory may be re-measured. A target that keeps flipping — a
    # limiter that relents and trips again — would otherwise re-calibrate forever, and each
    # round is `calibrate_probes + extensions` real requests. Past the cap the directory stops
    # producing findings entirely and says so in `RunStats#drift_suppressed`: fail safe, and
    # loud enough to read.
    MAX_RECALIBRATIONS = 2

    # The documents fetched ONCE at the origin to seed the crawl, in the order they are
    # queued. Every one is a GUESS at a registered path whose BODY names further endpoints —
    # which is the whole reason they are fetched here instead of being left to the wordlist:
    # `.well-known` and `.well-known/security.txt` do ship in `wordlists/paths.txt`, but that
    # probes them once per calibrated DIRECTORY (so never at the origin on a path-confined
    # run) and reads nothing they say.
    #
    #   robots.txt / sitemap.xml / sitemap_index.xml
    #     the site's own declared surface. `sitemap_index.xml` is the WordPress/Yoast
    #     spelling, which is the majority of the sitemaps in the wild that `sitemap.xml`
    #     misses; a `<sitemapindex>` child recurses for free (`Extract.from_sitemap`).
    #   .well-known/openid-configuration, oauth-authorization-server, oauth-protected-resource
    #     OIDC Discovery / RFC 8414 / RFC 9728. The highest-yield document on this list by a
    #     wide margin: one 200 hands over authorize, token, userinfo, jwks, revocation,
    #     introspection, registration and end-session as absolute URLs, and the endpoints it
    #     names are routinely on a host the crawl would otherwise never reach.
    #   .well-known/apple-app-site-association, assetlinks.json
    #     the deep-link manifests. AASA enumerates the app's PATHS literally — a hand-written
    #     list of the routes the product considers real, including the ones behind auth.
    #   .well-known/security.txt
    #     RFC 9116 Contact / Policy / Acknowledgments / Hiring URLs.
    #   .well-known/host-meta
    #     XRD `<Link href>`, and the one that points at a separate API origin often enough to
    #     be worth the request.
    #   .well-known/change-password
    #     RFC-registered pointer at the real credential-management flow.
    #
    # Eleven requests per run — a rounding error against a brute-force pass of ~315 per
    # directory, and the only part of a run that reads a target's own declaration of itself.
    WELL_KNOWN = {
      {"/robots.txt", Source::Robots},
      {"/sitemap.xml", Source::Sitemap},
      {"/sitemap_index.xml", Source::Sitemap},
      {"/.well-known/openid-configuration", Source::WellKnown},
      {"/.well-known/oauth-authorization-server", Source::WellKnown},
      {"/.well-known/oauth-protected-resource", Source::WellKnown},
      {"/.well-known/apple-app-site-association", Source::WellKnown},
      {"/.well-known/assetlinks.json", Source::WellKnown},
      {"/.well-known/security.txt", Source::WellKnown},
      {"/.well-known/host-meta", Source::WellKnown},
      {"/.well-known/change-password", Source::WellKnown},
    }

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
    @dir_states : Hash(String, DirState)
    @found_urls : Set(String)
    @clusters : ClusterMap
    @pending : Int32
    @found : Int32
    @errors : Int64
    # The first non-benign send error, so a run in which EVERY send was refused can name the
    # reason. `Miner::Engine#first_error` and `Sequencer::Engine#first_error` (both #491) for
    # the identical shape, and for the identical reason: the engine stays surface-free, the
    # consumer reads this and decides. ONE string, not a list — every send in a wholly-blocked
    # run fails for the same reason and the point is to name it, not to tally it.
    getter first_error : String? = nil
    # Sends that reached an origin and came back without an error. `@capped.sent` cannot
    # answer that — it is a BUDGET counter that charges an attempt before the fetch, so a run
    # whose every send failed still has `sent > 0`. Same counter, same name and same purpose
    # as `Miner::Engine#successful_sends`; see `wholly_refused_reason`.
    getter successful_sends : Int64 = 0_i64
    @pages : Int32
    @crawl_enqueued : Int32
    @calibrated_out : Int32
    @dedup_suppressed : Int32
    @template_suppressed : Int32
    @cluster_suppressed : Int32
    @uncalibratable : Int32
    @drift_suppressed : Int32
    @conf_hist : Array(Int32)
    @last_dispatch : Time::Instant
    @phase : Phase
    @seed_calibration_dir : String?
    @seed_baseline : Calibrate::DirBaseline?
    @pending_seed_fetches : Array({Task, Calibrate::Fetched, Exchange?})

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
      @dir_states = Hash(String, DirState).new
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
      @drift_suppressed = 0
      @conf_hist = [0, 0, 0, 0]
      @last_dispatch = Time.instant
      @phase = Phase::Seeding
      @seed_calibration_dir = nil
      @seed_baseline = nil
      @pending_seed_fetches = [] of {Task, Calibrate::Fetched, Exchange?}
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
            # No pace here: `send_with_retries` paces every wire request, and a Calibrate
            # task is MANY of them. Pacing the dispatch too charged a task one extra slot.
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
      #
      # `@capped.sent` is a BUDGET counter — `CappedBackend#fetch` charges the attempt before
      # the inner fetch, deliberately, so a refusal costs the run a request the same way a
      # retry or a redirect hop does. It is therefore the wrong question for "did anything
      # reach the wire": a run whose every send was refused before a socket (an unbound
      # `$NAME`, an unsafe URL) has `sent > 0`, took this branch, and ended in a clean
      # `DoneEvent` with the reason nowhere — `handle_crawl`/`handle_probe` had built the
      # sentence and dropped it. `first_error` is what Miner and Sequencer already carry for
      # exactly this (#491), so a wholly-refused run is terminal here too and NAMES the cause.
      refusal = @state == State::Stopped ? nil : (@capped.sent == 0 ? NOTHING_TO_SEND : wholly_refused_reason)
      if refusal
        @events.send(ErrorEvent.new(refusal))
      else
        @events.send(DoneEvent.new(progress_snapshot, run_stats, @state == State::Stopped,
          budget_exhausted?))
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
      release_held
    end

    # Every directory whose last probes formed a run too SHORT to be drift still has that run
    # held (see `admit_hit`), and nothing is coming to break it. Releasing here rather than in
    # `orchestrate` puts it in the one place every ending passes — including a stopped run,
    # whose held findings are as real as any other.
    private def release_held : Nil
      @dir_states.each_value { |state| break_run(state) }
    end

    private def seed_frontier : Nil
      @seen << Url.visit_key(@seed_parts)
      if @config.spider?
        # The seed itself needs no gate here — `initialize` already refused the whole run if
        # Layer 2 blocks it, so reaching this line means it passed.
        @crawl_enqueued += 1
        @frontier << Task.new(TaskKind::Crawl, Url.normalize(@seed_parts), 0, Source::Seed)
        root = Url.origin(@seed_parts)
        WELL_KNOWN.each { |path, source| enqueue_well_known("#{root}#{path}", source) }
      end
      bf_dir = bruteforce_root
      enqueue_dir(bf_dir, 0) if @config.bruteforce?
      # WELL_KNOWN paths are GUESSED, not organically-linked — they deserve the same soft-404
      # gate a brute-forced wordlist hit gets, not the "exists by
      # construction" trust record_page gives a crawled <a href>. Only wire this up when
      # bruteforce is on: that's the only mode with a calibration baseline to gate against.
      # The origin is calibrated separately — a well-known path always lives there even on
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

    # A WELL_KNOWN document is DERIVED, not typed: nothing but the run itself asked for
    # it, and they are anchored on the origin, so on a path-confined run they sit outside
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

    # The run stopped SHORT of its work because `max_requests` ran out — not merely reached
    # its cap on the last thing it had to do, which is an ordinary complete run. Both halves
    # are needed and neither alone is right:
    #   * `@frontier` non-empty — the orchestrator's `break if @capped.cap_reached?` leaves
    #     every un-dispatched task sitting there (the 275-of-283 case);
    #   * `@capped.refused > 0` — a Calibrate task whose bogus probes were all denied
    #     consumed no frontier entry at all, so the frontier can drain while real work was
    #     skipped.
    private def budget_exhausted? : Bool
      @capped.cap_reached? && (!@frontier.empty? || @capped.refused > 0)
    end

    # The reason this run produced nothing, or nil when it produced something.
    #
    # "Produced nothing" is `@found == 0 && @pages == 0` AND nothing got through
    # (`@successful_sends == 0`) — the second clause is `Miner::Engine`'s predicate, added
    # here for its reason and against the same failure: a target that accepts TCP and then
    # answers nothing, under a budget small enough that only CALIBRATION probes ever ran,
    # reported `done · 0 found · 9 sent · 0 errors` and exit 0. Nine requests went out, nine
    # got no response. Calibration failures now reach `@first_error` too (see
    # `send_with_retries`), which is what makes that run nameable at all; `successful_sends`
    # is what stops the wider check from turning a target that answered fine but held nothing
    # into a spurious terminal error.
    private def wholly_refused_reason : String?
      return nil unless @found == 0 && @pages == 0 && @successful_sends == 0
      @first_error.presence
    end

    private def handle_crawl(oc : Outcome) : Nil
      task = oc.task
      @pages += 1 if task.kind == TaskKind::Crawl
      fetched = oc.fetched
      return unless fetched
      if err = fetched.error
        unless benign_error?(err)
          @errors += 1
          # `.presence`: an error String can be EMPTY (a spec double, a backend that reports
          # failure without a message), and "" is truthy in Crystal — recording it would make
          # `first_error` present but say nothing, which is worse than absent.
          @first_error ||= err.presence
        end
        return
      end
      if @seed_calibration_dir && well_known?(task.source)
        resolve_seed_finding(task, fetched, oc.exchange)
      else
        record_page(task, fetched, oc.exchange)
      end
      confirm_bruteforce_dir(task, fetched)
      expand_links(oc, task, fetched)
    end

    # The other half of `consider_link`'s declared-only rule: this page's own directory, seeded
    # now that the fetch has come back and says something is there.
    #
    # Placed here rather than in `record_page` so it covers the WELL_KNOWN branch above too, and
    # so it is asked once per fetched page regardless of which gate scored it. It is a no-op for
    # a DECLARED link — `consider_link` already enqueued that directory and `@dirs` dedups — so
    # what this actually restores is the inferred half: a route recovered from a bundle earns its
    # directory a sweep by answering, one round-trip later than before and only when real.
    #
    # The existence test is `record_page`'s, deliberately: `< 400`, plus 401 and 403, because an
    # endpoint behind auth is the strongest reason there is to sweep its neighbours. A 404 earns
    # nothing, which is the entire saving.
    private def confirm_bruteforce_dir(task : Task, fetched : Calibrate::Fetched) : Nil
      return unless @config.bruteforce?
      s = fetched.status
      return unless s && (s < 400 || s == 401 || s == 403)
      return unless p = Url.parse(task.url)
      enqueue_dir(Url.dir_of(p), task.depth)
    end

    # A finding the run GUESSED rather than followed a link to: the WELL_KNOWN documents, and
    # everything they declare. Their claim to exist rests on gori having asked for a fixed
    # path, so it goes through the soft-404 baseline (`resolve_seed_finding`) instead of
    # `record_page`'s raw-status trust — a wildcard-200 origin answers 200 to
    # `/.well-known/openid-configuration` exactly as readily as to `/robots.txt`.
    #
    # ONE predicate rather than three call sites repeating the same three-way or, because the
    # routing test and the confidence anchor must agree: a source routed to the baseline gate
    # and then scored on the crawl ladder would report a soft-404 at 0.95.
    private def well_known?(source : Source) : Bool
      source.robots? || source.sitemap? || source.well_known?
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
      @events.send(BaselineEvent.new(bl.dir, bl.label, nil))
      if bl.dir == @seed_calibration_dir
        @seed_baseline = bl
        flush_pending_seed_fetches
      end
      return if oc.task.seed_only
      # A RE-calibration (`declare_drift`): this directory already has state, and a frontier
      # full of probes pointing at it. Swap the baseline in place — that is what the shared
      # `DirState` reference exists for — and resume. Queueing the wordlist a second time here
      # would double the directory's cost and re-probe everything already in `@seen`.
      if state = @dir_states[bl.dir]?
        state.baseline = bl
        state.generation += 1
        state.drifted = false
        break_run(state)
        return
      end
      state = DirState.new(bl)
      @dir_states[bl.dir] = state
      enqueue_probes(oc.task, state)
    end

    private def handle_probe(oc : Outcome) : Nil
      fetched = oc.fetched
      return unless fetched
      if err = fetched.error
        unless benign_error?(err)
          @errors += 1
          # `.presence`: an error String can be EMPTY (a spec double, a backend that reports
          # failure without a message), and "" is truthy in Crystal — recording it would make
          # `first_error` present but say nothing, which is worse than absent.
          @first_error ||= err.presence
        end
        return
      end
      state = oc.task.state
      admissible = oc.hit && oc.confidence >= @config.confidence_floor
      if state && oc.generation != state.generation
        # Scored against a baseline that has since been REPLACED — the very snapshot
        # `declare_drift` threw out — so it is evidence about nothing and is discarded rather
        # than believed. Counted only when it would have been a finding, because that is the
        # number the operator is being told about; a stale miss is not a suppressed result.
        @drift_suppressed += 1 if admissible
        return
      end
      unless admissible
        @calibrated_out += 1
        # A MISS breaks the run: the origin is still discriminating between paths, so whatever
        # was held back was ordinary divergence and is released now.
        break_run(state) if state
        return
      end
      admit_hit(state, Finding.new(oc.task.url, "GET", fetched.status, fetched.length,
        fetched.content_type, Source::Bruteforced, oc.task.depth, oc.confidence, nil),
        fetched, oc.exchange)
    end

    # A probe that cleared its baseline — emitted, held, or dropped.
    #
    # The three outcomes are what makes the drift guard cost ONE false positive instead of the
    # rest of the wordlist. The FIRST member of a uniform run is indistinguishable from a real
    # finding at the moment it arrives, so it is emitted; the second and later members are
    # HELD, because by then "several unrelated paths answering identically" is a hypothesis
    # worth waiting on; and if the run reaches DRIFT_RUN the hypothesis is confirmed and the
    # whole held batch goes in the bin. A run that breaks first releases everything, so the
    # common case — a directory with a handful of scattered real hits — pays nothing but the
    # latency of one more probe outcome.
    private def admit_hit(state : DirState?, f : Finding, fetched : Calibrate::Fetched,
                          ex : Exchange?) : Nil
      unless state
        emit_probe_finding(f, ex)
        return
      end
      if state.drifted?
        # Already declared, and either re-calibrating or past MAX_RECALIBRATIONS. Probes
        # dispatched before the declaration land here judged against the stale baseline.
        @drift_suppressed += 1
        return
      end
      unless extends_run?(state, fetched)
        break_run(state)
        state.run = 1
        state.run_fp = fetched.simhash
        state.run_status = fetched.status
        emit_probe_finding(f, ex)
        return
      end
      state.run += 1
      if state.run >= DRIFT_RUN
        declare_drift(state)
        return
      end
      state.held << {f, ex}
    end

    # Does this outcome look like the one before it — same status, and content inside the
    # run's own simhash cluster? The same `simhash_distance` the calibrator and the crawl's
    # `ClusterMap` use, because it is the same question about the same fingerprint.
    private def extends_run?(state : DirState, fetched : Calibrate::Fetched) : Bool
      return false if state.run == 0
      return false unless state.run_status == fetched.status
      Fingerprint.hamming(state.run_fp, fetched.simhash) <= @config.simhash_distance
    end

    # End the current run and emit everything it was holding.
    private def break_run(state : DirState) : Nil
      state.run = 0
      return if state.held.empty?
      state.held.each { |f, ex| emit_probe_finding(f, ex) }
      state.held.clear
    end

    # DRIFT_RUN probes in a row came back cleared AND identical to each other. That is not a
    # directory of endpoints; that is an origin that stopped answering the question. Drop what
    # the run was holding, stop counting this directory, and go re-measure it — which is the
    # part a status heuristic could not do, since the new uniform answer is as often a 200
    # block page or a 403 as it is a 429.
    private def declare_drift(state : DirState) : Nil
      state.drifted = true
      @drift_suppressed += state.held.size + 1
      state.held.clear
      state.run = 0
      dir = state.baseline.dir
      if state.recalibrations < MAX_RECALIBRATIONS
        state.recalibrations += 1
        @events.send(BaselineEvent.new(dir, "drifted", "re-calibrating"))
        enqueue_recalibration(dir)
      else
        @events.send(BaselineEvent.new(dir, "drifted", "giving up on this directory"))
      end
    end

    # Emit a brute-force hit and, when it looks like a container, recurse into it. The two
    # move together on purpose: a finding the drift guard is still holding must not seed a
    # directory before the guard has decided whether it was real — otherwise a WAF block page
    # answering 200 would enqueue a wordlist sweep of its own URL.
    private def emit_probe_finding(f : Finding, ex : Exchange?) : Nil
      record_finding(f, ex)
      s = f.status
      if s && s >= 200 && s < 300 && f.depth < @config.max_depth
        enqueue_dir_from_url(f.url, f.depth + 1)
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

    private def record_page(task : Task, fetched : Calibrate::Fetched, ex : Exchange?) : Nil
      s = fetched.status
      return unless s && (s < 400 || s == 401 || s == 403)
      conf = crawl_confidence(task.source, s)
      record_finding(Finding.new(task.url, "GET", s, fetched.length, fetched.content_type,
        task.source, task.depth, conf, nil), ex)
    end

    private def crawl_confidence(source : Source, status : Int32) : Float64
      if well_known?(source)
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
    private def resolve_seed_finding(task : Task, fetched : Calibrate::Fetched, ex : Exchange?) : Nil
      if bl = @seed_baseline
        record_seed_hit(task, fetched, bl, ex)
      else
        @pending_seed_fetches << {task, fetched, ex}
      end
    end

    private def flush_pending_seed_fetches : Nil
      return if @pending_seed_fetches.empty?
      return unless bl = @seed_baseline
      @pending_seed_fetches.each { |task, fetched, ex| record_seed_hit(task, fetched, bl, ex) }
      @pending_seed_fetches.clear
    end

    # Same hit/confidence gate handle_probe applies to a brute-forced wordlist entry.
    private def record_seed_hit(task : Task, fetched : Calibrate::Fetched, bl : Calibrate::DirBaseline,
                                ex : Exchange?) : Nil
      hit, conf = Calibrate.hit?(bl, fetched)
      if hit && conf >= @config.confidence_floor
        record_finding(Finding.new(task.url, "GET", fetched.status, fetched.length, fetched.content_type,
          task.source, task.depth, conf, nil), ex)
      else
        @calibrated_out += 1
      end
    end

    private def record_finding(f : Finding, ex : Exchange? = nil) : Nil
      return unless @found_urls.add?(f.url)
      @found += 1
      bump_conf_hist(f.confidence)
      @events.send(FindingEvent.new(f, ex))
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
      # Seeding a brute-force sweep of this link's DIRECTORY costs the whole wordlist — ~315
      # sends with the defaults, before extensions — so it is spent only on a link the target
      # DECLARED. An inferred literal has to be confirmed first: it comes back through
      # `confirm_bruteforce_dir` once its own fetch says something is actually there.
      #
      # Measured, on a bundle of 120 i18n/asset/vendor paths that resolve to nothing: seeding on
      # faith turned one response into 38,929 requests for 2 findings. The same guard costs a
      # real SPA nothing — its bundle names routes that answer 200, so every directory it points
      # at is seeded one round-trip later.
      enqueue_dir(Url.dir_of(p), task.depth) if @config.bruteforce? && link.declared
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

    # A SECOND Calibrate task for a directory `@dirs` already holds, so it deliberately skips
    # `enqueue_dir`'s dedup — that set exists to stop the wordlist being queued twice, which
    # `handle_calibrate` prevents here by taking the swap branch instead.
    #
    # Queued at the FRONT of the frontier: every probe behind it is about to be judged against
    # the baseline that was just found stale, and each one dispatched before the re-measurement
    # lands is a request spent on an answer that will be thrown away. Layer 2 is re-asked, as
    # it is for every URL this engine derives — the scope may have changed since the first
    # calibration, and this queues `calibrate_probes + extensions` real sends.
    private def enqueue_recalibration(dir : String) : Nil
      return unless p = Url.parse(dir)
      return unless @scope.allowed?(Url.gate_url(p), p.host)
      @frontier.unshift(Task.new(TaskKind::Calibrate, dir, 0, Source::Bruteforced, dir: dir))
    end

    private def enqueue_probes(task : Task, state : DirState) : Nil
      bl = state.baseline
      cap = @config.per_dir_cap
      count = 0
      exts = @config.extensions
      # Parse the DIRECTORY once for the whole wordlist. `Url.probe` can then derive each
      # candidate's Parts and its one shared `visit_key`/`normalize` string by concatenation,
      # instead of `URI.parse`-ing `#{bl.dir}#{cand}` and building three more strings from the
      # result — 315 words × (1 + extensions) × directories, all of it on the ORCHESTRATOR
      # fiber, which is also the only fiber that dispatches jobs.
      #
      # The fast path is armed ONLY when `bl.dir` is already its own normal form and carries
      # no query, because that equality is the whole proof that `dir_url + cand` is the string
      # `Url.parse` would have produced. Every directory this engine derives satisfies it
      # (`Url.dir_of` is `origin + a path ending in '/'`), but `enqueue_dir_from_url` appends a
      # '/' to a normalized PROBE url, which a wordlist entry carrying a query would leave
      # spelled differently — so it is checked, not assumed, and a mismatch simply falls back.
      dp = Url.parse(bl.dir)
      base = dp && dp.query.nil? && Url.normalize(dp) == bl.dir ? dp : nil
      @words.each do |w|
        break if @capped.cap_reached?
        break if cap > 0 && count >= cap
        count += 1 if enqueue_probe(task, state, base, w)
        exts.each do |ext|
          break if cap > 0 && count >= cap
          count += 1 if enqueue_probe(task, state, base, "#{w}.#{ext}")
        end
      end
    end

    # One brute-force candidate against a calibrated directory. True when it entered the
    # frontier — and therefore counts against the per-directory cap — false when it was
    # unparseable, already seen, or refused by the gates.
    private def enqueue_probe(task : Task, state : DirState,
                              base : Url::Parts?, cand : String) : Bool
      dir = state.baseline.dir
      p, key, url =
        if base && (pr = Url.probe(base, dir, cand))
          # `visit_key` and `normalize` are the SAME string for a query-less URL (compare the
          # two: both are `origin + path`), and `Url.probe` built it once.
          {pr.parts, pr.url, pr.url}
        else
          slow = Url.parse("#{dir}#{cand}")
          return false unless slow
          {slow, Url.visit_key(slow), Url.normalize(slow)}
        end
      # @seen first: it is a hash lookup, while probe_allowed? walks every scope rule
      # under a mutex with PCRE2. Same verdict either way — this runs 315 words × dirs.
      return false if @seen.includes?(key)
      return false unless probe_allowed?(p)
      @seen << key
      @frontier << Task.new(TaskKind::Probe, url, task.depth,
        Source::Bruteforced, dir: dir, state: state)
      true
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
    # authorised — one `allowed?` answer standing in for ~315 real requests with the defaults.
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
      Outcome.new(task, fetched, links, nil, false, 0.0, capture_exchange(task.url, raw))
    end

    # Pick the link extractor from the RESPONSE, not from how the URL was found. Only the
    # well-known robots.txt (fetched by role at its fixed path) is parsed by label — it is
    # plain text and never sniffable. Everything else defers to the body: a <loc>-bearing
    # payload is a sitemap (the well-known /sitemap.xml, a <sitemapindex> child, OR a
    # robots.txt `Sitemap:` URL at any path), and only genuine HTML is parsed as HTML. This
    # stops a non-standard-path sitemap from being wrongly parsed as HTML and lost.
    #
    # A text body that is NEITHER goes to `Extract.from_text`, and that branch is where most
    # of a modern target's surface actually lives. It used to be `EMPTY_LINKS`: the spider
    # followed `<script src>` like any other link, spent a real request on the bundle, decoded
    # it, fingerprinted it — and then discarded every endpoint in it because
    # `application/javascript` is not html-like. The same held for every JSON document,
    # including each of the `.well-known/` ones this run now fetches, whose entire value IS
    # the URLs they list.
    private def extract_links(task : Task, fetched : Calibrate::Fetched, body : Bytes) : Array(RawLink)
      if task.kind.fetch? && task.source.robots?
        return Extract.from_robots(body).map { |h| RawLink.new(h, Source::Robots) }
      end
      # What a well-known document DECLARES is a guess too — the origin's word for it, at a
      # path gori chose — so it inherits the source that keeps it behind the soft-404 gate
      # (`well_known?`). Everything else a page points at is an ordinary crawl link.
      #
      # `task.kind.fetch?` bounds that inheritance to ONE HOP, the same way the robots branch
      # above does, and it is load-bearing rather than tidy. Only `enqueue_well_known` queues a
      # Fetch; every link this method yields is enqueued as a Crawl. Without the guard the
      # source propagated down the WHOLE subtree — an `<a href>` on a page an OIDC document
      # named came back `WellKnown`, and so did its children — which routes an ordinary crawled
      # page through `resolve_seed_finding` and judges it against the SEED ORIGIN ROOT's
      # soft-404 baseline. That is not a stricter gate, it is the wrong question: measured, a
      # linked `/deep/page` answering 401 on an origin that 401s unknown paths cleared nothing
      # and was dropped into `calibrated_out`, while the identical page reached by a link from
      # `/` was recorded at 0.85. A guess deserves the baseline; a link the target itself
      # published does not.
      src = task.kind.fetch? && task.source.well_known? ? Source::WellKnown : Source::Crawled
      if Extract.sitemap_body?(body)
        return Extract.from_sitemap(body).map { |h| RawLink.new(h, Source::Sitemap) }
      end
      ct = fetched.content_type
      # No content type at all stays html-like, which is where it has always gone — and now
      # loses nothing by it, since `from_html` runs the endpoint pass too.
      if ct.nil? || html_like?(ct)
        # The one MIXED source: `from_html` runs both the attribute passes and the endpoint pass,
        # and only it can say which found what.
        Extract.from_html(body).map { |f| RawLink.new(f.href, src, f.declared) }
      elsif text_like?(ct)
        # A bundle, a JSON document, a `.map`: not markup, so it declares no links at all and
        # every literal here is inferred.
        Extract.from_text(body).map { |h| RawLink.new(h, src, false) }
      else
        EMPTY_LINKS
      end
    end

    # Calibration is the ONE task that fans out into many sends — every other `process_*`
    # makes a single `send_with_retries` call — so it is also the one place where
    # `worker_loop`'s stop check, which runs once per RECEIVED task, is not enough. Without a
    # per-probe check a worker already inside here kept firing its whole batch after
    # `stop`: at the defaults that is 20 workers × 3 probes × (1 + 1 retry) = up to ~120
    # requests at a third party AFTER the operator pressed stop. Calibration runs for every
    # directory and is this engine's largest single cost (see the comment on the frontier),
    # so it is also the batch most likely to be in flight when stop arrives.
    private def process_calibrate(task : Task) : Outcome
      dir = task.dir || task.url
      probes = [] of Calibrate::Fetched
      echoes = false
      @config.calibrate_probes.times do
        break if @capped.cap_reached? || stopped?
        probes << calibration_probe(dir, bogus_name) { |hit| echoes ||= hit }
      end
      @config.extensions.each do |ext|
        break if @capped.cap_reached? || stopped?
        probes << calibration_probe(dir, "#{bogus_name}.#{ext}") { |hit| echoes ||= hit }
      end
      baseline = Calibrate.build(dir, probes, @config.simhash_distance, echoes)
      Outcome.new(task, nil, EMPTY_LINKS, baseline, false, 0.0)
    end

    # One bogus probe, distilled — and, on the way past, the answer to "does this directory's
    # miss page QUOTE the requested path back into its body?".
    #
    # Asked here because this is the only place that holds a bogus probe's BODY and its NAME at
    # the same time: `Calibrate::Fetched` deliberately carries no body, so the baseline builder
    # cannot ask it, and the fingerprint cannot answer it. That second half is worth being
    # precise about, because it is what let an echoing soft-404 hide for so long:
    # `Fingerprint.dynamic?` skips any all-hex run of 12 or more — deliberately, so ids,
    # hashes and CSRF tokens cannot move a hash — and `bogus_name` is exactly 16 hex
    # characters. The reflected name is invisible to the very hash the reflection would show up
    # in, so every bogus probe agrees with every other one no matter how loudly the page quotes
    # the path. Inferring the echo from an out-of-cluster fingerprint does not work either: one
    # extra token in an 80-token page moves a simhash by fewer bits than `simhash_distance`,
    # while a multi-segment wordlist entry like `swagger/v1/swagger.json` contributes four and
    # clears it — so the inferred test is LESS sensitive than the thing it is trying to
    # predict, which is the wrong way round. A byte search is exact and costs no extra request.
    private def calibration_probe(dir : String, name : String, & : Bool ->) : Calibrate::Fetched
      raw = send_with_retries("#{dir}#{name}")
      body = decode_body(raw)
      yield raw.error.nil? && body_contains?(body, name)
      distill(raw, body)
    end

    # `body.includes?(needle)` for bytes. `String.new(body).includes?` would copy the whole
    # response and would have to reckon with invalid UTF-8; the needle here is ASCII by
    # construction (`bogus_name` is hex, plus a configured extension), so a byte scan answers
    # the same question without either.
    private def body_contains?(body : Bytes, needle : String) : Bool
      n = needle.to_slice
      return false if n.empty? || body.size < n.size
      first = n.unsafe_fetch(0)
      i = 0
      last = body.size - n.size
      while i <= last
        if body.unsafe_fetch(i) == first
          k = 1
          while k < n.size && body.unsafe_fetch(i + k) == n.unsafe_fetch(k)
            k += 1
          end
          return true if k == n.size
        end
        i += 1
      end
      false
    end

    private def process_probe(task : Task) : Outcome
      raw = send_with_retries(task.url)
      fetched = distill(raw, decode_body(raw))
      # Read through the shared `DirState`, so a probe queued before a drift re-calibration is
      # judged against the baseline in force NOW rather than the one queued alongside it. The
      # baseline and the generation are read TOGETHER, with no yield between them, so the pair
      # the orchestrator gets back always describes one snapshot.
      state = task.state
      bl = state.try(&.baseline)
      gen = state.try(&.generation) || 0
      if bl
        hit, conf = Calibrate.hit?(bl, fetched)
        # Only a HIT can become a finding, and `hit?` is decided right here in the worker — so
        # a wordlist sweep keeps the bytes of the handful it found and forgets the thousands of
        # soft-404s it did not, instead of shipping every miss's body through the channel for
        # the orchestrator to drop.
        Outcome.new(task, fetched, EMPTY_LINKS, nil, hit, conf,
          hit ? capture_exchange(task.url, raw) : nil, gen)
      else
        Outcome.new(task, fetched, EMPTY_LINKS, nil, false, 0.0, nil, gen)
      end
    end

    # The exchange to keep for an outcome that may be recorded, or nil when there is nothing
    # to keep (no response — an error, a refusal, or the request cap).
    #
    # The body is capped at `Settings.capture_max` HERE and not only at the store boundary,
    # because between the two it travels through a channel: without the cap an 8 MiB response
    # (`Body::CAPTURE_READ_MAX`) per queued finding is live at once, and the truncation would
    # then be indistinguishable from a short response. `body_size` carries what the origin
    # actually delivered so the store records it as truncated.
    private def capture_exchange(url : String, raw : Repeater::Result) : Exchange?
      resp = raw.response
      return nil unless resp
      p = Url.parse(url)
      return nil unless p
      target = p.query ? "#{p.path}?#{p.query}" : p.path
      body = raw.body
      size = body.try(&.size.to_i64)
      max = Settings.capture_max
      body = body[0, max].dup if body && body.size > max
      Exchange.new(@capped.request_head(p.scheme, p.host, p.port, target),
        resp, body, size, raw.incomplete?, raw.duration_us, @capped.sni)
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
      interval = pace_interval
      loop do
        # The single funnel for this engine's wire sends, so pacing HERE is what makes
        # `--rate` mean requests/sec exactly once per request. Two things it fixes over
        # pacing the dispatch loop: a RETRY was spaced only by `retry_pause` and so ran on
        # top of the operator's rate, and a Calibrate task used to pay one slot for the task
        # plus one per probe, undershooting the rate by a slot per directory.
        pace(interval)
        raw = @capped.fetch(p.scheme, p.host, p.port, target)
        if raw.error && raw.error != CappedBackend::CAP_ERROR && attempts < @config.retries
          attempts += 1
          sleep @config.retry_pause
          next
        end
        # Book the outcome HERE — the one line every send passes — rather than in the two
        # `handle_*` methods that used to do it. `handle_calibrate` never did, so a run whose
        # whole budget went on CALIBRATION probes against a dead-silent origin recorded no
        # error at all and reported `0 errors` on a run where nothing answered. The error
        # COUNT stays in the handlers (a calibration miss is not a probe result and must not
        # inflate it); only the "what went wrong / did anything work" facts move here.
        if err = raw.error
          @first_error ||= err.presence unless benign_error?(err)
        else
          @successful_sends += 1
        end
        return raw
      end
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

    private def html_like?(ct : String) : Bool
      c = ct.downcase
      c.includes?("html") || c.includes?("xml") || c.includes?("xhtml") || c.empty?
    end

    # Bodies worth scanning for endpoint literals, asked POSITIVELY on purpose. A crawl
    # follows `<img src>`, `<link href>` and every font and archive a page names, so binary
    # responses are the common case here, not the rare one — and each would cost
    # `Extract.text` a full `String#scrub` (a second walk that rebuilds the whole body) to
    # feed a regex no image can match. A body with NO content type never reaches this: it is
    # html-like by default, which the branch above already handles.
    private def text_like?(ct : String) : Bool
      c = ct.downcase
      c.starts_with?("text/") || c.includes?("json") || c.includes?("javascript") ||
        c.includes?("ecmascript") || c.includes?("yaml") || c.includes?("graphql")
    end

    private def bogus_name : String
      Random::Secure.hex(8)
    end

    # ── lifecycle (pause / wake) ────────────────────────────────────────────────────

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
        @template_suppressed, @cluster_suppressed, @uncalibratable, @conf_hist.dup,
        @drift_suppressed)
    end
  end
end
