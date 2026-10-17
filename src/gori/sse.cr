require "./proxy/codec/content_decode"
require "./media_type"
require "./utf8"

module Gori
  # Parses a Server-Sent Events (`text/event-stream`) body into discrete events.
  # This is a DISPLAY-time projection over an already content-decoded body — the
  # counterpart of `Proxy::H2::Grpc.messages` for gRPC. gori captures an SSE
  # response as one opaque body blob (it streams through the generic body path);
  # this splits it back into the events the server emitted so the detail view can
  # show them individually instead of as a wall of `event:`/`data:` lines.
  #
  # Follows the WHATWG event-stream parsing rules: UTF-8; CR, LF, or CRLF line
  # terminators; `event:` / `data:` / `id:` / `retry:` fields; one optional space
  # after the colon is stripped; lines starting with `:` are comments. An event is
  # dispatched at each blank line; a block with no `data` field is not emitted.
  module Sse
    # Safety ceiling on events parsed from one body, so a pathological stream of
    # millions of tiny events can't blow up memory (the detail view caps display
    # separately). Far above any realistic captured stream.
    MAX_EVENTS = 100_000

    # Ceiling on one event's `data`, the ceiling every body projection already shares
    # (`Pretty::MAX_OUT_PRETTY`). Data lines past it are dropped; the rest of the stream
    # still parses.
    MAX_EVENT_DATA = 8 * 1024 * 1024

    # One dispatched SSE event. `type` is the `event:` field (nil = the default
    # "message"); `data` is the joined data lines with no trailing newline; `id`
    # is the last-event-id in effect at dispatch; `retry` is the `retry:`
    # reconnection time (ms) if the block carried one.
    record Event,
      type : String?,
      data : String,
      id : String?,
      retry : Int32?

    def self.sse?(content_type : String?) : Bool
      MediaType.essence(content_type) == "text/event-stream"
    end

    # True when a response head declares a text/event-stream body. Resolves the
    # Content-Type value (case-insensitive name, any/no space after the colon, charset
    # params) and reuses sse? — the single source of truth all surfaces call, instead
    # of each doing a brittle `includes?("content-type: text/event-stream")` scan. The scan
    # itself is `MediaType.of` — the one every body decoder now shares, and the one that stops
    # at the blank line ending the head instead of reading on into the body.
    def self.event_stream?(head : Bytes?) : Bool
      sse?(MediaType.of(head))
    end

    # The events of an event-stream RESPONSE: content-decode (de-chunk/inflate) the
    # body, then parse. The single helper all three surfaces (History, `gori run
    # show`, MCP) call so the decode→parse incantation isn't triplicated. Returns
    # [] when the response isn't a text/event-stream.
    def self.from_response(head : Bytes?, body : Bytes?) : Array(Event)
      return [] of Event unless event_stream?(head)
      decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
      events(decoded || body || Bytes.empty)
    end

    # Splits an event-stream body into events. Tolerant: a trailing block without
    # its terminating blank line (a capture cut mid-stream) is still emitted, so a
    # truncated stream shows its last partial event rather than dropping it.
    #
    # One pass over the bytes, line by line. The body is up to 32 MiB of decoded content the
    # SERVER chose, and the old shape — `String.new` + `scrub` + two whole-body `gsub`s + one
    # `split` — copied it five times and then made a String per line: 32 MiB of `a\n` (a 32 KB
    # gzip) cost ~760 MiB per History view, MCP `get_flow` or `gori run show`. Now only the
    # values gori keeps become Strings, and a block's data accumulates in one buffer.
    def self.events(body : Bytes) : Array(Event)
      events = [] of Event
      return events if body.empty?
      state = Block.new
      pos = 0
      # Drop one leading BOM (U+FEFF) — WHATWG preprocessing — so the first field name isn't
      # mangled (a BOM-prefixed stream would otherwise lose its first event).
      pos = 3 if body.size >= 3 && body[0] == 0xEF && body[1] == 0xBB && body[2] == 0xBF
      while pos < body.size
        break if events.size >= MAX_EVENTS
        line, pos = next_line(body, pos)
        if line.empty?
          state.flush(events)
        else
          state.field(line)
        end
      end
      state.flush(events) if events.size < MAX_EVENTS # trailing block (no terminating blank line)
      events
    end

    # The line starting at `pos`, and where the next one starts. CR, LF and CRLF all end a
    # line; a lone CR is a terminator of its own (WHATWG).
    private def self.next_line(body : Bytes, pos : Int32) : {Bytes, Int32}
      stop = pos
      while stop < body.size && body[stop] != '\n'.ord && body[stop] != '\r'.ord
        stop += 1
      end
      after = stop + 1
      after += 1 if body[stop]? == '\r'.ord && body[after]? == '\n'.ord
      {body[pos, stop - pos], after}
    end

    # One block's fields as they arrive, plus the stream-level last event id.
    private class Block
      @last_id = nil.as(String?) # stream-level: persists across blocks (per spec)
      @data = IO::Memory.new     # the block's data lines, LF-joined, as raw bytes
      @data_lines = 0
      @truncated = false
      @type = nil.as(String?)
      @retry = nil.as(Int32?)

      def field(line : Bytes) : Nil
        return if line[0] == ':'.ord # a comment
        # SSE is UTF-8; invalid bytes become U+FFFD (display-only, never re-sent).
        name, value = split(line)
        case name
        when "event".to_slice
          @type = value.empty? ? nil : Utf8.text(value) # empty ⇒ default (nil)
        when "data".to_slice
          data(value)
        when "id".to_slice
          @last_id = Utf8.text(value) unless value.includes?(0_u8) # a NUL ⇒ ignore the id
        when "retry".to_slice
          @retry = Sse.retry_ms(value) || @retry # invalid keeps the prior
        end
      end

      private def split(line : Bytes) : {Bytes, Bytes}
        Sse.split(line)
      end

      private def data(value : Bytes) : Nil
        sep = @data_lines > 0 ? 1 : 0
        if @truncated || @data.bytesize + sep + value.size > MAX_EVENT_DATA
          @truncated = true
          return
        end
        @data.write_byte('\n'.ord.to_u8) if sep == 1
        @data.write(value)
        @data_lines += 1
      end

      # A block emits an event only if it carried at least one `data` field.
      def flush(events : Array(Event)) : Nil
        if @data_lines > 0 || @truncated
          events << Event.new(@type, Utf8.text(@data.to_slice), @last_id, @retry)
        end
        @data.clear
        @data_lines = 0
        @truncated = false
        @type = nil
        @retry = nil
      end
    end

    # {name, value}. A line with no colon is a field whose value is empty, and one optional
    # space after the colon goes (WHATWG).
    protected def self.split(line : Bytes) : {Bytes, Bytes}
      colon = line.index(':'.ord.to_u8) || return {line, Bytes.empty}
      value = line[(colon + 1)..]
      value = value[1..] if value[0]? == ' '.ord
      {line[0, colon], value}
    end

    # Counts the events `events` would dispatch, fed the body as it arrives, for a sender that
    # stops after N events (`Repeater::StreamBound`) and must not re-parse the whole stream on
    # every read. The same rules: CR, LF or CRLF end a line (a CRLF split across two feeds is
    # one terminator), a leading BOM is dropped, and a blank line dispatches only a block that
    # carried a `data` field. It keeps the first bytes of each line, enough for `split` to tell
    # a `data` field from any other.
    class Counter
      getter count = 0
      @head = Bytes.new(8) # a BOM plus `data:`
      @len = 0
      @data = false
      @cr = false
      @first = true

      # Feeds `bytes`. Returns how many of them it took to dispatch the `limit`th event, or nil
      # when the limit was not reached in them.
      def feed(bytes : Bytes, limit : Int32) : Int32?
        bytes.each_with_index do |b, i|
          lf = b == '\n'.ord
          if @cr && lf # the LF of a CRLF
            @cr = false
            next
          end
          @cr = b == '\r'.ord
          if lf || @cr
            line_end
            if @count >= limit
              return bytes[i + 1]? == '\n'.ord && @cr ? i + 2 : i + 1
            end
          else
            @head[@len] = b if @len < @head.size
            @len += 1
          end
        end
        nil
      end

      private def line_end : Nil
        if @len == 0
          @count += 1 if @data
          @data = false
        else
          line = @head[0, Math.min(@len, @head.size)]
          line = line[3..] if @first && line.size >= 3 && line[0] == 0xEF && line[1] == 0xBB && line[2] == 0xBF
          @data = true if Sse.split(line)[0] == "data".to_slice
        end
        @first = false
        @len = 0
      end
    end

    # Renders parsed events as text: a header line per event (type/id/retry when set) then its
    # data, indented. The whole stream is server→client, so no arrows. `base` is the count of
    # older events a window dropped, so the visible numbers stay continuous with a "showing
    # latest N of M" note (no restart at #1). The one rendering History's EVENTS pane and the
    # Repeater's response share.
    def self.display_lines(events : Array(Event), base : Int32 = 0) : Array(String)
      return ["(no events)"] if events.empty?
      lines = [] of String
      events.each_with_index do |e, i|
        meta = String.build do |io|
          io << "▸ event #" << base + i + 1
          io << "  type=" << e.type if e.type
          io << "  id=" << e.id if e.id
          io << "  retry=" << e.retry if e.retry
        end
        lines << meta
        # Cap a single event's data lines so one pathological multi-MB event can't
        # materialise a giant row array (the event COUNT is windowed separately).
        dls = e.data.split('\n')
        dls.first(EVENT_DATA_LINE_CAP).each { |dl| lines << "    #{dl}" }
        lines << "    … (#{dls.size - EVENT_DATA_LINE_CAP} more lines)" if dls.size > EVENT_DATA_LINE_CAP
      end
      lines
    end

    EVENT_DATA_LINE_CAP = 1000 # max rendered data lines per event

    # `display_lines` over the latest `cap` events, numbered past the older ones it leaves
    # out, and how many it showed. The window History's EVENTS pane and the Repeater share.
    def self.latest_lines(events : Array(Event), cap : Int32) : {Array(String), Int32}
      dropped = {events.size - cap, 0}.max
      {display_lines(dropped > 0 ? events[dropped..] : events, dropped), events.size - dropped}
    end

    # A `retry` reconnection time (ms): only an all-ASCII-digit value qualifies; one
    # too large for Int32 clamps to MAX rather than being dropped. nil ⇒ not valid.
    protected def self.retry_ms(value : Bytes) : Int32?
      return nil if value.empty? || !value.all? { |b| '0'.ord <= b <= '9'.ord }
      String.new(value).to_i? || Int32::MAX
    end
  end
end
