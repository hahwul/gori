require "../spec_helper"
require "../support/memory_backend"

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
    o = TabsOverlay.new                                 # 9 catalog tabs by default
    o.select_move(100)                                  # selection clamps to the last index (8)
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

  # The number IS the state. A `✓` beside a number said it twice, and the `·` it paired with on
  # an off-bar row said a third thing that was false — that the tab was switched off, when `0`
  # opens it either way. The one mark left is the `✓` for an UNCAPPED bar past the ninth slot,
  # where a tab is on the bar but there is no digit left to print.
  it "lets the slot number carry the state, with one ink for every label" do
    o = TabsOverlay.new
    box = o.overlay_box(Rect.new(0, 0, 60, 40)).not_nil!
    backend = MemoryBackend.new(60, 40)
    o.render(Screen.new(backend), Rect.new(0, 0, 60, 40))

    first = box.y + 2
    backend.row(first)[box.x + 3].should eq('1') # slot 1
    backend.row(first).should_not contain("✓")   # …and nothing restating it
    off = (0...o.entry_count).find { |i| o.slot_of(i).nil? }.not_nil!
    backend.row(first + off)[box.x + 3].should eq(' ') # off the bar: an empty column
    backend.fg_at(box.x + 6, first + off).should eq(Theme.text)
    backend.fg_at(box.x + 6, first + off).should_not eq(Theme.muted)
  end

  it "marks an on-bar tab past the ninth slot, where no digit is left to print" do
    slots = Gori::Settings.tab_slots?
    begin
      Gori::Settings.tab_slots = false # the unbounded bar: more visible tabs than there are digits
      o = TabsOverlay.new
      o.entry_count.times do |i| # put the whole catalog on the bar — no cap to refuse it
        o.set_selected(i)
        o.toggle_selected unless o.to_prefs[i][1]
      end
      tenth = (0...o.entry_count).find { |i| o.slot_of(i).nil? }.not_nil!
      tenth.should eq(Chrome::MAX_SLOTS) # the tenth row is the first past the digits
      o.to_prefs[tenth][1].should be_true
      backend = MemoryBackend.new(60, 40)
      box = o.overlay_box(Rect.new(0, 0, 60, 40)).not_nil!
      o.render(Screen.new(backend), Rect.new(0, 0, 60, 40))
      backend.row(box.y + 2 + tenth)[box.x + 3].should eq('✓')
    ensure
      Gori::Settings.tab_slots = slots
    end
  end

  it "does not offer Evidence before the project has its first snapshot" do
    unavailable = TabsOverlay.new(false)
    available = TabsOverlay.new(true)

    unavailable.to_prefs.map(&.[0]).should_not contain("evidence")
    available.to_prefs.map(&.[0]).should contain("evidence")
    unavailable.entry_count.should eq(available.entry_count - 1)
  end
end
