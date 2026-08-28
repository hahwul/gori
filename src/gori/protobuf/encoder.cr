require "./schema"
require "./lens"

module Gori::Protobuf
  # `Lens`'s inverse: ONE `.proto` declaration + the operator's typed text → the tag and
  # payload bytes that declaration says the value is, and a message rebuilt around them
  # (#828). The write half of #823's read half.
  #
  # ## Why this needs the schema at all
  #
  # The wire says a field is a varint. It does not say whether the declaration behind it is
  # an `int32`, a `bool`, an `enum` or a zigzag `sint32` — and `-3` encodes as ten bytes,
  # one byte, or `05` depending on which. Schema-lessly there is no honest re-encode, which
  # is why editing a gRPC payload was hex-only until a descriptor set was in hand.
  #
  # ## Everything not edited is COPIED, not re-encoded (P7)
  #
  # `replace` is a splice, not a serializer: it takes the original octets, swaps the one
  # field the operator changed, and copies every other byte through unchanged — undeclared
  # field numbers, fields whose wire type the schema contradicts, groups, a non-minimal
  # varint some other producer emitted, and the trailing bytes of a truncated capture.
  # A rebuild with nothing edited is the input slice itself. The message gori sends is the
  # message it captured, minus exactly one field.
  #
  # ## Errors are sentences, not exceptions
  #
  # Every entry point returns `Bytes | String`, where the String is what to show the
  # operator. The input is a human typing into a one-line field; "not a number" is the
  # normal case, not an exceptional one.
  module Encoder
    extend self

    # Elements one packed edit may carry. A packed run can legally hold hundreds of
    # thousands, but this is a value TYPED into a single-line field — past this the input is
    # not what the field is for, and `Lens::PACKED_MAX` has already stopped listing them.
    MAX_PACKED = 512

    # Separators a `bytes` field's hex accepts between octets, so `de ad be ef` (what the
    # tree prints) and `de:ad:be:ef` (what every other tool prints) both paste in.
    HEX_SEPARATORS = " \t\r\n:-_"

    # --- encoding one field --------------------------------------------------

    # The tag + payload for `d` carrying `text`. `packed` says the occurrence being replaced
    # arrived length-delimited on a repeated packable field — a comma/space separated list
    # goes back the same way, so a packed run stays packed and an unpacked repeated field
    # stays unpacked. Neither shape is invented: this only re-emits the one the wire had.
    def encode(schema : Schema, d : Schema::FieldDef, text : String, *, packed : Bool) : Bytes | String
      return encode_packed(schema, d, text) if packed
      case d.type
      when .string?
        return "the value is not valid UTF-8" unless text.valid_encoding?
        length_delimited(d.number, text.to_slice)
      when .bytes?
        case parsed = parse_hex(text)
        in String then parsed
        in Bytes  then length_delimited(d.number, parsed)
        end
      when .message?, .group?
        "#{d.name} is a #{d.type_label} — edit the fields inside it, or ^X for its bytes"
      else
        case payload = scalar_payload(schema, d, text)
        in String then payload
        in Bytes
          io = IO::Memory.new
          write_tag(io, d.number, scalar_wire(d.type))
          io.write(payload)
          io.to_slice
        end
      end
    end

    # The text `encode` would turn back into the bytes already on the wire — what the input
    # field is SEEDED with, so applying an untouched value re-emits what was captured.
    # nil when the reading has no single-line text form: the caller keeps that row read-only
    # rather than seeding a lossy value into an editor (see `editable?`).
    def seed(d : Schema::FieldDef, f : Protobuf::Field, r : Lens::Reading) : String?
      if packed = r.packed
        # Two ways a packed run has no faithful text form, and BOTH drop bytes on apply:
        # elements past `Lens::PACKED_MAX` that the lens stopped listing, and a run that ended
        # MID-ELEMENT — `read_packed` reports that one as a note with `packed_more` still 0,
        # so counting only the omitted elements let a truncated run seed as its decodable
        # prefix and re-encode without the leftover octets. That capture is deliberately
        # malformed; silently repairing it is the one thing this editor must not do.
        return nil if r.packed_more > 0 || r.note
        return packed.map { |v| scalar_text(v) }.join(", ")
      end
      return hex_text(f.bytes || Bytes.empty) if d.type.bytes?
      # The enum's NAME when the schema has one: it is what the operator reads on the row,
      # and `encode` takes it back. An unnamed value seeds as its number, which is the only
      # thing anyone knows about it.
      if d.type.enum? && (label = r.enum_name)
        return label
      end
      v = r.value
      return nil if v.nil?
      # A string carrying a control byte has no one-line form: the ROW escapes it (`"a\nb"`),
      # a terminal cell paints it as a space, and an operator retyping what they see would
      # turn 0x0A into 0x20 with nothing on screen having said so. Read-only, and `^X`.
      return nil if v.is_a?(String) && v.each_char.any?(&.control?)
      scalar_text(v)
    end

    # --- rebuilding the message ----------------------------------------------

    # `data` with the field at `path` replaced by `encoded`, every other byte copied
    # verbatim. `path` is field INDICES — `[3]` is the fourth top-level field on the wire,
    # `[3, 0]` the first field of the message inside it — because a field NUMBER can occur
    # more than once and only the index says which occurrence was picked.
    #
    # A nested replacement re-emits the enclosing field's ORIGINAL tag bytes and a freshly
    # measured length; only the containers on the edited path are rebuilt at all.
    def replace(data : Bytes, path : Array(Int32), encoded : Bytes) : Bytes | String
      return "no field is selected" if path.empty?
      spans = Protobuf.field_spans(data)
      i = path[0]
      return "the message changed under the editor — reopen the field list" unless 0 <= i < spans.size
      s = spans[i]
      field = if path.size == 1
                encoded
              else
                unless s.wire.length_delimited?
                  return "field #{s.number} is not a message — nothing to descend into"
                end
                inner = replace(data[s.body, s.body_size], path[1..], encoded)
                return inner if inner.is_a?(String)
                io = IO::Memory.new
                io.write(data[s.start, s.value - s.start]) # the tag, exactly as it arrived
                write_varint(io, inner.size.to_u64)
                io.write(inner)
                io.to_slice
              end
      spliced = IO::Memory.new(data.size - s.size + field.size)
      spliced.write(data[0, s.start])
      spliced.write(field)
      spliced.write(data[s.finish, data.size - s.finish])
      spliced.to_slice
    end

    # --- scalars --------------------------------------------------------------

    # The wire type a scalar declaration encodes to. Message/group/string/bytes never reach
    # here (`encode` handles them above); they answer length-delimited so the `case` is total.
    def scalar_wire(type : Schema::FieldType) : Protobuf::WireType
      case type
      when .fixed32?, .s_fixed32?, .float?       then Protobuf::WireType::Fixed32
      when .fixed64?, .s_fixed64?, .double?      then Protobuf::WireType::Fixed64
      when .string?, .bytes?, .message?, .group? then Protobuf::WireType::LengthDelimited
      else                                            Protobuf::WireType::Varint
      end
    end

    # One scalar's payload bytes — no tag, so a packed run can concatenate them.
    private def scalar_payload(schema : Schema, d : Schema::FieldDef, text : String) : Bytes | String
      t = text.strip
      case d.type
      when .int32?     then int_varint(t, Int32::MIN.to_i64, Int32::MAX.to_i64, "int32")
      when .int64?     then int_varint(t, Int64::MIN, Int64::MAX, "int64")
      when .u_int32?   then uint_varint(t, UInt32::MAX.to_u64, "uint32")
      when .u_int64?   then uint_varint(t, UInt64::MAX, "uint64")
      when .s_int32?   then zigzag_varint(t, Int32::MIN.to_i64, Int32::MAX.to_i64, "sint32")
      when .s_int64?   then zigzag_varint(t, Int64::MIN, Int64::MAX, "sint64")
      when .bool?      then parse_bool(t)
      when .enum?      then parse_enum(schema, d, t)
      when .fixed32?   then uint_fixed32(t, "fixed32")
      when .fixed64?   then uint_fixed64(t, "fixed64")
      when .s_fixed32? then int_fixed32(t)
      when .s_fixed64? then int_fixed64(t)
      when .float?
        f = parse_float(t) || return "#{t.inspect} is not a float"
        # `to_f32!`, not `to_f32`: the checked cast RAISES on a value past Float32's range,
        # in a module whose whole contract is a sentence back rather than an exception. The
        # unchecked one saturates to Infinity, which is exactly the case named below.
        v = f.to_f32!
        return "#{t.inspect} does not fit a float (32-bit)" if v.infinite? && !f.infinite?
        bytes32(v.unsafe_as(UInt32))
      when .double?
        f = parse_float(t) || return "#{t.inspect} is not a double"
        bytes64(f.unsafe_as(UInt64))
      else
        "#{d.type_label} has no single-value form"
      end
    end

    # A scalar as text `scalar_payload` reads back. Kept beside it so the round trip is one
    # decision in one place.
    private def scalar_text(v : Lens::Scalar) : String
      case v
      in String        then v
      in Bool          then v ? "true" : "false"
      in Int64, UInt64 then v.to_s
      in Float32, Float64
        # `to_s` is shortest-round-trip for a finite float; the three non-finite spellings are
        # not parseable by `to_f64?`, so `parse_float` names the same three.
        v.finite? ? v.to_s : (v.nan? ? "nan" : (v > 0 ? "inf" : "-inf"))
      end
    end

    private def encode_packed(schema : Schema, d : Schema::FieldDef, text : String) : Bytes | String
      parts = text.split(/[,\s]+/).reject(&.empty?)
      if parts.size > MAX_PACKED
        return "#{parts.size} elements — more than the #{MAX_PACKED} this field takes"
      end
      payload = IO::Memory.new
      parts.each_with_index do |p, i|
        case bytes = scalar_payload(schema, d, p)
        in String then return "element #{i + 1}: #{bytes}"
        in Bytes  then payload.write(bytes)
        end
      end
      length_delimited(d.number, payload.to_slice)
    end

    # --- text → number --------------------------------------------------------

    private def int_varint(t : String, lo : Int64, hi : Int64, name : String) : Bytes | String
      v = parse_int(t) || return "#{t.inspect} is not an integer"
      return "#{v} does not fit #{name} (#{lo}..#{hi})" unless lo <= v <= hi
      # Negative int32/int64 are SIGN-EXTENDED to 64 bits on the wire — ten bytes for -1.
      # Truncating to 32 bits here is the classic re-encode bug: the reader sign-extends
      # what it finds, so -7 in four bytes comes back as 4294967289.
      varint_bytes(v.to_u64!)
    end

    private def uint_varint(t : String, hi : UInt64, name : String) : Bytes | String
      v = parse_uint(t) || return "#{t.inspect} is not a non-negative integer"
      return "#{v} does not fit #{name} (0..#{hi})" unless v <= hi
      varint_bytes(v)
    end

    private def zigzag_varint(t : String, lo : Int64, hi : Int64, name : String) : Bytes | String
      v = parse_int(t) || return "#{t.inspect} is not an integer"
      return "#{v} does not fit #{name} (#{lo}..#{hi})" unless lo <= v <= hi
      # zigzag: `(n << 1) ^ (n >> 63)`. `<<` on Int64 wraps in Crystal, which is what the
      # encoding wants at the extremes.
      varint_bytes(((v << 1) ^ (v >> 63)).to_u64!)
    end

    private def uint_fixed32(t : String, name : String) : Bytes | String
      v = parse_uint(t) || return "#{t.inspect} is not a non-negative integer"
      return "#{v} does not fit #{name} (0..#{UInt32::MAX})" if v > UInt32::MAX.to_u64
      bytes32(v.to_u32)
    end

    private def uint_fixed64(t : String, name : String) : Bytes | String
      v = parse_uint(t) || return "#{t.inspect} is not a non-negative integer"
      bytes64(v)
    end

    private def int_fixed32(t : String) : Bytes | String
      v = parse_int(t) || return "#{t.inspect} is not an integer"
      unless Int32::MIN.to_i64 <= v <= Int32::MAX.to_i64
        return "#{v} does not fit sfixed32 (#{Int32::MIN}..#{Int32::MAX})"
      end
      bytes32(v.to_i32.to_u32!)
    end

    private def int_fixed64(t : String) : Bytes | String
      v = parse_int(t) || return "#{t.inspect} is not an integer"
      bytes64(v.to_u64!)
    end

    # `true`/`false` first, then 1/0 — a `bool` field renders as `true` and has to take back
    # what it showed.
    private def parse_bool(t : String) : Bytes | String
      case t.downcase
      when "true", "1"  then Bytes[1]
      when "false", "0" then Bytes[0]
      else                   "#{t.inspect} is not a bool — type true or false"
      end
    end

    # An enum takes its NAME (what the row shows) or its number. A name the schema does not
    # carry is refused rather than guessed at; a NUMBER outside the declaration is accepted,
    # because sending a value the API has never named is a thing an operator does on purpose.
    private def parse_enum(schema : Schema, d : Schema::FieldDef, t : String) : Bytes | String
      e = d.type_name.try { |tn| schema.enum?(tn) }
      if e
        e.values.each { |num, name| return varint_bytes(num.to_u64!) if name == t }
      end
      if v = parse_int(t)
        unless Int32::MIN.to_i64 <= v <= Int32::MAX.to_i64
          return "#{v} does not fit an enum (int32)"
        end
        return varint_bytes(v.to_u64!)
      end
      # Neither a declared name nor a number. Naming a few of the values it COULD have is the
      # difference between "wrong" and "wrong, and here is the vocabulary".
      if e && !(known = e.values.values.first(6).join(", ")).empty?
        return "#{t.inspect} is not a value of #{e.full_name} — try #{known}"
      end
      "#{t.inspect} is not an enum value or number"
    end

    # Underscores are stripped so a long id can be typed the way it reads; `0x`/`0b`/`0o`
    # are Crystal's own prefixes and `to_i64?(prefix: true)` takes them.
    private def parse_int(t : String) : Int64?
      s = t.delete('_')
      return nil if s.empty?
      s.to_i64?(underscore: false, prefix: true, whitespace: false)
    end

    private def parse_uint(t : String) : UInt64?
      s = t.delete('_')
      return nil if s.empty?
      s.to_u64?(underscore: false, prefix: true, whitespace: false)
    end

    # The three spellings `scalar_text` writes for a non-finite float, plus what a human
    # would type. `to_f64?` handles none of them.
    private def parse_float(t : String) : Float64?
      case t.downcase
      when "inf", "+inf", "infinity", "+infinity" then Float64::INFINITY
      when "-inf", "-infinity"                    then -Float64::INFINITY
      when "nan"                                  then Float64::NAN
      else                                             t.to_f64?(whitespace: false)
      end
    end

    # --- bytes ----------------------------------------------------------------

    # `bytes` is edited as HEX: the payload is binary by declaration, and a text field that
    # took characters would silently re-encode them as UTF-8 — a different set of octets
    # than the ones on screen.
    private def parse_hex(text : String) : Bytes | String
      cleaned = text.delete { |c| HEX_SEPARATORS.includes?(c) }
      cleaned = cleaned[2..] if cleaned.size > 2 && (cleaned.starts_with?("0x") || cleaned.starts_with?("0X"))
      return Bytes.empty if cleaned.empty?
      return "hex needs an even number of digits (#{cleaned.size} given)" if cleaned.size.odd?
      buf = Bytes.new(cleaned.size // 2)
      i = 0
      while i < cleaned.size
        v = cleaned[i, 2].to_u8?(16)
        return "#{cleaned[i, 2].inspect} is not a hex byte" unless v
        buf[i // 2] = v
        i += 2
      end
      buf
    end

    def hex_text(data : Bytes) : String
      data.map(&.to_s(16).rjust(2, '0')).join(' ')
    end

    # --- primitives -----------------------------------------------------------

    private def length_delimited(number : UInt32, payload : Bytes) : Bytes
      io = IO::Memory.new(payload.size + 10)
      write_tag(io, number, Protobuf::WireType::LengthDelimited)
      write_varint(io, payload.size.to_u64)
      io.write(payload)
      io.to_slice
    end

    private def write_tag(io : IO, number : UInt32, wire : Protobuf::WireType) : Nil
      write_varint(io, (number.to_u64 << 3) | wire.value.to_u64)
    end

    private def write_varint(io : IO, value : UInt64) : Nil
      v = value
      while v > 0x7f_u64
        io.write_byte(((v & 0x7f_u64) | 0x80_u64).to_u8)
        v >>= 7
      end
      io.write_byte(v.to_u8)
    end

    private def varint_bytes(value : UInt64) : Bytes
      io = IO::Memory.new(10)
      write_varint(io, value)
      io.to_slice
    end

    private def bytes32(value : UInt32) : Bytes
      buf = Bytes.new(4)
      IO::ByteFormat::LittleEndian.encode(value, buf)
      buf
    end

    private def bytes64(value : UInt64) : Bytes
      buf = Bytes.new(8)
      IO::ByteFormat::LittleEndian.encode(value, buf)
      buf
    end
  end
end
