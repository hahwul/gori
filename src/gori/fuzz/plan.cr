require "../decoder"
require "../env"
require "../host_overrides"
require "../outbound"
require "../repeater/flow_request"
require "./engine"
require "./generator"
require "./grpc_fields"
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

  # A WebSocket run asked for something only an HTTP sweep has, or handed frames to a template
  # that has no handshake to ride them.
  #
  # Deliberately NOT a `PlanError::Reason`. That enum is the machine-readable fact behind a
  # sentence each surface writes in its own idiom, and AGENTS.md lists adding a member to it as
  # a trap: three surfaces `case … in` it exhaustively, and one of them is the TUI Fuzzer tab,
  # which has no WebSocket path at all and so can never produce this refusal — a new member
  # would drag it into the diff to handle a case it cannot reach. Same shape and the same
  # argument as `ChainError` directly above: these refusals have no surface idiom to write
  # (`--race is HTTP-only` reads identically on the CLI and on MCP), so the builder writes the
  # sentence once and every surface's existing `Gori::Error` path carries it unchanged.
  class WsError < Gori::Error
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
    # Percent-encode a payload spliced into a QUERY-STRING or FORM-BODY position (the
    # default). `false` is the operator's escape hatch — `gori run fuzz --no-encode`, MCP
    # `no_encode:true` — for a run whose payload IS the raw byte. See `Fuzz::AutoEncode`
    # for what the default covers, what it deliberately leaves raw, and why an explicit
    # `processors` pipeline or a per-position `¦chain` already turns it off on its own.
    property? auto_encode : Bool
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
    # Schema-known gRPC fields to sweep, as the operator NAMED them: `role`, `profile.age`,
    # `tags[1]`, a bare field number, each optionally carrying `¦chain`. Resolved against the
    # seed message by `Fuzz::GrpcFieldTemplate.build`, which is also where every refusal lives.
    #
    # A NAME rather than a byte range, because the wire encoding of a value is not a thing an
    # operator can usefully wrap `§…§` around: marking an `int32` means marking the octets of a
    # varint, and `-3` is a different set of octets as `int32`, `sint32`, `bool` or an enum.
    # These positions follow the template's own `§…§` positions in the run's index space, so
    # `--mode`, the payload sets and `--mark` all keep their meaning (see `GrpcFieldTemplate`).
    property grpc_fields : Array(String)
    # The outbound WebSocket frame script, or nil for an ordinary HTTP sweep.
    #
    # NON-NIL AND NON-EMPTY is the "this is a WebSocket run" bit — there is no separate boolean,
    # so the two cannot disagree. An EMPTY array folds to an ordinary HTTP sweep rather than to
    # a handshake-only framed run: see `build_ws_script`, which is where that is decided for
    # every surface at once.
    #
    # `template` still carries the handshake, which is why nothing else here needed a WS
    # spelling: the handshake is part 0 of the run's position space (see `Fuzz::WsScript`), so
    # `auto_mark`, `marks`, `sources`, `processors` and `auto_encode` all keep their meaning.
    property ws_messages : Array(WsMessageSource)?

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
                   @auto_encode : Bool = true,
                   @config : Config = Config.new,
                   @matcher : Matcher = Matcher.new,
                   @verify : Bool = true,
                   @sni : String? = nil,
                   @overrides : Gori::HostOverrides? = nil,
                   @env_vars : Hash(String, String)? = nil,
                   @grpc_fields : Array(String) = [] of String,
                   @ws_messages : Array(WsMessageSource)? = nil)
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
    # The `--mark` / MCP `marks` tokens that DID occur but made no position, because every
    # occurrence was already inside a `§…§` region — or flush against one — that `--auto` or an
    # earlier `--mark` had made. `wrap_token` must skip those (see the harm it enumerates) but
    # a skip is indistinguishable from `{token, 0}` for a token that is simply not in the
    # text, and neither the CLI's `occ > 1` note nor the `NoPositions` refusal (auto_mark's
    # positions exist) says anything. So the operator's explicit mark silently did nothing.
    # Reported here for the same reason `rewrites_content_length?` is: a fact about the run
    # that only the builder can see, said ONCE, up front, by whichever surface asked.
    getter shadowed_marks : Array(String)
    # Which positions this run percent-encodes for, and the encode itself. Exposed so a
    # surface can SAY so (the CLI notes it once, up front, and names `--no-encode`) and so
    # the TUI's request RECONSTRUCTION can reproduce the bytes the generator produced —
    # `AutoEncode.none` when an explicit `--encode`/`processors`, `--no-encode`, or a
    # template with no query/form position turned it off.
    getter auto_encode : AutoEncode
    # The `update_content_length` pass will REWRITE a Content-Length the operator authored —
    # i.e. the template's declared CL already disagrees with its own body BEFORE any payload
    # is substituted, which only happens on purpose. Computed here rather than discovered per
    # request so a surface can say it ONCE, up front, and name the flag that turns it off.
    # False when the knob is already off, or when the declared length was correct anyway.
    getter? rewrites_content_length : Bool
    # The marked WebSocket script, or nil for an ordinary HTTP sweep. `template` above stays the
    # HANDSHAKE template in either case — it is part 0 of the script's position space — so a
    # surface reading `plan.template` keeps its type and its meaning.
    getter ws_script : WsScript?
    # Config knobs this run cannot honour because it is a WebSocket sweep.
    #
    # SYMBOLS, not sentences: each surface names its own control (`--follow-redirects` on the
    # CLI, `follow_redirects` on MCP), which is the same division of labour `PlanError::Reason`
    # exists for. A fact about the run that only the builder can see, said ONCE, up front — the
    # contract `shadowed_marks` and `rewrites_content_length?` already have.
    #
    # These are IGNORED, not refused, and the distinction is deliberate. `--follow-redirects`
    # names a hop a 101-or-error exchange cannot produce, `--timeout` names a per-operation
    # bound `WsEngine` does not take (it paces on `--idle-ms`), and `--ac` would open a full
    # session per calibration sample. All three are inert rather than wrong, and refusing a
    # whole run over an inert flag is hostile — while staying silent about it is how an operator
    # comes to believe a sweep followed redirects it never followed.
    getter ws_ignored_knobs : Array(Symbol)
    # The resolved schema-known gRPC field positions, or nil when the run named none.
    # `template` above stays the request's own `Template` in either case — it is part 0 of this
    # composite's position space — so a surface reading `plan.template` keeps its type and its
    # meaning, exactly as it does for `ws_script`.
    getter grpc_fields : GrpcFieldTemplate?

    def initialize(@engine : Engine, @generator : Generator, @matcher : Matcher,
                   @config : Config, @origin : Origin, @template : Template,
                   @http2 : Bool, @request_target : String,
                   @mark_matches : Array({String, Int32}), @pool : ConnPool? = nil,
                   @rewrites_content_length : Bool = false,
                   @shadowed_marks : Array(String) = [] of String,
                   @auto_encode : AutoEncode = AutoEncode.none,
                   @ws_script : WsScript? = nil,
                   @ws_ignored_knobs : Array(Symbol) = [] of Symbol,
                   @grpc_fields : GrpcFieldTemplate? = nil)
    end

    # Does this run sweep a WebSocket script rather than an HTTP request?
    def websocket? : Bool
      !@ws_script.nil?
    end

    # The run's TOTAL positions, across every part. `template.position_count` is the
    # handshake's alone on a WS run, and the request's `§…§` alone on a gRPC field run, so a
    # surface that reports "N positions" must ask this.
    def position_count : Int32
      if ws = @ws_script
        ws.position_count
      elsif grpc = @grpc_fields
        grpc.position_count
      else
        @template.position_count
      end
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
      # The FRAME payloads, expanded on the same provenance axis as the head one line up: a
      # frame the operator typed (`--message`, MCP `messages`) resolves its `$KEY`, a CAPTURED
      # frame does not. `Env.expand`, not `expand_wire` — a frame has no head, so there is no
      # LF→CRLF promotion to make and nothing in it is a message boundary.
      ws_texts = options.ws_messages.try(&.map { |m| m.evidence ? m.payload : Env.expand(m.payload) })

      if options.auto_mark?
        text = Template.auto_mark(text)
        # A frame gets the BODY-shaped marker pass (`auto_mark_payload`): it has no request line
        # and no `Cookie:` header, so the head half of `auto_mark` has nothing to mark there.
        # The OPCODE rides along — that pass marks TEXT frames only, because its urlencoded
        # sniff would otherwise carve positions out of a binary payload that happens to carry
        # an `=` (see there).
        if (sources = options.ws_messages) && (texts = ws_texts)
          ws_texts = texts.map_with_index { |t, i| Template.auto_mark_payload(t, sources[i].opcode) }
        end
      end

      shadowed_marks = [] of String
      mark_matches = options.marks.map do |tok|
        text, count, shadowed = wrap_token(text, tok)
        # Across EVERY part. A `--mark` aimed at a value that lives in a frame would otherwise
        # report `{token, 0}` and mark nothing, while the operator watched the flag they typed
        # do nothing to the payload they typed it for. The counts sum.
        #
        # `shadowed` ORs, and `&&` here was a bug. `wrap_token` returns `shadowed == false` for
        # a part that does not CONTAIN the token at all, so ANDing made a token shadowed only if
        # every part contained it and had it marked already — which for a two-part script is
        # almost never. Since `shadowed_marks` is reported only when the total `count` is also
        # zero (i.e. the mark added no position ANYWHERE), OR is the right fold: at least one
        # part had occurrences that were all already inside a `§…§`, and no part made a new
        # position. With `&&` the operator got no note at all that their `--mark` did nothing.
        if texts = ws_texts
          texts.each_with_index do |t, i|
            t2, c2, sh2 = wrap_token(t, tok)
            texts[i] = t2
            count += c2
            shadowed ||= sh2
          end
        end
        # It occurred, and every occurrence was already marked — see `shadowed_marks`. A token
        # that DID make positions is not listed: it landed, and the count says so.
        shadowed_marks << tok if shadowed && count.zero?
        {tok, count}
      end
      template = Template.parse(text, options.http2?)

      # The template's BASELINE rendering — every position spliced with its own default — and
      # the byte span each default occupies in it. Rendered ONCE here because three things
      # below read it and they must not disagree: the Layer-1 scope gate matches on its request
      # line, the gRPC field resolver reads the message its body carries, and that resolver
      # refuses a `§…§` position that lands in the same body.
      #
      # Rendering the defaults back out (rather than reading the raw marked text) is what makes
      # the three surfaces agree: the TUI's template arrives ALREADY marked, so the raw first
      # line would be `/find?term=§VAL§` there and `/find?term=VAL` from the CLI and MCP.
      baseline, baseline_spans = template.render_spans(template.default_payloads)
      request_target = Gori::Outbound.request_target(baseline)

      # The WebSocket script, when this is a WS run. Built here — after marking, before every
      # guard below — because from this point on `marked` is what the whole builder reads, and
      # the two shapes answer the same protocol (see `Fuzz::WsScript`).
      ws_script = build_ws_script(options, template, ws_texts)
      # …and the gRPC field positions, when the run named any. Same seam and the same argument:
      # a composite that concatenates its parts' position lists into one vector (see
      # `Fuzz::GrpcFieldTemplate`), so `marked` stays the one thing the rest of the builder reads.
      grpc_fields = build_grpc_fields(options, template, baseline, baseline_spans,
        request_target, ws_script)
      marked = ws_script || grpc_fields || template
      ws_ignored = ws_script ? ws_ignored_knobs(options.config) : [] of Symbol
      # A race group is N copies of ONE request, not a payload-substitution sweep — see
      # `Config#race_count` — so it has no use for §…§ positions or payload sets at all, and
      # both guards below (and NoPayloads, one screen down) are skipped when it is set.
      race_count = validate_race_count(options.config.race_count)
      raise PlanError.new(PlanError::Reason::NoPositions, "the template has no §…§ positions") if marked.position_count == 0 && !race_count
      # The twin of `refuse_unresolved`, one line down and for the same reason: a `¦chain` this
      # run cannot apply leaves the position's payload UNTRANSFORMED on the wire. See
      # `refuse_unusable_chains`.
      refuse_unusable_chains(marked.positions, Decoder.shared_registry)

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
      # A payload a field's DECLARATION cannot hold, refused before the first dial — `abc` into
      # an `int32`, an enum name the schema does not carry. Beside `refuse_unusable_chains`
      # above and for the same reason its comment gives, over the sets the generator will
      # actually draw from (`gen_sets`, mapped exactly as `Generator#set_for` maps them).
      refuse_unencodable_fields(grpc_fields, gen_sets, template.position_count)
      # Percent-encoding for the QUERY-STRING / FORM-BODY positions, decided ONCE off the
      # template's structure. Here rather than in each surface for the reason this whole
      # builder exists: `--auto`, MCP `auto:true` and the TUI's `^A params` mark the same
      # positions, so they have to encode for the same ones — and the TUI, which has no
      # processor UI at all, could not have opted in by itself.
      auto_encode = AutoEncode.build(template, options.processors, options.auto_encode?)
      # The shared decoder registry applies each position's inline `¦chain` at render time.
      # Wired here so a new surface cannot forget it and silently send un-transformed payloads.
      generator = Generator.new(marked, gen_sets, config, registry: Decoder.shared_registry,
        auto_encode: auto_encode)
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
        # Forced OFF for a WebSocket run, silently. One variation is one session on its own
        # socket, which `WsEngine` closes in its own `ensure` — there is nothing for the pool
        # to park. Silently because `keep_alive` DEFAULTS true, so reporting it as ignored
        # would fire on every WS run for a choice the operator never made; `Plan#pool` is then
        # nil and the surfaces' handshake-count line naturally prints nothing.
        keep_alive: config.keep_alive? && ws_script.nil?,
        idle_conns: config.concurrency.clamp(1, Engine::MAX_CONCURRENCY),
        evidence: options.evidence?,
        ws_idle: config.ws_idle, ws_keep_key: config.ws_keep_key?)
      new(engine: Engine.new(generator, matcher, sender, config), generator: generator,
        matcher: matcher, config: config, origin: origin, template: template,
        http2: options.http2?, request_target: request_target, mark_matches: mark_matches,
        pool: sender.pool,
        rewrites_content_length: config.update_content_length? &&
                                 generator.baseline_request != generator.baseline_raw,
        shadowed_marks: shadowed_marks, auto_encode: auto_encode,
        ws_script: ws_script, ws_ignored_knobs: ws_ignored, grpc_fields: grpc_fields)
    end

    # A payload a field's DECLARATION cannot hold, refused before the first dial — the nil-guard
    # kept out of `build` so a run with no field position adds no branch to it.
    private def self.refuse_unencodable_fields(grpc_fields : GrpcFieldTemplate?,
                                               sets : Array(PayloadSet), base_count : Int32) : Nil
      return unless grpc_fields
      grpc_fields.refuse_unencodable(sets, base_count, Decoder.shared_registry)
    end

    # The schema-known gRPC field positions this run sweeps, or nil when it named none — in
    # which case every existing sweep keeps the plain `Template` path, byte for byte.
    #
    # The two combinations refused here are genuine incompatibilities rather than inert flags
    # (the inert ones are reported through `ws_ignored_knobs`), and both are refused HERE rather
    # than inside `GrpcFieldTemplate.build` because they are facts about the RUN, not about the
    # message: the resolver would otherwise have to be handed a Config to ask about them.
    private def self.build_grpc_fields(options : PlanOptions, template : Template,
                                       baseline : Bytes, baseline_spans : Array({Int32, Int32}),
                                       request_target : String,
                                       ws_script : WsScript?) : GrpcFieldTemplate?
      return nil if options.grpc_fields.empty?
      if ws_script
        raise GrpcFieldError.new(
          "a gRPC field position and a WebSocket script cannot combine: a field position names " \
          "a declaration in a unary gRPC message, and a WebSocket exchange carries frames. " \
          "Drop the frames to sweep the handshake's request as HTTP")
      end
      if options.config.race_count
        raise GrpcFieldError.new(
          "a gRPC field position and --race cannot combine: a race group is N byte-identical " \
          "copies of ONE request released together, which bypasses payload substitution " \
          "entirely — there is nothing for a field position to substitute into")
      end
      GrpcFieldTemplate.build(template, baseline, baseline_spans, options.grpc_fields, request_target)
    end

    # The marked WebSocket script, or nil when this is an ordinary HTTP sweep.
    #
    # `ws_messages` non-nil IS the "this is a WebSocket run" bit — see `PlanOptions#ws_messages`
    # — so the only question left here is whether the run is COHERENT, and there is exactly one
    # way it can fail to be: frames with no handshake to ride. `WsEngine.upgrade_request?` is
    # the single source of truth for "is this a WebSocket gori can re-establish" (`ws_engine.cr`
    # says so), and it is asked of the MARKED text rather than the raw options, so a `--mark`
    # that landed inside `Upgrade: websocket` is judged on the head that will actually be sent.
    #
    # Every surface also refuses this before `Plan.build`, in its own idiom and before anything
    # dials. This is the backstop, not the report.
    private def self.build_ws_script(options : PlanOptions, handshake : Template,
                                     texts : Array(String)?) : WsScript?
      sources = options.ws_messages
      return nil unless sources && texts
      # NO FRAMES = an ordinary HTTP sweep, decided HERE so every surface folds the same way.
      # A handshake-only script is exactly what an HTTP sweep of the same bytes already is, and
      # taking the framed path for it costs a real socket and a real handshake per payload to
      # send nothing — then waits out `WsEngine`'s no-frames branch (HANDSHAKE_TIMEOUT, 15 s)
      # instead of the milliseconds the HTTP sweep takes. Reachable without anyone asking for
      # it: a captured socket the client never wrote to, or one whose only `out` rows were
      # gori's own `[gori]` advisories, seeds an EMPTY list — and a bare `Array` is truthy.
      return nil if sources.empty?
      # `Proxy::WS.upgrade_request?`, not `WsEngine`'s delegate: that predicate's documented
      # home is the codec, and `WsEngine.upgrade_request?` is where the REPEATER asks it.
      # Same bytes, same answer, one home.
      unless Gori::Proxy::WS.upgrade_request?(String.new(handshake.render(handshake.default_payloads)))
        raise WsError.new("#{sources.size} WebSocket frame#{sources.size == 1 ? "" : "s"} were given, " \
                          "but this template declares no `Upgrade: websocket` handshake for them to ride. " \
                          "Seed from a WebSocket flow or repeater session, or drop the frames to sweep it as HTTP")
      end
      # RFC 8441 extended CONNECT is a real WebSocket that this path cannot re-establish:
      # `WsEngine` writes an h1 upgrade and accepts nothing but a 101. Refused rather than
      # degraded, because degrading would sweep the CONNECT as an ordinary h2 request and
      # report rows about an exchange that carried no frames.
      if options.http2?
        raise WsError.new("--http2 and a WebSocket script cannot combine: gori re-establishes a " \
                          "WebSocket with an HTTP/1.1 upgrade handshake and accepts nothing but a 101 " \
                          "(RFC 8441 extended CONNECT has no send path). Sweep it over HTTP/1.1, or drop " \
                          "the frames to sweep the handshake itself as an h2 request")
      end
      if options.config.race_count
        raise WsError.new("--race and a WebSocket script cannot combine: a race group is N byte-identical " \
                          "copies of ONE request released together, which bypasses payload substitution " \
                          "entirely and has no framed-exchange form. Drop the frames to race the handshake")
      end
      frames = sources.map_with_index do |m, i|
        # `http2: false` per part, always: a frame is not an HTTP message, and the flag only
        # ever reaches `Template#http2?`, which nothing on this path reads.
        FrameTemplate.new(Template.parse(texts[i], false), m.opcode, m.shape, m.evidence)
      end
      WsScript.build(handshake, frames)
    end

    # Knobs a WebSocket run cannot honour — see `Plan#ws_ignored_knobs` for why these are
    # reported rather than refused.
    private def self.ws_ignored_knobs(config : Config) : Array(Symbol)
      out = [] of Symbol
      out << :follow_redirects if config.follow_redirects?
      out << :timeout if config.timeout
      out << :auto_calibrate if config.auto_calibrate?
      out
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
    private def self.refuse_unusable_chains(positions : Array(Template::Position),
                                            registry : Decoder::Registry) : Nil
      bad = [] of String
      positions.each do |pos|
        next if pos.chain.empty?
        Decoder.parse_spec(pos.chain).each do |tok|
          # An `exec:` step resolves to no converter by construction (#818). What CAN be asked
          # of it before the first dial is whether its argv tokenizes; whether the command
          # exists is a run-time answer, and one that is allowed to change between now and the
          # send. Asking the registry about it would report "unknown converter" for a chain
          # that is perfectly well formed.
          if Decoder.exec_step?(tok)
            if reason = Decoder.exec_step_error(tok)
              bad << reason
            end
            next
          end
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
    # `§…§` that does not touch an ALREADY-marked `§…§` region, returning {new text, occurrence
    # count, was any occurrence SKIPPED for that} — one pass, so the count a surface warns with
    # is the number of occurrences this call WRAPPED, and the skip is reported rather than
    # folded into the same `0` a missing token gets (`Plan#shadowed_marks`).
    #
    # That count is the number of positions made except for ADJACENT occurrences, where the
    # pass's OWN closing marker abuts the next opener: `--mark ab` over `?q=abab` splices
    # `§ab§§ab§`, and `parse` folds that into the single position `ab§ab` — the same `§§` seam
    # the skip below is about, from the other direction. Pre-existing and left alone here (the
    # span list is empty for that text, so the skip never runs): closing it turns a corrupt
    # template into a SILENT partial landing, because a token that wrapped one of its two
    # occurrences is reported by neither `shadowed_marks` (count is not 0) nor the CLI's
    # `occ > 1` note — i.e. it would trade this defect for the silence `shadowed_marks` exists
    # to end.
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
    private def self.wrap_token(text : String, token : String) : {String, Int32, Bool}
      return {text, 0, false} if token.empty?
      hay = text.to_slice
      needle = token.to_slice
      return {text, 0, false} if needle.size > hay.size
      marker = Template::MARKER_BYTES
      # The already-marked regions of THIS text. `auto_mark` runs before the marks, and each
      # mark rewrites the text the next one sees, so an occurrence can already be inside a
      # `§…§` pair — wrapping it again makes `§§`, which `Template.parse` reads as the
      # ESCAPED-LITERAL form: the position the operator named silently disappears from the
      # sweep and a literal `§` (0xC2 0xA7) it never typed goes out on the wire. Spans are
      # re-derived per call for that reason, and by BYTE offset because the subject may be a
      # capture's non-UTF-8 bytes (see the note above).
      spans = Template.marked_byte_spans(hay)
      io = IO::Memory.new(hay.size + 8)
      count = 0
      shadowed = false
      i = 0
      # ONE advancing cursor into `spans`, not a scan of all of them per byte (P6): both `i`
      # and the spans are monotonic, so a span that ends BEFORE `i` can never touch a later
      # window either, and the first span left is then the only candidate. The `spans.none?`
      # this replaces ran at every byte offset, i.e. O(bytes × spans) — a 512 KiB `--flow`
      # body with 40 `--auto` positions and 5 marks is ~100M comparisons before the first dial.
      si = 0
      last = hay.size - needle.size
      while i <= last
        if hay[i, needle.size] == needle
          while si < spans.size && spans[si][1] < i
            si += 1
          end
          # TOUCHING, not just overlapping, and not containment. A run straddling a marker
          # boundary would be wrapped into structurally corrupt text — and so would one merely
          # FLUSH against a marker, because `parse` applies the `§§` escape inside an interior
          # too: on `?a=§x§b`, `--mark b` splices `§x§§b§`, which comes back as the SINGLE
          # position `x§b`. The operator's `b` is swallowed (the sweep sends `?a=P`, not
          # `?a=Pb`) and a `§` nobody typed goes out on the wire — the same two harms this
          # skip exists to prevent. One byte of separation is enough: `§x§Z§b§` is two
          # positions. (The advance above is therefore `<`, not `<=`: a span ending AT `i`
          # still touches an occurrence starting there.)
          if si < spans.size && i + needle.size >= spans[si][0]
            shadowed = true
          else
            io.write(marker)
            io.write(needle)
            io.write(marker)
            count += 1
            i += needle.size
            next
          end
        end
        io.write_byte(hay[i])
        i += 1
      end
      return {text, 0, shadowed} if count.zero?
      io.write(hay[i..]) if i < hay.size
      {String.new(io.to_slice), count, shadowed}
    end
  end
end
