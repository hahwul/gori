require "./types"
require "./extract"
require "../fuzz/engine"
require "../fuzz/matcher"
require "../pacing"

module Gori::Sequencer
  # Collects tokens into an Event stream. LIVE REPLAY sends the ONE fixed @request
  # repeatedly through the reused Fuzz send seam (wrapped in a CappedBackend hard
  # ceiling) and extracts a token per response; MANUAL emits the pasted tokens without
  # touching the network. The live loop terminates when the goal (counted by successful
  # extractions), the max-sends safety cap, or the request cap is reached — so a wrong
  # descriptor that extracts nothing still ends instead of spinning forever. Analysis
  # is NOT done here: the engine only collects; the consumer runs Stats.analyze over the
  # accumulated tokens.
  #
  # Single-threaded fiber scheduler (no -Dpreview_mt): plain ivar increments never yield
  # mid-op, so the shared counters across dispatcher/worker fibers need no locks.
  class Engine
    # Outbound rate limiting (rps / throttle_ms / jitter_ms) over `@last_dispatch`.
    include Gori::Pacing

    MAX_CONCURRENCY = 50

    enum State : UInt8
      Running
      Paused
      Stopped
    end

    getter events : Channel(Event)

    # nil for an ANALYSE-ONLY engine: manual mode replays a pasted token list and never
    # opens a socket, so it needs no send seam at all. The constructor rejects the other
    # combination (live replay without a backend), which is what makes this nil safe.
    @backend : Fuzz::CappedBackend?
    @concurrency : Int32
    @state : State
    @wake : Channel(Nil)
    @collected : Int32
    @sent : Int32
    @errors : Int32
    @idx : Int32
    @dispatched : Int32
    # Jobs handed to a worker that have not finished yet. Incremented at the dispatch, and
    # decremented in `run_job`'s ensure so a RAISING sample still closes its slot — see
    # `await_outstanding`, which parks on this count.
    @outstanding : Int32
    # Nudged whenever one settles, so the dispatcher can re-decide without polling.
    @settled : Channel(Nil)
    @last_dispatch : Time::Instant
    @token_re : Regex? = nil # Regex token descriptor compiled ONCE per run (see run_live)

    # Final per-run counters, read by a consumer AFTER `run` returns (the block form is
    # synchronous, so they are settled). `first_error` is the first real per-send failure —
    # a max-requests cap is a budget, not a failure, so it is excluded. Without this the
    # reason for a wholly-refused run was counted into `@errors` and the string thrown away,
    # and `gori run sequence` reported "0 collected" and exited 0.
    getter errors : Int32
    getter first_error : String? = nil

    # `backend` is nil ONLY for manual mode, which analyses pasted tokens offline. Live
    # replay without one is rejected here rather than discovered inside a worker fiber —
    # and modelling it as absent is why manual mode no longer needs a throwaway sender
    # pointed at http://localhost:80 just to satisfy this signature.
    def initialize(@request : Bytes, @http2 : Bool, backend : Fuzz::Backend?, @config : Config)
      raise ArgumentError.new("sequencer: live replay needs a send backend") if backend.nil? && !@config.mode.manual?
      # `wire_cap`, not `max_requests`: a surface may impose a hard ceiling of its own on top
      # of the operator's budget, and only the tighter of the two may reach the wire.
      @backend = backend.try { |b| Fuzz::CappedBackend.new(b, @config.wire_cap) }
      @concurrency = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @settled = Channel(Nil).new(1)
      @events = Channel(Event).new(256)
      @collected = 0
      @sent = 0
      @errors = 0
      @idx = 0
      @dispatched = 0
      @outstanding = 0
      @last_dispatch = Time.instant
    end

    # The progress denominator: the goal in live mode, the pasted-token count in manual.
    def total : Int32
      @config.mode.manual? ? @config.manual_tokens.count { |t| !t.empty? } : @config.goal
    end

    def start : Nil
      spawn(name: "sequencer") { orchestrate }
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
      poke(@wake)
      # The dispatcher may be HOLDING for an in-flight sample to settle rather than parked on
      # `@wake` (see `await_outstanding`); without this second nudge a stop taken during that
      # hold waits out the sample before it is noticed.
      poke(@settled)
    end

    def pause : Nil
      @state = State::Paused
    end

    def resume : Nil
      @state = State::Running
      poke(@wake)
    end

    def stopped? : Bool
      @state == State::Stopped
    end

    # ── orchestration ───────────────────────────────────────────────────────────────

    private def orchestrate : Nil
      case @config.mode
      in Mode::Manual     then run_manual
      in Mode::LiveReplay then run_live
      end
      @events.send(DoneEvent.new(@collected, @sent, @state.stopped?, wire_requests))
    rescue ex
      @events.send(ErrorEvent.new(ex.message || "sequencer error"))
      @events.send(DoneEvent.new(@collected, @sent, @state.stopped?, wire_requests))
    ensure
      # Release the keep-alive pool's parked sockets (see `Plan.build`). In the `ensure` so a
      # stopped or raising run leaks no fd — the same standard `Fuzz::Engine` and
      # `Discover::Engine` hold. A no-op for manual mode (no backend) and for the
      # connection-per-send doubles, whose `close` is empty by default.
      # `rescue nil` so a raising close cannot skip the `@events.close` on the next line —
      # that close is what ends the consumer's blocking `receive?`, and without it an MCP
      # job fiber never reaches `finalize_job` and stays pinned at `:running`.
      @backend.try(&.close) rescue nil
      @events.close
    end

    private def run_manual : Nil
      @config.manual_tokens.each do |tok|
        break if @state.stopped?
        next if tok.empty?
        @idx += 1
        @collected += 1
        @events.send(SampleEvent.new(Sample.new(@idx, tok, nil, tok.bytesize, 0_i64, nil)))
        emit_progress
      end
    end

    private def run_live : Nil
      # Unwrapped once here, then passed down. The constructor rejects live-replay-with-no-
      # backend, but `@config` is the caller's LIVE object (the TUI config overlay binds one),
      # so a consumer that flips an analyse-only run's `mode` to LiveReplay after the engine
      # was built lands here — with no sender to reach for. Doing the unwrap on THIS fiber
      # makes that a clean ErrorEvent from orchestrate (and NO traffic) rather than a raise
      # inside a worker fiber; it is the reason manual mode can honestly carry no backend
      # instead of a throwaway sender that would have sent somewhere real.
      backend = @backend || raise Error.new("sequencer: live replay without a send backend")
      # Compile the Regex token descriptor ONCE up front instead of per response. A bad
      # pattern is reported to the operator as a clean error (via orchestrate's ErrorEvent
      # + DoneEvent) rather than raising per-sample inside a worker fiber — which would dump
      # an "Unhandled exception in spawn" trace over the TUI alt-screen and leak the
      # dispatcher fiber blocked on `jobs.send`. Crystal raises ArgumentError (not only
      # Regex::Error) for an invalid pattern, so catch both.
      if @config.token_loc.kind.regex? && !@config.token_loc.selector.empty?
        begin
          @token_re = Regex.new(@config.token_loc.selector)
        rescue ex : ArgumentError | Regex::Error
          @events.send(ErrorEvent.new("invalid token regex: #{ex.message}"))
          return
        end
      end
      interval = pace_interval
      # Int32 job tokens (not Channel(Nil)): with a Nil channel, `receive?` returns nil
      # for BOTH a sent value and a closed channel, so the worker loop can't tell a job
      # from shutdown. Any Int32 (even 0) is truthy, so `while jobs.receive?` ends only
      # on close.
      jobs = Channel(Int32).new(@concurrency)
      finished = Channel(Nil).new(@concurrency)

      spawn(name: "sequencer-dispatch") do
        loop do
          break if @state.stopped?
          park_if_paused
          break if @state.stopped?
          # Hold — do not break — while enough samples are already IN FLIGHT to reach the
          # goal; see `await_outstanding` for what the old break cost.
          await_outstanding
          break if @state.stopped?
          break if @collected >= @config.goal
          break if @dispatched >= @config.max_sends
          break if backend.cap_reached?
          pace(interval)
          # BEFORE the send: `jobs.send` yields when the buffer is full, and during that
          # yield a worker can take this very job and settle it — decrementing a slot the
          # dispatcher had not opened yet.
          @dispatched += 1
          @outstanding += 1
          jobs.send(@dispatched)
        end
      ensure
        jobs.close
      end

      @concurrency.times do |i|
        spawn(name: "sequencer-worker-#{i}") do
          while jobs.receive?
            run_job(backend)
          end
        ensure
          finished.send(nil)
        end
      end

      @concurrency.times { finished.receive }
    end

    # Hold the dispatch loop while enough samples are already IN FLIGHT to reach the goal.
    #
    # `@collected + @outstanding` is an optimistic projection of the final collected count —
    # what the run ends on if every outstanding job extracts a token. The loop used to BREAK
    # on that projection, which is right only while every sample hits: an outstanding job
    # that MISSES lowers it again, and by then the dispatcher was gone. So a collection whose
    # LAST samples missed ended below its goal with the `max_sends` budget untouched —
    # measured at 19/20 tokens at concurrency 1 and 35/40 at concurrency 5 against a
    # 50%-extracting origin, the shortfall growing with concurrency, on a run that had 40 and
    # 80 sends of budget left. (Misses BEFORE the projection first reaches the goal were
    # topped up correctly all along, which is what kept this narrow enough to miss.)
    #
    # Holding re-decides when a sample settles instead, so the run tops up a late miss and
    # still lands EXACTLY on the goal — the no-overshoot property the break was there for.
    # `max_sends` (below) is what bounds a descriptor that never matches; this wait cannot
    # outlive the `finished.receive` join that already waits on the same jobs, so it adds no
    # way to hang that the run did not already have.
    private def await_outstanding : Nil
      while !@state.stopped? && @collected < @config.goal &&
            @collected + @outstanding >= @config.goal && @outstanding > 0
        @settled.receive
      end
    end

    # One sample, with the worker fiber's survival and its dispatch slot both guaranteed.
    #
    # Without the rescue, a raise out of `process_one` kills the worker. `finished` still
    # fires from the loop's `ensure`, so the join completes and the run reports Done — but
    # the DISPATCHER is left parked on `jobs.send` (buffered to @concurrency) with no
    # receiver, never reaches its own `ensure jobs.close`, and leaks forever holding the
    # engine and a `CappedBackend` that `orchestrate`'s ensure has already closed. The
    # comment above `run_live` names this exact leak and guards only the invalid-regex
    # case; this covers the rest. Count the sample as an error and keep sampling.
    private def run_job(backend : Fuzz::CappedBackend) : Nil
      process_one(backend) unless @state.stopped?
    rescue ex
      @errors += 1
      @first_error ||= ex.message || ex.class.name
    ensure
      # In the ensure, and covering the stopped-skip above too: `@outstanding` is what
      # `await_outstanding` parks on, so a job that never closed its slot would hold that
      # wait open — the raise that used to merely skew a projection would now hang the run.
      @outstanding -= 1
      poke(@settled)
    end

    private def process_one(backend : Fuzz::CappedBackend) : Nil
      raw = send_with_retries(backend, @request)
      @sent += 1
      token = Extract.extract(raw, @config.token_loc, @token_re)
      # An EMPTY extraction is a MISS, not a collected token. `Set-Cookie: SID=` — what an
      # origin sends to DELETE the session once the replayed one goes stale — and an empty
      # header both hand back `""`, which is truthy in Crystal, so those samples counted
      # toward the goal, carried no error, and were then dropped by `Stats.analyze` (which
      # rejects empty tokens): the run reported "500 collected" over a report reading
      # "0 usable / 500 total · rating CRITICAL (no usable tokens)". Manual mode has always
      # skipped an empty token; live replay was the half that did not.
      token = nil if token && token.empty?
      idx = (@idx += 1)
      status = raw.response.try(&.status)
      len = token.try(&.bytesize) || 0
      err = raw.error || (token ? nil : "no token matched")
      if e = raw.error
        @errors += 1
        @first_error ||= e unless e == Fuzz::CappedBackend::CAP_ERROR
      end
      @collected += 1 if token
      # The gRPC CALL's real outcome — `status` above is 200 for every gRPC response, so
      # without this a live-replay collection against a target rejecting every call (an
      # expired session cookie, say) read as healthy on every sample. nil/nil (and free, past
      # the allocation-free needle scan) for a non-gRPC response.
      grpc_status, grpc_message = Fuzz::GrpcVerdict.response(raw.head)
      @events.send(SampleEvent.new(Sample.new(idx, token, status, len, raw.duration_us, err,
        grpc_status, grpc_message)))
      emit_progress
    end

    private def send_with_retries(backend : Fuzz::CappedBackend, bytes : Bytes) : Repeater::Result
      attempts = 0
      loop do
        raw = backend.send(bytes)
        return raw if raw.error.nil? || permanent_refusal?(raw.error) || attempts >= @config.retries
        attempts += 1
        # A STOP ends the retry chain. It was honoured everywhere else in the run — the
        # dispatcher breaks, a worker skips its next job — and invisible only here, where a
        # retry is a NEW request: measured, a `stop` mid-chain put 18 more requests on the
        # wire and held the run open 490ms past it, and MCP's ceilings (`retries` up to 1000,
        # `retry_pause` 500ms by default) scale that to 1000 requests and ~8 minutes PER
        # WORKER after `sequence_stop` returned. Checked on BOTH sides of the pause so
        # neither a stop that arrived during the send nor one during the pause costs another.
        return raw if @state.stopped?
        sleep @config.retry_pause
        return raw if @state.stopped?
      end
    end

    # Refusals no retry can change: the request budget is spent, or Layer 2 said no. Only the
    # cap was exempt here, so a sandboxed or excluded target burned `retries` attempts and the
    # collection slept its way to `max_sends` with nothing collected. The Layer-2 half of the
    # rule lives once, on `Outbound.permanent_refusal?` (read its comment for why the cap is
    # not folded in there); the cap is asked here because `CappedBackend#send` charges it
    # BEFORE the gate refuses, so a re-ask costs a second request for a fixed answer.
    private def permanent_refusal?(err : String?) : Bool
      err == Fuzz::CappedBackend::CAP_ERROR || Gori::Outbound.permanent_refusal?(err)
    end

    # ── counters / pacing ───────────────────────────────────────────────────────────

    # Requests actually put on the wire, retries included — see `ProgressEvent#requests`.
    # 0 on an analyse-only plan, which has no backend and opens no socket.
    private def wire_requests : Int64
      @backend.try(&.sent) || 0_i64
    end

    private def emit_progress : Nil
      ev = ProgressEvent.new(@collected, @sent, total, @errors, wire_requests)
      select
      when @events.send(ev)
      else
      end
    end

    private def park_if_paused : Nil
      while @state == State::Paused
        @wake.receive
      end
    end

    # A non-blocking nudge. Dropping it when the buffer is already full costs nothing: the
    # receiver re-reads `@state` and the counters and decides for itself, so a token that
    # never lands only means the decision it would have triggered has already been made.
    private def poke(ch : Channel(Nil)) : Nil
      select
      when ch.send(nil)
      else
      end
    end
  end
end
