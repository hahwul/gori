require "./spec_helper"
require "./support/demo_descriptor"
require "base64"
require "file_utils"

private alias PB = Gori::Protobuf
private alias Schema = Gori::Protobuf::Schema
private alias Lens = Gori::Protobuf::Lens
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

# Run `blk` with the registry loaded from `spec`, then put the process global back.
# `Schemas` is per-PROCESS state and every other example in the suite renders through it.
private def with_schemas(spec : String, &)
  Schemas.apply(spec)
  yield
ensure
  Schemas.clear
end

describe Gori::Protobuf::Schema do
  describe ".parse" do
    it "reads messages, nested types, enums and services out of a real descriptor set" do
      s = demo_schema
      s.files.should eq(1)
      s.messages.keys.sort.should eq(["demo.GetUserRequest", "demo.Outer", "demo.Outer.Inner",
                                      "demo.Profile", "demo.User"])
      s.enums.keys.sort.should eq(["demo.Outer.Kind", "demo.Role"])
      s.methods.keys.sort.should eq(["/demo.Users/GetUser", "/demo.Users/Watch"])
    end

    it "binds each rpc path to its input and output message types" do
      m = demo_schema.method?("/demo.Users/GetUser").not_nil!
      m.input_type.should eq("demo.GetUserRequest")
      m.output_type.should eq("demo.User")
      m.client_streaming.should be_false
      m.server_streaming.should be_false
    end

    it "records the streaming flags of a bidirectional rpc" do
      m = demo_schema.method?("/demo.Users/Watch").not_nil!
      m.client_streaming.should be_true
      m.server_streaming.should be_true
    end

    it "carries each field's number, name, declared type and repeated label" do
      u = demo_schema.message?("demo.User").not_nil!
      u.field?(1_u32).not_nil!.name.should eq("id")
      u.field?(1_u32).not_nil!.type.should eq(Schema::FieldType::Int64)
      u.field?(3_u32).not_nil!.type_name.should eq("demo.Role") # leading dot stripped
      u.field?(6_u32).not_nil!.repeated.should be_true
      u.field?(6_u32).not_nil!.type_label.should eq("repeated int32")
      u.field?(4_u32).not_nil!.type_label.should eq("Profile") # short name in the type column
    end

    it "qualifies a nested message and a nested enum with their parent's name" do
      demo_schema.message?("demo.Outer.Inner").not_nil!.field?(1_u32).not_nil!.name.should eq("label")
      demo_schema.enum?("demo.Outer.Kind").not_nil!.name?(1_i64).should eq("KIND_B")
    end

    it "maps enum value numbers to their names" do
      demo_schema.enum?("demo.Role").not_nil!.values.should eq({
        0_i64 => "ROLE_UNKNOWN", 1_i64 => "ROLE_USER", 2_i64 => "ROLE_ADMIN",
      })
    end

    it "names the `.proto` SOURCE mistake instead of reporting generic corruption" do
      src = "syntax = \"proto3\";\npackage demo;\nmessage User { string name = 1; }\n"
      msg = Schema.parse(src.to_slice).as(String)
      msg.should contain("looks like a `.proto` SOURCE file")
      msg.should contain("--descriptor_set_out")
    end

    it "refuses bytes that are not protobuf at all" do
      Schema.parse(Bytes[0xff, 0xff, 0xff, 0xff]).as(String).should contain("not a FileDescriptorSet")
    end

    it "refuses an empty file" do
      Schema.parse(Bytes.empty).as(String).should eq("empty file")
    end

    it "drops a field whose declared type code is outside the frozen 1..18 range" do
      # `type` = 265, which `to_u8!` would WRAP into 9 (String) — admitting the field under a
      # declaration the descriptor never made. It has to render from the wire instead.
      field = concat(pb_len(1, "ghost"), pb_varint(3, 1_u64), pb_varint(5, 265_u64))
      msg = pb_len(2, field)
      file = concat(pb_len(1, "x.proto"), pb_len(2, "demo"), pb_len(4, concat(pb_len(1, "Ghost"), msg)))
      s = Schema.parse(pb_len(1, file)).as(Schema)
      s.message?("demo.Ghost").not_nil!.field?(1_u32).should be_nil
    end

    it "stops absorbing nested messages at MAX_NEST instead of recursing off the stack" do
      # `nested_type` (field 3) chained far deeper than the ceiling. Two bytes per level, so a
      # real file can carry hundreds of thousands — and `submessages` restarts the PARSE budget
      # on each, which is what made the absorb recursion unbounded.
      payload = concat(pb_len(1, "Leaf"))
      4_000.times { payload = concat(pb_len(1, "N"), pb_len(3, payload)) }
      file = concat(pb_len(1, "deep.proto"), pb_len(2, "demo"), pb_len(4, payload))
      s = Schema.parse(pb_len(1, file))
      s.should be_a(Schema)
      s.as(Schema).messages.size.should be <= Schema::MAX_NEST + 2
    end

    it "refuses protobuf that carries no file descriptors" do
      # Valid protobuf, but field 2 — not FileDescriptorSet.file (1).
      Schema.parse(pb_len(2, "nope")).as(String).should contain("no FileDescriptorProto")
    end
  end

  describe "#merge!" do
    it "does not count the identical overlap two --include_imports sets always share" do
      a = demo_schema
      b = demo_schema
      a.merge!(b)
      a.conflicts.should eq(0)
      a.files.should eq(2)
    end

    it "counts a DIFFERING redefinition of the same fully-qualified name" do
      a = demo_schema
      # The same descriptor set with `demo.Profile.age` renamed — one byte of the wire, so
      # every other declaration still compares equal and only the redefinition is counted.
      raw = Base64.decode(DEMO_DESC_B64)
      i = String.new(raw).index("age").not_nil!
      raw[i] = 'a'.ord.to_u8
      raw[i + 1] = 'g'.ord.to_u8
      raw[i + 2] = 'X'.ord.to_u8
      b = Schema.parse(raw).as(Schema)
      b.message?("demo.Profile").not_nil!.field?(1_u32).not_nil!.name.should eq("agX")
      a.merge!(b)
      a.conflicts.should eq(1)
      a.message?("demo.Profile").not_nil!.field?(1_u32).not_nil!.name.should eq("agX")
    end

    it "carries a merged schema's own conflict count forward" do
      a = demo_schema
      b = demo_schema
      c = demo_schema
      b.merge!(c)
      b.conflicts.should eq(0)
      a.merge!(b)
      a.files.should eq(3)
    end
  end
