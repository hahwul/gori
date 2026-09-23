require "./spec_helper"

private alias JP = Gori::JsonPath

private def at(json : String, path : String) : JSON::Any?
  JP.resolve(JSON.parse(json), path)
end

describe Gori::JsonPath do
  doc = %({"data":{"token":"s3cr3t","items":[{"secret":"x"},{"secret":"y"}],"0":"zero-key"},"$oid":"o","a.b":1})

  it "reads the dotted and the bracketed spellings of one path identically (#1201)" do
    ["data.token", "$.data.token", "$['data']['token']", %($["data"].token), "data[token]", ".data.token"].each do |p|
      at(doc, p).try(&.as_s?).should eq("s3cr3t")
    end
    ["data.items.1.secret", "data.items[1].secret", "$.data.items[1]['secret']", "data.items[-1].secret", "data.items.-1.secret"].each do |p|
      at(doc, p).try(&.as_s?).should eq("y")
    end
  end

  it "reads a dotted digit step as a key on an object and an index on an array; `[n]` only indexes" do
    at(doc, "data.0").try(&.as_s?).should eq("zero-key")
    at(doc, "data[0]").should be_nil
    at(doc, %(data.items["0"])).should be_nil
  end

  it "reads names a dotted step cannot spell through quotes, and a `$` that starts a name" do
    at(doc, %($["a.b"])).try(&.as_i).should eq(1)
    at(doc, "$oid").try(&.as_s?).should eq("o")
    at(doc, "$").should eq(JSON.parse(doc))
  end

  it "answers nil for a missing field and PRESENT for a null one" do
    at(doc, "data.nope").should be_nil
    at(doc, "data.items.5").should be_nil
    at(%({"error":null}), "error").not_nil!.raw.should be_nil
  end

  it "refuses what it cannot resolve instead of reading it as absent" do
    ["", "a..b", "$..token", "a.*", "a[*]", "a[?(@.x)]", "a[0:2]", "a[1,2]", "a[", "a]", ".", "$.", %(a[b"c]),
     %(a["x), %(a["x"), "a[]"].each do |p|
      JP.parse(p).should be_a(String)
      JP.valid?(p).should be_false
    end
    JP.parse("a..b").as(String).should contain("recursive descent")
    JP.parse("a[").as(String).should contain("unclosed")
  end

  it "tolerates a trailing dot and spaces around a quoted name" do
    at(doc, "data.token.").try(&.as_s?).should eq("s3cr3t")
    at(doc, %(data[ "token" ])).try(&.as_s?).should eq("s3cr3t")
  end

  it "keeps a quoted name's characters, JSONPath syntax included" do
    JP.parse(%(a["*[x]:y"])).should eq([JP::Step.new(key: "a", index: nil), JP::Step.new(key: "*[x]:y")])
  end
end
