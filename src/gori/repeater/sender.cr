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

      def initialize(@outbound : Gori::Outbound, *, @scheme : String, @host : String, @port : Int32,
                     @verify : Bool, @http2 : Bool = false, @sni : String? = nil,
                     @timeout : Time::Span? = nil, @overrides : Gori::HostOverrides? = nil,
                     @preserve_field_case : Bool = false, @evidence : Bool = false)
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
      # a reference to resolve — it is a byte the origin saw. The scope gate runs either way,
      # on the bytes that will actually go out.
      def refusal(bytes : Bytes) : String?
        return @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(bytes)) if @evidence
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(Gori::Env.expand_bindings(bytes)))
      end

      def refusal(text : String) : String?
        return @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(text)) if @evidence
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(Gori::Env.expand_bindings(text)))
      end

      # The first refusal across a whole send-group, or nil when every request may proceed.
      # A group is ONE connection carrying a deliberate sequence (smuggling / keep-alive
      # desync probes), so one blocked member refuses the whole batch rather than sending a
      # partial, misleading sequence.
      def group_refusal(requests : Array(Bytes)) : String?
        requests.each { |b| (r = refusal(b)) && (return r) }
        nil
      end

      def send(bytes : Bytes) : Result
        if reason = refusal(bytes)
          return Result.new(Bytes.new(0), nil, nil, 0_i64, reason)
        end
        bytes = Gori::Env.expand_bindings(bytes) unless @evidence
        result =
          if @http2
            H2Engine.send(bytes, scheme: @scheme, host: @host, port: @port,
              verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides,
              preserve_field_case: @preserve_field_case)
          else
            Engine.send(bytes, scheme: @scheme, host: @host, port: @port,
              verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
          end
        extract(bytes, result)
        result
      end

      # Send a field-native h2 request: the operator's exact HPACK field list plus body, with
      # no h1-text carrier in between (see `H2Engine.send_fields`). Gated identically to `send`
      # — Sandbox / exclude on a request line synthesized from `:method`/`:path`, so a
      # field-native send can no more reach a blocked host than a byte-authored one. The
      # `refusal` scans only that synthetic line, which carries no operator token, so a
      # field-native path is never expanded or injected.
      def send_fields(fields : Array({String, String}), body : Bytes?) : Result
        scope = H2Engine.field_scope_line(fields)
        if reason = refusal(scope)
          return Result.new(Bytes.new(0), nil, nil, 0_i64, reason)
        end
        result = H2Engine.send_fields(fields, body, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
        extract(scope, result)
        result
      end

      def send_group(requests : Array(Bytes)) : Array(Result)
        if reason = group_refusal(requests)
          return requests.map { Result.new(Bytes.new(0), nil, nil, 0_i64, reason) }
        end
        requests = requests.map { |b| Gori::Env.expand_bindings(b) } unless @evidence
        results = Engine.send_pipeline(requests, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
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
        WsEngine.send(Gori::Env.expand_bindings(upgrade), expand_messages(messages),
          scheme: @scheme, host: @host, port: @port, verify_upstream: @verify, sni: @sni,
          idle: idle, overrides: @overrides, keep_key: keep_key)
      end

      # Whole payload, not `expand_bindings`' head/body split: a WS frame has no head to take,
      # so nothing here is a message boundary and the value goes in as it was observed.
      private def expand_messages(messages : Array(WsEngine::OutMsg)) : Array(WsEngine::OutMsg)
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
