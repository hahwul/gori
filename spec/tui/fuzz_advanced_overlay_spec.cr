require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def akey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def blank_snapshot : Gori::Tui::AdvancedSnapshot
  Gori::Tui::AdvancedSnapshot.new(
    conc: "20", rate: "", timeout: "", retries: "0",
    follow: false, calibrate: false, keep_alive: true,
    m_status: "", m_size: "", m_words: "", m_regex: "",
    f_status: "", f_size: "", f_words: "", f_regex: "")
end

describe Gori::Tui::FuzzAdvancedOverlay do
  it "edits the concurrency text row and reflects it in the snapshot" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    2.times { ov.handle_key(akey(Termisu::Input::Key::Backspace)) } # clear "20"
    "50".each_char { |c| ov.handle_key(akey(Termisu::Input::Key::LowerA, c)) }
    ov.snapshot.conc.should eq("50")
  end

  it "toggles a boolean row with space (←/→ on text rows never toggles it)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    4.times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # → Follow redirects (row 4)
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.follow.should be_true
  end

  it "esc returns :commit so the open-site's closure writes the snapshot back" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.handle_key(akey(Termisu::Input::Key::Escape)).should eq(:commit)
  end

  it "renders every field on its own labeled row" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("ADVANCED").should be_true
    backend.contains?("Concurrency").should be_true
    backend.contains?("Match status").should be_true
    backend.contains?("Filter regex").should be_true
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot)).assert_chrome(OverlayKind::FuzzAdvanced, "ADVANCED")
  end

  it "esc applies the edited snapshot through the injected closure" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    applied = [] of String
    h = OverlayHarness.new(ov)
    h.on_commit do
      applied << ov.snapshot.conc
      true
    end
    2.times { h.press(Termisu::Input::Key::Backspace) } # clear "20"
    h.type("50").should eq(:open)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    applied.should eq(["50"])
  end

  it "↵ advances a row and, on the LAST row, does nothing at all" do
    # Pins the PRE-EXISTING behaviour the migration preserved: handle_key discards the
    # case's value, so handle_text's commit-on-the-last-row never reaches the shell. Only
    # esc and a click-away apply. See the note on FuzzAdvancedOverlay#handle_key.
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Enter).should eq(:open) # row 0 → row 1
    h.commits.should eq(0)
    (FuzzAdvancedOverlay::ROWS.size - 1).times { h.press(Termisu::Input::Key::Down) }
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
    # …and the last row stays FOCUSED rather than stepping out of ROWS' range: what gets
    # typed next still lands in Filter regex.
    h.type("x").should eq(:open)
    ov.snapshot.f_regex.should eq("x")
  end

  it "a click outside the card APPLIES rather than dismissing" do
    # This modal has no cancel: apply_close_fuzz_advanced was the shell's click-away path too.
    away = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(1)
  end

  it "a click inside focuses the row under the pointer and stays open" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.click_in_box(2, 5).should eq(:open) # rows start at box.y + 1 → row index 4 (Follow redirects)
    h.commits.should eq(0)
    h.press(Termisu::Input::Key::Space)
    ov.snapshot.follow.should be_true
  end

  it "the wheel moves the selected row (base handle_wheel delegates to move)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.wheel(5) # → Calibrate (row 5)
    h.press(Termisu::Input::Key::Space)
    ov.snapshot.calibrate.should be_true
    ov.snapshot.follow.should be_false
  end

  it "routes IME preedit into the focused text row" do
    h = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot))
    h.preedit("한")
    h.rendered?("한").should be_true
  end

  it "APPLIES a click when the window is too small to draw the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. This
    # editor diverges from the base class on purpose: the pre-seam shell ran
    # `apply_close_fuzz_advanced(ov) if box.nil?`, so an unrenderable card must APPLY, and
    # the inherited :cancel would silently drop knobs the user had already edited.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:commit)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(1)
    h.rendered?("advanced editor").should be_true
  end

  it "toggles keep-alive, which starts on" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.snapshot.keep_alive.should be_true
    6.times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # → Keep-alive (row 6)
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.keep_alive.should be_false
    ov.snapshot.calibrate.should be_false # the neighbouring toggle is untouched
    ov.snapshot.follow.should be_false
  end

  it "offsets a click by the scroll position once the list has scrolled" do
    # Production hands an overlay `layout.body` — 6 rows shorter and offset from the screen —
    # so this 18-row card renders clipped to 14 and the row list must scroll to reach the
    # bottom fields. That scroll is what makes handle_click's `@scroll + i` load-bearing:
    # @scroll only ever advances inside `render`, so a click example that never renders
    # leaves it at 0, where `@scroll + i` and plain `i` are indistinguishable.
    body = Gori::Tui::Rect.new(2, 4, 76, 18)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: body)
    h.box.should_not be_nil
    h.rendered?("Filter regex").should be_false # off-screen until the list scrolls
    (FuzzAdvancedOverlay::ROWS.size - 1).times { h.press(Termisu::Input::Key::Down) }
    h.rendered?("Filter regex").should be_true # this render is what advances @scroll
    h.type("x")

    # The list has scrolled, so the first VISIBLE row is no longer ROWS[0] (Concurrency):
    # the 4th visible row is "Match status", which is where this click must land.
    h.click_in_box(2, 4).should eq(:open)
    h.type("9")
    ov.snapshot.m_status.should eq("9") # lands in Retries if the click ignores @scroll
    ov.snapshot.retries.should eq("0")  # …and the un-scrolled rows stay untouched
    ov.snapshot.conc.should eq("20")
    ov.snapshot.f_regex.should eq("x")

    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(1)
  end
end
