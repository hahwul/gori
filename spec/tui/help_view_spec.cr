require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::HelpView do
  it "renders the grouped shortcut sections" do
    view = HelpView.new
    backend = MemoryBackend.new(90, 60) # tall enough for every row
    view.render(Screen.new(backend), Rect.new(0, 0, 90, 60))

    backend.contains?("GLOBAL").should be_true
    backend.contains?("command palette").should be_true
    backend.contains?("MOUSE").should be_true
    backend.contains?("REPLAY").should be_true
    backend.contains?("rename").should be_true # the new sub-tab rename shortcut is documented
  end

  it "scrolls — the first section leaves and the last arrives" do
    view = HelpView.new
    short = Rect.new(0, 0, 90, 8)
    view.render(Screen.new(MemoryBackend.new(90, 8)), short)
    view.at_top?.should be_true

    view.move(100) # past the end → clamped to the last screenful on render
    after = MemoryBackend.new(90, 8)
    view.render(Screen.new(after), short)
    after.contains?("GLOBAL").should be_false  # scrolled off the top
    after.contains?("OVERLAYS").should be_true # last section now on screen
    view.at_top?.should be_false
  end
end
