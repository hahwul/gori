require "uri"
require "./types"
require "./inject"
require "./fingerprint"
require "./baseline"
require "../fuzz/engine"
require "../fuzz/matcher"
require "../pacing"

module Gori::Miner
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
      report = Baseline.new(@backend, @base, @config, -> { @state.stopped? }).calibrate(@config.locations)
      # A stop that landed DURING calibration, which the check above cannot catch: the predicate
      # handed to `Baseline` kept the remaining probes off the wire, so `report` describes a wave
      # that never finished. Publishing it would claim a baseline was established.
      if @state.stopped?
        @events.send(DoneEvent.new(snapshot, true))
        return
      end
      @report = report
      @events.send(BaselineEvent.new(report.stable, report.warning))

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
      bytes, spans = Inject.apply_with_spans(@base, task.location, pairs, @config.add_content_length_when_missing?)
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
      decision = Miner.decide(report, probe, pairs, task.location)

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
      # finding whose signal reproduces early (the common case, e.g. confirm_rounds=2 → 1 round);
      # the classification is identical, and a run that never reaches majority still runs them all.
      majority = (rounds + 1) // 2
      hits = 0
      last_status = nil.as(Int32?)
      last_delta = 0_i64
      last_canary = canary
      last_grpc_status = nil.as(Int32?)
      last_grpc_message = nil.as(String?)
      interval = pace_interval
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
        bytes, spans = Inject.apply_with_spans(@base, location, [{name, c}], @config.add_content_length_when_missing?)
        # A confirm round is a REQUEST. Only the bucket send that produced this candidate was
        # paced by the dispatch loop, so these ran on top of the operator's rate — up to
        # `confirm_rounds` extra unpaced requests for every candidate that shows signal.
        pace(interval)
        raw = send_with_retries(bytes, spans)
        next if raw.error
        probe = Fingerprint.probe(raw)
        decision = Miner.decide(r, probe, [{name, c}], location)
        if matches_evidence?(decision, evidence, name)
          hits += 1
          # Only record status/delta from a round that actually reproduced the signal, so a
          # Confirmed finding's reported evidence can't come from a non-matching (flaky) round.
          last_status = probe.metrics.status
          last_delta = probe.metrics.length - r.base_length
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

    private def matches_evidence?(decision : Decision, evidence : Evidence, name : String) : Bool
      if evidence.reflection?
        decision.reflected.has_value?(name)
      else
        decision.kind == diffkind_of(evidence)
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

    private def diffkind_of(evidence : Evidence) : DiffKind
      case evidence
      in Evidence::Reflection then DiffKind::None
      in Evidence::Status     then DiffKind::Status
      in Evidence::Length     then DiffKind::Length
      in Evidence::Words      then DiffKind::Words
      in Evidence::Lines      then DiffKind::Lines
      end
    end

    # ── buckets + name filtering ────────────────────────────────────────────────────

    private def initial_buckets(loc : Location, names : Array(String)) : Array(Task)
      cap = @config.bucket_for(loc)
      url_loc = loc.query? || loc.form?
      # JSON injects each candidate into EVERY object node, so a name's real byte cost is the
      # per-name cost × node count. Derive the count ONCE from @base (fixed → the node set never
      # varies with bucket size, so bisection/confirm stay valid) and bound per-request growth.
      json_nodes = loc.json? ? {Inject.json_object_node_count(Inject.split(@base)[1], Inject::MAX_JSON_NODES), 1}.max : 1
      byte_budget = if url_loc
                      Inject::MAX_URL_BYTES
                    elsif loc.json?
                      MAX_JSON_INJECT_BYTES
                    else
                      Int32::MAX
                    end
      buckets = [] of Task
      cur = [] of String
      cur_bytes = 0
      names.each do |n|
        # Count the ENCODED size for query/form — a name with reserved chars (e.g. "v2/x")
        # expands under URI.encode_www_form, so the raw bytesize would under-budget the URL
        # and a bucket could overflow MAX_URL_BYTES → 414. For Json, multiply by the node count.
        # (One-time cost during bucketing.)
        nb = ((url_loc ? URI.encode_www_form(n).bytesize : n.bytesize) + Canary::LEN + 2) * (loc.json? ? json_nodes : 1)
        if !cur.empty? && (cur.size >= cap || cur_bytes + nb > byte_budget)
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

    private def valid_names_for(loc : Location) : Array(String)
      case loc
      when Location::Headers   then @names.select { |n| Inject.valid_header_name?(n) }
      when Location::Cookies   then @names.select { |n| Inject.valid_cookie_name?(n) }
      when Location::Multipart then @names.select { |n| Inject.valid_multipart_name?(n) }
      else                          @names
      end
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
        n = @names.size - valid_names_for(loc).size
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

    # Refusals no retry can change: the request budget is spent, or Layer 2 says no. Both are
    # decided from state that does not move between two calls a `retry_pause` apart. The
    # Layer-2 half is `Outbound.permanent_refusal?` — ONE home for the rule, because an
    # exclude was once omitted from this list and an EXCLUDE_SWEEP_ERROR was then retried
    # `retries` times, burning the request cap and stalling the run for nothing.
    private def permanent_refusal?(err : String?) : Bool
      err == Fuzz::CappedBackend::CAP_ERROR || Gori::Outbound.permanent_refusal?(err)
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
