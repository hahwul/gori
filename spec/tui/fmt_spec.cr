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

  # `Float64#to_i` is Crystal's CHECKED conversion into Int32, so every formatter here used to
  # raise `OverflowError` past a rounded magnitude of 2.1e9 — on the RENDER path, where the
  # same frame is asked for again 50ms later and three failures trip the Runner's tick breaker
  # and end the process. Reachable from stored data, not just from arithmetic: an imported
  # HAR's `"time"` is carried into `duration_us` as-is, so `"time": 8e15` poisons the row.
  describe "values too large or too strange to spell" do
    it "renders an unspellable magnitude instead of raising" do
      Gori::Tui::Fmt.dur(8_000_000_000_000_000_000_i64).should eq("2222222222h")
      Gori::Tui::Fmt.dur(Int64::MAX).should eq("2562047788h")
      Gori::Tui::Fmt.size(Int64::MAX).should eq("8589934592GB")
      Gori::Tui::Fmt.count(Int64::MAX).should eq("9223372037B")
    end

    it "says infinity rather than overflowing on a non-finite float" do
      Gori::Tui::Fmt.pct(1e308).should eq("∞%")
      Gori::Tui::Fmt.pct(Float64::INFINITY).should eq("∞%")
      Gori::Tui::Fmt.bits(1e308).should eq("∞b")
      Gori::Tui::Fmt.bits(-Float64::INFINITY).should eq("-∞b")
    end

    it "reads a NaN magnitude as the module's own no-value dash" do
      Gori::Tui::Fmt.bits(Float64::NAN).should eq("—")
    end

    # `pct` is the formatter fed a RATIO — `uniqueness` is `unique.to_f / n` — so 0/0 is its
    # ordinary NaN source, and it printed "NaN%" while `bits` printed the dash for the same
    # quantity. Both comparisons in `pct` are false for NaN, so it never reached the guard.
    it "reads a NaN ratio the same way bits does" do
      Gori::Tui::Fmt.pct(Float64::NAN).should eq("—")
    end

    # `Int64::MAX.to_f64` rounds UP to 2^63 — one MORE than Int64 holds — so a `<=` bound
    # admits exactly the value `to_i64` then overflows on, inside the guard written to stop
    # that. `Int64::MIN` is a power of two and converts exactly, so its bound stays inclusive.
    it "refuses the exact 2^63 boundary that Int64::MAX.to_f64 rounds up to" do
      two_63 = 9223372036854775808.0
      Gori::Tui::Fmt.unit(two_63, "B").should eq("∞B")
      Gori::Tui::Fmt.bits(two_63).should eq("∞b")
      Gori::Tui::Fmt.pct(two_63 / 100).should eq("∞%")
    end

    # `unit` is public and its threshold is a MAGNITUDE question only for the non-negative
    # callers it has today; a negative value keeps the one-decimal spelling it always had.
    it "keeps the decimal spelling for a negative magnitude" do
      Gori::Tui::Fmt.unit(-50.0, "KB").should eq("-50.0KB")
    end
  end
end
