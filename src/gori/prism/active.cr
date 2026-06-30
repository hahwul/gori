require "./active/types"
require "./active/reflected_param"

module Gori
  module Prism
    # The lightweight active scanner. Each check is a self-contained `Active::Rule` in its own
    # file under `active/`; the analyzer iterates RULES, sending each rule's probe and folding
    # its detections. To add a check: drop a new `Rule` subclass in `active/` and append it here.
    module Active
      # The primary rule, reused for the registry AND the module-level facade.
      PRIMARY = ReflectedParam.new

      RULES = [PRIMARY] of Rule

      # Convenience facade over the primary (reflected-param) rule. The analyzer drives the
      # whole RULES list; these keep a stable single-rule entry point for callers/tests.
      def self.plan(detail : Store::FlowDetail) : Plan?
        PRIMARY.plan(detail)
      end

      def self.detections(plan : Plan, result : Replay::Result, detail : Store::FlowDetail) : Array(Detection)
        PRIMARY.detections(plan, result, detail)
      end
    end
  end
end
