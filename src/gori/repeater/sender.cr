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

      def initialize(@outbound : Gori::Outbound, *, @scheme : String, @host : String, @port : Int32,
                     @verify : Bool, @http2 : Bool = false, @sni : String? = nil,
                     @timeout : Time::Span? = nil, @overrides : Gori::HostOverrides? = nil)
      end

      # The reason this request may not go out, or nil to proceed. Two rules stop a
      # deliberate single send: Sandbox mode (see `Outbound#send_block`), and a `$NAME` that
      # an extract rule declares but nothing has bound yet (#501).
      #
      # The binding check comes FIRST and lives here rather than only in `send`, so every
      # caller that already asks `refusal` in order to report a block in its own idiom — a
      # TUI status line, a CLI abort, an MCP error — reports this one the same way, with no
      # per-surface change. `send_group` and `send_ws` inherit it through `refusal` too.
      def refusal(bytes : Bytes) : String?
        if (unbound = Gori::Env.unbound(bytes)).present?
          return Gori::Env.unbound_error(unbound)
        end
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(Gori::Env.expand_bindings(bytes)))
      end

      def refusal(text : String) : String?
        if (unbound = Gori::Env.unbound(text)).present?
          return Gori::Env.unbound_error(unbound)
        end
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
        bytes = Gori::Env.expand_bindings(bytes)
        result =
          if @http2
            H2Engine.send(bytes, scheme: @scheme, host: @host, port: @port,
              verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
          else
            Engine.send(bytes, scheme: @scheme, host: @host, port: @port,
              verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
          end
        extract(bytes, result)
        result
      end

      def send_group(requests : Array(Bytes)) : Array(Result)
        if reason = group_refusal(requests)
          return requests.map { Result.new(Bytes.new(0), nil, nil, 0_i64, reason) }
        end
        requests = requests.map { |b| Gori::Env.expand_bindings(b) }
        results = Engine.send_pipeline(requests, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
        # A group is ONE connection carrying a deliberate sequence, so every member is as
        # hand-authored as a lone `send` and every response is an equally legitimate source.
        # Later members win on a name both write, which is the wire order.
        requests.each_with_index { |b, i| results[i]?.try { |r| extract(b, r) } }
        results
      end

      def send_ws(upgrade : Bytes, messages : Array(WsEngine::OutMsg),
                  idle : Time::Span = WsEngine::DEFAULT_IDLE) : WsEngine::Result
        if reason = refusal(upgrade)
          return WsEngine::Result.new(Bytes.new(0), [] of WsEngine::Message, 0_i64, reason)
        end
        # EXTRACTION is handshake-only — a WS frame is not an HTTP response and `TokenExtract`'s
        # five descriptors are all defined over one. INJECTION is not: the messages carry
        # `$NAME` as readily as the handshake does, the proxy's own WS path already resolves it
        # (`Rules` `RulePart::Ws`), and every surface that builds these frames runs `Env.expand`
        # over them — which by design covers env vars and NOT bindings. So a `$SESSION` in a
        # frame went out as those seven characters with the name bound, and with it unbound
        # there was no refusal either: exactly the failure #519/#525 exist to stop, on the one
        # send path that had neither half.
        if reason = ws_message_refusal(messages)
          return WsEngine::Result.new(Bytes.new(0), [] of WsEngine::Message, 0_i64, reason)
        end
        WsEngine.send(Gori::Env.expand_bindings(upgrade), expand_messages(messages),
          scheme: @scheme, host: @host, port: @port, verify_upstream: @verify, sni: @sni,
          idle: idle, overrides: @overrides)
      end

      # The first declared-but-unbound name across the outgoing frames, as a refusal.
      private def ws_message_refusal(messages : Array(WsEngine::OutMsg)) : String?
        messages.each do |m|
          unbound = Gori::Env.unbound(m.payload)
          return Gori::Env.unbound_error(unbound) if unbound.present?
        end
        nil
      end

      # Whole payload, not `expand_bindings`' head/body split: a WS frame has no head to take,
      # so nothing here is a message boundary and the value goes in as it was observed.
      private def expand_messages(messages : Array(WsEngine::OutMsg)) : Array(WsEngine::OutMsg)
        messages.map do |m|
          expanded = Gori::Env.expand_bindings(String.new(m.payload), guard_boundary: false).to_slice
          expanded == m.payload ? m : WsEngine::OutMsg.new(m.opcode, expanded)
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
        line = String.new(request).each_line.first? || ""
        parts = line.split
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
