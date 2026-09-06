require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# `Overlay#page_key` — PgUp/PgDn/Home/End over a list CARD, one page being the rows the last
# frame drew. `PickerOverlay` had this for the pickers (#958); the list cards each hand-rolled
# ↑/↓ and walked a 100-entry ring one row at a time. The two cards below stand for the nine
# that take the arm now (notifications, agents, listeners, passthrough, tabs, columns, hosts,
# env, hotkeys): one whose window is derived from a scrolling ring, one whose list is fixed.

private def notes(n : Int32) : Notifications
  s = Notifications.new
  n.times { |i| s.push(:info, "note #{i}", Jobs::Goto.new(:history, i.to_i64)) }
  s
end

describe "Overlay#page_key on the list cards" do
  it "pages the notification centre by the rows it drew, and jumps to the ends" do
    ov = NotificationsOverlay.new(notes(60))
    h = OverlayHarness.new(ov, area: Rect.new(0, 0, 100, 20))
    h.render # the page is measured off a frame
    first = ov.selected_note.not_nil!.message
    h.press(Termisu::Input::Key::PageDown)
    paged = ov.selected_note.not_nil!.message
    paged.should_not eq(first)
    h.press(Termisu::Input::Key::End)
    last = ov.selected_note.not_nil!.message
    last.should_not eq(paged)
    h.press(Termisu::Input::Key::Home)
    ov.selected_note.not_nil!.message.should eq(first)
    h.press(Termisu::Input::Key::PageUp) # at the top already: inert, never raises
    ov.selected_note.not_nil!.message.should eq(first)
  end

  it "jumps the tab editor to its ends" do
    ov = TabsOverlay.new
    h = OverlayHarness.new(ov)
    h.render
    h.press(Termisu::Input::Key::End)
    ov.selected.should eq(ov.entry_count - 1)
    h.press(Termisu::Input::Key::Home)
    ov.selected.should eq(0)
    h.press(Termisu::Input::Key::PageDown)
    ov.selected.should be > 0
  end

  it "is inert on a card that reports no rows" do
    ov = TabsOverlay.new
    ov.page_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerJ, Termisu::Input::Modifier::None, 'j')).should be_false
  end
end

describe "NotificationsOverlay `y`" do
  it "copies the selected note and says so in the hint until the next key" do
    ov = NotificationsOverlay.new(notes(3))
    h = OverlayHarness.new(ov)
    h.render
    h.press(Termisu::Input::Key::LowerY, 'y')
    ov.hint.should start_with("copied ")
    h.press(Termisu::Input::Key::Down)
    ov.hint.should_not start_with("copied ")
    ov.hint.should contain("y copy")
  end
end

describe "Overlay.too_small" do
  it "draws the one line inside the area, and nothing on an empty area" do
    be = MemoryBackend.new(80, 3)
    Overlay.too_small(Screen.new(be), Rect.new(0, 0, 80, 3), "the card needs a larger window")
    be.contains?("the card needs a larger window · esc to close").should be_true
    be2 = MemoryBackend.new(40, 3)
    Overlay.too_small(Screen.new(be2), Rect.new(0, 0, 0, 0), "x")
    be2.contains?("x").should be_false
  end
end
