require "./proxy/codec/content_decode"

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
      !!content_type.try { |ct| ct.lstrip.downcase.starts_with?("text/event-stream") }
    end

    # True when a response head declares a text/event-stream body. Resolves the
    # Content-Type value (case-insensitive name, any/no space after the colon, charset
    # params) and reuses sse? — the single source of truth all surfaces call, instead
    # of each doing a brittle `includes?("content-type: text/event-stream")` scan.
    def self.event_stream?(head : Bytes?) : Bool
      return false unless head
      String.new(head).each_line do |line|
        colon = line.index(':') || next
        next unless line[0, colon].strip.downcase == "content-type"
        return sse?(line[(colon + 1)..])
      end
      false
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
    def self.events(body : Bytes) : Array(Event)
      events = [] of Event
      return events if body.empty?
      # SSE is UTF-8; invalid bytes become U+FFFD (display-only, never re-sent).
      # Normalise all three line terminators to LF so a single split suffices, and
      # drop one leading BOM (U+FEFF) — WHATWG preprocessing — so the first field name
      # isn't mangled (a BOM-prefixed stream would otherwise lose its first event).
      text = String.new(body).scrub.gsub("\r\n", "\n").gsub('\r', '\n').lchop(0xFEFF.chr)

      last_id = nil.as(String?) # stream-level: persists across blocks (per spec)
      data = [] of String       # data lines accumulated for the current block
      type = nil.as(String?)
      retry = nil.as(Int32?)

      flush = -> do
        # A block emits an event only if it carried at least one `data` field.
        events << Event.new(type, data.join('\n'), last_id, retry) unless data.empty?
        data.clear
        type = nil
        retry = nil
      end

      text.split('\n').each do |line|
        break if events.size >= MAX_EVENTS
        if line.empty?
          flush.call
          next
        end
        field, value = field_of(line) || next # nil ⇒ a comment (`:`-prefixed) line
        case field
        when "event" then type = value.empty? ? nil : value # empty ⇒ default (nil)
        when "data"  then data << value
        when "id"    then last_id = value unless value.includes?(Char::ZERO) # a NUL ⇒ ignore the id
        when "retry" then retry = retry_ms(value) || retry                   # invalid keeps the prior
        end
      end

      flush.call if events.size < MAX_EVENTS # trailing block (no terminating blank line)
      events
    end

    # Splits a non-comment field line into {name, value}, stripping the one optional
    # space after the colon (WHATWG). Returns nil for a comment line; a line with no
    # colon is a field whose value is empty.
    private def self.field_of(line : String) : {String, String}?
      return nil if line.starts_with?(':')
      colon = line.index(':') || return {line, ""}
      value = line[(colon + 1)..]
      value = value[1..] if value.starts_with?(' ')
      {line[0, colon], value}
    end

    # A `retry` reconnection time (ms): only an all-ASCII-digit value qualifies; one
    # too large for Int32 clamps to MAX rather than being dropped. nil ⇒ not valid.
    private def self.retry_ms(value : String) : Int32?
      return nil if value.empty? || !value.each_char.all?(&.ascii_number?)
      value.to_i? || Int32::MAX
    end
  end
end
