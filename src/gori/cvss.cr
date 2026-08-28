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

      if vec = ::CVSS.parse?(trimmed) || ::CVSS.parse?(trimmed.upcase)
        score = vec.base_score
        sev = Store::Severity.new(vec.severity.value)
        return {score, sev, vec.to_s}
      end

      if (score = trimmed.to_f?) && score.finite? && (0.0 <= score <= 10.0)
        sev = Store::Severity.new(::CVSS::Severity.from_score(score).value)
        return {score, sev, trimmed}
      end

      nil
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
  end
end
