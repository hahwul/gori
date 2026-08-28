require "cvss"
require "./store/models"

module Gori
  # CVSS parsing, scoring, and severity resolution for Issues (#575).
  # Wraps hahwul/cvss.cr to handle both vector strings (v1..v4) and numeric scores.
  module Cvss
    # Resolves a vector string or numeric score into {score, severity, canonical_string}.
    # Returns nil if input is blank or unparseable.
    def self.resolve(input : String) : {Float64, Store::Severity, String}?
      trimmed = input.strip
      return nil if trimmed.empty?

      if vec = parse(trimmed)
        return {vec.base_score, severity_of(vec.severity), vec.to_s}
      end

      if (score = trimmed.to_f?) && score.finite? && (0.0 <= score <= 10.0)
        sev = severity_of(::CVSS::Severity.from_score(score))
        return {score, sev, trimmed}
      end

      nil
    end

    # The parsed vector, or nil when `input` is a bare score / not a vector at all. The
    # `upcase` retry is what lets an operator paste the lowercase form some scanners emit.
    def self.parse(input : String) : ::CVSS::Vector?
      trimmed = input.strip
      return nil if trimmed.empty?
      ::CVSS.parse?(trimmed) || ::CVSS.parse?(trimmed.upcase)
    end

    # Whether this string is something gori can score. THE gate every write path asks before
    # it stores an operator's (or an agent's) CVSS: a value that resolves to nothing is a
    # value the Issues list, the exports and `cvss:` queries would all silently skip, so the
    # surfaces refuse it at the boundary rather than persisting a field only the raw string
    # can see. Blank is NOT valid here — "clear it" is its own intent, spelled by the caller.
    def self.valid?(input : String) : Bool
      !resolve(input).nil?
    end

    def self.severity_for(input : String) : Store::Severity?
      resolve(input).try &.[1]
    end

    def self.score_for(input : String) : Float64?
      resolve(input).try &.[0]
    end

    # Qualitative label for a numeric score or vector string.
    def self.label_for(input : String) : String?
      severity_for(input).try(&.label)
    end

    # CVSS's own rating scale and the store's are the same five bands with one member
    # renamed (`None` ⇄ `Info`), so the mapping is one-to-one — but it used to ride on the
    # two enums' ORDINALS happening to line up (`Store::Severity.new(vec.severity.value)`).
    # That is the coupling this repo kills on sight: a member added to either enum
    # re-numbers the other's bands with no compiler help and no visible failure, just
    # issues filed one band off. As an exhaustive `case … in` the same edit stops the build.
    def self.severity_of(sev : ::CVSS::Severity) : Store::Severity
      case sev
      in .none?     then Store::Severity::Info
      in .low?      then Store::Severity::Low
      in .medium?   then Store::Severity::Medium
      in .high?     then Store::Severity::High
      in .critical? then Store::Severity::Critical
      end
    end
  end
end
