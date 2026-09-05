require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# `PickerOverlay#page_key` — PgUp/PgDn/Home/End over a picker's list, one page being the
# rows the last frame drew. Every picker walked its rows one at a time; a 500-flow
# FlowPicker had no other gait.

private def rows(n : Int32) : Array(SubtabPicker::Row)
  (0...n).map { |i| SubtabPicker::Row.new(i, "s#{i}", "GET /r#{i}") }
end

describe "PickerOverlay#page_key" do
  it "pages by the rows the last frame drew, and jumps to the ends" do
    sp = SubtabPicker.new("FIND SUB-TAB", rows(200))
    h = OverlayHarness.new(sp)
    h.render # the page is measured off a frame
    h.press(Termisu::Input::Key::PageDown).should eq(:open)
    page = sp.selected_index.not_nil!
    page.should be > 1
    page.should be < 40
    h.press(Termisu::Input::Key::PageDown)
    sp.selected_index.should eq(page * 2)
    h.press(Termisu::Input::Key::End)
    sp.selected_index.should eq(199)
    h.press(Termisu::Input::Key::PageUp)
    sp.selected_index.should eq(199 - page)
    h.press(Termisu::Input::Key::Home)
    sp.selected_index.should eq(0)
  end

  it "is inert for a key that is not one of the four" do
    sp = SubtabPicker.new("FIND SUB-TAB", rows(3))
    sp.page_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerJ, Termisu::Input::Modifier::None, 'j')).should be_false
  end
end
