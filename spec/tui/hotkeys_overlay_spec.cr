require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

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

  it "does not read a Ctrl chord as the bare letter in browse mode" do
    # `elsif c = ev.char` had no modifier guard, and Event::Key#char falls back to
    # `key.to_char` — so every Ctrl+letter arrived here as the bare letter. ^X (stop/hex in
    # six scopes, high-traffic muscle memory) ran unbind_selected, setting the highlighted
    # verb to an explicit unbind that ↵ then persisted. ^R reset it, ^E armed capture, ^J/^K
    # moved. Every sibling dispatcher already guards this (Runner#handle_palette_key,
    # #handle_space_menu_key, TabController#handle_subtab_filter_key).
    o = fresh_overlay
    h = OverlayHarness.new(o)

    # char nil → the key.to_char fallback, which is the shape the Ctrl+letter parser emits.
    h.press(Termisu::Input::Key::LowerX, ctrl: true).should eq(:open)
    o.to_working[0].should be_empty
    # …and the Kitty shape, which attaches the char explicitly.
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true).should eq(:open)
    o.to_working[0].should be_empty

    h.press(Termisu::Input::Key::LowerR, ctrl: true).should eq(:open)
    o.to_working[0].should be_empty # ^R is not reset_selected
    h.press(Termisu::Input::Key::UpperR, 'R', ctrl: true).should eq(:open)
    o.to_working[0].should be_empty
    h.press(Termisu::Input::Key::LowerE, ctrl: true).should eq(:open)
    o.capturing?.should be_false # ^E does not arm capture

    # Positive control: the bare letters still do their job, so the guard cannot pass by
    # breaking the feature it protects.
    h.press(Termisu::Input::Key::LowerX, 'x').should eq(:open)
    working, _ = o.to_working
    working.size.should eq(1)
    working.values.first.should be_nil # explicit unbind
  ensure
    reset_settings
  end

  it "still records a modified chord in CAPTURE mode, where it is legitimate input" do
    # HotkeysOverlay is the one overlay whose raw_key_capture? is true, and only while
    # capturing — the browse-mode guard must not reach that path or the rebinder could no
    # longer bind any Ctrl/Alt chord at all.
    o = fresh_overlay
    o.begin_capture
    o.capturing?.should be_true
    o.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerY,
      Termisu::Input::Modifier::Alt, nil)).should eq(:stay)
    o.capturing?.should be_false
    o.to_working[0].values.first.should eq(Gori::Verb::Chord.new("y", alt: true))
  ensure
    reset_settings
  end

  it "treats ^X in capture as a binding attempt, never as the browse unbind" do
    o = fresh_overlay
    o.begin_capture
    o.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX,
      Termisu::Input::Modifier::Ctrl, nil)).should eq(:stay)
    # Whether the validator accepts ^X or rejects it inline is its business; what must never
    # happen is the browse-mode unbind writing a nil into the working copy.
    o.to_working[0].each_value { |v| v.should_not be_nil }
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
