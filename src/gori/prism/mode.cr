module Gori
  # Prism — the passive + lightweight-active scanner. It analyzes proxied traffic as it is
  # captured (zero-request passive checks) and, when armed, confirms reflected parameters
  # with a handful of in-scope probes. Findings are GROUPED by (code, host) into
  # Store::PrismIssue rows; technology fingerprints (category "tech") double as the
  # project's "representative technologies" surfaced in the Project tab.
  #
  # Headless-friendly: the engine (passive/active) has no TUI dependency, so the analyzer
  # runs for both the TUI and `gori run capture`. Only the analyzer touches Store/Scope.
  module Prism
    # The `settings`-table key holding the per-project Mode (stored as its label).
    MODE_SETTING_KEY = "prism_mode"

    # Per-project scanning mode. Off = no analysis at all; Passive = zero-request checks on
    # observed traffic (the safe default); Active = Passive plus the lightweight reflected-
    # params probe (in-scope hosts only, one probe per unique target).
    enum Mode
      Off
      Passive
      Active

      def label : String
        to_s.downcase
      end

      def title : String
        to_s.upcase
      end

      # Any analysis at all (Passive OR Active). `passive?`/`active?`/`off?` are the
      # auto-generated exact-member predicates.
      def scanning? : Bool
        !off?
      end

      # Parse a stored label back to a Mode; unknown/nil → Passive (the safe, zero-request
      # default so a fresh project scans passively out of the box).
      def self.from_setting(value : String?) : Mode
        case value
        when "off"    then Off
        when "active" then Active
        else               Passive
        end
      end

      # Next mode in the OFF → Passive → Active → OFF cycle (the `m` key affordance).
      def cycle : Mode
        case self
        in Off     then Passive
        in Passive then Active
        in Active  then Off
        end
      end
    end
  end
end
