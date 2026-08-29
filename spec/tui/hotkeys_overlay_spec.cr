require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def fresh_overlay : HotkeysOverlay
  Gori::Settings.keymap_os = "auto"
  Gori::Settings.keymap_overrides = {} of String => Array(String)
  HotkeysOverlay.new(Gori::Verbs.registry)
end

private def start_hotkey_search(h : OverlayHarness) : Nil
  h.press(Termisu::Input::Key::Slash, '/')
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

  # `reset_all` is what ⇧R runs, and its footer promises the BINDINGS — an operator who pinned
  # an OS profile did so on purpose, so it leaves the pin. The Preferences modal's ^R promises
  # both ("drop every rebinding and the OS profile pin"), which is why `reset_profile` exists
  # separately for that arm to call; folding it into reset_all would make ⇧R lie instead.
  it "keeps the OS profile pin on reset_all, and drops it only on reset_profile" do
    Gori::Settings.keymap_os = "linux"
    o = HotkeysOverlay.new(Gori::Verbs.registry)
    o.reset_all
    o.to_working[1].should eq("linux")

    o.reset_profile
    o.to_working[1].should eq(Gori::Settings::DEFAULT_KEYMAP_OS)
  ensure
    reset_settings
  end

  it "selects only binding rows (headers are skipped) and row_at ignores headers" do
    o = fresh_overlay
    box = o.overlay_box(Rect.new(0, 0, 80, 50)).not_nil!
    # The search row + divider precede the list; its first row is the first scope HEADER.
    o.row_at(box, box.x + 5, box.y + 3).should be_nil
    # a row further down lands on a binding (non-nil index)
    o.row_at(box, box.x + 5, box.y + 4).should_not be_nil
  ensure
    reset_settings
  end

  describe "explicit / search" do
    after_each do
      reset_settings
    end

    it "matches visible title and binding text while retaining the scope header" do
      by_title = fresh_overlay
      ht = OverlayHarness.new(by_title)
      start_hotkey_search(ht)
      ht.type("toggle capture")
      by_title.searching?.should be_true
      ht.rendered?("GLOBAL").should be_true
      ht.rendered?("Toggle capture").should be_true

      by_binding = fresh_overlay
      hb = OverlayHarness.new(by_binding)
      start_hotkey_search(hb)
      hb.type("shift-s")
      hb.rendered?("Toggle scope lens").should be_true
    end

    it "shows IME preedit only after / activates search" do
      o = fresh_overlay
      h = OverlayHarness.new(o)
      h.preedit("한")
      h.rendered?("한").should be_false
      start_hotkey_search(h)
      h.preedit("한")
      h.rendered?("한").should be_true
      o.hint.should contain("type to search")
    end

    it "accepts a match with enter and returns to the full editor at that binding" do
      o = fresh_overlay
      h = OverlayHarness.new(o)
      start_hotkey_search(h)
      h.type("toggle capture")
      h.press(Termisu::Input::Key::Enter).should eq(:open)
      o.searching?.should be_false

      h.press(Termisu::Input::Key::LowerE, 'e')
      o.capturing?.should be_true
      h.press(Termisu::Input::Key::LowerY, 'y', alt: true)
      o.to_working[0]["capture.toggle"].should eq(Gori::Verb::Chord.new("y", alt: true))
    end

    it "cancels to the row focused before search, then a second esc closes" do
      control = fresh_overlay
      control.select_move(1)
      control.unbind_selected
      expected = control.to_working[0].keys.first

      o = fresh_overlay
      o.select_move(1)
      h = OverlayHarness.new(o)
      start_hotkey_search(h)
      h.type("toggle capture")
      # The hint has to name THIS esc, not the browse-mode one: here it clears the query and
      # the card stays up, where in browse mode esc discards the working copy and closes.
      # The popup card next door already words the two apart, and a hint that says "cancel"
      # over a key that does not cancel is the drift the sibling specs exist to catch.
      o.hint.should contain("esc clear")
      o.hint.should_not contain("esc cancel")
      h.press(Termisu::Input::Key::Escape).should eq(:open)
      o.searching?.should be_false
      o.hint.should contain("esc cancel")
      o.unbind_selected
      o.to_working[0].keys.first.should eq(expected)
      h.press(Termisu::Input::Key::Escape).should eq(:closed)
    end

    it "drops the pane's caret when the terminal is too small to draw the card at all" do
      # The degraded line is the only thing on screen, but the pane underneath has already
      # drawn its own editor caret into this frame — and the shell hands the hardware cursor
      # to whatever `desired_cursor` last held. Without clearing it here the caret blinks
      # through the "larger window" message, at a column belonging to a hidden pane.
      screen = Screen.new(MemoryBackend.new(30, 6))
      screen.cursor(4, 2)
      fresh_overlay.render(screen, Rect.new(0, 0, 30, 6))
      screen.desired_cursor.should be_nil
    end

    it "keeps search open and safe when nothing matches" do
      o = fresh_overlay
      h = OverlayHarness.new(o)
      start_hotkey_search(h)
      h.type("zzzznotahotkey")
      h.rendered?("no hotkeys match").should be_true
      h.press(Termisu::Input::Key::Enter).should eq(:open)
      o.searching?.should be_true
      o.to_working[0].should be_empty
    end

    it "treats browse mnemonics as query text and ignores modified chords" do
      o = fresh_overlay
      h = OverlayHarness.new(o)
      start_hotkey_search(h)
      h.type("exrRjk")
      h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true)
      h.press(Termisu::Input::Key::LowerR, 'r', alt: true)
      o.searching?.should be_true
      o.capturing?.should be_false
      o.to_working[0].should be_empty
      o.to_working[1].should eq("auto")
    end

    it "keeps slash bindable while raw capture has precedence" do
      o = fresh_overlay
      o.begin_capture
      o.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Slash, char: '/')).should eq(:stay)
      o.searching?.should be_false
      o.capturing?.should be_false
      o.to_working[0].values.first.should eq(Gori::Verb::Chord.new("/"))
    end
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
