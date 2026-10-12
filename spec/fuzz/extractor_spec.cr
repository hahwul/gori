require "../spec_helper"

private alias F = Gori::Fuzz

# The Fuzzer's named extractors (#1592): History's `[LABEL=][res:]kind:selector` grammar, parsed
# once for all three surfaces, with the old single `extract` regex as extractor 0.
describe F::Extractor do
  describe ".parse" do
    it "puts the legacy regex first, as `extracted`, then each spec in order" do
      list = F::Extractor.parse(["RID=header:x-request-id", "jsonpath:data.id"], "code=(\\d+)")
      list = list.as(Array(F::Extractor))
      list.map(&.label).should eq(["extracted", "RID", "data.id"])
      list[0].loc.kind.regex?.should be_true
      list[1].loc.kind.header?.should be_true
      list[2].loc.selector.should eq("data.id")
      F::Extractor.parse([] of String).should eq([] of F::Extractor)
    end

    it "refuses the request side, an unknown kind, a bad regex and more than MAX_COLUMNS" do
      F::Extractor.parse(["req:header:authorization"]).as(String).should contain("RESPONSE")
      F::Extractor.parse(["nope:x"]).as(String).should contain("unknown kind")
      F::Extractor.parse(["regex:x{2,1}"]).as(String).should contain("does not compile")
      F::Extractor.parse([] of String, "x{2,1}").as(String).should contain("extract regex")
      too_many = Array.new(Gori::DisplayColumns::MAX_COLUMNS + 1) { |i| "header:h#{i}" }
      F::Extractor.parse(too_many).as(String).should contain("limit")
      # The legacy regex is a column too.
      F::Extractor.parse(too_many[1..], "x").as(String).should contain("limit")
      F::Extractor.parse(too_many[2..], "x").should be_a(Array(F::Extractor))
    end

    it "round-trips through the run's stored specs" do
      list = F::Extractor.parse(["RID=header:x-request-id", "position:0:4", "cookie:sid"]).as(Array(F::Extractor))
      back = F::Extractor.of_run(F::Extractor.to_json(list))
      back.should eq(list)
      back.map(&.sensitive?).should eq([false, false, true])
      F::Extractor.to_json([] of F::Extractor).should be_nil
    end

    it "labels a run saved before extractors as the legacy `extracted`" do
      F::Extractor.of_run(nil).map(&.label).should eq(["extracted"])
    end

    it "keeps an unreadable stored spec in its slot, masked" do
      back = F::Extractor.of_run(%(["header:x-a","bogus:?","jsonpath:id"]))
      back.map(&.label).should eq(["x-a", "bogus:?", "id"])
      back[1].sensitive?.should be_true
      F::Extractor.of_run(%({"not":"an array"})).map(&.label).should eq(["extracted"])
      F::Extractor.specs_of(%(["a=header:x"])).should eq(["a=header:x"])
    end
  end

  it "caps a stored value at a cell, saying so" do
    F::Extractor.cap(nil).should be_nil
    F::Extractor.cap("abc").should eq("abc")
    long = F::Extractor.cap("x" * 10_000).not_nil!
    long.size.should eq(Gori::DisplayColumns::CELL_MAX + 1)
    long.ends_with?('…').should be_true
  end
end
