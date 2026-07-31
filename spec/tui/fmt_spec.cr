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

  describe ".dur" do
    it "keeps sub-millisecond latency in µs instead of collapsing it to '0ms'" do
      # A loopback/LAN response lands here. Truncating to ms rendered every one of these
      # as "0ms", which flattens the Fuzzer's DIST time histogram to a single bucket.
      Gori::Tui::Fmt.dur(0_i64).should eq("0µs")
      Gori::Tui::Fmt.dur(120_i64).should eq("120µs")
      Gori::Tui::Fmt.dur(511_i64).should eq("511µs")
      Gori::Tui::Fmt.dur(999_i64).should eq("999µs")
    end

    it "rounds the millisecond tier instead of truncating it" do
      Gori::Tui::Fmt.dur(1_000_i64).should eq("1.0ms")
      Gori::Tui::Fmt.dur(1_500_i64).should eq("1.5ms") # was "1ms"
      Gori::Tui::Fmt.dur(1_990_i64).should eq("2.0ms") # was "1ms"
      Gori::Tui::Fmt.dur(345_000_i64).should eq("345ms")
    end

    it "rolls a value just under a boundary up to the next unit" do
      Gori::Tui::Fmt.dur(999_600_i64).should eq("1.0s") # not "1000ms"
      Gori::Tui::Fmt.dur(59_600_000_i64).should eq("1.0m")
    end

    it "carries the slow tiers" do
      Gori::Tui::Fmt.dur(2_500_000_i64).should eq("2.5s")
      Gori::Tui::Fmt.dur(90_000_000_i64).should eq("1.5m")
      Gori::Tui::Fmt.dur(5_400_000_000_i64).should eq("1.5h")
    end

    it "stays within the 6-column cell the History DUR column draws" do
      # history_view draws this with `width: 6`; every tier boundary must fit.
      [0, 999, 1_000, 999_599, 999_600, 59_599_000, 59_600_000, 3_599_000_000,
       3_600_000_000, 86_400_000_000].each do |us|
        Gori::Tui::Fmt.dur(us.to_i64).size.should be <= 6
      end
    end

    it "shows an em dash until the response lands" do
      Gori::Tui::Fmt.dur(nil).should eq("—")
    end
  end
end
