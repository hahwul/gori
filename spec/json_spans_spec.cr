require "./spec_helper"

private alias J = Gori::JsonSpans

private def append(json : String, fragment = %("p":"v"), cap = 32) : String
  bytes = json.to_slice
  nodes = J.objects(bytes, cap).not_nil!
  String.new(J.append_members(bytes, nodes, fragment))
end

describe Gori::JsonSpans do
  it "keeps a duplicated member, in order, when appending (#1183)" do
    append(%({"dup":"first","dup":"second"})).should eq(%({"dup":"first","dup":"second","p":"v"}))
  end

  it "keeps number spellings, escapes and whitespace byte-exact" do
    src = %({ "n" : 1.0e2, "big": 18446744073709551615, "s": "\\u00e9\\/" \n})
    append(src).should eq(%({ "n" : 1.0e2, "big": 18446744073709551615, "s": "\\u00e9\\/","p":"v" \n}))
  end

  it "appends bare into an empty object and after the last member otherwise" do
    append(%({})).should eq(%({"p":"v"}))
    append(%({ \n })).should eq(%({"p":"v" \n }))
    append(%({"a":[1,{"b":{}}]})).should eq(%({"a":[1,{"b":{"p":"v"},"p":"v"}],"p":"v"}))
  end

  it "walks object nodes breadth-first in document order, capped" do
    nodes = J.objects(%([{"a":{"x":1}},{"b":2}]).to_slice, 32).not_nil!
    nodes.map(&.members.map(&.key)).should eq([["a"], ["b"], ["x"]])
    J.objects(%([{"a":{"x":1}},{"b":2}]).to_slice, 2).not_nil!.size.should eq(2)
  end

  it "reports member keys decoded and value spans exact" do
    src = %({"k\\u0031":"v","n":-2,"o":{"z":null}})
    root = J.root_object(src.to_slice).not_nil!
    root.members.map(&.key).should eq(["k1", "n", "o"])
    root.members.map { |m| src.byte_slice(m.value_start, m.value_end - m.value_start) }
      .should eq([%("v"), "-2", %({"z":null})])
    root.members[0].string?(src.to_slice).should be_true
    root.members[1].string?(src.to_slice).should be_false
  end

  it "does not read a quote or brace inside a string as structure" do
    append(%({"a":"}\\"{","b":"]"})).should eq(%({"a":"}\\"{","b":"]","p":"v"}))
  end

  it "answers nil for anything that is not exactly one JSON value" do
    J.objects(%({"a":1).to_slice, 32).should be_nil
    J.objects(%({"a":1} x).to_slice, 32).should be_nil
    J.objects(Bytes.empty, 32).should be_nil
    J.root_object(%([1]).to_slice).should be_nil
    J.objects(%([1,2]).to_slice, 32).should eq([] of J::Container)
  end

  it "keeps bytes that are not valid UTF-8 inside a string" do
    b = IO::Memory.new
    b << %({"bin":")
    b.write(Bytes[0xff, 0xfe])
    b << %("})
    bytes = b.to_slice
    res = J.append_members(bytes, J.objects(bytes, 32).not_nil!, %("p":"v"))
    res[0, bytes.size - 1].should eq(bytes[0, bytes.size - 1])
    String.new(res[bytes.size - 1..]).should eq(%(,"p":"v"}))
  end
end
