require "./issue"
require "./passive/context"
require "./passive/rule"
require "./passive/tech"
require "./passive/secret_in_url"
require "./passive/security_headers"
require "./passive/cacheable_api"
require "./passive/cookies"
require "./passive/cors"
require "./passive/body_leaks"
require "./passive/auth"
require "./passive/graphql"
require "./passive/jwt"
require "./passive/sourcemap"
require "./passive/sri"
require "./passive/directory_listing"
require "./passive/ws_payloads"
require "./passive/secrets"
require "./passive/js_scan"
require "./passive/dom_xss"
require "./passive/dom_clobbering"
require "./passive/prototype_pollution"
require "./passive/post_message"
require "./custom_rule"

module Gori
  module Probe
    # Zero-request passive checks over a single captured flow. Pure: depends only on the codec,
    # the body decoder, and the protocol detectors — no Store/Scope/TUI. Each check is a self-
    # contained `Passive::Rule` in its own file under `passive/`; `analyze` parses the flow once
    # (Context) and runs every registered rule, returning the raw Detections. The analyzer folds
    # them into grouped Store::ProbeIssue rows.
    #
    # To add a check: drop a new `Rule` subclass in `passive/` and append it to RULES.
    module Passive
      RULES = [
        Tech.new,
        SecretInUrl.new,
        SecurityHeaders.new,
        CacheableApi.new,
        Cookies.new,
        Cors.new,
        BodyLeaks.new,
        Auth.new,
        GraphqlIntrospection.new,
        JwtWeaknesses.new,
        SourceMap.new,
        Sri.new,
        DirectoryListing.new,
        WsPayloads.new,
        DomXss.new,
        DomClobbering.new,
        PrototypePollution.new,
        PostMessage.new,
      ] of Rule

      # WS-only subset used when a flow was already fully analyzed and new WebSocket frames arrive.
      WS_RULES = [WsPayloads.new] of Rule

      # Shared read-only defaults so the common no-config call path (CLI / Repeater / tests) never
      # allocates. The analyzer passes its own live sets. Callers MUST NOT mutate these.
      NO_DISABLED = Set(String).new
      NO_CUSTOM   = [] of CustomRule

      # `disabled` holds RuleInfo#id values the operator switched off in the Rules sub-tab (skipped
      # here); `custom` are the merged global+project user match rules, run after the built-ins.
      # A SHORT-CIRCUITED flow is refused outright (#511): gori wrote that response itself from
      # a Match&Replace stub, so every passive rule here would be reading the operator's own
      # bytes and reporting them as a property of the target. That is the `probe-rule-fp-review`
      # lesson — a probe that cannot see its own signal must refuse — and it is enforced at BOTH
      # analyze entry points rather than at the callers, because `Analyzer#scan_detail` and
      # `Probe::Scan` reach them by different routes.
      def self.analyze(detail : Store::FlowDetail,
                       ws_messages : Array(Store::WsMessage) = [] of Store::WsMessage,
                       *, disabled : Set(String) = NO_DISABLED,
                       custom : Array(CustomRule) = NO_CUSTOM) : Array(Detection)
        return [] of Detection if detail.row.short_circuited?
        ctx = Context.new(detail, ws_messages)
        acc = [] of Detection
        RULES.each { |r| r.check(ctx, acc) unless disabled.includes?(r.info.id) }
        custom.each(&.check(ctx, acc))
        acc
      end

      # Re-scan only WebSocket text payloads (cheap path for post-101 message events). Custom rules
      # are HTTP-only, so only the (single) WS built-in participates, gated by the disabled set.
      def self.analyze_ws(detail : Store::FlowDetail,
                          ws_messages : Array(Store::WsMessage),
                          *, disabled : Set(String) = NO_DISABLED) : Array(Detection)
        return [] of Detection if ws_messages.empty? || detail.row.short_circuited?
        ctx = Context.new(detail, ws_messages)
        acc = [] of Detection
        WS_RULES.each { |r| r.check(ctx, acc) unless disabled.includes?(r.info.id) }
        acc
      end
    end
  end
end
