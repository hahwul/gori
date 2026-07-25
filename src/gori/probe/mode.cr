module Gori
  # Probe — the passive + lightweight-active scanner. It analyzes proxied traffic as it is
  # captured (zero-request passive checks) and, when armed, confirms reflected parameters
  # with a handful of in-scope probes. Issues are GROUPED by (code, host) into
  # Store::ProbeIssue rows; technology fingerprints (category "tech") double as the
  # project's "representative technologies" surfaced in the Project tab.
  #
  # Headless-friendly: the engine (passive/active) has no TUI dependency, so the analyzer
  # runs for both the TUI and `gori run capture`. Only the analyzer touches Store/Scope.
  module Probe
    # The `settings`-table key holding the per-project Mode (stored as its label).
    MODE_SETTING_KEY = "probe_mode"

    # Per-project scanning mode. Off = no analysis at all; Passive = zero-request checks on
    # observed traffic (the safe default); Active = Passive plus a set of light-touch probes
    # (reflected params today) over hosts/paths covered by Project scope rules only — the ⇧S
    # display lens need not be on; one probe per unique target. Keep Active DELIBERATELY quiet:
    # safe-method only, low-volume (a handful of confirming probes), one probe per unique target.
    #
    # Aggressive = Active's sanctioned louder tier for AUTHORIZED targets: raised per-rule caps
    # (wider param sets), a wider bypass-header set, and — unlike Active — it also probes
    # UNSAFE methods (POST/PUT/PATCH/DELETE), so an in-scope endpoint can be state-mutated by the
    # automatic pipeline. It is still Project-scope-gated (never widens scope) and still "more of
    # the same probes with relaxed caps", NOT an unbounded flood of attack payloads.
    enum Mode
      Off
      Passive
      Active
      Aggressive

      def label : String
        to_s.downcase
      end

      def title : String
        to_s.upcase
      end

      # Any analysis at all (Passive OR Active OR Aggressive). `passive?`/`active?`/`aggressive?`/
      # `off?` are the auto-generated exact-member predicates.
      def scanning? : Bool
        !off?
      end

      # Whether this mode drives the AUTOMATIC active-probe pipeline (enqueue + backfill). Active
      # and Aggressive both do; the difference is the Options they run with, not whether they run.
      def probes_actively? : Bool
        active? || aggressive?
      end

      # Parse a stored label back to a Mode; unknown/nil → Passive (the safe, zero-request
      # default so a fresh project scans passively out of the box).
      def self.from_setting(value : String?) : Mode
        case value
        when "off"        then Off
        when "active"     then Active
        when "aggressive" then Aggressive
        else                   Passive
        end
      end

      # Next mode in the OFF → Passive → Active → Aggressive → OFF cycle (the `m` key affordance).
      def cycle : Mode
        case self
        in Off        then Passive
        in Passive    then Active
        in Active     then Aggressive
        in Aggressive then Off
        end
      end
    end
  end
end
