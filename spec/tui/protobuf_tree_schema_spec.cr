require "../spec_helper"
require "../support/demo_descriptor"

private alias PB = Gori::Protobuf
private alias Tree = Gori::Tui::ProtobufTree
private alias Schemas = Gori::Protobuf::Schemas

private def write_varint(io : IO, n : UInt64) : Nil
  while n > 0x7f_u64
    io.write_byte(((n & 0x7f_u64) | 0x80_u64).to_u8)
    n >>= 7
  end
  io.write_byte((n & 0x7f_u64).to_u8)
end

private def pb_varint(field : Int32, value : UInt64) : Bytes
  io = IO::Memory.new
  write_varint(io, ((field << 3) | 0).to_u64)
  write_varint(io, value)
  io.to_slice
end

private def pb_len(field : Int32, payload : Bytes | String) : Bytes
  data = payload.is_a?(String) ? payload.to_slice : payload
  io = IO::Memory.new
  write_varint(io, ((field << 3) | 2).to_u64)
  write_varint(io, data.size.to_u64)
  io.write(data)
  io.to_slice
end

private def concat(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

# The `demo.User` tree as the History / Repeater panes draw it with the schema loaded.
private def user_lines(extra : Bytes = Bytes.empty) : Array(String)
  s = demo_schema
  t = s.message?("demo.User").not_nil!
  body = extra.empty? ? Base64.decode(DEMO_USER_B64) : concat(Base64.decode(DEMO_USER_B64), extra)
  Tree.lines(PB.decode(body), indent: "", schema: s, type: t)
end

private def line_for(lines : Array(String), name : String) : String
  lines.find { |l| l.includes?(" #{name} ") }.not_nil!
end

describe "ProtobufTree with a .proto lens" do
  it "renders named, typed fields for a message the schema declares" do
    lines = user_lines
    line_for(lines, "id").should match(/^\s*1\s+id\s+int64\s+-7$/)
    line_for(lines, "name").should match(/^\s*2\s+name\s+string\s+"hahwul"$/)
    line_for(lines, "active").should match(/^\s*7\s+active\s+bool\s+true$/)
    line_for(lines, "ratio").should match(/^\s*8\s+ratio\s+double\s+0\.5$/)
    line_for(lines, "delta").should match(/^\s*10\s+delta\s+sint32\s+-3$/)
  end

  it "names an enum value beside its number" do
    line_for(user_lines, "role").should match(/^\s*3\s+role\s+Role\s+2 · ROLE_ADMIN$/)
  end

  it "lists a packed repeated scalar element by element" do
    line_for(user_lines, "scores").should contain("packed 3: 1, 2, 300")
  end

  it "descends into a nested message under its own declared type" do
    lines = user_lines
    i = lines.index { |l| l.includes?(" profile ") }.not_nil!
    lines[i].should contain("Profile")
    lines[i + 1].should match(/^\s+1\s+age\s+int32\s+30$/)
    lines[i + 2].should match(/^\s+2\s+tags\s+repeated string\s+"red"$/)
    lines[i + 3].should match(/^\s+2\s+tags\s+repeated string\s+"blue"$/)
  end

  it "shows a field number the message does not declare, raw, rather than hiding it" do
    lines = user_lines(pb_len(99, "surprise"))
    row = lines.find { |l| l.lstrip.starts_with?("99 ") }.not_nil!
    row.should contain("(undeclared)")
    row.should contain("len")
    row.should contain("string | bytes") # every reading the wire fits, exactly as with no schema
    lines.any? { |l| l.includes?("string: \"surprise\"") }.should be_true
  end

  it "reports a wire type the declaration contradicts AND still draws the wire reading" do
    # Field 2 is declared `string`; here it arrives as a varint.
    lines = user_lines(pb_varint(2, 7_u64))
    bad = lines.select { |l| l.includes?("⚠ schema declares name as string") }
    bad.size.should eq(1)
    bad[0].should contain("varint")
    lines.any? { |l| l.strip == "wire: 7" }.should be_true
  end

  it "notes an unrecognised enum value without dropping the number" do
    lines = user_lines(pb_varint(3, 77_u64))
    lines.any? { |l| l.match(/3\s+role\s+Role\s+77$/) }.should be_true
    lines.any? { |l| l.includes?("77 has no name in demo.Role") }.should be_true
  end

  it "renders exactly what it always did when no schema is passed" do
    plain = Tree.lines(demo_user_message, indent: "")
    plain[0].should eq("1  varint   18446744073709551609") # the RAW varint, not -7
    plain.any? { |l| l.includes?("message | string | bytes") }.should be_true
    plain.none? { |l| l.includes?("role") }.should be_true
  end

  describe ".schema_note" do
    it "names the rpc and the message the lens resolved to" do
      s = demo_schema
      b = Schemas::Binding.new(s, s.method?("/demo.Users/GetUser").not_nil!,
        s.message?("demo.User").not_nil!, false)
      note = Tree.schema_note(b)
      note.should contain("/demo.Users/GetUser")
      note.should contain("demo.User")
      note.should contain("are still shown")
    end
  end
end
