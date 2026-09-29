require "./spec"

module Gori::RequestMacro
  # The error of a send the run's request budget refused. `Fuzz::CappedBackend::CAP_ERROR` IS
  # this string: the engines recognise a spent budget by it and never retry it, and a candidate
  # the macro could not pay for must read exactly like one the cap refused.
  BUDGET_ERROR = "max-requests cap reached"

  # One execution of a macro's steps, finished. Carries binding NAMES and never a value: a
  # surface prints `message` into a status line, an event row and an MCP reply, and none of
  # those is a place for a credential (the same rule `SessionRefresh::Outcome` keeps).
  record Outcome,
    ok : Bool,
    # How many steps the macro has.
    steps : Int32,
    # Requests the steps actually put on the wire — what the run's request budget was charged.
    requests : Int32 = 0,
    # 1-based step that failed, nil on success or when the failure is not a step's.
    failed_step : Int32? = nil,
    # What that step is called — the tab's name, or `METHOD path`.
    step_label : String? = nil,
    # The failed step's response status, when it got one.
    status : Int32? = nil,
    # Why it failed, operator-readable. nil on success.
    reason : String? = nil,
    # The bindings a step rebound, by name.
    rebound : Array(String) = [] of String,
    # History rows the steps were recorded as.
    flow_ids : Array(Int64) = [] of Int64,
    # The steps stopped because the run's request budget could not pay for the next one. Not a
    # macro FAILURE — the run is out of budget, and its candidates already answer that with the
    # cap's own error — so the lane neither counts it against the failure limit nor renames it.
    budget_exhausted : Bool = false,
    # The steps stopped because the run was stopped between two of them. Not a failure either —
    # nobody's login broke — so the lane does not count it, and the candidate it was for is
    # dropped the way any candidate waiting when the stop landed is.
    stopped : Bool = false,
    at : Time = Time.utc do
    # `failed at step 2 (login → 403) — the step answered 403` — what happened, without saying
    # "macro" (every surface that prints it already has). No value is in it by construction.
    def detail : String
      names = rebound.empty? ? "" : Env.token_list(rebound, ns: Env::Namespace::Bind)
      if ok
        return "ok · #{names.empty? ? "no binding rebound" : "#{names} rebound"}"
      end
      where =
        if (n = failed_step) && (label = step_label)
          info = status ? "#{label} → #{status}" : label
          " at step #{n} (#{info})"
        else
          ""
        end
      why = reason ? " — #{reason}" : ""
      "failed#{where}#{why}"
    end

    # `macro failed at step 2 (login → 403) — the step answered 403` — the sentence an event row,
    # a status line and a failure summary print.
    def message : String
      "macro #{detail}"
    end

    # The `error` of the candidate this failure took the place of. Prefixed (`ERROR_PREFIX`) so
    # nothing downstream reads it as the target's answer or retries it.
    def error_text : String
      return BUDGET_ERROR if budget_exhausted
      "#{ERROR_PREFIX}#{detail} — the candidate was not sent"
    end
  end

  # The run's request budget, as the macro sees it. `Fuzz::CappedBackend` implements it, so the
  # steps are charged against the same `max_requests` the candidates are: the macro's traffic is
  # real traffic at the target, and a tester working inside an agreed request budget counts it.
  module Budget
    # Claim `n` requests, or false when they would not fit. A claim that succeeds is spent.
    abstract def reserve(n : Int64) : Bool

    # Give back `n` requests that were charged and never sent — see `Lane#refund_candidate`.
    abstract def refund(n : Int64) : Nil
  end

  # What produces a fresh value. The concrete one (`Runner`) sends Repeater sessions; the lane
  # only needs to be able to ask, which keeps this file free of the Repeater layer and lets a
  # spec drive the gating with a fake.
  abstract class Source
    # Run every step once, in order. Never raises; a failure is an `Outcome`. `budget`,
    # `pacer` and `cancelled` belong to the run that owns the lane: the budget is charged one
    # request per step, the pacer waits out the run's rate limit before it, and `cancelled` is
    # asked between steps so a stop does not have to wait for a whole login to finish.
    abstract def run(budget : Budget?, pacer : Proc(Nil)?, cancelled : Proc(Bool)? = nil) : Outcome

    # The steps as labels, in order.
    abstract def labels : Array(String)

    # Write one row to the project's event feed, filed under `source` (`fuzzer` / `miner`). A
    # no-op by default: only a source that holds a project has anywhere to write it.
    def note(source : String, kind : String, level : Symbol, message : String, flow_id : Int64? = nil) : Nil
    end
  end

  # What a run reports about its macro: enough to see that it ran, that it failed, and how many
  # candidates it cost. Counts and the first failure's message — never a value.
  record Tally,
    # Executions of the steps that finished, failed ones included.
    runs : Int64 = 0_i64,
    failed : Int64 = 0_i64,
    # Candidates NOT sent because the macro failed (or the run had already been ended by it).
    skipped : Int64 = 0_i64,
    # Requests the steps put on the wire. Included in the run's own `requests`.
    requests : Int64 = 0_i64,
    # The first failure's message, or nil when none happened.
    first_error : String? = nil do
    # `12 runs · 12 requests`, and on a failure `· 2 failed · 2 candidates not sent — first
    # failure: macro failed at step 1 (csrf-fetch → 500) — the step answered 500`. The one
    # sentence every surface prints for what the macro did to a run. Counts and a message,
    # never a value.
    def summary : String
      parts = ["#{runs} run#{runs == 1 ? "" : "s"}", "#{requests} request#{requests == 1 ? "" : "s"}"]
      if failed > 0
        parts << "#{failed} failed" << "#{skipped} candidate#{skipped == 1 ? "" : "s"} not sent"
      end
      line = parts.join(" · ")
      (fe = first_error) ? "#{line} — first failure: #{fe}" : line
    end
  end

  # The plan-time description of the stage — what "visible in the plan" means. `sharing` says
  # whether a value is shared between candidates; `concurrency` is the parallelism the macro
  # leaves the run, which is lower than the configured one for any macro that is not off.
  record Info,
    steps : Array(String),
    cadence : Cadence,
    on_failure : OnFailure,
    sharing : String,
    concurrency : Int32 do
    # `macro: csrf-fetch → login · before every request · one candidate at a time · on failure: skip the candidate`
    def line : String
      "macro: #{steps.join(" → ")} · #{cadence.label} · #{sharing} · on failure: #{on_failure.label}"
    end
  end

  # The gate every candidate passes through: it decides WHEN the steps run, what a candidate does
  # while they are running, and what a failure costs. One lane per run, shared by every worker
  # fiber.
  #
  # ## Epochs
  #
  # `cadence.every == N` means the value a run of the steps leaves is used by the next N
  # candidates, and those N are an EPOCH. The first candidate to arrive with no epoch open runs
  # the steps; the N-1 after it share the value; the candidate after that opens the next epoch.
  # An epoch is a barrier in one direction: the steps of epoch k+1 do not start until every
  # candidate of epoch k has finished. Without that, a slow candidate of epoch k could pick up
  # epoch k+1's value at its send, and "N candidates share a value" would be a hope rather than
  # a guarantee.
  #
  # So the parallelism the macro leaves a run is exactly `min(concurrency, N)`, and for
  # `every == 1` — a fresh value for EVERY candidate — it is one: a one-time token cannot be
  # shared by two workers without changing the test, and the barrier is what makes that true
  # instead of merely likely. The plan reports it (`Info#concurrency`) so nobody discovers it
  # from a stopwatch.
  #
  # Candidates are counted in the order they REACH the gate. With one worker that is the
  # generation order; with several it is the order the workers' fibers get there, which is
  # dispatch order in practice and is not promised any tighter than the scheduler promises.
  #
  # ## Failure
  #
  # A failed run of the steps opens no epoch. The candidate that asked for it is refused
  # (`Entry#refused?`, its row an error row), and the next candidate tries again, so a flaky
  # login costs the candidates it failed for and not the N after them. `OnFailure::Stop` ends
  # the run on the first failure; `Skip` ends it after `FAILURE_LIMIT` in a row, so a login that
  # is simply broken is not hammered once per payload — the lockout the same limit in #1233
  # exists to prevent. Ending the run is the ENGINE's act (`aborted?`): the lane only says so.
  class Lane
    # Consecutive failures after which the run is ended, whatever `on_failure` says.
    FAILURE_LIMIT = 3

    # At most this many failure events go to the project's feed per run; the tally keeps
    # counting. A dead login endpoint must not be a thousand-row event flood.
    EVENT_CAP = 20

    # A candidate's pass through the gate. Always `leave` it (or use `Lane#around`).
    class Entry
      # The failed run of the steps that took this candidate's place, when there is one.
      getter outcome : Outcome?
      # Why the candidate is refused when there is no run to point at: the run was ended by an
      # earlier failure, so the steps were not tried again.
      getter note : String?
      getter? cancelled : Bool

      def initialize(@lane : Lane?, @outcome : Outcome? = nil, @cancelled : Bool = false,
                     @note : String? = nil)
        @open = !@lane.nil?
      end

      # The steps failed, or the run was already ended by a failure: do NOT send the candidate.
      def refused? : Bool
        !@outcome.nil? || !@note.nil?
      end

      # Whether the candidate may go on the wire.
      def send? : Bool
        !refused? && !@cancelled
      end

      # The `error` of the row that stands in for a candidate that was not sent.
      def error : String
        if o = @outcome
          o.error_text
        elsif n = @note
          "#{ERROR_PREFIX}#{n} — the candidate was not sent"
        else
          STOPPED_UNSENT
        end
      end

      def leave : Nil
        return unless @open
        @open = false
        @lane.try(&.release_slot)
      end
    end

    getter spec : Spec
    getter source : Source
    # The `events.source` this run's failure rows are filed under (`fuzzer` / `miner`).
    getter event_source : String
    getter abort_reason : String? = nil

    @every : Int32
    @budget : Budget? = nil
    @pacer : Proc(Nil)? = nil
    @cancelled : Proc(Bool)? = nil
    @runs = 0_i64
    @failed = 0_i64
    @skipped = 0_i64
    @requests = 0_i64
    @first_error : String? = nil
    @consecutive = 0
    @events_written = 0

    # `noun` is what one run of the steps precedes: a fuzz `candidate`, a mine `request`. It
    # only words the plan-time line.
    def initialize(@spec : Spec, @source : Source, @event_source : String = "fuzzer",
                   @noun : String = "candidate")
      @every = Math.max(@spec.cadence.every, 1)
      @gate = Mutex.new
      # Candidates that may still join the open epoch. 0 = no epoch open.
      @left = 0
      # Candidates admitted and not yet left — what the next epoch waits to see reach zero.
      @inflight = 0
      @drained = Channel(Nil).new(1)
    end

    # Bind the lane to the run that owns it: the budget its steps are charged against, the
    # pacer that holds them to the run's rate, and the predicate that says the run was stopped
    # (a stop must not be followed by one more login). Called once by the engine.
    def attach(budget : Budget?, pacer : Proc(Nil)?, cancelled : Proc(Bool)?) : self
      @budget = budget
      @pacer = pacer
      @cancelled = cancelled
      self
    end

    def aborted? : Bool
      !@abort_reason.nil?
    end

    # The most requests the steps can put on the wire for `candidates` candidates: one run of every
    # step per epoch, so `ceil(candidates / every)` runs. What the huge-run gates add to the
    # candidate count they judge (`Fuzz.request_bound`), so a per-request macro's second request is
    # not the one nobody counted.
    def macro_requests(candidates : Int64?) : Int64
      return 0_i64 unless candidates
      runs = (candidates.to_i128 + @every - 1) // @every
      (runs * @source.labels.size).clamp(0_i128, Int64::MAX.to_i128).to_i64
    end

    # Return the charge for a candidate the gate refused, for a caller that sits INSIDE the
    # budget (`Miner::MacroBackend`): the cap charged the candidate on its way in, before the
    # gate could say the steps failed, so without this a refused probe would count as traffic
    # the target never saw. The Fuzzer gates OUTSIDE its cap and charges only what it sends.
    def refund_candidate : Nil
      @budget.try(&.refund(1_i64))
    end

    def tally : Tally
      Tally.new(@runs, @failed, @skipped, @requests, @first_error)
    end

    # The stage as the plan reports it. `race` is the race group size for a race run — its
    # members share one value by construction, and that is said rather than left to be inferred.
    def info(concurrency : Int32, race : Int32? = nil) : Info
      sharing, effective =
        if race
          {"fetched once, before the group is dialled — all #{race} members share it", 1}
        elsif @every == 1
          {"one #{@noun} at a time — a value is never shared", 1}
        else
          {"a value is shared by up to #{@every} #{@noun}s at once; the next waits for all of them", Math.min(concurrency, @every)}
        end
      Info.new(@source.labels, @spec.cadence, @spec.on_failure, sharing, effective)
    end

    # ── the gate ────────────────────────────────────────────────────────────────────

    def around(& : Entry -> T) : T forall T
      entry = enter
      begin
        yield entry
      ensure
        entry.leave
      end
    end

    # Admit one candidate, running the steps first when it opens an epoch. Serialised: the
    # candidates behind it wait on the gate, which is what they must do anyway — they belong to
    # the same epoch (and want its value) or to the next one (and want it not to exist yet).
    def enter : Entry
      @gate.synchronize do
        if @abort_reason
          @skipped += 1
          return Entry.new(nil, note: "an earlier failure ended the run")
        end
        return Entry.new(nil, nil, true) if cancelled?
        if @left == 0
          wait_drained
          return Entry.new(nil, nil, true) if cancelled?
          outcome = execute
          unless outcome.ok
            return Entry.new(nil, nil, true) if outcome.stopped
            @skipped += 1 unless outcome.budget_exhausted
            return Entry.new(nil, outcome)
          end
          @left = @every
        end
        @left -= 1
        @inflight += 1
        Entry.new(self)
      end
    end

    # Called by `Entry#leave`. Never takes the gate: the opener of the next epoch holds it while
    # it waits for exactly this.
    def release_slot : Nil
      @inflight -= 1
      return unless @inflight <= 0
      select
      when @drained.send(nil)
      else
      end
    end

    # ── internals ───────────────────────────────────────────────────────────────────

    private def cancelled? : Bool
      !!@cancelled.try(&.call)
    end

    # Park until every admitted candidate has left. A stale wake in the 1-slot buffer only costs
    # one more look at the counter.
    private def wait_drained : Nil
      while @inflight > 0 && !cancelled?
        @drained.receive
      end
    end

    private def execute : Outcome
      outcome =
        begin
          @source.run(@budget, @pacer, @cancelled)
        rescue ex
          Outcome.new(false, @source.labels.size, reason: "the macro raised: #{ex.class.name}: #{ex.message}")
        end
      # A run the budget refused before its first step went nowhere: it is not an execution.
      @runs += 1 unless (outcome.budget_exhausted || outcome.stopped) && outcome.requests == 0
      @requests += outcome.requests
      if outcome.ok
        @consecutive = 0
        return outcome
      end
      # Out of budget, or stopped, is the run ending, not the macro breaking: no failure, no
      # event, no abort.
      return outcome if outcome.budget_exhausted || outcome.stopped
      @failed += 1
      @consecutive += 1
      @first_error ||= outcome.message
      report(outcome)
      settle_abort(outcome)
      outcome
    end

    private def settle_abort(outcome : Outcome) : Nil
      if @spec.on_failure.stop?
        @abort_reason = "#{outcome.message} — the macro is set to stop the run on a failure"
      elsif @consecutive >= FAILURE_LIMIT
        @abort_reason = "#{outcome.message} — #{FAILURE_LIMIT} failures in a row, so the run was ended " \
                        "rather than send a broken step once per candidate"
      end
      if reason = @abort_reason
        @source.note(@event_source, "macro_aborted", :warn, reason)
      end
    end

    # One `events` row per failure, up to `EVENT_CAP`. A success writes none: its History rows
    # are the record, and one event per candidate would be the flood the cap prevents.
    private def report(outcome : Outcome) : Nil
      return if @events_written >= EVENT_CAP
      @events_written += 1
      @source.note(@event_source, "macro_failed", :warn, outcome.message, outcome.flow_ids.last?)
    end
  end
end
