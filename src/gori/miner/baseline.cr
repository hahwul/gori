require "../tolerance"
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
    # A location's calibrated comparison.
    #
    # `probe` is a control response: `width` bogus names — parameters no application has ever
    # heard of — each `name_len` bytes long. Every probe the run then sends at that location is
    # padded to the same width (`Engine#pad_pairs`), so whatever the page does ABOUT being
    # handed unknown parameters is present on both sides of the diff and cancels. What is left
    # is what the candidate itself did.
    #
    # `echo` is how many bytes of response the page returns per byte of parameter NAME it was
    # handed — measured from two controls of the same width whose names are different lengths.
    # It is 0 for a page that does not print what it received and ~1 for one that does, and it
    # is the only honest way to compare a byte COUNT against a control whose names gori chose:
    # the difference in name bytes is a difference the miner created, so the length band is
    # widened by `echo × those bytes` and only a move bigger than that counts as signal.
    # `length_tol`/`words_tol`/`lines_tol` are the bands to judge a probe against WHEN THIS IS
    # THE ANCHOR, and they are not the report's: the report's come from `stability_rounds`
    # copies of the untouched request, which is not the jitter of a page that is reacting to
    # a bucket of unknown parameters. They are measured from two identical-width controls, so
    # a page whose reaction wobbles is absorbed instead of being reported once per bucket.
    record Reference,
      probe : Probe,
      width : Int32,
      name_len : Int32,
      echo : Float64,
      length_tol : Int64,
      words_tol : Int32,
      lines_tol : Int32 do
      # The control's total injected name bytes — the reference point `byte_delta` is measured
      # from (see `Engine#byte_delta`).
      def name_bytes : Int32
        width * name_len
      end
    end

    # The control name lengths. The short one is close to the median parameter name, so the
    # byte delta a real bucket carries against the control is small; the long one is far enough
    # from it that a page which prints back what it received moves measurably between the two.
    CONTROL_NAME_LEN      =  8
    CONTROL_NAME_LEN_LONG = 24

    # A width the target REFUSES is not a width to mine at. When the control comes back with a
    # different status than the baseline, the request itself was rejected — a max_input_vars
    # ceiling, an oversized-header refusal, a WAF rule on parameter count — so the width is
    # halved and re-probed rather than handed to a run that would then bisect the refusal.
    # The floor is ONE candidate per request. That is the degenerate mine — as many requests as
    # there are names — but it is what a target with a tight parameter ceiling leaves, and it
    # is still cheaper and far more accurate than the alternative the miner had: send the
    # bucket anyway, read the refusal as a Status finding, and bisect it all the way down.
    #
    # The walk is bounded by the halving itself (a `Config` width is at most 1024, so at most
    # ten steps) rather than by a separate try count — a cap of its own has to be derived from
    # the ceiling or it silently stops short of the floor.
    MIN_CONTROL_WIDTH = 1

    # What `settle` learned about one location: the width to mine it at, the control probe it
    # ended on, the reference to diff against (nil = the plain baseline), and whether the
    # location must have its metric findings disabled — either because the target refuses every
    # width, or because its reaction to unknown parameters does not reproduce.
    record Settled,
      width : Int32,
      probe : Probe?,
      reference : Reference?,
      refused : Bool,
      mute : Bool = false do
      # Metric findings are meaningless here: there is no anchor this location can be compared
      # against. `refused` is the harder case of the same fact.
      def mute? : Bool
        mute || refused
      end
    end

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
      warning : String?,
      # Did ANY calibration probe come back? False means every stability round errored, so
      # every field above is a placeholder rather than a measurement — `status` is nil and the
      # three tolerances are 0. `decide` compares against those placeholders literally, so a
      # run that mined on one reported EVERY candidate as a Status finding (nil != 200) at full
      # bisection cost, with `errors: 0` and exit 0 behind it. There is no baseline here to
      # diff against; `Engine#orchestrate` refuses the run instead of inventing one.
      reachable : Bool = true,
      # The RAW send failure behind `reachable: false` (`connection refused`, a scope refusal),
      # unwrapped — `warning` is the sentence, this is the reason a consumer re-reports as its
      # own first error. nil whenever the baseline answered.
      error : String? = nil,
      # Per-location calibrated comparison — see `Reference`. Present only for a location that
      # reacts to unknown parameters REPRODUCIBLY; absent means either the location is calm
      # (diff against the plain baseline, as before) or it reacts unpredictably
      # (`reflection_only`, metric findings suppressed there).
      refs : Hash(Location, Reference) = Hash(Location, Reference).new,
      # How many candidate names one probe carries at each location. Calibrated, not merely
      # configured: a target that refuses a 128-parameter request is mined at a width it
      # accepts (see `calibrate`), instead of bisecting its own refusal 400 times.
      width : Hash(Location, Int32) = Hash(Location, Int32).new,
      # How the run had to be CALIBRATED, as distinct from what makes its findings tentative.
      # A location mined against a same-width control is a healthy mine — the surfaces render
      # `warning` with a ⚠ and the word "tentative", and saying that about a page whose only
      # sin is a "3 filters applied" counter would be false.
      note : String? = nil do
      def reachable? : Bool
        reachable
      end

      # How many candidate names one probe carries at `loc`. nil for a report that predates
      # the location (specs, an unreachable baseline) — the caller falls back to its config.
      def width_for(loc : Location) : Int32?
        width[loc]?
      end

      # The control to diff a probe at `loc` against, or nil to diff against the plain
      # baseline. Only a location that has one is padded (`Engine#pad_pairs`).
      def reference_for(loc : Location) : Reference?
        refs[loc]?
      end
    end

    # `stopped` is the engine's stop flag, read before every calibration probe. Calibration is
    # real requests at the target and it runs entirely inside one `calibrate` call, so without
    # it a ^X / `mine_stop` that lands after `orchestrate`'s own pre-flight check keeps the whole
    # stability + control wave going — the operator asked gori to stop touching the target and it
    # kept touching it. Defaults to "never stopped" so a caller that has no engine (specs, the
    # one-shot calibrate paths) is unchanged.
    # Locations whose control VALUES came back in the response — an echo API, where reflection
    # carries no discovery signal. Written by `control` at whatever width it ran at.
    @echoed : Hash(Location, Bool)

    def initialize(@backend : Fuzz::Backend, @base : Bytes, @config : Config,
                   @stopped : Proc(Bool) = -> { false })
      @echoed = Hash(Location, Bool).new
    end

    # `widths` is the bucket width the run wants to use at each location — the width this
    # calibration then CHECKS against the target and, where the target refuses it, lowers.
    #
    # The control bucket is sent at that width, not at a token 8. What a page does about eight
    # unknown parameters is not what it does about 128 of them: an origin that 400s an
    # oversized header set, a framework with a max_input_vars ceiling and a "N filters applied"
    # counter all read as calm at 8 and react at the width the run then mines with — so the
    # control answered a question nobody had asked, and every bucket of the run went on to
    # bisect a reaction the calibration had been shaped to miss.
    def calibrate(locations : Array(Location),
                  widths : Hash(Location, Int32) = Hash(Location, Int32).new) : Report
      rounds = {@config.stability_rounds, 1}.max
      # Calibration is pure round-trip time and it runs BEFORE a single candidate is tested,
      # so on a real target its cost is RTTs of dead air at the head of every mine — on a
      # 100ms origin that is most of a second before the run does anything. The probes do not
      # depend on each other (the stability rounds are N copies of the same request; the
      # controls are one independent bucket per location), so they all go out in ONE wave.
      #
      # They used to go in TWO, stability then controls, because the controls are JUDGED
      # against the tolerance the stability rounds establish. But judging is not sending: a
      # control's bytes do not depend on the bands, only its verdict does. One RTT, not two.
      #
      # Indexed writes, not appends: `probes.first` is the round the whole report is built
      # from, so the answer must not depend on which fiber finished first.
      slots = Array(Probe?).new(rounds, nil)
      controls = Array(Probe?).new(locations.size, nil)
      wide = locations.map { |loc| (widths[loc]? || 8).clamp(1, 1024) }
      # The first STABILITY round's failure reason, kept for the `unreachable` report: when NO
      # round answered, "baseline unreachable" alone sends the operator looking for a target
      # problem gori already has the name of (`connection refused`, a scope refusal, a
      # timeout). A control's failure is not that fact — it only costs the location its
      # reference, and the location is then mined against the plain baseline as before.
      first_error = nil.as(String?)
      in_parallel(rounds + locations.size) do |i|
        next if @stopped.call
        if i < rounds
          raw = send_with_retries(@base)
          if err = raw.error
            first_error ||= err
          else
            slots[i] = Fingerprint.probe(raw)
          end
        else
          j = i - rounds
          controls[j] = control(locations[j], wide[j], CONTROL_NAME_LEN)
        end
      end
      probes = slots.compact
      return unreachable(first_error) if probes.empty?

      base = probes.first
      lengths = probes.map(&.metrics.length)
      words = probes.map(&.metrics.words)
      lines = probes.map(&.metrics.lines)
      # Each band = 2× the observed calibration jitter, floored so a near-static page
      # still tolerates small natural churn. The floor is size-PROPORTIONAL for all three
      # metrics (not just length): a 50 KB / 8k-word page has word/line jitter that a fixed
      # floor of 3/2 is far too tight for, so an ad slot or a "results: N" counter tripped a
      # false Words/Lines finding while the proportional length band absorbed the same change.
      length_tol = Tolerance.band(lengths.min, lengths.max, base.metrics.length, Tolerance::LENGTH_FLOOR)
      words_tol = Tolerance.band(words.min, words.max, base.metrics.words, Tolerance::WORDS_FLOOR)
      lines_tol = Tolerance.band(lines.min, lines.max, base.metrics.lines, Tolerance::LINES_FLOOR)

      statuses = probes.compact_map(&.metrics.status).uniq!
      stable = statuses.size <= 1

      reflection_only = Hash(Location, Bool).new
      reflects_all = Hash(Location, Bool).new
      refs = Hash(Location, Reference).new
      width = Hash(Location, Int32).new
      # Each location refines ITSELF — the width walk and the second control are sequential
      # (each probe decides whether the next one is needed), but the locations are independent
      # of each other and go in parallel, as their first controls just did.
      settled = Array(Settled?).new(locations.size, nil)
      in_parallel(locations.size) do |j|
        settled[j] = settle(locations[j], wide[j], controls[j], base, length_tol, words_tol, lines_tol)
      end

      refused = [] of Location
      locations.each_with_index do |loc, j|
        outcome = settled[j] || Settled.new(wide[j], controls[j], nil, false)
        width[loc] = outcome.width
        if reference = outcome.reference
          refs[loc] = reference
        end
        reflection_only[loc] = outcome.mute?
        refused << loc if outcome.refused
        reflects_all[loc] = @echoed[loc]? || false
      end

      note = calibration_note(refs)
      Report.new(base.metrics.status, length_tol, words_tol, lines_tol,
        base.metrics.length, base.metrics.words, base.metrics.lines,
        stable, reflection_only, reflects_all,
        baseline_warning(stable, statuses, reflects_all, reflection_only, refused),
        reachable: true, refs: refs, width: width, note: note)
    end

    # Settle one location: find a width the target accepts, then decide whether the page's
    # reaction to unknown parameters there is reproducible enough to mine against. Returns
    # {width, the control probe at that width, the reference or nil, refused?}.
    private def settle(loc : Location, want : Int32, first : Probe?, base : Probe,
                       ltol : Int64, wtol : Int32, lntol : Int32) : Settled
      w, p, refused = accepted_width(loc, want, first, base)
      # A location that refuses every width gori tried cannot be compared against anything: its
      # control IS the refusal, and mining against that reads every ordinary 200 as a Status
      # finding — the whole wordlist reported as hidden parameters, at Confirmed confidence.
      # Say so and disable metric findings there, which is what the flag is for — and hand back
      # the width that was ASKED for, not the one the walk climbed down to. Metric findings are
      # off either way, so the narrow width buys nothing and costs everything: at width 1 a
      # 441-name wordlist is 441 refused requests instead of 4.
      return Settled.new(want, p, nil, true) if refused
      return Settled.new(w, p, nil, false) unless p
      return Settled.new(w, p, nil, false) unless reacts?(p, base, ltol, wtol, lntol)
      return Settled.new(w, p, nil, false) if @stopped.call

      # It reacts to SOMETHING. Two more controls at the same width answer what to do about it:
      #   twin — the same width AND the same name length, so its only difference from the first
      #     is time. It is the jitter of this page UNDER INJECTION, which is not the jitter the
      #     stability rounds measured, and it is the band every later probe is judged against.
      #   long — the same width with LONGER names, so the bytes it moves are what the page
      #     returns per byte of name it was handed (`echo`).
      twin = control(loc, w, CONTROL_NAME_LEN)
      return Settled.new(w, p, nil, false) unless twin
      # Counts that do not reproduce mean a metric diff here means nothing — the fallback this
      # flag has always been, now reached only when the reaction is genuinely unrepeatable.
      return Settled.new(w, p, nil, false, mute: true) unless consistent?(p, twin, wtol, lntol)

      bands = injected_bands(p, twin, ltol, wtol, lntol)
      # Re-ask the reaction question against the bands measured UNDER INJECTION. A page whose
      # only "reaction" was its own churn — a rotating element clearing a band that 4 samples
      # of a quiet page had underestimated — is not reacting, and locking a single noisy sample
      # in as the anchor for the whole run is strictly worse than the plain baseline it
      # replaces. A page that still differs is reacting structurally, in bytes or in counts.
      return Settled.new(w, p, nil, false) unless reacts?(p, base, *bands)
      return Settled.new(w, p, nil, false) if @stopped.call

      long = control(loc, w, CONTROL_NAME_LEN_LONG)
      echo = long ? echo_factor(p, long, w, bands[0]) : 0.0
      Settled.new(w, p, Reference.new(p, w, CONTROL_NAME_LEN, echo, *bands), false)
    end

    # {width, its control probe, still refused?}. Halve the width until the target stops
    # REFUSING the request: a status the baseline never returned means the request was
    # rejected, not that a parameter did something — a max_input_vars ceiling, an
    # oversized-header refusal, a WAF rule on parameter count — and every bucket of the run
    # would have been rejected the same way and then bisected down through its own 400s.
    #
    # A mismatch is CONFIRMED at the same width before the first halving. The width this
    # returns is the width the whole run buckets at, so one transient 502 on one probe would
    # otherwise collapse a 441-name mine from 4 requests to 441, permanently and silently.
    private def accepted_width(loc : Location, want : Int32,
                               first : Probe?, base : Probe) : {Int32, Probe?, Bool}
      w = want
      p = first
      return {w, p, false} unless p && p.metrics.status != base.metrics.status
      confirm = control(loc, w, CONTROL_NAME_LEN)
      return {w, confirm || p, false} unless confirm && confirm.metrics.status != base.metrics.status
      p = confirm
      while p && p.metrics.status != base.metrics.status && w > MIN_CONTROL_WIDTH
        break if @stopped.call
        w = {w // 2, MIN_CONTROL_WIDTH}.max
        p = control(loc, w, CONTROL_NAME_LEN)
      end
      {w, p, !p.nil? && p.metrics.status != base.metrics.status}
    end

    # The bands to judge a probe against when the location's control is the anchor: the
    # report's, widened to twice whatever two identical controls disagreed by. Two samples is
    # a thin estimate, which is why it only ever WIDENS — the report's band still applies as
    # the floor.
    private def injected_bands(a : Probe, b : Probe,
                               ltol : Int64, wtol : Int32, lntol : Int32) : {Int64, Int32, Int32}
      {
        {ltol, (a.metrics.length - b.metrics.length).abs * 2}.max,
        {wtol, (a.metrics.words - b.metrics.words).abs * 2}.max,
        {lntol, (a.metrics.lines - b.metrics.lines).abs * 2}.max,
      }
    end

    # How many bytes of response this page returns per byte of parameter NAME it was handed.
    #
    # The two controls differ by `span` bytes of name and by nothing else, so what the response
    # length does across them is what the page does with the names. A move inside the ordinary
    # band is not a move: the page does not print them back, this is 0, and the length metric
    # keeps its full sensitivity — the common case, and the one where a widened band would cost
    # real findings.
    private def echo_factor(a : Probe, b : Probe, width : Int32, ltol : Int64) : Float64
      span = (width * (CONTROL_NAME_LEN_LONG - CONTROL_NAME_LEN)).to_f
      moved = (b.metrics.length - a.metrics.length).abs
      return 0.0 unless span > 0 && moved > ltol
      (moved / span).clamp(0.0, 8.0)
    end

    # One control probe: `width` names no application has ever heard of, each `name_len` bytes,
    # each with its own canary value. nil when the send failed.
    private def control(loc : Location, width : Int32, name_len : Int32) : Probe?
      bogus = bogus_bucket(width, name_len)
      raw = send_with_retries(Inject.apply(@base, loc, bogus, @config.add_content_length_when_missing?))
      return nil unless raw.error.nil?
      probe = Fingerprint.probe(raw)
      # An endpoint that echoes its input does it at every width, so recording this as each
      # control lands (rather than re-deriving it from one of them) keeps the answer with the
      # bucket whose values it is actually about.
      @echoed[loc] = true if bogus.any? { |(_, value)| probe.reflects?(value) }
      probe
    end

    private def bogus_bucket(width : Int32, name_len : Int32) : Array({String, String})
      n = width.clamp(1, 1024)
      values = Canary.fresh_batch(n)
      # DISTINCT names, from one draw: a control that carries the same name twice is one
      # parameter narrower than every probe compared against it. See `Canary.bogus_batch`.
      names = Canary.bogus_batch(n, name_len)
      Array({String, String}).new(n) { |i| {names[i], values[i]} }
    end

    # Did the app answer a bucket of names it has never heard of differently at all? True ⇒ the
    # plain baseline is not a valid reference here. Asked TWICE in `settle`, first against the
    # bands the stability rounds measured and then against the bands two identical controls
    # measured under injection — the second is what tells a page's structural reaction apart
    # from its own churn.
    private def reacts?(p : Probe, base : Probe,
                        ltol : Int64, wtol : Int32, lntol : Int32) : Bool
      p.metrics.status != base.metrics.status ||
        (p.metrics.length - base.metrics.length).abs > ltol ||
        (p.metrics.words - base.metrics.words).abs > wtol ||
        (p.metrics.lines - base.metrics.lines).abs > lntol
    end

    # Do two same-width control buckets agree? On status and on the COUNT metrics only — the
    # two carry names of different lengths on purpose, so their byte counts are meant to
    # differ (that difference is what `echo` measures).
    private def consistent?(a : Probe, b : Probe, wtol : Int32, lntol : Int32) : Bool
      a.metrics.status == b.metrics.status &&
        (a.metrics.words - b.metrics.words).abs <= wtol &&
        (a.metrics.lines - b.metrics.lines).abs <= lntol
    end

    # Calibration was the miner's ONE un-retried send path, and an empty calibration is now
    # FATAL to the run (`Engine#orchestrate` refuses to mine against a `Report` of placeholders)
    # — so a blip that `@config.retries` absorbs anywhere else would have killed the whole run
    # rather than one bucket. It matters more here than anywhere else, not less: `in_parallel`
    # dispatches the stability wave CONCURRENTLY, so its probes are not independent samples in
    # time. One full accept backlog, TLS-handshake burst limit or ephemeral-port stall at t=0
    # fails every one of them at once, which is exactly the shape a retry exists for.
    #
    # Same rules as `Engine#send_with_retries`: a permanent refusal (budget spent, Layer 2 says
    # no) is not retried, and a stop ends the attempts — the operator asked gori to stop
    # touching the target, and a `retry_pause` nap followed by another probe is still touching it.
    private def send_with_retries(bytes : Bytes) : Repeater::Result
      attempts = 0
      loop do
        raw = @backend.send(bytes)
        return raw if raw.error.nil?
        return raw if attempts >= @config.retries || Miner.permanent_refusal?(raw.error) || @stopped.call
        attempts += 1
        sleep @config.retry_pause
      end
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

    # The purely informational half: the comparison changed shape, nothing is downgraded.
    private def calibration_note(refs : Hash(Location, Reference)) : String?
      return nil if refs.empty?
      "unknown parameters change the response at #{refs.keys.map(&.label).join("/")} — " \
      "mined against a same-width control"
    end

    private def baseline_warning(stable : Bool, statuses : Array(Int32),
                                 reflects_all : Hash(Location, Bool),
                                 reflection_only : Hash(Location, Bool),
                                 refused : Array(Location)) : String?
      # Only conditions that DOWNGRADE findings belong here (`confidence_for` reads the same
      # facts, and every surface renders this string as a warning). The comparison having
      # changed shape is not one of them — that is `calibration_note`.
      notes = [] of String
      notes << "baseline status varies (#{statuses.join("/")})" unless stable
      notes << "endpoint echoes input at some locations — reflection findings disabled there" if reflects_all.any? { |_, v| v }
      # A refusal is the harder half of `reflection_only` and deserves its own sentence: the
      # operator can act on "it rejects every width I tried" (raise --bucket's ceiling? mine a
      # different location?) and cannot act on "unpredictable".
      notes << "#{refused.map(&.label).join("/")} refuses every bucket width gori tried — metric findings disabled there" unless refused.empty?
      mute = (reflection_only.select { |_, v| v }.keys - refused)
      notes << "unknown parameters change the response unpredictably at #{mute.map(&.label).join("/")} — metric findings disabled there" unless mute.empty?
      return nil if notes.empty?
      "#{notes.join("; ")} — findings tentative"
    end

    # No round answered: `reachable: false` marks every field below it as a placeholder rather
    # than a measurement, which is what `Engine#orchestrate` refuses to mine against.
    private def unreachable(error : String? = nil) : Report
      Report.new(nil, 0_i64, 0, 0, 0_i64, 0, 0, false,
        Hash(Location, Bool).new, Hash(Location, Bool).new,
        error ? "baseline unreachable — #{error}" : "baseline unreachable",
        reachable: false, error: error)
    end
  end

  # Compare a probe to the baseline: which canaries reflected, and the strongest metric
  # diff (suppressed when the location is reflection-only).
  #
  # `reference`, when present, is the location's calibrated control — a bucket of bogus names
  # exactly as wide as every probe of this run (see `Baseline::Reference`). It replaces the
  # untouched baseline as the metric reference on a page that reacts to unknown parameters at
  # all, which is the ordinary case: a "3 filters applied" counter, a canonical link that
  # lists what was received, an error page that quotes the query. Against the plain baseline
  # those pages move on EVERY probe, which is why the location used to be written off
  # wholesale (`reflection_only`) and found nothing at all.
  #
  # `byte_delta` is how many more bytes of parameter NAME the probe carries than that control
  # (`Engine#byte_delta`), and it only matters for the length metric — see `strongest`.
  def self.decide(report : Baseline::Report, probe : Probe,
                  candidates : Array({String, String}), location : Location,
                  reference : Baseline::Reference? = nil, byte_delta : Int32 = 0) : Decision
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
      ref = reference.try(&.probe.metrics)
      kind = if m.status != (ref ? ref.status : report.status)
               DiffKind::Status
             else
               strongest(m, anchor_for(ref, report), bands_for(reference, report),
                 reference.try(&.echo), byte_delta)
             end
    end
    Decision.new(reflected, kind)
  end

  # The {length, words, lines} a probe is measured FROM: the location's control when there is
  # one, the untouched baseline otherwise.
  private def self.anchor_for(ref : Fuzz::Metrics?,
                              report : Baseline::Report) : {Int64, Int32, Int32}
    if r = ref
      {r.length, r.words, r.lines}
    else
      {report.base_length, report.base_words, report.base_lines}
    end
  end

  # The bands a probe at this location is judged against: the reference's when there is one
  # (measured from two identical controls, so they carry the page's jitter UNDER INJECTION),
  # the report's otherwise.
  private def self.bands_for(reference : Baseline::Reference?,
                             report : Baseline::Report) : {Int64, Int32, Int32}
    if r = reference
      {r.length_tol, r.words_tol, r.lines_tol}
    else
      {report.length_tol, report.words_tol, report.lines_tol}
    end
  end

  # The metric whose move is the LARGEST RELATIVE TO ITS OWN BAND, among those that moved
  # beyond it — not the first one in a fixed order, which is what this was.
  #
  # The bands differ per metric by design (bytes are noisier than lines), so a fixed
  # Length-then-Words-then-Lines order hands the verdict to whichever metric is NOISIEST.
  # Measured against a page with a 400-byte rotating element and a hidden parameter worth
  # +15 words / +5 lines: length randomly cleared its 358-byte band on ~40% of probes and the
  # bucket was reported as `Length` — a kind the isolated name then could not reproduce, so
  # `confirm` dropped a parameter both count metrics had identified unambiguously. Ratio
  # ordering picks Words (5x its band) over Length (1.2x) and the finding survives.
  #
  # Compared as cross-multiplied integers (`a/band_a > b/band_b` <=> `a*band_b > b*band_a`),
  # so there is no float and no divide-by-zero on a zero-width band. Ties keep the old order,
  # so a page whose metrics all move together reports exactly what it always did.
  private def self.strongest(m : Fuzz::Metrics, anchor : {Int64, Int32, Int32},
                             bands : {Int64, Int32, Int32}, echo : Float64?,
                             byte_delta : Int32) : DiffKind
    kind = DiffKind::None
    best_excess = 0_i64
    best_band = 1_i64

    # LENGTH against a control needs one correction the counts do not: the control's names are
    # gori's own bogus tokens, so on a page that prints back what it received the response's
    # byte count also moves by the difference between those names and the candidates' — a
    # difference the MINER chose, not one the target revealed. `echo` is how many bytes of
    # response that page returns per byte of name (measured from two controls of the same
    # width and different name lengths: 0 for a page that prints nothing back, ~1 for one that
    # does), so the band absorbs exactly that much and no more. Off a plain baseline the
    # correction is zero and this is the comparison it always was.
    d = (m.length - anchor[0]).abs
    band = bands[0] + (echo ? (echo * byte_delta.abs).ceil.to_i64 : 0_i64)
    if d > band
      kind, best_excess, best_band = DiffKind::Length, d, {band, 1_i64}.max
    end

    wd = (m.words - anchor[1]).abs.to_i64
    if wd > bands[1]
      wband = {bands[1].to_i64, 1_i64}.max
      if wd * best_band > best_excess * wband
        kind, best_excess, best_band = DiffKind::Words, wd, wband
      end
    end

    ld = (m.lines - anchor[2]).abs.to_i64
    if ld > bands[2]
      lband = {bands[2].to_i64, 1_i64}.max
      kind = DiffKind::Lines if ld * best_band > best_excess * lband
    end
    kind
  end
end
