module Gori
  module Probe
    module Active
      # A response used as differential evidence must be a complete, non-timeout exchange. A
      # timed-out Result can still be `ok?` and can carry a plausible status/body prefix, but that
      # prefix is not a trustworthy baseline or bypass fingerprint. Keeping this predicate here
      # makes the safety boundary shared by the differential rules instead of letting one of them
      # forget the timeout half of the contract.
      module Evidence
        def self.complete?(result : Repeater::Result) : Bool
          result.ok? && !result.incomplete? && !result.timed_out?
        end
      end
    end
  end
end
