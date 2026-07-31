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
      # "1 req/flow" for the fixed-cost rules, "4–8 req/flow" for the differential BackslashPowered.
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
      # `on_error` (optional) is called with the failing rule's id when a rule raises; see the
      # per-rule rescue below for why that isolation exists at all.
      def self.analyze(detail : Store::FlowDetail, verify_upstream : Bool = true,
                       timeout : Time::Span = 10.seconds, *, outbound : Outbound,
                       backend : Fuzz::Backend? = nil, opts : Options = Options::DEFAULT,
                       disabled : Set(String) = NO_DISABLED,
                       on_error : Proc(String, Exception, Nil)? = nil) : Array(Detection)
        # A short-circuited flow is refused before a single probe is sent (#511). Its baseline
        # response came from a Match&Replace stub, not from the origin, so every differential
        # this builds would be measuring the rule — and the probes themselves WOULD reach the
        # origin (Active dials directly, not through the proxy), so the comparison is between
        # two different responders. Same refusal, same reason, as `Passive.analyze`.
        return [] of Detection if detail.row.short_circuited?
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

        # Send-refusal reasons already reported for THIS flow (see the `result.ok?` branch).
        refusals = Set(String).new
        RULES.each do |rule|
          next if disabled.includes?(rule.info.id)
          # ISOLATE each rule. Without this, one rule raising in plan/detections_all took down
          # the whole scan — every rule after it AND (via Scan.scan_flows) every remaining flow,
          # discarding findings already collected. The TUI path has always had this: the analyzer
          # wraps each rule in its own rescue (analyzer.cr's execute_active), so the same rule
          # that merely gets skipped in the TUI used to kill a `gori run probe` / MCP probe_scan
          # batch outright. Send FAILURES are not exceptions (Fuzz returns an errored Result and
          # `result.ok?` skips), so what this catches is a rule bug on hostile input.
          begin
            plan = rule.plan(detail, opts)
            next unless plan
            result = sender.send(plan.request)
            unless result.ok?
              # A refused or failed send is NOT an exception — `Fuzz::Sender` returns an
              # errored Result for a sandbox block, an unbound binding, a connect failure —
              # so the rescue below cannot see it and `next` alone made it invisible. With
              # Sandbox on and nothing in scope, EVERY probe was refused and the operator
              # read `0 issues` / MCP emitted no `scan_errors` key at all: indistinguishable
              # from a clean target. `Miner::Engine#first_error` and the TUI analyzer's
              # `emit_active_error` both name this; probe active is the one automated sweep
              # that never got the #491 treatment.
              #
              # Deduped per flow per reason: 14 rules refused for the same cause would
              # otherwise push 14 identical rows at the caller for one flow.
              err = result.error
              if err && refusals.add?(err)
                on_error.try &.call("flow #{row.id}", Gori::Error.new(err))
              end
              next
            end
            results = [result]
            plan.followups.each { |req| results << sender.send(req) }
            dets = rule.detections_all(plan, results, detail)
            out.concat(dets)
          rescue ex
            on_error.try &.call(rule.info.id, ex)
          end
        end
        out
      end
    end
  end
end
