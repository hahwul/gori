require "./spec_helper"
require "./support/demo_descriptor"
require "base64"

private alias PB = Gori::Protobuf
private alias Schema = Gori::Protobuf::Schema
private alias Lens = Gori::Protobuf::Lens
private alias Encoder = Gori::Protobuf::Encoder

# A declaration with no descriptor set behind it — the encoder takes a `FieldDef`, and every
# scalar type has to round-trip whether or not `demo.proto` happens to use it.
private def defn(number : Int32, type : Schema::FieldType, *,
                 repeated = false, type_name : String? = nil) : Schema::FieldDef
  Schema::FieldDef.new(number.to_u32, "f#{number}", type, type_name, repeated)
end

# One field, encoded from text, decoded straight back through the LENS — so the assertion is
# against the reader #823 validated against a reference encoder, not against this spec's own
# idea of the wire format.
private def round_trip(d : Schema::FieldDef, text : String, schema : Schema? = nil,
                       packed = false) : Lens::Reading
  s = schema || Schema.new
  bytes = Encoder.encode(s, d, text, packed: packed)
  bytes.should be_a(Bytes)
  msg = PB.decode(bytes.as(Bytes))
  msg.complete.should be_true
  msg.fields.size.should eq(1)
  type = Schema::MessageType.new("T", {d.number => d})
  Lens.read(s, type, msg.fields[0]).not_nil!
end

describe Gori::Protobuf do
  describe ".field_spans" do
    it "returns one span per decoded field, in the same order" do
      data = Base64.decode(DEMO_USER_B64)
      spans = PB.field_spans(data)
      fields = PB.decode(data).fields
      spans.size.should eq(fields.size)
      spans.zip(fields) do |s, f|
        s.number.should eq(f.number)
        s.wire.should eq(f.wire)
      end
    end

    it "spans cover the message end to end with no gaps" do
      data = Base64.decode(DEMO_USER_B64)
      pos = 0
      PB.field_spans(data).each do |s|
        s.start.should eq(pos)
        pos = s.finish
      end
      pos.should eq(data.size)
    end

    it "points a length-delimited span's body past its length varint" do
      # field 2, `name` — "hahwul" behind a one-byte length.
      data = Base64.decode(DEMO_USER_B64)
      s = PB.field_spans(data).find { |x| x.number == 2 }.not_nil!
      String.new(data[s.body, s.body_size]).should eq("hahwul")
      data[s.start, s.value - s.start].should eq(Bytes[0x12]) # the tag, one byte
    end

    it "stops where the decoder stops on a truncated message" do
      # A clean varint field, then a length prefix claiming more than arrived.
      data = Bytes[0x08, 0x01, 0x12, 0x40, 0x41]
      msg = PB.decode(data)
      msg.complete.should be_false
      msg.fields.size.should eq(1)
      PB.field_spans(data).size.should eq(1)
    end

    it "stops on a lone end-group tag, exactly as the decoder does" do
      data = Bytes[0x08, 0x01, 0x0C] # field 1 = 1, then end-group for field 1
      PB.decode(data).fields.size.should eq(1)
      PB.field_spans(data).size.should eq(1)
    end

    it "agrees with the decoder on hostile input" do
      # Every prefix of the reference message: each one is a different truncation point, and
      # the two walks must give up at the same field on all of them.
      full = Base64.decode(DEMO_USER_B64)
      (0..full.size).each do |n|
        slice = full[0, n]
        PB.field_spans(slice).size.should eq(PB.decode(slice).fields.size)
      end
    end
  end
end

