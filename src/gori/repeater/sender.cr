require "log"
require "../outbound"
require "../bindings"
require "../env"
require "../intercept_filter"
require "../host_overrides"
require "./engine"
require "./h2_engine"
require "./ws_engine"

module Gori
  module Repeater
    # The dial seam for a single HAND-AUTHORED send: Repeater's ^R / send-group / WebSocket
    # replay in the TUI, `gori run repeater send|flow`, and MCP send_request/send_websocket.
    #
    # These paths dial `Engine`/`H2Engine`/`WsEngine` straight from the UI, bypassing the
    # proxy's per-request gate, and each surface used to re-implement the Sandbox check
    # beside its own send call. Repeater dialed with NO gate at all on several of them
    # before that was noticed, and MCP's `send_request` still let allow_unscoped:true walk
    # straight past Sandbox. Requiring a `Gori::Outbound` in the constructor makes that
    # class of omission a compile error.
    #
    # Callers ask `#refusal` first so they can report the block in their own idiom (a TUI
    # status line, a CLI abort, an MCP SCOPE_BLOCKED error) BEFORE anything is printed;
    # `#send` re-checks anyway, so a caller that forgets still cannot put bytes on the wire.
    class Sender
      getter scheme : String
      getter host : String
      getter port : Int32
      getter? http2 : Bool

      # PROVENANCE, carried from `PlanOptions#evidence?`. `Plan` stopped expanding `$KEY`
      # into captured bytes, and `plan.cr` names the one exception it deliberately left
      # open: "except a DECLARED session binding, which `Env.expand` deliberately leaves
      # for `Env.expand_bindings` at the send seam." THIS is that seam, and it ran
      # unconditionally — so an extract rule declaring an ordinary name (`filter`, `top`,
      # `token`, `user`, `where`) rewrote a captured `GET /api?$filter=…` exactly the way
      # the project env var used to, one seam past the one that was closed. Reproduced from
      # MCP over one process: a `send_request` that binds `$TOKEN`, then a replay of a
      # stored `GET /api?$TOKEN=1` — the origin logged `GET /api?SECRETTOKEN123=1` while
      # the tool result still reported the stored target.
      #
      # The cost is the mirror of the engine tabs' (`FuzzerView#evidence_template`): an
      # operator's own `$TOKEN` merged into evidence — `gori run repeater -H`, a TUI edit
      # over a seeded capture — now ships literally rather than resolving. That is the
      # direction that can only be READ WRONG, never SENT wrong, and a surface that wants
      # both can expand at its own merge seam, where it still knows whose bytes are whose.
      getter? evidence : Bool

      # LITERALNESS, carried from `PlanOptions#expand_bindings?` — and NOT a second spelling of
      # `evidence?` one field up. `evidence?` answers WHO WROTE these bytes; this answers
      # whether the operator asked for them to go out as they are. Both switch the same `$NAME`
      # pass off, and they stay two words because a `--verbatim` send is the operator's OWN
      # draft: provenance says expand it, the flag says do not, and folding the flag into
      # `evidence` would make `verbatim` claim a capture's provenance for a request the
      # operator just typed. (`Fuzz::Sender` spells the same thing `evidence` on purpose, and
      # that is not drift: there it is defined as the MAXIMAL verbatim span, so the two words
      # already mean one thing on that side of the tree.)
      #
      # It exists because `verbatim` never reached this seam. `--verbatim` / `verbatim:true`
      # promise "no `$VAR` expansion" and delivered it for project env vars by switching off
      # `PlanOptions#expand_request?` — a BUILDER flag — while the binding pass down here ran
      # regardless. A session whose stored request is `GET /api?$TOKEN=1` therefore left for the
      # origin as `GET /api?SECRETTOKEN123=1` under the flag that says it would not: a request
      # nobody wrote, carrying a live credential in the position the operator chose as a
      # PAYLOAD, into the target's access log. `Env.expand_bindings` already takes a `verbatim`
      # span list for that exact reason — `Fuzz::Generator` excludes a payload's span with it —
      # so this is the whole-buffer answer at a seam that has no spans to compute.
      #
      # The SESSION SLOT overlay is deliberately NOT switched off with it; `wire` says why.
      getter? expand_bindings : Bool

      # See `PlanOptions#reframe_grpc?`. h2 ONLY, and carried down to `H2Engine.parse_request`
      # rather than applied to `bytes` here, so the reframe rides the same fields/body split
      # `encoded_request` reports the wire through.
      getter? reframe_grpc : Bool

      # The TLS fingerprint this tab/send was told to present, or nil for "whatever the
      # destination policy says" (#844). PER-SEND, not per destination: two tabs against one
      # host with different values dial two different SSL contexts, which is the A/B the
      # override exists for. It reaches only the https dial — `Settings.outbound_tls_for`
      # narrows the destination rule with it, so there is no second TLS policy path (P1).
      #
      # NEVER inferred (P4): every surface either takes it from the operator or leaves it nil.
      # It is an APPROXIMATION of the named client's hello, exactly as #822 documents the
      # presets — reporting it does not claim a byte-exact JA3 match.
      getter tls_preset : String?

      def initialize(@outbound : Gori::Outbound, *, @scheme : String, @host : String, @port : Int32,
                     @verify : Bool, @http2 : Bool = false, @sni : String? = nil,
                     @timeout : Time::Span? = nil, @overrides : Gori::HostOverrides? = nil,
                     @preserve_field_case : Bool = false, @evidence : Bool = false,
                     @expand_bindings : Bool = true,
                     @reframe_grpc : Bool = false, tls_preset : String? = nil)
        @tls_preset = Settings.tls_preset_normalize(tls_preset)
      end

      # The reason this request may not go out, or nil to proceed. ONE rule stops a deliberate
      # single send: Sandbox mode (see `Outbound#send_block`).
      #
      # There used to be a second — a `$NAME` an extract rule declares but nothing has bound
      # yet (#501) — and it is gone. `$NAME` without a value is a literal string on the wire
      # now, at every seam that interprets it, because the token grammar is byte-identical to
      # GraphQL's `$id`, Mongo's `$ne` and JSON Schema's `$ref`: declaring an extract rule
      # named `id` made every captured GraphQL body in the project unsendable. See
      # `Env.unbound`. `$$id` is the escape when the name DOES resolve and the operator wants
      # the literal anyway.
      #
      # Still off for EVIDENCE (see `evidence?`): a `$filter` in a stored request line is not
      # a reference to resolve — it is a byte the origin saw. And off for LITERAL bytes
      # (`expand_bindings?`) for the reason that matters more here than anywhere: this gate
      # must read the REQUEST LINE THAT WILL GO OUT. Expanding for the verdict and sending the
      # token would ask the scope about `/api?SECRETTOKEN123=1` and then put `/api?$TOKEN=1` on
      # the wire — one path-scoped include or exclude rule away from a decision taken about a
      # URL that never existed. Whichever way the pass is switched, both halves move together.
      def refusal(bytes : Bytes) : String?
        return @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(bytes), @port) unless resolve_bindings?
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(Gori::Env.expand_bindings(bytes)), @port)
      end

      def refusal(text : String) : String?
        return @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(text), @port) unless resolve_bindings?
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(Gori::Env.expand_bindings(text)), @port)
      end

      # Does the `$NAME` binding pass run at this seam? The two independent reasons it does not
      # — the bytes are somebody else's (`evidence?`) or the operator said they are the message
      # (`expand_bindings?`) — read as one question everywhere the pass is reached, so they are
      # ANDed once here rather than at each of the four sites. `wire`, both `refusal`s and
      # `send_ws` all ask this, which is what keeps the gate's URL and the socket's URL equal.
      private def resolve_bindings? : Bool
        @expand_bindings && !@evidence
      end

      # The first refusal across a whole send-group, or nil when every request may proceed.
      # A group is ONE connection carrying a deliberate sequence (smuggling / keep-alive
      # desync probes), so one blocked member refuses the whole batch rather than sending a
      # partial, misleading sequence.
      def group_refusal(requests : Array(Bytes)) : String?
        requests.each { |b| (r = refusal(b)) && (return r) }
        nil
      end

      # The SEND SEAM's own transform: the assembled request as the SOCKET will get it.
      #
      # Two passes, in this order:
      #
      #   * the `$NAME` binding pass, skipped when `resolve_bindings?` says so — for
      #     `evidence?` (somebody else wrote these bytes) or for `expand_bindings?` (the
      #     operator said these bytes ARE the message). See both.
      #   * the SESSION SLOT overlay, after the `$NAME` pass and regardless of EITHER of them.
      #     AFTER, because the slot's own header values may name a binding
      #     (`Authorization: Bearer $SESSION`) and the layer resolves those as it applies
      #     them, against the ACTIVE slot's table — so the order is "resolve the message,
      #     then write this identity over it", never the reverse. REGARDLESS, because a slot
      #     is not a resolution of somebody's tokens; it is the operator answering "send this
      #     AS WHOM" (P4), and replaying a capture under another identity is the single most
      #     common reason to ask. The no-overlay answer has a name and it is `as-captured` —
      #     select it, or select no slot at all, and this is the identity function.
      #
      #     `verbatim` does not change that answer, and the answer is STATED rather than
      #     inherited because the two flags arrived one round apart. `--verbatim` says which
      #     BYTES; a slot says WHOSE identity. They are different questions asked by the same
      #     operator in the same command (`gori run repeater send --slot admin --verbatim`),
      #     and letting the byte answer veto the identity one would send that command as the
      #     STORED identity while the operator named another — a silent substitution in the
      #     one direction P4 refuses. The `$NAME` in a slot header is also the one `$NAME` in
      #     gori that is guaranteed to be a reference and never a payload (`unbound_in_slot`
      #     argues it), so resolving it takes nothing literal away from the operator's bytes:
      #     the overlay writes the slot's own line, and every byte the operator typed that
      #     survives it is untouched.
      #
      # Header-only overlay, so Content-Length cannot move and the body stays byte-exact (P7).
      #
      # PUBLIC, and that is the point. These two passes ran INSIDE `send`, where no caller
      # could see their output — so every surface that RECORDS or REPORTS "the outbound
      # request" described the pre-seam draft: `gori run repeater send --record-history` and
      # MCP `send_request{record_history}` wrote a History flow with the slot's
      # `Authorization` line missing (and `$SESSION` still literal in it) while the socket
      # got both, and MCP's `effective_request` — documented as "the request actually put on
      # the wire" — was derived from the same pre-seam bytes. A flow recorded that way is not
      # the request that was sent: replay it, fuzz from it, or scan it and the identity gori
      # actually used is nowhere in the evidence. A caller now takes these bytes once, hands
      # them to `send_wire`, and records exactly what went out.
      #
      # The Fuzzer reaches the same seam through `Fuzz::Sender#send`, which runs the two passes
      # itself; its answer travels back on `Repeater::Result#wire` because a fuzz ROW must keep
      # showing the template (see `Fuzz::Result#wire`). Two shapes, one rule: what is recorded
      # is what was written.
      def wire(bytes : Bytes) : Bytes
        bytes = Gori::Env.expand_bindings(bytes) if resolve_bindings?
        Gori::Env.overlay_slot(bytes)
      end

      def send(bytes : Bytes) : Result
        send_wire(wire(bytes))
      end

      # Send bytes that are ALREADY through `wire` — for a surface that has to hold the exact
      # slice the socket gets (to record it as a flow, or to report it back).
      #
      # Still through `refusal`, not a hand-rolled `send_block` beside it: this is the door
      # `gori run repeater send` and MCP `send_request` now use, and "may these bytes go out"
      # has to keep ONE implementation — `refusal` used to carry a second rule (see its
      # comment), and a copy here would walk past the next one added. Asking it about the
      # final bytes is the same verdict it takes one step earlier: its own expansion is a
      # no-op on an already-expanded buffer, and the slot overlay is header-only, so neither
      # pass can move the request line the gate reads.
      def send_wire(wire : Bytes) : Result
        if reason = refusal(wire)
          return Result.new(Bytes.new(0), nil, nil, 0_i64, reason)
        end
        result =
          if @http2
            H2Engine.send(wire, scheme: @scheme, host: @host, port: @port,
              verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides,
              preserve_field_case: @preserve_field_case, reframe_grpc: @reframe_grpc,
              tls_preset: @tls_preset)
          else
            Engine.send(wire, scheme: @scheme, host: @host, port: @port,
              verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides,
              tls_preset: @tls_preset)
          end
        extract(wire, result)
        result
      end

      # Send a field-native h2 request: the operator's exact HPACK field list plus body, with
      # no h1-text carrier in between (see `H2Engine.send_fields`). Gated identically to `send`
      # — Sandbox / exclude on a request line synthesized from `:method`/`:path`, so a
      # field-native send can no more reach a blocked host than a byte-authored one.
      #
      # Nothing on this path expands: the fields ARE the message and go to the encoder as
      # given. The synthetic line is built from `:method`/`:path`, which ARE operator-typed and
      # can hold a `$NAME` like any other path — so `Plan.build_field_native` constructs this
      # Sender with `expand_bindings: false`, or the gate would have decided about
      # `/api?SECRETTOKEN123=1` while `/api?$TOKEN=1` went on the wire.
      def send_fields(fields : Array({String, String}), body : Bytes?) : Result
        scope = H2Engine.field_scope_line(fields)
        if reason = refusal(scope)
          return Result.new(Bytes.new(0), nil, nil, 0_i64, reason)
        end
        # No SESSION SLOT overlay here, and this is a limit rather than an omission: a slot's
        # overlay is defined over HEADER LINES in an h1 text head (`SessionSlot.overlay_head`),
        # and a field-native send has no such carrier — that is the entire point of the path.
        # Applying it would mean a second implementation of the upsert/strip semantics over an
        # HPACK field list, which is the "two copies of one rule" this file's own history warns
        # about. An operator who wants an identity on these bytes writes the field.
        result = H2Engine.send_fields(fields, body, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides,
          tls_preset: @tls_preset)
        extract(scope, result)
        result
      end

      def send_group(requests : Array(Bytes)) : Array(Result)
        if reason = group_refusal(requests)
          return requests.map { Result.new(Bytes.new(0), nil, nil, 0_i64, reason) }
        end
        # Per member, through the SAME seam `send` uses — a group is ONE connection carrying a
        # deliberate sequence, and every member of it goes out as the same identity.
        requests = requests.map { |b| wire(b) }
        results = Engine.send_pipeline(requests, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides,
          tls_preset: @tls_preset)
        # A group is ONE connection carrying a deliberate sequence, so every member is as
        # hand-authored as a lone `send` and every response is an equally legitimate source.
        # Later members win on a name both write, which is the wire order.
        requests.each_with_index { |b, i| results[i]?.try { |r| extract(b, r) } }
        results
      end

      def send_ws(upgrade : Bytes, messages : Array(WsEngine::OutMsg),
                  idle : Time::Span = WsEngine::DEFAULT_IDLE,
                  keep_key : Bool = false) : WsEngine::Result
        if reason = refusal(upgrade)
          return WsEngine::Result.new(Bytes.new(0), [] of WsEngine::Message, 0_i64, reason)
        end
        # EXTRACTION is handshake-only — a WS frame is not an HTTP response and `TokenExtract`'s
        # five descriptors are all defined over one. INJECTION is not: the messages carry
        # `$NAME` as readily as the handshake does, the proxy's own WS path already resolves it
        # (`Rules` `RulePart::Ws`), and every surface that builds these frames runs `Env.expand`
        # over them — which by design covers env vars and NOT bindings. So a `$SESSION` in a
        # frame went out as those seven characters with the name bound; `expand_messages` below
        # is what fixed that. Unbound it stays literal, the same rule `refusal` now follows.
        # The HANDSHAKE takes the slot overlay (it is an HTTP request head, and the session a
        # WebSocket rides is chosen there); the message FRAMES do not, because a frame has no
        # header lines for a header overlay to write.
        #
        # Through `wire`, not a second copy of its two lines — which is what this was, and the
        # copy had already fallen behind: it expanded `$NAME` UNCONDITIONALLY, so everything
        # `evidence?` turns off for an HTTP send was still on for the handshake of a WS tab
        # seeded from the same capture, and `--verbatim` could not reach it either. The
        # refusal above reads the same predicate, so the gate's URL and the socket's stay equal.
        WsEngine.send(wire(upgrade), expand_messages(messages),
          scheme: @scheme, host: @host, port: @port, verify_upstream: @verify, sni: @sni,
          idle: idle, overrides: @overrides, keep_key: keep_key, tls_preset: @tls_preset)
      end

      # Whole payload, not `expand_bindings`' head/body split: a WS frame has no head to take,
      # so nothing here is a message boundary and the value goes in as it was observed.
      #
      # LITERALNESS is per-SEND here and provenance is per-FRAME, which is why this reads
      # `expand_bindings?` and not `resolve_bindings?`: `--verbatim` / `verbatim:true` is the
      # operator saying every byte of this exchange is the message, while the two populations
      # a WS send mixes — seeded rows and a `--message` draft beside them — carry `evidence`
      # one frame at a time. The surfaces already stop their own `Env.expand` pass under the
      # flag (`ws_out_messages`, MCP's `out_messages`); this is the binding half they could
      # not reach, and without it a `$TOKEN` frame authored as a payload went out as the live
      # session token under the flag promising it would not.
      private def expand_messages(messages : Array(WsEngine::OutMsg)) : Array(WsEngine::OutMsg)
        return messages unless @expand_bindings
        messages.map do |m|
          next m if m.evidence # captured bytes: see `ws_message_refusal`
          expanded = Gori::Env.expand_bindings(String.new(m.payload), guard_boundary: false).to_slice
          # `m.shape` rides along. Rebuilding without it silently reset every frame a binding
          # touched back to FIN=1/RSV=0/fresh-mask — the exact shape this round exists to stop
          # being the only one.
          expanded == m.payload ? m : WsEngine::OutMsg.new(m.opcode, expanded, m.shape, m.evidence)
        end
      end

      # Offer this response to the binding table's extract rules.
      #
      # THIS class is the extraction source, and `Fuzz::Sender` deliberately is not. Not a
      # scope trim — a security argument: a sweep sends attacker-shaped payloads, and a
      # response echoing one back could rebind the operator's session to a payload-derived
      # value that is then injected into every subsequent request. The line between "a
      # deliberate send" and "an automated sweep" is one this codebase had already drawn,
      # exactly here, and reusing it beats inventing a second one.
      #
      # Best-effort: an extract rule must never be able to fail a send the operator made.
      private def extract(request : Bytes, result : Result) : Nil
        bindings = Gori::Env.layer.as?(Gori::Bindings)
        return unless bindings
        return if result.error
        # First line only (NOT `request_target_line`, which deliberately scans past blank
        # lines — this is evidence for an extract rule, not the scope gate's verdict). Read
        # off the slice so a large body is not copied into a String to look at its head.
        nl = request.index(0x0a_u8)
        parts = String.new(request[0, nl || request.size]).split
        subject = Gori::InterceptFilter::Subject.new(
          method: parts[0]? || "GET", host: @host, target: parts[1]? || "/",
          scheme: @scheme, status: result.response.try(&.status))
        bindings.observe(result, subject)
      rescue ex
        ::Log.warn { "extract rules skipped: #{ex.message}" }
      end
    end
  end
end
