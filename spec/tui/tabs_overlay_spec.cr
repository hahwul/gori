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
    default = Chrome.bar_partition(Chrome.reconcile([] of {String, Bool})).map { |(s, _, v)| {s.to_s, v} }
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
    # The list is partitioned, so the bar is the top N rows, the seam is the row after them,
    # and the first tab off the bar is the row after that.
    on_bar = o.to_prefs.count { |(_, vis)| vis }
    o.slot_of(on_bar - 1).should eq(on_bar)
    o.slot_of(on_bar).should be_nil
    backend.row(first + on_bar).should contain("off the bar") # the seam, in place
    off = first + on_bar + 1
    backend.row(off)[box.x + 3].should eq(' ') # off the bar: an empty column
    backend.fg_at(box.x + 6, off).should eq(Theme.text)
    backend.fg_at(box.x + 6, off).should_not eq(Theme.muted)
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

  # Order and visibility used to be two things you edited with two keys, in a list where an
  # off-bar tab could sit BETWEEN two slots — so "slot 3" and "third row" were different facts.
  # Partitioned, they are one fact, and these are the three halves of that claim: the list is
  # partitioned, a move across the seam trades, and `space` is the move that changes the count.
  it "keeps the bar above the seam and everything else below it" do
    o = TabsOverlay.new
    vis = o.to_prefs.map { |(_, v)| v }
    vis.index(false).not_nil!.should eq(vis.count(true)) # every true precedes every false
    o.slot_of(0).should eq(1)
    o.slot_of(vis.count(true)).should be_nil # the first row under the seam wears no digit
  end

  it "trades a tab in and one out when a move crosses the seam" do
    o = TabsOverlay.new
    on_bar = o.to_prefs.count { |(_, v)| v }
    last_slot = o.to_prefs[on_bar - 1][0] # the tab holding the final slot
    first_off = o.to_prefs[on_bar][0]     # the one just under the seam

    o.set_selected(on_bar)
    o.move_selected(-1) # ⇧K across the seam

    o.to_prefs[on_bar - 1].should eq({first_off, true}) # came up onto the bar…
    o.to_prefs[on_bar].should eq({last_slot, false})    # …and pushed the other one off
    o.to_prefs.count { |(_, v)| v }.should eq(on_bar)   # the count never moved
    o.selected.should eq(on_bar - 1)                    # the cursor followed the tab
    o.slot_of(on_bar - 1).should eq(on_bar)
  end

  it "sends a row across the seam on space, which is what changes the count" do
    slots = Gori::Settings.tab_slots?
    begin
      Gori::Settings.tab_slots = false # no cap, so the send is not refused
      o = TabsOverlay.new
      on_bar = o.to_prefs.count { |(_, v)| v }
      sym = o.to_prefs[on_bar][0] # the first row under the seam

      o.set_selected(on_bar)
      o.toggle_selected.should be_true

      o.to_prefs[on_bar].should eq({sym, true}) # landed as the last slot, in place
      o.to_prefs.count { |(_, v)| v }.should eq(on_bar + 1)
      o.selected.should eq(on_bar) # the selection followed it across

      o.toggle_selected.should be_true # and back again, to where it came from
      o.to_prefs[on_bar].should eq({sym, false})
      o.to_prefs.count { |(_, v)| v }.should eq(on_bar)
    ensure
      Gori::Settings.tab_slots = slots
    end
  end

  it "names the move that works when the bar is full" do
    o = TabsOverlay.new
    o.set_selected(o.to_prefs.count { |(_, v)| v }) # the first row under a full bar
    o.toggle_selected.should be_false
    # The old refusal said "take one off first" — two keystrokes for what ⇧K does in one.
    o.hint.should contain("⇧K/⇧J")
  end

  it "does not select the seam when it is clicked" do
    o = TabsOverlay.new
    area = Rect.new(0, 0, 60, 40)
    box = o.overlay_box(area).not_nil!
    on_bar = o.to_prefs.count { |(_, v)| v }
    o.row_at(box, box.x + 5, box.y + 2 + on_bar).should be_nil # the seam itself
    o.row_at(box, box.x + 5, box.y + 2 + on_bar - 1).should eq(on_bar - 1)
    o.row_at(box, box.x + 5, box.y + 2 + on_bar + 1).should eq(on_bar) # first row below it
  end

  # `Chrome.render_status` truncates the hint to whatever the status chips leave it, so a
  # clause added at the front costs one at the back — and the ones at the back are `↵ save`
  # and `esc cancel`. No hint in the app survives an 80-column row whole; the bound here just
  # keeps this card from being the one that spends the most columns before reaching its keys.
  it "keeps the hint inside the width the status bar will draw" do
    Screen.display_width(TabsOverlay.new.hint).should be <= 68
  end

  # The seam is the only place the editor answers "where did the tab I just moved down go",
  # so the `0` half of its label is the half that has to survive a narrow card.
  it "keeps `0` on the seam when the card is too narrow for the whole label" do
    o = TabsOverlay.new
    area = Rect.new(0, 0, 38, 40)
    box = o.overlay_box(area).not_nil!
    box.w.should be < 36 # too narrow for " off the bar · 0 opens these "
    backend = MemoryBackend.new(area.w, area.h)
    o.render(Screen.new(backend), area)
    seam = backend.row(box.y + 2 + o.to_prefs.count { |(_, vis)| vis })
    seam.should contain("0 opens these")
    seam.should_not contain("off the bar")
  end

  it "does not offer Evidence before the project has its first snapshot" do
    unavailable = TabsOverlay.new(false)
    available = TabsOverlay.new(true)

    unavailable.to_prefs.map(&.[0]).should_not contain("evidence")
    available.to_prefs.map(&.[0]).should contain("evidence")
    unavailable.entry_count.should eq(available.entry_count - 1)
  end
end
