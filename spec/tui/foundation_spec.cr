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
  it "splits the screen into topbar / menu / rule / body (inset with padding) / status" do
    l = Layout.compute(100, 30)
    hpad = Layout::H_PADDING
    vpad = Layout::V_PADDING
    iw = 100 - 2 * hpad
    ih = 30 - 2 * vpad
    l.topbar.should eq(Rect.new(hpad, vpad + 0, iw, 1))
    l.menu.should eq(Rect.new(hpad, vpad + 1, iw, 1))
    l.rule.should eq(Rect.new(hpad, vpad + 2, iw, 1)) # header hairline under the tabs
    l.status.should eq(Rect.new(hpad, vpad + ih - 1, iw, 1))
    l.body.should eq(Rect.new(hpad, vpad + 3, iw, ih - 4)) # inset vertically and horizontally
  end

  it "still accepts the original min size in usable? (padding handled inside)" do
    Layout.usable?(40, 8).should be_true
    Layout.usable?(39, 8).should be_false
    Layout.usable?(40, 7).should be_false
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
  it "renders the segmented tab menu and brightens the active one when focused" do
    backend = MemoryBackend.new(90, 2)
    screen = Screen.new(backend)
    Chrome.render_menu(screen, Rect.new(0, 1, 90, 1),
      active_tab: :history, focused: true, findings_count: 2, intercept_count: 3)

    backend.contains?("History").should be_true
    backend.contains?("Intercept").should be_true
    backend.contains?("Sitemap").should be_true
    backend.contains?("(3)").should be_true # held-message badge on Intercept
    # active segment ` History ` starts at col 2 (rect.x+1 fill, +1 pad); bright accent.
    backend.fg_at(2, 1).should eq(Theme::ACCENT)
    backend.fg_at(12, 1).should eq(Theme::MUTED) # an inactive label is muted
  end

  it "settles the active segment to bold TEXT (no accent) when the menu is unfocused" do
    backend = MemoryBackend.new(90, 2)
    Chrome.render_menu(Screen.new(backend), Rect.new(0, 1, 90, 1),
      active_tab: :history, focused: false)
    backend.fg_at(2, 1).should eq(Theme::TEXT) # active but body-focused: present, not lit
    backend.fg_at(2, 1).should_not eq(Theme::ACCENT)
  end

  it "windows the tab strip so the active tab stays visible when the row is too narrow" do
    backend = MemoryBackend.new(30, 2)
    Chrome.render_menu(Screen.new(backend), Rect.new(0, 1, 30, 1),
      active_tab: :agent, focused: true)      # last tab — can't all fit in 30 cols
    backend.contains?("Agent").should be_true # scrolled into view, not dropped
    backend.row(1).should contain("‹")        # indicator that earlier tabs are hidden
  end

  it "renders the focus-area badge at the far left of the status bar" do
    backend = MemoryBackend.new(90, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 90, 1),
      focus: "BODY", hints: "↹ pane · esc tabs", capturing: true, insecure_upstream: false)
    backend.contains?("BODY").should be_true
    backend.fg_at(1, 0).should eq(Theme::TEXT_BRIGHT) # badge text is bright (col 0 is the leading pad)
    backend.contains?("↹ pane").should be_true        # hints still render to the right of the badge
    backend.contains?("capture:on").should be_true    # chips still on the right
  end

  it "keeps the focus badge intact when chips would otherwise overflow a narrow bar" do
    # 36-col status rect ≈ a 40-col terminal (the minimum supported size). The
    # widest chip pair must not clobber the persistent focus badge.
    backend = MemoryBackend.new(36, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 36, 1),
      focus: "FINDING", hints: "type title · esc cancel", capturing: false, insecure_upstream: true)
    backend.row(0)[0, 9].should eq(" FINDING ") # badge survives, no chip bled into it
    backend.fg_at(1, 0).should eq(Theme::TEXT_BRIGHT)
    backend.contains?("capture:off").should be_true # chips still present (truncated at the right edge)
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

describe Gori::Tui::Frame do
  it "frames a rounded card with corners and an embedded title" do
    backend = MemoryBackend.new(30, 6)
    screen = Screen.new(backend)
    Frame.card(screen, Rect.new(0, 0, 20, 5), "SCOPE")

    backend.row(0).should contain("╭")     # rounded top-left
    backend.row(0).should contain("╮")     # rounded top-right
    backend.row(0).should contain("SCOPE") # title rides the top edge
    backend.row(4).should contain("╰")     # rounded bottom-left
    backend.row(4).should contain("╯")     # rounded bottom-right
    backend.grid[2][0].should eq('│')      # left edge
    backend.grid[2][19].should eq('│')     # right edge
  end

  it "draws a tee divider that joins the side borders" do
    backend = MemoryBackend.new(30, 6)
    screen = Screen.new(backend)
    box = Rect.new(0, 0, 20, 5)
    Frame.card(screen, box)
    Frame.tee_divider(screen, box, 2)

    backend.grid[2][0].should eq('├')
    backend.grid[2][19].should eq('┤')
    backend.row(2).should contain("─")
  end
end
