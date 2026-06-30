require "./issue"
require "./passive/context"
require "./passive/rule"
require "./passive/tech"
require "./passive/secret_in_url"
require "./passive/security_headers"
require "./passive/cookies"
require "./passive/cors"
require "./passive/body_leaks"

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
      ] of Rule

      def self.analyze(detail : Store::FlowDetail) : Array(Detection)
        ctx = Context.new(detail)
        acc = [] of Detection
        RULES.each(&.check(ctx, acc))
        acc
      end
    end
  end
end
