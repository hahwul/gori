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

  # Calibrates a stable baseline + two per-location controls — the false-positive killers.
  # Tolerance bands absorb timestamps / CSRF tokens. (1) A location that reacts metrically
  # to bogus params has its metric findings suppressed (`reflection_only`). (2) A location
  # that ECHOES bogus values back (an echo API like httpbin/get) has its REFLECTION findings
  # suppressed (`reflects_all`) — otherwise every random candidate "reflects" and floods the
  # results with false positives.
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
      reflects_all : Hash(Location, Bool),
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
      # Each band = 2× the observed calibration jitter, floored so a near-static page
      # still tolerates small natural churn. The floor is size-PROPORTIONAL for all three
      # metrics (not just length): a 50 KB / 8k-word page has word/line jitter that a fixed
      # floor of 3/2 is far too tight for, so an ad slot or a "results: N" counter tripped a
      # false Words/Lines finding while the proportional length band absorbed the same change.
      length_tol = {(lengths.max - lengths.min) * 2, {8_i64, base.metrics.length // 100}.max}.max
      words_tol = {(words.max - words.min) * 2, {3, base.metrics.words // 100}.max}.max
      lines_tol = {(lines.max - lines.min) * 2, {2, base.metrics.lines // 100}.max}.max

      statuses = probes.compact_map(&.metrics.status).uniq!
      stable = statuses.size <= 1

      reflection_only = Hash(Location, Bool).new
      reflects_all = Hash(Location, Bool).new
      locations.each do |loc|
        reacts, echoes = control_signals(loc, base, length_tol, words_tol, lines_tol)
        reflection_only[loc] = reacts
        reflects_all[loc] = echoes
      end

      Report.new(base.metrics.status, length_tol, words_tol, lines_tol,
        base.metrics.length, base.metrics.words, base.metrics.lines,
        stable, reflection_only, reflects_all, baseline_warning(stable, statuses, reflects_all))
    end

    # Inject a bucket of random non-existent names ONCE per location. Returns
    # {metric_reacts, reflects_all}:
    #   metric_reacts — the response moved beyond tolerance, so the app reacts to ANY
    #     unknown param here → its metric-diff findings are noise (suppressed in `decide`).
    #   reflects_all  — the bogus VALUES were echoed back, so the endpoint reflects ANY
    #     input (an echo API, e.g. httpbin/get) → reflection is not a discovery signal
    #     here and its reflection findings must be suppressed too, else every candidate
    #     "reflects" and the run floods with false positives.
    private def control_signals(loc : Location, base : Probe,
                                ltol : Int64, wtol : Int32, lntol : Int32) : {Bool, Bool}
      bogus = Array.new(8) { {Canary.bogus_name, Canary.fresh} }
      raw = @backend.send(Inject.apply(@base, loc, bogus, @config.add_content_length_when_missing?))
      return {false, false} unless raw.error.nil?
      p = Fingerprint.probe(raw)
      reacts = p.metrics.status != base.metrics.status ||
               (p.metrics.length - base.metrics.length).abs > ltol ||
               (p.metrics.words - base.metrics.words).abs > wtol ||
               (p.metrics.lines - base.metrics.lines).abs > lntol
      echoes = bogus.any? { |(_, value)| p.reflects?(value) }
      {reacts, echoes}
    end

    private def baseline_warning(stable : Bool, statuses : Array(Int32),
                                 reflects_all : Hash(Location, Bool)) : String?
      notes = [] of String
      notes << "baseline status varies (#{statuses.join("/")})" unless stable
      notes << "endpoint echoes input at some locations — reflection findings disabled there" if reflects_all.any? { |_, v| v }
      return nil if notes.empty?
      "#{notes.join("; ")} — findings tentative"
    end

    private def unreachable : Report
      Report.new(nil, 0_i64, 0, 0, 0_i64, 0, 0, false,
        Hash(Location, Bool).new, Hash(Location, Bool).new, "baseline unreachable")
    end
  end

  # Compare a probe to the baseline: which canaries reflected, and the strongest metric
  # diff (suppressed when the location is reflection-only).
  def self.decide(report : Baseline::Report, probe : Probe,
                  canaries_inv : Hash(String, String), location : Location) : Decision
    reflected = Hash(String, String).new
    # Skip reflection detection on an echo endpoint (reflects ANY input): there every
    # candidate would "reflect", so it carries no discovery signal — only noise.
    unless report.reflects_all[location]?
      canaries_inv.each do |canary, name|
        reflected[canary] = name if probe.reflects?(canary)
      end
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
