require "../outbound"
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

      # The reason this request may not go out, or nil to proceed. Sandbox mode is the only
      # rule that stops a deliberate single send (see `Outbound#send_block`).
      def refusal(bytes : Bytes) : String?
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(bytes))
      end

      def refusal(text : String) : String?
        @outbound.send_block(@scheme, @host, Gori::Outbound.request_target(text))
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
        if @http2
          H2Engine.send(bytes, scheme: @scheme, host: @host, port: @port,
            verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
        else
          Engine.send(bytes, scheme: @scheme, host: @host, port: @port,
            verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
        end
      end

      def send_group(requests : Array(Bytes)) : Array(Result)
        if reason = group_refusal(requests)
          return requests.map { Result.new(Bytes.new(0), nil, nil, 0_i64, reason) }
        end
        Engine.send_pipeline(requests, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
      end

      def send_ws(upgrade : Bytes, messages : Array(WsEngine::OutMsg),
                  idle : Time::Span = WsEngine::DEFAULT_IDLE) : WsEngine::Result
        if reason = refusal(upgrade)
          return WsEngine::Result.new(Bytes.new(0), [] of WsEngine::Message, 0_i64, reason)
        end
        WsEngine.send(upgrade, messages, scheme: @scheme, host: @host, port: @port,
          verify_upstream: @verify, sni: @sni, idle: idle, overrides: @overrides)
      end
    end
  end
end
