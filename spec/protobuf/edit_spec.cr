require "../spec_helper"
require "../support/demo_descriptor"

private def user_type : Gori::Protobuf::Schema::MessageType
  demo_schema.message?("demo.User").not_nil!
end

private def set(data : Bytes, spec : String, schema = true) : Bytes | String
  if schema
    Gori::Protobuf::Edit.set(data, demo_schema, user_type, spec)
  else
    Gori::Protobuf::Edit.set(data, nil, nil, spec)
  end
end

# `name: "bob"` — a User whose every other field sits at its proto3 default, off the wire.
private BOB = Bytes[0x12, 0x03, 0x62, 0x6f, 0x62]

# `t.List { repeated t.Item items = 1; }`, `t.Item { string name = 1; }` — a repeated message,
# the shape a map field takes too.
private def list_schema : {Gori::Protobuf::Schema, Gori::Protobuf::Schema::MessageType}
  s = Gori::Protobuf::Schema.new
  s.messages["t.Item"] = Gori::Protobuf::Schema::MessageType.new("t.Item",
    {1_u32 => Gori::Protobuf::Schema::FieldDef.new(1_u32, "name", Gori::Protobuf::Schema::FieldType::String, nil, false)})
  list = Gori::Protobuf::Schema::MessageType.new("t.List",
    {1_u32 => Gori::Protobuf::Schema::FieldDef.new(1_u32, "items", Gori::Protobuf::Schema::FieldType::Message, "t.Item", true)})
  s.messages["t.List"] = list
  {s, list}
end

# items: [{name: "a", 99: 7}, {name: "b", 99: 8}] — field 99 undeclared, so the JSON hides it.
private ITEMS = Bytes[0x0a, 0x06, 0x0a, 0x01, 0x61, 0x98, 0x06, 0x07,
  0x0a, 0x06, 0x0a, 0x01, 0x62, 0x98, 0x06, 0x08]

