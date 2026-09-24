require "./spec_helper"

describe Gori::JsonUnicode do
  it "decodes valid escapes and surrogate pairs inside strings only" do
    result = Gori::JsonUnicode.decode("{\n  \"x\": \"\\u003c \\ud83d\\ude00\",\n  \"n\": 1\n}")
    result.text.should eq("{\n  \"x\": \"< 😀\",\n  \"n\": 1\n}")
    result.count.should eq(3)
    result.ranges.should eq([{1, 8, 9}, {1, 10, 11}])
  end

  it "keeps unpaired surrogates spelled as supplied" do
    json = "{\"x\":\"\\ud800\\udc00x\\udfff\"}"
    result = Gori::JsonUnicode.decode(json)
    result.text.should eq("{\"x\":\"𐀀x\\udfff\"}")
    result.count.should eq(2)
    Gori::JsonUnicode.escape_count("{\"x\":\"\\ud800\\udc00x\\udfff\"}").should eq(2)
  end

  it "renders decoded invisible characters as named badges" do
    result = Gori::JsonUnicode.decode("{\"x\":\"a\\u200b\\u202e\\u00a0b\"}")
    result.text.should eq("{\"x\":\"a\u{200b}\u{202e}\u{00a0}b\"}")
    result.count.should eq(3)
  end

  it "marks decoded newlines so the TUI can display them inline as badges" do
    json = "{\"x\":\"a\\u000ab\\u003c\"}"
    result = Gori::JsonUnicode.decode(json)
    result.text.should eq("{\"x\":\"a\nb<\"}")
    result.protected_linefeeds.size.should eq(1)
    result.protected_linefeeds[0].should eq(result.text.to_slice.index(0x0a_u8, 2).not_nil!)
  end

  it "does not decode escape-like text outside strings or behind an escaped backslash" do
    json = "{\"x\":\"\\\"\\\\u003c\"}"
    Gori::JsonUnicode.decode(json).text.should eq(json)
  end
end
