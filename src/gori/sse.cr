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

      # {name, value}. A line with no colon is a field whose value is empty, and one optional
      # space after the colon goes (WHATWG).
      private def split(line : Bytes) : {Bytes, Bytes}
        colon = line.index(':'.ord.to_u8) || return {line, Bytes.empty}
        value = line[(colon + 1)..]
        value = value[1..] if value[0]? == ' '.ord
        {line[0, colon], value}
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

    # A `retry` reconnection time (ms): only an all-ASCII-digit value qualifies; one
    # too large for Int32 clamps to MAX rather than being dropped. nil ⇒ not valid.
    protected def self.retry_ms(value : Bytes) : Int32?
      return nil if value.empty? || !value.all? { |b| '0'.ord <= b <= '9'.ord }
      String.new(value).to_i? || Int32::MAX
    end
  end
end
