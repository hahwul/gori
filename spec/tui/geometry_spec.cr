require "../spec_helper"

describe Gori::Tui::Rect do
  describe "#initialize / getters" do
    it "exposes the four fields verbatim, including negatives" do
      r = Gori::Tui::Rect.new(-3, -4, 7, 9)
      r.x.should eq(-3)
      r.y.should eq(-4)
      r.w.should eq(7)
      r.h.should eq(9)
    end

    it "gives structs value equality across identical fields" do
      Gori::Tui::Rect.new(1, 2, 3, 4).should eq(Gori::Tui::Rect.new(1, 2, 3, 4))
      Gori::Tui::Rect.new(1, 2, 3, 4).should_not eq(Gori::Tui::Rect.new(1, 2, 3, 5))
    end
  end

  describe "#right" do
    it "is x + w (exclusive edge)" do
      Gori::Tui::Rect.new(2, 3, 5, 4).right.should eq(7)
    end

    it "collapses to x when width is zero" do
      Gori::Tui::Rect.new(10, 0, 0, 5).right.should eq(10)
    end

    it "can fall left of x when width is negative" do
      Gori::Tui::Rect.new(10, 0, -3, 5).right.should eq(7)
    end

    it "handles a rect anchored at the origin" do
      Gori::Tui::Rect.new(0, 0, 1, 1).right.should eq(1)
    end
  end

  describe "#bottom" do
    it "is y + h (exclusive edge)" do
      Gori::Tui::Rect.new(2, 3, 5, 4).bottom.should eq(7)
    end

    it "collapses to y when height is zero" do
      Gori::Tui::Rect.new(0, 10, 5, 0).bottom.should eq(10)
    end

    it "can fall above y when height is negative" do
      Gori::Tui::Rect.new(0, 10, 5, -4).bottom.should eq(6)
    end
  end

  describe "#empty?" do
    it "is true when width is zero" do
      Gori::Tui::Rect.new(0, 0, 0, 5).empty?.should be_true
    end

    it "is true when height is zero" do
      Gori::Tui::Rect.new(0, 0, 5, 0).empty?.should be_true
    end

    it "is true when both dimensions are zero" do
      Gori::Tui::Rect.new(0, 0, 0, 0).empty?.should be_true
    end

    it "is true when width is negative" do
      Gori::Tui::Rect.new(0, 0, -1, 5).empty?.should be_true
    end

    it "is true when height is negative" do
      Gori::Tui::Rect.new(0, 0, 5, -1).empty?.should be_true
    end

    it "is false for a 1x1 rect" do
      Gori::Tui::Rect.new(0, 0, 1, 1).empty?.should be_false
    end

    it "is false for a normal positive rect regardless of origin" do
      Gori::Tui::Rect.new(-5, -5, 3, 3).empty?.should be_false
    end
  end

  describe "#contains?" do
    # Rect spans x in [2,7) and y in [3,7).
    it "includes the top-left corner (inclusive origin)" do
      Gori::Tui::Rect.new(2, 3, 5, 4).contains?(2, 3).should be_true
    end

    it "includes an interior point" do
      Gori::Tui::Rect.new(2, 3, 5, 4).contains?(4, 5).should be_true
    end

    it "excludes the right edge (exclusive, off-by-one)" do
      Gori::Tui::Rect.new(2, 3, 5, 4).contains?(7, 3).should be_false
    end

    it "excludes the bottom edge (exclusive, off-by-one)" do
      Gori::Tui::Rect.new(2, 3, 5, 4).contains?(2, 7).should be_false
    end

    it "includes the last cell just inside the exclusive edges" do
      Gori::Tui::Rect.new(2, 3, 5, 4).contains?(6, 6).should be_true
    end

    it "excludes points left of x and above y" do
      r = Gori::Tui::Rect.new(2, 3, 5, 4)
      r.contains?(1, 5).should be_false
      r.contains?(4, 2).should be_false
    end

    it "excludes the bottom-right exclusive corner" do
      Gori::Tui::Rect.new(2, 3, 5, 4).contains?(7, 7).should be_false
    end

    it "contains nothing when the rect is empty (zero width)" do
      r = Gori::Tui::Rect.new(2, 3, 0, 4)
      r.contains?(2, 3).should be_false
      r.contains?(2, 5).should be_false
    end

    it "contains nothing when the rect is empty (zero height)" do
      r = Gori::Tui::Rect.new(2, 3, 5, 0)
      r.contains?(4, 3).should be_false
    end

    it "hit-tests correctly around a negative origin" do
      r = Gori::Tui::Rect.new(-4, -3, 3, 2)
      r.contains?(-4, -3).should be_true  # inclusive top-left
      r.contains?(-2, -2).should be_true  # last interior cell
      r.contains?(-1, -3).should be_false # right edge exclusive (x+w == -1)
      r.contains?(-4, -1).should be_false # bottom edge exclusive (y+h == -1)
      r.contains?(-5, -3).should be_false # left of x
    end
  end

  describe "#inset" do
    it "shrinks inward by dx/dy on each side" do
      Gori::Tui::Rect.new(0, 0, 10, 10).inset(2, 1).should eq(Gori::Tui::Rect.new(2, 1, 6, 8))
    end

    it "returns a distinct value-equal Rect (immutability)" do
      base = Gori::Tui::Rect.new(0, 0, 10, 10)
      inset = base.inset(2, 1)
      base.should eq(Gori::Tui::Rect.new(0, 0, 10, 10)) # original untouched
      inset.w.should eq(6)
      inset.h.should eq(8)
    end

    it "supports asymmetric dx/dy" do
      Gori::Tui::Rect.new(5, 5, 20, 12).inset(3, 0).should eq(Gori::Tui::Rect.new(8, 5, 14, 12))
    end

    it "clamps width and height at zero rather than going negative" do
      r = Gori::Tui::Rect.new(0, 0, 3, 3).inset(5, 5)
      r.x.should eq(5)
      r.y.should eq(5)
      r.w.should eq(0)
      r.h.should eq(0)
    end

    it "clamps only the dimension that overshoots" do
      # dx=5 overshoots w=3 -> 0; dy=1 keeps h=3-2 -> 1
      Gori::Tui::Rect.new(0, 0, 3, 3).inset(5, 1).should eq(Gori::Tui::Rect.new(5, 1, 0, 1))
    end

    it "produces an empty rect once clamped" do
      Gori::Tui::Rect.new(0, 0, 3, 3).inset(5, 5).empty?.should be_true
    end

    it "grows the rect when dx/dy are negative (max-with-0 contract)" do
      # w - 2*dx with dx=-1 -> w + 2; origin shifts by dx.
      Gori::Tui::Rect.new(0, 0, 10, 10).inset(-1, -1).should eq(Gori::Tui::Rect.new(-1, -1, 12, 12))
    end

    it "is a no-op for zero inset" do
      Gori::Tui::Rect.new(4, 5, 6, 7).inset(0, 0).should eq(Gori::Tui::Rect.new(4, 5, 6, 7))
    end

    it "lands exactly on zero width at the clamp boundary" do
      # w=4, dx=2 -> 4-4 == 0 (exactly clamped, not below)
      Gori::Tui::Rect.new(0, 0, 4, 4).inset(2, 2).should eq(Gori::Tui::Rect.new(2, 2, 0, 0))
    end

    it "leaves a 1-cell sliver just before the clamp boundary" do
      # w=5, dx=2 -> 5-4 == 1
      Gori::Tui::Rect.new(0, 0, 5, 5).inset(2, 2).should eq(Gori::Tui::Rect.new(2, 2, 1, 1))
    end
  end
end
