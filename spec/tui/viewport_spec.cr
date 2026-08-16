require "../spec_helper"

include Gori::Tui

# The list-viewport arithmetic every scrolling list in the TUI now delegates to. It used to be
# re-derived at sixteen sites under eight signatures, and five of those copies had dropped the
# tail clamp — see `spec/tui/list_tail_clamp_spec.cr` for what that cost on screen. Here it is
# checked as what it is: a pure Int32 function, no terminal, no view.
describe Gori::Tui::Viewport do
  describe ".scroll_to_show" do
    it "leaves the window alone when the selection is already inside it" do
      Viewport.scroll_to_show(5, 3, 10, 100).should eq(3)
      Viewport.scroll_to_show(3, 3, 10, 100).should eq(3)  # the first drawn row
      Viewport.scroll_to_show(12, 3, 10, 100).should eq(3) # the last drawn row
    end

    it "scrolls UP to the selection when it sits above the window" do
      Viewport.scroll_to_show(2, 30, 10, 100).should eq(2)
      Viewport.scroll_to_show(0, 30, 10, 100).should eq(0)
    end

    it "scrolls DOWN one viewport back from the selection when it sits below" do
      # row 13 with a 10-row window ⇒ rows 4..13, so the selection is the LAST drawn row.
      Viewport.scroll_to_show(13, 3, 10, 100).should eq(4)
      Viewport.scroll_to_show(99, 0, 10, 100).should eq(90)
    end

    # A card under three rows, or a pane the layout gave nothing: there is no interior to
    # draw into, so the offset is returned UNTOUCHED rather than zeroed. A transient narrow
    # frame (a resize mid-drag) must not throw away where the operator was.
    it "returns the offset unchanged for a zero-or-negative height" do
      Viewport.scroll_to_show(50, 40, 0, 100).should eq(40)
      Viewport.scroll_to_show(50, 40, -3, 100).should eq(40)
    end

    it "collapses to 0 on an empty list" do
      Viewport.scroll_to_show(0, 0, 10, 0).should eq(0)
      Viewport.scroll_to_show(7, 25, 10, 0).should eq(0) # a stale cursor AND a stale offset
    end

    it "collapses to 0 when the whole list fits in the viewport" do
      Viewport.scroll_to_show(2, 0, 10, 3).should eq(0)
      Viewport.scroll_to_show(2, 7, 10, 3).should eq(0) # …even from a stale offset
    end

    # The half that kept getting left out. Neither rule above fires here: the cursor is still
    # inside the stale window, so only the clamp can pull the window back onto the rows that
    # are actually left.
    it "pulls a stale window back to the last full page when the list SHRANK" do
      # 44 rows became 3 under a window that had scrolled to 30 (IssuesView's `/` query).
      Viewport.scroll_to_show(2, 30, 10, 3).should eq(0)
      # 100 rows became 40 under the same window: the last full page starts at 30.
      Viewport.scroll_to_show(35, 60, 10, 40).should eq(30)
    end

    # The other way in: the list did not move, the PANE grew (a terminal resized taller).
    it "pulls the window back when the viewport grew past the rows below the offset" do
      Viewport.scroll_to_show(11, 9, 3, 12).should eq(9)  # short pane: rows 9..11
      Viewport.scroll_to_show(11, 9, 12, 12).should eq(0) # tall pane: the whole list fits
    end

    it "never returns a negative offset" do
      Viewport.scroll_to_show(-1, -5, 10, 100).should eq(0)
      Viewport.scroll_to_show(0, -5, 10, 0).should eq(0)
    end

    # `render` runs this EVERY frame on an unchanged list, so a second application that moved
    # anything would be a view that scrolls while nothing happens.
    it "is idempotent" do
      cases = [
        {5, 3, 10, 100}, {2, 30, 10, 3}, {99, 0, 10, 100}, {35, 60, 10, 40},
        {11, 9, 12, 12}, {7, 25, 10, 0}, {50, 40, 0, 100}, {2, 7, 10, 3},
      ]
      cases.each do |(sel, scroll, h, count)|
        once = Viewport.scroll_to_show(sel, scroll, h, count)
        twice = Viewport.scroll_to_show(sel, once, h, count)
        twice.should eq(once)
      end
    end

    # The clamp must never fight the rule above it: for any selection that is IN the list, the
    # window it lands in has to contain the selection.
    it "keeps an in-range selection on screen across every offset it could start from" do
      count = 40
      h = 7
      (0...count).each do |sel|
        [0, 1, 5, 20, 33, 39, 120].each do |from|
          s = Viewport.scroll_to_show(sel, from, h, count)
          s.should be >= 0
          s.should be <= {count - h, 0}.max
          (sel >= s && sel < s + h).should be_true
        end
      end
    end
  end

  # Four lists (the Setup wizard's and Settings' theme lists, the JWT ATTACKS list, and
  # PreferencesView) derived this the other way round — clamp to a valid window FIRST, then
  # nudge to keep the selection visible, with no clamp after. `scroll_to_show` follows THEN
  # clamps. The two orders are not obviously the same, and four call sites were migrated on the
  # strength of them being the same, so the claim is checked rather than argued: exhaustively,
  # over every list length, viewport height, in-range selection and starting offset in a range
  # that covers underfilled, exactly-filled and overfilled windows.
  #
  # The precondition is REAL and each of those call sites establishes it: the selection must be
  # in range. `sel = names.index(…) || 0` over a non-empty list, or an explicit
  # `@atk_sel.clamp(0, attacks.size - 1)` on the line above.
  describe "clamp-then-follow equivalence" do
    it "agrees with the pre-migration ordering for every in-range selection" do
      clamp_first = ->(sel : Int32, scroll : Int32, vp : Int32, count : Int32) do
        s = scroll.clamp(0, {count - vp, 0}.max)
        s = sel if sel < s
        s = sel - vp + 1 if sel >= s + vp
        s
      end

      checked = 0
      (1..14).each do |count|
        (1..14).each do |vp|
          (0...count).each do |sel|
            (-2..20).each do |scroll|
              checked += 1
              Viewport.scroll_to_show(sel, scroll, vp, count)
                .should eq(clamp_first.call(sel, scroll, vp, count))
            end
          end
        end
      end
      checked.should be > 20_000 # the sweep really ran
    end
  end

  describe ".clamp_scroll" do
    it "clamps a stale offset to the last full page" do
      Viewport.clamp_scroll(60, 10, 40).should eq(30)
      Viewport.clamp_scroll(5, 10, 40).should eq(5)
    end

    it "collapses to 0 when the list fits, is empty, or the offset went negative" do
      Viewport.clamp_scroll(7, 10, 3).should eq(0)
      Viewport.clamp_scroll(7, 10, 0).should eq(0)
      Viewport.clamp_scroll(-2, 10, 40).should eq(0)
    end

    it "is idempotent" do
      once = Viewport.clamp_scroll(60, 10, 40)
      Viewport.clamp_scroll(once, 10, 40).should eq(once)
    end
  end
end
