require "./spec_helper"

describe Gori::RawJson do
  describe ".reformat" do
    it "keeps a number past Int64/Float64 as the digits it arrived as (#1169)" do
      json = %({"sub":"admin","uid":18446744073709551615,"f":1.5e400})
      Gori::RawJson.reformat(json).should eq(json)
      Gori::RawJson.reformat(json, "  ").should contain(%("uid": 18446744073709551615))
    end

    it "keeps a duplicated key instead of folding it away" do
      Gori::RawJson.reformat(%({"sub":"a", "sub":"admin"})).should eq(%({"sub":"a","sub":"admin"}))
    end

    it "raises on bad syntax, trailing data, and empty input" do
      expect_raises(JSON::ParseException) { Gori::RawJson.reformat(%({"a":)) }
      expect_raises(JSON::ParseException) { Gori::RawJson.reformat(%({"a":1} x)) }
      expect_raises(JSON::ParseException) { Gori::RawJson.reformat("") }
    end
  end

  describe ".reindent" do
    it "changes JSON whitespace while preserving token spellings, duplicate keys, and outer whitespace" do
      source = " \t{ \"a\" : \"\\u003c\\/x\", \"a\" : 1E+05, \"s\" : \"\\ud800\" } \n"
      expected = " \t{\n  \"a\": \"\\u003c\\/x\",\n  \"a\": 1E+05,\n  \"s\": \"\\ud800\"\n} \n"
      Gori::RawJson.reindent(source).should eq(expected)
    end

    it "keeps invalid UTF-8 bytes inside strings verbatim" do
      source = String.new(Bytes[0x7b, 0x22, 0x78, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d])
      formatted = Gori::RawJson.reindent(source).not_nil!
      formatted.to_slice.should eq(Bytes[0x7b, 0x0a, 0x20, 0x20, 0x22, 0x78, 0x22, 0x3a, 0x20, 0x22, 0xff, 0x22, 0x0a, 0x7d])
    end

    it "returns nil for malformed JSON or output over the requested cap" do
      ["", "{\"a\":}", "[1,]", "01", "{} trailing"].each do |source|
        Gori::RawJson.reindent(source).should be_nil
      end
      Gori::RawJson.reindent("{\"a\":1}", "  ", 3).should be_nil
    end
  end

  describe ".members" do
    it "lists an object's members in order with raw values, duplicates kept" do
      Gori::RawJson.members(%({"a":1,"b":{"c":[99999999999999999999]},"a":2})).should eq(
        [{"a", "1"}, {"b", %({"c":[99999999999999999999]})}, {"a", "2"}])
    end

    it "is nil for valid JSON that is not an object" do
      Gori::RawJson.members(%(["a"])).should be_nil
    end
  end

  describe ".parse" do
    it "reads every other value when one number anywhere is past Int64/Float64 (#1200)" do
      doc = Gori::RawJson.parse(%({"id":18446744073709551615,"a":{"n":[1.5e400,2,-3.5]},"token":"t","ok":true,"z":null}))
      doc["id"].as_s.should eq("18446744073709551615")
      doc["a"]["n"][0].as_s.should eq("1.5e400")
      doc["a"]["n"][1].as_i64.should eq(2_i64)
      doc["a"]["n"][2].as_f.should eq(-3.5)
      doc["token"].as_s.should eq("t")
      doc["ok"].as_bool.should be_true
      doc["z"].raw.should be_nil
    end

    it "matches JSON.parse on a representable document, duplicate keys last-wins" do
      json = %({"a":[1,2.0,"x",{"b":false}],"a":{"c":-9223372036854775808}})
      Gori::RawJson.parse(json).should eq(JSON.parse(json))
    end

    it "raises on bad syntax and trailing data" do
      expect_raises(JSON::ParseException) { Gori::RawJson.parse(%({"a":)) }
      expect_raises(JSON::ParseException) { Gori::RawJson.parse(%({"a":1} x)) }
      expect_raises(JSON::ParseException) { Gori::RawJson.parse("") }
    end
  end

  describe ".claims" do
    it "keeps every key readable, carrying an unrepresentable number as its text" do
      h = Gori::RawJson.claims(%({"alg":"none","n":18446744073709551615,"alg":"HS256"})).not_nil!
      h["alg"].as_s.should eq("HS256") # last occurrence wins, as with JSON.parse
      h["n"].as_s.should eq("18446744073709551615")
    end

    it "is nil for a non-object or bad JSON" do
      Gori::RawJson.claims("[1]").should be_nil
      Gori::RawJson.claims("{").should be_nil
    end
  end

  describe ".member" do
    it "reads one claim when ANOTHER claim is unrepresentable" do
      Gori::RawJson.member(%({"uid":18446744073709551615,"exp":1700000000}), "exp")
        .try(&.as_i64?).should eq(1700000000_i64)
    end

    it "takes the last occurrence of a duplicated key, as JSON.parse does" do
      Gori::RawJson.member(%({"alg":"none","alg":"HS256"}), "alg").try(&.as_s?).should eq("HS256")
    end

    it "is nil when the claim itself is unrepresentable" do
      Gori::RawJson.member(%({"exp":18446744073709551615}), "exp").should be_nil
    end
  end
end
