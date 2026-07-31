require "../env"
require "../fuzz/engine"
require "../host_overrides"
require "../outbound"
require "../repeater/flow_request"
require "./detect"
require "./engine"
require "./types"
require "./wordlist"

module Gori::Miner
  # Why one option set cannot become a runnable mine.
  #
  # The builder never writes the user-facing sentence: every surface phrases these in its
  # own idiom (`gori run mine: --target is required for --request/stdin` vs the TUI's
  # `invalid target — use scheme://host[:port]/path`), and those strings are part of each
  # surface's contract. So `reason` is the machine-readable fact and the `message` here is
  # only a fallback for a caller that has nothing better to say.
  class PlanError < Exception
    enum Reason
      # Neither an explicit target nor one carried by the seeding flow.
      NoTarget
      # A target was given but no host could be parsed out of it (`detail` = the
      # Env-expanded string that failed, for surfaces that quote it back).
      BadTarget
      # Nothing to mine: the surface asked for an empty location set, or auto-detection
      # found none that apply to this request.
      NoLocations
      # The user wordlist could not be read (`detail` = the underlying message).
      Wordlist
      # The candidate-name list came back empty, so the run would send nothing.
      NoNames
      # The request or the target still names an env var that resolves to nothing, so
      # the run would put the token's own characters on the wire (`detail` = the
      # unresolved tokens, prefixed and comma-joined, for surfaces that quote them back).
      UnresolvedEnv
    end

    getter reason : Reason
    getter detail : String?

    def initialize(@reason : Reason, message : String, @detail : String? = nil)
      super(message)
    end
  end

  # A normalized, surface-independent description of ONE mining run.
  #
  # Each surface's remaining job is to parse ITS OWN input format into this — `OptionParser`
  # for `gori run mine`, the JSON args hash for MCP, view state for the TUI tab — and nothing
  # else. Everything downstream of it (Env expansion, location resolution, the wordlist, the
  # sender and the engine) belongs to `Plan.build`.
  #
  # `config` is the live mutable object the caller owns — the TUI's config overlay hands its
  # `Config` instance straight through — so the plan reads that instance, not a copy of it.
  struct PlanOptions
    # The raw request, BEFORE `Env.expand_wire` — the builder owns the expansion so it
    # happens exactly once (see `Plan.build`). A `String` rather than `Bytes` because
    # `Env.expand` is byte-safe: a captured flow's binary body survives the round trip
    # unchanged (see its doc comment), so `String.new(bytes)` here loses nothing.
    property request : String
    # The origin the seeding flow implies, when there is one (nil for --request/stdin).
    property default_target : String?
    # An explicit target, which wins over `default_target` when non-blank.
    property target : String?
    # The effective protocol: the caller has already folded "forced" and "the seeding flow
    # used h2" together, because only the surface knows about its own --http2 flag.
    property? http2 : Bool
    # Where to mine. `nil` means "the surface named none, pick the applicable defaults for
    # this request"; an EMPTY array means "the surface named none on purpose" and is an
    # error — the TUI's config overlay can leave every location unchecked, and silently
    # mining the query string there would ignore what the operator just said.
    property locations : Array(Location)?
    # One bucket size for every RESOLVED location (`--bucket`, MCP `bucket`). Applied by the
    # builder because it can only be spread over the location set once that set is known;
    # nil leaves `config.bucket_size` (which the TUI overlay owns per-location) untouched.
    property bucket : Int32?
    # Locations / concurrency / rps / throttle / timeout / retries / max_requests /
    # user_wordlist / notify. `locations` above is written INTO this instance.
    property config : Config
    # Verify upstream TLS certificates.
    property? verify : Bool
    # TLS SNI override.
    property sni : String?
    # The project's hostname overrides, or nil when the surface has no project to load
    # them from. Only a surface can reach a Store, so this is passed in rather than loaded.
    property overrides : Gori::HostOverrides?

    def initialize(@request : String = "",
                   *,
                   @default_target : String? = nil,
                   @target : String? = nil,
                   @http2 : Bool = false,
                   @locations : Array(Location)? = nil,
                   @bucket : Int32? = nil,
                   @config : Config = Config.new,
                   @verify : Bool = true,
                   @sni : String? = nil,
                   @overrides : Gori::HostOverrides? = nil)
    end
  end

  # A ready-to-run mining job: THE only place a `Miner::Engine` is constructed.
  #
  # The sequence *expand → origin → locations → buckets → wordlist → sender → engine* used
  # to exist three times over (TUI `MinerView#build_engine`, `gori run mine`, MCP
  # `build_mine_job`), and the copies had drifted:
  #
  # - `Env.expand` ran a different number of times on each. On the MCP mine path a seeding
  #   flow's target was expanded TWICE (once in `mine_request_source`, again in
  #   `fuzz_origin`), so a var whose value itself contains a `$TOKEN` resolved one level
  #   deeper there than on the CLI. The TUI expanded the target ZERO times, so `$HOST` was
  #   dialled literally, and it expanded a hand-authored REQUEST at seed time but a
  #   flow-seeded one never — two answers inside one tab.
  # - The TUI never applied the project's hostname overrides (#367), so a host pinned to a
  #   staging IP in the Project tab was mined at its real DNS address.
  #
  # One builder makes those answers the same by construction: once, here, on both the
  # request and the target. Two consequences worth naming, because they are visible:
  # a TUI mine seeded from a captured flow now resolves `$VAR` in the request body (matching
  # `gori run mine <flow-id>` and MCP, which always did), and a Miner session persisted by a
  # PRE-refactor build holds already-expanded bytes, which this expands a second time —
  # harmless unless one var's value contains another var's token.
  #
  # `outbound` is an ARGUMENT, never built here: Layer-1 strictness differs per surface on
  # purpose (`Outbound.agent` / `.cli` / `.interactive`, DESIGN.md §7), and constructing one
  # in here would silently collapse that distinction.
  struct Plan
    getter engine : Engine
    # The dial seam the engine sends through — carries the origin, TLS settings and the
    # hostname overrides, and counts sends the scope refused (`Sender#blocked`).
    getter sender : Fuzz::Sender
    getter config : Config
    getter origin : Fuzz::Origin
    getter? http2 : Bool
    # The Env-expanded wire bytes the run mines, exactly as the engine sees them.
    getter request : Bytes
    # The request-target of the request's first line, for the Layer-1 scope check.
    getter request_target : String
    # The candidate parameter names (built-in list + the user wordlist).
    getter names : Array(String)
    # Resolved locations that `Detect` says do NOT apply to this request — a surface can
    # only reach these by naming them explicitly, and `gori run mine` warns per location
    # rather than dropping them silently.
    getter inapplicable : Array(Location)

    def initialize(@engine : Engine, @sender : Fuzz::Sender, @config : Config,
                   @origin : Fuzz::Origin, @http2 : Bool, @request : Bytes,
                   @request_target : String, @names : Array(String),
                   @inapplicable : Array(Location))
    end

    # The number of distinct (name × location) tests this run performs — the progress
    # denominator every surface reports.
    def total_names : Int64
      @engine.total_names
    end

    # Which locations apply to `request`, decided on the bytes `build` will actually mine.
    # For a surface that must choose what to OFFER before a run exists — the TUI's config
    # overlay renders one checkbox per applicable location, so a location missed here can
    # never be ticked. It has to expand for the same reason `build` does: a `$BODY` var
    # holding a JSON document is not recognisable as JSON until the token is resolved.
    def self.applicable_locations(request : Bytes) : Detect::Applicability
      Detect.detect(Env.expand_wire(String.new(request)))
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      # ONE `Env.expand_wire` over the request, before anything reads it — and first, a
      # refusal when a token in the HEAD resolves to nothing (see `refuse_unresolved`).
      refuse_unresolved(Env.unresolved_wire(options.request))
      request = Env.expand_wire(options.request)
      request_target = Gori::Outbound.request_target(request)
      origin = resolve_origin(options)

      config = options.config
      detected = Detect.detect(request)
      # Written back into the caller's live Config: the engine reads its `locations`, and
      # `gori run mine` prints them, so the resolved set has to be the one everyone sees.
      config.locations = options.locations || detected.default
      raise PlanError.new(PlanError::Reason::NoLocations, "no applicable locations for this request") if config.locations.empty?
      inapplicable = config.locations - detected.applicable
      if b = options.bucket
        config.locations.each { |loc| config.bucket_size[loc] = b }
      end

      names = load_names(config.user_wordlist)
      sender = Fuzz::Sender.new(origin, outbound, http2: options.http2?, verify: options.verify?,
        sni: options.sni, timeout: config.timeout, overrides: options.overrides)
      new(engine: Engine.new(request, options.http2?, names, sender, config), sender: sender,
        config: config, origin: origin, http2: options.http2?, request: request,
        request_target: request_target, names: names, inapplicable: inapplicable)
    end

    # The explicit target when it has one, else the seeding flow's. Blank counts as absent
    # (an agent that sends `"url": ""` means "use the flow's", not "fail").
    private def self.resolve_origin(options : PlanOptions) : Fuzz::Origin
      raw = options.target.presence || options.default_target.presence
      raise PlanError.new(PlanError::Reason::NoTarget, "no target origin") unless raw
      # `deferred: nil` — a DIAL TUPLE cannot defer. Every other unresolved-name site skips a
      # DECLARED binding because a send seam re-scans the same value with `Env.unbound` +
      # `expand_bindings` later; this value is read ONCE, frozen into the plan, and never
      # looked at again — `Fuzz::Sender`/`Discover::Sender` build their ConnPool on it and the
      # Layer-1 `Outbound#check` verdict was already taken against it, so re-resolving per send
      # would move the dial target out from under a scope decision. Deferring bought nothing
      # anyway: a binding value is a token observed from a response, never a hostname, a port
      # or an SNI. Left deferred it shipped as the literal `$SESSION` — every send failing DNS,
      # and `Outbound.scope_url` asked about `https://$SESSION/a`, a URL no rule can match, so
      # the run was refused as out-of-scope, naming the wrong gate.
      refuse_unresolved(Env.unresolved(raw, deferred: nil))
      url = Env.expand(raw)
      scheme, host, port = Repeater::FlowRequest.parse_target(url)
      raise PlanError.new(PlanError::Reason::BadTarget, "could not parse a host from #{url.inspect}", url) if host.empty?
      Fuzz::Origin.new(scheme, host, port)
    end

    # Refuse a run whose request or target still carries a token that resolves to
    # nothing. `Env.expand` leaves an unregistered `$KEY` literal on purpose — right for
    # a display path, wrong here, because the seven characters `$SESSION` then go out as
    # a header value, the origin answers 401, and the results read as findings about the
    # target rather than as a variable the operator never set (#519). This builder is the
    # surface-independent chokepoint every mine surface expands through, so the check
    # lives here once instead of in each of the three.
    private def self.refuse_unresolved(names : Array(String)) : Nil
      return if names.empty?
      detail = Env.token_list(names)
      raise PlanError.new(PlanError::Reason::UnresolvedEnv,
        "unresolved env #{detail}", detail)
    end

    # Built-in names plus the optional user file, read HERE so a bad path surfaces as a
    # PlanError at build time rather than from inside a worker fiber.
    private def self.load_names(user_wordlist : String?) : Array(String)
      names = Wordlist.load(user_wordlist)
      # `Wordlist.load` always prepends the compiled-in list, so an empty result means the
      # candidate set is gone entirely — a run that would send nothing but a baseline.
      raise PlanError.new(PlanError::Reason::NoNames, "the candidate name list is empty") if names.empty?
      names
      # `IO::Error`, not `File::Error`: a missing path raises the latter, but a path that
      # names a DIRECTORY fails on the read with a plain `IO::Error`, and `File::Error` is
      # its subclass — rescuing only that let `--wordlist /some/dir` escape as a backtrace.


    rescue ex : IO::Error
      raise PlanError.new(PlanError::Reason::Wordlist, "wordlist error: #{ex.message}", ex.message)
    end
  end
end
