require "./codec/body"
require "./sink"
require "../sse"

module Gori::Proxy
  # The capture an event-stream response is teed into (#1631): a `Codec::CaptureBuffer` that
  # also hands what it has stored to the sink while the stream is still open, so History shows
  # the events before the origin closes. Every other response keeps the plain buffer and never
  # reaches this code (P6).
  #
  # Batched, never per event: an append goes out once FLUSH_BYTES are pending, or on a write
  # that ends an event once FLUSH_EVERY has passed since the last append (the first event at
  # once), judged inside `write` with no timer fiber. "Ends an event" because the codec tees a
  # chunked body in pieces: the chunk-size line arrives a moment before the event it frames,
  # and appending on it would hold that event back until the next one. A timed stream knows an
  # event ended from its arrivals, so a blank line split across two writes still counts; a
  # compressed one has no events to see, so any write that is not chunk framing (which ends in
  # a line end) counts. What is appended is a prefix of what is stored, so the capture cap caps
  # it too: once the buffer is full nothing more is pending and the appends stop. The final
  # response write carries the whole body and drops the chunks (`CapturedResponse#live?`).
  #
  # ponytail: an event that lands within FLUSH_EVERY of an append and is followed by silence,
  # or a compressed write whose last byte happens to be a line end, waits for the stream's next
  # write (an SSE heartbeat, usually); a timer fiber per stream is the upgrade if that wait
  # matters.
  #
  # `arrivals` times each event the stored bytes complete (`Sse::Arrivals`), so History shows
  # when each one landed; the times ride the same appends, and the final write carries all of
  # them (`event_times`). nil for a compressed stream, which is relayed untimed.
  class LiveCapture < Codec::CaptureBuffer
    FLUSH_BYTES = 16 * 1024
    FLUSH_EVERY = 250.milliseconds
    NO_TIMES    = [] of Int64

    @head : Store::CapturedResponse?
    @flushed = 0
    @flushed_at : Time::Instant? = nil
    @backoff = false
    @timed = 0 # the arrivals the sink has taken

    # `head` is the response with state Pending and no body. It is sent at once, alone, so
    # the status and content type show before the first event does.
    def initialize(limit : Int32, hint : Int64, @sink : FlowSink, head : Store::CapturedResponse,
                   @arrivals : Sse::Arrivals? = nil)
      super(limit, hint)
      @flow_id = head.flow_id
      @head = head
      append_pending
    end

    def write(slice : Bytes) : Nil
      before = stored
      super
      # Only what was stored: an event past the capture cap is not in the body to pair with.
      if (arrivals = @arrivals) && (mem = @mem) && stored > before
        arrivals.feed(mem.to_slice[before, stored - before])
      end
      pending = stored - @flushed
      return if pending == 0
      at = @flushed_at
      due = if @backoff
              at.nil? || Time.instant - at >= FLUSH_EVERY
            elsif pending >= FLUSH_BYTES
              true
            else
              ended?(slice) && (at.nil? || Time.instant - at >= FLUSH_EVERY)
            end
      append_pending if due
    end

    # Whether this write ended an event the sink has not taken. `event_end?` stays beside the
    # arrivals for a stream past `Sse::MAX_EVENTS`, whose times stop growing.
    private def ended?(slice : Bytes) : Bool
      if arrivals = @arrivals
        arrivals.times.size > @timed || event_end?(slice)
      else
        !slice.last?.in?(0x0a_u8, 0x0d_u8)
      end
    end

    # Whether `slice` holds the blank line that ends an SSE event: two line ends in a row, of
    # any of the three spellings (LF, CR, CRLF). CR LF alone is one line end, not two.
    private def event_end?(slice : Bytes) : Bool
      (1...slice.size).any? do |i|
        a, b = slice[i - 1], slice[i]
        (a == 0x0a_u8 || a == 0x0d_u8) && (b == 0x0a_u8 || b == 0x0d_u8) && !(a == 0x0d_u8 && b == 0x0a_u8)
      end
    end

    private def stored : Int32
      @mem.try(&.bytesize) || 0
    end

    # Every event's arrival, for the write that finalizes the flow. nil when untimed.
    def event_times : Bytes?
      @arrivals.try { |a| Sse::Arrivals.pack(a.times) }
    end

    # The offset advances only when the sink took the append. A dropped one (the writer was
    # saturated) is resent inside the next, bigger chunk, so the stored chunks never have a gap,
    # and the retry waits out FLUSH_EVERY whatever is pending, so a saturated writer does not
    # cost a copy of the pending bytes on every write.
    private def append_pending : Nil
      size = stored - @flushed
      mem = @mem
      bytes = mem && size > 0 ? mem.to_slice[@flushed, size].dup : Bytes.empty
      @flushed_at = Time.instant unless bytes.empty?
      times = @arrivals.try(&.times) || NO_TIMES
      if @sink.on_live_body(@flow_id, @flushed.to_i64, bytes, @head, @timed, Sse::Arrivals.pack(times, @timed))
        @flushed += size
        @timed = times.size
        @head = nil
        @backoff = false
      else
        @backoff = true
      end
    end
  end
end
