require "../spec_helper"

private alias S = Gori::Tui::Spark

private def w(str : String) : Int32
  Gori::Tui::Screen.display_width(str)
end

describe Gori::Tui::Spark do
  describe ".bar" do
    it "draws full blocks + space pad to exactly `width` columns" do
      S.bar(5, 10, 10).should eq("█████     ")
      w(S.bar(5, 10, 10)).should eq(10)
      S.bar(10, 10, 10).should eq("██████████")
      S.bar(0, 10, 10).should eq(" " * 10)
    end

    it "renders the fractional 1/8th cell" do
      S.bar(1, 8, 1).should eq("▏")
      S.bar(5, 8, 1).should eq("▋")
      S.bar(8, 8, 1).should eq("█")
    end

    it "shows at least a 1/8 sliver for any nonzero value (the anomaly cue)" do
      S.bar(1, 1000, 10).should start_with("▏")
      w(S.bar(1, 1000, 10)).should eq(10)
    end

    it "guards degenerate inputs" do
      S.bar(5, 10, 0).should eq("")
      S.bar(5, 0, 10).should eq(" " * 10)   # max <= 0
      S.bar(-3, 10, 10).should eq(" " * 10) # value <= 0
    end
  end

  describe ".line" do
    it "blanks all-zero / empty input" do
      S.line([0, 0, 0]).should eq("   ")
      S.line([] of Int32).should eq("")
    end

    it "renders a single nonzero bucket at full level" do
      S.line([1]).should eq("█")
    end

    it "scales levels to the max bucket and blanks zero buckets" do
      S.line([5, 5, 5]).should eq("███")
      gap = S.line([0, 5, 0])
      gap.size.should eq(3)
      gap[0].should eq(' ')
      gap[1].should eq('█')
      gap[2].should eq(' ')
      asc = S.line([1, 2, 4, 8])
      w(asc).should eq(4)
      asc[3].should eq('█') # the max bucket
    end
  end

  describe ".histogram" do
    it "counts into equal-width bins (max value is top-inclusive)" do
      S.histogram([0, 9], 10).first.should eq(1) # 0 → bin 0
      S.histogram([0, 9], 10).last.should eq(1)  # 9 (max) → last bin
    end

    it "puts all identical / single values in bin 0 (no spread)" do
      S.histogram([5, 5, 5], 4).should eq([3, 0, 0, 0])
      S.histogram([7], 4).should eq([1, 0, 0, 0])
    end

    it "handles empty input and non-positive bins" do
      S.histogram([] of Int32, 4).should eq([0, 0, 0, 0])
      S.histogram([1, 2], 0).should eq([] of Int32)
    end

    it "clamps values outside an explicit [min,max] into the edge bins" do
      S.histogram([-100, 100], 4, 0.0, 10.0).should eq([1, 0, 0, 1])
    end

    it "works for Int64 and Float64 element types" do
      S.histogram([0_i64, 100_i64], 2).sum.should eq(2)
      S.histogram([0.0, 1.0], 2).sum.should eq(2)
    end
  end
end
