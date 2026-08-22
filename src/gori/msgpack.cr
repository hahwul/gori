require "json"
require "base64"
require "./binary_document"

module Gori
  # Schema-less MessagePack reader (https://github.com/msgpack/msgpack/blob/master/spec.md),
  # rendering a captured body as JSON text. A pure byte parser over a `Bytes` slice (no I/O),
  # sibling to `Gori::Protobuf`: both exist because a proxy is handed binary bodies with no
  # schema in front of them, and "binary — press ^X for hex" is the answer that makes an
  # operator stop reading.
  #
  # ## The projection is explicit, because MessagePack carries what JSON does not
  #
  # A reader that quietly folded a `bin` into a string, or a 64-bit unsigned into a float, or
  # an `ext` into nothing, would be inventing evidence. Every type JSON has no room for gets a
  # named wrapper instead — `{"$bin": …}`, `{"$ext": …}` — so what is on the wire is legible
  # from the output alone. That is the same rule `Protobuf` follows when it reports a
  # length-delimited field as bytes AND string AND message rather than picking a winner.
  #
  # One ambiguity is accepted rather than papered over: a document whose own map key is
  # literally `$bin` or `$ext` renders the shape a wrapper does. Escaping every key in every
  # body to defend against the one body that does this would make the common body harder to
  # read, and the bytes stay reachable throughout (the hex view, and the store). The CBOR
  # sibling makes the same trade, and both are documented in the proxy guide.
  #
  # Never raises on hostile or truncated input (P7): the parse stops and the caller is told it
  # is partial, with everything decoded up to that point kept. Depth and item counts are
  # bounded, and a declared length is checked against the bytes that actually remain before
  # anything is allocated — a 5-byte header can claim 4 GiB.
  module Msgpack
    extend self

    # Nesting ceiling. Hostile input is the normal case for a proxy; a crafted chain of
    # one-byte fixarrays must not blow the fiber stack.
    MAX_DEPTH = 32

    # Total item ceiling across the whole document, not per container: a pathological stream of
    # `0x90` (empty fixarray) is cheap per item and unbounded in aggregate.
    MAX_ITEMS = 100_000

    # Render `data`, with everything a caller needs to decide whether the rendering is about
    # THIS body: see `BinaryDocument::Rendering`. `indent` pretty-prints; nil is compact.
    #
    # The text is never round-tripped through `JSON.parse` on its way anywhere — a document may
    # legitimately carry a DUPLICATE member (two identical map keys), which is a fact about the
    # body and often the point of it, and re-parsing would keep one and drop the other.
    def render(data : Bytes, *, max_depth : Int32 = MAX_DEPTH,
               indent : String? = nil) : BinaryDocument::Rendering
      p = Parser.new(data, max_depth)
      json = JSON.build(indent) { |j| p.value(j, 0) }
      # Trailing bytes are not an error the parse can report from inside — MessagePack has no
      # document terminator, and a body may legitimately be a stream of concatenated objects —
      # but they DO mean this rendering is not the whole body, which is what `complete` means.
      # Named `trailing` rather than folded into the truncation reason: it points the other way
      # (a body that ends and leaves a tail is usually not this document at all).
      trailing = p.ok? && p.pos < data.size
      BinaryDocument::Rendering.new(json, p.ok? && p.pos == data.size, p.pos,
        trailing ? "trailing" : p.stop)
    rescue JSON::Error
      # `JSON.build` can only fail on a builder misuse, which would be a bug here rather than
      # bad input. Report it as an incomplete parse rather than unwinding into a TUI draw (P7).
      BinaryDocument::Rendering.new("{\"$partial\":\"internal\"}", false, 0, "internal")
    end

    # :ditto: — the two-element form, for a caller that only wants the text and whether it is
    # whole (every spec, and the Decoder converter).
    def to_json(data : Bytes, *, max_depth : Int32 = MAX_DEPTH) : {String, Bool}
      r = render(data, max_depth: max_depth)
      {r.json, r.complete}
    end

    # One pass over the slice. Not a value tree: the JSON is emitted as the bytes are read, so a
    # 2 MiB body costs one output string rather than a graph of boxed values that is thrown away
    # immediately after rendering.
    private class Parser
      getter pos = 0
      getter? ok = true
      # WHY the parse stopped, or nil when it did not. The FIRST reason wins: an inner value
      # running out of input is what happened, and every level above it only reports that.
      getter stop : String?

      def initialize(@data : Bytes, @max_depth : Int32)
        @items = 0
        @stop = nil.as(String?)
      end

      # Read one value at `depth` and write it to `j`. Every exit that cannot continue clears
      # `ok` and writes SOMETHING — a JSON document with a hole in it is not a document, and the
      # caller's contract is that the text renders whatever was legible.
      def value(j : JSON::Builder, depth : Int32) : Nil
        return bail(j, "stopped") unless @ok
        return bail(j, "max_depth") if depth > @max_depth
        @items += 1
        return bail(j, "max_items") if @items > MAX_ITEMS
        b = byte || return bail(j, "truncated")
        # The one-byte forms, where the header IS the value or carries the length in its low
        # bits. Everything else has a separate length or width and goes to `headed`.
        case b
        when .<= 0x7f   then j.number(b)                      # positive fixint
        when .>= 0xe0   then j.number(b.to_i8!)               # negative fixint
        when 0x80..0x8f then map(j, (b & 0x0f).to_i, depth)   # fixmap
        when 0x90..0x9f then array(j, (b & 0x0f).to_i, depth) # fixarray
        when 0xa0..0xbf then str(j, (b & 0x1f).to_i)          # fixstr
        else                 headed(j, b, depth)
        end
      end

      # 0xc0..0xdf: the constants, and the forms whose header is followed by a fixed-width
      # value. Split out of `value` so neither table has to be read past what it decides.
      private def headed(j : JSON::Builder, b : UInt8, depth : Int32) : Nil
        case b
        when 0xc0       then j.null
        when 0xc2       then j.bool(false)
        when 0xc3       then j.bool(true)
        when 0xca, 0xcb then float(j, b == 0xca ? 4 : 8)
        when 0xcc..0xcf then uint(j, 1 << (b - 0xcc))
        when 0xd0..0xd3 then int(j, 1 << (b - 0xd0))
        else                 sized(j, b, depth)
        end
      end

      # The forms carrying an explicit length or element count.
      private def sized(j : JSON::Builder, b : UInt8, depth : Int32) : Nil
        case b
        when 0xc4..0xc6 then bin(j, len(1 << (b - 0xc4)))
        when 0xc7..0xc9 then ext(j, len(1 << (b - 0xc7)), depth)
        when 0xd4..0xd8 then ext(j, 1 << (b - 0xd4), depth, fixed: true)
        when 0xd9..0xdb then str(j, len(1 << (b - 0xd9)))
        when 0xdc, 0xdd then array(j, len(b == 0xdc ? 2 : 4), depth)
        when 0xde, 0xdf then map(j, len(b == 0xde ? 2 : 4), depth)
        else
          # 0xc1 is the one byte the spec leaves undefined. Meeting it means this is not
          # MessagePack (or not any more), so stop rather than resynchronise on a guess.
          bail(j, "malformed")
        end
      end

      # The JSON text of one value, for use as an object KEY. MessagePack allows any type
      # there and JSON allows only strings, so a non-string key is rendered as its own JSON and
      # used verbatim: `{"1": …}` for the integer 1, `{"[1,2]": …}` for an array. The map
      # carries `"$keys": "non-string"` beside it so the reader is not left guessing whether
      # `"1"` was a string on the wire.
      def key_text(depth : Int32) : String
        JSON.build { |j| value(j, depth) }
      end

      # A declared count is NOT checked against the bytes that remain, and that is deliberate:
      # every msgpack value is at least one byte, so a count larger than the input is a
      # TRUNCATED document, and refusing it up front would render `null` for a body that is
      # mostly readable. The loop is bounded instead — the first element that runs out of input
      # bails, `break unless @ok` ends the loop there, and `MAX_ITEMS` bounds the aggregate.
      # A count too wide to be an Int32 never gets here (`len` returns -1).
      private def map(j : JSON::Builder, n : Int32, depth : Int32) : Nil
        return bail(j, "malformed") if n < 0
        j.object do
          plain = true
          n.times do
            break unless @ok
            # STRUCTURALLY, off the key's own header byte — not off whether its rendering came
            # back quoted. Exactly one non-string type renders as a JSON string (a `uint64`
            # past Int64::MAX, which goes out as digits so it stays exact), so the textual test
            # read `{2**63: 1}` as string-keyed and suppressed the `$keys` marker: a map keyed
            # only on wide integers claimed to be keyed on strings, and was byte-identical to
            # one that really was. The CBOR sibling tests `head.major == 3` for this reason.
            str_key = string_header?(peek)
            k = key_text(depth + 1)
            break unless @ok
            if str_key && k.starts_with?('"')
              j.field(JSON.parse(k).as_s) { value(j, depth + 1) }
            else
              plain = false
              j.field(k) { value(j, depth + 1) }
            end
          end
          j.field("$keys", "non-string") unless plain
        end
      end

      # :ditto:
      private def array(j : JSON::Builder, n : Int32, depth : Int32) : Nil
        return bail(j, "malformed") if n < 0
        j.array do
          n.times do
            break unless @ok
            value(j, depth + 1)
          end
        end
      end

      private def str(j : JSON::Builder, n : Int32) : Nil
        raw = take(n) || return bail(j, "truncated")
        s = String.new(raw)
        # A `str` that is not valid UTF-8 is a fact about the body, not a rendering problem.
        # Scrubbing it to U+FFFD would hand the operator bytes the origin never sent, which is
        # the one thing a capture tool must not do — so it goes out as base64, named.
        if s.valid_encoding?
          j.string(s)
        else
          j.object { j.field "$str_invalid_utf8", Base64.strict_encode(raw) }
        end
      end

      private def bin(j : JSON::Builder, n : Int32) : Nil
        raw = take(n) || return bail(j, "truncated")
        j.object { j.field "$bin", Base64.strict_encode(raw) }
      end

      # `ext` is the application's own type tag plus opaque bytes — the extension point every
      # msgpack-based protocol uses, so it is exactly what an operator is looking at. Type -1 is
      # the one the spec itself defines (a timestamp), and it is decoded because a timestamp
      # rendered as base64 is a fact withheld.
      private def ext(j : JSON::Builder, n : Int32, depth : Int32, fixed : Bool = false) : Nil
        return bail(j, "malformed") if n < 0
        t = byte || return bail(j, "truncated")
        raw = take(n) || return bail(j, "truncated")
        type = t.to_i8!
        if type == -1
          j.object do
            j.field "$timestamp", timestamp_text(raw)
            # The BYTES too, and that is the module's own "both readings" rule rather than
            # belt-and-braces: `$timestamp` is second-resolution, and the 8- and 12-byte forms
            # carry nanoseconds. Dropping them made the reading unreconstructible — a fact
            # withheld, which is exactly what the comment above claims not to do.
            j.field "$ext", Base64.strict_encode(raw)
            j.field "$ext_type", type
          end
        else
          j.object do
            j.field "$ext", Base64.strict_encode(raw)
            j.field "$ext_type", type
          end
        end
      end

      # The spec's three timestamp encodings (4, 8 and 12 bytes). An unrecognised width is
      # reported as its bytes rather than as a wrong time.
      private def timestamp_text(raw : Bytes) : String
        case raw.size
        when 4
          Time.unix(be(raw, 0, 4).to_i64).to_rfc3339
        when 8
          packed = be(raw, 0, 8)
          Time.unix((packed & 0x3_ffff_ffff_u64).to_i64).to_rfc3339
        when 12
          Time.unix(be(raw, 4, 8).to_i64!).to_rfc3339
        else
          Base64.strict_encode(raw)
        end
      rescue ArgumentError | OverflowError
        # A seconds field far outside `Time`'s range is corrupt input, not an error to raise on.
        Base64.strict_encode(raw)
      end

      private def uint(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        v = be(raw, 0, width)
        # Past Int64::MAX a JSON number is no longer exact in most readers, and Crystal's own
        # builder takes an Int64. The digits go out as a string rather than as a wrong number.
        v <= Int64::MAX.to_u64 ? j.number(v.to_i64) : j.string(v.to_s)
      end

      private def int(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        v = be(raw, 0, width)
        j.number(sign_extend(v, width))
      end

      private def float(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        bits = be(raw, 0, width)
        f = width == 4 ? bits.to_u32!.unsafe_as(Float32).to_f64 : bits.unsafe_as(Float64)
        # NaN and the infinities are not JSON numbers. Named rather than dropped, because a
        # float that is not a number is usually the interesting one.
        if f.nan? || f.infinite?
          j.object { j.field "$float", f.nan? ? "NaN" : (f > 0 ? "Infinity" : "-Infinity") }
        else
          j.number(f)
        end
      end

      # --- byte plumbing -----------------------------------------------------------------

      # The next header byte without consuming it, or nil at the end.
      private def peek : UInt8?
        @pos < @data.size ? @data.unsafe_fetch(@pos) : nil
      end

      # Is this header one of the three `str` forms? `bin` is deliberately NOT one: it is a
      # byte string, it renders as a `$bin` wrapper, and a map keyed on one is not string-keyed.
      private def string_header?(h : UInt8?) : Bool
        return false unless h
        (0xa0_u8 <= h <= 0xbf_u8) || (0xd9_u8 <= h <= 0xdb_u8)
      end

      private def byte : UInt8?
        return nil if @pos >= @data.size
        b = @data.unsafe_fetch(@pos)
        @pos += 1
        b
      end

      # A length field, read big-endian. Returns -1 when the input ran out or the value cannot
      # be an Int32 — every caller treats a negative length as "stop", so an over-wide length
      # never reaches an allocation.
      private def len(width : Int32) : Int32
        raw = take(width) || return -1
        v = be(raw, 0, width)
        v > Int32::MAX.to_u64 ? -1 : v.to_i32
      end

      private def take(n : Int32) : Bytes?
        return nil if n < 0
        if @data.size - @pos < n
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
        out = @data[@pos, n]
        @pos += n
        out
      end

      private def be(raw : Bytes, off : Int32, width : Int32) : UInt64
        v = 0_u64
        width.times { |i| v = (v << 8) | raw[off + i].to_u64 }
        v
      end

      # `to_i64!`, the WRAPPING conversion, and only for the 64-bit case: an `int64` on the wire
      # is a bit pattern to reinterpret, not a magnitude to convert, and every negative one has
      # the high bit set — so the checked `to_i64` raises `OverflowError` on exactly the values
      # this branch exists for. That raise is the one thing this module promises not to do, and
      # a hand-written spec did not catch it because the widths below 8 cannot reach it (a
      # reference encoder's `-2147483649` did).
      private def sign_extend(v : UInt64, width : Int32) : Int64
        bits = width * 8
        return v.to_i64! if bits == 64
        top = 1_u64 << (bits - 1)
        (v & top) == 0 ? v.to_i64 : (v.to_i64 - (1_i64 << bits))
      end

      # Stop, and leave the document renderable — a marker naming WHY, in the value position
      # where the parse gave up. A bare `null` there was indistinguishable from a document that
      # really holds a nil, so `[1, null]` meant either "two elements, the second nil" or "the
      # body was cut off after the first" and the reader could not tell. The CBOR sibling has
      # always named it; the docs promised both did.
      private def bail(j : JSON::Builder, reason : String) : Nil
        @ok = false
        @stop ||= reason
        j.object { j.field "$partial", @stop }
      end
    end
  end
end