end

describe Gori::Protobuf::Lens do
  it "decodes every scalar type the reference encoder produced" do
    demo_reading(1).not_nil!.value.should eq(-7_i64)              # int64, sign-extended varint
    demo_reading(2).not_nil!.value.should eq("hahwul")            # string
    demo_reading(7).not_nil!.value.should eq(true)                # bool
    demo_reading(8).not_nil!.value.should eq(0.5_f64)             # double from fixed64 bits
    demo_reading(9).not_nil!.value.should eq(1.5_f32)             # float from fixed32 bits
    demo_reading(10).not_nil!.value.should eq(-3_i64)             # sint32 — zigzag, not raw
    demo_reading(11).not_nil!.value.should eq(0xdeadbeefcafe_u64) # fixed64
  end

  it "names an enum value and keeps its number" do
    r = demo_reading(3).not_nil!
    r.value.should eq(2_i64)
    r.enum_name.should eq("ROLE_ADMIN")
    r.note.should be_nil
  end

  it "decodes a packed repeated scalar element by element" do
    r = demo_reading(6).not_nil!
    r.packed.should eq([1_i64, 2_i64, 300_i64])
    r.packed_more.should eq(0)
  end

  it "resolves a message field to the type to recurse into" do
    demo_reading(4).not_nil!.nested.not_nil!.full_name.should eq("demo.Profile")
    demo_reading(12).not_nil!.nested.not_nil!.full_name.should eq("demo.Outer")
  end

  it "leaves a bytes field's value unset — the octets ARE the reading" do
    r = demo_reading(5).not_nil!
    r.value.should be_nil
    r.nested.should be_nil
    r.disagrees.should be_false
  end

  it "returns nil for a field number the message does not declare" do
    s = demo_schema
    t = s.message?("demo.User").not_nil!
    f = PB.decode(pb_varint(99, 42_u64)).fields[0]
    Lens.read(s, t, f).should be_nil
  end

  it "reports a wire type the declaration contradicts instead of re-reading it" do
    s = demo_schema
    t = s.message?("demo.User").not_nil!
    f = PB.decode(pb_varint(2, 7_u64)).fields[0] # field 2 is declared `string`
    r = Lens.read(s, t, f).not_nil!
    r.disagrees.should be_true
    r.note.not_nil!.should contain("schema declares name as string")
    r.note.not_nil!.should contain("varint")
    r.value.should be_nil
  end

  it "treats a `string` field whose bytes are not UTF-8 as a disagreement" do
    s = demo_schema
    t = s.message?("demo.User").not_nil!
    f = PB.decode(pb_len(2, Bytes[0xff, 0xfe])).fields[0]
    r = Lens.read(s, t, f).not_nil!
    r.disagrees.should be_true
    r.note.not_nil!.should contain("not valid UTF-8")
  end

  it "notes an unrecognised enum value WITHOUT calling it a disagreement" do
    s = demo_schema
    t = s.message?("demo.User").not_nil!
    f = PB.decode(pb_varint(3, 77_u64)).fields[0]
    r = Lens.read(s, t, f).not_nil!
    r.disagrees.should be_false # proto3 keeps unknown enum values; API drift is not corruption
    r.value.should eq(77_i64)
    r.enum_name.should be_nil
    r.note.not_nil!.should contain("demo.Role")
  end

  it "keeps the elements of a packed run that ends mid-element and says how many are left" do
    s = demo_schema
    t = s.message?("demo.User").not_nil!
    # scores: 1, 2, then a varint whose continuation bit never terminates.
    f = PB.decode(pb_len(6, Bytes[0x01, 0x02, 0x80])).fields[0]
    r = Lens.read(s, t, f).not_nil!
    r.packed.should eq([1_i64, 2_i64])
    r.note.not_nil!.should contain("ends mid-element")
    r.disagrees.should be_false
  end

  describe ".emit_json" do
    it "projects named, typed fields beside the raw tree" do
      s = demo_schema
      t = s.message?("demo.User").not_nil!
      json = JSON.parse(JSON.build { |j| Lens.emit_json(j, demo_user_message, s, t) })
      json["message"].should eq("demo.User")
      fields = json["fields"].as_a
      fields[0]["name"].should eq("id")
      fields[0]["value"].as_i64.should eq(-7)
      fields[2]["enum"].should eq("ROLE_ADMIN")
      fields[3]["message"]["message"].should eq("demo.Profile")
      fields[5]["values"].as_a.map(&.as_i).should eq([1, 2, 300])
      fields[6]["value"].as_bool.should be_true
    end

    it "marks an undeclared field rather than dropping it" do
      s = demo_schema
      t = s.message?("demo.User").not_nil!
      msg = PB.decode(concat(pb_varint(1, 5_u64), pb_len(99, "surprise")))
      json = JSON.parse(JSON.build { |j| Lens.emit_json(j, msg, s, t) })
      extra = json["fields"].as_a[1]
      extra["number"].as_i.should eq(99)
      extra["unknown"].as_bool.should be_true
      extra["wire"].should eq("len")
      extra["size"].as_i.should eq(8)
    end
  end
