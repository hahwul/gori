require "./types"
require "./inject"
require "./fingerprint"
require "../fuzz/engine"

module Gori::Miner
  # The strongest non-reflective signal a response carries vs the baseline.
  enum DiffKind
    None
    Status
    Length
    Words
    Lines
  end

  # The result of comparing one response to the calibrated baseline.
  record Decision,
    reflected : Hash(String, String), # canary => name (echoed canaries)
    kind : DiffKind                   # strongest metric diff, else None

  # Calibrates a stable baseline + a per-location "does it react to ANY unknown param?"
  # control — the two false-positive killers. Tolerance bands absorb timestamps / CSRF
  # tokens; a location that reacts to bogus params has its metric findings suppressed
  # (reflection still counts there).
  class Baseline
    record Report,
      status : Int32?,
      length_tol : Int64,
      words_tol : Int32,
      lines_tol : Int32,
      base_length : Int64,
      base_words : Int32,
      base_lines : Int32,
      stable : Bool,
      reflection_only : Hash(Location, Bool),
      warning : String?

    def initialize(@backend : Fuzz::Backend, @base : Bytes, @config : Config)
    end

    def calibrate(locations : Array(Location)) : Report
      probes = [] of Probe
      rounds = {@config.stability_rounds, 1}.max
      rounds.times do
        raw = @backend.send(@base)
        probes << Fingerprint.probe(raw) if raw.error.nil?
      end
      return unreachable if probes.empty?

      base = probes.first
      lengths = probes.map(&.metrics.length)
      words = probes.map(&.metrics.words)
      lines = probes.map(&.metrics.lines)
      length_tol = {(lengths.max - lengths.min) * 2, {8_i64, base.metrics.length // 100}.max}.max
      words_tol = {(words.max - words.min) * 2, 3}.max
      lines_tol = {(lines.max - lines.min) * 2, 2}.max

      statuses = probes.compact_map(&.metrics.status).uniq!
      stable = statuses.size <= 1
      warning = stable ? nil : "baseline status varies (#{statuses.join("/")}) — findings tentative"

      reflection_only = Hash(Location, Bool).new
      locations.each do |loc|
        reflection_only[loc] = control_reacts?(loc, base, length_tol, words_tol, lines_tol)
      end

      Report.new(base.metrics.status, length_tol, words_tol, lines_tol,
        base.metrics.length, base.metrics.words, base.metrics.lines,
        stable, reflection_only, warning)
    end

    # Inject a bucket of random non-existent names; if the response moves beyond
    # tolerance, the app reacts to ANY unknown param at this location.
    private def control_reacts?(loc : Location, base : Probe,
                                ltol : Int64, wtol : Int32, lntol : Int32) : Bool
      bogus = Array.new(8) { {Canary.bogus_name, Canary.fresh} }
      raw = @backend.send(Inject.apply(@base, loc, bogus, @config.add_content_length_when_missing?))
      return false unless raw.error.nil?
      p = Fingerprint.probe(raw)
      return true if p.metrics.status != base.metrics.status
      return true if (p.metrics.length - base.metrics.length).abs > ltol
      return true if (p.metrics.words - base.metrics.words).abs > wtol
      return true if (p.metrics.lines - base.metrics.lines).abs > lntol
      false
    end

    private def unreachable : Report
      Report.new(nil, 0_i64, 0, 0, 0_i64, 0, 0, false, Hash(Location, Bool).new, "baseline unreachable")
    end
  end

  # Compare a probe to the baseline: which canaries reflected, and the strongest metric
  # diff (suppressed when the location is reflection-only).
  def self.decide(report : Baseline::Report, probe : Probe,
                  canaries_inv : Hash(String, String), location : Location) : Decision
    reflected = Hash(String, String).new
    canaries_inv.each do |canary, name|
      reflected[canary] = name if probe.body_text.includes?(canary) || probe.head_text.includes?(canary)
    end
    kind = DiffKind::None
    unless report.reflection_only[location]?
      m = probe.metrics
      kind = if m.status != report.status
               DiffKind::Status
             elsif (m.length - report.base_length).abs > report.length_tol
               DiffKind::Length
             elsif (m.words - report.base_words).abs > report.words_tol
               DiffKind::Words
             elsif (m.lines - report.base_lines).abs > report.lines_tol
               DiffKind::Lines
             else
               DiffKind::None
             end
    end
    Decision.new(reflected, kind)
  end
end
