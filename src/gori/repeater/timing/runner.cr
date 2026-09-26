require "./stats"
require "../plan"

module Gori::Repeater::Timing
  # HOW the pairs are put on the wire each iteration.
  enum Mode
    # Pick the best simultaneous release for the transport (the default): h2 single-packet on one
    # connection, h1 last-byte-sync on two dedicated connections. Both release A and B in the SAME
    # narrow window (#1236), which is what makes their common-mode noise cancel.
    Auto
    # Force the synchronized race even if a caller wanted to override Auto — same path as Auto today,
    # kept distinct so the surfaces can name it and a future Auto heuristic can diverge.
    Race
    # Sequential fallback: send member 0, then member 1, one after the other on their own sends, and
    # ALTERNATE which goes first each iteration (A,B / B,A / …) so first-mover advantage cancels over
    # the run. Noisier than a race (the two are not released together), but works when a race cannot
    # assemble two connections, and is the shape the operator picks with `--interleaved`.
    Interleaved

    def race? : Bool
      self != Interleaved
    end
  end

  # Run the differential-timing measurement: send the plan's TWO requests `iterations` times and
  # hand the collected per-pair durations to `Stats.analyze`. The one place all three surfaces share,
  # kept BELOW the surface so parity is structural (DESIGN.md §2) — the TUI wraps this in a fiber, the
  # CLI and MCP call it on their own fiber.
  #
  # The caller has already validated the plan (one origin, one transport, `plan.refusal` clear) and
  # built it from exactly two members — `run` asserts the pair rather than guessing.
  #
  # P6: bounded `iterations` (the surface clamps to `Stats::MAX_ITERATIONS`); no sleep between pairs;
  # the send itself carries the per-send timeout the plan was built with. `cancel`/`progress` default
  # to no-ops so CLI/MCP need not pass them; the TUI passes real closures (marshalled to its fiber).
  def self.run(plan : Repeater::Plan, iterations : Int32,
               mode : Mode = Mode::Auto,
               warmup : Int32 = Stats::DEFAULT_WARMUP,
               cancel : -> Bool = -> { false },
               progress : Int32 -> = ->(_n : Int32) { }) : Stats::Report
    raise ArgumentError.new("timing analysis compares exactly two requests") unless plan.requests.size == 2
    iterations = iterations.clamp(1, Stats::MAX_ITERATIONS)
    warmup = warmup.clamp(0, iterations - 1)

    samples = [] of Stats::Sample
    total = warmup + iterations
    sent = 0
    while sent < total
      break if cancel.call
      pair = send_pair(plan, mode, sent)
      sent += 1
      next if sent <= warmup # discard the warm-up pairs (TLS / connection warm-up)
      samples << pair
      progress.call(samples.size)
    end

    Stats.analyze(samples)
  end

  # One A/B pair → its two release-relative durations. A member that errored (timeout, reset, a
  # refusal) contributes `nil` — no valid arrival time — so `Stats` drops it from that pair.
  private def self.send_pair(plan : Repeater::Plan, mode : Mode, index : Int32) : Stats::Sample
    if mode.race?
      results = plan.send_race # [A, B] in request order, both released together
      Stats::Sample.new(duration_of(results[0]?), duration_of(results[1]?))
    else
      # ALTERNATE order each iteration to cancel first-mover advantage; record by MEMBER, not by
      # send order.
      a_first = index.even?
      first = plan.sender.send(plan.requests[a_first ? 0 : 1])
      second = plan.sender.send(plan.requests[a_first ? 1 : 0])
      a, b = a_first ? {first, second} : {second, first}
      Stats::Sample.new(duration_of(a), duration_of(b))
    end
  end

  private def self.duration_of(result : Repeater::Result?) : Int64?
    return nil unless result
    result.error.nil? ? result.duration_us : nil
  end
end