end

describe Gori::Protobuf::Schemas do
  it "loads a descriptor set from a file path" do
    dir = File.tempname("gori-protos")
    Dir.mkdir_p(dir)
    path = File.join(dir, "demo.desc")
    File.write(path, Base64.decode(DEMO_DESC_B64))
    with_schemas(path) do
      Schemas.schema.should_not be_nil
      Schemas.errors?.should be_false
      Schemas.status.should contain("5 messages")
      Schemas.status.should contain("2 rpcs")
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "loads every descriptor set in a directory" do
    dir = File.tempname("gori-protos")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.desc"), Base64.decode(DEMO_DESC_B64))
    File.write(File.join(dir, "notes.txt"), "not a descriptor set") # ignored: wrong extension
    with_schemas(dir) do
      Schemas.sources.size.should eq(1)
      Schemas.schema.not_nil!.methods.size.should eq(2)
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "reports a missing path instead of silently loading nothing" do
    with_schemas(File.join(File.tempname("gori-nope"), "api.desc")) do
      Schemas.schema.should be_nil
      Schemas.errors?.should be_true
      Schemas.status.should contain("no such file or directory")
    end
  end

  it "loads nothing — and says so — when no descriptor set is configured" do
    with_schemas("") do
      Schemas.schema.should be_nil
      Schemas.status.should eq("no descriptor set loaded")
    end
  end

  it "carries a per-file failure through to the status line" do
    dir = File.tempname("gori-protos")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "good.desc"), Base64.decode(DEMO_DESC_B64))
    File.write(File.join(dir, "bad.desc"), "syntax = \"proto3\";\nmessage X { string a = 1; }\n")
    with_schemas(dir) do
      Schemas.errors?.should be_true
      Schemas.schema.should_not be_nil # the good one still loaded
      Schemas.status.should contain("1 failed")
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  describe ".resolve" do
    it "binds a captured gRPC target to the request and response message types" do
      dir = File.tempname("gori-protos")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
      with_schemas(dir) do
        req = Schemas.resolve("/demo.Users/GetUser", request: true).not_nil!
        req.type.full_name.should eq("demo.GetUserRequest")
        req.method.path.should eq("/demo.Users/GetUser")
        resp = Schemas.resolve("/demo.Users/GetUser", request: false).not_nil!
        resp.type.full_name.should eq("demo.User")
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "resolves an absolute-form target and ignores a query string" do
      dir = File.tempname("gori-protos")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
      with_schemas(dir) do
        Schemas.resolve("https://api.test/demo.Users/GetUser?x=1", request: true)
          .not_nil!.type.full_name.should eq("demo.GetUserRequest")
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns nil for an rpc the loaded set does not declare" do
      dir = File.tempname("gori-protos")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
      with_schemas(dir) do
        Schemas.resolve("/other.Svc/Method", request: true).should be_nil
        Schemas.resolve(nil, request: true).should be_nil
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns nil when no schema is loaded — every surface falls back to the wire" do
      Schemas.clear
      Schemas.resolve("/demo.Users/GetUser", request: true).should be_nil
    end
  end

  it "reads the path out of the project's settings row" do
    dir = File.tempname("gori-protos")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
    db = File.tempname("gori-protos-db")
    Dir.mkdir_p(db)
    store = Gori::Store.open(File.join(db, "gori.db"))
    begin
      store.set_setting(Schemas::SETTING_KEY, dir)
      Schemas.load_project(store)
      Schemas.spec.should eq(dir)
      Schemas.schema.not_nil!.methods.size.should eq(2)
    ensure
      Schemas.clear
      store.close
      FileUtils.rm_rf(db)
      FileUtils.rm_rf(dir)
    end
  end
end
