require "base64"
require "./schema"

module Gori::Protobuf
  # Reads ONE wire field through ONE `.proto` declaration — the whole schema-aware half of
  # #823, in the one place all four gRPC surfaces (History, the Repeater transcript,
  # `gori run show --format json`, MCP `get_flow`) can share.
  #
  # ## A lens, not a replacement (P7)
  #
  # Nothing here re-decodes the message. `Protobuf` already turned the octets into fields;
  # this decides what ONE declaration says a given field means, and — just as importantly —
  # when it says something the wire contradicts. Three outcomes, all of them visible:
  #
  #   * the declaration fits    → a named, typed reading (`value` / `packed` / `nested`)
  #   * the wire contradicts it → `disagrees`, and the caller falls back to the raw rendering
  #   * the schema is short     → `note` (an enum or message type the loaded set lacks)
  #
  # A field number the message does not declare gets no Reading at all (`read` returns nil),
  # and the caller renders it exactly as it does with no schema loaded. Unknown fields are
  # never hidden: the ability to see a field the API's own `.proto` forgot is a large part of
  # why an operator is reading the wire in the first place.
  module Lens
    extend self

    # What one field can decode to. The union is deliberate: the TUI wants text and JSON
    # wants a typed literal, and both would rather not re-derive the type from a string.
    # `Float32` stays itself so a `float` field prints `0.1` rather than the `Float64`
    # widening's honest-but-unreadable `0.10000000149011612`.
    alias Scalar = Int64 | UInt64 | Float64 | Float32 | Bool | String

    # Elements decoded out of one packed run before the rest is counted instead. A packed
    # `repeated int32` can legally hold hundreds of thousands of entries; neither a pane nor
    # an LLM client's context wants them all, and a silent cut would be the worse lie.
    PACKED_MAX = 512

    # Nesting levels the JSON projection descends. The wire decoder's own MAX_DEPTH bounds
    # the PARSE; this bounds the ANNOTATION, which is a different (much smaller) budget.
    JSON_MAX_DEPTH = 12

    # One wire field read through its declaration. At most one of `value` / `packed` /
    # `nested` is set; a `bytes` field sets none of them (its octets are the reading, and the
    # caller already has them).
    record Reading,
      defn : Schema::FieldDef,
      value : Scalar? = nil,
      enum_name : String? = nil,
      packed : Array(Scalar)? = nil,
      packed_more : Int32 = 0,
      nested : Schema::MessageType? = nil,
      note : String? = nil,
      disagrees : Bool = false

    # The declaration for `f` in `type`, applied. nil when `type` does not declare this field
    # number — the caller then renders the field from the wire, unchanged.
    def read(schema : Schema, type : Schema::MessageType, f : Protobuf::Field) : Reading?
      d = type.field?(f.number) || return nil
      case f.wire
      in .varint?           then read_varint_field(schema, d, f)
      in .fixed64?          then read_fixed64_field(d, f)
      in .fixed32?          then read_fixed32_field(d, f)
      in .length_delimited? then read_length_field(schema, d, f)
      in .start_group?      then read_group_field(d)
      in .end_group?        then Reading.new(d, note: conflict(d, "an end-group tag"), disagrees: true)
      end
    end

    # The sentence a disagreement gets. Names BOTH sides — what the schema declared and what
    # actually arrived — because either one can be the finding: a server that changed a field's
    # type without a new field number is a bug worth seeing, and so is a stale `.desc`.
    def conflict(d : Schema::FieldDef, arrived : String) : String
      "schema declares #{d.name} as #{d.type_label}, but the wire carries #{arrived}"
    end

    private def read_varint_field(schema : Schema, d : Schema::FieldDef,
                                  f : Protobuf::Field) : Reading
      u = f.uint || 0_u64
      case d.type
      when .int32?
        # int32 is sign-extended to 64 bits on the wire, so the low 32 bits reinterpreted
        # signed is the value — a truncation would turn -7 into 4294967289.
        Reading.new(d, value: u.to_u32!.to_i32!.to_i64)
      when .int64?   then Reading.new(d, value: u.to_i64!)
      when .u_int32? then Reading.new(d, value: u.to_u32!.to_u64)
      when .u_int64? then Reading.new(d, value: u)
      when .s_int32? then Reading.new(d, value: zigzag(u).to_i32!.to_i64)
      when .s_int64? then Reading.new(d, value: zigzag(u))
      when .bool?    then Reading.new(d, value: u != 0)
      when .enum?    then read_enum(schema, d, u)
      else                Reading.new(d, note: conflict(d, "a varint"), disagrees: true)
      end
    end

    # zigzag (sint32/sint64): the encoding that keeps a small negative number one byte
    # instead of ten. `(n >> 1) ^ -(n & 1)`.
    private def zigzag(u : UInt64) : Int64
      (u >> 1).to_i64! ^ -((u & 1).to_i64!)
    end

    private def read_enum(schema : Schema, d : Schema::FieldDef, u : UInt64) : Reading
      n = u.to_i64!
      e = d.type_name.try { |tn| schema.enum?(tn) }
      name = e.try(&.name?(n))
      note = if e.nil?
               "enum #{d.type_name} is not in the loaded schema"
             elsif name.nil?
               # NOT a disagreement: proto3 requires parsers to keep an unrecognised enum
               # value, and a value the client has never heard of is ordinary API drift —
               # and occasionally the interesting part of a response.
               "#{n} has no name in #{e.full_name}"
             end
      Reading.new(d, value: n, enum_name: name, note: note)
    end

    private def read_fixed64_field(d : Schema::FieldDef, f : Protobuf::Field) : Reading
      u = f.uint || 0_u64
      case d.type
      when .fixed64?   then Reading.new(d, value: u)
      when .s_fixed64? then Reading.new(d, value: u.to_i64!)
      when .double?    then Reading.new(d, value: u.unsafe_as(Float64))
      else                  Reading.new(d, note: conflict(d, "8 fixed bytes"), disagrees: true)
      end
    end

    private def read_fixed32_field(d : Schema::FieldDef, f : Protobuf::Field) : Reading
      u = (f.uint || 0_u64).to_u32!
      case d.type
      when .fixed32?   then Reading.new(d, value: u.to_u64)
      when .s_fixed32? then Reading.new(d, value: u.to_i32!.to_i64)
      when .float?     then Reading.new(d, value: u.unsafe_as(Float32))
      else                  Reading.new(d, note: conflict(d, "4 fixed bytes"), disagrees: true)
      end
    end

    private def read_length_field(schema : Schema, d : Schema::FieldDef,
                                  f : Protobuf::Field) : Reading
      case d.type
      when .string?
        if s = f.string
          Reading.new(d, value: s)
        else
          # A `string` field is UTF-8 by definition, so bytes that are not are a real
          # disagreement — and one of the classic gRPC test cases.
          Reading.new(d, note: "schema declares #{d.name} as string, but the bytes are not valid UTF-8",
            disagrees: true)
        end
      when .bytes?
        Reading.new(d) # the octets ARE the reading; the caller already holds them
      when .message?, .group?
        # Group is deprecated and its wire form is the 3/4 tag pair, but a producer that
        # encodes one length-delimited is carrying a message and reads as one here.
        t = d.type_name.try { |tn| schema.message?(tn) }
        t ? Reading.new(d, nested: t) : Reading.new(d, note: "#{d.type_name} is not in the loaded schema")
      else
        # A numeric/bool declaration arriving length-delimited is packed — legal for a
        # REPEATED field, and a type error for a singular one.
        if d.repeated && d.type.packable?
          read_packed(d, f.bytes || Bytes.empty)
        else
          Reading.new(d, note: conflict(d, "a length-delimited payload"), disagrees: true)
        end
      end
    end

    private def read_group_field(d : Schema::FieldDef) : Reading
      return Reading.new(d, note: "group wire type — the decoder does not descend into groups") if d.type.group?
      Reading.new(d, note: conflict(d, "a group"), disagrees: true)
    end

    # One packed run, element by element. A run that does not divide evenly (a truncated
    # capture, a hostile length) keeps the elements that decoded and says the rest did not —
    # the schema is not wrong here, the bytes are short, so this is a note and not a conflict.
    private def read_packed(d : Schema::FieldDef, data : Bytes) : Reading
      values = [] of Scalar
      more = 0
      pos = 0
      left = 0
      while pos < data.size
        start = pos
        value, pos, ok = read_packed_element(d, data, pos)
        unless ok
          left = data.size - start
          break
        end
        if values.size < PACKED_MAX
          values << value.not_nil!
        else
          more += 1
        end
      end
      note = left == 0 ? nil : "the packed run ends mid-element — #{left} byte#{left == 1 ? "" : "s"} left over"
      Reading.new(d, packed: values, packed_more: more, note: note)
    end

    private def read_packed_element(d : Schema::FieldDef, data : Bytes,
                                    pos : Int32) : {Scalar?, Int32, Bool}
      case d.type
      when .fixed32?, .s_fixed32?, .float?
        return {nil, pos, false} if pos + 4 > data.size
        u = IO::ByteFormat::LittleEndian.decode(UInt32, data[pos, 4])
        v = case d.type
            when .fixed32?   then u.to_u64.as(Scalar)
            when .s_fixed32? then u.to_i32!.to_i64.as(Scalar)
            else                  u.unsafe_as(Float32).as(Scalar)
            end
        {v, pos + 4, true}
      when .fixed64?, .s_fixed64?, .double?
        return {nil, pos, false} if pos + 8 > data.size
        u = IO::ByteFormat::LittleEndian.decode(UInt64, data[pos, 8])
        v = case d.type
            when .fixed64?   then u.as(Scalar)
            when .s_fixed64? then u.to_i64!.as(Scalar)
            else                  u.unsafe_as(Float64).as(Scalar)
            end
        {v, pos + 8, true}
      else
        u, pos, ok = read_varint(data, pos)
        return {nil, pos, false} unless ok
        v = case d.type
            when .int32?   then u.to_u32!.to_i32!.to_i64.as(Scalar)
            when .int64?   then u.to_i64!.as(Scalar)
            when .u_int32? then u.to_u32!.to_u64.as(Scalar)
            when .s_int32? then zigzag(u).to_i32!.to_i64.as(Scalar)
            when .s_int64? then zigzag(u).as(Scalar)
            when .bool?    then (u != 0).as(Scalar)
            else                u.as(Scalar) # uint64, and enum (rendered by number)
            end
        {v, pos, true}
      end
    end

    # A varint out of a packed run. `Protobuf`'s own reader is private to the decoder and
    # returns a decoder-shaped tuple; this is the same 10-byte rule, kept local so the
    # decoder's contract stays about MESSAGES.
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
      {0_u64, pos, false}
    end

    # --- JSON projection ----------------------------------------------------

    # The lens as JSON, emitted ALONGSIDE the schema-less tree the headless surfaces already
    # produce — never in place of it. That is P7 spelled out in the wire format an agent
    # reads: `protobuf` stays the authoritative octet-level report (every reading a payload
    # fits, none chosen), and this object is what one `.proto` says about the same bytes.
    # Because the raw tree sits right beside it, a disagreement or an unknown field only has
    # to be NAMED here — its octets are one key away.
    def emit_json(j : JSON::Builder, msg : Protobuf::Message, schema : Schema,
                  type : Schema::MessageType, depth : Int32 = 0) : Nil
      j.object do
        j.field "message", type.full_name
        j.field "fields" do
          j.array do
            msg.fields.each { |f| emit_field(j, f, schema, type, depth) }
          end
        end
        j.field "truncated", true unless msg.complete
      end
    end

    private def emit_field(j : JSON::Builder, f : Protobuf::Field, schema : Schema,
                           type : Schema::MessageType, depth : Int32) : Nil
      j.object do
        j.field "number", f.number.to_i64
        r = read(schema, type, f)
        unless r
          j.field "unknown", true
          j.field "wire", f.wire_name
          j.field("size", f.bytes.try(&.size) || 0) if f.wire.length_delimited?
          next
        end
        d = r.defn
        j.field "name", d.name
        j.field "type", d.type_label
        j.field "type_name", d.type_name if d.type_name
        if note = r.note
          j.field(r.disagrees ? "schema_mismatch" : "schema_note", note)
        end
        if r.disagrees
          j.field "wire", f.wire_name
          next
        end
        # `.nil?`, not truthiness: a `bool` field whose value is `false` is a reading like
        # any other, and `if v = r.value` would drop exactly half of them.
        unless (v = r.value).nil?
          j.field("value") { emit_scalar(j, v) }
          j.field "enum", r.enum_name if r.enum_name
        end
        if packed = r.packed
          j.field "values" do
            j.array { packed.each { |e| emit_scalar(j, e) } }
          end
          j.field "values_omitted", r.packed_more if r.packed_more > 0
        end
        if t = r.nested
          if depth + 1 >= JSON_MAX_DEPTH
            j.field "message_truncated", true
          else
            j.field "message" do
              emit_json(j, f.message || Protobuf.decode(f.bytes || Bytes.empty), schema, t, depth + 1)
            end
          end
        end
        j.field("size", f.bytes.try(&.size) || 0) if d.type.bytes?
      end
    end

    # JSON numbers are IEEE doubles, so an integer past 2^53-1 is emitted as a decimal
    # STRING rather than silently rounded — the same rule `Protobuf::Field#to_json` applies
    # to a raw varint, for the same reason.
    private def emit_scalar(j : JSON::Builder, v : Scalar) : Nil
      case v
      in String  then j.string v
      in Bool    then j.bool v
      in Float64 then v.finite? ? j.number(v) : j.string(v.to_s)
      in Float32 then v.finite? ? j.number(v) : j.string(v.to_s)
      in Int64
        # A comparison, not `abs`: `Int64::MIN.abs` RAISES (its magnitude has no Int64), and
        # this is fed straight off the wire.
        -9_007_199_254_740_991_i64 <= v <= 9_007_199_254_740_991_i64 ? j.number(v) : j.string(v.to_s)
      in UInt64
        v <= 9_007_199_254_740_991_u64 ? j.number(v) : j.string(v.to_s)
      end
    end
  end
end
