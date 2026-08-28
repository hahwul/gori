require "cvss"
require "./store/models"

module Gori
  # CVSS parsing, scoring, and severity resolution for Issues (#575).
  # Wraps hahwul/cvss.cr to handle both vector strings (v1..v4) and numeric scores.
  module Cvss
    # Everything derivable from one CVSS string, from ONE parse:
    # {score, severity, canonical form, was it a vector?}. Returns nil if the input is blank
    # or scores as nothing.
    #
    # One entry point because `::CVSS.parse?` is `rescue`-based — a bare score like `"9.8"`
    # runs the parser to a raise and unwinds it, TWICE (the plain string and the `upcase`
    # retry) — and the callers ask several questions about the same value. `Store::Issue`
    # asks at construction and keeps the answers; a per-question helper meant the Issues
    # list re-ran that pair for every visible row on every repaint and `cvss:` re-ran it for
    # every issue on every keystroke in the filter bar.
    #
    # The fourth member is what separates `"8.8"` from a vector, which Markdown export needs
    # and which no amount of squinting at the canonical string answers (`"8.8"` canonicalises
    # to itself).
    def self.read(input : String) : {Float64, Store::Severity, String, Bool}?
      trimmed = input.strip
      return nil if trimmed.empty?

      if vec = parse(trimmed)
        return {vec.base_score, severity_of(vec.severity), vec.to_s, true}
      end

      if (score = trimmed.to_f?) && score.finite? && (0.0 <= score <= 10.0)
        sev = severity_of(::CVSS::Severity.from_score(score))
        return {score, sev, trimmed, false}
      end

      nil
    end

    # Resolves a vector string or numeric score into {score, severity, canonical_string}.
    # Returns nil if input is blank or unparseable.
    def self.resolve(input : String) : {Float64, Store::Severity, String}?
      read(input).try { |r| {r[0], r[1], r[2]} }
    end

    # The form this value is STORED in: the shard's canonical vector (metrics in spec order,
    # uppercase keys and values, every temporal/threat/environmental metric preserved), or a
    # bare score unchanged. nil when the input scores as nothing.
    #
    # Two operators filing the same finding must not leave two different byte strings in the
    # column — one typing the lowercase form a scanner emitted and one the uppercase — because
    # every export prints the string verbatim and anything downstream keyed on it then sees
    # two values for one vector. `resolve` computed this from the start and every caller threw
    # it away; `Store#insert_issue`/`#update_issues` apply it now, at the one point no write
    # path can go around.
    def self.canonical(input : String) : String?
      read(input).try &.[2]
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
      !read(input).nil?
    end

    def self.severity_for(input : String) : Store::Severity?
      read(input).try &.[1]
    end

    def self.score_for(input : String) : Float64?
      read(input).try &.[0]
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
