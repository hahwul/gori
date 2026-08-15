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
require "./passive/exposed_config"
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
        ExposedConfig.new,
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

      # `disabled` records the operator's DEVIATION FROM DEFAULT, not a plain "off" list, so it is
      # read through `Probe.rule_disabled?` — the same helper the active path, the analyzer and the
      # headless scan use. A bare `disabled.includes?` was correct only by accident: membership
      # FLIPS meaning for `DEFAULT_DISABLED_RULES` ids, and today every one of those is an ACTIVE
      # rule, so no passive rule reached the branch where the two disagree. The first default-OFF
      # passive rule would have shipped silently dead for the operator who enabled it.
      # `custom` are the merged global+project user match rules, run after the built-ins.
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
        # Per-RULE containment, matching `Active.analyze`. Without it one rule raising on a
        # hostile body (a regex PCRE2 refuses, an unexpected shape) discarded the findings of
        # every rule after it in the list — the flow's whole scan was lost to one bad rule,
        # and which rules survived depended on their order. The raise was caught a layer up
        # (`Probe::Scan`, `supervise`), so this changes no crash behaviour; it changes how
        # much of the scan survives.
        RULES.each do |r|
          next if Probe.rule_disabled?(r.info.id, disabled)
          begin
            r.check(ctx, acc)
          rescue ex
            Log.debug(exception: ex) { "passive rule #{r.info.id} failed on flow #{detail.row.id}" }
          end
        end
        custom.each do |r|
          r.check(ctx, acc)
        rescue ex
          Log.debug(exception: ex) { "custom passive rule failed on flow #{detail.row.id}" }
        end
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
        WS_RULES.each { |r| r.check(ctx, acc) unless Probe.rule_disabled?(r.info.id, disabled) }
        acc
      end
    end
  end
end
