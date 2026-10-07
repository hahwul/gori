module Gori
  # The outbound rate-limit policy the four request-driving engines share: Discover, Fuzz,
  # Miner and Sequencer.
  #
  # It is one policy, not four. Each engine had carried a byte-identical private copy of both
  # methods, and the drift that pattern invites had already happened in the comments: one
  # copy alone recorded a lesson the other three carried with no trace of it. Sharing the
  # code shares the reasoning with it.
  #
  # The including class supplies three things, which is the whole contract:
  #   `@config`         — responds to `rps` and `throttle_ms`
  #   `@last_dispatch`  — a `Time::Instant` it also initialises
  #   `stopped?`        — true once the run was asked to stop; ends a wait in progress
  #
  # `@last_dispatch` is deliberately the includer's own ivar rather than state owned here:
  # each engine keeps ONE clock for its whole run. It is shared across the orchestrator and
  # its workers on purpose — see `pace`, which claims a slot without yielding so concurrent
  # fibers serialise onto it rather than racing.
  module Pacing
    # The gap to hold between dispatches, or nil when the run is unthrottled.
    #
    # `rps` wins over `throttle_ms` when both are set — a requests-per-second budget is the
    # more specific statement of intent, and the two would otherwise compose into a rate
    # neither knob names.
    # The largest gap worth expressing. `(1.0 / rps).seconds` on an absurdly small rate
    # (`--rate=1e-20` → 1e20 seconds) raises `OverflowError` building the Span; the engine
    # loops catch it, but the operator was then told "Arithmetic overflow" rather than
    # anything about the rate they typed. Clamping keeps the knob monotonic — smaller rate,
    # longer wait — and tops out at a gap no run outlives anyway.
    MAX_INTERVAL_SECONDS = 86_400.0

    private def pace_interval : Time::Span?
      if (rps = @config.rps) && rps > 0
        secs = 1.0 / rps
        secs = MAX_INTERVAL_SECONDS unless secs.finite? && secs < MAX_INTERVAL_SECONDS
        secs.seconds
      elsif (t = @config.throttle_ms) && t > 0
        t.milliseconds
      end
    end

    # Wait out the remaining gap before the next request.
    #
    # A TICKET, not a "sleep until the last one was long enough ago": each caller claims the
    # next slot by advancing `@last_dispatch` and only then sleeps until its own slot. The
    # claim is a read and a write with no yield between them, so under the single-threaded
    # cooperative scheduler two fibers cannot take the same slot — which is what makes this
    # safe to call from a WORKER and not just from the orchestrator.
    #
    # That matters because the operator-facing knob is `--rate=RPS "Cap requests/sec"`, a
    # promise about REQUESTS. Pacing only the orchestrator's dispatch loop kept that promise
    # only where one dispatched unit is one request; every path that fans a unit out into
    # several sends (a redirect chain, a confirm round, a calibration batch) then ran its
    # extra requests unpaced, and the rate the operator set did not hold.
    #
    # `{.., now}.max` floors the claim at the present: after an idle stretch the stored
    # instant is far in the past, and without the floor a burst of callers would all compute
    # a target already elapsed and go out at once — the opposite of a rate limit.
    #
    # Returns false when the run was stopped during the wait: the slot it waited for is not
    # a send to make, and every caller skips it. Sending anyway let a stop release all the
    # held slots at once, unpaced.
    private def pace(interval : Time::Span?) : Bool
      if interval
        now = Time.instant
        target = {@last_dispatch, now}.max
        @last_dispatch = target + interval # claim it before sleeping — no yield in between
        nap(target - now) if now < target
      end
      !stopped?
    end

    NAP_SLICE = 250.milliseconds

    # `sleep`, in slices that re-check `stopped?`. A gap can be MAX_INTERVAL_SECONDS (a
    # `--rate` of 1e-9) or a ten-minute throttle, and one unsliced sleep held the run
    # "running" through a stop for that long — while MCP refused to switch or delete the
    # project until it ended.
    private def nap(span : Time::Span) : Nil
      deadline = Time.instant + span
      until stopped?
        left = deadline - Time.instant
        break unless left.positive?
        sleep({left, NAP_SLICE}.min)
      end
    end

    # A non-blocking channel send: deliver `value` if the buffer has room, drop it otherwise.
    # The droppable events these engines emit — a progress nudge, an idle/wake poke — carry no
    # state a receiver cannot re-derive from the counters, so a full buffer means the decision
    # the dropped one would have triggered has already been made. Blocking here instead would
    # let a slow consumer stall the hot send loop (P6).
    private def offer(channel : Channel(T), value : T) : Nil forall T
      select
      when channel.send(value)
      else
      end
    end
  end
end
