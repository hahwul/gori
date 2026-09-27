require "log"
require "./store"
require "./proxy/pump"
require "./proxy/codec/body"

{% unless flag?(:gc_none) %}
  lib LibGC
    # A full collection that also unmaps every free heap block now, instead of waiting for the
    # block to stay free through GC_unmap_threshold more collections. Public bdwgc API since 7.2;
    # Crystal's own binding only exposes GC_gcollect.
    fun gcollect_and_unmap = GC_gcollect_and_unmap
  end
{% end %}

module Gori
  # Hands an IDLE process's garbage-collected heap back to the OS.
  #
  # Boehm unmaps a free heap block only after it has stayed free through several collections,
  # and a collection only runs when something allocates. An idle proxy allocates nothing, so
  # the heap a burst of traffic grew stays mapped however much of it is garbage. Measured under
  # `gori run capture` after three 15 s load phases (large, chunked, MITM keep-alive): 30 s into
  # idle the physical footprint was still 357 MB with 339 MB of the 365 MB heap free; with this
  # fiber it was 117 MB, 370 MB unmapped by two collections.
  #
  # This supplies those collections, and only when nothing is happening (P6). Once a tick sees
  # neither a store write nor more than BUSY_ALLOC_BYTES of allocation, and that has held for
  # QUIET_FOR, it collects once per CHECK_EVERY while there is free heap worth returning, at
  # most MAX_COLLECTIONS times, then stays out of the way until activity resumes and quiets
  # again. The first sign of traffic re-arms it without collecting. A tick is two counter reads.
  #
  # One fiber per PROCESS, started by each surface that stays up (the TUI, `gori run capture`,
  # `gori mcp`): the heap is process-wide, and so is the question of whether it is busy.
  class IdleGc
    CHECK_EVERY = 1.second
    # How long a process must stay quiet before the first collection. Long enough that a pause
    # between two page loads, or between an agent's tool calls, is not mistaken for idle.
    QUIET_FOR = 10.seconds
    # Allocation within one tick that counts as activity: a fuzz run, a crawl or a streaming body
    # still being captured, none of which necessarily writes to the store every second. A trickle
    # below it (an idle TUI's redraws) is not traffic worth protecting.
    BUSY_ALLOC_BYTES = 256_u64 * 1024
    # Free-but-mapped heap (or garbage allocated since the last collection) below which a
    # collection has nothing worth returning.
    RETURNABLE_MIN_BYTES = 32_u64 * 1024 * 1024
    # Collections per quiet period. `gcollect_and_unmap` reaches the floor in 3-4 in practice;
    # the cap bounds the cost of a heap whose free space never drops below the threshold.
    MAX_COLLECTIONS = 10

    # What one tick looks at. `allocated` is the process's cumulative GC allocation, `writes`
    # the cumulative count of ops the Store writers have taken (see `Store.write_ops`): only
    # their CHANGE between two ticks matters.
    #
    # Traffic that neither writes the Store nor allocates is still traffic: a blind CONNECT
    # tunnel (`forwarded` moves) and a body streaming past the capture limit (`streamed` moves).
    # Bytes MOVING, not a buffer on loan: an open SSE or long-poll body holds its lent copy
    # buffer for hours while nothing flows, and that kept the process "busy" for as long.
    record Sample, allocated : UInt64, free : UInt64, since_gc : UInt64, writes : Int64,
      forwarded : Int64 = 0_i64, streamed : Int64 = 0_i64

    getter collections : Int32 = 0

    def initialize(now : Time::Instant, @last : Sample)
      @quiet_since = now
    end

    # One check. True when the caller should collect now.
    def tick(now : Time::Instant, sample : Sample) : Bool
      busy = sample.writes != @last.writes || sample.allocated &- @last.allocated >= BUSY_ALLOC_BYTES ||
             sample.forwarded != @last.forwarded || sample.streamed != @last.streamed
      @last = sample
      if busy
        @quiet_since = now
        @collections = 0
        return false
      end
      return false if now - @quiet_since < QUIET_FOR
      return false if @collections >= MAX_COLLECTIONS
      # `free` alone would miss the first collection: garbage is not free until a collection
      # finds it, so right after a burst `since_gc` is the part that says there is some.
      return false unless sample.free >= RETURNABLE_MIN_BYTES || sample.since_gc >= RETURNABLE_MIN_BYTES
      @collections += 1
      true
    end

    def self.sample : Sample
      s = GC.stats
      Sample.new(s.total_bytes, s.free_bytes, s.bytes_since_gc, Store.write_ops,
        Proxy::Pump.forwarded, Proxy::Codec::Body.streamed)
    end

    def self.collect : Nil
      {% if flag?(:gc_none) %}
        GC.collect
      {% else %}
        LibGC.gcollect_and_unmap
      {% end %}
    end

    @@started = false

    # Idempotent: the fiber is process-wide, so a TUI that opens a second project does not start
    # a second one.
    def self.start : Nil
      return if @@started
      @@started = true
      spawn(name: "idle-gc") do
        gc = new(Time.instant, sample)
        loop do
          sleep CHECK_EVERY
          collect if gc.tick(Time.instant, sample)
        end
      rescue ex
        # gori.log, never STDERR: in the TUI that is the alternate screen (#411).
        ::Log.warn { "idle-gc stopped: #{ex.message}" }
      end
    end
  end
end