describe Gori::Protobuf::Edit do
  describe ".set" do
    it "replaces a field the message carries, copying the rest" do
      set(BOB, "name=eve").should eq(Bytes[0x12, 0x03, 0x65, 0x76, 0x65])
      edited = set(Base64.decode(DEMO_USER_B64), "active=false").as(Bytes)
      Gori::Protobuf.decode(edited).fields.find(&.number.==(7)).not_nil!.uint.should eq(0)
      edited.size.should eq(Base64.decode(DEMO_USER_B64).size)
    end

    it "ADDS a defaulted proto3 field the capture never carried" do
      set(BOB, "active=true").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x38, 0x01])
      set(BOB, "role=ROLE_ADMIN").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x18, 0x02])
    end

    it "creates a nested message on the way to a field inside it" do
      # profile (4) { age (1) = 30 }
      set(BOB, "profile.age=30").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x22, 0x02, 0x08, 0x1e])
    end

    it "edits inside an existing nested message, keeping its other bytes" do
      once = set(BOB, "profile.age=30").as(Bytes)
      set(once, "profile.age=31").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x22, 0x02, 0x08, 0x1f])
    end

    it "adds an undeclared field number given its type" do
      set(BOB, "99:varint=1").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x98, 0x06, 0x01])
      set(BOB, "99:string=hi").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x9a, 0x06, 0x02, 0x68, 0x69])
      set(BOB, "99:sint32=-1").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x98, 0x06, 0x01])
    end

    it "works without a schema, by number" do
      set(BOB, "2=eve", schema: false).should eq(Bytes[0x12, 0x03, 0x65, 0x76, 0x65])
      set(BOB, "7:varint=1", schema: false).should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x38, 0x01])
      set(BOB, "4.1:varint=30", schema: false).should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x22, 0x02, 0x08, 0x1e])
    end

    it "refuses with a sentence rather than guessing" do
      set(BOB, "is_admin=true").as(String).should contain("declares no field \"is_admin\"")
      set(BOB, "active=maybe").as(String).should contain("not a bool")
      set(BOB, "99=1").as(String).should contain("give its type")
      set(BOB, "name=x", schema: false).as(String).should contain("no .proto schema")
      set(BOB, "99:widget=1").as(String).should contain("not a field type")
      set(BOB, "nameonly").as(String).should contain("not path=value")
      set(BOB, "profile=1").as(String).should contain("set a field inside it")
    end

    it "keeps an undecodable tail after the fields it adds" do
      truncated = Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x1a, 0x09, 0x61] # field 3 claims 9 bytes, 1 arrived
      set(truncated, "active=true").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x38, 0x01, 0x1a, 0x09, 0x61])
    end
  end

  describe ".set with -path (remove)" do
    it "removes a top-level field, copying every other byte" do
      data = Base64.decode(DEMO_USER_B64)
      role = Gori::Protobuf.field_spans(data).find(&.number.==(3)).not_nil!
      want = IO::Memory.new
      want.write(data[0, role.start])
      want.write(data[role.finish, data.size - role.finish])
      set(data, "-role").should eq(want.to_slice)
      set(data, "-3", schema: false).should eq(want.to_slice)
    end

    it "removes inside a nested message, re-measuring only the containers on its path" do
      # profile (4) { age (1) = 30, tags (2) = "red", "blue" }: both tags go, age stays
      profile = Bytes[0x22, 0x0d, 0x08, 0x1e, 0x12, 0x03, 0x72, 0x65, 0x64, 0x12, 0x04, 0x62, 0x6c, 0x75, 0x65]
      set(BOB + profile, "-profile.tags").should eq(BOB + Bytes[0x22, 0x02, 0x08, 0x1e])
      set(BOB + profile, "-4.2", schema: false).should eq(BOB + Bytes[0x22, 0x02, 0x08, 0x1e])
    end

    it "removes every occurrence, inside every occurrence of a message on the path" do
      # 7 = 1 twice, and profile { age = 30 } twice (a parser merges them into one)
      twice = Bytes[0x38, 0x01] + BOB + Bytes[0x38, 0x01]
      set(twice, "-active").should eq(BOB)
      profiles = Bytes[0x22, 0x02, 0x08, 0x1e] + BOB + Bytes[0x22, 0x02, 0x08, 0x1f]
      set(profiles, "-profile.age").should eq(Bytes[0x22, 0x00] + BOB + Bytes[0x22, 0x00])
    end

    it "refuses a field the message does not carry, and a malformed spec" do
      set(BOB, "-role").as(String).should contain("not on this message")
      set(BOB, "-profile.age").as(String).should contain("not on this message")
      set(BOB, "-is_admin").as(String).should contain("declares no field \"is_admin\"")
      set(BOB, "-7:varint").as(String).should contain("takes no :type")
      set(BOB, "-").as(String).should contain("names no field")
      set(BOB, "-name..x").as(String).should contain("empty path segment")
      set(BOB, "-name.x").as(String).should contain("not a message")
    end

    it "keeps an undecodable tail after the fields it keeps" do
      truncated = Bytes[0x38, 0x01, 0x12, 0x03, 0x62, 0x6f, 0x62, 0x1a, 0x09, 0x61]
      set(truncated, "-active").should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x1a, 0x09, 0x61])
    end
  end

  describe ".to_json / .from_json" do
    it "round-trips the capture byte for byte when nothing is edited" do
      data = Base64.decode(DEMO_USER_B64)
      json = Gori::Protobuf::Edit.to_json(data, demo_schema, user_type)
      JSON.parse(json)["id"].as_s.should eq("-7") # 64-bit as a string, per proto3 JSON
      Gori::Protobuf::Edit.from_json(data, demo_schema, user_type, json).should eq(data)
    end

    it "shows a false bool and a zero, which are values like any other" do
      json = JSON.parse(Gori::Protobuf::Edit.to_json(Bytes[0x38, 0x00, 0x50, 0x00], demo_schema, user_type))
      json["active"].as_bool.should be_false
      json["delta"].as_i.should eq(0)
    end

    it "sets an existing field and adds a missing one" do
      edited = Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, %({"name": "eve", "isAdmin": null, "role": "ROLE_ADMIN"}))
      edited.should be_a(String) # isAdmin is not a demo.User field: refused, not dropped
      edited = Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, %({"name": "eve", "role": "ROLE_ADMIN", "active": true}))
      edited.should eq(Bytes[0x12, 0x03, 0x65, 0x76, 0x65, 0x18, 0x02, 0x38, 0x01])
    end

    it "keeps an undeclared field the JSON cannot show, and drops a deleted key" do
      data = Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x98, 0x06, 0x01, 0x38, 0x01]
      json = Gori::Protobuf::Edit.to_json(data, demo_schema, user_type)
      json.should_not contain("99")
      Gori::Protobuf::Edit.from_json(data, demo_schema, user_type, %({"name": "bob"}))
        .should eq(Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x98, 0x06, 0x01])
    end

    it "refuses an unknown key or a value its field cannot hold" do
      Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, %({"is_admin": true}))
        .as(String).should contain("has no field \"is_admin\"")
      Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, %({"active": "yes"}))
        .as(String).should contain("active")
      Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, %({"scores": 3}))
        .as(String).should contain("JSON array")
      Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, %({"id": true}))
        .as(String).should contain("does not fit")
      Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, "[1]")
        .as(String).should contain("JSON object")
      Gori::Protobuf::Edit.from_json(BOB, demo_schema, user_type, "{")
        .as(String).should contain("not valid JSON")
    end

    it "refuses to re-encode a singular message that occurs twice, which a parser merges" do
      data = Bytes[0x12, 0x03, 0x62, 0x6f, 0x62, 0x22, 0x02, 0x08, 0x1e, 0x22, 0x02, 0x08, 0x1f]
      json = Gori::Protobuf::Edit.to_json(data, demo_schema, user_type)
      Gori::Protobuf::Edit.from_json(data, demo_schema, user_type, json).should eq(data) # untouched: copied
      Gori::Protobuf::Edit.from_json(data, demo_schema, user_type, json.sub(%("age": 31), %("age": 40)))
        .as(String).should contain("occurs 2 times")
    end

    it "takes an integral float for an integer field, as proto3 JSON does" do
      Gori::Protobuf::Edit.from_json(Bytes.empty, demo_schema, user_type, %({"id": 30.0, "delta": 1e2}))
        .should eq(Bytes[0x08, 0x1e, 0x50, 0xc8, 0x01])
      Gori::Protobuf::Edit.from_json(Bytes.empty, demo_schema, user_type, %({"id": 1.5}))
        .as(String).should contain("not an integer")
    end

    it "merges each element of a repeated message into its own occurrence, keeping what it hides" do
      schema, list = list_schema
      json = Gori::Protobuf::Edit.to_json(ITEMS, schema, list)
      Gori::Protobuf::Edit.from_json(ITEMS, schema, list, json.sub(%("b"), %("c")))
        .should eq(Bytes[0x0a, 0x06, 0x0a, 0x01, 0x61, 0x98, 0x06, 0x07, 0x0a, 0x06, 0x0a, 0x01, 0x63, 0x98, 0x06, 0x08])
      # A new length cannot be paired with the wire's elements: refused rather than dropping 99.
      Gori::Protobuf::Edit.from_json(ITEMS, schema, list, %({"items": [{"name": "a"}]}))
        .as(String).should contain("keep 2 to edit them in place")
      # …and encoded afresh when the elements hold nothing the JSON cannot show.
      plain = Bytes[0x0a, 0x03, 0x0a, 0x01, 0x61]
      Gori::Protobuf::Edit.from_json(plain, schema, list, %({"items": [{"name": "a"}, {"name": "b"}]}))
        .should eq(Bytes[0x0a, 0x03, 0x0a, 0x01, 0x61, 0x0a, 0x03, 0x0a, 0x01, 0x62])
    end

    it "keeps an untouched element's bytes and each element where it stood" do
      schema, list = list_schema
      # items "a" behind a padded two-byte length, an undeclared field 2 between the two items.
      data = Bytes[0x0a, 0x83, 0x00, 0x0a, 0x01, 0x61, 0x10, 0x01, 0x0a, 0x03, 0x0a, 0x01, 0x62]
      json = Gori::Protobuf::Edit.to_json(data, schema, list)
      Gori::Protobuf::Edit.from_json(data, schema, list, json.sub(%("b"), %("c")))
        .should eq(Bytes[0x0a, 0x83, 0x00, 0x0a, 0x01, 0x61, 0x10, 0x01, 0x0a, 0x03, 0x0a, 0x01, 0x63])
    end

    it "refuses a key for a field on the wire that the JSON left out" do
      # name (2) as a varint, which the schema's string contradicts; scores (6) packed past
      # the lens's listing limit.
      contradicted = Bytes[0x10, 0x05]
      Gori::Protobuf::Edit.to_json(contradicted, demo_schema, user_type).should_not contain("name")
      Gori::Protobuf::Edit.from_json(contradicted, demo_schema, user_type, %({"name": "x"}))
        .as(String).should contain("cannot show")
      run = Bytes.new(Gori::Protobuf::Lens::PACKED_MAX + 10, 0x01_u8)
      long = Gori::Protobuf::Encoder.length_delimited(6_u32, run)
      Gori::Protobuf::Edit.to_json(long, demo_schema, user_type).should_not contain("scores")
      Gori::Protobuf::Edit.from_json(long, demo_schema, user_type, %({"scores": [1]}))
        .as(String).should contain("cannot show")
    end

    it "refuses a packed element that would split into several" do
      Gori::Protobuf::Edit.from_json(Bytes.empty, demo_schema, user_type, %({"scores": ["1,2"]}))
        .as(String).should contain("one element, not a list")
      Gori::Protobuf::Edit.from_json(Bytes.empty, demo_schema, user_type, %({"scores": ["1 2"]}))
        .as(String).should contain("one element, not a list")
    end

    it "edits inside a nested message in place" do
      data = Base64.decode(DEMO_USER_B64)
      edited = Gori::Protobuf::Edit.from_json(data, demo_schema, user_type,
        Gori::Protobuf::Edit.to_json(data, demo_schema, user_type).sub(%("age": 30), %("age": 31))).as(Bytes)
      edited.size.should eq(data.size)
      Gori::Protobuf.decode(edited).fields.find(&.number.==(4)).not_nil!.message.not_nil!.fields[0].uint.should eq(31)
    end
  end
end
