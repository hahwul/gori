require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::HelpView do
  it "renders the grouped shortcut sections" do
    view = HelpView.new
    backend = MemoryBackend.new(100, 120) # tall enough for every row (grows as tabs are added)
    view.render(Screen.new(backend), Rect.new(0, 0, 100, 120))

    backend.contains?("GLOBAL").should be_true
    backend.contains?("command palette").should be_true
    backend.contains?("MOUSE").should be_true
    backend.contains?("REPLAY").should be_true
    backend.contains?("rename").should be_true  # the new sub-tab rename shortcut is documented
    backend.contains?("DECODER").should be_true # the Decoder tab cheat-sheet
  end

  it "scrolls — the first section leaves and the last arrives" do
    view = HelpView.new
    short = Rect.new(0, 0, 90, 8)
    view.render(Screen.new(MemoryBackend.new(90, 8)), short)
    view.at_top?.should be_true

    view.move(10_000) # past the end → clamped to the last screenful on render
    after = MemoryBackend.new(90, 8)
    view.render(Screen.new(after), short)
    after.contains?("GLOBAL").should be_false  # scrolled off the top
    after.contains?("OVERLAYS").should be_true # last section now on screen
    view.at_top?.should be_false
  end

  it "renders the About page with brand art, version, author, and GitHub URL" do
    view = HelpView.new
    backend = MemoryBackend.new(80, 40)
    view.render_about(Screen.new(backend), Rect.new(0, 0, 80, 40))

    backend.contains?("gori").should be_true
    backend.contains?("v#{Gori::VERSION}").should be_true
    backend.contains?("hahwul").should be_true
    backend.contains?("Hwan Lee").should be_true
    backend.contains?(Gori::REPOSITORY_URL).should be_true
    # Same ink as the project-picker brand mark (a few solid blocks).
    backend.contains?("█").should be_true
  end
end
