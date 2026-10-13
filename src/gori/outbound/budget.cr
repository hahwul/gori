require "../store"
require "../pacing"
require "../settings/network"

module Gori
  class Outbound
    # The project-wide ceiling on gori-originated requests (#1601): `net.outbound_max_rps` and
    # `net.outbound_max_requests`, held across every run AND every process on one project DB.
    # A run's own `--rate` (`Pacing`) still applies on top; the slower of the two wins.
    #
    # One per (process, Store), shared by every `Outbound` built over that Store, so two TUI
    # runs draw from one lease. A process claims a LEASE of slots from the settings table in one
    # writer task (`Store#lease_outbound_slots`), about `LEASE_SPAN_US` of the rate at a time,
    # and hands them out locally with the `Pacing` ticket rule: the claim is a read and a write
    # with no yield between them. That keeps the cross-process writes to a few per second per
    # process (P6) while every process shares one clock.
    class Budget
      LEASE_SPAN_US = Store::OUTBOUND_LEASE_SPAN_US
      # A lease when only the total is set: no rate to size it by.
      # ponytail: a process that exits without `release` (only the CLI calls it) keeps at most one
      # lease of the total; release from every surface's shutdown if that ever matters.
      COUNT_LEASE = 8
      NAP_US      = Pacing::NAP_SLICE.total_microseconds.to_i64
      # Consecutive failed leases (~5s) before a send is refused rather than left waiting.
      MAX_FAILED_LEASES = 20

      # ponytail: never evicted, so a process that opens many projects keeps one small Budget
      # (and its Store reference) per project it ever sent from. Evict on Store close if it matters.
      @@budgets = {} of UInt64 => Budget

      def self.for(store : Store) : Budget
        @@budgets[store.object_id] ||= new(store)
      end

      def self.now_us : Int64
        (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
      end

      # 0 = no rate ceiling.
      @interval_us = 0_i64
      @max : Int64? = nil
      # The local lease: `@left` slots from `@next_us`, `@interval_us` apart.
      @next_us = 0_i64
      @left = 0
      # Counted against the total but never sent; handed back on the next lease or `release`.
      @refund = 0_i64
      # The total was spent at the last lease. Cleared by `reload`, so a refund or a raised total
      # is seen within a reload while a spent run's refusals cost no write each (P6).
      @spent = false
      @failed = 0
      @lock = Mutex.new

      def initialize(@store : Store)
        reload
      end

      def configured? : Bool
        @interval_us > 0 || !@max.nil?
      end

      # Re-read the two settings rows. `Outbound#refresh` calls this on its own throttle.
      def reload : Nil
        rps = @store.setting(Settings::PROJECT_OUTBOUND_MAX_RPS_KEY).try(&.to_f?)
        @interval_us = if rps && rps.finite? && rps > 0
                         {1_000_000.0 / rps, Pacing::MAX_INTERVAL_SECONDS * 1_000_000}.min.ceil.to_i64
                       else
                         0_i64
                       end
        @max = @store.setting(Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY).try(&.to_i64?).try { |n| n if n > 0 }
        @spent = false
      rescue
        # keep the last-known ceiling, as `Outbound#refresh` keeps the last-known scope
      end

      # Wait for a slot, then nil; or the refusal: `BUDGET_SPENT_ERROR` once the total is gone,
      # `BUDGET_STOPPED_ERROR` when `halt` turned true during a wait (checked every NAP_SLICE),
      # `BUDGET_UNAVAILABLE_ERROR` when the project DB will not take a lease.
      def admit(halt : Proc(Bool)?) : String?
        return nil unless configured?
        loop do
          if slot = take(Budget.now_us)
            return nil if wait_until(slot, halt)
            @refund += 1
            return BUDGET_STOPPED_ERROR
          end
          return BUDGET_SPENT_ERROR if @spent
          return BUDGET_STOPPED_ERROR if halt.try(&.call)
          # Another fiber may have refilled the lease while this one waited for the lock. Any
          # wait happens OUTSIDE the lock, so every waiter keeps checking its own `halt`.
          case r = @lock.synchronize { @left == 0 ? lease : nil }
          when String then return r
          when Int64  then return BUDGET_STOPPED_ERROR unless wait_until(r, halt)
          end
        end
      end

      # Claim the next local slot — a read and a write with no yield between them — or nil when
      # the lease is used up. A slot more than one interval late cannot be used without a burst,
      # so a stale lease is dropped and its count refunded.
      private def take(now : Int64) : Int64?
        if @left > 0 && @interval_us > 0 && @next_us < now - @interval_us
          @refund += @left
          @left = 0
        end
        return nil if @left == 0
        slot = @next_us
        @next_us += @interval_us
        @left -= 1
        slot
      end

      # Refill the local lease from the shared rows: nil to `take` again, the instant to wait
      # for before asking again, or the refusal.
      private def lease : (String | Int64)?
        want = @interval_us > 0 ? (LEASE_SPAN_US // @interval_us).clamp(1_i64, Int32::MAX.to_i64).to_i32 : COUNT_LEASE
        refund, @refund = @refund, 0_i64
        res = @store.lease_outbound_slots(Budget.now_us, @interval_us, want, @max, refund)
        unless res
          # Busy store: fail closed and ask again, never send past the ceiling — but not forever.
          @refund += refund
          @failed += 1
          return BUDGET_UNAVAILABLE_ERROR if @failed >= MAX_FAILED_LEASES
          return Budget.now_us + NAP_US
        end
        @failed = 0
        at, granted = res
        if granted > 0
          @next_us, @left = at, granted
          nil
        elsif at == 0
          @spent = true
          BUDGET_SPENT_ERROR
        else
          at
        end
      end

      # Hand the unsent part of the total back, for a process that is done sending.
      def release : Nil
        @lock.synchronize do
          refund = @refund + (@max ? @left : 0)
          @left = 0
          @refund = 0_i64
          @store.lease_outbound_slots(Budget.now_us, 0_i64, 0, @max, refund) if refund > 0 && @max
        end
      end

      # `Pacing#nap` against the wall clock the leases share: false when `halt` ended the wait.
      private def wait_until(at_us : Int64, halt : Proc(Bool)?) : Bool
        loop do
          return false if halt.try(&.call)
          left = at_us - Budget.now_us
          return true if left <= 0
          sleep({left, NAP_US}.min.microseconds)
        end
      end
    end
  end
end
