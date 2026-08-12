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
      @backend = backend.try { |b| Fuzz::CappedBackend.new(b, @config.max_requests) }
      @concurrency = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @events = Channel(Event).new(256)
      @collected = 0
      @sent = 0
      @errors = 0
      @idx = 0
      @dispatched = 0
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
      poke
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
      @backend.try(&.close)
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
          # Stop handing out jobs once enough are already IN FLIGHT to reach the
          # goal, not only once they've fully round-tripped. `@dispatched - @sent`
          # is the outstanding (dispatched-but-not-yet-completed) count — @sent
          # increments in process_one right after the send returns, success or
          # not — so this sum is an optimistic projection of the final collected
          # count if every outstanding job extracts a token. It only grows via a
          # dispatch here (+1) and only shrinks via an extraction MISS in
          # process_one (-1), so it steps by exactly ±1 and lands on @config.goal
          # exactly (no overshoot) whenever the goal is reachable, while still
          # letting the loop keep dispatching past a run of misses (bounded by
          # max_sends below) — unlike the old `@collected >= @config.goal` check,
          # which only reacted after a full round-trip and let the channel's
          # buffer slot plus one already-in-flight worker job race the goal by up
          # to 2 extra live requests.
          break if @collected + (@dispatched - @sent) >= @config.goal
          break if @dispatched >= @config.max_sends
          break if backend.cap_reached?
          pace(interval)
          jobs.send(@dispatched)
          @dispatched += 1
        end
      ensure
        jobs.close
      end

      @concurrency.times do |i|
        spawn(name: "sequencer-worker-#{i}") do
          while jobs.receive?
            next if @state.stopped?
            process_one(backend)
          end
        ensure
          finished.send(nil)
        end
      end

      @concurrency.times { finished.receive }
    end

    private def process_one(backend : Fuzz::CappedBackend) : Nil
      raw = send_with_retries(backend, @request)
      @sent += 1
      token = Extract.extract(raw, @config.token_loc, @token_re)
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
        return raw if raw.error.nil? || raw.error == Fuzz::CappedBackend::CAP_ERROR || attempts >= @config.retries
        attempts += 1
        sleep @config.retry_pause
      end
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

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end
  end
end
