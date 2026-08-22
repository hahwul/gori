require "json"
require "base64"
require "./binary_document"

module Gori
  # Schema-less CBOR (RFC 8949) reader. A pure byte parser over a `Bytes` slice
  # (no I/O) that renders a captured body as JSON text. Sibling of the protobuf
  # decoder in `src/gori/protobuf.cr`: same job — make an opaque binary body
  # readable without a schema — and the same refusal to guess.
  #
  # CBOR is self-describing, so unlike protobuf there is no ambiguity to report:
  # every item says what it is. The problem moves to the other end. CBOR carries
  # types JSON does not have (byte strings, non-string map keys, tags, undefined,
  # NaN, integers past 2^63) and the tempting move — coerce them into the nearest
  # JSON shape — is the failure class this reader is written to avoid. Every such
  # item gets an explicit `$`-prefixed envelope instead, so a reader can always
  # tell "the body said this" from "JSON could not say that". The envelopes are
  # `$bin`, `$str_invalid_utf8`, `$tag`, `$bignum`, `$time`, `$undefined`,
  # `$simple`, `$float`, `$non_string_keys` and `$partial`. A CBOR text key
  # spelled the same way is indistinguishable from a marker in the output; that
  # collision is accepted, because the alternative (escaping every key) makes the
  # common body unreadable to buy safety in a body nobody sends.
  #
  # Never raises on hostile / truncated input (P7): the parse stops where the
  # bytes stop, the JSON built so far is returned, and `complete` is false.
  # Recursion, item counts and every length claim are bounded.
  module Cbor
    extend self

    # Nesting ceiling. Hostile input is the normal case for a proxy; `81 81 81 …`
    # is three bytes per level, so a crafted body reaches thousands of levels in
    # a few KB and must not blow the fiber stack.
    MAX_DEPTH = 32

    # Total item ceiling for one body, not per container: the cheap bomb is a
    # flat `9f 00 00 00 … ff`, one byte per item, which a per-container limit
    # would wave through. Far above any realistic body.
    MAX_ITEMS = 100_000

    # Bignum (tag 2/3) byte-string ceiling for the decimal rendering. Base-256 to
    # base-10 is quadratic in the digit count, so an unbounded bignum is a CPU
    # bomb with a 9-byte header. 512 bytes covers an RSA-4096 modulus, which is
    # the realistic reason a security tool cares. Past it the raw bytes are still
    # emitted — only the decimal spelling is dropped.
    MAX_BIGNUM_BYTES = 512

    # Render `data`, with everything a caller needs to decide whether the rendering is about
    # THIS body: see `BinaryDocument::Rendering`. `indent` pretty-prints; nil is compact.
    #
    # The text is never round-tripped through `JSON.parse` on its way anywhere — a document may
    # legitimately carry a DUPLICATE member (two identical map keys), which is a fact about the
    # body and often the point of it, and re-parsing would keep one and drop the other.
    def render(data : Bytes, *, max_depth : Int32 = MAX_DEPTH,
               indent : String? = nil) : BinaryDocument::Rendering
      reader = Reader.new(data, max_depth)
      text = JSON.build(indent) { |j| reader.item(j, 0) }
      reader.note_trailing
      BinaryDocument::Rendering.new(text, reader.complete?, reader.pos, reader.stop)
    rescue JSON::Error
      internal_rendering
    end

    # :ditto: — the two-element form, for a caller that only wants the text and whether it is
    # whole (every spec, and the Decoder converter).
    def to_json(data : Bytes, *, max_depth : Int32 = MAX_DEPTH) : {String, Bool}
      r = render(data, max_depth: max_depth)
      {r.json, r.complete}
    end

    private def internal_rendering : BinaryDocument::Rendering
      # `JSON::Builder` raises on states this parser is written never to reach: a
      # document that ends with no value, a member with no value, a non-finite
      # number. The contract here ("never raises") is stronger than the belief
      # that the parser is right about all three, and the cost of being wrong is
      # an unhandled exception thrown while rendering someone's captured body.
      BinaryDocument::Rendering.new("{\"$partial\":\"internal\"}", false, 0, "internal")
    end

    # --- parser ---------------------------------------------------------------

    # The parse cursor. CBOR is read by recursion and its bounds (depth, items)
    # are global to one body, so position and bookkeeping live in one object
    # rather than being threaded back through every return tuple the way
    # `protobuf.cr` threads its `pos`. That cursor is also what the caller reads
    # back to decide whether the rendering is about this body at all — see
    # `BinaryDocument::Rendering#describes?`.
    private class Reader
      getter? complete : Bool = true

      def initialize(@data : Bytes, @max_depth : Int32)
        @pos = 0
        @items = 0
        @stop = nil.as(String?)
      end

      # One item's head: major type, additional info, and the argument the info
      # named (a value, a length, a count, a tag number, or float bits).
      record Head, major : UInt8, ai : UInt8, arg : UInt64, indefinite : Bool

      def exhausted? : Bool
        @pos == @data.size
      end

      # A CBOR body is ONE data item (RFC 8949 §5.1). Bytes after it are either a
      # CBOR sequence (RFC 8742 — a different media type) or corruption. Either
      # way the item that rendered is real, so it is kept and the leftovers make
      # the render partial rather than disappearing.
      def note_trailing : Nil
        return if exhausted?
        @complete = false
        # A COMPLETE value followed by bytes nobody asked for. Named apart from `truncated`
        # because it is the opposite situation and points the other way: a body that ends early
        # is this document cut short, while one that ends and leaves a tail is usually not this
        # document at all (the first byte of a gzip stream is a valid one-byte CBOR integer).
        @stop ||= "trailing"
      end

      # How far into the input the parse got, and why it stopped (nil when it did not).
      getter pos
      getter stop : String?

      # Render one item. ALWAYS writes exactly one JSON value, including on
      # failure — the builder may be mid-object, and a member with no value is
      # not JSON. Returns false when the parse stopped here.
      def item(j : JSON::Builder, depth : Int32) : Bool
        return partial(j, "max_depth") if depth > @max_depth
        @items += 1
        return partial(j, "max_items") if @items > MAX_ITEMS

        head, why = read_head
        return partial(j, why) unless head

        # Additional info 31 is the indefinite-length marker (and, on major 7,
        # the `break` that closes one). Only strings, arrays and maps may open
        # indefinite; on an integer or a tag it is a byte with no meaning.
        if head.indefinite && {0_u8, 1_u8, 6_u8}.includes?(head.major)
          return partial(j, "malformed")
        end

        render(j, head, depth)
      end

      # Major-type dispatch. Every branch writes exactly one JSON value and
      # returns whether the parse is still going — that pair is the invariant
      # `item` promises its callers, and it is why nothing here may return early
      # without emitting.
      private def render(j : JSON::Builder, head : Head, depth : Int32) : Bool
        case head.major
        when 0_u8 then write_uint(j, head.arg)
        when 1_u8 then write_nint(j, head.arg)
        when 2_u8 then bytes_item(j, head)
        when 3_u8 then text_item(j, head)
        when 4_u8 then array_item(j, head, depth)
        when 5_u8 then map_item(j, head, depth)
        when 6_u8 then tag_item(j, head, depth)
        else           simple_item(j, head)
        end
      end

      # --- scalars ------------------------------------------------------------

      private def write_uint(j : JSON::Builder, arg : UInt64) : Bool
        if arg <= Int64::MAX.to_u64
          j.number(arg.to_i64)
        else
          # The digits ARE legal JSON as a number, but every mainstream reader
          # (Crystal's own `JSON::Any` included) parses an integer literal into a
          # 64-bit int and either overflows or silently rounds it. A string of the
          # decimal digits is readable, exact, and obviously not a plain number.
          j.string(arg.to_s)
        end
        true
      end

      # Major 1 encodes -1 - arg, so the argument runs one below the magnitude.
      private def write_nint(j : JSON::Builder, arg : UInt64) : Bool
        if arg <= Int64::MAX.to_u64
          # arg == Int64::MAX lands exactly on Int64::MIN; nothing here overflows.
          j.number(-1_i64 - arg.to_i64)
        else
          j.string(negative_decimal(arg))
        end
        true
      end

      # -1 - arg in decimal without a 128-bit type. `arg + 1` wraps for exactly
      # one input, UInt64::MAX, whose value (-2^64) is the one constant CBOR can
      # name here — the RFC's own `3b ff ff ff ff ff ff ff ff` vector.
      private def negative_decimal(arg : UInt64) : String
        return "-18446744073709551616" if arg == UInt64::MAX
        "-#{arg + 1}"
      end

      # JSON has no NaN and no infinities. `JSON::Builder#number` RAISES on them,
      # and the two silent alternatives are both worse: `null` erases the value,
      # and `0` invents one. A NaN in a body is often the interesting part.
      private def write_float(j : JSON::Builder, f : Float64) : Nil
        if f.nan?
          j.object { j.field "$float", "NaN" }
        elsif inf = f.infinite?
          j.object { j.field "$float", inf > 0 ? "Infinity" : "-Infinity" }
        else
          j.number(f)
        end
      end

      # Major 7 is one type for four unrelated things: the three JSON literals,
      # `undefined`, the unassigned simple values, and the floats.
      private def simple_item(j : JSON::Builder, head : Head) : Bool
        # A `break` standing on its own is a container terminator with no
        # container: it is not a value, so there is nothing to render.
        return partial(j, "malformed") if head.indefinite

        case head.ai
        when 20 then j.bool(false)
        when 21 then j.bool(true)
        when 22 then j.null
        when 23 then j.object { j.field "$undefined", true }
        when 25 then write_float(j, half_to_f64(head.arg.to_u16))
        when 26 then write_float(j, head.arg.to_u32.unsafe_as(Float32).to_f64)
        when 27 then write_float(j, head.arg.unsafe_as(Float64))
        else
          # simple(n): 0..19 inline, 24 with a following byte. RFC 8949 §3.3 makes
          # the two-byte spelling of n < 32 malformed, and we render it anyway —
          # refusing a body we can perfectly well show is not this module's job.
          j.object { j.field "$simple", head.arg.to_i64 }
        end
        true
      end

      # IEEE 754 binary16, per the RFC 8949 Appendix D decoder. Crystal has no
      # Float16, and every half is exactly representable as a double, so the
      # widening is lossless.
      private def half_to_f64(bits : UInt16) : Float64
        exp = ((bits >> 10) & 0x1f).to_i32
        mant = (bits & 0x3ff).to_i32
        value =
          if exp == 0
            mant.to_f64 * (2.0 ** -24) # subnormal
          elsif exp != 31
            (mant.to_f64 + 1024.0) * (2.0 ** (exp - 25))
          else
            mant == 0 ? Float64::INFINITY : Float64::NAN
          end
        (bits & 0x8000) != 0 ? -value : value
      end

      # --- strings ------------------------------------------------------------

      private def bytes_item(j : JSON::Builder, head : Head) : Bool
        payload, why = string_payload(head, 2_u8)
        return partial(j, why) unless payload
        j.object { j.field "$bin", Base64.strict_encode(payload) }
        true
      end

      private def text_item(j : JSON::Builder, head : Head) : Bool
        payload, why = string_payload(head, 3_u8)
        return partial(j, why) unless payload
        s = String.new(payload)
        if s.valid_encoding?
          j.string(s)
        else
          # Writing the bytes as a JSON string would emit invalid UTF-8 into the
          # document — the whole render stops being parseable — and scrubbing to
          # U+FFFD would hand the operator a body that differs from the wire in
          # exactly the bytes worth looking at (P7). Base64 keeps them.
          j.object { j.field "$str_invalid_utf8", Base64.strict_encode(payload) }
        end
        true
      end

      # Definite length, or the indefinite chunked form. Returns {payload, reason}.
      private def string_payload(head : Head, major : UInt8) : {Bytes?, String}
        return indefinite_chunks(major) if head.indefinite
        payload = take(head.arg)
        payload ? {payload, ""} : {nil, "truncated"}
      end

      # RFC 8949 §3.2.3: the chunks of an indefinite-length string must all be
      # definite-length strings of the same major type, ending at a `break`.
      # Total size is bounded by the input, because every chunk is taken from it.
      private def indefinite_chunks(major : UInt8) : {Bytes?, String}
        io = IO::Memory.new
        loop do
          @items += 1
          return {nil, "max_items"} if @items > MAX_ITEMS

          head, why = read_head
          return {nil, why} unless head
          return {io.to_slice, ""} if break?(head)
          return {nil, "malformed"} if head.major != major || head.indefinite

          chunk = take(head.arg)
          return {nil, "truncated"} unless chunk
          io.write(chunk)
        end
      end

      # --- containers ---------------------------------------------------------

      private def array_item(j : JSON::Builder, head : Head, depth : Int32) : Bool
        ok = true
        j.array do
          if head.indefinite
            loop do
              break if take_break?
              # Out of input with no `break`: the array is open and the marker
              # goes in as its last element, so the JSON says where it stopped.
              unless @pos < @data.size
                ok = partial(j, "truncated")
                break
              end
              ok = item(j, depth + 1)
              break unless ok
            end
          else
            # No pre-allocation and no pre-check against the count: a header may
            # claim 2^64 items, and the first unreadable one ends the loop, so
            # the work is bounded by the bytes that are actually there.
            i = 0_u64
            while i < head.arg
              ok = item(j, depth + 1)
              break unless ok
              i += 1
            end
          end
        end
        ok
      end

      # A CBOR map keys on any item; a JSON object keys on strings only. Text
      # keys pass through. Anything else is rendered as its own JSON text and
      # that text becomes the member name (`1` → `"1"`, `[1,2]` → `"[1,2]"`),
      # which is reversible by eye and cannot collide with a rendering of a
      # different key. The map then carries `"$non_string_keys": true` so nobody
      # reads `{"1": …}` as having been keyed on the string "1". The flag is
      # written last because non-string keys are discovered as the pairs are.
      #
      # Duplicate keys are passed through as duplicate members. CBOR allows them,
      # JSON tolerates them, and merging would hide a body deliberately built to
      # exploit which one a parser keeps.
      private def map_item(j : JSON::Builder, head : Head, depth : Int32) : Bool
        ok = true
        tagged = false
        j.object do
          if head.indefinite
            loop do
              break if take_break?
              unless @pos < @data.size
                ok = false
                @complete = false
                @stop ||= "truncated" # an indefinite map with no `break` and no bytes left
                break
              end
              ok, tagged = pair(j, depth, tagged)
              break unless ok
            end
          else
            i = 0_u64
            while i < head.arg
              ok, tagged = pair(j, depth, tagged)
              break unless ok
              i += 1
            end
          end
          j.field "$non_string_keys", true if tagged
        end
        ok
      end

      # One key/value pair. Returns {ok, whether a non-string key has been seen}.
      private def pair(j : JSON::Builder, depth : Int32, tagged : Bool) : {Bool, Bool}
        name, plain, kok = key_name(depth + 1)
        tagged ||= !plain
        unless kok
          # The key itself ran out. Its marker text is the member name, so the
          # reason is already in the document; the value slot has to hold
          # something and there is nothing behind it.
          j.field(name) { j.null }
          return {false, tagged}
        end
        vok = true
        # `depth + 1`, the same as the key and the same as an array's elements. At `depth` a
        # chain of maps-as-values did not count as nesting at all, so `{"a": {"a": …}}` recursed
        # without bound: 40 levels rendered clean past a MAX_DEPTH of 32, and ~100 blew the JSON
        # builder's own nesting limit — which the rescue at the public boundary turned into
        # `{"$partial":"internal"}`, discarding a document that was mostly legible. The bound
        # exists precisely so that limit is never the thing that stops us.
        j.field(name) { vok = item(j, depth + 1) }
        {vok, tagged}
      end

      # Returns {member name, was it a plain text key, did it parse}.
      private def key_name(depth : Int32) : {String, Bool, Bool}
        save = @pos
        head, _why = read_head
        if head && head.major == 3_u8
          @items += 1
          if @items <= MAX_ITEMS
            payload, _reason = string_payload(head, 3_u8)
            if payload
              s = String.new(payload)
              # Invalid UTF-8 falls through deliberately: the scratch render
              # gives it the `$str_invalid_utf8` envelope and the map gets
              # flagged, which is truer than a member name JSON cannot hold.
              return {s, true, true} if s.valid_encoding?
            end
          end
        end
        @pos = save
        ok = true
        # A separate builder, so a key that fails writes nothing into the map.
        text = JSON.build { |kj| ok = item(kj, depth) }
        {text, false, ok}
      end

      # --- tags ---------------------------------------------------------------

      # Tags are semantic labels on the item that follows. The generic rendering
      # keeps both halves — `{"$tag": n, "value": …}` — and invents no meaning,
      # which is the right answer for the long tail (24 embedded CBOR, 32 URI, 35
      # regex, 55799 self-describe): the value is right there, tagged, and the
      # operator knows what n means better than a table would.
      #
      # Two exceptions earn their special case. Tags 2/3 are bignums, whose whole
      # content is a number that base64 hides — an RSA modulus, a nonce, a
      # counter past 2^64. Tag 1 is an epoch number, which is the field an
      # operator is usually looking for (an expiry, an issued-at) and which is
      # unreadable as a bare integer. Tag 0 needs nothing: its content is already
      # RFC 3339 text and reformatting a string the operator can read would only
      # move it further from the bytes (P7).
      private def tag_item(j : JSON::Builder, head : Head, depth : Int32) : Bool
        case head.arg
        when 1_u64        then epoch_item(j, depth)
        when 2_u64, 3_u64 then bignum_item(j, head.arg, depth)
        else                   generic_tag(j, head.arg, depth)
        end
      end

      private def generic_tag(j : JSON::Builder, tag : UInt64, depth : Int32) : Bool
        ok = true
        j.object do
          j.field("$tag") { write_uint(j, tag) }
          j.field("value") { ok = item(j, depth + 1) }
        end
        ok
      end

      # `{"$tag": 2, "$bignum": "<decimal>", "value": {"$bin": "<base64>"}}` —
      # both readings, like `protobuf.cr` reports a length-delimited field as
      # bytes AND string AND message. The decimal is the one an operator wants;
      # the base64 is what the wire said.
      private def bignum_item(j : JSON::Builder, tag : UInt64, depth : Int32) : Bool
        save = @pos
        head, _why = read_head
        if head && head.major == 2_u8
          @items += 1
          if @items <= MAX_ITEMS
            payload, _reason = string_payload(head, 2_u8)
            if payload
              j.object do
                j.field("$tag") { write_uint(j, tag) }
                if payload.size <= MAX_BIGNUM_BYTES
                  j.field "$bignum", bignum_decimal(payload, tag == 3_u64)
                end
                j.field("value") { j.object { j.field "$bin", Base64.strict_encode(payload) } }
              end
              return true
            end
          end
        end
        # Content that is not a byte string is a mislabelled bignum. Rewind and
        # let the generic envelope show whatever is actually there.
        @pos = save
        generic_tag(j, tag, depth)
      end

      # Big-endian base-256 magnitude to decimal, schoolbook, one byte at a time
      # over an array of little-endian decimal digits. No BigInt: this module
      # takes `json` and `base64` and nothing else, and the operation is small
      # enough at MAX_BIGNUM_BYTES to not be worth a dependency.
      private def bignum_decimal(bytes : Bytes, negative : Bool) : String
        digits = [0_u8]
        bytes.each do |byte|
          carry = byte.to_u32
          digits.each_with_index do |digit, i|
            v = digit.to_u32 * 256 + carry
            digits[i] = (v % 10).to_u8
            carry = v // 10
          end
          while carry > 0
            digits << (carry % 10).to_u8
            carry //= 10
          end
        end

        if negative
          # Tag 3 encodes -1 - n, so the printed magnitude is n + 1.
          carry = 1_u32
          i = 0
          while carry > 0 && i < digits.size
            v = digits[i].to_u32 + carry
            digits[i] = (v % 10).to_u8
            carry = v // 10
            i += 1
          end
          digits << carry.to_u8 if carry > 0
        end

        while digits.size > 1 && digits[-1] == 0
          digits.pop
        end
        String.build do |s|
          s << '-' if negative
          digits.reverse_each { |d| s << d }
        end
      end

      # `{"$tag": 1, "$time": "<RFC 3339>", "value": <the number, verbatim>}`.
      # The value is emitted by the normal item path rather than reconstructed,
      # so the number in the output is exactly the number in the bytes and the
      # readable spelling sits beside it.
      private def epoch_item(j : JSON::Builder, depth : Int32) : Bool
        seconds = peek_epoch_seconds
        return generic_tag(j, 1_u64, depth) unless seconds
        ok = true
        j.object do
          j.field("$tag") { write_uint(j, 1_u64) }
          if iso = rfc3339(seconds)
            j.field "$time", iso
          end
          j.field("value") { ok = item(j, depth + 1) }
        end
        ok
      end

      # Look at the tagged item's head without consuming it. A tag 1 whose
      # content is not a number is mislabelled and takes the generic envelope.
      private def peek_epoch_seconds : Float64?
        save = @pos
        head, _why = read_head
        @pos = save
        return nil unless head
        return nil if head.indefinite

        case head.major
        when 0_u8
          head.arg <= Int64::MAX.to_u64 ? head.arg.to_f64 : nil
        when 1_u8
          head.arg <= Int64::MAX.to_u64 ? (-1_i64 - head.arg.to_i64).to_f64 : nil
        when 7_u8
          case head.ai
          when 25 then half_to_f64(head.arg.to_u16)
          when 26 then head.arg.to_u32.unsafe_as(Float32).to_f64
          when 27 then head.arg.unsafe_as(Float64)
          end
        end
      end

      # `Time`'s own range is year 1 through 9999; outside it `Time.unix` RAISES,
      # and this module does not. A NaN fails the comparison and drops out here
      # too, which is the wanted answer. Sub-second precision is dropped from the
      # display string only — `value` still carries the exact number.
      private def rfc3339(seconds : Float64) : String?
        return nil unless -62_135_596_800.0 <= seconds <= 253_402_300_799.0
        Time.unix(seconds.to_i64).to_rfc3339
      end

      # --- bytes --------------------------------------------------------------

      # Read one item head: the initial byte, plus the 0/1/2/4/8 argument bytes
      # its additional info names. Returns {head, reason} — the reason is only
      # meaningful when the head is nil.
      private def read_head : {Head?, String}
        return {nil, "truncated"} if @pos >= @data.size
        ib = @data[@pos]
        @pos += 1
        major = ib >> 5
        ai = ib & 0x1f

        return {Head.new(major, ai, ai.to_u64, false), ""} if ai < 24
        case ai
        when 24 then read_arg(major, ai, 1)
        when 25 then read_arg(major, ai, 2)
        when 26 then read_arg(major, ai, 4)
        when 27 then read_arg(major, ai, 8)
        when 31 then {Head.new(major, ai, 0_u64, true), ""}
        else
          # 28..30 are reserved by RFC 8949 §3 and have never been assigned. They
          # are also what most non-CBOR bodies hit first: `<` is major 1 / ai 28.
          {nil, "malformed"}
        end
      end

      private def read_arg(major : UInt8, ai : UInt8, count : Int32) : {Head?, String}
        return {nil, "truncated"} if remaining < count
        arg = 0_u64
        count.times do
          arg = (arg << 8) | @data[@pos].to_u64
          @pos += 1
        end
        {Head.new(major, ai, arg, false), ""}
      end

      # Bytes not yet consumed. Every length claim is compared against this
      # BEFORE anything is sliced or allocated: an 8-byte header can name 2^64
      # bytes, and a reader that trusts it allocates until the process dies.
      private def remaining : Int32
        @data.size - @pos
      end

      private def take(length : UInt64) : Bytes?
        if length > remaining.to_u64
          # A SHORT read consumed everything that WAS there: the reader looked at every
          # remaining byte and found them insufficient. Recording that is what lets a caller
          # tell a body the capture cap cut short (ran out at the very end) from one whose
          # header lied (stopped with bytes still to go) — see
          # `BinaryDocument::Rendering#describes?`. Leaving `@pos` behind made a cut landing
          # INSIDE a string, which is where a cap lands for essentially any real body, look
          # like the second.
          @pos = @data.size
          return nil
        end
        slice = @data[@pos, length.to_i32]
        @pos += length.to_i32
        slice
      end

      private def break?(head : Head) : Bool
        head.major == 7_u8 && head.indefinite
      end

      # Consume a `break` if one is next. Peeked as a raw byte rather than
      # through `read_head` so the cursor never has to be rewound.
      private def take_break? : Bool
        return false unless @pos < @data.size && @data[@pos] == 0xff_u8
        @pos += 1
        true
      end

      private def partial(j : JSON::Builder, reason : String) : Bool
        @complete = false
        @stop ||= reason # the FIRST reason: later levels only report that this one stopped
        j.object { j.field "$partial", reason }
        false
      end
    end
  end
end
