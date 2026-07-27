require "./active/types"
require "./active/reflected_param"
require "./active/cors_reflection"
require "./active/forbidden_bypass"
require "./active/nginx_alias_traversal"
require "./active/backslash_powered"
require "./active/graphql_introspection"
require "./active/lfi_param_traversal"
require "./active/open_redirect"
require "./active/host_header_injection"
require "./active/crlf_injection"
require "./active/path_normalization_bypass"
require "./active/url_rewrite_bypass"
require "./active/ssti"
require "./active/nextjs_action_no_auth"
require "../outbound"
require "../scope"
require "../fuzz/engine"

module Gori
  module Probe
    # The lightweight active scanner. Each check is a self-contained `Active::Rule` in its own
    # file under `active/`; the analyzer iterates RULES, sending each rule's probe and folding
    # its detections. To add a check: drop a new `Rule` subclass in `active/` and append it here.
    module Active
      # The primary rule, reused for the registry AND the module-level facade.
      PRIMARY = ReflectedParam.new

      # The empty "nothing turned off" set — a shared constant so the `disabled` default in
      # .analyze does not allocate a Set per call. Mirrors Passive::NO_DISABLED (kept local so
      # active.cr need not require passive.cr).
      NO_DISABLED = Set(String).new

      RULES = [PRIMARY, CorsReflection.new, ForbiddenBypass.new,
               NginxAliasTraversal.new, BackslashPowered.new,
               GraphqlIntrospection.new, LfiParamTraversal.new,
               OpenRedirect.new, HostHeaderInjection.new,
               CrlfInjection.new, PathNormalizationBypass.new,
               UrlRewriteBypass.new, Ssti.new,
               NextjsActionNoAuth.new] of Rule

      # Convenience facade over the primary (reflected-param) rule. The analyzer drives the
      # whole RULES list; these keep a stable single-rule entry point for callers/tests.
      def self.dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
        PRIMARY.dedup_key(detail, opts)
      end

      def self.plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
        PRIMARY.plan(detail, opts)
      end

      def self.detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
        PRIMARY.detections(plan, result, detail)
      end

      # Compact per-flow request-count label for the Rules sub-tab + manual-run estimate:
      # "1 req/flow" for the fixed-cost rules, "3–7 req/flow" for the differential BackslashPowered.
      def self.estimate_label(rng : Range(Int32, Int32)) : String
        rng.begin == rng.end ? "#{rng.begin} req/flow" : "#{rng.begin}–#{rng.end} req/flow"
      end

      # Synchronously execute enabled Active rules against a flow (for headless / CLI scans).
      # `outbound` is the REQUIRED scope decision (Gori::Outbound): a Sandbox block or an
      # explicit exclude rule HARD-blocks the probe at the socket seam even when the caller
      # bypassed its own include gate (--allow-unscoped). Required rather than optional
      # precisely so a new caller cannot forget it.
      # `backend` overrides the default Fuzz::Sender so specs can drive the rules without a
      # socket; it is wrapped in Fuzz::GatedBackend so an injected backend is gated too.
      # `opts` widens the method gate / raises caps (manual unsafe opt-in, AGGRESSIVE mode).
      # `disabled` holds the RuleInfo#ids the operator turned off in the Rules sub-tab — the same
      # set the TUI analyzer filters on before enqueueing (analyzer.cr's maybe_enqueue_active), so
      # a headless scan honours that config too instead of silently running every built-in.
      def self.analyze(detail : Store::FlowDetail, verify_upstream : Bool = true,
                       timeout : Time::Span = 10.seconds, *, outbound : Outbound,
                       backend : Fuzz::Backend? = nil, opts : Options = Options::DEFAULT,
                       disabled : Set(String) = NO_DISABLED) : Array(Detection)
        out = [] of Detection
        row = detail.row
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = detail.http_version.starts_with?("HTTP/2")
        # Fuzz::Sender gates itself, so it is never double-wrapped; only an injected
        # backend needs GatedBackend to reach the same decision.
        sender = if base = backend
                   Fuzz::GatedBackend.new(base, outbound).as(Fuzz::Backend)
                 else
                   Fuzz::Sender.new(origin, outbound, http2, verify_upstream, timeout: timeout)
                 end

        RULES.each do |rule|
          next if disabled.includes?(rule.info.id)
          plan = rule.plan(detail, opts)
          next unless plan
          result = sender.send(plan.request)
          next unless result.ok?
          results = [result]
          plan.followups.each { |req| results << sender.send(req) }
          dets = rule.detections_all(plan, results, detail)
          out.concat(dets)
        end
        out
      end
    end
  end
end
