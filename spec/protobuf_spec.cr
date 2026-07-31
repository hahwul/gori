require "./spec_helper"
require "base64"
require "json"

private alias PB = Gori::Protobuf

# Encode a protobuf varint into `io`.
private def write_varint(io : IO, n : UInt64) : Nil
  while n > 0x7f_u64
    io.write_byte(((n & 0x7f_u64) | 0x80_u64).to_u8)
    n >>= 7
  end
  io.write_byte((n & 0x7f_u64).to_u8)
end

# Tag byte(s): (field_number << 3) | wire_type.
private def write_tag(io : IO, field : Int32, wire : Int32) : Nil
  write_varint(io, ((field << 3) | wire).to_u64)
end

# field N, wire type 0 (varint), value.
private def pb_varint(field : Int32, value : UInt64) : Bytes
  io = IO::Memory.new
  write_tag(io, field, 0)
  write_varint(io, value)
  io.to_slice
end

# field N, wire type 2 (length-delimited), raw payload.
private def pb_len(field : Int32, payload : Bytes | String) : Bytes
  data = payload.is_a?(String) ? payload.to_slice : payload
  io = IO::Memory.new
  write_tag(io, field, 2)
  write_varint(io, data.size.to_u64)
  io.write(data)
  io.to_slice
end

# field N, wire type 5 (fixed32), little-endian.
private def pb_fixed32(field : Int32, value : UInt32) : Bytes
  io = IO::Memory.new
  write_tag(io, field, 5)
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
  io.to_slice
end

# field N, wire type 1 (fixed64), little-endian.
private def pb_fixed64(field : Int32, value : UInt64) : Bytes
  io = IO::Memory.new
  write_tag(io, field, 1)
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
  io.to_slice
end

