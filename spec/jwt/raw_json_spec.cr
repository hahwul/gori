require "../spec_helper"

describe Gori::Jwt::RawJson do
  describe ".reformat" do
    it "keeps a number past Int64/Float64 as the digits it arrived as (#1169)" do
      json = %({"sub":"admin","uid":18446744073709551615,"f":1.5e400})
      Gori::Jwt::RawJson.reformat(json).should eq(json)
      Gori::Jwt::RawJson.reformat(json, "  ").should contain(%("uid": 18446744073709551615))
    end

    it "keeps a duplicated key instead of folding it away" do
      Gori::Jwt::RawJson.reformat(%({"sub":"a", "sub":"admin"})).should eq(%({"sub":"a","sub":"admin"}))
    end

    it "raises on bad syntax, trailing data, and empty input" do
      expect_raises(JSON::ParseException) { Gori::Jwt::RawJson.reformat(%({"a":)) }
      expect_raises(JSON::ParseException) { Gori::Jwt::RawJson.reformat(%({"a":1} x)) }
      expect_raises(JSON::ParseException) { Gori::Jwt::RawJson.reformat("") }
    end
  end

  describe ".members" do
    it "lists an object's members in order with raw values, duplicates kept" do
      Gori::Jwt::RawJson.members(%({"a":1,"b":{"c":[99999999999999999999]},"a":2})).should eq(
        [{"a", "1"}, {"b", %({"c":[99999999999999999999]})}, {"a", "2"}])
    end

    it "is nil for valid JSON that is not an object" do
      Gori::Jwt::RawJson.members(%(["a"])).should be_nil
    end
  end

  describe ".claims" do
    it "keeps every key readable, carrying an unrepresentable number as its text" do
      h = Gori::Jwt::RawJson.claims(%({"alg":"none","n":18446744073709551615,"alg":"HS256"})).not_nil!
      h["alg"].as_s.should eq("HS256") # last occurrence wins, as with JSON.parse
      h["n"].as_s.should eq("18446744073709551615")
    end

    it "is nil for a non-object or bad JSON" do
      Gori::Jwt::RawJson.claims("[1]").should be_nil
      Gori::Jwt::RawJson.claims("{").should be_nil
    end
  end

  describe ".member" do
    it "reads one claim when ANOTHER claim is unrepresentable" do
      Gori::Jwt::RawJson.member(%({"uid":18446744073709551615,"exp":1700000000}), "exp")
        .try(&.as_i64?).should eq(1700000000_i64)
    end

    it "takes the last occurrence of a duplicated key, as JSON.parse does" do
      Gori::Jwt::RawJson.member(%({"alg":"none","alg":"HS256"}), "alg").try(&.as_s?).should eq("HS256")
    end

    it "is nil when the claim itself is unrepresentable" do
      Gori::Jwt::RawJson.member(%({"exp":18446744073709551615}), "exp").should be_nil
    end
  end
end
