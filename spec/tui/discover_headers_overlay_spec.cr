require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::DiscoverHeadersOverlay do
  it "round-trips seeded headers through the editor buffer" do
    ov = DiscoverHeadersOverlay.new([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    ov.headers.should eq([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
  end

  it "renders seeded headers without crashing" do
    ov = DiscoverHeadersOverlay.new([{"A", "b"}])
    screen = Screen.new(MemoryBackend.new(80, 24))
    ov.render(screen, Rect.new(0, 0, 80, 24))
  end

  it "renders an empty editor without crashing" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    ov.headers.should be_empty
    screen = Screen.new(MemoryBackend.new(80, 24))
    ov.render(screen, Rect.new(0, 0, 80, 24))
  end
end
