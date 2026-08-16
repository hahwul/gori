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
      # The template or the target still names an env var that resolves to nothing, so
      # the run would put the token's own characters on the wire (`detail` = the
      # unresolved tokens, prefixed and comma-joined, for surfaces that quote them back).
      UnresolvedEnv
      # `--race`/`race_count` below 2 — a race needs at least two connections in flight
      # together, so 1 is just a send (refused, not silently clamped, so the operator sees why).
      BadRaceCount
    end

    getter reason : Reason
    getter detail : String?

    def initialize(@reason : Reason, message : String, @detail : String? = nil)
      super(message)
    end
  end

  # A `§value¦chain§` marker names a converter this run cannot apply: an unknown token, or a
  # saved chain gori ITSELF registered as unusable (recursive, or past `Library::MAX_TOKENS`).
  # Either way the payload would go out un-transformed, which is the one outcome a marked
  # position must never produce silently.
  #
  # Deliberately NOT a `PlanError`. That enum is the machine-readable FACT behind a sentence
  # each surface writes in its own idiom, naming its own controls (`--mark TOKEN` vs `^A
  # params · ^K word`) — and this refusal has no surface idiom to write. The chain lives in
  # settings.json, all four surfaces resolve it through the same `Decoder.shared_registry`, and
  # the remedy (`gori run decoder list`, or the Decoder tab) is word-for-word the same
  # everywhere. So the builder writes the sentence once and every surface's EXISTING
  # `Gori::Error` path carries it unchanged: `gori run fuzz` aborts with it (`CLI.run`'s
  # `rescue ex : Error`, cli.cr), MCP
  # codes it `INVALID_ARGUMENT` with the message intact (mcp/tools.cr:1644), the Fuzzer tab
  # shows it in place of the run. That also keeps the change inside the fuzz boundary — a new
  # `PlanError::Reason` member breaks the exhaustive `case … in` in six files outside it.
  class ChainError < Gori::Error
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
    # PROVENANCE: this template is a CAPTURED FLOW's stored bytes, not a request the operator
    # typed or edited. Identical in meaning and consequence to `Repeater::PlanOptions#evidence?`,
    # and it exists for the same reason that one does: "send this capture to the fuzzer" is
    # the main consumer of a captured flow, and the draft-time passes the replay path stopped
    # running were still running here. Concretely, with it OFF a capture was
    #
    #   * REFUSED outright when its head carried a `$` nobody typed — OData `$filter`/`$top`,
    #     Mongo `$where`, an `$IFS` shell probe, `$user.name` SSTI — and the refusal's own
    #     remedy ("set the variable") would have SUBSTITUTED a value and swept a different
    #     request; and
    #   * silently un-desynced when its head was bare-LF terminated, because `expand_wire`
    #     re-terminates a head with CRLF. `gori run repeater 3` replays that capture
    #     byte-exact; `gori run fuzz 3` promoted it and reported a clean run.
    #
    # A `--request FILE` / stdin / TUI-editor template keeps the draft behaviour: those bytes
    # ARE a draft, the editor's fresh lines really do end in LF, and a `$KEY` there is a
    # variable reference the operator meant.
    property? evidence : Bool
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
    # The processing pipeline applied to EVERY set — one list, shared by every set rather than
    # declared per set.
    #
    # Set by `gori run fuzz` (`--prefix/--suffix/--encode/--case/--hash/--regex-replace`) and by
    # MCP `fuzz_start{processors}`. NOT by the TUI: `FuzzerView#build_engine` passes none and the
    # Fuzzer tab has never had a processor UI (`Fuzz::Processor` appears nowhere under
    # `src/gori/tui/`). This comment used to claim "all three surfaces share one list", which was
    # false in the commit that wrote it — the same #366 change added the CLI/MCP wiring and
    # touched `tui/fuzzer_view.cr` without wiring it. Recorded rather than quietly widened, per
    # DESIGN.md's preamble; closing it is a TUI feature, not a rewording.
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
    # The `$KEY` table an EVIDENCE template may substitute from, or nil for "none" — the
    # historical evidence behaviour and still the default for every surface that cannot tell
    # a captured token from a typed one (`gori run fuzz --evidence`, MCP).
    #
    # A surface WITH an editor can tell: `FuzzerView` records the names its capture arrived
    # with and passes everything else, so a `$TOKEN` the operator adds to a seeded template
    # substitutes while the capture's own `$filter` stays the origin byte it is. Ignored
    # unless `evidence?` — a draft expands the full table and always has.
    property env_vars : Hash(String, String)?

    def initialize(@template : String = "",
                   *,
                   @evidence : Bool = false,
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
                   @overrides : Gori::HostOverrides? = nil,
                   @env_vars : Hash(String, String)? = nil)
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
    # The `update_content_length` pass will REWRITE a Content-Length the operator authored —
    # i.e. the template's declared CL already disagrees with its own body BEFORE any payload
    # is substituted, which only happens on purpose. Computed here rather than discovered per
    # request so a surface can say it ONCE, up front, and name the flag that turns it off.
    # False when the knob is already off, or when the declared length was correct anyway.
    getter? rewrites_content_length : Bool

    def initialize(@engine : Engine, @generator : Generator, @matcher : Matcher,
                   @config : Config, @origin : Origin, @template : Template,
                   @http2 : Bool, @request_target : String,
                   @mark_matches : Array({String, Int32}), @pool : ConnPool? = nil,
                   @rewrites_content_length : Bool = false)
    end

    # Candidate request count, or nil when unknown / Int64-overflowing. Reads the payload
    # sets (a wordlist is counted + opened here), so a bad path surfaces as `Gori::Error`
    # at this call, not from inside a worker fiber.
    def total : Int64?
      @engine.total
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      # ONE `Env.expand_wire` over the template, before anything reads it.
      #
      # There USED to be a refusal in front of it, when a token in the HEAD resolved to
      # nothing (#519). It is gone: a `$NAME` with no value is a literal string on the wire
      # (see `Env::Escape`), and this check refused a GraphQL query string, a Mongo `$where`
      # filter and a JSON Schema `$ref` in a header — all of them the operator's test case.
      # `$$` is the escape for a name that DOES resolve.
      #
      # `expand_wire`, not `expand`: this was the ONE plan builder of the three that skipped
      # the head's LF→CRLF promotion (`miner/plan.cr` and `sequencer/plan.cr` have always
      # used it), and the TUI editor joins lines with LF. So every Fuzzer run launched from
      # the TUI put a BARE-LF request head on the wire while the Repeater, on the same flow
      # in the same session, sent CRLF. A bare LF is itself a front-end/back-end desync
      # primitive, so it does not merely look untidy — it confounds every result the sweep
      # produces. The body is left byte-exact either way; `expand_wire` only touches the head.
      #
      # BOTH steps are skipped for EVIDENCE (`PlanOptions#evidence?`): a captured head's `$`
      # was not typed by anyone, and its terminators are already exact wire bytes. The
      # marking, template parse and payload splice below are unchanged either way — a
      # position is a position whether the operator marked it in an editor or `--auto`
      # found it in a capture.
      #
      # `env_vars` narrows the first step rather than cancelling it: a surface that knows
      # WHICH names the capture brought (the TUI template editor) hands over the rest, so an
      # operator-typed `$TOKEN` in a seeded template expands and the capture's `$filter` does
      # not. nil — every other evidence caller — keeps the blanket skip.
      text =
        if options.evidence?
          (vars = options.env_vars) ? String.new(Env.expand_wire(options.template, vars)) : options.template
        else
          String.new(Env.expand_wire(options.template))
        end
      text = Template.auto_mark(text) if options.auto_mark?
      mark_matches = options.marks.map do |tok|
        text, count = wrap_token(text, tok)
        {tok, count}
      end
      template = Template.parse(text, options.http2?)
      # A race group is N copies of ONE request, not a payload-substitution sweep — see
      # `Config#race_count` — so it has no use for §…§ positions or payload sets at all, and
      # both guards below (and NoPayloads, one screen down) are skipped when it is set.
      race_count = validate_race_count(options.config.race_count)
      raise PlanError.new(PlanError::Reason::NoPositions, "the template has no §…§ positions") if template.position_count == 0 && !race_count
      # The twin of `refuse_unresolved`, one line down and for the same reason: a `¦chain` this
      # run cannot apply leaves the position's payload UNTRANSFORMED on the wire. See
      # `refuse_unusable_chains`.
      refuse_unusable_chains(template, Decoder.shared_registry)

      # The string the Layer-1 scope check matches on, taken from the template's BASELINE
      # rendering (every position = its own default) rather than the raw text. The TUI's
      # template arrives ALREADY marked, so reading the raw first line would hand the gate
      # `/find?term=§VAL§` there while handing it `/find?term=VAL` from the CLI and MCP,
      # whose text is marked by the builder. Rendering the defaults back out is marker-free
      # on all three and byte-identical to what those two used to pass.
      request_target = Gori::Outbound.request_target(template.render(template.default_payloads))

      origin = resolve_origin(options)

      sets = options.sources.map { |src| PayloadSet.new(src, options.processors) }
      raise PlanError.new(PlanError::Reason::NoPayloads, "no payload sets") if sets.empty? && !race_count

      config = options.config
      matcher = options.matcher
      # Auto-calibration is a Config knob the Matcher enforces, so the two must agree — it
      # was previously synced by hand on two surfaces out of three.
      matcher.auto_calibrate = config.auto_calibrate?
      # Sniper / BatteringRam take ONE shared set; Pitchfork / ClusterBomb take one per
      # position (see Generator's set contract). Empty for a race run — `Generator#each`/
      # `#total` (the only readers of `@sets`) are never called on that path; `Engine#run_race`
      # calls `Generator#baseline_request` instead, which does not touch `@sets` either.
      gen_sets = sets.empty? ? [] of PayloadSet : (config.mode.per_position? ? sets : [sets.first])
      # The shared decoder registry applies each position's inline `¦chain` at render time.
      # Wired here so a new surface cannot forget it and silently send un-transformed payloads.
      generator = Generator.new(template, gen_sets, config, registry: Decoder.shared_registry)
      # gRPC framing, decided ONCE off the seed rendering: a template that declares
      # `content-type: application/grpc` and whose body frames cleanly has a 5-byte length
      # prefix that a payload of a different length will INVALIDATE. gori keeps the operator's
      # bytes either way (P7), but Content-Length gets resynced-and-announced while this
      # declaration got neither — so a sweep in which two of three requests were malformed at
      # the gRPC layer reported `3 sent · 0 errors`. From here the Matcher counts them and the
      # surfaces name it once. A seed that was ALREADY mis-framed is the operator's own parser
      # test and switches this off, because there is nothing left to break.
      matcher.grpc_template = GrpcVerdict.framed_template?(generator.baseline_raw)
      # One parked connection per worker fiber is the ceiling that can ever be checked out
      # at once, so the pool is sized to the (clamped) concurrency the engine will run at.
      #
      # `evidence:` carries the SAME provenance decision the template branch above took, one
      # stage further — to the send seam, where session bindings resolve (`Sender#evidence?`).
      # Skipping `expand_wire` at plan time and then expanding `$id` per send is the shape
      # this whole axis is made of: the run's own `--mark`/`--auto` payload spans protected
      # the operator's payloads while the CAPTURED body around them was still substituted.
      # It reaches all three of the engine's send sites at once — the sweep, the redirect
      # hops, and `calibrate_baseline`, whose nonces are safe but whose CARRIER is this same
      # template rendered with them.
      sender = Sender.new(origin, outbound, http2: options.http2?, verify: options.verify?,
        sni: options.sni, timeout: config.timeout, overrides: options.overrides,
        keep_alive: config.keep_alive?,
        idle_conns: config.concurrency.clamp(1, Engine::MAX_CONCURRENCY),
        evidence: options.evidence?)
      new(engine: Engine.new(generator, matcher, sender, config), generator: generator,
        matcher: matcher, config: config, origin: origin, template: template,
        http2: options.http2?, request_target: request_target, mark_matches: mark_matches,
        pool: sender.pool,
        rewrites_content_length: config.update_content_length? &&
                                 generator.baseline_request != generator.baseline_raw)
    end

    # The explicit target when it has one, else the seeding flow's. Blank counts as absent
    # (an agent that sends `"url": ""` means "use the flow's", not "fail").
    private def self.resolve_origin(options : PlanOptions) : Origin
      raw = options.target.presence || options.default_target.presence
      raise PlanError.new(PlanError::Reason::NoTarget, "no target origin") unless raw
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
      refuse_unresolved(Env.unresolved(raw, deferred: nil))
      url = Env.expand(raw)
      scheme, host, port = Repeater::FlowRequest.parse_target(url)
      raise PlanError.new(PlanError::Reason::BadTarget, "could not parse a host from #{url.inspect}", url) if host.empty?
      Origin.new(scheme, host, port)
    end

    # Race mode needs at least two connections in flight together (one is just a send).
    # Refused here — not silently clamped — so the operator sees why a `--race=1` did nothing.
    # Returns the count back so the caller can gate the position/payload guards on it in one go.
    #
    # A `PlanError`, not a bare `Gori::Error`: this is a plan-INPUT refusal, the same family as
    # `NoPositions`/`NoPayloads` above, so it rides the `rescue Fuzz::PlanError` every surface
    # already wraps `Plan.build` in (the CLI closes `outbound` and prefixes `gori run fuzz:`
    # there; a raw `Gori::Error` slipped past that rescue and leaked to the top-level handler).
    private def self.validate_race_count(race_count : Int32?) : Int32?
      if race_count && race_count < 2
        raise PlanError.new(PlanError::Reason::BadRaceCount,
          "race_count must be at least 2 (a race needs at least two connections in " \
          "flight together, or it is just a send)")
      end
      race_count
    end

    # Refuse a run whose TARGET carries a token that resolves to nothing.
    #
    # The template half of this is gone — a `$NAME` with no value is a literal string on the
    # wire now, everywhere. A DIAL TUPLE is the exception the note at the call site argues:
    # `$` is not a legal byte in a hostname, so there is no operator test case to protect,
    # and a literal `$SESSION` there makes `Outbound.scope_url` ask about `https://$SESSION/a`
    # — a URL no rule can match — so the run comes back refused as OUT-OF-SCOPE, naming a
    # gate that was never the problem. Refusing here names the real one.
    private def self.refuse_unresolved(names : Array(String)) : Nil
      return if names.empty?
      detail = Env.token_list(names)
      raise PlanError.new(PlanError::Reason::UnresolvedEnv,
        "unresolved env #{detail}", detail)
    end

    # Refuse a run whose `§value¦chain§` markers name a converter the registry cannot apply.
    #
    # `Template#apply_chains` returns the payload VERBATIM when its chain does not run, with a
    # comment arguing that a streaming fuzz run has nowhere to surface a per-position error.
    # That was written when the only way to reach it was a typo. The saved-chain library added
    # a class that is not a typo: a name the operator saved, that the `^Y` autocomplete offers
    # and `gori run decoder list` prints as an ordinary converter, and that the library
    # registered as an always-raising step precisely so the failure would be VISIBLE — and this
    # path swallowed the raise. Five marked positions, three of them naming such a chain, put
    # the raw payload in the query string under `1 sent · 0 errors`, `"error":null`,
    # `"matched":true`. `gori run decoder` names the identical refusal off the identical
    # registry one screen away.
    #
    # So it is refused HERE, beside `refuse_unresolved`, whose comment makes the same argument
    # for `$KEY`: this builder is the surface-independent chokepoint every fuzz surface goes
    # through, and a refusal before the first dial is the only report a sweep of ten thousand
    # requests can act on.
    #
    # Two kinds, both answerable from the registry with no side effect:
    #   * the token resolves to nothing         → unknown converter
    #   * it resolves to an UNUSABLE saved chain → `Converter#unusable` carries the reason
    # The second is why this is not a build-time dry run over each position's default: a dry
    # run cannot tell "this chain is broken" from "this chain is fine and the DEFAULT value
    # isn't valid input for it" (`base64-decode` over a `§admin§` default raises, and refusing
    # that run would block a legitimate sweep). Asking whether the converter can run at all
    # answers the first question and leaves the second — genuinely per-payload — alone.
    private def self.refuse_unusable_chains(template : Template, registry : Decoder::Registry) : Nil
      bad = [] of String
      template.positions.each do |pos|
        next if pos.chain.empty?
        Decoder.parse_spec(pos.chain).each do |tok|
          conv = registry[tok]?
          if conv.nil?
            bad << "#{tok}: unknown converter"
          elsif reason = conv.unusable
            bad << reason # already prefixed with the chain's own name
          end
        end
      end
      return if bad.empty?
      raise ChainError.new("§…§ chain cannot run: #{bad.uniq.join("; ")}. " \
                           "The payload would go out untransformed — fix or remove the chain " \
                           "(list the converters with `gori run decoder list`)")
    end

    # Wrap every non-overlapping occurrence of a literal `--mark` / MCP `marks` token in
    # `§…§`, returning {new text, occurrence count} — one pass, so the count a surface warns
    # with is by construction the number of positions that were actually made.
    #
    # BYTE SAFETY — read before reaching for `String#gsub` here. `text` can be a CAPTURE's
    # own bytes (`--flow`, MCP `flow_id`), which may legitimately not be valid UTF-8: a
    # protobuf/gRPC frame, a gzip'd POST, a latin-1 form field. `String#gsub(String, String)`
    # delegates to the CHAR overload as soon as the needle is ONE BYTE long, and Crystal's
    # char iteration substitutes the three bytes of U+FFFD for every byte that is not valid
    # UTF-8 — so the LENGTH of the operator's token silently decided whether the request
    # survived. Measured through `gori run fuzz --request` against a recording origin, on a
    # body `v=1&bin=<ff fe 01 02>&w=2`:
    #
    #   --mark v   →  50 3d 31 26 62 69 6e 3d ef bf bd ef bf bd 01 02 26 77 3d 32   CL 16 → 20
    #   --mark v=  →  50 31 26 62 69 6e 3d ff fe 01 02 26 77 3d 32                  intact
    #
    # …and on the corrupt run gori then printed "the template's Content-Length disagrees with
    # its own body", about a disagreement it had just manufactured. This is the headless twin
    # of the ^K marking defect; the rule is the same one written down under
    # `Fuzz::Template.split_raw_interior` — bytes in, bytes out, never a char walk.
    #
    # Returns `text` ITSELF when the token does not occur, so the common case is
    # byte-identical and allocation-free.
    private def self.wrap_token(text : String, token : String) : {String, Int32}
      return {text, 0} if token.empty?
      hay = text.to_slice
      needle = token.to_slice
      return {text, 0} if needle.size > hay.size
      marker = Template::MARKER_BYTES
      io = IO::Memory.new(hay.size + 8)
      count = 0
      i = 0
      last = hay.size - needle.size
      while i <= last
        if hay[i, needle.size] == needle
          io.write(marker)
          io.write(needle)
          io.write(marker)
          count += 1
          i += needle.size
        else
          io.write_byte(hay[i])
          i += 1
        end
      end
      return {text, 0} if count.zero?
      io.write(hay[i..]) if i < hay.size
      {String.new(io.to_slice), count}
    end
  end
end
