require "../spec_helper"
require "../support/memory_backend"

describe Gori::Tui::TagPromptOverlay do
  it "drops the previous completion when a resize hides the card" do
    overlay = Gori::Tui::TagPromptOverlay.new([] of String, [{"web", 3}])
    screen = Gori::Tui::Screen.new(MemoryBackend.new(80, 20))
    overlay.render(screen, Gori::Tui::Rect.new(0, 0, 80, 20))
    overlay.render(screen, Gori::Tui::Rect.new(0, 0, 80, 4))
    overlay.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Tab))
    overlay.tags.should be_empty
  end
end
