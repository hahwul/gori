require "../spec_helper"

include Gori::Tui

private def fresh_overlay : HotkeysOverlay
  Gori::Settings.keymap_os = "auto"
  Gori::Settings.keymap_overrides = {} of String => Array(String)
  HotkeysOverlay.new(Gori::Verbs.registry)
end

# The settings:hotkeys overlay edits a working copy; its windowed draw + click hit-test
# stay in sync and the browse/capture state machine validates rebinds inline.
describe HotkeysOverlay do
  it "returns a box on a normal area and nil only when genuinely too small" do
    o = fresh_overlay
    o.overlay_box(Rect.new(0, 0, 80, 30)).should_not be_nil
    o.overlay_box(Rect.new(0, 0, 80, 6)).should be_nil  # area.h-2 = 4 < 7
    o.overlay_box(Rect.new(0, 0, 30, 30)).should be_nil # area.w-4 = 26 < 32
  ensure
    reset_settings
  end

  it "selects only binding rows (headers are skipped) and row_at ignores headers" do
    o = fresh_overlay
    box = o.overlay_box(Rect.new(0, 0, 80, 50)).not_nil!
    # the first interior row is the first scope HEADER → not a click target
    o.row_at(box, box.x + 5, box.y + 2).should be_nil
    # a row further down lands on a binding (non-nil index)
    o.row_at(box, box.x + 5, box.y + 3).should_not be_nil
  ensure
    reset_settings
  end

  it "captures a valid chord into the working copy and leaves capture mode" do
    o = fresh_overlay
    o.capturing?.should be_false
    o.begin_capture
    o.capturing?.should be_true
    o.apply_capture(Gori::Verb::Chord.new("y", alt: true)) # alt-y: not reserved, no Global conflict
    o.capturing?.should be_false
    working, _ = o.to_working
    working.size.should eq(1)
    working.values.first.should eq(Gori::Verb::Chord.new("y", alt: true))
  ensure
    reset_settings
  end

  it "stays in capture mode and records nothing on a reserved key" do
    o = fresh_overlay
    o.begin_capture
    o.apply_capture(Gori::Verb::Chord.new("c", ctrl: true)) # ^C: reserved (quit)
    o.capturing?.should be_true
    o.to_working[0].should be_empty
  ensure
    reset_settings
  end

  it "unbinds (nil) and resets (removes) the selected binding in the working copy" do
    o = fresh_overlay
    o.unbind_selected
    working, _ = o.to_working
    working.size.should eq(1)
    working.values.first.should be_nil # explicit unbind
    o.reset_selected
    o.to_working[0].should be_empty # back to default
  ensure
    reset_settings
  end

  it "cycles the OS profile through the known set" do
    o = fresh_overlay
    o.to_working[1].should eq("auto")
    o.cycle_profile(1)
    Gori::Hotkeys::PROFILES.should contain(o.to_working[1])
    o.to_working[1].should_not eq("auto")
  ensure
    reset_settings
  end
end

private def reset_settings
  Gori::Settings.keymap_os = "auto"
  Gori::Settings.keymap_overrides = {} of String => Array(String)
end
