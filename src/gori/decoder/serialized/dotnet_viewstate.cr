require "../serialized"

module Gori::Decoder::Serialized
  # ASP.NET ViewState — the `LosFormatter` / `ObjectStateFormatter` token tree behind every
  # `__VIEWSTATE` field that starts `/wE` (#1011).
  #
  # `Probe::Passive::SerializedObject` already flags one; this reads it. The token values and
  # the widths below are transcribed from `ObjectStateFormatter.cs` in Microsoft's
  # `referencesource`, `DeserializeValue`, so they are the format rather than a reconstruction
  # of it.
  #
  # ## MAC-present versus MAC-absent, which is the finding
  #
  # A ViewState carries no marker for its MAC: `MachineKeySection.GetDecodedData` simply strips
  # a signature of the hash's length off the end. So a whole value tree followed by a SHORT
  # trailing run is a signed ViewState, and this reader consumes that run and names it —
  # `{"mac": {"bytes": 20, "algorithm": "HMACSHA1"}}` — rather than leaving it as trailing
  # bytes, which `BinaryDocument::Rendering#describes?` would (correctly) read as "this body is
  # not a ViewState" and refuse. No trailing run at all means `EnableViewStateMac` is off,
  # which is the whole of CVE-2020-0688's precondition and worth saying out loud.
  #
  # An ENCRYPTED ViewState is deliberately left alone: it does not begin `/wE` (`FF 01`), so it
  # never reaches here, and the passive rule declines it for the same reason — encryption is
  # the fix, and flagging it would punish the secure configuration.
  #
  # ## `Token_BinarySerialized` is where a gadget chain lives, and it is not unpacked
  #
  # It carries a `BinaryFormatter` (MS-NRBF) graph, a different format again — the ysoserial.net
  # / ToolShell sink. The bytes come back named, with the record header identified when it is
  # there, and reading MS-NRBF is left out of scope rather than half-done.
  module DotnetViewState
    extend self

    # `FF 01` — `Marker_Format` then `Marker_Version_1`, base64 `/wE…`.
    MARKER_FORMAT    = 0xff_u8
    MARKER_VERSION_1 = 0x01_u8

    TOKEN_INT16              =   1_u8
    TOKEN_INT32              =   2_u8
    TOKEN_BYTE               =   3_u8
    TOKEN_CHAR               =   4_u8
    TOKEN_STRING             =   5_u8
    TOKEN_DATETIME           =   6_u8
    TOKEN_DOUBLE             =   7_u8
    TOKEN_SINGLE             =   8_u8
    TOKEN_COLOR              =   9_u8
    TOKEN_KNOWN_COLOR        =  10_u8
    TOKEN_INT_ENUM           =  11_u8
    TOKEN_EMPTY_COLOR        =  12_u8
    TOKEN_PAIR               =  15_u8
    TOKEN_TRIPLET            =  16_u8
    TOKEN_ARRAY              =  20_u8
    TOKEN_STRING_ARRAY       =  21_u8
    TOKEN_ARRAY_LIST         =  22_u8
    TOKEN_HASHTABLE          =  23_u8
    TOKEN_HYBRID_DICTIONARY  =  24_u8
    TOKEN_TYPE               =  25_u8
    TOKEN_UNIT               =  27_u8
    TOKEN_EMPTY_UNIT         =  28_u8
    TOKEN_EVENT_VALIDATION   =  29_u8
    TOKEN_INDEXED_STRING_ADD =  30_u8
    TOKEN_INDEXED_STRING     =  31_u8
    TOKEN_STRING_FORMATTED   =  40_u8
    TOKEN_TYPE_REF_ADD       =  41_u8
    TOKEN_TYPE_REF_ADD_LOCAL =  42_u8
    TOKEN_TYPE_REF           =  43_u8
    TOKEN_BINARY_SERIALIZED  =  50_u8
    TOKEN_SPARSE_ARRAY       =  60_u8
    TOKEN_NULL               = 100_u8
    TOKEN_EMPTY_STRING       = 101_u8
    TOKEN_ZERO_INT32         = 102_u8
    TOKEN_TRUE               = 103_u8
    TOKEN_FALSE              = 104_u8

    # `EventValidationStore.HASH_SIZE_IN_BYTES` — 128 bits per entry.
    EVENT_VALIDATION_HASH = 16

    # Trailing bytes past this are not a signature; they are a body that was never a ViewState.
    # The longest MAC `machineKey` can produce is HMACSHA512's 64.
    MAX_MAC = 64

    # A `BinaryFormatter` `SerializationHeaderRecord` — the same nine bytes
    # `Probe::Passive::SerializedObject::NET_BINFMT` matches base64-encoded.
    BINARY_FORMATTER_HEADER = Bytes[0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff]

    def render(data : Bytes, *, indent : String? = nil) : BinaryDocument::Rendering
      Serialized.build(data, indent) { |sink| Reader.new(data, sink) }
    end

    # :ditto: — the two-element form, for a caller that only wants the text and whether it is
    # whole (every spec, and the Decoder converter).
    def to_json(data : Bytes) : {String, Bool}
      r = render(data)
      {r.json, r.complete}
    end

    # The signing algorithm a MAC of this length came from, or nil for a run that is not one of
    # the lengths `machineKey` can produce.
    def mac_algorithm(bytes : Int32) : String?
      case bytes
      when 16 then "MD5"
      when 20 then "SHA1 / HMACSHA1"
      when 32 then "HMACSHA256"
      when 48 then "HMACSHA384"
      when 64 then "HMACSHA512"
      end
    end

    class Reader < Serialized::Reader
      def initialize(data : Bytes, sink : IO::Memory)
        super
        # `Token_IndexedString` and `Token_TypeRef` are indexes into tables the stream builds
        # as it goes; both are back-references, and both are resolved rather than emitted raw
        # because the whole point of the indexed form is that the text appeared earlier.
        @strings = [] of String
        @types = [] of String
      end

      def document(j : JSON::Builder) : Nil
        head = take(2)
        if head.nil? || head[0] != MARKER_FORMAT || head[1] != MARKER_VERSION_1
          @pos = 0
          return bail(j, "malformed")
        end
        j.object do
          j.field "$format", "aspnet-viewstate"
          j.field "version", 1
          j.field("state") { value(j, 1) }
          trailer(j)
        end
      end

      # A ViewState's MAC has no in-band marker — see the note on the module. A short trailing
      # run is the signature; a long one means this was never a ViewState, and is left as
      # trailing bytes for `describes?` to refuse.
      private def trailer(j : JSON::Builder) : Nil
        return unless @ok
        n = remaining
        if n == 0
          j.field "mac", false
          return
        end
        return if n > MAX_MAC
        raw = rest
        j.field("mac") do
          j.object do
            j.field "bytes", raw.size
            if algo = DotnetViewState.mac_algorithm(raw.size)
              j.field "algorithm", algo
            end
            j.field "$bin", Base64.strict_encode(raw)
          end
        end
      end

      private def value(j : JSON::Builder, depth : Int32) : Nil
        return unless step?(j, depth)
        t = byte || return bail(j, "truncated")
        case t
        when TOKEN_NULL                                     then (got!; j.null)
        when TOKEN_EMPTY_STRING                             then (got!; j.string(""))
        when TOKEN_ZERO_INT32                               then (got!; j.number(0))
        when TOKEN_TRUE, TOKEN_FALSE                        then (got!; j.bool(t == TOKEN_TRUE))
        when TOKEN_STRING                                   then read_string(j)
        when TOKEN_INT32                                    then encoded(j)
        when TOKEN_PAIR, TOKEN_TRIPLET                      then tuple(j, t == TOKEN_PAIR ? 2 : 3, depth)
        when TOKEN_INDEXED_STRING_ADD, TOKEN_INDEXED_STRING then indexed(j, t)
        else                                                     numeric(j, t, depth)
        end
      end

      # The fixed-width scalars and the two-word values built out of them.
      private def numeric(j : JSON::Builder, t : UInt8, depth : Int32) : Nil
        case t
        when TOKEN_INT16       then fixed_int(j, 2)
        when TOKEN_BYTE        then fixed_int(j, 1)
        when TOKEN_CHAR        then read_char(j)
        when TOKEN_DOUBLE      then real(j, 8)
        when TOKEN_SINGLE      then real(j, 4)
        when TOKEN_DATETIME    then date_time(j)
        when TOKEN_COLOR       then wrapped_int(j, "$color", 4)
        when TOKEN_KNOWN_COLOR then wrapped_encoded(j, "$known_color")
        when TOKEN_EMPTY_COLOR then (got!; j.object { j.field "$color", "empty" })
        when TOKEN_UNIT        then unit(j)
        when TOKEN_EMPTY_UNIT  then (got!; j.object { j.field "$unit", "empty" })
        else                        structured(j, t, depth)
        end
      end

      # The containers and the values that carry a TYPE.
      private def structured(j : JSON::Builder, t : UInt8, depth : Int32) : Nil
        case t
        when TOKEN_ARRAY_LIST                         then list(j, depth)
        when TOKEN_STRING_ARRAY                       then string_array(j, depth)
        when TOKEN_ARRAY                              then typed_array(j, depth)
        when TOKEN_SPARSE_ARRAY                       then sparse_array(j, depth)
        when TOKEN_HASHTABLE, TOKEN_HYBRID_DICTIONARY then table(j, t, depth)
        when TOKEN_TYPE                               then type_value(j)
        when TOKEN_INT_ENUM                           then int_enum(j)
        when TOKEN_STRING_FORMATTED                   then string_formatted(j)
        when TOKEN_BINARY_SERIALIZED                  then binary_serialized(j)
        when TOKEN_EVENT_VALIDATION                   then event_validation(j)
        else
          @pos -= 1
          bail(j, "malformed")
        end
      end

      # --- scalars -------------------------------------------------------------------------

      private def fixed_int(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        got!
        # `Token_Byte` is a .NET `byte` (unsigned); `Token_Int16` is signed.
        j.number(width == 1 ? le(raw).to_i64 : sign_extend(le(raw), 16))
      end

      private def real(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        got!
        f = width == 8 ? IO::ByteFormat::LittleEndian.decode(Float64, raw) : IO::ByteFormat::LittleEndian.decode(Float32, raw).to_f64
        number(j, f)
      end

      # `BinaryReader.ReadChar` over a UTF-8 stream: one character, however many bytes that is.
      private def read_char(j : JSON::Builder) : Nil
        lead = peek || return bail(j, "truncated")
        n = case
            when lead < 0x80           then 1
            when (lead & 0xe0) == 0xc0 then 2
            when (lead & 0xf0) == 0xe0 then 3
            when (lead & 0xf8) == 0xf0 then 4
            else                            0
            end
        return bail(j, "malformed") if n == 0
        raw = take(n) || return bail(j, "truncated")
        got!
        text(j, raw)
      end

      # `BinaryReader.ReadString`: a 7-bit-encoded BYTE length, then UTF-8.
      private def read_string(j : JSON::Builder) : Nil
        raw = string_bytes(j) || return
        got!
        text(j, raw)
      end

      private def string_bytes(j : JSON::Builder) : Bytes?
        n = encoded_int || return length_stop(j)
        if n < 0
          bail(j, "malformed")
          return nil
        end
        raw = take(n)
        unless raw
          bail(j, "truncated")
          return nil
        end
        raw
      end

      private def length_stop(j : JSON::Builder) : Nil
        bail(j, @stop || "truncated")
        nil
      end

      # `Token_Int32` is written with `WriteEncoded`, so it is 7-bit encoded and a negative one
      # takes all five groups — hence the reinterpretation rather than a widening.
      private def encoded(j : JSON::Builder) : Nil
        v = encoded_int || return length_stop(j)
        got!
        j.number(v)
      end

      # `Read7BitEncodedInt`: up to five 7-bit groups, least significant first. A sixth group,
      # or a fifth that keeps going, is not this format.
      private def encoded_int : Int32?
        v = 0_u32
        shift = 0
        5.times do
          b = byte
          unless b
            halt("truncated")
            return nil
          end
          v |= (b & 0x7f).to_u32 << shift
          return sign_extend(v.to_u64, 32).to_i32 if (b & 0x80) == 0
          shift += 7
        end
        halt("malformed")
        nil
      end

      # `DateTime.FromBinary`: the top two bits are the `DateTimeKind`, the rest is ticks of
      # 100ns since 0001-01-01. Spelled out as a date because that is the field an operator is
      # looking for, with the raw ticks kept beside it.
      private def date_time(j : JSON::Builder) : Nil
        raw = take(8) || return bail(j, "truncated")
        bits = le(raw)
        ticks = (bits & 0x3fff_ffff_ffff_ffff_u64).to_i64
        got!
        j.object do
          j.field "$datetime", iso_time(ticks) || "out-of-range"
          j.field "kind", KINDS[((bits >> 62) & 3).to_i32]
          j.field "ticks", ticks
        end
      end

      KINDS = ["Unspecified", "Utc", "Local", "Local"]

      # Ticks are 100ns since year 1; `Time` counts seconds, so the sub-second remainder rides
      # along as a fraction. nil when the value is outside the calendar, which a hostile or
      # mis-read field routinely is.
      private def iso_time(ticks : Int64) : String?
        return nil if ticks < 0 || ticks > 3_155_378_975_999_999_999_i64
        (Time.utc(1, 1, 1) + Time::Span.new(seconds: ticks // 10_000_000,
          nanoseconds: (ticks % 10_000_000) * 100)).to_rfc3339
      rescue
        nil
      end

      private def unit(j : JSON::Builder) : Nil
        raw = take(8) || return bail(j, "truncated")
        kind = take(4) || return bail(j, "truncated")
        got!
        j.object do
          j.field("$unit") { number(j, IO::ByteFormat::LittleEndian.decode(Float64, raw)) }
          j.field "type", sign_extend(le(kind), 32)
        end
      end

      private def wrapped_int(j : JSON::Builder, name : String, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        got!
        j.object { j.field name, sign_extend(le(raw), width * 8) }
      end

      private def wrapped_encoded(j : JSON::Builder, name : String) : Nil
        v = encoded_int || return length_stop(j)
        got!
        j.object { j.field name, v }
      end

      # --- containers ----------------------------------------------------------------------

      private def tuple(j : JSON::Builder, n : Int32, depth : Int32) : Nil
        got!
        j.object do
          j.field(n == 2 ? "$pair" : "$triplet") do
            j.array do
              n.times do
                break unless @ok
                value(j, depth + 1)
              end
            end
          end
        end
      end

      private def list(j : JSON::Builder, depth : Int32) : Nil
        n = count(j) || return
        got!
        j.array do
          n.times do
            break unless @ok
            value(j, depth + 1)
          end
        end
      end

      # Charged per element, unlike the other containers: its elements do not go through
      # `value`, so nothing else counts them and a large count of empty strings would render
      # without bound.
      private def string_array(j : JSON::Builder, depth : Int32) : Nil
        n = count(j) || return
        got!
        j.array do
          n.times do
            break unless step?(j, depth + 1)
            raw = string_bytes(j)
            break unless raw
            text(j, raw)
          end
        end
      end

      private def typed_array(j : JSON::Builder, depth : Int32) : Nil
        t = read_type(j) || return
        n = count(j) || return
        got!
        j.object do
          j.field "$array", t
          j.field("values") do
            j.array do
              n.times do
                break unless @ok
                value(j, depth + 1)
              end
            end
          end
        end
      end

      # `Token_SparseArray`: a length, an item count, then `(index, value)` pairs — the elements
      # that are not the default. The gaps are a fact about the array, so the projection keeps
      # the declared length beside the items rather than materialising nulls.
      private def sparse_array(j : JSON::Builder, depth : Int32) : Nil
        t = read_type(j) || return
        n = count(j) || return
        items = count(j) || return
        if items > n
          bail(j, "malformed")
          return
        end
        got!
        j.object do
          j.field "$sparse_array", t
          j.field "length", n
          j.field("items") do
            j.object do
              items.times do
                break unless @ok
                idx = count(j)
                unless idx
                  j.field("$partial", @stop || "stopped")
                  break
                end
                j.field(idx.to_s) { value(j, depth + 1) }
              end
            end
          end
        end
      end

      # A `Hashtable` allows any value as a KEY and JSON allows only strings, so a non-string
      # key is rendered as its own JSON and used verbatim, with `"$keys": "non-string"` beside
      # it — the same marker, and the same accepted ambiguity, as `Msgpack::Parser#map`.
      private def table(j : JSON::Builder, t : UInt8, depth : Int32) : Nil
        n = count(j) || return
        got!
        j.object do
          j.field "$type", t == TOKEN_HASHTABLE ? "Hashtable" : "HybridDictionary"
          plain = true
          j.field("entries") do
            j.object do
              n.times do
                break unless @ok
                str_key = string_token?(peek)
                k = scratch { |kj| value(kj, depth + 1) }
                unless @ok
                  j.field("$partial", @stop || "stopped")
                  break
                end
                if str_key && k.starts_with?('"')
                  j.field(JSON.parse(k).as_s) { value(j, depth + 1) }
                else
                  plain = false
                  j.field(k) { value(j, depth + 1) }
                end
              end
            end
          end
          j.field("$keys", "non-string") unless plain
        end
      end

      # STRUCTURALLY, off the key's own token — not off whether its rendering came back quoted.
      # An indexed string is a string on the wire even though it arrives as an index.
      private def string_token?(t : UInt8?) : Bool
        return false unless t
        t == TOKEN_STRING || t == TOKEN_EMPTY_STRING ||
          t == TOKEN_INDEXED_STRING || t == TOKEN_INDEXED_STRING_ADD
      end

      # --- types and the two opaque payloads -------------------------------------------------

      # `Token_IndexedStringAdd` carries the text and appends it to the table;
      # `Token_IndexedString` is a one-BYTE index into it.
      private def indexed(j : JSON::Builder, t : UInt8) : Nil
        if t == TOKEN_INDEXED_STRING_ADD
          raw = string_bytes(j) || return
          s = String.new(raw)
          # UNCONDITIONALLY, because the table is POSITIONAL: dropping an entry that is not
          # text shifts every later `Token_IndexedString` by one, and the index then resolves
          # to a real but WRONG string with nothing on the row to say so. `read_type` does the
          # same base64 substitution next door for the same reason.
          @strings << (s.valid_encoding? ? s : Base64.strict_encode(raw))
          got!
          return text(j, raw)
        end
        i = byte || return bail(j, "truncated")
        got!
        if s = @strings[i.to_i32]?
          j.string(s)
        else
          j.object { j.field "$string_index", i.to_i32 }
        end
      end

      # `DeserializeType`: a type reference that either carries the name and adds it to the
      # table, or indexes back into it.
      private def read_type(j : JSON::Builder) : String?
        t = byte
        unless t
          bail(j, "truncated")
          return nil
        end
        case t
        when TOKEN_TYPE_REF_ADD, TOKEN_TYPE_REF_ADD_LOCAL
          raw = string_bytes(j) || return nil
          name = String.new(raw)
          name = name.valid_encoding? ? name : Base64.strict_encode(raw)
          # `Token_TypeRefAddLocal` resolves against `System.Web` rather than by full name.
          name = "#{name}, System.Web" if t == TOKEN_TYPE_REF_ADD_LOCAL
          @types << name
          name
        when TOKEN_TYPE_REF
          i = encoded_int
          unless i
            length_stop(j)
            return nil
          end
          # `i < 0` before the lookup: Crystal's `Array#[]?` counts a negative index from the
          # END, so a `Token_TypeRef` of -1 would resolve to the most recent type and show the
          # operator a name the stream never wrote. `count` guards the same way one field over.
          i < 0 ? "$type_index:#{i}" : (@types[i]? || "$type_index:#{i}")
        else
          @pos -= 1
          bail(j, "malformed")
          nil
        end
      end

      private def type_value(j : JSON::Builder) : Nil
        t = read_type(j) || return
        got!
        j.object { j.field "$type", t }
      end

      private def int_enum(j : JSON::Builder) : Nil
        t = read_type(j) || return
        v = encoded_int || return length_stop(j)
        got!
        j.object do
          j.field "$enum", t
          j.field "value", v
        end
      end

      # A value the framework round-trips through its `TypeConverter` — the type, and the
      # invariant string it converts from.
      private def string_formatted(j : JSON::Builder) : Nil
        t = read_type(j) || return
        raw = string_bytes(j) || return
        got!
        j.object do
          j.field "$formatted", t
          j.field("value") { text(j, raw) }
        end
      end

      # `Token_BinarySerialized`: a length, then a `BinaryFormatter` (MS-NRBF) graph — a
      # different format, and the one a ysoserial.net payload actually lives in. The bytes come
      # back named, with the record header identified when it is there; reading MS-NRBF is left
      # out rather than half-done.
      private def binary_serialized(j : JSON::Builder) : Nil
        n = encoded_int || return length_stop(j)
        if n < 0
          bail(j, "malformed")
          return
        end
        raw = take(n)
        return bail(j, "truncated") unless raw
        got!
        j.object do
          j.field "$binaryformatter", binary_formatter?(raw)
          j.field "bytes", raw.size
          j.field "$bin", Base64.strict_encode(raw)
        end
      end

      private def binary_formatter?(raw : Bytes) : Bool
        raw.size >= BINARY_FORMATTER_HEADER.size &&
          raw[0, BINARY_FORMATTER_HEADER.size] == BINARY_FORMATTER_HEADER
      end

      # `EventValidationStore.DeserializeFrom`: a version byte, a count, then that many 128-bit
      # hashes of the (target, argument) pairs the page will accept.
      private def event_validation(j : JSON::Builder) : Nil
        v = byte || return bail(j, "truncated")
        return bail(j, "malformed") unless v == 0
        n = encoded_int || return length_stop(j)
        if n < 0
          bail(j, "malformed")
          return
        end
        if n > remaining // EVENT_VALIDATION_HASH
          # BEFORE the multiply, which is checked in Crystal: `n * 16` past `Int32::MAX` raises
          # `OverflowError`, and that is neither of the two exceptions `Serialized.build`
          # catches — it would reach the operator as a backtrace out of the converter.
          # A short read consumes everything that WAS there; see `Reader#take`.
          @pos = @data.size
          bail(j, "truncated")
          return
        end
        raw = take(n * EVENT_VALIDATION_HASH)
        return bail(j, "truncated") unless raw
        got!
        j.object do
          j.field "$event_validation", n
          j.field("hashes") do
            j.array do
              # Charged, like every other loop that emits without descending through `value`:
              # one entry is 16 input bytes and 34 output ones, so a large store renders past
              # `MAX_JSON_BYTES` with nothing else counting it.
              n.times do |i|
                break unless step?(j, 2)
                j.string(raw[i * EVENT_VALIDATION_HASH, EVENT_VALIDATION_HASH].hexstring)
              end
            end
          end
        end
      end

      # A non-negative element count. Every count in this format is 7-bit encoded.
      private def count(j : JSON::Builder) : Int32?
        v = encoded_int
        unless v
          length_stop(j)
          return nil
        end
        if v < 0
          bail(j, "malformed")
          return nil
        end
        v
      end
    end
  end
end