# Concatenate message fragments.
private def pb_join(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

describe Gori::Protobuf do
  describe ".decode" do
    it "returns a complete empty message for empty input" do
      m = PB.decode(Bytes.empty)
      m.complete.should be_true
      m.fields.should be_empty
    end

    it "decodes a varint field (int32/uint64 wire shape)" do
      # classic protobuf example: field 1 = 150 → 08 96 01
      m = PB.decode(Bytes[0x08, 0x96, 0x01])
      m.complete.should be_true
      m.fields.size.should eq(1)
      f = m.fields[0]
      f.number.should eq(1_u32)
      f.wire.should eq(PB::WireType::Varint)
      f.uint.should eq(150_u64)
    end

    it "decodes a length-delimited string field" do
      # field 2 = "testing" → 12 07 74 65 73 74 69 6e 67
      m = PB.decode(pb_len(2, "testing"))
      m.complete.should be_true
      f = m.fields[0]
      f.number.should eq(2_u32)
      f.wire.should eq(PB::WireType::LengthDelimited)
      f.string.should eq("testing")
      f.bytes.should eq("testing".to_slice)
      # A pure ASCII string does not parse cleanly as a nested message (lone
      # end-group / truncated varint mid-string), so message stays nil.
      f.message.should be_nil
    end

    it "decodes fixed32 and fixed64" do
      m = PB.decode(pb_join(pb_fixed32(3, 0x01020304_u32), pb_fixed64(4, 0x0102030405060708_u64)))
      m.complete.should be_true
      m.fields[0].wire.should eq(PB::WireType::Fixed32)
      m.fields[0].uint.should eq(0x01020304_u64)
      m.fields[1].wire.should eq(PB::WireType::Fixed64)
      m.fields[1].uint.should eq(0x0102030405060708_u64)
    end

    it "recurses into a nested message when the length-delimited payload parses cleanly" do
      # outer field 1 = message { field 1 = "alice"; field 2 = 42 }
      inner = pb_join(pb_len(1, "alice"), pb_varint(2, 42_u64))
      m = PB.decode(pb_len(1, inner))
      m.complete.should be_true
      outer = m.fields[0]
      outer.message.should_not be_nil
      nested = outer.message.not_nil!
      nested.complete.should be_true
      nested.fields.size.should eq(2)
      nested.fields[0].string.should eq("alice")
      nested.fields[1].uint.should eq(42_u64)
    end

    it "reports string AND message when a length-delimited field is both" do
      # Nested payload that is also valid UTF-8 text. The classic greeter shape
      # `field 1 = "alice"` is itself valid UTF-8 (tag + len + letters), so the
      # outer length-delimited field is ambiguous: nested message *and* string.
      inner = pb_len(1, "alice") # 0a 05 61 6c 69 63 65 — all printable UTF-8
      m = PB.decode(pb_len(2, inner))
      f = m.fields[0]
      f.message.should_not be_nil
      f.message.not_nil!.fields[0].string.should eq("alice")
      f.string.should_not be_nil
      f.string.not_nil!.should eq(String.new(inner))
      f.bytes.should eq(inner)
    end

    it "falls back to bytes (no string) for non-UTF-8 length-delimited payloads" do
      payload = Bytes[0xff, 0xfe, 0xfd]
      m = PB.decode(pb_len(1, payload))
      f = m.fields[0]
      f.bytes.should eq(payload)
      f.string.should be_nil
      f.message.should be_nil # 0xff is an illegal wire type on nested probe
    end

    it "surfaces repeated field numbers in wire order" do
      m = PB.decode(pb_join(pb_varint(1, 1_u64), pb_varint(1, 2_u64), pb_varint(1, 3_u64)))
      m.fields.map(&.uint).should eq([1_u64, 2_u64, 3_u64])
    end

    it "skips a deprecated group without raising and marks it skipped" do
      # field 5 start-group, interior field 1 = 7, field 5 end-group
      io = IO::Memory.new
      write_tag(io, 5, 3) # start group
      write_tag(io, 1, 0)
      write_varint(io, 7_u64)
      write_tag(io, 5, 4) # end group
      write_tag(io, 9, 0) # a trailing varint so we know skip advanced correctly
      write_varint(io, 99_u64)
      m = PB.decode(io.to_slice)
      m.complete.should be_true
      m.fields.size.should eq(2)
      m.fields[0].number.should eq(5_u32)
      m.fields[0].skipped.should be_true
      m.fields[1].number.should eq(9_u32)
      m.fields[1].uint.should eq(99_u64)
    end

    it "marks incomplete when the input is truncated mid-field" do
      # declares a 10-byte length-delimited payload, only gives 2
      io = IO::Memory.new
      write_tag(io, 1, 2)
      write_varint(io, 10_u64)
      io.write(Bytes[0x01, 0x02])
      m = PB.decode(io.to_slice)
      m.complete.should be_false
      m.fields.should be_empty # never finished the length-delimited field
    end

    it "marks incomplete on a truncated varint" do
      m = PB.decode(Bytes[0x08, 0x80]) # tag ok, varint continuation with no next byte
      m.complete.should be_false
    end

    it "marks incomplete on an illegal wire type" do
      # tag: field 1, wire type 6 (illegal)
      m = PB.decode(Bytes[(1 << 3) | 6])
      m.complete.should be_false
    end

    it "does not raise on deeply nested length-delimited shells" do
      # Build a chain deeper than MAX_DEPTH: each layer is field 1 = next layer.
      payload = Bytes.empty
      (PB::MAX_DEPTH + 4).times do
        payload = pb_len(1, payload)
      end
      m = PB.decode(payload)
      # Top level still returns; nested interpretation stops at the ceiling
      # rather than overflowing the stack.
      m.fields.size.should eq(1)
      m.fields[0].bytes.should_not be_nil
    end

    it "does not raise on a hostile length prefix larger than the buffer" do
      io = IO::Memory.new
      write_tag(io, 1, 2)
      write_varint(io, 0xffff_ffff_u64) # claims 4 GiB
      io.write(Bytes[0x00])
      m = PB.decode(io.to_slice)
      m.complete.should be_false
    end

    it "decodes a real greeter-shaped message (field 1 string + field 2 varint)" do
      # Hand-encoded equivalent of:
      #   message Hello { string name = 1; int32 id = 2; }
      #   Hello{name: "alice", id: 42}
      # Wire: 0a 05 61 6c 69 63 65 10 2a
      raw = Bytes[0x0a, 0x05, 0x61, 0x6c, 0x69, 0x63, 0x65, 0x10, 0x2a]
      m = PB.decode(raw)
      m.complete.should be_true
      m.fields.size.should eq(2)
      m.fields[0].number.should eq(1_u32)
      m.fields[0].string.should eq("alice")
      m.fields[1].number.should eq(2_u32)
      m.fields[1].uint.should eq(42_u64)
    end
  end

  describe "JSON projection" do
    it "emits every applicable length-delimited interpretation as sibling keys" do
      inner = pb_len(1, "alice")
      m = PB.decode(pb_len(2, inner))
      json = JSON.parse(m.to_json)
      json["complete"].as_bool.should be_true
      f = json["fields"].as_a[0]
      f["number"].as_i.should eq(2)
      f["wire"].as_s.should eq("len")
      f["string"]?.should_not be_nil
      f["message"]?.should_not be_nil
      f["bytes"]?.should_not be_nil
      Base64.decode(f["bytes"].as_s).should eq(inner)
      f["message"]["fields"].as_a[0]["string"].as_s.should eq("alice")
    end

    it "emits large uint values above 2^53-1 as strings so JSON stays exact" do
      big = 9_007_199_254_740_992_u64 # 2^53
      m = PB.decode(pb_varint(1, big))
      json = JSON.parse(m.to_json)
      # Must be a string — a JSON number would round.
      json["fields"].as_a[0]["uint"].as_s.should eq(big.to_s)
    end
  end

  describe ".message?" do
    it "is true for a clean message and false for truncated garbage" do
      PB.message?(pb_varint(1, 1_u64)).should be_true
      PB.message?(Bytes[0x08, 0x80]).should be_false
    end
  end

  # The module's contract is "never raises on hostile / truncated input (P7)", and a tag
  # varint of 2^35 or more made the `to_u32` that extracts the field number raise
  # OverflowError. Unrescued from `cli/run/history.cr`, so `gori run show --format json` on
  # such a captured flow died with an unhandled exception mid-JSON.
  describe "a tag whose field number overflows" do
    # Tag varint = 2^36, so wire type 0 (a VALID one — the wire-type check is not what stops
    # this) and field number 2^33, which does not fit in a UInt32.
    wide = Bytes[0x80, 0x80, 0x80, 0x80, 0x80, 0x02]

    it "is corrupt input, not an exception" do
      m = PB.decode(wide)
      m.complete.should be_false
      PB.message?(wide).should be_false
    end

    it "is caught inside a length-delimited field too (the nested-message probe)" do
      # field 1, wire type 2 (length-delimited), length 6, then the hostile tag.
      nested = Bytes[0x0a, 0x06] + wide
      PB.decode(nested).complete.should be_true # the OUTER message is well-formed…
      PB.message?(wide).should be_false         # …and the probe rejects the inner bytes
    end
  end
end
