require "../proxy/codec/http1"
require "../sse"

module Gori
  module Repeater
    # An event-stream response while it is still arriving (#1631), for a surface that shows the
    # stream before the send returns. The send fiber's `StreamRun` writes it, from the response
    # head on, with the same bytes the capture keeps; the surface reads it on its own fiber and
    # sets `stop` to end the stream. Only an event stream is ever written: every other response
    # leaves it empty and arrives through the send's Result alone.
    #
    # No lock: gori runs one cooperative scheduler, so a read between two appends sees a
    # consistent prefix (P6).
    class LiveBody
      # The response head, set once the head says `text/event-stream`. nil until then.
      getter head : Bytes?
      getter? stopped = false
      @body = IO::Memory.new
      @arrivals : Sse::Arrivals?

      # `arrivals` times each event as it lands; nil for a stream whose events can't be counted
      # as they arrive (a compressed one).
      def open(head : Bytes, arrivals : Sse::Arrivals? = nil) : Nil
        @head = head
        @arrivals = arrivals
      end

      def append(bytes : Bytes) : Nil
        @body.write(bytes)
        @arrivals.try(&.feed(bytes))
      end

      # When each event so far arrived (`Sse::Arrivals`); nil when untimed.
      def times : Array(Int64)?
        @arrivals.try(&.times)
      end

      def size : Int32
        @body.bytesize
      end

      # The send's cancel predicate reads this, so it closes the socket; the engine keeps the
      # body read so far (`StreamRun#stop_on_error`).
      def stop : Nil
        @stopped = true
      end

      # The stream so far as a Result, for a view that renders one. A copy: the buffer grows
      # under it.
      def result(started : Time::Instant) : Result?
        head = @head || return nil
        Result.new(head, @body.to_slice.dup, Proxy::Codec::Http1.parse_response_head(head),
          Engine.elapsed(started), incomplete: true)
      end
    end
  end
end
