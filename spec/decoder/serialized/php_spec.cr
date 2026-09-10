require "../../spec_helper"
require "../../support/serialized_vectors"

private alias P = Gori::Decoder::Serialized::Php

private def read(s : String) : String
  P.render(s.to_slice).json
end

describe Gori::Decoder::Serialized::Php do
  it "demangles a private and a protected property, and says which was which" do
    # PHP writes `\\0Class\\0prop` and `\\0*\\0prop` on the wire. A NUL in the middle of a JSON
    # member name is unreadable and easy to miss, so the name is demangled and the visibility
    # comes back beside it rather than being dropped with the mangling.
    doc = SerializedVectors::PHP_OBJECT
    r = P.render(doc)
    r.complete.should be_true
    r.describes?(doc.size).should be_true
    r.json.should eq(
      %({"$class":"MyClass","pub":"hi","priv":7,"prot":true,) +
      %("$private":["priv"],"$protected":["prot"]}))
  end

  it "marks an integer key rather than passing it off as a string one" do
    # A PHP array is an ordered map with integer OR string keys, and JSON has room for only
    # the second. Same marker, same accepted ambiguity, as the MessagePack reader.
    read(%(a:3:{i:0;s:1:"a";i:1;d:1.5;i:2;N;})).should eq(
      %({"0":"a","1":1.5,"2":null,"$keys":"non-string"}))
    read(%(a:1:{s:3:"key";s:5:"value";})).should eq(%({"key":"value"}))
  end

  it "EMITS a back-reference rather than expanding it" do
    read(%(a:2:{i:0;O:8:"stdClass":0:{}i:1;r:2;})).should eq(
      %({"0":{"$class":"stdClass"},"1":{"$ref":2},"$keys":"non-string"}))
    read(%(R:4;)).should eq(%({"$ref":4,"byref":true}))
  end

  it "treats the hex-escaped S: form as a string KEY, which is how a filter gets dodged" do
    # `S:` is not academic here — it is the standard spelling of a serialized payload written
    # to get past a filter looking for `s:`, so the crafted input this reader exists for is
    # exactly the one a one-byte `== 's'` test renders wrong: the key's whole JSON rendering,
    # surrounding quotes included, became the member name.
    read(%(a:1:{S:3:"k\\65y";s:1:"v";})).should eq(%({"key":"v"}))
  end

  it "reads a string BY LENGTH, so a quote or a semicolon inside it is just a byte" do
    read(%(s:5:"a";bc";)).should eq(%("a\\";bc"))
  end

  it "decodes the \\HH escapes of the S: form, whose length counts DECODED bytes" do
    read(%(S:5:"h\\65ll\\6f";)).should eq(%("hello"))
  end

  it "hands back a string that is not UTF-8 as bytes rather than scrubbing it" do
    P.render(%(s:3:").to_slice + Bytes[0x00, 0xff, 0xfe] + %(";).to_slice).json
      .should eq(%({"$str_invalid_utf8":"AP/+"}))
  end

  it "names the three float values JSON has no literal for" do
    read(%(a:3:{i:0;d:INF;i:1;d:-INF;i:2;d:NAN;})).should contain(
      %({"$float":"Infinity"},"1":{"$float":"-Infinity"},"2":{"$float":"NaN"}))
  end

  it "reads an enum case and hands a Serializable's own payload back as bytes" do
    read(%(E:11:"Suit:Hearts";)).should eq(%({"$enum":"Suit:Hearts"}))
    read(%(C:11:"ArrayObject":6:{x:i:0;})).should eq(
      %({"$class":"ArrayObject","$custom":{"$bin":"eDppOjA7"}}))
  end

  it "refuses a value with bytes behind it — a serialized parameter is exact" do
    doc = "i:5;XX"
    r = P.render(doc.to_slice)
    r.stop.should eq("trailing")
    r.describes?(doc.size).should be_false
  end

  it "never allocates a length it has not compared against the input" do
    # `S:2000000000:"` asks for a 2 GB allocation in fifteen bytes. An escaped run costs at
    # least one encoded byte per decoded byte, so a length past what is left cannot be
    # truthful — and the guard has to sit in front of `Bytes.new(n)`, not inside the loop.
    # The rendering alone does NOT prove it: with the guard deleted the loop still runs out
    # of input after two bytes and still reports `truncated`, having allocated two gigabytes
    # on the way (measured: `total_bytes` moved 2 000 003 088). So the assertion is on what
    # was allocated. `S:` is the form the guard exists for; `s:` is here to show the plain
    # form was never exposed, because `take` refuses a length past the input before it
    # returns anything.
    before = GC.stats.total_bytes
    [%(S:2000000000:"ab";), %(s:2000000000:"ab";)].each do |doc|
      r = P.render(doc.to_slice)
      r.stop.should eq("truncated")
      r.json.should eq(%({"$partial":"truncated"}))
    end
    (GC.stats.total_bytes - before).should be < 16_u64 * 1024 * 1024
  end

  it "writes exactly one marker for a position, even when two things went wrong in it" do
    # A bad hex digit inside an `S:` run used to `bail` in the unescape AND again in its
    # caller, putting two JSON values where one belongs — which is not a document at all.
    json = read(%(S:2:"\\zz";))
    JSON.parse(json).should be_a(JSON::Any)
    json.should eq(%({"$partial":"malformed"}))
  end

  it "refuses a body that is not this grammar, and says nothing was decoded" do
    r = P.render("hello world".to_slice)
    r.decoded.should be_false
    r.json.should eq(%({"$partial":"malformed"}))
  end

  it "keeps a body cut short readable, which is what a capture cap produces" do
    doc = %(a:2:{i:0;s:5:"hello";i:1;s:5:"world";})
    (10..doc.bytesize).each do |n|
      cut = doc.to_slice[0, n]
      r = P.render(cut)
      next unless r.decoded
      r.describes?(n).should be_true
    end
    read(%(a:2:{i:0;s:5:"he)).should contain(%("$partial":"truncated"))
  end
end
