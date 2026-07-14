require "../issue"
require "./context"

module Gori
  module Probe
    module Passive
      # A passive rule: pure, zero-request analysis of one captured flow. Each rule appends its
      # Detections to `acc`. Rules self-gate (e.g. `return unless resp = ctx.response`), so the
      # orchestrator just runs every registered rule in order. One rule per file under
      # `passive/`; register new ones in `Passive::RULES` (passive.cr).
      abstract class Rule
        abstract def check(ctx : Context, acc : Array(Detection)) : Nil
      end
    end
  end
end
