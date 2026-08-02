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

    # Replay of a CAPTURED flow: keep the stored Content-Length byte-exact, and recompute it
    # ONLY where env expansion changed the body's length. Distinct from `auto_content_length`,
    # which is the repeater's explicit operator toggle ("keep CL matching the body I typed")
    # and must keep recomputing unconditionally. A flow's bytes are evidence, not a draft.
    property? resync_cl_after_expansion : Bool

    # PROVENANCE: these request bytes are stored EVIDENCE (a captured flow, or a flow gori
    # recorded from a direct send), not a request the operator is DRAFTING in an editor.
    #
    # One signal rather than several, because every draft-time policy on this path is off for
    # the same reason and they had already drifted apart across the surfaces:
    #
    #   * the unresolved-`$KEY` refusal. A stored head is full of `$` that no one typed —
    #     OData `$filter`/`$top`, MongoDB `$where`, `$IFS` shell probes, `$user.name` SSTI,
    #     a PHP/JS cookie — and refusing them made those captures unreplayable, while the
    #     refusal's own remedy ("set the variable") would have SUBSTITUTED a value and sent a
    #     different request. A surface still checks its OPERATOR-TYPED parts itself.
    #   * the head's CRLF normalization. It exists because the TUI/Miner editors hold a
    #     request as a line buffer whose fresh lines end in LF; a captured head is already
    #     exact wire bytes, so normalizing can only CHANGE them — promoting a bare-LF
    #     terminator (a front-end/back-end desync primitive gori stores byte-exact) into an
    #     ordinary conformant request.
    #   * `$KEY` SUBSTITUTION ITSELF. This one was left running, and it is the same argument
    #     one step further: a project that happens to define `filter` (or `top`, `where`,
    #     `token`, `user` — ordinary names) rewrote `GET /api?$filter=…` into
    #     `GET /api?PWNED=…` on the wire and then re-framed Content-Length so the corrupted
    #     request looked self-consistent, while MCP's flow path — which reaches the same
    #     end state through `expand_request: false` — sent the stored bytes. Two surfaces,
    #     one flow id, different requests. A capture is replayed as recorded or not at all.
    #
    # A surface that merges OPERATOR-TYPED overrides into evidence bytes (`gori run
    # repeater <flow-id>`'s `-H`/`-b`) must therefore expand those at ITS OWN merge seam,
    # where it still knows which bytes are the operator's. `expand_request: false` remains
    # the separate "already final, do not expand" knob for a surface whose bytes are a
    # DRAFT it expanded itself (MCP's `RequestBuilder`, the TUI editor's byte modes).
    property? evidence : Bool

    # h2 ONLY: put field names on the wire with the case the operator typed. Off by default
    # because the h1 head text is both a wire format and the paste buffer — a request copied
    # from Burp or curl is conventionally title-cased and h2 requires lowercase (RFC 9113
    # §8.2.1), so verbatim case would kill the stream of every ordinary `--http2` send. A
    # surface turns it on under `--verbatim` / MCP `verbatim:true`, where the bytes ARE the
    # message and an uppercase name is the §8.2.1 conformance probe rather than a paste
    # artifact.
    # Ignored on the h1 path, which has always been byte-exact.
    property? preserve_field_case : Bool

    # h2 ONLY: the EXACT HPACK field list to encode, bypassing the h1-text carrier entirely.
    # When set it WINS over `requests` and forces http2 — the operator supplies :method,
    # :path, :scheme, :authority and every regular field verbatim, so the shapes h1 head text
    # cannot hold (a duplicate pseudo-header, a pseudo AFTER a regular field, a :scheme that
    # disagrees with the connection, :protocol per RFC 8441, an unknown pseudo, a leading-space
    # value — `HeadCodec.h1_faithful?` is the loss set) become sendable. The body rides in
    # `h2_body`. None of the byte-path normalization (env expansion, Content-Length resync,
    # version-line downgrade, field-case fold) applies: the fields are the message.
    property h2_fields : Array({String, String})?
    property h2_body : Bytes?

    def initialize(@requests : Array(Bytes) = [] of Bytes,
                   *,
                   @expand_request : Bool = true,
                   @auto_content_length : Bool = true,
                   @resync_cl_after_expansion : Bool = false,
                   @evidence : Bool = false,
                   @preserve_field_case : Bool = false,
                   @h2_fields : Array({String, String})? = nil,
                   @h2_body : Bytes? = nil,
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
    # See `PlanOptions#preserve_field_case?`. Carried on the plan (not only inside the
    # `Sender`) so a surface that REPORTS the wire request can encode the same fields the
    # send will — MCP's `effective_request` is derived that way.
    getter? preserve_field_case : Bool

    # The field-native request (see `PlanOptions#h2_fields`), or nil for the ordinary byte
    # path. When present, `send` encodes THESE fields rather than `bytes`, and the surfaces
    # that REPORT the wire render the faithful `H2Engine.field_dump` off them rather than the
    # lossy h1 projection. `requests` still holds one synthetic scope line so `refusal` and
    # the scope gate work unchanged.
    getter h2_fields : Array({String, String})?
    getter h2_body : Bytes?

    def initialize(@sender : Sender, @requests : Array(Bytes), @scheme : String,
                   @host : String, @port : Int32, @http2 : Bool,
                   @websocket : Bool, @sni : String?, @preserve_field_case : Bool = false,
                   @h2_fields : Array({String, String})? = nil, @h2_body : Bytes? = nil)
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
      if fields = @h2_fields
        @sender.send_fields(fields, @h2_body)
      else
        @sender.send(bytes)
      end
    end

    def send_group : Array(Result)
      @sender.send_group(@requests)
    end

    # `keep_key` sends the operator's own `Sec-WebSocket-Key` header instead of a fresh one.
    # A send-time argument rather than a `PlanOptions` field: it changes nothing about the
    # target, the scope verdict or the assembled bytes — only which of the head's own lines
    # survives — so it has no business in the builder the scope gate reads.
    def send_ws(messages : Array(WsEngine::OutMsg),
                idle : Time::Span = WsEngine::DEFAULT_IDLE,
                keep_key : Bool = false) : WsEngine::Result
      @sender.send_ws(bytes, messages, idle, keep_key)
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
        websocket: WsEngine.upgrade_request?(String.new(requests.first)), sni: @sni,
        preserve_field_case: @preserve_field_case)
    end

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : Plan
      # Field-native is a separate assembly with no bytes to expand, re-frame or version-fix —
      # kept fully off the byte path below so an ordinary `--http2` send is byte-for-byte what
      # it was, and a field list never accidentally acquires a normalization it opted out of.
      if fields = options.h2_fields
        return build_field_native(options, outbound, fields)
      end

      scheme, host, port = resolve_origin(options)

      raise PlanError.new(PlanError::Reason::NoRequest, "no request to send") if options.requests.empty?
      # The DRAFT-TIME policies — head CRLF normalization and `$KEY` substitution itself —
      # are off for evidence. See `PlanOptions#evidence?`.
      #
      # A third used to live here: a refusal when a `$KEY` in the HEAD resolved to nothing
      # (#519). It is gone, and with it `PlanOptions#refuse_unresolved_env?`, which existed
      # only to switch it off for `--verbatim`. A `$NAME` with no value is a literal string
      # on the wire at every seam now (see `Env::Escape`) — which is what `verbatim` always
      # wanted, and what a GraphQL `?query=…$id…`, a Mongo `$where` header and a JSON Schema
      # `$ref` need in order to be sendable at all.
      draft = !options.evidence?
      wires = expand_requests(options, draft)

      # Detect the upgrade on the FINAL wire, not the stored text: the bytes that decide
      # which engine runs must be the bytes that go out, or a `$KEY` expanding into the
      # `Upgrade: websocket` header would pick the h1 engine and silently exchange nothing.
      websocket = WsEngine.upgrade_request?(String.new(wires.first))
      # A handshake carries no body, and all three surfaces have always sent it verbatim —
      # `resync_content_length` never ADDS a header, but a captured upgrade that happened to
      # carry a Content-Length would be rewritten, so skip the pass rather than rely on that.
      if !websocket
        if options.auto_content_length?
          wires = wires.map { |b| FlowRequest.resync_content_length(b) }
        elsif options.resync_cl_after_expansion?
          # Byte-exact unless expansion just changed the body's length. A no-op whenever
          # nothing expanded (`evidence?`, or `expand_request: false`), which is now every
          # flow-replay caller — it stays wired because the flag means "the CL is not pinned",
          # and a surface that DOES expand a merged draft body still needs it.
          # See `FlowRequest.resync_content_length_if_body_changed`.
          wires = wires.map_with_index { |b, i| FlowRequest.resync_content_length_if_body_changed(options.requests[i], b) }
        end
      end
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
      # DECLARED binding because a send seam re-scans the same value with `Env.expand_bindings`
      # later; this value is read ONCE, frozen into the plan, and never
      # looked at again — `Fuzz::Sender`/`Discover::Sender` build their ConnPool on it and the
      # Layer-1 `Outbound#check` verdict was already taken against it, so re-resolving per send
      # would move the dial target out from under a scope decision. Deferring bought nothing
      # anyway: a binding value is a token observed from a response, never a hostname, a port
      # or an SNI. Left deferred it shipped as the literal `$SESSION` — every send failing DNS,
      # and `Outbound.scope_url` asked about `https://$SESSION/a`, a URL no rule can match, so
      # the run was refused as out-of-scope, naming the wrong gate.
      options.sni.try { |s| refuse_unresolved(Env.unresolved(s, deferred: nil)) }
      sni = options.sni.try { |s| Env.expand(s).presence }
      # `evidence` reaches the SENDER, not just this builder. The comment on
      # `expand_requests` says a declared session binding is deliberately left for
      # `Env.expand_bindings` at the send seam — and that seam ran unconditionally, so
      # everything `evidence?` turns off here was turned back on one layer down for any
      # extract rule whose name collides with a token in the capture. See `Sender#evidence?`.
      sender = Sender.new(outbound, scheme: scheme, host: host, port: port,
        verify: options.verify?, http2: options.http2?, sni: sni,
        timeout: options.timeout, overrides: options.overrides,
        preserve_field_case: options.preserve_field_case?, evidence: options.evidence?)
      new(sender: sender, requests: wires, scheme: scheme, host: host, port: port,
        http2: options.http2?, websocket: websocket, sni: sni,
        preserve_field_case: options.preserve_field_case?)
    end

    # The request wires with `$KEY` expansion applied, or the originals when the surface says
    # it already expanded (`expand_request: false` — MCP's pre-expanded `raw`, the TUI's byte
    # modes, `--verbatim`) — or when the bytes are EVIDENCE, which is never expanded at all.
    #
    # `expand_wire` is the DRAFT pass and there is no evidence pass: a stored head is full of
    # `$` nobody typed (OData `$filter`/`$top`, Mongo `$where`, `$IFS`, `$user.name`), and
    # substituting a project value into one sends a request the operator never captured. This
    # USED to run plain `Env.expand` for evidence, on the theory that only the head's CRLF
    # promotion was a draft policy — but expansion is one too, and it was the one that could
    # silently change the request line. See `PlanOptions#evidence?`.
    #
    # Left INSIDE `evidence?` rather than left to each surface to remember (via
    # `expand_request: false`) precisely because that is how the two headless surfaces drifted:
    # MCP turned expansion off and `gori run repeater` did not, and nothing compared them.
    private def self.expand_requests(options : PlanOptions, draft : Bool) : Array(Bytes)
      return options.requests unless options.expand_request? && draft
      options.requests.map { |b| Env.expand_wire(String.new(b)) }
    end

    # A field-native h2 send: dial origin + SNI resolution, then a `Sender` whose `send` will
    # encode the fields verbatim. `requests` carries ONE synthetic scope line
    # (`H2Engine.field_scope_line`) so `refusal` and the scope gate — both of which key off a
    # request line — work with no special case. The scheme check and the SNI
    # expansion mirror the byte path; everything the byte path does to the WIRE bytes (env
    # expansion, Content-Length, version-line, field-case) is deliberately absent, because a
    # field list is already the exact message.
    private def self.build_field_native(options : PlanOptions, outbound : Gori::Outbound,
                                        fields : Array({String, String})) : Plan
      scheme, host, port = resolve_origin(options)
      unless scheme.in?("http", "https")
        raise PlanError.new(PlanError::Reason::UnsupportedScheme,
          "unsupported target scheme #{scheme.inspect}", scheme)
      end
      options.sni.try { |s| refuse_unresolved(Env.unresolved(s, deferred: nil)) }
      sni = options.sni.try { |s| Env.expand(s).presence }
      sender = Sender.new(outbound, scheme: scheme, host: host, port: port,
        verify: options.verify?, http2: true, sni: sni,
        timeout: options.timeout, overrides: options.overrides)
      new(sender: sender, requests: [H2Engine.field_scope_line(fields)], scheme: scheme,
        host: host, port: port, http2: true, websocket: false, sni: sni,
        h2_fields: fields, h2_body: options.h2_body)
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

    # Refuse a send whose TARGET, host override or SNI still carries a token that resolves
    # to nothing.
    #
    # The REQUEST half of this is gone — a `$NAME` with no value is a literal string on the
    # wire now, everywhere, which is what makes a GraphQL query string sendable. A DIAL TUPLE
    # is the exception the `deferred: nil` note above argues: `$` is not a legal byte in a
    # hostname, so there is no operator test case to protect, and a literal `$SESSION` there
    # makes `Outbound.scope_url` ask about `https://$SESSION/a` — a URL no rule can match —
    # so the send comes back refused as OUT-OF-SCOPE, naming a gate that was never the
    # problem. Refusing here names the real one.
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
