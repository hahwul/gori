require "../env"
require "../host_overrides"
require "../outbound"
require "../repeater/flow_request"
require "../fuzz/engine"
require "./engine"
require "./types"

module Gori::Sequencer
  # Why one option set cannot become a runnable collection.
  #
  # The builder never writes the user-facing sentence: every surface phrases these in its
  # own idiom (`gori run sequence: token location selector is empty` vs the TUI's `set a
  # token location first`), and those strings are part of each surface's contract. So
  # `reason` is the machine-readable fact and the `message` here is only a fallback for a
  # caller that has nothing better to say.
  class PlanError < Exception
    enum Reason
      # Neither an explicit target nor one carried by the seeding flow (live replay).
      NoTarget
      # A target was given but no host could be parsed out of it (`detail` = the
      # Env-expanded string that failed, for surfaces that quote it back).
      BadTarget
      # A token location whose kind needs a selector (cookie / header / regex / jsonpath)
      # was left blank, so every response would miss and the run would only burn requests.
      NoTokenLoc
      # Manual mode with nothing to analyze: no pasted token, or all of them blank.
      NoTokens
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

  # A normalized, surface-independent description of ONE sequencer run.
  #
  # Each surface's remaining job is to parse ITS OWN input format into this — `OptionParser`
  # for `gori run sequence`, the JSON args hash for MCP, view state for the TUI tab — and
  # nothing else. Everything downstream of it (Env expansion, origin resolution, the sender,
  # the engine) belongs to `Plan.build`.
  #
  # `config` is the live mutable object the caller owns — the TUI's config overlay binds one
  # `Config` instance and edits it in place, so the plan must read that instance, not a copy.
  # It carries mode / token location / goal / concurrency / rps / throttle / jitter / timeout
  # / retries / max_requests / manual tokens / notify policy.
  struct PlanOptions
    # The raw request to replay, BEFORE `Env.expand_wire` — the builder owns the expansion
    # so it happens exactly once (see `Plan.build`). Empty for a manual (analyse-only) run.
    property request : Bytes
    # The origin the seeding flow implies, when there is one (nil for --request/stdin).
    property default_target : String?
    # An explicit target, which wins over `default_target` when non-blank.
    property target : String?
    # The effective protocol: the caller has already folded "forced" and "the seeding flow
    # used h2" together, because only the surface knows about its own --http2 flag.
    property? http2 : Bool
    # Mode, token descriptor, goal, pacing, caps — the live instance the caller owns.
    property config : Config
    # Verify upstream TLS certificates.
    property? verify : Bool
    # TLS SNI override.
    property sni : String?
    # The project's hostname overrides, or nil when the surface has no project to load them
    # from. Only a surface can reach a Store (or, in the TUI, the live `Session` copy the
    # HOST OVERRIDES pane edits), so this is passed in rather than loaded here.
    property overrides : Gori::HostOverrides?

    def initialize(@request : Bytes = Bytes.empty,
                   *,
                   @default_target : String? = nil,
                   @target : String? = nil,
                   @http2 : Bool = false,
                   @config : Config = Config.new,
                   @verify : Bool = true,
                   @sni : String? = nil,
                   @overrides : Gori::HostOverrides? = nil)
    end
  end

  # A ready-to-run collection: THE only place a `Sequencer::Engine` is constructed.
  #
  # The sequence *expand → origin → token-descriptor check → sender → engine* used to exist
  # three times over (TUI `SequencerView#build_engine`, `gori run sequence`, MCP
  # `build_sequence_job`), and the copies had drifted: the TUI applied neither `Env.expand`
  # to the replayed request nor the project's host overrides to the dial, so the same
  # request sent from the Sequencer tab and from `gori run sequence` could go to a different
  # machine with different bytes. One builder makes those answers the same by construction.
  #
  # `outbound` is an ARGUMENT, never built here: Layer-1 strictness differs per surface on
  # purpose (`Outbound.agent` / `.cli` / `.interactive`, DESIGN.md §7), and constructing one
  # in here would silently collapse that distinction into whichever policy was hard-coded.
  struct Plan
    getter engine : Engine
    getter config : Config
    # Where every live send is dialled, or NIL on an ANALYSE-ONLY plan. Manual mode reads a
    # pasted token list and never opens a socket, so it has no origin and no sender — where
    # the TUI used to hand the engine a throwaway `Fuzz::Sender` pointed at
    # http://localhost:80 purely to satisfy the constructor.
    getter origin : Fuzz::Origin?
    # The Env-expanded wire bytes the run replays (empty on an analyse-only plan).
    getter request : Bytes
    # The request-target of `request`'s first line, for the surface's Layer-1 scope check
    # (`Outbound#check_request`). Empty on an analyse-only plan — there is no request.
    getter request_target : String
    getter? http2 : Bool

    def initialize(@engine : Engine, @config : Config, @origin : Fuzz::Origin?,
                   @request : Bytes, @request_target : String, @http2 : Bool)
    end

    # The progress denominator every surface reports against: the goal in live replay, the
    # non-blank pasted-token count in manual mode.
    def goal : Int32
      @engine.total
    end

    # True when this plan sends nothing (manual mode).
    def analyse_only? : Bool
      @origin.nil?
    end

    # The origin, for a surface whose options are statically live replay — `gori run
    # sequence` and MCP `sequence_start` both handle their manual path (--tokens /
    # sequence_analyze) without building a plan at all. Raises rather than returning nil so
    # those two need no dead nil-branch around every use.
    def origin! : Fuzz::Origin
      @origin || raise Gori::Error.new("sequencer: an analyse-only plan has no origin")
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      config = options.config
      return analyse(config) if config.mode.manual?

      # Origin BEFORE the token descriptor — the order the TUI and `gori run sequence`
      # already reported in. (MCP enforces its own "exactly one of cookie|header|regex|
      # position|jsonpath" rule while parsing the args hash, so a blank descriptor cannot
      # reach the check below from there and its precedence is decided before this point.)
      origin = resolve_origin(options)
      loc = config.token_loc
      if !loc.kind.position? && loc.selector.strip.empty?
        raise PlanError.new(PlanError::Reason::NoTokenLoc, "no token location selector")
      end

      # ONE `Env.expand_wire` over the request, before anything reads it. The TUI never ran
      # it at all, so a `$TOKEN` in a sequenced request went out literally there while
      # resolving on the other two surfaces; `gori run sequence` and MCP each ran it in
      # their source reader, and doing it there AND here would resolve a var whose value
      # itself contains a `$TOKEN` twice. A token in the HEAD that resolves to nothing
      # refuses the run first (see `refuse_unresolved`).
      refuse_unresolved(Env.unresolved_wire(String.new(options.request)))
      request = Env.expand_wire(String.new(options.request))
      sender = Fuzz::Sender.new(origin, outbound, http2: options.http2?, verify: options.verify?,
        sni: options.sni, timeout: config.timeout, overrides: options.overrides)
      new(engine: Engine.new(request, options.http2?, sender, config), config: config,
        origin: origin, request: request,
        request_target: Gori::Outbound.request_target(request), http2: options.http2?)
    end

    # A manual run: the pasted tokens are replayed into the same event stream with no
    # sender, no origin and no request — nothing here can reach the network.
    private def self.analyse(config : Config) : Plan
      if config.manual_tokens.all?(&.empty?)
        raise PlanError.new(PlanError::Reason::NoTokens, "no tokens to analyze")
      end
      new(engine: Engine.new(Bytes.empty, false, nil, config), config: config,
        origin: nil, request: Bytes.empty, request_target: "", http2: false)
    end

    # The explicit target when it has one, else the seeding flow's. Blank counts as absent
    # (an agent that sends `"url": ""` means "use the flow's", not "fail").
    private def self.resolve_origin(options : PlanOptions) : Fuzz::Origin
      raw = options.target.presence || options.default_target.presence
      raise PlanError.new(PlanError::Reason::NoTarget, "no target origin") unless raw
      refuse_unresolved(Env.unresolved(raw))
      url = Env.expand(raw)
      scheme, host, port = Repeater::FlowRequest.parse_target(url)
      if host.empty?
        raise PlanError.new(PlanError::Reason::BadTarget, "could not parse a host from #{url.inspect}", url)
      end
      Fuzz::Origin.new(scheme, host, port)
    end

    # Refuse a collection whose request or target still carries a token that resolves to
    # nothing. `Env.expand` leaves an unregistered `$KEY` literal on purpose — right for
    # a display path, wrong here, because the seven characters `$SESSION` then go out as
    # a header value, the origin answers 401, and the sampled tokens describe a rejected
    # session rather than the one the operator meant to measure (#519). This builder is
    # the surface-independent chokepoint every sequence surface expands through, so the
    # check lives here once instead of in each of the three. The manual (analyse-only)
    # path returns before this and needs none — it opens no socket.
    private def self.refuse_unresolved(names : Array(String)) : Nil
      return if names.empty?
      detail = Env.token_list(names)
      raise PlanError.new(PlanError::Reason::UnresolvedEnv,
        "unresolved env #{detail}", detail)
    end
  end
end
