module Gori::Tui
  # The run loop's tick-error circuit breaker, as arithmetic: `limit` raises recorded inside
  # `window` and the breaker is tripped. `Runner#absorb_tick_error` owns the policy of WHICH
  # raises count (an input-phase raise does; a full render's first failure does not — it is
  # answered with the reduced frame instead); this class only keeps the tally. Pure and
  # Runner-free for the same reason `Runner.decorate_status` is: `Runner.new` owns a terminal
  # and appears nowhere under spec/, so the rule has to live where a spec can reach it.
  class TickBreaker
    getter limit : Int32
    getter window : Time::Span

    def initialize(@limit : Int32, @window : Time::Span)
      @stamps = [] of Time::Instant
    end

    # Record one strike at `now` and return how many are inside the window, this one
    # included. Strikes older than the window are forgotten first, so a raise every few
    # minutes never accumulates into a trip.
    def record(now : Time::Instant = Time.instant) : Int32
      @stamps.reject! { |t| now - t > @window }
      @stamps << now
      @stamps.size
    end

    # Whether the strikes still inside the window at `now` have reached the limit.
    def tripped?(now : Time::Instant = Time.instant) : Bool
      @stamps.count { |t| now - t <= @window } >= @limit
    end

    def reset : Nil
      @stamps.clear
    end
  end
end
