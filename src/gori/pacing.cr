module Gori
  # The outbound rate-limit policy the four request-driving engines share: Discover, Fuzz,
  # Miner and Sequencer.
  #
  # It is one policy, not four. Each engine had carried a byte-identical private copy of both
  # methods, and the drift that pattern invites had already happened in the comments: the
  # Fuzzer's copy alone records why the jitter `sleep` sits OUTSIDE the `if interval` guard
  # (gating it behind a base rate silently dropped jitter unless rps/throttle was also set),
  # while the other three carried the fixed code with no trace of the lesson. Anyone reading
  # the Miner's copy would have seen an unexplained line begging to be tidied back into the
  # branch. Sharing the code shares the reasoning with it.
  #
  # The including class supplies two things, which is the whole contract:
  #   `@config`         — responds to `rps`, `throttle_ms` and `jitter_ms`
  #   `@last_dispatch`  — a `Time::Instant` it also initialises
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

    # Wait out the remaining gap before the next request, then apply jitter.
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
    private def pace(interval : Time::Span?) : Nil
      if interval
        now = Time.instant
        target = {@last_dispatch, now}.max
        @last_dispatch = target + interval # claim it before sleeping — no yield in between
        sleep(target - now) if now < target
      end
      # Jitter applies on its own — don't gate it behind a base rate, which silently
      # dropped jitter unless rps/throttle was also set.
      sleep(rand(@config.jitter_ms).milliseconds) if @config.jitter_ms > 0
    end
  end
end
