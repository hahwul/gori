require "../../spec_helper"

private alias Schema = Gori::Export::OpenApi::Schema

private def infer(*docs : String) : JSON::Any
  s = Schema.new
  docs.each { |d| s.observe_json(d).should be_true }
  s.to_any
end

private def text(*values : String) : JSON::Any
  s = Schema.new
  values.each { |v| s.observe_text(v) }
  s.to_any(text: true)
end

describe Gori::Export::OpenApi::Schema do
  it "unions object properties and requires only the members every sample had" do
    infer(%({"a":1,"b":"x"}), %({"a":2,"c":true})).should eq(JSON.parse(<<-JSON))
      {"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"string"},"c":{"type":"boolean"}},
       "required":["a"]}
      JSON
  end

  it "widens integer to number instead of a union" do
    infer(%({"n":1}), %({"n":1.5}))["properties"]["n"].should eq(JSON.parse(%({"type":"number"})))
  end

  it "uses oneOf only when the types really differ, and nullable for null" do
    infer(%({"v":"a"}), %({"v":{"k":1}}))["properties"]["v"].should eq(JSON.parse(<<-JSON))
      {"oneOf":[{"type":"object","properties":{"k":{"type":"integer"}},"required":["k"]},{"type":"string"}]}
      JSON
    infer(%({"v":"a"}), %({"v":null}))["properties"]["v"].should eq(JSON.parse(%({"type":"string","nullable":true})))
    # 3.0.3 scopes `nullable` to a schema that names a type, so a union carries it on one branch.
    union = infer(%([1, "a", null]))["items"]["oneOf"].as_a
    union.count { |b| b["nullable"]? == JSON::Any.new(true) }.should eq(1)
    infer(%({"v":null}))["properties"]["v"].should eq(JSON.parse(%({"nullable":true})))
  end

  it "merges array items across every element, arrays of objects included" do
    infer(%({"items":[{"id":1,"tag":"a"},{"id":2}]}), %({"items":[]}))["properties"]["items"].should eq(JSON.parse(<<-JSON))
      {"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"tag":{"type":"string"}},"required":["id"]}}
      JSON
    infer(%([]))["items"].should eq(JSON.parse("{}"))
  end

  it "states a string format only when every string matched it" do
    infer(%({"u":"3f1c9ab4-0000-4000-8000-00000000abcd"}))["properties"]["u"]["format"].should eq("uuid")
    infer(%({"d":"2026-07-19T10:00:00Z"}), %({"d":"2026-07-20T11:30:00.5+09:00"}))["properties"]["d"]["format"].should eq("date-time")
    infer(%({"d":"2026-07-19"}), %({"d":"soon"}))["properties"]["d"]["format"]?.should be_nil
  end

  it "counts a member once per object, duplicates included" do
    infer(%({"a":1,"a":2}), %({"b":1}))["required"]?.should be_nil
  end

  it "rejects a body that is not exactly one JSON value, leaving nothing behind" do
    s = Schema.new
    s.observe_json(%({"a":1)).should be_false
    s.observe_json(%({"a":1} trailing)).should be_false
    s.observe_json("").should be_false
    s.empty?.should be_true
  end

  it "reads numbers past Int64 without raising" do
    infer(%({"big":123456789012345678901234567890}))["properties"]["big"]["type"].should eq("integer")
  end

  it "bounds depth and object width" do
    deep = "#{"[" * 40}1#{"]" * 40}"
    infer(deep) # must not raise or recurse without bound
    wide = String.build do |io|
      io << '{'
      (Schema::MAX_PROPERTIES + 50).times { |i| io << ',' if i > 0; io << %("k#{i}":1) }
      io << '}'
    end
    infer(wide)["properties"].as_h.size.should eq(Schema::MAX_PROPERTIES)
  end

  describe "text values" do
    it "types text as narrowly as every sample allows, never as a union" do
      text("1", "20").should eq(JSON.parse(%({"type":"integer"})))
      text("1", "2.5").should eq(JSON.parse(%({"type":"number"})))
      text("true", "false").should eq(JSON.parse(%({"type":"boolean"})))
      text("2", "last").should eq(JSON.parse(%({"type":"string"})))
      text("true", "1").should eq(JSON.parse(%({"type":"string"})))
      text("").should eq(JSON.parse(%({"type":"string"})))
      text("2026-07-19").should eq(JSON.parse(%({"type":"string","format":"date"})))
      text("12345678901234567890").should eq(JSON.parse(%({"type":"string"}))) # an id, not a count
    end
  end
end
