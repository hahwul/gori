require "../spec_helper"

# The layout is pure integer geometry, so no backend/harness is needed. We assert
# the documented contract from src/gori/tui/layout.cr: chrome rows (topbar/rule/menu)
# at y0+0/+1/+2, body at y0+3, status pinned near the bottom, an empty statusline
# Rect unless the feature is on, and the clamped dims that must never go negative.

private HPAD = Gori::Tui::Layout::H_PADDING # 2
private VPAD = Gori::Tui::Layout::V_PADDING # 1

describe Gori::Tui::Layout do
  describe ".usable?" do
    it "requires at least 40 columns AND 8 rows (>= on both dims)" do
      # exact thresholds from source: width >= 40 && height >= 8
      Gori::Tui::Layout.usable?(40, 8).should be_true
    end

    it "rejects one column short of the width threshold" do
      Gori::Tui::Layout.usable?(39, 8).should be_false
    end

    it "rejects one row short of the height threshold" do
      Gori::Tui::Layout.usable?(40, 7).should be_false
    end

    it "accepts values comfortably above both thresholds" do
      Gori::Tui::Layout.usable?(41, 9).should be_true
      Gori::Tui::Layout.usable?(80, 24).should be_true
      Gori::Tui::Layout.usable?(Int32::MAX, Int32::MAX).should be_true
    end

    it "rejects a terminal that is wide enough but far too short" do
      Gori::Tui::Layout.usable?(200, 1).should be_false
    end

    it "rejects a terminal that is tall enough but far too narrow" do
      Gori::Tui::Layout.usable?(1, 200).should be_false
    end

    it "rejects zero and negative sizes" do
      Gori::Tui::Layout.usable?(0, 0).should be_false
      Gori::Tui::Layout.usable?(-40, -8).should be_false
    end
  end

  describe ".compute (default, statusline off)" do
    it "places chrome, body and status at the documented rows with reserved==4" do
      l = Gori::Tui::Layout.compute(80, 24)
      x = HPAD              # 2
      y0 = VPAD             # 1
      inner_w = 80 - 2*HPAD # 76
      inner_h = 24 - 2*VPAD # 22

      # topbar/rule/menu are single-row inset bars stacked at y0, y0+1, y0+2.
      l.topbar.should eq(Gori::Tui::Rect.new(x, y0 + 0, inner_w, 1))
      l.rule.should eq(Gori::Tui::Rect.new(x, y0 + 1, inner_w, 1))
      l.menu.should eq(Gori::Tui::Rect.new(x, y0 + 2, inner_w, 1))

      # body starts at row 3 and reserves 4 rows (topbar+rule+menu+status).
      l.body.should eq(Gori::Tui::Rect.new(x, y0 + 3, inner_w, inner_h - 4))
      l.body.h.should eq(18)

      # status sits on the last inner row (statusline off => -1).
      l.status.should eq(Gori::Tui::Rect.new(x, y0 + inner_h - 1, inner_w, 1))

      # statusline is the empty Rect built at (x, y0, 0, 0) when the feature is off.
      l.statusline.should eq(Gori::Tui::Rect.new(x, y0, 0, 0))
      (l.statusline.w == 0 && l.statusline.h == 0).should be_true
      l.statusline.empty?.should be_true
    end

    it "field-wiring regression: menu.y is y0+2 and rule.y is y0+1 (never swapped)" do
      # initialize(@topbar,@menu,@rule,...) takes params in a different order than the
      # local vars, so a swap at the call site would flip these two. Guard against it.
      l = Gori::Tui::Layout.compute(80, 24)
      l.rule.y.should eq(VPAD + 1) # 2
      l.menu.y.should eq(VPAD + 2) # 3
      l.topbar.y.should eq(VPAD)   # 1
      l.rule.y.should be < l.menu.y
    end

    it "insets every chrome/body rect by H_PADDING on x and shares inner_w width" do
      l = Gori::Tui::Layout.compute(80, 24)
      inner_w = 80 - 2*HPAD
      {l.topbar, l.rule, l.menu, l.body, l.status}.each do |r|
        r.x.should eq(HPAD)
        r.w.should eq(inner_w)
      end
    end

    it "explicitly reserves 4 rows: inner_h - body.h == 4 for a tall terminal" do
      l = Gori::Tui::Layout.compute(80, 100)
      inner_h = 100 - 2*VPAD
      (inner_h - l.body.h).should eq(4)
    end
  end

  describe ".compute (statusline on)" do
    it "reserves 5 rows, shifts status up one and gives the statusline the last row" do
      x = HPAD
      y0 = VPAD
      inner_w = 80 - 2*HPAD
      inner_h = 24 - 2*VPAD

      on = Gori::Tui::Layout.compute(80, 24, true)

      # chrome is unchanged relative to the default layout.
      on.topbar.should eq(Gori::Tui::Rect.new(x, y0 + 0, inner_w, 1))
      on.rule.should eq(Gori::Tui::Rect.new(x, y0 + 1, inner_w, 1))
      on.menu.should eq(Gori::Tui::Rect.new(x, y0 + 2, inner_w, 1))

      # status moves to inner_h-2; statusline occupies inner_h-1 with full inner_w.
      on.status.should eq(Gori::Tui::Rect.new(x, y0 + inner_h - 2, inner_w, 1))
      on.statusline.should eq(Gori::Tui::Rect.new(x, y0 + inner_h - 1, inner_w, 1))
      on.statusline.w.should eq(inner_w)
      on.statusline.empty?.should be_false

      # reserved == 5 => body one row shorter than the default layout.
      on.body.should eq(Gori::Tui::Rect.new(x, y0 + 3, inner_w, inner_h - 5))
      (inner_h - on.body.h).should eq(5)
    end

    it "makes body exactly one row shorter than the statusline-off layout" do
      off = Gori::Tui::Layout.compute(80, 24, false)
      on = Gori::Tui::Layout.compute(80, 24, true)
      (off.body.h - on.body.h).should eq(1)
      # and the statusline row exactly occupies where off.status used to be free below.
      on.statusline.y.should eq(off.status.y)
    end
  end

  describe ".compute (clamping and tiny terminals)" do
    it "clamps inner_w/inner_h and body.h to 0 on a 0x0 terminal (never negative)" do
      l = Gori::Tui::Layout.compute(0, 0)
      # inner_w = max(0 - 4, 0) = 0; inner_h = max(0 - 2, 0) = 0.
      l.topbar.w.should eq(0)
      l.body.w.should eq(0)
      l.body.h.should eq(0)
      # widths/heights that are clamped must never be negative.
      {l.topbar, l.rule, l.menu, l.body, l.status, l.statusline}.each do |r|
        r.w.should be >= 0
        r.h.should be >= 0
      end
    end

    it "clamps inner_w to 0 when width is below twice the horizontal padding" do
      # width 3 < 2*HPAD(=4) => inner_w = max(3-4,0) = 0.
      l = Gori::Tui::Layout.compute(3, 40)
      l.topbar.w.should eq(0)
      l.body.w.should eq(0)
    end

    it "clamps body.h to 0 (default, reserved=4) when inner_h < reserved" do
      # height 5 => inner_h = 3 < 4 => body.h = max(3-4,0) = 0.
      l = Gori::Tui::Layout.compute(80, 5)
      l.body.h.should eq(0)
    end

    it "clamps body.h to 0 (statusline, reserved=5) when inner_h < reserved" do
      # NOTE: the checklist's "height=9 statusline -> body.h==0" is off: at height 9
      # inner_h=7, body.h=max(7-5,0)=2. The clamp only bites once inner_h<5, i.e.
      # height<7. Assert the real source contract with height=6 (inner_h=4).
      l = Gori::Tui::Layout.compute(80, 6, true)
      l.body.h.should eq(0)
    end

    it "verifies the checklist's height=9 statusline case actually yields body.h==2" do
      # Documents the corrected arithmetic so a future reader is not misled.
      l = Gori::Tui::Layout.compute(80, 9, true)
      l.body.h.should eq(2)
    end

    it "keeps clamped dims non-negative even when statusline is on at 0x0" do
      l = Gori::Tui::Layout.compute(0, 0, true)
      l.body.w.should eq(0)
      l.body.h.should eq(0)
      l.statusline.w.should eq(0)
      # inner_h==0 pushes status.y negative (y0+0-2 = -1). The doc only promises the
      # dims are clamped, not the coords, and usable? gates rendering at 40x8, so this
      # is out-of-contract territory: assert the actual value rather than a "no
      # negative coords" rule the source never claims.
      l.status.y.should eq(VPAD + 0 - 2) # -1
    end
  end

  describe ".compute (boundaries and extreme sizes)" do
    it "produces a 1-row body at the smallest usable height (8) with statusline off" do
      # inner_h = 8 - 2 = 6; body.h = 6 - 4 = 2.
      l = Gori::Tui::Layout.compute(40, 8)
      l.body.h.should eq(2)
      l.status.y.should eq(VPAD + (8 - 2*VPAD) - 1) # last inner row
    end

    it "handles Int32::MAX dimensions without overflowing (overflow-clamp analogue)" do
      # inner_w = max(MAX-4,0) = MAX-4; inner_h = MAX-2; y0+inner_h = MAX-1 (no wrap).
      l = Gori::Tui::Layout.compute(Int32::MAX, Int32::MAX)
      l.topbar.w.should eq(Int32::MAX - 2*HPAD)
      l.topbar.y.should eq(VPAD)
      l.body.h.should eq(Int32::MAX - 2*VPAD - 4)
      l.status.y.should eq(VPAD + (Int32::MAX - 2*VPAD) - 1)
      l.body.h.should be > 0
    end

    it "handles Int32::MAX dimensions with the statusline on" do
      l = Gori::Tui::Layout.compute(Int32::MAX, Int32::MAX, true)
      l.body.h.should eq(Int32::MAX - 2*VPAD - 5)
      l.statusline.w.should eq(Int32::MAX - 2*HPAD)
      l.statusline.y.should eq(VPAD + (Int32::MAX - 2*VPAD) - 1)
      l.status.y.should eq(VPAD + (Int32::MAX - 2*VPAD) - 2)
    end

    it "exposes the padding constants used to inset the chrome" do
      Gori::Tui::Layout::H_PADDING.should eq(2)
      Gori::Tui::Layout::V_PADDING.should eq(1)
    end
  end
end