describe Gori::Protobuf::Encoder do
  describe "every scalar type" do
    it "round-trips int32, including a negative (sign-extended, not truncated)" do
      round_trip(defn(1, Schema::FieldType::Int32), "-7").value.should eq(-7_i64)
      round_trip(defn(1, Schema::FieldType::Int32), "2147483647").value.should eq(2147483647_i64)
      # The sign extension is the point: an int32 -1 is ten bytes on the wire, and a
      # four-byte encoding reads back as 4294967295.
      enc = Encoder.encode(Schema.new, defn(1, Schema::FieldType::Int32), "-1", packed: false).as(Bytes)
      enc.size.should eq(11)
    end

    it "round-trips int64" do
      round_trip(defn(2, Schema::FieldType::Int64), "-9223372036854775808").value
        .should eq(Int64::MIN)
      round_trip(defn(2, Schema::FieldType::Int64), "9223372036854775807").value
        .should eq(Int64::MAX)
    end

    it "round-trips uint32 and uint64" do
      round_trip(defn(3, Schema::FieldType::UInt32), "4294967295").value.should eq(4294967295_u64)
      round_trip(defn(4, Schema::FieldType::UInt64), "18446744073709551615").value
        .should eq(UInt64::MAX)
    end

    it "round-trips sint32/sint64 through zigzag" do
      round_trip(defn(5, Schema::FieldType::SInt32), "-3").value.should eq(-3_i64)
      round_trip(defn(6, Schema::FieldType::SInt64), "-9223372036854775808").value
        .should eq(Int64::MIN)
      # zigzag is what keeps a small negative one byte instead of ten.
      Encoder.encode(Schema.new, defn(5, Schema::FieldType::SInt32), "-1", packed: false)
        .as(Bytes).should eq(Bytes[0x28, 0x01])
    end

    it "round-trips fixed32/fixed64 and sfixed32/sfixed64" do
      round_trip(defn(7, Schema::FieldType::Fixed32), "4294967295").value.should eq(4294967295_u64)
      round_trip(defn(8, Schema::FieldType::Fixed64), "18446744073709551615").value
        .should eq(UInt64::MAX)
      round_trip(defn(9, Schema::FieldType::SFixed32), "-2147483648").value.should eq(-2147483648_i64)
      round_trip(defn(10, Schema::FieldType::SFixed64), "-1").value.should eq(-1_i64)
    end

    it "round-trips float and double" do
      round_trip(defn(11, Schema::FieldType::Float), "1.5").value.should eq(1.5_f32)
      round_trip(defn(12, Schema::FieldType::Double), "0.5").value.should eq(0.5)
      round_trip(defn(12, Schema::FieldType::Double), "-inf").value.should eq(-Float64::INFINITY)
    end

    it "round-trips bool from both spellings" do
      round_trip(defn(13, Schema::FieldType::Bool), "true").value.should be_true
      round_trip(defn(13, Schema::FieldType::Bool), "0").value.should be_false
    end

    it "round-trips string and bytes" do
      round_trip(defn(14, Schema::FieldType::String), "hahwul").value.should eq("hahwul")
      r = round_trip(defn(15, Schema::FieldType::Bytes), "de ad be ef")
      r.defn.type.bytes?.should be_true
      Encoder.encode(Schema.new, defn(15, Schema::FieldType::Bytes), "deadbeef", packed: false)
        .as(Bytes).should eq(Bytes[0x7A, 0x04, 0xDE, 0xAD, 0xBE, 0xEF])
    end

    it "round-trips an enum by NAME and by number" do
      s = demo_schema
      d = s.message?("demo.User").not_nil!.field?(3_u32).not_nil!
      round_trip(d, "ROLE_ADMIN", s).value.should eq(2_i64)
      round_trip(d, "ROLE_ADMIN", s).enum_name.should eq("ROLE_ADMIN")
      # A number the enum does not declare is accepted — sending a value the API never named
      # is a thing an operator does on purpose, and the lens reports it as a schema gap.
      r = round_trip(d, "99", s)
      r.value.should eq(99_i64)
      r.note.not_nil!.should contain("has no name")
    end

    it "round-trips a packed repeated scalar" do
      d = defn(6, Schema::FieldType::Int32, repeated: true)
      r = round_trip(d, "1, 2, 300", packed: true)
      r.packed.should eq([1_i64, 2_i64, 300_i64])
      # Whitespace-separated too — a run pasted out of another tool.
      round_trip(d, "1 2 300", packed: true).packed.should eq([1_i64, 2_i64, 300_i64])
    end

    it "keeps an UNPACKED repeated occurrence unpacked" do
      # `packed: false` on a repeated field re-emits ONE element with the scalar wire type —
      # the shape the wire had. Inventing a packed run here would change how a proto2 peer
      # reads the field.
      d = defn(6, Schema::FieldType::Int32, repeated: true)
      Encoder.encode(Schema.new, d, "7", packed: false).as(Bytes).should eq(Bytes[0x30, 0x07])
    end
  end

  describe ".seed" do
    it "gives back the text that re-encodes the captured bytes, for every declared field" do
      s = demo_schema
      type = s.message?("demo.User").not_nil!
      data = Base64.decode(DEMO_USER_B64)
      msg = PB.decode(data)
      seen = 0
      msg.fields.each_with_index do |f, i|
        r = Lens.read(s, type, f).not_nil!
        d = r.defn
        seed = Encoder.seed(d, f, r)
        next if seed.nil? # the two message fields — edited through their own rows
        packed = f.wire.length_delimited? && d.repeated && d.type.packable?
        encoded = Encoder.encode(s, d, seed, packed: packed).as(Bytes)
        # The whole property: re-encoding a field from its own seed reproduces the capture
        # byte for byte, so a rebuild with no edit is the input slice.
        Encoder.replace(data, [i], encoded).should eq(data)
        seen += 1
      end
      seen.should eq(10)
    end

    it "refuses to seed a packed run that ended mid-element" do
      # `read_packed` reports this one as a NOTE with `packed_more` still 0, so counting only
      # the omitted elements let a truncated run seed as its decodable prefix — and applying
      # it unchanged then dropped the leftover octets off a deliberately-malformed capture.
      d = defn(5, Schema::FieldType::Int32, repeated: true)
      f = PB::Field.new(5_u32, PB::WireType::LengthDelimited, bytes: Bytes[0x01, 0x02, 0xFF])
      r = Lens.read(Schema.new, Schema::MessageType.new("T", {5_u32 => d}), f).not_nil!
      r.packed.should eq([1_i64, 2_i64])
      r.packed_more.should eq(0)
      r.note.not_nil!.should contain("ends mid-element")
      Encoder.seed(d, f, r).should be_nil
    end

    it "refuses to seed a string carrying a control byte" do
      # The ROW escapes it (`"a\nb"`); a terminal cell paints a control char as a space. An
      # operator retyping what they see would turn 0x0A into 0x20 with nothing saying so.
      d = defn(1, Schema::FieldType::String)
      f = PB::Field.new(1_u32, PB::WireType::LengthDelimited,
        bytes: "a\nb".to_slice, string: "a\nb")
      r = Lens.read(Schema.new, Schema::MessageType.new("T", {1_u32 => d}), f).not_nil!
      r.value.should eq("a\nb")
      Encoder.seed(d, f, r).should be_nil
      # An ordinary string is unaffected.
      g = PB::Field.new(1_u32, PB::WireType::LengthDelimited, bytes: "ok".to_slice, string: "ok")
      Encoder.seed(d, g, Lens.read(Schema.new, Schema::MessageType.new("T", {1_u32 => d}), g).not_nil!)
        .should eq("ok")
    end

    it "refuses to seed a packed run longer than the lens lists" do
      # A seed built from a truncated element list would DROP the rest on apply. nil keeps
      # the row read-only instead.
      d = defn(1, Schema::FieldType::Int32, repeated: true)
      payload = Bytes.new(Lens::PACKED_MAX + 8, 1_u8) # one-byte varints, all `1`
      f = PB::Field.new(1_u32, PB::WireType::LengthDelimited, bytes: payload)
      r = Lens.read(demo_schema, Schema::MessageType.new("T", {1_u32 => d}), f).not_nil!
      r.packed_more.should be > 0
      Encoder.seed(d, f, r).should be_nil
    end
  end

  describe ".replace" do
    it "changes the edited field and copies every other byte verbatim" do
      s = demo_schema
      type = s.message?("demo.User").not_nil!
      data = Base64.decode(DEMO_USER_B64)
      d = type.field?(2_u32).not_nil! # name
      encoded = Encoder.encode(s, d, "admin", packed: false).as(Bytes)
      res = Encoder.replace(data, [1], encoded).as(Bytes)
      spans = PB.field_spans(data)
      res[0, spans[1].start].should eq(data[0, spans[1].start]) # everything before
      res[spans[1].start + encoded.size..].should eq(data[spans[1].finish..])
      msg = PB.decode(res)
      Lens.read(s, type, msg.fields[1]).not_nil!.value.should eq("admin")
      Lens.read(s, type, msg.fields[0]).not_nil!.value.should eq(-7_i64) # untouched
    end

    it "replaces a NESTED field and re-measures only its container's length" do
      s = demo_schema
      data = Base64.decode(DEMO_USER_B64)
      profile = s.message?("demo.Profile").not_nil!
      d = profile.field?(1_u32).not_nil! # age
      encoded = Encoder.encode(s, d, "31", packed: false).as(Bytes)
      res = Encoder.replace(data, [3, 0], encoded).as(Bytes)
      msg = PB.decode(res)
      inner = msg.fields[3].message.not_nil!
      Lens.read(s, profile, inner.fields[0]).not_nil!.value.should eq(31_i64)
      # `tags` — the sibling inside the same nested message — is copied, not re-encoded.
      inner.fields[1].string.should eq("red")
      msg.fields[1].string.should eq("hahwul") # and so is the whole rest of the message
    end

    it "descends two levels" do
      s = demo_schema
      data = Base64.decode(DEMO_USER_B64)
      d = s.message?("demo.Outer.Inner").not_nil!.field?(1_u32).not_nil!
      encoded = Encoder.encode(s, d, "DEEPER", packed: false).as(Bytes)
      res = Encoder.replace(data, [11, 0, 0], encoded).as(Bytes)
      outer = PB.decode(res).fields[11].message.not_nil!
      outer.fields[0].message.not_nil!.fields[0].string.should eq("DEEPER")
      outer.fields[1].uint.should eq(1_u64) # `kind`, untouched
    end

    it "carries an UNDECLARED field and a schema/wire disagreement through an edit untouched" do
      # field 1 = int64 id (declared), field 3 = the enum arriving as a STRING (a
      # disagreement), field 77 = a number `demo.User` does not declare at all.
      io = IO::Memory.new
      io.write(Bytes[0x08, 0x2A])                   # 1: varint 42
      io.write(Bytes[0x1A, 0x03, 0x61, 0x62, 0x63]) # 3: "abc" — wrong wire type for Role
      io.write(Bytes[0xE8, 0x04, 0x07])             # 77: varint 7 — undeclared
      data = io.to_slice
      s = demo_schema
      type = s.message?("demo.User").not_nil!
      d = type.field?(1_u32).not_nil!
      encoded = Encoder.encode(s, d, "99", packed: false).as(Bytes)
      res = Encoder.replace(data, [0], encoded).as(Bytes)
      res[2..].should eq(data[2..]) # the disagreeing field and the undeclared one, byte for byte
      msg = PB.decode(res)
      Lens.read(s, type, msg.fields[0]).not_nil!.value.should eq(99_i64)
      Lens.read(s, type, msg.fields[1]).not_nil!.disagrees.should be_true
      Lens.read(s, type, msg.fields[2]).should be_nil # still undeclared, still there
    end

    it "keeps the unparsed tail of a truncated message" do
      # Two clean fields plus a length prefix claiming more than arrived. The decoder stops
      # at the tail; the rebuild must not delete it.
      data = Bytes[0x08, 0x01, 0x10, 0x02, 0x1A, 0x40, 0x41]
      d = defn(1, Schema::FieldType::Int32)
      encoded = Encoder.encode(Schema.new, d, "9", packed: false).as(Bytes)
      res = Encoder.replace(data, [0], encoded).as(Bytes)
      res.should eq(Bytes[0x08, 0x09, 0x10, 0x02, 0x1A, 0x40, 0x41])
    end

    it "refuses an index the message no longer has" do
      Encoder.replace(Bytes[0x08, 0x01], [4], Bytes[0x08, 0x02]).should be_a(String)
      empty = [] of Int32
      Encoder.replace(Bytes[0x08, 0x01], empty, Bytes[0x08, 0x02]).should be_a(String)
    end

    it "refuses to descend into a field that is not length-delimited" do
      Encoder.replace(Bytes[0x08, 0x01], [0, 0], Bytes[0x08, 0x02]).should be_a(String)
    end
  end

  describe "refusals" do
    it "names what the text is not, rather than raising" do
      s = Schema.new
      Encoder.encode(s, defn(1, Schema::FieldType::Int32), "abc", packed: false)
        .should eq(%("abc" is not an integer))
      Encoder.encode(s, defn(1, Schema::FieldType::Int32), "5000000000", packed: false)
        .as(String).should contain("does not fit int32")
      Encoder.encode(s, defn(1, Schema::FieldType::UInt32), "-1", packed: false)
        .as(String).should contain("not a non-negative integer")
      Encoder.encode(s, defn(1, Schema::FieldType::Bool), "maybe", packed: false)
        .as(String).should contain("is not a bool")
      Encoder.encode(s, defn(1, Schema::FieldType::Bytes), "de ad b", packed: false)
        .as(String).should contain("even number of digits")
      Encoder.encode(s, defn(1, Schema::FieldType::Bytes), "zz", packed: false)
        .as(String).should contain("not a hex byte")
      # A float past Float32's range SATURATES on an unchecked cast; the checked one would
      # raise, in a module whose contract is a sentence back.
      Encoder.encode(s, defn(1, Schema::FieldType::Float), "1e60", packed: false)
        .as(String).should contain("does not fit a float")
      Encoder.encode(s, defn(1, Schema::FieldType::Message, type_name: "demo.Profile"), "x", packed: false)
        .as(String).should contain("edit the fields inside it")
    end

    it "names the enum's own values when a name does not resolve" do
      s = demo_schema
      d = s.message?("demo.User").not_nil!.field?(3_u32).not_nil!
      msg = Encoder.encode(s, d, "ROLE_ROOT", packed: false).as(String)
      msg.should contain("demo.Role")
      msg.should contain("ROLE_ADMIN")
    end

    it "reports which element of a packed run failed" do
      d = defn(1, Schema::FieldType::Int32, repeated: true)
      Encoder.encode(Schema.new, d, "1, 2, nope", packed: true)
        .as(String).should contain("element 3")
    end

    it "stops a packed edit far past what the field is for" do
      d = defn(1, Schema::FieldType::Int32, repeated: true)
      text = Array.new(Encoder::MAX_PACKED + 1, "1").join(",")
      Encoder.encode(Schema.new, d, text, packed: true).as(String).should contain("more than")
    end
  end
end
