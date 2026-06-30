require "../spec_helper"

describe Gori::Tui::Fmt do
  describe ".count" do
    it "shows a plain integer below 1000" do
      Gori::Tui::Fmt.count(0_i64).should eq("0")
      Gori::Tui::Fmt.count(999_i64).should eq("999")
    end

    it "abbreviates thousands/millions/billions with one decimal under 10" do
      Gori::Tui::Fmt.count(1_000_i64).should eq("1.0k")
      Gori::Tui::Fmt.count(1_234_i64).should eq("1.2k")
      Gori::Tui::Fmt.count(12_345_i64).should eq("12k")
      Gori::Tui::Fmt.count(1_500_000_i64).should eq("1.5M")
      Gori::Tui::Fmt.count(2_500_000_000_i64).should eq("2.5B")
    end

    it "rolls a value just under a boundary up to the next unit (no misleading '1000k')" do
      Gori::Tui::Fmt.count(999_999_i64).should eq("1.0M")
    end
  end
end
