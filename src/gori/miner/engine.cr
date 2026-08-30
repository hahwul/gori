require "uri"
require "./types"
require "./inject"
require "./fingerprint"
require "./baseline"
require "../fuzz/engine"
require "../fuzz/matcher"
require "../pacing"

module Gori::Miner
  # Refusals no retry can change: the request budget is spent, or Layer 2 says no. Both are
  # decided from state that does not move between two calls a `retry_pause` apart, and the
  # Layer-2 half is `Outbound.permanent_refusal?` — ONE home for the rule, because an exclude
  # was once omitted from a private copy and an EXCLUDE_SWEEP_ERROR was then retried `retries`
  # times, burning the request cap and stalling the run for nothing.
  #
  # Module-level, and in THIS file, because the miner has TWO retry loops that must not drift —
  # `Engine#send_with_retries` and `Baseline#send_with_retries` (calibration) — and because
  # `spec/outbound_spec.cr`'s executable one-home guard reads `src/gori/<tool>/engine.cr` for
  # the call. Both loops ask this; neither names a refusal constant of its own.
  def self.permanent_refusal?(err : String?) : Bool
    return true if err.try(&.starts_with?(HookBackend::HOOK_ERROR_PREFIX))
    err == Fuzz::CappedBackend::CAP_ERROR || Gori::Outbound.permanent_refusal?(err)
  end

  # The hard-cap wrapper (baseline calibration + bucket probes + confirmation rounds all
  # count against `--max-requests`) lives with the send seam it wraps: Fuzz::CappedBackend.

  # Drives a parameter-mining run: calibrate a baseline, then for each location stuff
  # candidate names into buckets, diff vs baseline, and BISECT each interesting bucket
  # (into up to `BISECT_MAX_WAYS` sub-buckets, not just two — see `split`) to isolate the
  # responsible name. Concurrency = ONE work queue for the whole run, drained by a bounded
  # worker pool: every location's buckets go in together and a bisection's children are
  # pushed straight back, so nothing waits on a round barrier or on another location
  # finishing. See `drain`.
  #
  # Single-threaded fiber scheduler (no -Dpreview_mt): plain ivar increments and array
  # appends never yield mid-op, so the counters and per-round outcome array need no locks.
  class Engine
    # Outbound rate limiting (rps / throttle_ms / jitter_ms) over `@last_dispatch`.
    include Gori::Pacing

    MAX_CONCURRENCY = 100

    # Upper bound on the bisection branch factor — how many sub-buckets a positive bucket is
    # split into to isolate the responsible name (see `split`). 4 halves the tree DEPTH vs a
    # binary bisection and never costs more probes (measured: equal when a bucket holds ≤1
    # positive, −6%…−11% as it fills, because the pruning tree over K names has K·b/(b−1)
    # nodes — fewer as b grows). Higher than 4 keeps shrinking the count but the depth returns
    # flatten, so 4 is the knee. The effective factor is `min(this, concurrency)`, so a run
    # with fewer workers than this never splits wider than it can fill.
    BISECT_MAX_WAYS = 4

    # Per-request growth ceiling for the Json location. A JSON candidate is injected into EVERY
    # object node, so a deeply-nested body could otherwise balloon one request to megabytes; this
    # shrinks Json buckets (in initial_buckets) instead. A single-object body (node count 1) is
    # unaffected and buckets exactly as before.
    MAX_JSON_INJECT_BYTES = 128 * 1024

    enum State : UInt8
      Running
      Paused
      Stopped
    end

    # One unit of work: test these names at this location (a bucket, or a bisection half).
    record Task, location : Location, names : Array(String)

    getter events : Channel(Event)

    @concurrency : Int32
    @state : State
    @wake : Channel(Nil)
    @backend : Fuzz::CappedBackend
    @report : Baseline::Report?
    @seen : Set({Location, String})
    # Locations whose injector returned no spans at all — see `process_bucket`. One entry per
    # location, so the "nothing could be injected" verdict is reported once and not per bucket.
    @uninjectable : Set(Location)
    @found : Int32
    @errors : Int64
    @names_done : Int64
    @names_total : Int64
    @last_dispatch : Time::Instant
    # Buckets dispatched to a worker and not yet accounted for, and the 1-slot channel a
    # worker pokes when one lands. Together they are the mine's "is there still work?"
    # answer — see `drain` / `wait_for_worker`.
    @inflight : Int32
    @idle : Channel(Nil)
    # Per-location cache of the names the base request already carries — see `present_at`.
    @present : Hash(Location, Set(String))
    # Per-location caches of the name filtering, which is pure over `@names` + `@base`.
    @carriable : Hash(Location, Array(String))
    @valid : Hash(Location, Array(String))
    # Form-encoded byte size per candidate name — see `encoded_name_bytes`. Keyed by name
    # alone: query and form encode identically, and no other location encodes at all.
    @encoded : Hash(String, Int32)

    # The first per-send failure reason of the run. `@errors` counts refusals and drops the
    # string, which is how a scope-blocked run could report "0 found" and exit 0 with the
    # reason nowhere on screen. Kept as ONE string rather than a list: every send in a
    # wholly-blocked run fails for the same reason, and the point is to name it, not to
    # tally it. The engine stays surface-free — consumers read it and decide (DESIGN.md §2.1).
    #
    # Falls back to the BACKEND's first refusal, and has to: baseline calibration dials the
    # same backend, but its probe failures never pass through `process_bucket` and so never
    # reach `@first_error`. A run whose whole budget was spent — and refused — inside
    # calibration therefore had a reason that existed and was unreachable, `mine_all_refused?`
    # could not fire, and the CLI printed "0 found" and exited 0. Which is the answer a
    # security tool must never give for a run that sent nothing.
    @first_error : String? = nil

    def first_error : String?
      @first_error || @backend.blocked_reason
    end

    # Attempts the gate refused before the socket, across the WHOLE run (calibration
    # included) — the count that goes with the reason above.
    def blocked : Int64
      @backend.blocked
    end

    # Mining sends that came back WITHOUT an error. `Progress#sent` counts attempts (and
    # includes Baseline's probes, whose failures never reach `@errors`), so `errors >= sent`
    # is not the same question as "did anything get through". Zero here with `first_error`
    # set means the run produced no verdict at all — it was refused, not answered.
    getter successful_sends : Int64 = 0_i64

    def initialize(@base : Bytes, @http2 : Bool, @names : Array(String),
                   backend : Fuzz::Backend, @config : Config)
      # Wrap the backend so max_requests is enforced at every real send (baseline,
      # bucket, and confirm), not just as a racy pre-dispatch check.
      @backend = Fuzz::CappedBackend.new(backend, @config.max_requests)
      @concurrency = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @events = Channel(Event).new(256)
      @report = nil
      @seen = Set({Location, String}).new
      @uninjectable = Set(Location).new
      @found = 0
      @errors = 0_i64
      @names_done = 0_i64
      @names_total = 0_i64
      @last_dispatch = Time.instant
      @inflight = 0
      @idle = Channel(Nil).new(1)
      @present = Hash(Location, Set(String)).new
      @carriable = Hash(Location, Array(String)).new
      @valid = Hash(Location, Array(String)).new
      @encoded = Hash(String, Int32).new
    end

    # The number of distinct (name × location) tests this run will perform — the stable
    # progress denominator. Computed up front (also surfaces an empty wordlist early).
    def total_names : Int64
      @config.locations.sum(0_i64) { |loc| valid_names_for(loc).size.to_i64 }
    end

    def start : Nil
      spawn(name: "miner") { orchestrate }
    end

    # Blocking drain — for synchronous consumers (CLI, the MCP background fiber).
    def run(& : Event ->) : Nil
      start
      while ev = @events.receive?
        yield ev
      end
    end

    def stop : Nil
      @state = State::Stopped
      poke
      # The dispatcher has TWO park points and `poke` only reaches one: `park_if_paused`
      # waits on @wake, `wait_for_worker` waits on @idle. A stop arriving while it is parked
      # on @idle was therefore invisible until a worker finished an in-flight bucket — which
      # against a dead origin is `retries × retry_pause` long. Releasing @idle too is safe by
      # construction: `wait_for_worker`'s own comment says a wake means "look again", never
      # "one task finished", and the loop re-reads @state on the next iteration.
      select
      when @idle.send(nil)
      else
      end
    end

    def pause : Nil
      @state = State::Paused
    end

    def resume : Nil
      @state = State::Running
      poke
    end

    def stopped? : Bool
      @state == State::Stopped
    end

    # ── orchestration ───────────────────────────────────────────────────────────────

    private def orchestrate : Nil
      @names_total = total_names
      # `stop` can land before this fiber's first tick (`start` spawns, the caller keeps the
      # engine and the TUI's ^X reaches it immediately) — and calibration is real requests at
      # the target, so opening with the stability wave would be a burst dispatched entirely
      # after the operator asked to stop. `drain` re-reads the flag for the same reason.
      if @state.stopped?
        @events.send(DoneEvent.new(snapshot, true))
        return
      end
      # The width the run will actually mine each location at, derived BEFORE calibration so
      # the control bucket can be sent at that width (see `Baseline#calibrate`) — a control
      # eight names wide answers a question about eight names, and the run then sends 128.
      widths = Hash(Location, Int32).new
      @config.locations.each { |loc| widths[loc] = bucket_width(loc) }
      report = Baseline.new(@backend, @base, @config, -> { @state.stopped? }).calibrate(@config.locations, widths)
      # A stop that landed DURING calibration, which the check above cannot catch: the predicate
      # handed to `Baseline` kept the remaining probes off the wire, so `report` describes a wave
      # that never finished. Publishing it would claim a baseline was established.
      if @state.stopped?
        @events.send(DoneEvent.new(snapshot, true))
        return
      end
      @report = report
      @events.send(BaselineEvent.new(report.stable, report.warning, report.note))
      # A baseline that never answered is not a baseline. Its `Report` carries placeholders —
      # `status: nil`, every tolerance 0 — and `decide` reads them literally, so mining on one
      # made EVERY candidate a Status finding (nil != 200) and every bucket bisect down to its
      # names: a target where nothing is hidden came back as one finding per name, `errors: 0`,
      # exit 0. Measured: 20 names → 20 "findings" over 64 requests. Refuse instead, and name
      # the reason the calibration wave already collected (`report.warning`).
      #
      # `cap_reached?` first: when `--max-requests` is what refused those probes, the run is
      # BUDGET-exhausted, not blind — the surfaces already say so off `Progress` (and
      # `mine_all_refused?` deliberately exempts a cap), so it must not be reported as a failure.
      if !report.reachable? && !@backend.cap_reached?
        # The RAW send reason, not the wrapped sentence: `first_error` is what
        # `mine_all_refused?` prints, and "every request failed — baseline unreachable —
        # blocked by sandbox" says the same thing three times.
        @first_error ||= report.error
        @events.send(ErrorEvent.new(report.warning || "baseline unreachable"))
        @events.send(DoneEvent.new(snapshot, @state.stopped?))
        return
      end

      work = Deque(Task).new
      @config.locations.each { |loc| initial_buckets(loc, valid_names_for(loc)).each { |t| work << t } }
      drain(work)
      @events.send(DoneEvent.new(snapshot, @state.stopped?))
    rescue ex
      @events.send(ErrorEvent.new(ex.message || "miner error"))
      @events.send(DoneEvent.new(snapshot, @state.stopped?))
    ensure
      # Every worker has left `drain` by here, so no fiber can be holding a checked-out
      # socket: release the keep-alive pool's parked ones instead of waiting for GC to
      # finalize them (a stopped 40-worker run would otherwise sit on 40 fds). Same close
      # `Fuzz::Engine#coordinate` performs, at the miner's equivalent seam.
      # `rescue nil` so a raising close cannot skip the `@events.close` on the next line —
      # that close is what ends the consumer's blocking `receive?`, and without it an MCP
      # job fiber never reaches `finalize_job` and stays pinned at `:running`.
      @backend.close rescue nil
      @events.close
    end

    # Run every bucket of the whole mine through ONE bounded worker pool, feeding each
    # task's bisection children straight back into the queue.
    #
    # It used to be a level-synchronised BFS per location: `locations.each` ran the locations
    # one after another, and inside each, a round dispatched the frontier, waited for ALL of
    # it, then dispatched the children. Both halves of that idled the pool, and a mine is
    # LATENCY-bound — its request count is small (bucket + bisect + confirm) and almost all of
    # its wall clock is time-of-flight — so an idle worker is time nobody gets back:
    #
    #   * the tail of a bisection is 1-2 tasks wide (that is what isolating one name MEANS),
    #     so the last log₂(bucket) rounds ran at a concurrency of 1-2 no matter what the
    #     operator set. Meanwhile the OTHER buckets' subtrees, which are entirely independent,
    #     sat in a later round waiting on the barrier;
    #   * a three-location mine took three times as long as its slowest location, for no
    #     reason at all: query/headers/cookies share nothing but the baseline report.
    #
    # A queue removes both without changing what is sent: the tasks are exactly the same
    # tasks, each still decided against the same calibrated baseline, and a bisection child
    # still cannot run before its parent — it does not EXIST before its parent. Only the
    # order of independent work changes, so findings can now interleave across locations.
    #
    # Concurrency: single-threaded fiber scheduler (no `-Dpreview_mt`). `Deque#push`/`#shift?`
    # never yield mid-op, so workers and this fiber can share the queue with no lock, the same
    # reasoning the counters already rely on.
    private def drain(work : Deque(Task)) : Nil
      return if work.empty?
      # The pool is spawned ONCE for the run, so an idle worker is a fiber parked on a receive
      # rather than the per-round spawn/exit churn the old code capped against — and the cap
      # it used (`min(concurrency, frontier.size)`) cannot be computed here anyway: the queue
      # grows as buckets bisect, and sizing the pool to the first frontier would pin a
      # 40-worker run to its 4 initial buckets for the whole mine.
      workers = @concurrency
      # UNBUFFERED on purpose: a send parks until a worker actually TAKES the task, which is
      # what keeps `@inflight` bounded by the pool size instead of by the queue's length.
      jobs = Channel(Task).new
      finished = Channel(Nil).new(workers)
      interval = pace_interval
      @inflight = 0

      workers.times do |i|
        spawn(name: "miner-worker-#{i}") do
          while task = jobs.receive?
            begin
              # Children are queued BEFORE the task is counted out, so the "queue empty and
              # nothing in flight" test below is a true end-of-work and never races a child in.
              process_bucket(task).each { |child| work << child } unless @state.stopped?
            rescue ex
              # Every received task MUST count itself out, or the mine hangs — the same
              # invariant `Discover::Engine#worker_loop` states for its Outcome. Without this
              # rescue a raise out of process_bucket skips BOTH the decrement and the poke
              # below, so the dispatcher parks in `wait_for_worker` on an @inflight that can
              # never reach 0, never reaches `jobs.close`, and every other worker then parks
              # forever on `jobs.receive?` — a mine that is wedged, not merely wrong. Count the
              # bucket as an error and keep the pool alive instead.
              @errors += 1
              @first_error ||= ex.message || ex.class.name
            ensure
              @inflight -= 1
              # Non-blocking: a worker must never park reporting completion (the dispatcher
              # only listens while it is idle). Dropping a poke is safe — see `wait_for_worker`.
              select
              when @idle.send(nil)
              else
              end
            end
          end
        ensure
          finished.send(nil)
        end
      end

      until @state.stopped?
        if task = work.shift?
          park_if_paused
          break if @state.stopped?
          # Early-out once the hard cap is hit — the CappedBackend also refuses any
          # send that slips past this racy check, so the network count never exceeds it.
          break if @backend.cap_reached?
          pace(interval)
          @inflight += 1
          jobs.send(task)
        elsif @inflight > 0
          wait_for_worker # a bucket is still out; its children may refill the queue
        else
          break # queue drained and nothing outstanding — the mine is complete
        end
      end
      jobs.close
      workers.times { finished.receive }
    end

    # Park until a worker reports a finished bucket.
    #
    # A DROPPED poke cannot lose a wake-up, because the only place this is called from tests
    # `@inflight > 0` and then parks with no yield point in between: the fiber scheduler is
    # single-threaded and cooperative, so a worker that is still out at the moment of the test
    # can only run — and only poke — once this receive is already parked, and a parked receiver
    # is handed the value directly rather than through the buffer. The 1-slot buffer is there
    # for the reverse case (a poke that lands while the dispatcher is busy dispatching), where
    # collapsing several into one is exactly right: the dispatcher re-reads the queue and the
    # counter after every wake, so a wake means "look again", never "one task finished".
    private def wait_for_worker : Nil
      @idle.receive
    end

    # ── the bucketing + bisection core ──────────────────────────────────────────────

    # Test one bucket; emit any findings; return the bisection children to test next.
    private def process_bucket(task : Task) : Array(Task)
      # One {name, canary} pair per candidate — the SAME array feeds the injector and the
      # detector (decide), so no per-bucket name→canary / canary→name hashes are built.
      canaries = Canary.fresh_batch(task.names.size) # one CSPRNG draw for the whole bucket
      pairs = task.names.map_with_index { |n, i| {n, canaries[i]} }
      # `apply_with_spans` (not `apply`): the spans mark the INJECTED candidate names/values
      # so the send seam protects them from session-binding expansion. Without this a `$NAME`
      # a param wordlist carries — or an injected byte colliding with a bound name — expands
      # to the live credential and leaves gori for the target, the run reporting `0 errors`.
      # Resolved ONCE for the send: the padding, the byte delta and the decision all need it.
      ref = report.reference_for(task.location)
      bytes, spans = Inject.apply_with_spans(@base, task.location, pad_pairs(pairs, ref),
        @config.add_content_length_when_missing?)
      # Nothing was injected, so this location cannot carry candidates in THIS request — e.g.
      # a request line that is not METHOD SP TARGET SP VERSION, which `inject_query` bails on
      # unmodified rather than rewrite the operator's bytes (P7, and it is right to). Sending
      # anyway would put the baseline request back on the wire, see no residual signal, and
      # fall into the `kind.none?` branch below, which calls every untested name clean: the
      # worst possible failure mode, a false negative that looks like a clean bill of health
      # (`Fuzz::Backend#blocked` names it, and `skipped_names` was added for the same class of
      # invisible coverage loss). `valid_names_for` already pre-filters per location, so an
      # empty span list never means "these particular names were rejected".
      if spans.empty? && !task.names.empty?
        # Counted ONCE per location, not once per bucket. The fact is a property of the
        # location and this request — every one of that location's buckets bails identically —
        # so incrementing per bucket would report a 4000-name wordlist as thousands of errors
        # and let a reader (and the CLI's exit-code logic) read one malformed request line as
        # that many failed sends.
        if @uninjectable.add?(task.location)
          @errors += 1
          @first_error ||= "#{task.location.label}: nothing could be injected into this request"
        end
        mark_done(task.names.size) # keep the bar monotonic; this bucket is inconclusive
        return [] of Task
      end
      raw = send_with_retries(bytes, spans)
      if err = raw.error
        # A max-requests cap refusal isn't a network error — don't let it inflate @errors.
        unless err == Fuzz::CappedBackend::CAP_ERROR
          @errors += 1
          @first_error ||= err
        end
        mark_done(task.names.size) # keep the bar monotonic; this bucket is inconclusive
        return [] of Task
      end

      probe = Fingerprint.probe(raw)
      decision = Miner.decide(report, probe, pairs, task.location, ref, byte_delta(pairs, ref, task.location))

      # Reflection is self-identifying — resolve those names with no bisection. `reflected`
      # maps canary → name, so the confirming canary is in hand without a name→canary lookup.
      decision.reflected.each do |canary, name|
        # The widest amplifier in the miner: one bucket can carry `bucket_size` reflected names
        # and each one calls `confirm`, which is itself up to `confirm_rounds × (1 + retries)`
        # requests. Entry to `process_bucket` is gated on the stop flag but nothing below it
        # was, so a stop landed while ten workers were inside this loop still let hundreds of
        # requests out per worker. The progress bar is left short on purpose — a stopped run
        # did not finish these names, and saying it did would be a lie.
        break if @state.stopped?
        confirmed = confirm(name, task.location, Evidence::Reflection, canary)
        record_finding(confirmed) if confirmed
        mark_done(1)
      end
      remaining = task.names - decision.reflected.values

      children = [] of Task
      if decision.kind.none? || remaining.empty?
        mark_done(remaining.size) # no residual signal → these names are clean
      elsif remaining.size == 1
        confirmed = confirm(remaining[0], task.location, evidence_of(decision.kind), nil)
        record_finding(confirmed) if confirmed
        mark_done(1)
      else
        split(remaining).each { |slice| children << Task.new(task.location, slice) }
      end
      children
    end

    # Partition a positive bucket into `bisect_ways` roughly-equal contiguous sub-buckets to
    # search next, instead of the two halves a strict binary bisection would.
    #
    # A mine is LATENCY-bound and its critical path is this tree's DEPTH: isolating one name
    # in a K-bucket takes ~log_b(K) sequential round trips at branch factor b, and — since the
    # tail of a bisection is only 1-2 tasks wide — that chain is a floor no amount of
    # concurrency can lower (see `drain`: at concurrency 40 the pool sat ~half idle waiting on
    # it). Widening the split lowers the floor: log₄ is half of log₂.
    #
    # It buys the depth WITHOUT costing requests. To isolate a lone positive, a b-way split
    # sends `b` probes at each of `log_b(K)` levels = `b·log_b(K)` = `2·log₂(K)` for b∈{2,4} —
    # the same count a binary search sends, in wider, shallower waves. When a bucket holds
    # SEVERAL positives it recurses into several children, but the total still falls, not
    # rises: the pruning tree over K names has ~K·b/(b−1) nodes (2K binary, ~1.33K at b=4), so
    # a dense bucket costs FEWER probes under 4-ary (measured −6%…−11% at ≥8 positives per
    # 128). Under `--max-requests` that means 4-ary reaches full coverage inside the same
    # budget a binary run would — it never finds fewer. That is why `BISECT_MAX_WAYS` caps b
    # for DEPTH returns, not to bound a request cost that only shrinks.
    #
    # Tied to `@concurrency` on purpose, floored at 2: widening past the worker count cannot
    # help — the extra pieces just queue — so a serial/paced run (concurrency 1-2) keeps the
    # exact binary tree it had, request-for-request, and only a run with idle workers to fill
    # splits wider. That also keeps the split neutral for a SATURATED pool, whose wall clock is
    # its request count over its worker count regardless of how the tree branches.
    private def split(names : Array(String)) : Array(Array(String))
      ways = @concurrency.clamp(2, BISECT_MAX_WAYS)
      k = {names.size, ways}.min
      base = names.size // k
      extra = names.size % k
      slices = Array(Array(String)).new(k)
      start = 0
      k.times do |i|
        len = base + (i < extra ? 1 : 0)
        slices << names[start, len]
        start += len
      end
      slices
    end

    # Re-test an isolated name alone with fresh canaries; Confirmed only if it
    # reproduces a majority of rounds AND the baseline is stable AND the location isn't
    # reflection-only. Drops a name that no longer reproduces (bucket-interaction FP).
    private def confirm(name : String, location : Location,
                        evidence : Evidence, canary : String?) : Finding?
      r = report
      rounds = @config.confirm_rounds
      if rounds <= 0
        return Finding.new(name, location, evidence, confidence_for(true, location), canary, nil, 0_i64)
      end

      # Once `majority` matching rounds land, `reproduced` is locked true and no further round
      # can change the verdict — so stop re-sending. Saves the tail confirm requests for every
      # finding whose signal reproduces early; the classification is identical, and a run that
      # never reaches majority still runs them all.
      #
      # A REAL majority — `(rounds + 1) // 2` made the default `confirm_rounds: 2` mean "one of
      # two rounds is enough", which was already thin and became unsafe once the isolated
      # re-test stopped having to reproduce the same METRIC (`matches_evidence?`): one 429 or
      # 503 from a rate limiter during confirmation is a Status diff, and a single such round
      # would confirm any name a jittery bucket had nominated, relabelled as Status with the
      # rate limiter's own code as its evidence. Two rounds have to agree now, at a cost of one
      # request per finding.
      majority = rounds // 2 + 1
      hits = 0
      last_status = nil.as(Int32?)
      last_delta = 0_i64
      last_canary = canary
      last_grpc_status = nil.as(Int32?)
      last_grpc_message = nil.as(String?)
      interval = pace_interval
      ref = r.reference_for(location)
      # The delta a finding REPORTS is measured from whatever it was compared against. Off a
      # width-matched control that is the control's own length: the confirm round carried
      # `width - 1` padding names, so against the untouched baseline the number the TUI, the
      # CLI row and MCP all print as "observed length delta" would be the padding's bulk —
      # kilobytes on a page that answers a row per parameter — and not what the parameter did.
      anchor = ref ? ref.probe.metrics.length : r.base_length
      rounds.times do
        # A confirm round is a REQUEST, so the stop flag has to be read here and not only at
        # the top of the bucket: `process_bucket` checks it once on entry, and everything below
        # that check keeps sending. `Discover::Engine#process_calibrate` re-checks inside its
        # own fan-out for exactly this reason, and its comment quantifies the bug that fixed at
        # ~120 requests to a third party AFTER the operator pressed stop. Breaking with
        # `hits == 0` returns nil — no finding — which is the honest answer for a candidate
        # whose confirmation never ran.
        break if @state.stopped?
        c = Canary.fresh
        # Same span-protection as the main loop — the confirm re-send injects the same name.
        bytes, spans = Inject.apply_with_spans(@base, location, pad_pairs([{name, c}], ref),
          @config.add_content_length_when_missing?)
        # A confirm round is a REQUEST. Only the bucket send that produced this candidate was
        # paced by the dispatch loop, so these ran on top of the operator's rate — up to
        # `confirm_rounds` extra unpaced requests for every candidate that shows signal.
        pace(interval)
        raw = send_with_retries(bytes, spans)
        if err = raw.error
          # A confirm round is a REQUEST like any other, and this was the one send path that
          # swallowed its failure whole: a candidate whose confirmation never reached the origin
          # was dropped with no finding, no error counted and no reason retained, so a target
          # that died right after the bucket probes ended "0 found · 0 errors". Same cap
          # exemption `process_bucket` makes — a budget refusal is not a network failure.
          unless err == Fuzz::CappedBackend::CAP_ERROR
            @errors += 1
            @first_error ||= err
          end
          next
        end
        probe = Fingerprint.probe(raw)
        decision = Miner.decide(r, probe, [{name, c}], location, ref,
          byte_delta([{name, c}], ref, location))
        if matches_evidence?(decision, evidence, name)
          hits += 1
          # The isolated round is the better measurement of WHAT this parameter does: the
          # bucket's kind was decided with up to `bucket_size` other names in the request, and
          # a name whose effect is a status change can easily read as Length inside one. Report
          # what the name did alone.
          evidence = evidence_of(decision.kind) unless evidence.reflection? || decision.kind.none?
          # Only record status/delta from a round that actually reproduced the signal, so a
          # Confirmed finding's reported evidence can't come from a non-matching (flaky) round.
          last_status = probe.metrics.status
          last_delta = probe.metrics.length - anchor
          last_canary = c if evidence.reflection?
          # Same projection the Fuzzer uses (`Fuzz::GrpcVerdict.response`): the h2 `:status`
          # above is 200 for every gRPC call, so for a gRPC target this — not `last_status` —
          # is the isolated candidate's real outcome. nil/nil for a non-gRPC response, at the
          # cost of one allocation-free byte scan.
          last_grpc_status, last_grpc_message = Fuzz::GrpcVerdict.response(raw.head)
          break if hits >= majority
        end
      end
      return nil if hits == 0
      Finding.new(name, location, evidence, confidence_for(hits >= majority, location),
        last_canary, last_status, last_delta, last_grpc_status, last_grpc_message)
    end

    private def confidence_for(reproduced : Bool, location : Location) : Confidence
      r = report
      (reproduced && r.stable && !r.reflection_only[location]?) ? Confidence::Confirmed : Confidence::Tentative
    end

    # Did the isolated re-test reproduce the signal the bucket nominated this name for?
    #
    # For a metric nomination this asks "does this name still move the response", NOT "does it
    # move the SAME metric". Demanding the identical kind conflated the two and dropped real
    # parameters: the bucket's kind is measured with up to `bucket_size` other names in the
    # request, so a name that returns 500 alone can read as Length inside a bucket whose
    # status was already 200 — evidence Status vs kind Length, no match, no finding, and
    # nothing anywhere saying a candidate had been seen and thrown away. A name that moves
    # the response ALONE, reproducibly, is the thing the miner exists to report; which of the
    # four metrics carried it is a label, and `confirm` now relabels it from the isolated
    # round. False positives are still held off by the same two gates as before — the name
    # has to clear the calibrated band on a MAJORITY of rounds.
    private def matches_evidence?(decision : Decision, evidence : Evidence, name : String) : Bool
      if evidence.reflection?
        decision.reflected.has_value?(name)
      else
        !decision.kind.none?
      end
    end

    private def evidence_of(kind : DiffKind) : Evidence
      case kind
      in DiffKind::Status then Evidence::Status
      in DiffKind::Length then Evidence::Length
      in DiffKind::Words  then Evidence::Words
      in DiffKind::Lines  then Evidence::Lines
      in DiffKind::None   then Evidence::Length
      end
    end

    # ── buckets + name filtering ────────────────────────────────────────────────────

    # The number of candidate names one probe carries at `loc`: the configured bucket size,
    # lowered only if that many of THIS wordlist's names could not fit the location's byte
    # budget. Derived from the widest name, so it is a single number for the whole location —
    # which is what a width-matched control needs (`Baseline#calibrate`): every probe of the
    # run carries exactly this many parameters, so the control's reaction cancels against the
    # probe's and only the candidate's own effect is left.
    private def bucket_width(loc : Location) : Int32
      cap = @config.bucket_for(loc)
      names = valid_names_for(loc)
      return cap if names.empty?
      budget = byte_budget(loc)
      return cap if budget == Int32::MAX
      worst = names.max_of { |n| name_cost(n, loc) }
      return cap if worst <= 0
      {cap, {budget // worst, 1}.max}.min
    end

    # Per-request byte ceiling for the location, or Int32::MAX where there is none.
    private def byte_budget(loc : Location) : Int32
      if loc.query? || loc.form?
        Inject::MAX_URL_BYTES
      elsif loc.json?
        MAX_JSON_INJECT_BYTES
      else
        Int32::MAX
      end
    end

    # What one name costs on the wire at `loc`: the ENCODED name (a name with reserved chars
    # expands under URI.encode_www_form, so the raw bytesize would under-budget the URL and a
    # bucket could overflow MAX_URL_BYTES → 414), its canary, the separators — times the JSON
    # node count, since a JSON candidate is injected into EVERY object node.
    private def name_cost(n : String, loc : Location) : Int32
      (encoded_name_bytes(n, loc) + Canary::LEN + 2) * (loc.json? ? json_nodes : 1)
    end

    # Object nodes in the BASE body — fixed for the run (the node set never varies with bucket
    # size, so bisection and confirmation stay valid), so derived once.
    @json_nodes : Int32? = nil

    private def json_nodes : Int32
      @json_nodes ||= {Inject.json_object_node_count(Inject.split(@base)[1], Inject::MAX_JSON_NODES), 1}.max
    end

    # Extend a probe's candidate list with bogus names to the location's calibrated width, so
    # every request of the run — initial bucket, bisection child, confirmation round — carries
    # the SAME number of parameters as the control it is compared against. Without this the
    # comparison changes shape as the bisection narrows, and on a page that reacts to unknown
    # parameters (a "3 filters applied" counter, an error page that lists what it received)
    # the reaction itself is what the reference cancels.
    #
    # The padding is NOT in the candidate list handed to `decide`, so a bogus name can never
    # become a finding, and its canary is never looked up.
    private def pad_pairs(pairs : Array({String, String}),
                          ref : Baseline::Reference?) : Array({String, String})
      return pairs unless ref && pairs.size < ref.width
      extra = ref.width - pairs.size
      values = Canary.fresh_batch(extra)
      # Padding names carry the CONTROL's own length, so the only byte difference left between
      # a probe and its reference is the candidate names themselves — which is exactly what
      # `byte_delta` measures and the length band is widened by. One draw for the whole batch,
      # and DISTINCT by construction: see `Canary.bogus_batch`.
      names = Canary.bogus_batch(extra, ref.name_len)
      padded = Array({String, String}).new(ref.width)
      padded.concat(pairs)
      extra.times { |i| padded << {names[i], values[i]} }
      padded
    end

    # How many more (or fewer) bytes of parameter NAME this probe carries than the location's
    # control did. A page that prints back what it received returns that difference in its own
    # byte count — and the difference is gori's own doing, so `decide` widens the length band
    # by `echo x this` instead of reading it as a finding.
    private def byte_delta(pairs : Array({String, String}),
                           ref : Baseline::Reference?, loc : Location) : Int32
      return 0 unless ref
      mine = pairs.sum(0) { |(n, _)| encoded_name_bytes(n, loc) }
      pad = {ref.width - pairs.size, 0}.max * ref.name_len
      (mine + pad - ref.name_bytes) * (loc.json? ? json_nodes : 1)
    end

    # Memoized per location: the encoded size is pure over {name, location} and fixed for the
    # run, and this is on the hot path — `byte_delta` asks it for every candidate of every
    # send, which without the memo re-ran `URI.encode_www_form` (and allocated a throwaway
    # String) 128 times per probe to recompute a number the bucketing had already computed.
    # Only query/form encode at all; everywhere else the name's own `bytesize` is the answer.
    private def encoded_name_bytes(n : String, loc : Location) : Int32
      return n.bytesize unless loc.query? || loc.form?
      (@encoded[n] ||= URI.encode_www_form(n).bytesize)
    end

    private def initial_buckets(loc : Location, names : Array(String)) : Array(Task)
      # The CALIBRATED width, not the configured one: the target may have refused the width the
      # config asked for (`Baseline#settle`), and at a location with a width-matched control
      # the comparison is only valid while every probe carries the same number of parameters —
      # `pad_pairs` can pad a short bucket UP but nothing can shrink an over-wide one.
      cap = @report.try(&.width_for(loc)) || @config.bucket_for(loc)
      budget = byte_budget(loc)
      buckets = [] of Task
      cur = [] of String
      cur_bytes = 0
      names.each do |n|
        # `name_cost` counts the ENCODED size for query/form — a name with reserved chars
        # (e.g. "v2/x") expands under URI.encode_www_form, so the raw bytesize would
        # under-budget the URL and a bucket could overflow MAX_URL_BYTES → 414 — and multiplies
        # by the JSON node count, since a JSON candidate is injected into every object node.
        nb = name_cost(n, loc)
        if !cur.empty? && (cur.size >= cap || cur_bytes + nb > budget)
          buckets << Task.new(loc, cur)
          cur = [] of String
          cur_bytes = 0
        end
        cur << n
        cur_bytes += nb
      end
      buckets << Task.new(loc, cur) unless cur.empty?
      buckets
    end

    # The names this run actually tests at `loc`: the wordlist, minus what the location cannot
    # carry, minus what the request ALREADY carries there (see `Inject.existing_names` for why
    # the second filter is a correctness fix and not a saving — at Json the injector OVERWRITES
    # the operator's own value, so testing a visible name corrupted the request AND reported it
    # back as a hidden parameter).
    private def valid_names_for(loc : Location) : Array(String)
      @valid[loc] ||= compute_valid_names(loc)
    end

    # Memoized: `@names` and `@base` are both fixed for the run, so this answer cannot change
    # — and it was recomputed over the WHOLE wordlist on every call, including the two
    # coverage accessors (`skipped_names`, `present_names`) that a live surface polls while
    # the run is going (MCP `mine_status`, the TUI tab). A 100k-name user wordlist made each
    # poll a full re-filter of the list, per location, for a number that never moves.
    private def compute_valid_names(loc : Location) : Array(String)
      present = present_at(loc)
      return carriable_names_for(loc) if present.empty?
      # Header field names are case-insensitive, so `X-Api-Key` in the request rules out a
      # wordlist's `x-api-key`; every other location's namespace is byte-exact.
      cased = loc.headers?
      carriable_names_for(loc).reject { |n| present.includes?(cased ? n.downcase : n) }
    end

    # Wordlist names the location can carry at all (a header/cookie name must be an RFC 7230
    # token; a framing header is never injected).
    private def carriable_names_for(loc : Location) : Array(String)
      @carriable[loc] ||= compute_carriable_names(loc)
    end

    private def compute_carriable_names(loc : Location) : Array(String)
      case loc
      when Location::Headers   then @names.select { |n| Inject.valid_header_name?(n) }
      when Location::Cookies   then @names.select { |n| Inject.valid_cookie_name?(n) }
      when Location::Multipart then @names.select { |n| Inject.valid_multipart_name?(n) }
      else                          @names
      end
    end

    # Memoized per location — derived from `@base`, which never changes during a run, and read
    # once per name by the filter above. The memo write is safe from the surfaces' reporting
    # fibers (MCP `mine_status` calls `present_names` while the run is live): the whole
    # derivation is pure computation over bytes with no yield point in it, which is the same
    # single-threaded-scheduler reasoning the counters rely on.
    private def present_at(loc : Location) : Set(String)
      @present[loc] ||= Inject.existing_names(@base, loc)
    end

    # {location, how many wordlist names it cannot carry}, for the locations this run
    # actually mines and only where something WAS dropped.
    #
    # The rejection itself is right — a header/cookie name must be an RFC 7230 token, and
    # `Content-Length`/`Host` would break framing — but it was invisible: `total_names` sums
    # the FILTERED sizes, so the operator's only signal was that the same wordlist produced
    # "444 names" against the query and "435 names" against headers, and only if they ran
    # both and compared. Coverage was incomplete and the run reported clean. `probe` already
    # publishes a `skipped` count for exactly this reason; this is the same fact.
    def skipped_names : Array({Location, Int32})
      @config.locations.compact_map do |loc|
        n = @names.size - carriable_names_for(loc).size
        n > 0 ? {loc, n} : nil
      end
    end

    # {location, how many wordlist names the REQUEST ALREADY CARRIES there}, for the locations
    # this run mines and only where something was dropped — the second half of the same
    # coverage fact `skipped_names` reports, kept apart because the two have different answers:
    # a name skipped here is one the operator can see in their own request, not one gori
    # refused to encode. `names_total` excludes both, so without this the count comes up short
    # with nothing anywhere to say why.
    def present_names : Array({Location, Int32})
      @config.locations.compact_map do |loc|
        n = carriable_names_for(loc).size - valid_names_for(loc).size
        n > 0 ? {loc, n} : nil
      end
    end

    # The wordlist size BEFORE any per-location filtering — the denominator a `skipped`
    # count is only meaningful against.
    def candidate_names : Int32
      @names.size
    end

    # ── counters / events ───────────────────────────────────────────────────────────

    private def report : Baseline::Report
      @report || raise("baseline not calibrated")
    end

    private def record_finding(finding : Finding) : Nil
      key = {finding.location, finding.name}
      return if @seen.includes?(key)
      @seen << key
      @found += 1
      @events.send(FindingEvent.new(finding)) # blocking — never drop a finding
    end

    private def mark_done(n : Int32) : Nil
      @names_done += n
      emit_progress
    end

    private def emit_progress : Nil
      ev = ProgressEvent.new(snapshot)
      select
      when @events.send(ev)
      else
      end
    end

    private def snapshot : Progress
      Progress.new(@names_total, @names_done, @backend.sent, @found, @errors)
    end

    # ── sending / pacing ────────────────────────────────────────────────────────────

    private def send_with_retries(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      attempts = 0
      loop do
        raw = @backend.send(bytes, verbatim)
        if raw.error.nil?
          @successful_sends += 1
          return raw
        end
        # A PERMANENT refusal is not worth a retry. All three siblings exempt the cap
        # explicitly (`Fuzz::Engine#run_one`, `Discover`'s `send_with_retries`,
        # `Sequencer`'s), and miner had no exemption at all — so once `--max-requests` tripped,
        # every remaining bucket slept `retry_pause` and called a backend whose answer cannot
        # change. A Layer-2 refusal is permanent for the same reason: the scope did not move
        # between the two calls, and each attempt is charged to the cap a second time
        # (`CappedBackend#send` increments AFTER the cap check but BEFORE the gate's).
        return raw if permanent_refusal?(raw.error) || attempts >= @config.retries
        attempts += 1
        sleep @config.retry_pause
      end
    end

    private def permanent_refusal?(err : String?) : Bool
      Miner.permanent_refusal?(err)
    end

    private def park_if_paused : Nil
      while @state == State::Paused
        @wake.receive
      end
    end

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end
  end
end
