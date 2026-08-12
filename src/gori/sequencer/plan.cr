require "../env"
require "../host_overrides"
require "../outbound"
require "../repeater/flow_request"
require "../fuzz/content_length"
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
    # PROVENANCE: this request is a CAPTURED FLOW's stored bytes, not one the operator typed.
    # Same flag, same meaning and same consequences as `Fuzz::PlanOptions#evidence?` and
    # `Repeater::PlanOptions#evidence?` — with it off, sequencing a capture refused any head
    # carrying an OData/Mongo `$token` and promoted a bare-LF head to CRLF on every replay in
    # the collection, while `gori run repeater <same-flow>` sent it byte-exact.
    # `--request FILE` / stdin / the TUI editor keep the draft behaviour.
    property? evidence : Bool
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
                   @evidence : Bool = false,
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
      # itself contains a `$TOKEN` twice. A DRAFT-time pass, skipped for EVIDENCE — see
      # `PlanOptions#evidence?`.
      #
      # The head-only refusal that used to run first (#519) is gone: a `$NAME` with no value
      # is a literal string on the wire (see `Env::Escape`).
      #
      # `resync_expanded_body` re-frames the head when expansion moved the BODY's byte length
      # — see its own comment. It and the dropped refusal are orthogonal edits to this one
      # statement, landed independently; the union is what both intended.
      request = if options.evidence?
                  options.request
                else
                  resync_expanded_body(options.request, Env.expand_wire(String.new(options.request)))
                end
      # `evidence:` carries the branch above to the SEND seam, where session bindings resolve
      # (`Fuzz::Sender#evidence?`). The Sequencer is the worst place in gori to get this
      # wrong for the same reason `resync_expanded_body` gives below: its whole output is a
      # VERDICT about a token, and every one of the `--count` samples is the same captured
      # request re-sent. Substituting a `$id` in that capture makes the entropy report a
      # statement about a request the operator never captured — measured at 5 tainted sends
      # out of 6 on `gori run sequence <flow> --bind-from <flow>`.
      # Keep-alive. The Sequencer is the single worst offender in gori for handshakes: every
      # one of `--count` samples (default 500) is the SAME captured request re-sent, to the
      # same origin, at a default concurrency of 1 — so it was paying 500 sequential TCP +
      # TLS handshakes to collect 500 tokens. `idle_conns` is the concurrency because that is
      # the most sockets that can be checked out at once (see `Fuzz::Sender#initialize`).
      #
      # Safe for the verdict this tool produces: `ConnPool` refuses to park a socket whose
      # request or response was not cleanly framed, so a reused connection carries the same
      # bytes a fresh one would. It is also excluded on h2, which frames its own connection.
      # `Engine#orchestrate` closes the backend, which is what releases the parked sockets.
      sender = Fuzz::Sender.new(origin, outbound, http2: options.http2?, verify: options.verify?,
        sni: options.sni, timeout: config.timeout, overrides: options.overrides,
        evidence: options.evidence?, keep_alive: config.keep_alive?, idle_conns: config.concurrency)
      new(engine: Engine.new(request, options.http2?, sender, config), config: config,
        origin: origin, request: request,
        request_target: Gori::Outbound.request_target(request), http2: options.http2?)
    end

    # Re-frame the head when `Env.expand_wire` changed the BODY's byte length.
    #
    # The expansion runs over the whole message, head and body, so a `$KEY` in a body resolves
    # to a value that is almost never the token's own width — and the head still declares the
    # PRE-expansion `Content-Length`. `Engine#process_one` then hands `@request` to the backend
    # verbatim on every sample, so the collection wrote more (or fewer) body bytes than it
    # announced: the origin read the declared prefix and the remainder sat in the connection as
    # the front of the next request line, a request-smuggling primitive gori generated by itself
    # out of a request nobody authored.
    #
    # It is the worst place in gori for it, because the Sequencer's whole output is a VERDICT
    # about a token. A strict origin 400s the truncated body, no `Set-Cookie` comes back, every
    # sample misses, and the report reads `rating: CRITICAL (no usable tokens) · 0 usable / 0
    # total · 0.0 bits effective` — a sentence about the target's entropy, over a request the
    # target rejected as malformed. An operator acts on that; a named refusal is what belonged
    # there.
    #
    # Every sibling builder already frames here and the Sequencer was the one that did not:
    # `Repeater::Plan` runs `FlowRequest.resync_content_length_if_body_changed`,
    # `Fuzz::Generator#emit` runs `ContentLength.sync` on every dispatched request, and
    # `Env.expand_bindings` carries `shift_content_length` for the send-time half of the same
    # collision. This is that missing pass, at the one seam all three sequence surfaces
    # (`gori run sequence`, MCP `sequence_start`, the TUI Sequencer tab) expand through.
    #
    # Gated on the body LENGTH changing, never run unconditionally:
    #
    #   * a request with no `$KEY` in its body comes back byte-identical, so a deliberately
    #     wrong `Content-Length` over a short body — a CL-desync probe whose session cookie
    #     someone is sequencing precisely because the endpoint is odd — survives.
    #     `Fuzz::ContentLength.sync` is otherwise a RESYNC and would silently correct it.
    #   * an expansion that only touched the HEAD leaves the body alone and is a no-op here.
    #
    # `Fuzz::ContentLength.sync` and not `FlowRequest.resync_content_length`: it is the
    # byte-level one (no `String` round trip, so a binary body survives), and `add_when_missing:
    # false` means a request that declared no length never grows one — `sync` also leaves a
    # `Transfer-Encoding` message alone, for the same reason `Env.content_length_digits` refuses
    # it. `Env.head_body_boundary` on BOTH sides on purpose: it accepts `\n\n` as well as
    # `\r\n\r\n`, so a bare-LF head — what the TUI editor holds, and what `expand_wire` promotes
    # to CRLF on the way out — is measured rather than silently skipped.
    #
    # TWIN: `Miner::Plan.resync_expanded_body` is this function, byte for byte. It is duplicated
    # rather than shared because the two builders own nothing in common below `Env`, and the
    # shared home either fixer could reach (`Fuzz::ContentLength`) is the primitive both already
    # call — the policy above (WHEN to re-frame, and with which of the two resync helpers) is
    # the part that must not drift. Change one, change the other.
    private def self.resync_expanded_body(before : Bytes, after : Bytes) : Bytes
      return after if body_size(before) == body_size(after)
      Fuzz::ContentLength.sync(after, add_when_missing: false)
    end

    private def self.body_size(bytes : Bytes) : Int32
      bytes.size - Env.head_body_boundary(bytes)
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
