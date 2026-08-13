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

    # `stopped` is the engine's stop flag, read before every calibration probe. Calibration is
    # real requests at the target and it runs entirely inside one `calibrate` call, so without
    # it a ^X / `mine_stop` that lands after `orchestrate`'s own pre-flight check keeps the whole
    # stability + control wave going — the operator asked gori to stop touching the target and it
    # kept touching it. Defaults to "never stopped" so a caller that has no engine (specs, the
    # one-shot calibrate paths) is unchanged.
    def initialize(@backend : Fuzz::Backend, @base : Bytes, @config : Config,
                   @stopped : Proc(Bool) = -> { false })
    end

    def calibrate(locations : Array(Location)) : Report
      rounds = {@config.stability_rounds, 1}.max
      # Calibration is pure round-trip time and it runs BEFORE a single candidate is tested,
      # so on a real target its cost is `stability_rounds + locations` RTTs of dead air at the
      # head of every mine — on a 100ms origin that is most of a second before the run does
      # anything. The probes do not depend on each other (the stability rounds are N copies of
      # the same request; the controls are one independent bucket per location), so they go out
      # concurrently, in two waves: the tolerance bands the controls are judged against come
      # from the stability wave.
      #
      # Indexed writes, not appends: `probes.first` is the round the whole report is built
      # from, so the answer must not depend on which fiber finished first.
      slots = Array(Probe?).new(rounds, nil)
      in_parallel(rounds) do |i|
        next if @stopped.call
        raw = @backend.send(@base)
        slots[i] = Fingerprint.probe(raw) if raw.error.nil?
      end
      probes = slots.compact
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
      signals = Array({Bool, Bool}?).new(locations.size, nil)
      in_parallel(locations.size) do |i|
        next if @stopped.call
        signals[i] = control_signals(locations[i], base, length_tol, words_tol, lines_tol)
      end
      locations.each_with_index do |loc, i|
        reacts, echoes = signals[i] || {false, false}
        reflection_only[loc] = reacts
        reflects_all[loc] = echoes
      end

      Report.new(base.metrics.status, length_tol, words_tol, lines_tol,
        base.metrics.length, base.metrics.words, base.metrics.lines,
        stable, reflection_only, reflects_all, baseline_warning(stable, statuses, reflects_all))
    end

    # Call the block for `0...count` through at most `concurrency` fibers, and return only
    # once every call has finished.
    #
    # SEQUENTIAL when the run is paced (`--rate` / `--throttle`): calibration has never
    # charged itself against the pacer, which was invisible while it also sent one request at
    # a time. Firing `stability_rounds` at once would turn "1 request per second, please" into
    # a burst on the very first thing the target sees from a mine — the opposite of what the
    # operator asked for, and the calibration is a handful of requests either way.
    #
    # An exception inside the block is re-raised on THIS fiber rather than escaping on a
    # worker's: an unhandled exception in a spawned fiber takes the process down, and until
    # this ran concurrently every raise here landed inside `Engine#orchestrate`'s rescue and
    # became an ErrorEvent. The first one wins; the rest are already-failed work.
    private def in_parallel(count : Int32, &block : Int32 ->) : Nil
      return if count <= 0
      workers = {count, {@config.concurrency, 1}.max}.min
      workers = 1 if @config.rps || @config.throttle_ms
      if workers <= 1
        count.times { |i| block.call(i) }
        return
      end

      jobs = Channel(Int32).new
      done = Channel(Nil).new(workers)
      failure = nil.as(Exception?)
      workers.times do
        spawn(name: "miner-baseline") do
          while i = jobs.receive?
            begin
              block.call(i)
            rescue ex
              failure ||= ex
            end
          end
        ensure
          done.send(nil)
        end
      end
      count.times { |i| jobs.send(i) }
      jobs.close
      workers.times { done.receive }
      if ex = failure
        raise ex
      end
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
                  candidates : Array({String, String}), location : Location) : Decision
    reflected = Hash(String, String).new
    # Skip reflection detection on an echo endpoint (reflects ANY input): there every
    # candidate would "reflect", so it carries no discovery signal — only noise.
    unless report.reflects_all[location]?
      candidates.each do |(name, canary)|
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
