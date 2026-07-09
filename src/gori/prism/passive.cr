require "./issue"
require "./passive/context"
require "./passive/rule"
require "./passive/tech"
require "./passive/secret_in_url"
require "./passive/security_headers"
require "./passive/cookies"
require "./passive/cors"
require "./passive/body_leaks"
require "./passive/auth"
require "./passive/graphql"
require "./passive/ws_payloads"
require "./passive/secrets"

module Gori
  module Prism
    # Zero-request passive checks over a single captured flow. Pure: depends only on the codec,
    # the body decoder, and the protocol detectors — no Store/Scope/TUI. Each check is a self-
    # contained `Passive::Rule` in its own file under `passive/`; `analyze` parses the flow once
    # (Context) and runs every registered rule, returning the raw Detections. The analyzer folds
    # them into grouped Store::PrismIssue rows.
    #
    # To add a check: drop a new `Rule` subclass in `passive/` and append it to RULES.
    module Passive
      RULES = [
        Tech.new,
        SecretInUrl.new,
        SecurityHeaders.new,
        Cookies.new,
        Cors.new,
        BodyLeaks.new,
        Auth.new,
        GraphqlIntrospection.new,
        WsPayloads.new,
      ] of Rule

      # WS-only subset used when a flow was already fully analyzed and new WebSocket frames arrive.
      WS_RULES = [WsPayloads.new] of Rule

      def self.analyze(detail : Store::FlowDetail,
                       ws_messages : Array(Store::WsMessage) = [] of Store::WsMessage) : Array(Detection)
        ctx = Context.new(detail, ws_messages)
        acc = [] of Detection
        RULES.each(&.check(ctx, acc))
        acc
      end

      # Re-scan only WebSocket text payloads (cheap path for post-101 message events).
      def self.analyze_ws(detail : Store::FlowDetail,
                          ws_messages : Array(Store::WsMessage)) : Array(Detection)
        return [] of Detection if ws_messages.empty?
        ctx = Context.new(detail, ws_messages)
        acc = [] of Detection
        WS_RULES.each(&.check(ctx, acc))
        acc
      end
    end
  end
end
