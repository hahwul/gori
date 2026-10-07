require "../env"
require "../fuzz/content_length"
require "../fuzz/engine"
require "../host_overrides"
require "../outbound"
require "../payload_from"
require "../process_hook"
require "../repeater/flow_request"
require "../request_macro"
require "../settings"
require "./detect"
require "./engine"
require "./hook_backend"
require "./macro_backend"
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
      # Nothing to mine: the surface asked for an empty location set, auto-detection found
      # none that apply to this request, or EVERY location the surface named is one this
      # request cannot carry (`detail` = why, per location, from `Detect.inapplicable_reason`;
      # nil for the other two). Refused before any send: a run with nothing to inject still
      # sent its baseline and then reported every name as tested and clean (#1203).
      NoLocations
      # The user wordlist could not be read (`detail` = the underlying message).
      Wordlist
      # The candidate-name list came back empty, so the run would send nothing.
      NoNames
      # The request or the target still names an env var that resolves to nothing, so
      # the run would put the token's own characters on the wire (`detail` = the
      # unresolved tokens, prefixed and comma-joined, for surfaces that quote them back).
      UnresolvedEnv
      # The per-request transform hook (`--hook`, #846) is set but its argv does not tokenize
      # (`detail` = what is wrong, from `ProcessHook.parse_argv`). Refused HERE so a bad command
      # is a build-time error, not a per-worker one that would fail every send of the run.
      HookArgv
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
    # PROVENANCE: this request is a CAPTURED FLOW's stored bytes, not one the operator typed.
    # Same flag, same meaning and same consequences as `Fuzz::PlanOptions#evidence?` and
    # `Repeater::PlanOptions#evidence?` — with it off, seeding the miner from a capture
    # refused any head carrying an OData/Mongo `$token` and promoted a bare-LF head to CRLF
    # on every one of the run's probes, while `gori run repeater <same-flow>` replayed it
    # byte-exact. `--request FILE` / stdin / the TUI editor keep the draft behaviour.
    property? evidence : Bool
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
    # Candidate names read from the project's own captured data (#1352): each `param-names`
    # source names a QL-selected flow set whose parameter names are tested BEFORE the built-in
    # list and the user wordlist (after any explicit `config.seed_names`). Only that projection
    # is a list of NAMES; another is refused by name. Resolved by `Plan.build`, against `project`.
    property project_names : Array(PayloadFrom::Spec)
    # The project `project_names` are read from — passed in like `overrides`, since only a surface
    # can reach a store. A name source with no project to read is refused.
    property project : Gori::Store?
    # Drain the off-commit search index before a `body:`/free-text source query, and refuse when it
    # cannot: the default for one-shot CLI and MCP. The live TUI passes false.
    property? project_drain_fts : Bool

    def initialize(@request : String = "",
                   *,
                   @evidence : Bool = false,
                   @default_target : String? = nil,
                   @target : String? = nil,
                   @http2 : Bool = false,
                   @locations : Array(Location)? = nil,
                   @bucket : Int32? = nil,
                   @config : Config = Config.new,
                   @verify : Bool = true,
                   @sni : String? = nil,
                   @overrides : Gori::HostOverrides? = nil,
                   @project_names : Array(PayloadFrom::Spec) = [] of PayloadFrom::Spec,
                   @project : Gori::Store? = nil,
                   @project_drain_fts : Bool = true)
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
    # The candidate parameter names, in the order they are tested: the explicit `seed_names`,
    # then the names read from the project (`PlanOptions#project_names`), then the built-in list,
    # then the user wordlist — de-duplicated, the first sighting keeping its place.
    getter names : Array(String)

    # What each project name source read (#1352), in the order given: flows, names, what a
    # cap cut short. Never carries a value beyond the names themselves, which are `names`.
    getter project_reports : Array(PayloadFrom::Report)

    # Named locations that `Detect` says do NOT apply to this request, dropped from the run —
    # a surface can only reach these by naming them explicitly, so each one says so
    # (`gori run mine` per location on stderr, MCP as `not-applicable` skipped rows).
    getter inapplicable : Array(Location)

    # The run's request-time macro (#1350), or nil when it has none. The lane the engine's
    # `MacroBackend` gates every request through; a surface reads `request_macro_info` for the
    # plan-time line and `Progress#request_macro` for what happened.
    getter request_macro : RequestMacro::Lane?

    def initialize(@engine : Engine, @sender : Fuzz::Sender, @config : Config,
                   @origin : Fuzz::Origin, @http2 : Bool, @request : Bytes,
                   @request_target : String, @names : Array(String),
                   @inapplicable : Array(Location),
                   @project_reports : Array(PayloadFrom::Report) = [] of PayloadFrom::Report,
                   @request_macro : RequestMacro::Lane? = nil)
    end

    # What the macro does to this run, said before it starts: the steps, the cadence, whether a
    # value is shared between requests, and the parallelism that leaves the run. nil without a
    # macro. The engine's OWN clamped concurrency, so the line cannot describe a number the run
    # will not use.
    def request_macro_info : RequestMacro::Info?
      @request_macro.try(&.info(@engine.concurrency))
    end

    # The run's keep-alive pool, or nil when it runs connection-per-send (h2, or
    # `config.keep_alive?` off). Surfaces read its counters to report how many handshakes the
    # run actually paid for — the one directly observable measure of what pooling bought.
    # Same accessor `Fuzz::Plan` publishes, so the two CLI reporters stay one shape.
    def pool : Fuzz::Pool?
      @sender.pool
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
      # ONE `Env.expand_wire` over the request, before anything reads it. A DRAFT-time pass,
      # skipped for EVIDENCE — see `PlanOptions#evidence?`.
      #
      # The head-only refusal that used to run first (#519) is gone: a `$NAME` with no value
      # is a literal string on the wire (see `Env::Escape`). It refused a Mongo `$ne` and a
      # GraphQL `$id` in a query string — the operator's test case, not a typo.
      #
      # `ContentLength.resync_expanded` re-frames the head when expansion moved the BODY's
      # byte length — see its comment. Without it a mine reported `baseline: stable · 0 found ·
      # 0 errors` over a conversation the target had 400'd. It and the dropped refusal are
      # orthogonal edits to this one statement; the union is what both intended.
      request = if options.evidence?
                  options.request.to_slice
                else
                  Fuzz::ContentLength.resync_expanded(options.request.to_slice, Env.expand_wire(options.request))
                end
      request = frame_unframed_body(request)
      request_target = Gori::Outbound.request_target(request)
      origin = resolve_origin(options)

      config = options.config
      detected = Detect.detect(request)
      # Written back into the caller's live Config: the engine reads its `locations`, and
      # `gori run mine` prints them, so the resolved set has to be the one everyone sees.
      #
      # A named location this request cannot carry is DROPPED from the run, not kept in it: the
      # engine could inject nothing there, yet counted its names as tested and clean (#1203).
      # The plan and the engine both keep the list, so every surface can say what was skipped.
      # Refused BEFORE the write-back, so a refusal leaves the TUI's live selection as it was.
      requested = options.locations || detected.default
      inapplicable = requested - detected.applicable
      runnable = requested - inapplicable
      if runnable.empty?
        why = inapplicable.empty? ? nil : inapplicable.map { |loc| "#{loc.label}: #{Detect.inapplicable_reason(loc, request)}" }.join("; ")
        raise PlanError.new(PlanError::Reason::NoLocations, "no applicable locations for this request", why)
      end
      config.locations = runnable
      if b = options.bucket
        config.locations.each { |loc| config.bucket_size[loc] = b }
      end

      project_reports = [] of PayloadFrom::Report
      names = load_names(config.user_wordlist, config.seed_names, resolve_project_names(options, project_reports))
      # `evidence:` carries the branch above to the SEND seam, where session bindings resolve
      # (`Fuzz::Sender#evidence?`). Round 6 marked the miner's INJECTED candidates verbatim
      # and cleared the carrier as safe because gori's canaries cannot contain a `$` — true
      # of the material and false of the message: on an evidence run the carrier is this
      # untouched captured request, and `Baseline#calibrate` sends it raw before any
      # injection at all. Reproduced: `gori run mine <flow> --bind-from <flow>` put the live
      # session token on the wire in 6 of 8 requests.
      #
      # The per-request transform hook argv (#846), parsed HERE so a bad command is a build-time
      # `PlanError`, not a per-worker one. Decided BEFORE the sender is built because it moves the
      # session-slot overlay: a hook must sign the FINAL bytes, so when one is present the overlay
      # becomes the hook wrapper's job and the sender must not also apply it (see below).
      hook_argv = resolve_hook_argv(config)
      # The request-time macro (#1350), validated HERE for the reason the hook is: a build-time
      # refusal before a request is sent, not a per-worker surprise. Its steps are the first
      # traffic the run produces.
      request_macro = build_request_macro(options, outbound, request)
      # `idle_conns: concurrency` — one parked socket per worker fiber is the most that can
      # ever be checked out at once, so a larger pool would only hold dead sockets open.
      #
      # `slot_overlay: hook_argv.nil?` — the active session slot's header overlay is applied by
      # the sender by default (true), AFTER `$NAME` expansion. That is one transform too late for
      # a hook: it would rewrite headers over bytes the hook already signed, so a `--slot analyst
      # --hook ./sign.sh` run against a signed API would ship an overlay the signature does not
      # cover and the target would reject every probe. So when a hook is present the sender leaves
      # the overlay alone and `HookBackend` applies it BEFORE the hook — the hook signs the slot's
      # identity headers along with everything else.
      sender = Fuzz::Sender.new(origin, outbound, http2: options.http2?, verify: options.verify?,
        sni: options.sni, timeout: config.timeout, overrides: options.overrides,
        keep_alive: config.keep_alive?, idle_conns: config.concurrency,
        evidence: options.evidence?, slot_overlay: hook_argv.nil?)
      # The per-request transform hook (#846), when the run has one. Wrapped OUTSIDE the raw
      # sender and INSIDE the engine's `CappedBackend`, so the cap refuses a send before the
      # hook forks once the budget is spent — see `HookBackend`. The raw `sender` is still what
      # the plan holds for `pool`/`blocked` reporting; `HookBackend` delegates those down to it.
      backend = hook_argv ? HookBackend.new(sender, hook_argv,
        Gori::Settings.hook_timeout_secs.seconds, hook_env(origin)) : sender
      # The macro OUTSIDE the hook, so the value it leaves is bound before the hook expands the
      # request and signs it (see `MacroBackend`).
      backend = MacroBackend.new(backend, request_macro) if request_macro
      new(engine: Engine.new(request, options.http2?, names, backend, config, inapplicable, request_macro),
        sender: sender,
        config: config, origin: origin, http2: options.http2?, request: request,
        request_target: request_target, names: names, inapplicable: inapplicable,
        project_reports: project_reports, request_macro: request_macro)
    end

    # The run's macro lane, or nil when it has none (or has it `off`). Refused with the words the
    # operator can act on: no project to read the steps from; a step that cannot run
    # (`Runner.build` names it); a request that can never carry what the steps produce.
    private def self.build_request_macro(options : PlanOptions, outbound : Gori::Outbound,
                                         request : Bytes) : RequestMacro::Lane?
      spec = options.config.request_macro
      return nil unless spec && spec.active?
      store = options.project || raise RequestMacro::Error.new(
        "a macro reads its steps from the project's Repeater sessions, and this run has no project attached — " \
        "open one (--project / --db), or seed the run from a captured flow or a Repeater session")
      runner = RequestMacro::Runner.build(spec, store, outbound,
        overrides: options.overrides, verify: options.verify?)
      runner.check_reachable!([String.new(request)], options.evidence?)
      RequestMacro::Lane.new(spec, runner, "miner", "request")
    end

    # The names the project's own traffic offers (#1352), read HERE — the one place a store is
    # read for a mine, so every surface gets the same caps, secret policy and refusals. Header
    # and cookie NAMES are not withheld (a name is not a value); an unknown location is refused
    # by the source's own policy, and the run's location checks still decide which candidate is
    # tested where (`Miner::Engine#skipped_names`).
    private def self.resolve_project_names(options : PlanOptions, reports : Array(PayloadFrom::Report)) : Array(String)
      options.project_names.flat_map do |spec|
        unless spec.projection.param_names?
          raise PayloadFrom::Error.new("a Miner name source reads parameter NAMES: use the param-names projection " \
                                       "(got #{spec.projection.label} in #{spec.label.inspect})")
        end
        store = options.project || raise PayloadFrom::Error.new(
          "payload source #{spec.label.inspect} reads the project's captured data, and this run has no project to read")
        resolved = PayloadFrom.resolve(store, spec, drain_fts: options.project_drain_fts?)
        reports << resolved.report
        resolved.values
      end
    end

    # ADD a `Content-Length` when the seed carries a body and declares none — once, here, so
    # the baseline, the per-location controls and every probe are framed the same way.
    #
    # A request body has no close-delimited form (`Connection: close` delimits a RESPONSE), so
    # an HTTP/1.1 origin handed a body with no length reads a ZERO-LENGTH one (RFC 7230 §3.3.3)
    # and the octets after the blank line are the front of the next request line. Nothing the
    # miner splices into that body can reach the application, and the run cannot tell that from
    # a target with no hidden parameters: measured on a hand-authored `--request` form POST with
    # a `debug` parameter the origin reflects, the mine reported `baseline: stable · 0 found ·
    # 0 errors` and exit 0, while the same seed carrying `Content-Length: 5` found it.
    #
    # This is `Fuzz::Config#update_content_length`'s add-when-missing decision (#905) at
    # the sibling builder that was missed. It is done to the SEED rather than left to
    # `Inject.apply`'s own `add_cl_when_missing` flag — which no surface can set, and which
    # `Baseline`'s plain stability rounds never reach — because the baseline sends `@base`
    # verbatim: framing only the probes would diff a body the origin read against a baseline it
    # did not, and `Baseline#settle` reads that status split as a REFUSED width.
    #
    # ADD-only, never a resync. The two `ContentLength.sync` calls differ EXACTLY when the add
    # path fired (an absent header, a non-empty body, no `Transfer-Encoding`), which is the same
    # predicate `Fuzz::Plan.unframed_body?` asks and the reason the rule is not spelled twice.
    # So a capture whose declared length deliberately disagrees with its body — a CL-desync
    # probe, the reason an operator mines that endpoint at all — comes back byte-identical here;
    # only `Inject.apply`, which changes the body itself, re-declares a length.
    private def self.frame_unframed_body(bytes : Bytes) : Bytes
      framed = Fuzz::ContentLength.sync(bytes, true)
      framed == Fuzz::ContentLength.sync(bytes, false) ? bytes : framed
    end

    # The per-request transform hook's argv (#846), or nil when the run declared no hook. The
    # argv is tokenized HERE so a command that cannot parse is a `PlanError` before the first
    # send rather than a failure on every worker — the same up-front discipline `load_names`
    # follows for a bad wordlist path.
    private def self.resolve_hook_argv(config : Config) : Array(String)?
      spec = config.hook.try(&.presence)
      return nil unless spec
      argv = Gori::ProcessHook.parse_argv(spec)
      if argv.is_a?(String)
        raise PlanError.new(PlanError::Reason::HookArgv,
          "hook command does not parse: #{argv}", argv)
      end
      argv
    end

    # Context for the hook, on top of the operator's inherited environment. `GORI_HOOK` names
    # the seam (the Rewriter/Decoder/Probe hooks each set their own) and `GORI_TARGET` the
    # origin, so one script can tell a mine's probes from a rewrite's bytes.
    private def self.hook_env(origin : Fuzz::Origin) : Hash(String, String)
      {
        "GORI_HOOK"   => "miner",
        "GORI_TARGET" => "#{origin.scheme}://#{origin.host}:#{origin.port}",
      }
    end

    # The explicit target when it has one, else the seeding flow's. Blank counts as absent
    # (an agent that sends `"url": ""` means "use the flow's", not "fail").
    private def self.resolve_origin(options : PlanOptions) : Fuzz::Origin
      raw = options.target.presence || options.default_target.presence
      raise PlanError.new(PlanError::Reason::NoTarget, "no target origin") unless raw
      Fuzz::Origin.new(*Repeater::FlowRequest.dial_target(raw))
    rescue e : Repeater::FlowRequest::DialTargetError
      raise PlanError.new(e.unresolved? ? PlanError::Reason::UnresolvedEnv : PlanError::Reason::BadTarget, e.message.to_s, e.detail)
    end

    # The candidate list, in the order it is TESTED (which is what a `max_requests`-capped run
    # spends its budget on, so it is the likeliest-first order):
    #
    #   1. the explicit `seed_names` (`--name`, MCP `names`) — the operator's own guesses;
    #   2. the names read from the project (`--payload-from '<QL> param-names'`) — vocabulary the
    #      target has already used, ahead of any generic list;
    #   3. the built-in list;
    #   4. the user wordlist (`--wordlist`).
    #
    # De-duplicated with the first sighting keeping its place, so a name the project offers is
    # tested at ITS position and not again where the built-in list has it. The user file is read
    # HERE so a bad path surfaces as a PlanError at build time rather than from inside a worker
    # fiber.
    private def self.load_names(user_wordlist : String?, seeds : Array(String),
                                project : Array(String) = [] of String) : Array(String)
      names = Wordlist.load(user_wordlist)
      front = (seeds + project).reject(&.strip.empty?)
      names = (front + names).uniq unless front.empty?
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
