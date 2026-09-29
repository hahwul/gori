require "html"
require "json"
require "uri"

module Gori
  module Fuzz
    # A compact RESPONSE-SHAPE fingerprint (issue #1351): two responses share a shape when an
    # operator reading them would call them "the same answer", whatever payload produced them.
    # It is what `Fuzz::Clusters` groups a run's rows by, so a 10,000-row sweep reads as the
    # handful of distinct answers it actually got.
    #
    # Computed ONCE, in `Matcher#build`, over the body that call already decoded (P6: never a
    # second decode) and bounded to the body's first `BODY_UNITS` normalized units. The key is
    # the response's outcome rather than its bytes:
    #
    #   * the outcome class — a response, or a failed send folded to a coarse `error_class`
    #     (raw error text names hosts, ports and timings, and would split every row);
    #   * status, gRPC status, the truncation flags, and (folded in by `Result#with_ws`) the
    #     WebSocket close code — each its own key part, so an error, a truncated body, a denied
    #     call or a policy close never reads as an ordinary short response;
    #   * the SET of response header names minus the ones that vary per response or with body
    #     size (`VOLATILE_HEADERS`), plus the normalized `Location` and `Content-Type` values;
    #   * the decoded body with the job's OWN payload bytes masked (so a reflected payload does
    #     not make every row its own shape) — as sent, and HTML-, percent- and JSON-escaped —
    #     digit runs, hex-ish and long random tokens collapsed, and whitespace runs folded.
    #
    # Deliberately NOT in the key: `length`, `words` and `lines`. A reflected payload moves all
    # three by its own size, which is exactly the split the masking exists to prevent — the
    # cluster reports their RANGE instead.
    #
    # FNV-1a 64 rather than `#hash`: Crystal's hasher is seeded per process, and this id is
    # persisted (`fuzz_results.shape`) and compared across runs. `VERSION` is folded into every
    # key, so a change to the normalization changes every id rather than silently merging old
    # rows with new ones.
    module Shape
      VERSION = 1_u8

      # How much of the decoded body the signature reads: its first `BODY_UNITS` NORMALIZED
      # units — a masked payload, a folded value, a word, a whitespace run or one punctuation
      # byte each count one — and never more than `BODY_RAW_MAX` raw bytes.
      #
      # Units, not bytes, because the cut has to land on the same CONTENT in two responses
      # that differ only by the payload they echo: a search page that echoes its query at the
      # top moves every later byte by the payload's length, so a raw-byte window ended at a
      # different place in the page for every payload (and split the one cluster it exists
      # to form). Whether the body continued past the window is folded in as one bit.
      #
      # `BODY_RAW_MAX` is the cost bound: the normalization is ~1.3 ns/byte on token-dense HTML
      # (`bench/fuzz_shape_bench.cr`), so a whole 8 MiB capture would cost milliseconds per
      # response. Only a body of long unbroken tokens reaches it before `BODY_UNITS`.
      BODY_UNITS   = 16_384
      BODY_RAW_MAX = 256 * 1024
      # A payload shorter than this is not masked: masking every `a` in a body would make two
      # identical bodies hash differently for the payloads `a` and `b`.
      MIN_NEEDLE   = 3
      private HTML_SPECIAL = StaticArray['&'.ord.to_u8, '<'.ord.to_u8, '>'.ord.to_u8, '"'.ord.to_u8, '\''.ord.to_u8]
      private JSON_SPECIAL = StaticArray['"'.ord.to_u8, '\\'.ord.to_u8, '<'.ord.to_u8, '>'.ord.to_u8, '&'.ord.to_u8]

      # Shared and never mutated: the default of `compute`, so a caller without a job pays no
      # allocation for it.
      NO_NEEDLES  = [] of Bytes
      MAX_NEEDLES = 32
      # A token (a run of ASCII letters and digits) that mixes in a digit and is at least this
      # long, or is all-hex with a digit, is an id/nonce/hash and collapses to one marker.
      TOKEN_MIN = 8
      # A letter-only token this long is not a word anyone wrote: a base64 or random blob.
      LONG_TOKEN = 24

      private FNV_OFFSET = 0xcbf29ce484222325_u64
      private FNV_PRIME  =      0x100000001b3_u64

      # Markers folded in place of a masked span, mixed as two bytes behind a 0xff lead. A
      # literal 0xff body byte is mixed as 0xff 0x00, so no body can spell a marker.
      #
      # A number and an id-like token fold to the SAME `MARK_VALUE`: a random hex id is
      # sometimes all digits (`1201083555725435` beside `5397ae9c4b977308`), and one marker per
      # kind split exactly those rows off into their own shape.
      private MARK_PAYLOAD = 0x01_u8
      private MARK_VALUE   = 0x02_u8
      private MARK_SPACE   = 0x04_u8

      # Header names whose PRESENCE varies per response, per cache state or with body size, and
      # so say nothing about which answer this was. Values of every header are excluded anyway.
      VOLATILE_HEADERS = %w[
        date age expires last-modified etag content-length transfer-encoding content-encoding
        connection keep-alive vary x-request-id x-correlation-id request-id x-amzn-requestid
        x-amz-request-id x-amz-id-2 x-amz-cf-id x-amz-cf-pop cf-ray cf-cache-status x-cache
        x-cache-hits x-served-by x-timer x-runtime x-response-time server-timing traceparent
        tracestate x-trace-id x-b3-traceid x-varnish via report-to nel
      ]

      private VOLATILE_HASHES   = VOLATILE_HEADERS.map { |n| name_hash(n.to_slice) }.to_set
      private LOCATION_HASH     = name_hash("location".to_slice)
      private CONTENT_TYPE_HASH = name_hash("content-type".to_slice)

      # The coarse class of a failed send. Raw error text quotes the host, port, a byte count or
      # a duration, so keying on it would give every row its own cluster.
      enum ErrorClass : UInt8
        Blocked
        Budget
        RedirectRefused
        Timeout
        Refused
        Dns
        Tls
        Reset
        Malformed
        Other

        def label : String
          case self
          in Blocked         then "blocked"
          in Budget          then "budget"
          in RedirectRefused then "redirect_refused"
          in Timeout         then "timeout"
          in Refused         then "refused"
          in Dns             then "dns"
          in Tls             then "tls"
          in Reset           then "reset"
          in Malformed       then "malformed"
          in Other           then "other"
          end
        end
      end

      # Which words in a failed send's text put it in which class, checked in this order (a
      # "timed out" TLS handshake is a timeout, a "connection refused" one is refused).
      private ERROR_WORDS = [
        {ErrorClass::Blocked, {"blocked by"}},
        {ErrorClass::Budget, {"cap reached"}},
        {ErrorClass::Timeout, {"timed out", "timeout"}},
        {ErrorClass::Refused, {"refused"}},
        {ErrorClass::Dns, {"resolve", "getaddrinfo", "name or service", "nodename", "dns"}},
        {ErrorClass::Tls, {"tls", "ssl", "certificate", "handshake"}},
        {ErrorClass::Reset, {"reset", "broken pipe", "closed", "eof", "no response"}},
        {ErrorClass::Malformed, {"malformed", "unparseable", "invalid"}},
      ]

      # Matched on wording, not on `Outbound.permanent_refusal?` / `CappedBackend::CAP_ERROR`:
      # this file is required by `Matcher`, which benches build without `Outbound` (it pulls in
      # the Store). `spec/fuzz/shape_spec.cr` pins both constants to their classes, so a reword
      # of either fails there rather than quietly reclassifying.
      def self.error_class(error : String?) : ErrorClass?
        return nil unless error
        return ErrorClass::RedirectRefused if error.starts_with?(REDIRECT_HOP_REFUSED)
        # A candidate the request-time macro did not send. Ahead of ERROR_WORDS: the sentence
        # embeds the step's own failure ("connection refused", "timed out"), and that must not
        # file an unsent row under a network class. The prefix is `RequestMacro::ERROR_PREFIX`;
        # this file cannot require that module (Matcher benches build without the store).
        # `spec/fuzz/shape_spec.cr` pins the two together.
        return ErrorClass::Other if error.starts_with?("macro:")
        e = error.downcase
        ERROR_WORDS.each do |(klass, words)|
          return klass if words.any? { |w| e.includes?(w) }
        end
        ErrorClass::Other
      end

      # The needles `compute` masks: each payload as generated, the bytes it was spliced into the
      # request as (a `¦chain` transforms them), and its HTML-escaped and percent-encoded forms
      # when those differ — the three ways a page usually echoes what it was sent. Slices of
      # buffers the job already holds, except the two encoded variants.
      def self.needles(job : Job) : Array(Bytes)
        list = Array(Bytes).new(job.payloads.size + job.payload_spans.size)
        # The bytes themselves first, so a many-position job that reaches `MAX_NEEDLES` drops an
        # escaped variant rather than what actually went on the wire.
        job.payloads.each { |payload| add_needle(list, payload.to_slice) }
        job.payload_spans.each do |(start, len)|
          add_needle(list, job.bytes[start, len]) if start >= 0 && len > 0 && start + len <= job.bytes.size
        end
        job.ws_frames.try &.each do |frame|
          frame.payload_spans.each do |(start, len)|
            add_needle(list, frame.payload[start, len]) if start >= 0 && len > 0 && start + len <= frame.payload.size
          end
        end
        job.payloads.each do |payload|
          # Built only when they can differ: the common payload is plain text, and string
          # allocations per response to learn that would be the fingerprint's whole garbage.
          next unless payload.valid_encoding? && payload.bytesize >= MIN_NEEDLE
          add_html_needles(list, payload)
          add_needle(list, URI.encode_www_form(payload, space_to_plus: false).to_slice) unless payload.to_slice.all? { |b| URI.unreserved?(b) }
          add_json_needles(list, payload)
        end
        # Longest first, so a payload and the longer escaped form containing it mask as one span.
        list.sort! { |a, b| b.size <=> a.size }
        list
      end

      # An HTML page echoes `<>&` one way and a quote several: `HTML.escape` writes `&#39;` and
      # `&quot;`, PHP's htmlspecialchars `&#039;`, Python's `html.escape` `&#x27;`, Go's
      # html/template `&#34;`, and XML-minded servers `&apos;`. A SQLi or XSS list puts a quote
      # in nearly every payload, so masking one spelling left every other server's echo split
      # into one cluster per payload.
      private def self.add_html_needles(list : Array(Bytes), payload : String) : Nil
        return unless payload.to_slice.any? { |b| HTML_SPECIAL.includes?(b) }
        base = HTML.escape(payload)
        add_needle(list, base.to_slice)
        return unless payload.includes?('\'') || payload.includes?('"')
        HTML_QUOTE_SPELLINGS.each do |(single, double)|
          add_needle(list, base.gsub("&#39;", single).gsub("&quot;", double).to_slice)
        end
      end

      # {`'`, `"`} as the servers above write them, beside `HTML.escape`'s own.
      private HTML_QUOTE_SPELLINGS = [{"&#039;", "&quot;"}, {"&#x27;", "&quot;"}, {"&#39;", "&#34;"}, {"&apos;", "&quot;"}]

      # A JSON API echoes a payload inside a string literal: `"` as `\"`, a control byte as
      # `\n`/`\u0001`, and — Go's `encoding/json`, among others — `<`, `>` and `&` as `\u003c`,
      # `\u003e` and `\u0026`. Both spellings, built only for a payload that has such a byte.
      private def self.add_json_needles(list : Array(Bytes), payload : String) : Nil
        return unless payload.to_slice.any? { |b| b < 0x20 || JSON_SPECIAL.includes?(b) }
        std = payload.to_json[1...-1]
        add_needle(list, std.to_slice) unless std == payload
        go = std.gsub('<', "\\u003c").gsub('>', "\\u003e").gsub('&', "\\u0026")
        add_needle(list, go.to_slice) unless go == std
      end

      private def self.add_needle(list : Array(Bytes), bytes : Bytes) : Nil
        return if bytes.size < MIN_NEEDLE || list.size >= MAX_NEEDLES
        return if list.any? { |n| n == bytes }
        list << bytes
      end

      # The fingerprint of one response. `body` is the DECODED body `Matcher#build` holds;
      # `head` the raw response head (status line + headers), empty for a failed send.
      def self.compute(status : Int32?, grpc_status : Int32?, error : String?, incomplete : Bool,
                       timed_out : Bool, head : Bytes, body : Bytes,
                       needles : Array(Bytes) = NO_NEEDLES) : Int64
        h = FNV_OFFSET
        h = mix(h, VERSION)
        h = mix(h, status ? 'R'.ord.to_u8 : 'E'.ord.to_u8)
        h = mix_i32(h, status || -1)
        h = mix(h, error_class(error).try(&.value) || 0xff_u8)
        h = mix(h, (incomplete ? 1_u8 : 0_u8) | (timed_out ? 2_u8 : 0_u8))
        h = mix_i32(h, grpc_status || -1)
        # A failed send has no response to describe; its class above is the whole shape.
        if status
          h = mix_head(h, head, needles)
          h = mix(h, 'B'.ord.to_u8)
          raw = body.size > BODY_RAW_MAX ? body[0, BODY_RAW_MAX] : body
          h, whole = mix_text(h, raw, needles, BODY_UNITS)
          h = mix(h, whole && raw.size == body.size ? 1_u8 : 0_u8)
        end
        h.to_i64!
      end

      # Fold a WebSocket session's close code in. Applied by `Result#with_ws`, the one seam that
      # holds both the built row and the session outcome.
      def self.with_ws(shape : Int64?, close_code : Int32?, frames_in : Int32?) : Int64?
        return shape unless shape
        return shape if close_code.nil? && frames_in.nil?
        h = mix(shape.to_u64!, 'W'.ord.to_u8)
        mix_i32(h, close_code || -1).to_i64!
      end

      # The key for a row saved before shapes were recorded (a NULL `fuzz_results.shape`): only
      # the outcome and metric columns survive, so it is an approximation, and a distinct key
      # space (the high bit of the version byte) so it can never equal a real shape.
      def self.approximate(status : Int32?, grpc_status : Int32?, error : String?,
                           incomplete : Bool, timed_out : Bool, ws_close_code : Int32?,
                           words : Int32, lines : Int32) : Int64
        h = FNV_OFFSET
        h = mix(h, VERSION | 0x80_u8)
        h = mix_i32(h, status || -1)
        h = mix(h, error_class(error).try(&.value) || 0xff_u8)
        h = mix(h, (incomplete ? 1_u8 : 0_u8) | (timed_out ? 2_u8 : 0_u8))
        h = mix_i32(h, grpc_status || -1)
        h = mix_i32(h, ws_close_code || -1)
        h = mix_i32(h, words)
        h = mix_i32(h, lines)
        h.to_i64!
      end

      # The printed form of an id: 16 lowercase hex digits. The one spelling every surface uses.
      def self.hex(shape : Int64) : String
        shape.to_u64!.to_s(16).rjust(16, '0')
      end

      def self.parse_hex?(text : String) : Int64?
        t = text.strip.downcase
        return nil unless t.size == 16 && t.each_char.all?(&.hex?)
        t.to_u64(16).to_i64!
      rescue ArgumentError
        nil
      end

      # Header NAMES as a set (order-insensitive, duplicates once), minus the volatile ones,
      # plus the normalized values of the two headers whose value IS the answer's shape.
      private def self.mix_head(h : UInt64, head : Bytes, needles : Array(Bytes)) : UInt64
        seen = StaticArray(UInt64, 64).new(0_u64)
        count = 0
        location = Bytes.empty
        content_type = Bytes.empty
        start = 0
        first = true
        n = head.size
        while start < n
          stop = start
          while stop < n && head[stop] != 0x0a_u8
            stop += 1
          end
          line = head[start, stop - start]
          start = stop + 1
          if first
            first = false # the status line: its code is mixed on its own, the reason is prose
            next
          end
          colon = line.index(':'.ord.to_u8)
          next unless colon && colon > 0
          name = line[0, colon]
          nh = name_hash(name)
          next if VOLATILE_HASHES.includes?(nh)
          if nh == LOCATION_HASH
            location = trim(line[colon + 1, line.size - colon - 1])
          elsif nh == CONTENT_TYPE_HASH
            content_type = trim(line[colon + 1, line.size - colon - 1])
          end
          next if count >= seen.size || seen.to_slice[0, count].includes?(nh)
          seen[count] = nh
          count += 1
        end
        names = seen.to_slice[0, count]
        names.sort!
        h = mix(h, 'H'.ord.to_u8)
        names.each { |v| h = mix_u64(h, v) }
        h = mix(h, 'L'.ord.to_u8)
        h = mix_text(h, location, needles)[0]
        h = mix(h, 'C'.ord.to_u8)
        mix_text(h, content_type, needles)[0]
      end

      # One pass over `bytes`: payload spans, digit runs, id-like tokens and
      # whitespace runs each fold to a marker; every other byte folds as itself. The normalized
      # stream goes through a `Sink`, which packs it eight bytes to a multiply — this runs over
      # up to `BODY_UNITS` units of every response. Returns the hash and whether it read to the
      # end of `bytes` (rather than stopping at `unit_cap`).
      private def self.mix_text(h : UInt64, bytes : Bytes, needles : Array(Bytes),
                                unit_cap : Int32 = Int32::MAX) : {UInt64, Bool}
        limit = bytes.size
        units = 0
        first, any_needle = needle_first_bytes(needles)
        sink = Sink.new
        cls = CLASS.to_unsafe
        i = 0
        while i < limit
          break if units >= unit_cap
          units += 1 # every branch below folds exactly one unit
          b = bytes.unsafe_fetch(i)
          c = cls[b]
          if any_needle && first.unsafe_fetch(b) && (len = needle_at(bytes, i, limit, needles))
            sink.mark(MARK_PAYLOAD)
            i += len
          elsif c >= C_DIGIT
            j, kind, word = scan_token(bytes, i, limit, cls)
            kind == 0_u8 ? sink.word(word) : sink.mark(kind)
            i = j
          elsif c == C_SPACE
            sink.mark(MARK_SPACE)
            while i < limit && cls[bytes.unsafe_fetch(i)] == C_SPACE
              i += 1
            end
          else
            b == 0xff_u8 ? sink.mark(0x00_u8) : sink.put(b)
            i += 1
          end
        end
        {mix_u64(h, sink.finish), i >= limit}
      end

      private def self.needle_first_bytes(needles : Array(Bytes)) : {StaticArray(Bool, 256), Bool}
        first = StaticArray(Bool, 256).new(false)
        any_needle = false
        needles.each do |nd|
          next if nd.empty?
          first[nd.unsafe_fetch(0)] = true
          any_needle = true
        end
        {first, any_needle}
      end

      # Byte classes for `mix_text`, one load per byte. Ordered so `>= C_DIGIT` is "part of a
      # token".
      private C_OTHER  = 0_u8
      private C_SPACE  = 1_u8
      private C_DIGIT  = 2_u8
      private C_HEX    = 3_u8 # a-f / A-F
      private C_LETTER = 4_u8 # every other ASCII letter

      # A heap `Bytes`, not a StaticArray: `mix_text` holds its pointer, and a StaticArray
      # constant is a value — its `to_unsafe` would point into a temporary copy.
      private CLASS = begin
        t = Bytes.new(256, C_OTHER)
        {0x20, 0x09, 0x0a, 0x0d}.each { |b| t[b] = C_SPACE }
        ('0'.ord..'9'.ord).each { |b| t[b] = C_DIGIT }
        ('a'.ord..'z'.ord).each { |b| t[b] = C_LETTER }
        ('A'.ord..'Z'.ord).each { |b| t[b] = C_LETTER }
        ('a'.ord..'f'.ord).each { |b| t[b] = C_HEX }
        ('A'.ord..'F'.ord).each { |b| t[b] = C_HEX }
        t
      end

      # The normalized-text accumulator: eight bytes per multiply-xorshift step. Each step is a
      # bijection of the state for a given word, so two streams that differ stay different
      # unless a later difference cancels an earlier one. Deterministic, never seeded.
      private struct Sink
        PRIME = 0x9e3779b97f4a7c15_u64

        def initialize
          @h = 0x243f6a8885a308d3_u64
          @acc = 0_u64
          @n = 0
        end

        @[AlwaysInline]
        def put(b : UInt8) : Nil
          @acc |= b.to_u64 << (@n << 3)
          @n += 1
          step if @n == 8
        end

        @[AlwaysInline]
        def mark(m : UInt8) : Nil
          put(0xff_u8)
          put(m)
        end

        # A whole word's hash as one step. The pending partial word is closed first (with its
        # count), so `td<` and `<td` cannot fold the same bytes in the same place.
        def word(w : UInt64) : Nil
          if @n > 0
            @acc |= @n.to_u64 << 59
            step
          end
          @acc = w | 1_u64 << 63
          step
        end

        # The trailing partial word carries its byte count, so `ab` and `ab\0` differ.
        def finish : UInt64
          @acc |= @n.to_u64 << 59
          step
          @h
        end

        private def step : Nil
          h = (@h ^ @acc) &* PRIME
          @h = h ^ (h >> 31)
          @acc = 0_u64
          @n = 0
        end
      end

      # One pass over the token at `i`: where it ends, and either the marker it folds to
      # (`MARK_VALUE`) or 0 with the hash of its normalized form — so a kept word costs one
      # sink step rather than one per letter.
      private def self.scan_token(bytes : Bytes, i : Int32, limit : Int32,
                                  cls : Pointer(UInt8)) : {Int32, UInt8, UInt64}
        j = i
        digit = false
        alpha = false
        hex = true
        in_digits = false
        t = 0x9ae16a3b2f90404f_u64
        while j < limit
          ch = bytes.unsafe_fetch(j)
          k = cls[ch]
          break if k < C_DIGIT
          if k == C_DIGIT
            digit = true
            # a digit run inside a word (`v2`, `item12`) folds like a bare number does
            t = t &* 31 &+ 0x100 unless in_digits
            in_digits = true
          else
            alpha = true
            hex &&= k == C_HEX
            in_digits = false
            t = t &* 31 &+ ch
          end
          j += 1
        end
        size = j - i
        return {j, MARK_VALUE, 0_u64} unless alpha
        if (digit && (size >= TOKEN_MIN || (hex && size >= 4))) || size >= LONG_TOKEN
          return {j, MARK_VALUE, 0_u64}
        end
        {j, 0_u8, t ^ size.to_u64}
      end

      private def self.needle_at(bytes : Bytes, i : Int32, limit : Int32, needles : Array(Bytes)) : Int32?
        needles.each do |nd|
          next if nd.empty? || i + nd.size > limit
          return nd.size if bytes[i, nd.size] == nd
        end
        nil
      end

      private def self.trim(bytes : Bytes) : Bytes
        s = 0
        e = bytes.size
        while s < e && space?(bytes.unsafe_fetch(s))
          s += 1
        end
        while e > s && space?(bytes.unsafe_fetch(e - 1))
          e -= 1
        end
        bytes[s, e - s]
      end

      # :nodoc:
      def self.name_hash(name : Bytes) : UInt64
        h = FNV_OFFSET
        s = 0
        e = name.size
        while s < e && space?(name.unsafe_fetch(s))
          s += 1
        end
        while e > s && space?(name.unsafe_fetch(e - 1))
          e -= 1
        end
        (s...e).each do |k|
          b = name.unsafe_fetch(k)
          b += 32 if b >= 'A'.ord && b <= 'Z'.ord
          h = mix(h, b)
        end
        h
      end

      @[AlwaysInline]
      private def self.space?(b : UInt8) : Bool
        b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
      end

      @[AlwaysInline]
      private def self.mix(h : UInt64, b : UInt8) : UInt64
        (h ^ b) &* FNV_PRIME
      end

      private def self.mix_i32(h : UInt64, v : Int32) : UInt64
        u = v.to_u32!
        4.times { |k| h = mix(h, ((u >> (8 * k)) & 0xff).to_u8) }
        h
      end

      private def self.mix_u64(h : UInt64, v : UInt64) : UInt64
        8.times { |k| h = mix(h, ((v >> (8 * k)) & 0xff).to_u8) }
        h
      end
    end
  end
end
