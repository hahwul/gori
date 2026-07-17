require "./active/types"
require "./active/reflected_param"
require "./active/cors_reflection"
require "./active/forbidden_bypass"

module Gori
  module Probe
    # The lightweight active scanner. Each check is a self-contained `Active::Rule` in its own
    # file under `active/`; the analyzer iterates RULES, sending each rule's probe and folding
    # its detections. To add a check: drop a new `Rule` subclass in `active/` and append it here.
    module Active
      # The primary rule, reused for the registry AND the module-level facade.
      PRIMARY = ReflectedParam.new

      RULES = [PRIMARY, CorsReflection.new, ForbiddenBypass.new] of Rule

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
    end
  end
end
