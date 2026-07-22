require "./active/types"
require "./active/reflected_param"
require "./active/cors_reflection"
require "./active/forbidden_bypass"
require "./active/nginx_alias_traversal"
require "./active/backslash_powered"

module Gori
  module Probe
    # The lightweight active scanner. Each check is a self-contained `Active::Rule` in its own
    # file under `active/`; the analyzer iterates RULES, sending each rule's probe and folding
    # its detections. To add a check: drop a new `Rule` subclass in `active/` and append it here.
    module Active
      # The primary rule, reused for the registry AND the module-level facade.
      PRIMARY = ReflectedParam.new

      RULES = [PRIMARY, CorsReflection.new, ForbiddenBypass.new,
               NginxAliasTraversal.new, BackslashPowered.new] of Rule

      # Convenience facade over the primary (reflected-param) rule. The analyzer drives the
      # whole RULES list; these keep a stable single-rule entry point for callers/tests.
      def self.dedup_key(detail : Store::FlowDetail) : String?
        PRIMARY.dedup_key(detail)
      end

      def self.plan(detail : Store::FlowDetail) : Plan?
        PRIMARY.plan(detail)
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
      def self.analyze(detail : Store::FlowDetail, verify_upstream : Bool = true,
                       timeout : Time::Span = 10.seconds) : Array(Detection)
        out = [] of Detection
        row = detail.row
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = detail.http_version.starts_with?("HTTP/2")
        sender = Fuzz::Sender.new(origin, http2, verify_upstream, timeout: timeout)

        RULES.each do |rule|
          plan = rule.plan(detail)
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
