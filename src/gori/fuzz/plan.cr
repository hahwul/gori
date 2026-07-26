require "../decoder"
require "../env"
require "../host_overrides"
require "../outbound"
require "../repeater/flow_request"
require "./engine"
require "./generator"
require "./matcher"
require "./payload"
require "./template"
require "./types"

module Gori::Fuzz
  # Why one option set cannot become a runnable plan.
  #
  # The builder never writes the user-facing sentence: every surface phrases these in its
  # own idiom (`gori run fuzz: no positions — add §…§ markers, --auto, or --mark TOKEN`
  # vs the TUI's `mark a position first — ^A params · ^K word`), and those strings are
  # part of each surface's contract. So `reason` is the machine-readable fact and the
  # `message` here is only a fallback for a caller that has nothing better to say.
  class PlanError < Exception
    enum Reason
      # The template carries no §…§ position after auto-marking and --mark tokens.
      NoPositions
      # Neither an explicit target nor one carried by the seeding flow.
      NoTarget
      # A target was given but no host could be parsed out of it (`detail` = the
      # Env-expanded string that failed, for surfaces that quote it back).
      BadTarget
      # No payload sets at all.
      NoPayloads
    end

    getter reason : Reason
    getter detail : String?

    def initialize(@reason : Reason, message : String, @detail : String? = nil)
      super(message)
    end
  end

  # A normalized, surface-independent description of ONE fuzz run.
  #
  # Each surface's remaining job is to parse ITS OWN input format into this — `OptionParser`
  # for `gori run fuzz`, the JSON args hash for MCP, view state for the TUI tab — and nothing
  # else. Everything downstream of it (marking, template parse, payload sets, generator,
  # sender, engine, and the `Env.expand` / host-override / decoder-registry wiring that used
  # to drift between the three copies) belongs to `Plan.build`.
  #
  # `config` and `matcher` are the live mutable objects the caller owns — the TUI's config
  # overlay edits its `Config` in place while a tab is open, so the plan must read that
  # instance, not a copy of it.
  struct PlanOptions
    # Raw template text, BEFORE `Env.expand` — the builder owns the expansion so it happens
    # exactly once (see `Plan.build`).
    property template : String
    # The origin the seeding flow implies, when there is one (nil for --request/stdin).
    property default_target : String?
    # An explicit target, which wins over `default_target` when non-blank.
    property target : String?
    # Mark every query / cookie / body parameter value (`--auto`, MCP `auto:true`).
    property? auto_mark : Bool
    # Literal tokens to wrap in §…§ (`--mark`, MCP `marks`). Applied after `auto_mark`.
    property marks : Array(String)
    # The effective protocol: the caller has already folded "forced" and "the seeding flow
    # used h2" together, because only the surface knows about its own --http2 flag.
    property? http2 : Bool
    # Payload sources, in position order. `Plan.build` pairs each with `processors`.
    property sources : Array(PayloadSource)
    # The processing pipeline applied to EVERY set (all three surfaces share one list).
    property processors : Array(Processor)
    # Mode / concurrency / rps / throttle / retries / timeout / follow_redirects /
    # auto_calibrate / keep_bodies (the evidence policy) / max_requests.
    property config : Config
    # Match + filter conditions and the extract regex.
    property matcher : Matcher
    # Verify upstream TLS certificates.
    property? verify : Bool
    # TLS SNI override.
    property sni : String?
    # The project's hostname overrides, or nil when the surface has no project to load
    # them from. Only a surface can reach a Store, so this is passed in rather than loaded.
    property overrides : Gori::HostOverrides?

    def initialize(@template : String = "",
                   *,
                   @default_target : String? = nil,
                   @target : String? = nil,
                   @auto_mark : Bool = false,
                   @marks : Array(String) = [] of String,
                   @http2 : Bool = false,
                   @sources : Array(PayloadSource) = [] of PayloadSource,
                   @processors : Array(Processor) = [] of Processor,
                   @config : Config = Config.new,
                   @matcher : Matcher = Matcher.new,
                   @verify : Bool = true,
                   @sni : String? = nil,
                   @overrides : Gori::HostOverrides? = nil)
    end
  end

  # A ready-to-run fuzz job: THE only place a `Fuzz::Engine` is constructed.
  #
  # The sequence *expand → auto-mark → mark → template parse → origin → payload sets →
  # generator → sender → engine* used to exist three times over (TUI `build_engine`,
  # `gori run fuzz`, MCP `build_fuzz_job`), and the copies had drifted: the TUI never
  # applied the project's host overrides, and `gori run fuzz` ran `Env.expand` over a
  # flow's target TWICE (once on the raw target, again inside `resolve_fuzz_target`), so
  # a var whose value itself contained a `$TOKEN` expanded on one surface but not another.
  # One builder makes those answers the same by construction.
  #
  # `outbound` is an ARGUMENT, never built here: Layer-1 strictness differs per surface on
  # purpose (`Outbound.agent` / `.cli` / `.interactive`, DESIGN.md §7), and constructing one
  # in here would silently collapse that distinction into whichever policy was hard-coded.
  struct Plan
    getter engine : Engine
    getter generator : Generator
    getter matcher : Matcher
    getter config : Config
    getter origin : Origin
    getter template : Template
    getter? http2 : Bool
    # The run's keep-alive pool, or nil when it runs connection-per-send (h2, or
    # `keep_alive` off). Surfaces read its counters to report how many handshakes the run
    # actually paid for — the one directly observable measure of what pooling bought.
    getter pool : ConnPool?
    # The request-target of the template's first line, taken BEFORE marking so the §…§
    # bytes never leak into the string the scope gate matches on.
    getter request_target : String
    # {token, occurrence count} per `--mark`, in the order the marks were applied — the
    # CLI warns when one token silently matched several spots (including in headers).
    getter mark_matches : Array({String, Int32})

    def initialize(@engine : Engine, @generator : Generator, @matcher : Matcher,
                   @config : Config, @origin : Origin, @template : Template,
                   @http2 : Bool, @request_target : String,
                   @mark_matches : Array({String, Int32}), @pool : ConnPool? = nil)
    end

    # Candidate request count, or nil when unknown / Int64-overflowing. Reads the payload
    # sets (a wordlist is counted + opened here), so a bad path surfaces as `Gori::Error`
    # at this call, not from inside a worker fiber.
    def total : Int64?
      @engine.total
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      # ONE `Env.expand` over the template, before anything reads it.
      text = Env.expand(options.template)
      text = Template.auto_mark(text) if options.auto_mark?
      marker = Template::MARKER
      mark_matches = options.marks.map do |tok|
        occ = {tok, occurrences(text, tok)}
        text = text.gsub(tok, "#{marker}#{tok}#{marker}")
        occ
      end
      template = Template.parse(text, options.http2?)
      raise PlanError.new(PlanError::Reason::NoPositions, "the template has no §…§ positions") if template.position_count == 0

      # The string the Layer-1 scope check matches on, taken from the template's BASELINE
      # rendering (every position = its own default) rather than the raw text. The TUI's
      # template arrives ALREADY marked, so reading the raw first line would hand the gate
      # `/find?term=§VAL§` there while handing it `/find?term=VAL` from the CLI and MCP,
      # whose text is marked by the builder. Rendering the defaults back out is marker-free
      # on all three and byte-identical to what those two used to pass.
      request_target = Gori::Outbound.request_target(template.render(template.default_payloads))

      origin = resolve_origin(options)

      sets = options.sources.map { |src| PayloadSet.new(src, options.processors) }
      raise PlanError.new(PlanError::Reason::NoPayloads, "no payload sets") if sets.empty?

      config = options.config
      matcher = options.matcher
      # Auto-calibration is a Config knob the Matcher enforces, so the two must agree — it
      # was previously synced by hand on two surfaces out of three.
      matcher.auto_calibrate = config.auto_calibrate?
      # Sniper / BatteringRam take ONE shared set; Pitchfork / ClusterBomb take one per
      # position (see Generator's set contract).
      gen_sets = config.mode.per_position? ? sets : [sets.first]
      # The shared decoder registry applies each position's inline `¦chain` at render time.
      # Wired here so a new surface cannot forget it and silently send un-transformed payloads.
      generator = Generator.new(template, gen_sets, config, registry: Decoder.shared_registry)
      # One parked connection per worker fiber is the ceiling that can ever be checked out
      # at once, so the pool is sized to the (clamped) concurrency the engine will run at.
      sender = Sender.new(origin, outbound, http2: options.http2?, verify: options.verify?,
        sni: options.sni, timeout: config.timeout, overrides: options.overrides,
        keep_alive: config.keep_alive?,
        idle_conns: config.concurrency.clamp(1, Engine::MAX_CONCURRENCY))
      new(engine: Engine.new(generator, matcher, sender, config), generator: generator,
        matcher: matcher, config: config, origin: origin, template: template,
        http2: options.http2?, request_target: request_target, mark_matches: mark_matches,
        pool: sender.pool)
    end

    # The explicit target when it has one, else the seeding flow's. Blank counts as absent
    # (an agent that sends `"url": ""` means "use the flow's", not "fail").
    private def self.resolve_origin(options : PlanOptions) : Origin
      raw = options.target.presence || options.default_target.presence
      raise PlanError.new(PlanError::Reason::NoTarget, "no target origin") unless raw
      url = Env.expand(raw)
      scheme, host, port = Repeater::FlowRequest.parse_target(url)
      raise PlanError.new(PlanError::Reason::BadTarget, "could not parse a host from #{url.inspect}", url) if host.empty?
      Origin.new(scheme, host, port)
    end

    # Non-overlapping occurrences of a literal token (mirrors what `String#gsub` will
    # replace), so a surface can warn about a short token matching far more than intended.
    private def self.occurrences(text : String, token : String) : Int32
      return 0 if token.empty?
      count = 0
      idx = 0
      while found = text.index(token, idx)
        count += 1
        idx = found + token.size
      end
      count
    end
  end
end
