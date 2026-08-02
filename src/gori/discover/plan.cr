require "./adapters"
require "./engine"
require "./types"
require "./url"
require "./wordlist"
require "../env"
require "../host_overrides"
require "../outbound"

module Gori::Discover
  # Why one option set cannot become a runnable discover plan.
  #
  # The builder never writes the user-facing sentence: every surface phrases these in its
  # own idiom (`gori run discover: --target URL is required` vs the TUI's `start from
  # Sitemap/History (space → "Discover here")`), and those strings are part of each
  # surface's contract. So `reason` is the machine-readable fact and the `message` here is
  # only a fallback for a caller that has nothing better to say.
  class PlanError < Exception
    enum Reason
      # No seed target at all (missing, blank, or an Env var that expanded to nothing).
      NoTarget
      # A seed was given but no http(s) host could be parsed out of it (`detail` = the
      # Env-expanded string that failed, for surfaces that quote it back).
      BadTarget
      # Both techniques disabled — a run with neither spider nor brute-force sends nothing.
      NoTechnique
      # The user wordlist could not be read (`detail` = the underlying error message).
      Wordlist
      # The seed or a custom header still names an env var that resolves to nothing, so
      # the crawl would put the token's own characters on the wire (`detail` = the
      # unresolved tokens, prefixed and comma-joined, for surfaces that quote them back).
      UnresolvedEnv
    end

    getter reason : Reason
    getter detail : String?

    def initialize(@reason : Reason, message : String, @detail : String? = nil)
      super(message)
    end
  end

  # A normalized, surface-independent description of ONE discover run.
  #
  # Each surface's remaining job is to parse ITS OWN input format into this — `OptionParser`
  # for `gori run discover`, the JSON args hash for MCP, the config overlay's state for the
  # TUI tab — and nothing else. Everything downstream of it (seed normalization, wordlist
  # load, scope policy, sender, engine, and the `Env.expand` / host-override wiring that used
  # to drift between the three copies) belongs to `Plan.build`.
  #
  # `config` is the live mutable object the caller owns — the TUI's discover config overlay
  # edits its `Config` in place while a run row is selected, so the plan must read that
  # instance, not a copy of it. The builder never writes to it (see the header expansion in
  # `Plan.build`): a re-run of the same row must see exactly what the operator configured.
  struct PlanOptions
    # Raw seed, BEFORE `Env.expand` and before the scheme default — the builder owns both
    # so they happen exactly once, on every surface (see `Plan.build`).
    property target : String
    # Every knob of the run: pacing, budget, techniques, depth, containment, extensions,
    # custom headers, AND the user wordlist path (`config.user_wordlist`). One field, one
    # source — the TUI's overlay already stored the path there while `gori run --wordlist`
    # and MCP's `wordlist` arg used to pass it separately and leave the Config's copy nil.
    property config : Config
    # Verify upstream TLS certificates.
    property? verify : Bool
    # TLS SNI override — the name presented in the ClientHello (and, under verify, the name
    # the certificate is checked against) WITHOUT changing the dialed host:port. Mirrors
    # `Miner::PlanOptions#sni` / `Fuzz` / `Sequencer`; discover was the one engine of the four
    # that could not carry it, which made an IP-direct sweep of a name-based vhost
    # inexpressible (the crawler also owns its `Host:` header, so there was no second way in).
    property sni : String?
    # Send over HTTP/2 (TLS + ALPN `h2`, or h2c prior-knowledge on http://). `Discover::Sender`
    # has always had the field; nothing could set it, so an h2-only origin was unreachable
    # from this engine while the other three took `--http2`.
    property? http2 : Bool
    # The project's hostname overrides, or nil when the surface has no project to load them
    # from. Only a surface can reach a Store, so this is passed in rather than loaded — and
    # the TUI passes its LIVE `Session#host_overrides` so a mid-session edit is honoured
    # (issue #367).
    property overrides : Gori::HostOverrides?

    def initialize(@target : String,
                   *,
                   @config : Config = Config.new,
                   @verify : Bool = true,
                   @sni : String? = nil,
                   @http2 : Bool = false,
                   @overrides : Gori::HostOverrides? = nil)
    end
  end

  # A ready-to-run discover job: THE only place a `Discover::Engine` is constructed.
  #
  # The sequence *expand → scheme default → parse → wordlist → scope policy → sender →
  # engine* used to exist three times over (TUI `build_engine`, `gori run discover`, MCP
  # `build_discover_job`), and the copies had drifted: the TUI applied neither `Env.expand`
  # nor the project's host overrides and rejected a bare host outright, while MCP expanded
  # custom header values and `gori run discover` did not. One builder makes those answers the
  # same by construction.
  #
  # `outbound` is an ARGUMENT, never built here: Layer-1 strictness differs per surface on
  # purpose (`Outbound.agent` / `.cli` / `.interactive`, DESIGN.md §7), and constructing one
  # in here would silently collapse that distinction into whichever policy was hard-coded.
  # Discover is also the one tool whose *engine* carries a scope of its own (`ScopePolicy`,
  # which keeps the engine Store-free), and that policy is DERIVED from this same Outbound —
  # see `resolve_policy`.
  struct Plan
    getter engine : Engine
    # The seed the engine will actually crawl: Env-expanded, `https://` filled in when the
    # operator gave a bare host, then `Url.normalize`d. This — not the origin — is the string
    # the Layer-1 scope check matches on, since it is the first URL the run requests, and it
    # is normalized so the gate and the crawl can never judge two different spellings.
    getter seed : String
    # The seed's host, for the Layer-1 verdict and the audit line.
    getter host : String
    # The crawl-time scope gate handed to the engine. Exposed rather than left buried inside
    # the Engine because it is a DERIVED scope decision (see `resolve_policy`) and not a run
    # knob the caller passed in — so it stays assertable, and folding it into `Config` would
    # hide the one part of the plan the operator did not choose directly.
    getter policy : ScopePolicy
    getter config : Config
    # Brute-force candidate count (built-in list + the user wordlist), for the CLI preflight.
    getter word_count : Int32
    # The wire seam the engine was built over. Exposed for ONE thing the Engine's own events
    # cannot answer: `Sender#pool_stats`, i.e. how many handshakes the run actually paid
    # (`gori run discover` prints it, the same way the fuzz CLI reports its pool).
    getter sender : Sender

    def initialize(@engine : Engine, @seed : String, @host : String,
                   @policy : ScopePolicy, @config : Config, @word_count : Int32,
                   @sender : Sender)
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      config = options.config
      unless config.spider? || config.bruteforce?
        raise PlanError.new(PlanError::Reason::NoTechnique, "neither spider nor brute-force is enabled")
      end
      raw = resolve_seed(options.target)
      parts = Url.parse(raw) ||
              raise PlanError.new(PlanError::Reason::BadTarget, "could not parse a host from #{raw.inspect}", raw)
      # CANONICAL form, and the reason this is not just `raw`: every scope rule and the crawl
      # itself must judge one spelling of the seed. `Url.normalize` lowercases the host, drops
      # a default port, and fills in the path — without it a `string`/`regex` rule saw whatever
      # the operator typed, so an exclude like `^https://prod\.acme\.test` missed
      # `https://PROD.acme.test/` and `prod.acme.test:443`, while an include anchored on
      # `^https://acme\.test/` missed a seed given as bare `acme.test` (no trailing slash).
      # Both directions were live at HEAD; gating on the normalized string closes them.
      seed = Url.normalize(parts)
      # The seed is spliced straight into a request line (`Sender#build_get`), and `URI.parse`
      # keeps a raw CR/LF in the path — so an env var whose VALUE carries one would inject a
      # second request. Same single rule the header values go through.
      unless Headers.safe_value?(seed)
        raise PlanError.new(PlanError::Reason::BadTarget, "seed contains a control character", raw)
      end
      # Custom header values go through `Headers.expand` below. An unresolved `$NAME` there
      # used to refuse the crawl; it now rides every probe LITERALLY, which is the policy
      # everywhere — `--header 'X-Filter: $ne'` is a Mongo operator the operator meant to
      # send, not a variable they forgot to set. `Headers.safe_value?` still gates the bytes.
      words = load_words(config.user_wordlist)
      policy = resolve_policy(outbound, seed, parts.host)
      # `idle_conns` is the run's concurrency for the reason Fuzz uses it: one worker fiber
      # can hold at most one socket per origin, so a larger pool would only keep dead ones open.
      sender = Sender.new(verify: options.verify?, timeout: config.timeout,
        http2: options.http2?, sni: options.sni,
        headers: Headers.expand(config.headers), overrides: options.overrides,
        keep_alive: config.keep_alive?, idle_conns: config.concurrency)
      new(engine: Engine.new(seed, words, sender, config, policy), seed: seed, host: parts.host,
        policy: policy, config: config, word_count: words.size, sender: sender)
    end

    # ONE `Env.expand` over the seed, then the scheme default: `acme.test/admin` means
    # `https://acme.test/admin` on every surface (the TUI used to reject it as invalid).
    private def self.resolve_seed(raw : String) : String
      # `deferred: nil` — a DIAL TUPLE cannot defer. Every other unresolved-name site skips a
      # DECLARED binding because a send seam re-scans the same value with `Env.expand_bindings`
      # later; this value is read ONCE, frozen into the plan, and never
      # looked at again — `Fuzz::Sender`/`Discover::Sender` build their ConnPool on it and the
      # Layer-1 `Outbound#check` verdict was already taken against it, so re-resolving per send
      # would move the dial target out from under a scope decision. Deferring bought nothing
      # anyway: a binding value is a token observed from a response, never a hostname, a port
      # or an SNI. Left deferred it shipped as the literal `$SESSION` — every send failing DNS,
      # and `Outbound.scope_url` asked about `https://$SESSION/a`, a URL no rule can match, so
      # the run was refused as out-of-scope, naming the wrong gate.
      refuse_unresolved(Env.unresolved(raw.strip, deferred: nil))
      target = Env.expand(raw.strip)
      raise PlanError.new(PlanError::Reason::NoTarget, "no seed target") if target.empty?
      target.matches?(/\Ahttps?:\/\//i) ? target : "https://#{target}"
    end

    # The crawl-time scope gate, derived from the Outbound the surface handed in rather than
    # re-derived per surface (`gori run discover` and MCP each carried a copy of this, the
    # MCP one labelled "mirror of the CLI's"; the TUI had a third, shorter one).
    #
    # No project at all ⇒ OpenScope, nothing bounded. Otherwise StoreScope (sandbox/exclude
    # + the include boundary) — UNLESS Layer 1 was waived by the OPERATOR (--allow-unscoped /
    # allow_unscoped:true) AND the seed is genuinely outside the include boundary, in which
    # case UnscopedStoreScope keeps the hard sandbox/exclude gate but drops the include
    # boundary so scope-aware containment can fall back to same-origin. Without that the flag
    # was a no-op on the policy and gutted the crawl to the seed alone (see UnscopedStoreScope).
    #
    # The waiver test is on `Reason::Operator` specifically, NOT on `gate.waived?`: the TUI's
    # Outbound is also waived, for `Reason::Interactive`, and "the human typed this target"
    # is not a request to drop the include boundary the same human configured. (That test
    # would read better as an `Outbound#operator_waived?` predicate — `src/gori/outbound.cr`
    # already names `gated?` for the same reason — but that file belongs to another issue.)
    private def self.resolve_policy(outbound : Gori::Outbound, seed : String, host : String) : ScopePolicy
      scope = outbound.scope
      # The scope's OWN reading of the seed, not a second copy of it: `Verdict#decision` is
      # gate-independent (`Outbound#evaluate`), so `unscoped?` is "no configured scope" and
      # `in_scope?` is "inside the include boundary" — the two questions this used to answer
      # by pulling the Scope out and re-running `configured?` / `matches_url?` by hand.
      verdict = outbound.check(seed, host)
      # Only a genuinely absent project gets OpenScope. A project whose scope simply has no
      # RULES does not: `verdict.unscoped?` is true exactly when `Scope#configured?` is false,
      # and Sandbox is enabled independently of rules (`Scope#enable_sandbox`) — so discover
      # used to crawl and brute-force completely unrestricted on the one configuration
      # DESIGN.md §3 singles out as fail-CLOSED, while the proxy blocked every request and
      # every other sweep (`Outbound#sweep_block`, which only skips on a nil scope) refused.
      #
      # Nothing about containment changes: `StoreScope#configured?` delegates to
      # `Scope#configured?`, which is false here too, so scope-aware containment still falls
      # back to same-origin and `boundary?` is never consulted. The only difference is that
      # `allowed?` starts consulting Sandbox and EXCLUDE — both false on an ordinary
      # rule-less project with Sandbox off, so those runs are unaffected.
      return OpenScope.new if scope.nil?
      return StoreScope.new(scope) if verdict.unscoped?
      if outbound.reason == Gori::Outbound::Reason::Operator && !verdict.in_scope?
        return UnscopedStoreScope.new(scope)
      end
      StoreScope.new(scope)
    end

    # Refuse a crawl whose seed or custom headers still carry a token that resolves to
    # nothing. `Env.expand` leaves an unregistered `$KEY` literal on purpose — right for
    # a display path, wrong here, because the seven characters `$SESSION` then go out as
    # a header value on every probe, the origin answers 401 to all of them, and the run
    # reports a uniformly locked-down target rather than a variable the operator never
    # set (#519). This builder is the surface-independent chokepoint every discover
    # surface expands through, so the check lives here once instead of in each of three.
    private def self.refuse_unresolved(names : Array(String)) : Nil
      return if names.empty?
      detail = Env.token_list(names)
      raise PlanError.new(PlanError::Reason::UnresolvedEnv,
        "unresolved env #{detail}", detail)
    end

    # A missing/unreadable/binary wordlist is a user mistake, not a crash: every surface
    # already caught it (each with its own rescue, one of them blanket), so the catch-all
    # lives here once. Nothing in `Wordlist.load` raises PlanError, so this cannot swallow one.
    private def self.load_words(path : String?) : Array(String)
      Wordlist.load(path)
    rescue ex
      raise PlanError.new(PlanError::Reason::Wordlist, "wordlist error: #{ex.message}", ex.message)
    end
  end
end
