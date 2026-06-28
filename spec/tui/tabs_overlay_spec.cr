require "../spec_helper"

include Gori::Tui

# The settings:tabs overlay must degrade on small terminals instead of becoming an
# invisible-but-input-capturing modal, and its windowed list draw + click hit-test must
# stay in sync (both derive the scroll from list_window).
describe TabsOverlay do
  it "returns a box on a normal area and nil only when genuinely too small" do
    o = TabsOverlay.new
    o.overlay_box(Rect.new(0, 0, 80, 24)).should_not be_nil
    o.overlay_box(Rect.new(0, 0, 80, 5)).should be_nil  # area.h-2 = 3 < 6 rows
    o.overlay_box(Rect.new(0, 0, 20, 24)).should be_nil # area.w-4 = 16 < 24 cols
  end

  it "windows a long catalog on a short area so row_at maps to the scrolled rows" do
    o = TabsOverlay.new # 9 catalog tabs by default
    o.select_move(100)  # selection clamps to the last index (8)
    box = o.overlay_box(Rect.new(0, 0, 60, 9)).not_nil! # short: only a few rows fit
    # the top visible row is scrolled past index 0 to keep the last-selected row on screen
    o.row_at(box, box.x + 5, box.y + 2).not_nil!.should be > 0
    # a click below the visible list rejects (no phantom selection)
    o.row_at(box, box.x + 5, box.bottom).should be_nil
  end

  it "shows every catalog row (start at 0) when the area is tall enough" do
    o = TabsOverlay.new
    box = o.overlay_box(Rect.new(0, 0, 60, 40)).not_nil!
    o.row_at(box, box.x + 5, box.y + 2).should eq(0) # no scroll → first row is index 0
  end

  it "reverts the working copy to the factory default order and visibility" do
    default = Chrome.reconcile([] of {String, Bool}).map { |(s, _, v)| {s.to_s, v} }
    o = TabsOverlay.new
    o.set_selected(0)
    o.move_selected(1) # reorder away from the default
    o.to_prefs.should_not eq(default)
    o.reset_to_defaults
    o.to_prefs.should eq(default) # back to the canonical catalog order/visibility
  end
end
