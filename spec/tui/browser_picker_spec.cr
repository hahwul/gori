require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def browser_found(id : String, name : String, kind : Gori::Browser::Kind) : Gori::Browser::Found
  Gori::Browser::Found.new(id, name, kind, "/path/#{id}")
end

private BROWSERS = [
  browser_found("chrome", "Google Chrome", Gori::Browser::Kind::Chromium),
  browser_found("firefox", "Firefox", Gori::Browser::Kind::Firefox),
]

describe Gori::Tui::BrowserPicker do
  it "moves the selection within bounds" do
    picker = BrowserPicker.new(BROWSERS)
    picker.selected.should eq(0)
    picker.move(-1)
    picker.selected.should eq(0) # clamp at the top
    picker.move(1)
    picker.selected.should eq(1)
    picker.move(1)
    picker.selected.should eq(1) # clamp at the bottom
    picker.selected_browser.try(&.id).should eq("firefox")
  end

  it "renders the title and each browser name" do
    backend = MemoryBackend.new(80, 14)
    BrowserPicker.new(BROWSERS).render(Screen.new(backend), Rect.new(0, 0, 80, 14))
    backend.contains?("OPEN BROWSER").should be_true
    backend.contains?("Google Chrome").should be_true
    backend.contains?("Firefox").should be_true
  end

  # Firefox trusts the CA via a `certutil` NSS import (see Browser.setup_firefox_profile);
  # without it the profile only gets proxy prefs and HTTPS shows cert errors. Warn on the
  # row BEFORE launch — the post-launch toast is easy to miss once focus jumps to the
  # freshly opened browser window (see issue #311).
  it "warns on the Firefox row when certutil is unavailable" do
    backend = MemoryBackend.new(80, 14)
    BrowserPicker.new(BROWSERS, false).render(Screen.new(backend), Rect.new(0, 0, 80, 14))
    backend.contains?("firefox ⚠").should be_true
  end

  it "doesn't warn when certutil is available" do
    backend = MemoryBackend.new(80, 14)
    BrowserPicker.new(BROWSERS, true).render(Screen.new(backend), Rect.new(0, 0, 80, 14))
    backend.contains?("firefox ⚠").should be_false
    backend.contains?("firefox").should be_true
  end
end

describe "BrowserPicker — Overlay contract" do
  it "supplies the chrome the shell's collapsed title/hint ladders read off it" do
    h = OverlayHarness.new(BrowserPicker.new(BROWSERS))
    h.assert_chrome(OverlayKind::Browser, "BROWSER")
    # Only a confirm raised from inside another modal carries a restore. A picker that grew
    # one would re-open something behind it after a plain dismiss.
    h.overlay.on_close.should be_nil
  end

  it "navigates with ↑/↓ and with k/j" do
    h = OverlayHarness.new(BrowserPicker.new(BROWSERS))
    picker = h.overlay.as(BrowserPicker)
    h.press(Termisu::Input::Key::Down)
    picker.selected.should eq(1)
    h.press(Termisu::Input::Key::LowerK)
    picker.selected.should eq(0)
    h.press(Termisu::Input::Key::LowerJ)
    picker.selected.should eq(1)
    h.press(Termisu::Input::Key::Up)
    picker.selected.should eq(0)
  end

  it "launches the highlighted row on ↵ and cancels on esc" do
    h = OverlayHarness.new(BrowserPicker.new(BROWSERS))
    launched = nil.as(String?)
    h.on_commit { launched = h.overlay.as(BrowserPicker).selected_browser.try(&.id); true }
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    launched.should eq("firefox") # the commit sees the row the user moved to

    esc = OverlayHarness.new(BrowserPicker.new(BROWSERS))
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  it "scrolls the list with the wheel rather than committing" do
    h = OverlayHarness.new(BrowserPicker.new(BROWSERS))
    h.wheel(3)
    h.overlay.as(BrowserPicker).selected.should eq(1)
    h.commits.should eq(0)
  end

  it "routes clicks: a row selects AND launches, off-list holds, outside dismisses" do
    h = OverlayHarness.new(BrowserPicker.new(BROWSERS))
    picker = h.overlay.as(BrowserPicker)
    box = h.box.not_nil!
    # The list starts 3 rows below the card top (title + subtitle + divider).
    picker.handle_click(h.area, box.x + 3, box.y + 4).should eq(:commit)
    picker.selected.should eq(1)                                       # the clicked row, not the one that was highlighted
    picker.handle_click(h.area, box.x + 3, box.y + 1).should eq(:stay) # the subtitle line
    picker.handle_click(h.area, box.x - 1, box.y).should eq(:cancel)
  end

  # The harness default area is the whole screen, which is roomier than the `layout.body`
  # production hands over, so this path needs an explicit rect: with no card drawn there is
  # nothing to click, and a click must dismiss rather than act on a phantom row.
  it "dismisses a click when the area is too small to draw the card" do
    picker = BrowserPicker.new(BROWSERS)
    tiny = Rect.new(0, 0, 20, 4)
    picker.overlay_box(tiny).should be_nil
    picker.handle_click(tiny, 10, 2).should eq(:cancel)
  end
end
