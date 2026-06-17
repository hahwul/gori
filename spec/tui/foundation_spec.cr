require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::Rect do
  it "computes edges and containment" do
    r = Rect.new(2, 3, 10, 5)
    r.right.should eq(12)
    r.bottom.should eq(8)
    r.contains?(2, 3).should be_true
    r.contains?(12, 3).should be_false
    r.inset(1, 1).should eq(Rect.new(3, 4, 8, 3))
  end
end

describe Gori::Tui::Layout do
  it "splits the screen into topbar / menu / body (full width) / status" do
    l = Layout.compute(100, 30)
    l.topbar.should eq(Rect.new(0, 0, 100, 1))
    l.menu.should eq(Rect.new(0, 1, 100, 1))
    l.status.should eq(Rect.new(0, 29, 100, 1))
    l.body.should eq(Rect.new(0, 2, 100, 27)) # full width, below the two top rows
  end

  it "flags too-small terminals" do
    Layout.usable?(30, 5).should be_false
    Layout.usable?(120, 40).should be_true
  end
end

describe Gori::Tui::Screen do
  it "writes text and truncates with an ellipsis past the width" do
    backend = MemoryBackend.new(20, 3)
    screen = Screen.new(backend)
    screen.text(0, 0, "hello", Theme::TEXT)
    backend.row(0).rstrip.should eq("hello")

    screen.text(0, 1, "abcdefghij", Theme::TEXT, width: 5)
    backend.row(1)[0, 5].should eq("abcd…")
  end

  it "clips text to the right edge" do
    backend = MemoryBackend.new(5, 2)
    screen = Screen.new(backend)
    screen.text(3, 0, "overflowing", Theme::TEXT) # only 2 columns left (x=3,4)
    backend.row(0).should eq("   o…")             # cols 0-2 blank, then fit("...",2)
  end
end

describe Gori::Tui::Chrome do
  it "renders the horizontal tab menu and highlights the active one" do
    backend = MemoryBackend.new(90, 2)
    screen = Screen.new(backend)
    Chrome.render_menu(screen, Rect.new(0, 1, 90, 1),
      active_tab: :history, focused: true, findings_count: 2, intercept_count: 3)

    backend.contains?("History").should be_true
    backend.contains?("Intercept").should be_true
    backend.contains?("Sitemap").should be_true
    backend.row(1).should contain("▸")           # active+focused marker
    backend.row(1).should contain("(3)")         # held-message badge on Intercept
    backend.fg_at(3, 1).should eq(Theme::ACCENT) # active label (col 3, after "▸ ") uses accent
  end

  it "marks the active tab without a focus band when the menu is unfocused" do
    backend = MemoryBackend.new(90, 2)
    Chrome.render_menu(Screen.new(backend), Rect.new(0, 1, 90, 1),
      active_tab: :history, focused: false)
    backend.row(1).should contain("·") # active marker, dimmed
    backend.row(1).should_not contain("▸")
  end

  it "renders the top bar with capture indicator" do
    backend = MemoryBackend.new(80, 1)
    screen = Screen.new(backend)
    Chrome.render_top_bar(screen, Rect.new(0, 0, 80, 1),
      project: "acme", capturing: true, listen: "127.0.0.1:8080", identity: "user", scope: "scope:2")
    backend.row(0).should contain("gori")
    backend.row(0).should contain("acme")
    backend.row(0).should contain("rec")
    backend.row(0).should contain("scope:2")
  end
end
