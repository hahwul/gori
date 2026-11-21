require "./spec_helper"

describe Gori::Fuzzy do
  it "scores an empty query as a neutral match" do
    Gori::Fuzzy.score("", "anything").should eq(0)
  end

  it "matches an in-order subsequence and rejects a non-subsequence" do
    Gori::Fuzzy.score("abc", "a_b_c").should_not be_nil
    Gori::Fuzzy.score("abc", "acb").should be_nil # 'b' before 'c' breaks the order
    Gori::Fuzzy.score("xyz", "abc").should be_nil
  end

  it "ranks a contiguous match above a scattered one" do
    contiguous = Gori::Fuzzy.score("abc", "abc").not_nil!
    scattered = Gori::Fuzzy.score("abc", "a.b.c").not_nil!
    contiguous.should be > scattered
  end

  it "scores characters rather than byte offsets in multilingual text" do
    Gori::Fuzzy.score("한글", "x한글").should eq(30)
    Gori::Fuzzy.score("한글", "x한x글").should eq(24)
    Gori::Fuzzy.score("한글", "글한").should be_nil
  end

  it "finds a match after a long multibyte prefix" do
    text = "한" * 4096 + "글"
    Gori::Fuzzy.score("글", text).should eq(15 - 4097)
    Gori::Fuzzy.score("z", text).should be_nil
  end

  it "does not overflow Int32 on a very long contiguous match (regression)" do
    # ~70k contiguous matches: the per-char `run * 5` bonus summed over the run
    # length exceeds Int32::MAX, which used to raise OverflowError mid-scan.
    s = "a" * 70_000
    score = Gori::Fuzzy.score(s, s)
    score.should_not be_nil
    score.not_nil!.should eq(Int32::MAX) # clamped, not crashed
  end
end
