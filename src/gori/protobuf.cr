require "json"
require "base64"

module Gori
  # Schema-less protobuf wire-format decoder. A pure byte parser over a `Bytes`
  # slice (no I/O): every field carries its number and wire type, length-delimited
  # fields are probed as nested messages when the bytes parse cleanly, and
  # varints / fixed32 / fixed64 render as numbers. Companion to the gRPC framer
  # in `proxy/h2/grpc.cr` — framing splits the length-prefixed messages; this
  # decodes each message body.
  #
  # Ambiguity is normal without a `.proto`. A length-delimited field that parses
  # as both a nested message and a valid UTF-8 string reports **both** (and
  # always the raw bytes) rather than picking a winner. Guessing is the failure
  # class this decoder is written to avoid.
  #
  # Never raises on hostile / truncated input (P7): partial fields are returned
  # with `complete: false`. Recursion and field counts are bounded.
  module Protobuf
    extend self

    # Nesting ceiling. Hostile input is the normal case for a proxy; a crafted
    # length-delimited chain must not blow the fiber stack.
    MAX_DEPTH = 32

    # Per-message field ceiling so a pathological stream of tiny tags can't
    # allocate unbounded Field arrays. Far above any realistic message.
    MAX_FIELDS = 100_000

    # A tag's field-number half must fit here. UInt32::MAX rather than the spec's 2^29-1
    # because the job is the P7 contract, not conformance: past this the `to_u32` that turns
    # a tag into a field number RAISES, which is the one thing this module promises not to do.
    # A tag varint that wide is corrupt either way and takes the corrupt-tag exit.
    MAX_FIELD_NUMBER = UInt32::MAX.to_u64

    # Wire types from the protobuf encoding (https://protobuf.dev/programming-guides/encoding/).
    # Groups (3/4) are long-deprecated; we skip them rather than surface a tree.
    enum WireType : UInt8
      Varint          = 0
      Fixed64         = 1
      LengthDelimited = 2
      StartGroup      = 3
      EndGroup        = 4
      Fixed32         = 5
    end

    # One decoded message. `complete` is false when the input was truncated
    # mid-field, a length overran the buffer, an illegal wire type appeared, or
    # a bound was hit — partial `fields` are still returned so the operator sees
    # what decoded (P7: the octets stay reachable even when the parse can't).
    record Message, fields : Array(Field), complete : Bool do
      # JSON projection used by `gori run show --format json` (and anything else
      # that wants the same tree). Length-delimited fields emit every applicable
      # interpretation as sibling keys — never a single chosen type.
      def to_json(j : JSON::Builder) : Nil
        j.object do
          j.field "complete", complete
          j.field "fields" do
            j.array { fields.each &.to_json(j) }
          end
        end
      end
    end

    # One field occurrence on the wire. Scalar fields set `uint` (and for
    # fixed32/fixed64, that value is the raw bits). Length-delimited fields set
    # `bytes` always, plus `string` when the payload is valid UTF-8, plus
    # `message` when the payload parses cleanly as a nested message — any
    # combination may be present together. `skipped` marks a deprecated group
    # whose interior was consumed but not decoded.
    record Field,
      number : UInt32,
      wire : WireType,
      uint : UInt64? = nil,
      bytes : Bytes? = nil,
      string : String? = nil,
      message : Message? = nil,
      skipped : Bool = false do
      def to_json(j : JSON::Builder) : Nil
        j.object do
          j.field "number", number.to_i64
          j.field "wire", wire_name
          if u = uint
            # JSON numbers are IEEE doubles; keep integers above 2^53-1 exact by
            # falling back to a decimal string (UInt64 can exceed Int64::MAX too).
            if u <= 9_007_199_254_740_991_u64 # 2^53 - 1
              j.field "uint", u.to_i64
            else
              j.field "uint", u.to_s
            end
          end
          if b = bytes
            j.field "bytes", Base64.strict_encode(b)
            j.field "size", b.size
          end
          j.field "string", string if string
          if m = message
            j.field "message" { m.to_json(j) }
          end
          j.field "skipped", true if skipped
        end
      end

      private def wire_name : String
        case wire
        in .varint?           then "varint"
        in .fixed64?          then "fixed64"
        in .length_delimited? then "len"
        in .start_group?      then "group"
        in .end_group?        then "end_group"
        in .fixed32?          then "fixed32"
        end
      end
    end

    # Decode a protobuf message body. Empty input is a complete empty message.
    # Never raises.
    def decode(data : Bytes, *, max_depth : Int32 = MAX_DEPTH) : Message
      parse_message(data, 0, max_depth)
    end

    # True when `data` parses cleanly as a protobuf message: every byte is
    # consumed, no illegal wire type, no truncated field, depth/field bounds held.
    # Used as the nested-message probe for length-delimited fields — a clean parse
    # is necessary but not exclusive of a string interpretation of the same bytes.
    def message?(data : Bytes, *, max_depth : Int32 = MAX_DEPTH) : Bool
      m = parse_message(data, 0, max_depth)
      m.complete
    end

    # --- parser -------------------------------------------------------------

    private def parse_message(data : Bytes, depth : Int32, max_depth : Int32) : Message
      return Message.new([] of Field, false) if depth > max_depth
      fields = [] of Field
      pos = 0
      complete = true

      while pos < data.size
        if fields.size >= MAX_FIELDS
          complete = false
          break
        end

        tag, pos, ok = read_varint(data, pos)
        unless ok
          complete = false
          break
        end
        # Range-checked BEFORE the conversion: a tag varint of 2^35 or more (six bytes of
        # `ff ff ff ff ff 1f` is enough) makes `to_u32` RAISE `OverflowError`, in a module
        # whose contract is "never raises on hostile / truncated input" — and it is reached
        # through the nested-message probe too, so the bytes need only sit inside a
        # length-delimited field. A field number that wide is not a legal protobuf tag anyway,
        # so it is corrupt input and takes the same exit every other corrupt tag does.
        wide = (tag >> 3) > MAX_FIELD_NUMBER
        wt = WireType.from_value?((tag & 0x7).to_u8)
        if wide || wt.nil?
          complete = false
          break
        end
        number = (tag >> 3).to_u32

        # Lone end-group at message level is not a clean message (groups must be
        # opened first). Hard-stop so a nested probe rejects the payload.
        if wt.end_group?
          complete = false
          break
        end

        field, pos, ok = read_field(data, pos, number, wt, depth, max_depth)
        unless ok
          complete = false
          break
        end
        fields << field if field
      end

      Message.new(fields, complete)
    end

    # Read one field's payload after its tag. Returns {field?, new_pos, ok}.
    # `field` is nil only when ok is false (caller discards it).
    private def read_field(data : Bytes, pos : Int32, number : UInt32, wt : WireType,
                           depth : Int32, max_depth : Int32) : {Field?, Int32, Bool}
      case wt
      in .varint?
        value, pos, ok = read_varint(data, pos)
        return {nil, pos, false} unless ok
        {Field.new(number, wt, uint: value), pos, true}
      in .fixed64?
        value, pos, ok = read_fixed64(data, pos)
        return {nil, pos, false} unless ok
        {Field.new(number, wt, uint: value), pos, true}
      in .fixed32?
        value, pos, ok = read_fixed32(data, pos)
        return {nil, pos, false} unless ok
        {Field.new(number, wt, uint: value.to_u64), pos, true}
      in .length_delimited?
        payload, pos, ok = read_length_payload(data, pos)
        return {nil, pos, false} unless ok
        {length_field(number, payload, depth, max_depth), pos, true}
      in .start_group?
        # Deprecated group: consume until the matching end-group tag, don't
        # surface the interior as a nested tree.
        pos, ok = skip_group(data, pos, number)
        return {nil, pos, false} unless ok
        {Field.new(number, WireType::StartGroup, skipped: true), pos, true}
      in .end_group?
        {nil, pos, false}
      end
    end

    # Length-delimited payload: varint length + that many bytes. Rejects a
    # length that would wrap or over-read the remaining buffer.
    private def read_length_payload(data : Bytes, pos : Int32) : {Bytes, Int32, Bool}
      len_u, pos, ok = read_varint(data, pos)
      return {Bytes.empty, pos, false} unless ok
      return {Bytes.empty, pos, false} if len_u > Int32::MAX.to_u64
      len = len_u.to_i32
      return {Bytes.empty, pos, false} if pos.to_i64 + len.to_i64 > data.size
      payload = data[pos, len]
      {payload, pos + len, true}
    end

    # Build a length-delimited field: always keep the raw bytes; add `string`
    # when valid UTF-8; add `message` when the payload parses cleanly as nested
    # protobuf. All three may coexist — that is the ambiguity report.
    private def length_field(number : UInt32, payload : Bytes, depth : Int32, max_depth : Int32) : Field
      str = utf8_string?(payload)
      nested = nested_message?(payload, depth, max_depth)
      Field.new(number, WireType::LengthDelimited, bytes: payload, string: str, message: nested)
    end

    # Nested-message probe. Empty payload is a clean empty message. Depth is
    # checked before recursing so a chain of empty length-delimited fields can't
    # recurse past the ceiling either.
    private def nested_message?(payload : Bytes, depth : Int32, max_depth : Int32) : Message?
      return nil if depth + 1 > max_depth
      m = parse_message(payload, depth + 1, max_depth)
      m.complete ? m : nil
    end

    # Valid UTF-8 only — no "printable" filter. Control bytes are legal UTF-8
    # and often meaningful (e.g. nested protobuf that also happens to be text).
    # Empty payload is a valid empty string.
    private def utf8_string?(payload : Bytes) : String?
      s = String.new(payload)
      s.valid_encoding? ? s : nil
    end

    # Skip a group opened by field `number` until its end-group tag. Nested
    # start-groups of any field number nest the skip depth; only the matching
    # end-group for `number` at depth 0 closes this group. Length/varint/fixed
    # fields inside are skipped without decoding. Never raises.
    private def skip_group(data : Bytes, pos : Int32, number : UInt32) : {Int32, Bool}
      depth = 1
      while depth > 0 && pos < data.size
        tag, pos, ok = read_varint(data, pos)
        return {pos, false} unless ok
        return {pos, false} if (tag >> 3) > MAX_FIELD_NUMBER # see `decode`: `to_u32` RAISES past 2^35
        field = (tag >> 3).to_u32
        wt = WireType.from_value?((tag & 0x7).to_u8) || return {pos, false}
        case wt
        in .start_group?
          depth += 1
        in .end_group?
          # End-group for a different field number mid-group is corrupt.
          return {pos, false} if depth == 1 && field != number
          depth -= 1
        in .varint?, .fixed64?, .fixed32?, .length_delimited?
          pos, ok = skip_value(data, pos, wt)
          return {pos, false} unless ok
        end
      end
      {pos, depth == 0}
    end

    # Advance past one scalar / length-delimited value (no field record).
    private def skip_value(data : Bytes, pos : Int32, wt : WireType) : {Int32, Bool}
      case wt
      in .varint?
        _, pos, ok = read_varint(data, pos)
        {pos, ok}
      in .fixed64?
        return {pos, false} if pos + 8 > data.size
        {pos + 8, true}
      in .fixed32?
        return {pos, false} if pos + 4 > data.size
        {pos + 4, true}
      in .length_delimited?
        _, pos, ok = read_length_payload(data, pos)
        {pos, ok}
      in .start_group?, .end_group?
        {pos, false}
      end
    end

    # Read a protobuf varint. Up to 10 bytes (64-bit value + overflow nibble).
    # Returns {value, new_pos, ok}.
    private def read_varint(data : Bytes, pos : Int32) : {UInt64, Int32, Bool}
      value = 0_u64
      shift = 0
      10.times do
        return {0_u64, pos, false} if pos >= data.size
        b = data[pos]
        pos += 1
        value |= (b.to_u64 & 0x7f_u64) << shift
        return {value, pos, true} if (b & 0x80) == 0
        shift += 7
      end
      # 10th byte still had continuation bit, or value overflowed 64 bits.
      {0_u64, pos, false}
    end

    private def read_fixed64(data : Bytes, pos : Int32) : {UInt64, Int32, Bool}
      return {0_u64, pos, false} if pos + 8 > data.size
      value = IO::ByteFormat::LittleEndian.decode(UInt64, data[pos, 8])
      {value, pos + 8, true}
    end

    private def read_fixed32(data : Bytes, pos : Int32) : {UInt32, Int32, Bool}
      return {0_u32, pos, false} if pos + 4 > data.size
      value = IO::ByteFormat::LittleEndian.decode(UInt32, data[pos, 4])
      {value, pos + 4, true}
    end
  end
end
