require "../sse"
require "../proxy/socket_tuning"
require "./live_body"

module Gori
  module Repeater
    # Stop reading a `text/event-stream` response after `max_events` events or `max_time` of
    # streaming, whichever comes first (#1631). Without it a send to an SSE endpoint read until
    # the 8 MiB capture ceiling or the idle timeout, so one fuzz payload could cost 30 s.
    #
    # Applied only once the response head says `text/event-stream`: every other response reads
    # exactly as before. A bounded stop is a SUCCESS with the events read so far as the body,
    # reported through `Result#bounded`; the stream's socket is not reused (`incomplete?`).
    # nil on either axis leaves that axis unbounded.
    #
    # `live` is the TUI's sink: the stream's bytes as they arrive, for a view that renders the
    # events before the send returns. The TUI passes a bound with no axis and a sink, so its
    # Stop (the send's cancel) keeps the events read so far.
    record StreamBound, max_events : Int32? = nil, max_time : Time::Span? = nil, live : LiveBody? = nil do
      # The Fuzzer's and the Miner's default: one payload must not wait out an open stream.
      SWEEP = new(50, 5.seconds)
      # MCP `send_request` and `gori run repeater`: one send, so a longer look.
      SEND = new(100, 10.seconds)

      # A surface's two arguments over `default`: an absent axis takes the default's value, and
      # 0 (or less) switches that axis off. nil when both end up off.
      def self.resolve(events : Int64?, time : Time::Span?, default : StreamBound) : StreamBound?
        e = events.nil? ? default.max_events : (events <= 0 ? nil : events.clamp(1_i64, Int32::MAX.to_i64).to_i)
        t = time.nil? ? default.max_time : (time <= Time::Span.zero ? nil : time)
        e || t ? new(e, t) : nil
      end

      # The bounded read of a response the caller has already found to be an event stream
      # (`Sse.sse?` on its Content-Type, checked first because every swept response asks).
      # `encoding` is the response's Content-Encoding: the events of a compressed stream can't
      # be counted as they arrive, so only the time axis applies to one. `head` opens `live`.
      def start(encoding : String?, chunked : Bool, cancel : Proc(Bool)? = nil,
                head : Bytes = Bytes.empty) : StreamRun
        countable = encoding.nil? || encoding.strip.empty? || encoding.strip.compare("identity", case_insensitive: true) == 0
        live.try(&.open(head))
        StreamRun.new(countable ? max_events : nil, max_time, chunked, cancel, live)
      end
    end

    # One event stream under a `StreamBound`, from its response head on. Shared by the h1
    # engine (through `BoundedRead`) and the h2 engine's DATA branch.
    class StreamRun
      # "events" or "time" once a bound stopped the stream, "cancelled" when the send's cancel
      # did. Becomes `Result#bounded`.
      getter reason : String?

      @counter : Sse::Counter?
      @deadline : Time::Instant?
      # De-chunking for the COUNT only: `Body.read_complete` stays the framing authority, and a
      # size line this cannot read just stops the count (the time axis still holds).
      @chunk = :size
      @chunk_left = 0_i64
      @chunk_ext = false

      def initialize(@max_events : Int32?, max_time : Time::Span?, @chunked : Bool,
                     @cancel : Proc(Bool)? = nil, @live : LiveBody? = nil)
        @counter = Sse::Counter.new if @max_events
        @deadline = max_time.try { |t| Time.instant + t }
      end

      def stopped? : Bool
        !@reason.nil?
      end

      # Time left on the time axis (nil when it has none). Records the stop once it is spent.
      def remaining : Time::Span?
        deadline = @deadline || return nil
        left = deadline - Time.instant
        @reason ||= "time" if left <= Time::Span.zero
        left
      end

      # Why a read that raised should end the stream instead of failing the send: the time
      # bound ran out under it, or the send's cancel closed the socket. nil = a real failure.
      def stop_on_error : String?
        return @reason if (left = remaining) && left <= Time::Span.zero
        @reason ||= "cancelled" if @cancel.try(&.call)
        @reason
      end

      # Counts the wire bytes just read and returns how many of them the capture keeps: all of
      # them, or only those up to the end of the `max_events`th event. The kept ones go to
      # `live` too.
      def take(bytes : Bytes) : Int32
        n = keep(bytes)
        @live.try(&.append(bytes[0, n]))
        n
      end

      private def keep(bytes : Bytes) : Int32
        counter = @counter
        limit = @max_events
        return bytes.size unless counter && limit && !stopped?
        at = @chunked ? feed_chunked(counter, limit, bytes) : counter.feed(bytes, limit)
        return bytes.size unless at
        @reason = "events"
        at
      end

      private def feed_chunked(counter : Sse::Counter, limit : Int32, bytes : Bytes) : Int32?
        i = 0
        while i < bytes.size
          case @chunk
          when :data
            n = Math.min(@chunk_left, (bytes.size - i).to_i64).to_i
            if at = counter.feed(bytes[i, n], limit)
              return i + at
            end
            i += n
            @chunk_left -= n
            @chunk = :crlf if @chunk_left == 0
          when :size
            size_byte(bytes[i])
            i += 1
          when :crlf
            @chunk = :size if bytes[i] == '\n'.ord
            i += 1
          else
            return nil # past the last chunk: trailers, or a size line this could not read
          end
        end
        nil
      end

      # One byte of a chunk-size line.
      private def size_byte(b : UInt8) : Nil
        if b == '\n'.ord
          @chunk = @chunk_left == 0 ? :done : :data
          @chunk_ext = false
        elsif !@chunk_ext && (d = b.chr.to_i?(16))
          return @chunk = :done if @chunk_left >= Int64::MAX >> 4 # past any real size
          @chunk_left = @chunk_left * 16 + d
        else
          @chunk_ext = true # `;ext`, CR, whitespace
        end
      end
    end

    # The h1 body source under a `StreamRun`. `Body.read_complete` reads through this, so the
    # capture keeps every byte read before the stop, and the framing code never learns a bound
    # exists: a stop is an EOF, which it reports as a short body.
    #
    # The time axis is the head deadline's mechanism (`Http1.read_head_result`): the socket's
    # read timeout shrinks toward what is left before each read, so a blocked read wakes at the
    # bound with no timer fiber, on a pooled socket as on a one-shot one. `restore` puts the
    # idle timeout back for a stream that ended on its own and may be parked.
    class BoundedRead < IO
      @sock : ::Socket?
      @idle : Time::Span?

      def initialize(@io : IO, @run : StreamRun)
        @sock = Proxy::SocketTuning.underlying_socket(@io)
        @idle = @sock.try(&.read_timeout)
      end

      def read(slice : Bytes) : Int32
        return 0 if @run.stopped?
        if left = @run.remaining
          return 0 if left <= Time::Span.zero
          idle = @idle
          @sock.try(&.read_timeout = idle && idle < left ? idle : left)
        end
        n = @io.read(slice)
        n == 0 ? 0 : @run.take(slice[0, n])
      rescue ex
        raise ex unless @run.stop_on_error
        0
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("BoundedRead is read-only")
      end

      def restore : Nil
        @sock.try(&.read_timeout = @idle)
      rescue
        # The socket is retired anyway when this fails.
      end
    end
  end
end
