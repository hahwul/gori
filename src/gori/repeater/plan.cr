require "../env"
require "../host_overrides"
require "../outbound"
require "./engine"
require "./flow_request"
require "./sender"
require "./ws_engine"

module Gori::Repeater
  # Why one option set cannot become a runnable send.
  #
  # The builder never writes the user-facing sentence: every surface phrases these in its
  # own idiom (`gori run repeater: could not determine a target host` vs the TUI's
  # `repeater: invalid target — use scheme://host[:port]/path`), and those strings are part
  # of each surface's contract. So `reason` is the machine-readable fact and the `message`
  # here is only a fallback for a caller that has nothing better to say.
  class PlanError < Exception
    enum Reason
      # No request wire at all (the TUI's editor split into zero non-blank `%%%` chunks).
      NoRequest
      # Neither an explicit target, nor one carried by the seeding flow / saved session.
      NoTarget
      # A target was given but no usable host/port came out of it (`detail` = the
      # Env-expanded string that failed, for surfaces that quote it back).
      BadTarget
      # The target's scheme is one the repeater engines cannot dial (`detail` = the scheme).
      UnsupportedScheme
      # The request, the target or the SNI still names an env var that resolves to
      # nothing, so the send would put the token's own characters on the wire (`detail` =
      # the unresolved tokens, prefixed and comma-joined, for surfaces that quote back).
      UnresolvedEnv
    end

    getter reason : Reason
    getter detail : String?

    def initialize(@reason : Reason, message : String, @detail : String? = nil)
      super(message)
    end
  end

  # A pre-resolved dial origin, for a surface that already parsed and validated one.
  #
  # MCP's `url`/`raw` path is the only such caller, and the reason is expansion, not
  # validation: `MCP::RequestBuilder` has already run `Env.expand` over the url, so rebuilding
  # a target string from its parts and feeding it back through `resolve_origin` — which
  # expands again — would DOUBLE-expand a host whose value came from a `$KEY`. That is the
  # same failure `Fuzz::Plan` was written to end (DESIGN.md §7). Skipping the round-trip also
  # keeps `RequestBuilder`'s stricter checks (port range, CR/LF in the authority) as the only
  # ones that ran, rather than layering a second, looser parse on top.
  record Origin, scheme : String, host : String, port : Int32

  # A normalized, surface-independent description of ONE hand-authored send.
  #
  # Each surface's remaining job is to parse ITS OWN input format into this — `OptionParser`
  # plus a flow/session row for `gori run repeater`, the JSON args hash for MCP, editor state
  # for the TUI tab — and nothing else. Everything downstream (env expansion, the
  # Content-Length policy, WebSocket detection, target parsing, SNI, host overrides, and the
  # `Sender` construction that used to drift between the three copies) belongs to `Plan.build`.
  struct PlanOptions
    # The request wire(s). More than one ONLY for a `%%%` send-group pipeline, which rides a
    # single connection and is therefore one plan, not several.
    property requests : Array(Bytes)
    # Run `Env.expand_wire` over each request. False when the surface already produced final
    # bytes and a second pass would DOUBLE-expand (a `$KEY` whose value itself looks like a
    # token): the TUI editor's hex / gRPC / decode / §…§ modes each own their byte semantics,
    # and MCP's `RequestBuilder` expands while it builds.
    property? expand_request : Bool
    # Recompute Content-Length over the (possibly expanded) body. Off keeps a deliberately
    # hand-set CL — `repeater create --no-auto-cl`, and `gori run repeater -H "Content-Length: N"`,
    # both of which exist for CL-mismatch / request-smuggling testing.
    property? auto_content_length : Bool
    # A pre-resolved origin, which wins over `target` / `default_target` when set.
    property origin : Origin?
    # An explicit target, which wins over `default_target` when non-blank.
    property target : String?
    # The origin the seeding flow or saved session implies, when there is one.
    property default_target : String?
    # Dial over HTTP/2. Ignored on the WebSocket path (`WsEngine` is h1-only by RFC 6455).
    property? http2 : Bool
    # TLS SNI override, BEFORE `Env.expand` — the builder owns the expansion so it happens
    # on every surface (MCP's flow path and the TUI both used to skip it).
    property sni : String?
    # Verify the upstream TLS certificate.
    property? verify : Bool
    # Per-operation connect/read/write timeout, or nil for the engine defaults.
    property timeout : Time::Span?
    # The project's hostname overrides, or nil when the surface has no project to load them
    # from. Only a surface can reach a Store (or the live `Session#host_overrides`), so this
    # is passed in rather than loaded.
    property overrides : Gori::HostOverrides?

    def initialize(@requests : Array(Bytes) = [] of Bytes,
                   *,
                   @expand_request : Bool = true,
                   @auto_content_length : Bool = true,
                   @origin : Origin? = nil,
                   @target : String? = nil,
                   @default_target : String? = nil,
                   @http2 : Bool = false,
                   @sni : String? = nil,
                   @verify : Bool = true,
                   @timeout : Time::Span? = nil,
                   @overrides : Gori::HostOverrides? = nil)
    end
  end

  # A ready-to-send repeater job: THE only place a `Repeater::Sender` is constructed.
  #
  # The sequence *expand → Content-Length policy → WebSocket detection → target parse →
  # SNI → host overrides → sender* used to exist five times over (`gori run repeater` for a
  # flow and for a saved session, MCP `send_request` and `send_websocket`, and the TUI's
  # ^R / send-group / WS paths), and the copies had drifted:
  #
  #   * MCP's flow path never ran `Env.expand` over the captured SNI, so a `$SNI_HOST` var
  #     reached the TLS handshake literally there while `gori run repeater` expanded it.
  #   * The TUI never applied the project's host overrides at all (#367) — the same run
  #     through `gori run repeater` was pinned to the operator's IP and the TUI's was not.
  #   * `port <= 0` was rejected only by MCP `send_websocket`; the other four dialed it.
  #
  # One builder makes those answers the same by construction.
  #
  # `outbound` is an ARGUMENT, never built here: Layer-1 strictness differs per surface on
  # purpose (`Outbound.agent` / `.cli` / `.interactive`, DESIGN.md §7), and constructing one
  # in here would silently collapse that distinction into whichever policy was hard-coded.
  struct Plan
    getter sender : Sender
    # The final wire bytes, in send order. Size > 1 only for a send-group pipeline.
    getter requests : Array(Bytes)
    getter scheme : String
    getter host : String
    getter port : Int32
    getter? http2 : Bool
    # The request is an RFC 6455 upgrade, so it must go out through `send_ws` (a plain
    # one-shot would re-issue the handshake and report the 101 having exchanged no frames).
    getter? websocket : Bool
    # The expanded SNI host, or nil to present the dialed host.
    getter sni : String?

    def initialize(@sender : Sender, @requests : Array(Bytes), @scheme : String,
                   @host : String, @port : Int32, @http2 : Bool,
                   @websocket : Bool, @sni : String?)
    end

    # The single request's wire bytes (the first, for a group).
    def bytes : Bytes
      @requests.first
    end

    # The reason this send may not go out, or nil to proceed. Covers EVERY request in the
    # plan: a group rides one connection, so one blocked member refuses the whole batch
    # rather than sending a partial, misleading sequence.
    def refusal : String?
      @sender.group_refusal(@requests)
    end

    def send : Result
      @sender.send(bytes)
    end

    def send_group : Array(Result)
      @sender.send_group(@requests)
    end

    def send_ws(messages : Array(WsEngine::OutMsg),
                idle : Time::Span = WsEngine::DEFAULT_IDLE) : WsEngine::Result
      @sender.send_ws(bytes, messages, idle)
    end

    # The same target and gated dialer carrying different wire bytes — for a surface that
    # rewrites the request AFTER assembly. MCP's opt-in Match&Replace parity is the only
    # such caller: its rules key off the dialed host, which is not known until the plan
    # resolved it, so the rewrite cannot happen before `build`.
    #
    # Reusing the SAME `Sender` is the point: the scope verdict was taken against this
    # origin, and a rewrite must not be able to move the dial target out from under it.
    # `websocket?` IS re-derived, because a rule that adds or strips `Upgrade: websocket`
    # would otherwise leave the plan classified against bytes it no longer carries.
    def with_requests(requests : Array(Bytes)) : Plan
      raise PlanError.new(PlanError::Reason::NoRequest, "no request to send") if requests.empty?
      Plan.new(sender: @sender, requests: requests, scheme: @scheme, host: @host,
        port: @port, http2: @http2,
        websocket: WsEngine.upgrade_request?(String.new(requests.first)), sni: @sni)
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      scheme, host, port = resolve_origin(options)

      raise PlanError.new(PlanError::Reason::NoRequest, "no request to send") if options.requests.empty?
      # Checked on `options.requests` REGARDLESS of `expand_request?`, and that is the
      # point: when it is false the surface expanded already (MCP's `RequestBuilder`, the
      # TUI editor's byte modes), so an unresolved token is sitting in the bytes it handed
      # over and this is still the last place anyone looks before they reach a socket.
      refuse_unresolved(options.requests.flat_map { |b| Env.unresolved_wire(String.new(b)) }.uniq!)
      wires = options.expand_request? ? options.requests.map { |b| Env.expand_wire(String.new(b)) } : options.requests

      # Detect the upgrade on the FINAL wire, not the stored text: the bytes that decide
      # which engine runs must be the bytes that go out, or a `$KEY` expanding into the
      # `Upgrade: websocket` header would pick the h1 engine and silently exchange nothing.
      websocket = WsEngine.upgrade_request?(String.new(wires.first))
      # A handshake carries no body, and all three surfaces have always sent it verbatim —
      # `resync_content_length` never ADDS a header, but a captured upgrade that happened to
      # carry a Content-Length would be rewritten, so skip the pass rather than rely on that.
      wires = wires.map { |b| FlowRequest.resync_content_length(b) } if options.auto_content_length? && !websocket
      # `HTTP/2` on the version line of a request going down an h1 socket is never anything
      # but a mistake (a Burp-pasted h2 view, or a captured h2 flow replayed as h1), and
      # `FlowRequest.downgrade_version_line` exists to correct it. Its comment says it "runs
      # unasked on every send", but the TUI was its only caller — so the SAME session sent
      # different bytes from the TUI than from `gori run repeater send` / MCP
      # `send_request{repeater_id}`. Doing it here puts it on the one path all three surfaces
      # share. It is deliberately narrow (only the h2/h3 spellings; `HTTP/1.0` and a probe's
      # `HTTP/9.9` are left alone), and it cannot touch an h2 send, which never builds a
      # version line from this text.
      # Gated on `expand_request?` as well: that flag is what a surface sets to mean "these
      # bytes are the message, do not help" — the TUI's hex/byte modes, MCP's pre-expanded
      # `raw`, and `gori run repeater send --verbatim`. Every other normalization on this path
      # is already behind it, and a version line is the operator's to get wrong when they asked
      # for verbatim.
      wires = wires.map { |b| FlowRequest.downgrade_request_line(b) } if options.expand_request? && !options.http2?

      unless scheme.in?("http", "https")
        raise PlanError.new(PlanError::Reason::UnsupportedScheme,
          "unsupported target scheme #{scheme.inspect}", scheme)
      end

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
      options.sni.try { |s| refuse_unresolved(Env.unresolved(s, deferred: nil)) }
      sni = options.sni.try { |s| Env.expand(s).presence }
      sender = Sender.new(outbound, scheme: scheme, host: host, port: port,
        verify: options.verify?, http2: options.http2?, sni: sni,
        timeout: options.timeout, overrides: options.overrides)
      new(sender: sender, requests: wires, scheme: scheme, host: host, port: port,
        http2: options.http2?, websocket: websocket, sni: sni)
    end

    # The pre-resolved origin when the surface has one, else the explicit target, else the
    # seeding flow's / saved session's.
    #
    # Note the asymmetry: a BLANK `target` is an error, not "fall back to the default".
    # `Fuzz::PlanOptions` treats blank as absent because an MCP agent that sends `"url": ""`
    # means "use the flow's" — but no repeater surface does that (MCP only ever sets
    # `default_target`/`origin`), and `gori run repeater --target=` used to abort. Silently
    # redirecting an empty `--target "$MAYBE_UNSET"` to the captured host would send the
    # request somewhere the operator did not name.
    private def self.resolve_origin(options : PlanOptions) : {String, String, Int32}
      if o = options.origin
        # A pre-resolved origin skips `Env.expand` because its builder already ran it —
        # but an unresolved `$HOST` survives that expansion as the literal host, and this
        # early return is the one path where nothing else would ever look at it again.
        refuse_unresolved(Env.unresolved(o.host, deferred: nil)) # see the SNI note above
        return {normalize_scheme(o.scheme), o.host, o.port}
      end
      raw = options.target || options.default_target.presence
      raise PlanError.new(PlanError::Reason::NoTarget, "no target origin") unless raw
      refuse_unresolved(Env.unresolved(raw, deferred: nil)) # see the SNI note above
      url = Env.expand(raw)
      scheme, host, port = FlowRequest.parse_target(url)
      if host.empty? || port <= 0
        raise PlanError.new(PlanError::Reason::BadTarget,
          "could not determine a target host from #{url.inspect}", url)
      end
      {normalize_scheme(scheme), host, port}
    end

    # Refuse a send whose request, target or SNI still carries a token that resolves to
    # nothing. `Env.expand` leaves an unregistered `$KEY` literal on purpose — right for a
    # display path, wrong here, because the seven characters `$SESSION` then go out as a
    # header value, the origin answers 401, and the operator reads that as the target
    # rejecting a token rather than as a variable they never set (#519). This builder is
    # the surface-independent chokepoint every repeater surface goes through, so the check
    # lives here once instead of in each of the five paths that used to drift.
    private def self.refuse_unresolved(names : Array(String)) : Nil
      return if names.empty?
      detail = Env.token_list(names)
      raise PlanError.new(PlanError::Reason::UnresolvedEnv,
        "unresolved env #{detail}", detail)
    end

    # ws/wss are hand-typed spellings of http/https — the capture proxy only ever records
    # `http`/`https` (Proxy::Server and Tls::Tunnel are the only ClientConn constructors), so
    # a `wss://` target can only come from an operator's TARGET field, `--target`, an MCP
    # `url`, or a session row created with one.
    #
    # Fold them here rather than allowing both spellings downstream: `WsEngine` tests
    # `scheme == "https" || scheme == "wss"`, but `Engine` and `H2Engine` test `== "https"`
    # ALONE. Passing `wss` through therefore made the TLS decision depend on which engine the
    # surface happened to pick — and a WebSocket upgrade replayed as a plain one-shot (a
    # captured upgrade whose response was not 101, so the CLI's 101 guard does not fire) went
    # out over a CLEARTEXT socket to a TLS port, leaking the request's cookies and auth
    # headers. Normalizing makes every engine's `== "https"` test correct by construction.
    private def self.normalize_scheme(scheme : String) : String
      case scheme
      when "ws"  then "http"
      when "wss" then "https"
      else            scheme
      end
    end
  end
end
