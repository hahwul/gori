require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Records the exact String object handed to `put`, so a spec can prove Screen#cell
# reuses one interned String for a repeated non-ASCII glyph instead of allocating per cell.
private class CaptureBackend < Gori::Tui::Backend
  getter drawn = [] of String

  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Gori::Tui::Color, bg : Gori::Tui::Color, attr : Gori::Tui::Attribute) : Nil
    @drawn << (grapheme.is_a?(String) ? grapheme : grapheme.to_s)
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

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

describe Gori::Tui::Screen do
  it "column_width counts a raw control char as 1 column (inverse of column_for)" do
    line = "ab\rc" # a lone CR (display width 0) between real chars
    # display_width under-counts the control char (0); column_width matches the drawn
    # cells + column_for, so the caret after it lands on the right column.
    Screen.display_width(line).should eq(3)                                 # CR contributes 0
    Screen.column_width(line).should eq(4)                                  # CR occupies a cell → counts as 1
    Screen.column_for(line, Screen.column_width(line)).should eq(line.size) # round-trips
  end

  it "column_width equals display_width for plain text and doubles wide glyphs" do
    Screen.column_width("hello").should eq(5)
    Screen.column_width("日本").should eq(4) # CJK: 2 columns each, same as display_width
  end

  it "fit truncates a too-wide string with an ellipsis and returns a fitting one whole" do
    screen = Screen.new(MemoryBackend.new(10, 1))
    screen.fit("hello", 10).should eq("hello")   # fits → unchanged
    screen.fit("hello", 5).should eq("hello")    # exactly fits → no ellipsis
    screen.fit("abcdefgh", 5).should eq("abcd…") # overflows → 4 chars + ellipsis = width 5
    screen.fit("日本語テスト", 5).should eq("日本…")     # wide glyphs (2 cols): 2+2+ellipsis = 5
    screen.fit("x", 0).should eq("")
  end

  it "interns non-ASCII glyph cells so a repeated glyph reuses one String (no per-cell alloc)" do
    cap = CaptureBackend.new(10, 2)
    screen = Screen.new(cap)
    screen.cell(0, 0, '┃', Theme.text) # box-drawing glyph — the scroll gauge thumb
    screen.cell(1, 0, '┃', Theme.text)
    cap.drawn.size.should eq(2)
    cap.drawn[0].should eq("┃")                       # renders the correct glyph
    cap.drawn[0].same?(cap.drawn[1]).should be_true   # …and the SAME interned instance, not a fresh String
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
    l.rule.should eq(Rect.new(hpad, vpad + 1, iw, 1)) # header hairline under the logo row
    l.menu.should eq(Rect.new(hpad, vpad + 2, iw, 1))
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
    screen.text(0, 0, "hello", Theme.text)
    backend.row(0).rstrip.should eq("hello")

    screen.text(0, 1, "abcdefghij", Theme.text, width: 5)
    backend.row(1)[0, 5].should eq("abcd…")
  end

  it "clips text to the right edge" do
    backend = MemoryBackend.new(5, 2)
    screen = Screen.new(backend)
    screen.text(3, 0, "overflowing", Theme.text) # only 2 columns left (x=3,4)
    backend.row(0).should eq("   o…")            # cols 0-2 blank, then fit("...",2)
  end
end

describe Gori::Tui::Chrome do
  it "renders the segmented tab menu and brightens the active one when focused" do
    backend = MemoryBackend.new(90, 2)
    screen = Screen.new(backend)
    Chrome.render_menu(screen, Rect.new(0, 1, 90, 1),
      active_tab: :project, focused: true, intercept_count: 3)

    backend.contains?("Project").should be_true
    backend.contains?("History").should be_true
    backend.contains?("Intercept").should be_true
    backend.contains?("Target").should be_true
    backend.contains?("(3)").should be_true      # held-message badge on Intercept (the only tab-bar count)
    backend.contains?("Issues(").should be_false # issues/repeater/notes carry no count badge
    # active segment ` Project ` (now first tab) starts at col 2 (rect.x+1 fill, +1 pad); FOCUS_GOLD pill.
    backend.fg_at(2, 1).should eq(Theme.ink_on(Theme.focus_gold))
    backend.bg_at(2, 1).should eq(Theme.focus_gold)
    backend.fg_at(12, 1).should eq(Theme.muted) # an inactive label (History) is muted
  end

  it "settles the active segment to bold TEXT (no gold pill) when the menu is unfocused" do
    backend = MemoryBackend.new(90, 2)
    Chrome.render_menu(Screen.new(backend), Rect.new(0, 1, 90, 1),
      active_tab: :project, focused: false)
    backend.fg_at(2, 1).should eq(Theme.text) # active but body-focused: present, not lit
    backend.bg_at(2, 1).should eq(Theme.selection_dim)
    backend.bg_at(2, 1).should_not eq(Theme.focus_gold)
  end

  it "windows the tab strip so the active tab stays visible when the row is too narrow" do
    backend = MemoryBackend.new(30, 2)
    Chrome.render_menu(Screen.new(backend), Rect.new(0, 1, 30, 1),
      active_tab: :help, focused: true)      # last tab — can't all fit in 30 cols
    backend.contains?("Help").should be_true # scrolled into view, not dropped
    backend.row(1).should contain("‹")       # indicator that earlier tabs are hidden
  end

  it "renders the focus-area badge at the far left of the status bar" do
    backend = MemoryBackend.new(90, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 90, 1),
      focus: "BODY", hints: "↹ pane · esc tabs", activity: {"scanning", Theme.accent})
    backend.contains?("BODY").should be_true
    backend.fg_at(1, 0).should eq(Theme.text_bright) # badge text is bright (col 0 is the leading pad)
    backend.contains?("↹ pane").should be_true       # hints still render to the right of the badge
    backend.contains?("scanning").should be_true     # the activity chip renders on the right
  end

  it "keeps the focus badge intact when a chip would otherwise overflow a narrow bar" do
    # 36-col status rect ≈ a 40-col terminal (the minimum supported size). The activity
    # label here is wide enough (>27 cols) that its natural right-aligned x falls left of
    # the hint start, so the min_x floor MUST clamp it — proving the clamp protects the
    # persistent focus badge rather than the chip merely happening to fit.
    backend = MemoryBackend.new(36, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 36, 1),
      focus: "ISSUE", hints: "type title · esc cancel",
      activity: {"scanning a very long-running background job", Theme.accent})
    backend.row(0)[0, 7].should eq(" ISSUE ") # badge survives, no chip bled into it
    backend.fg_at(1, 0).should eq(Theme.text_bright)
    backend.contains?("scanning").should be_true # chip still present (floored at the hint start, truncated at the right edge)
  end

  it "anchors the resource readout to the right of the activity chip" do
    # The resource chip is fixed-width and drawn LAST so it owns the right edge: a job
    # starting or ending must not slide the readout around under the operator's eye.
    backend = MemoryBackend.new(90, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 90, 1),
      focus: "BODY", hints: "↹ pane · esc tabs",
      activity: {"scanning", Theme.accent}, resource: "CPU 12% MEM 48M")
    row = backend.row(0)
    res_x = row.index("CPU 12%").not_nil!
    row.index("scanning").not_nil!.should be < res_x # activity sits to its left
    # …and the readout ends flush against render_chips' one-column right pad.
    (res_x + "CPU 12% MEM 48M".size).should eq(90 - 1)
    backend.fg_at(res_x, 0).should eq(Theme.muted) # a passive readout, not an alert
  end

  it "leaves the status bar chip-free when the resource meter is off" do
    backend = MemoryBackend.new(90, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 90, 1),
      focus: "BODY", hints: "↹ pane · esc tabs", resource: nil)
    backend.contains?("CPU").should be_false
    backend.contains?("MEM").should be_false
  end

  it "anchors the clock at the far right of the status bar, right of the resource readout" do
    backend = MemoryBackend.new(90, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 90, 1),
      focus: "BODY", hints: "↹ pane · esc tabs", resource: "CPU 12% MEM 48M", time: "01:37 PM")
    row = backend.row(0)
    tx = row.index("01:37 PM").not_nil!
    row.index("CPU 12%").not_nil!.should be < tx # the readout stays left of the clock
    (tx + "01:37 PM".size).should eq(90 - 1)      # flush against the one-column right pad
    backend.fg_at(tx, 0).should eq(Theme.muted)
    backend.bg_at(tx, 0).should eq(Theme.panel) # nothing on this bar is a button
  end

  it "gilds the shell only for single-pane body focus" do
    BodyChrome.shell_focused(:body, multi_pane: false).should be_true
    BodyChrome.shell_focused(:body, multi_pane: true).should be_false
    BodyChrome.shell_focused(:subtabs, multi_pane: false).should be_false
  end

  it "carves the sub-tab strip inside a framed body" do
    outer = Rect.new(0, 0, 80, 20)
    strip = BodyChrome.strip_rect(outer, strip: true).not_nil!
    content = BodyChrome.content_rect(outer, strip: true)
    strip.y.should eq(1) # inside the frame, not on the canvas
    strip.h.should eq(BodyChrome::STRIP_H)
    content.y.should eq(strip.y + strip.h)
    content.h.should eq(outer.h - 2 - BodyChrome::STRIP_H) # frame inset + strip
  end

  it "carves chips-only when strip_divider is false (Repeater filter owns the hairline)" do
    outer = Rect.new(0, 0, 80, 20)
    strip = BodyChrome.strip_rect(outer, strip: true, strip_divider: false).not_nil!
    content = BodyChrome.content_rect(outer, strip: true, strip_divider: false)
    strip.h.should eq(BodyChrome::CHIPS_H)
    content.y.should eq(strip.y + strip.h)
    content.h.should eq(outer.h - 2 - BodyChrome::CHIPS_H)
  end

  it "renders the active sub-tab chip as a filled pill with a divider hairline" do
    backend = MemoryBackend.new(60, 2)
    screen = Screen.new(backend)
    BodyChrome.render_subtab_strip(screen, Rect.new(0, 0, 60, 2),
      ["1:alpha", "2:beta"], 0, focused: true)

    backend.bg_at(13, 0).should eq(Theme.bg) # inactive label sits on the canvas, no pill
    backend.bg_at(13, 0).should_not eq(Theme.elevated)
    backend.bg_at(2, 0).should eq(Theme.focus_gold) # active pill when focused
    backend.row(1).should contain("─")              # hairline under the chips
  end

  it "skips the hairline when the strip is chips-only (h=1)" do
    backend = MemoryBackend.new(60, 1)
    screen = Screen.new(backend)
    BodyChrome.render_subtab_strip(screen, Rect.new(0, 0, 60, 1),
      ["1:alpha", "2:beta"], 0, focused: true)
    # Chips still render; rect.h < 2 means no hline is drawn (Repeater filter owns it).
    backend.bg_at(2, 0).should eq(Theme.focus_gold)
    backend.row(0).should_not contain("─")
  end

  it "settles the active sub-tab chip to a calmer receded gold when the strip is unfocused" do
    backend = MemoryBackend.new(60, 1)
    Chrome.render_tab_strip(Screen.new(backend), Rect.new(0, 0, 60, 1),
      ["one", "two"], 1, focused: false)
    dim_gold = Theme.blend(Theme.focus_gold, Theme.bg, Chrome::SUBTAB_DIM_GOLD)
    backend.bg_at(8, 0).should eq(dim_gold)             # the whole chip fills the receded gold, edge to edge
    backend.bg_at(9, 0).should eq(dim_gold)             # band body under the label
    backend.bg_at(9, 0).should_not eq(Theme.focus_gold) # a step below the bright focus pill
    backend.fg_at(9, 0).should eq(Theme.text_bright)    # active label ink on the band
  end

  it "renders the top bar with project and scope, and no clock (it moved to the status bar)" do
    backend = MemoryBackend.new(80, 1)
    screen = Screen.new(backend)
    Chrome.render_top_bar(screen, Rect.new(0, 0, 80, 1),
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:2")
    backend.row(0).should contain("𝓰𝓸𝓻𝓲")
    backend.row(0).should contain("acme")
    backend.row(0).should contain("scope:2")
    backend.row(0).should contain("⌘")              # far-right palette affordance
    backend.row(0).should contain("127.0.0.1:8080") # listen address always shown, capture state rides its colour
    backend.row(0).should_not contain("notify")     # no unread → badge omitted
    # The bar is actions-only now; a wall clock isn't pressable, so it lives on the status bar.
    backend.contains?("PM").should be_false
  end

  it "leaves every top-bar chip flush on the bar background (no button tint)" do
    # A lifted band on the clickable chips was tried and dropped — it only pays for itself
    # alongside a hover highlight, which termisu can't report. Clickability is metadata for
    # the hit-test, not a paint. This pins that so the tint doesn't creep back.
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), Rect.new(0, 0, 80, 1),
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:2", probe: "probe:passive",
      sandbox: "sandbox")
    row = backend.row(0)
    {"scope:2", "probe:passive", "127.0.0.1:8080", "⌘", "⚙", "sandbox"}.each do |label|
      x = row.index(label).not_nil!
      backend.bg_at(x, 0).should eq(Theme.bg)
    end
  end

  it "colours the probe chip by mode, mirroring the Probe tab's mode band" do
    {"probe:off" => Theme.muted, "probe:passive" => Theme.accent, "probe:active" => Theme.orange}.each do |label, want|
      backend = MemoryBackend.new(80, 1)
      Chrome.render_top_bar(Screen.new(backend), Rect.new(0, 0, 80, 1),
        project: "acme", listen: "127.0.0.1:8080", scope: "scope:2", probe: label)
      x = backend.row(0).index(label).not_nil!
      backend.fg_at(x, 0).should eq(want)
    end
  end

  it "shows the unread notify badge on the top bar, left of scope" do
    backend = MemoryBackend.new(80, 1)
    screen = Screen.new(backend)
    Chrome.render_top_bar(screen, Rect.new(0, 0, 80, 1),
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:2", unread: 3)
    backend.row(0).should contain("notify:3")
    row = backend.row(0)
    row.index("notify:3").not_nil!.should be < row.index("scope:2").not_nil!
    fx = row.index("notify:3").not_nil!
    backend.fg_at(fx, 0).should eq(Theme.accent)
  end

  it "omits the notify badge from the bottom status bar (it moved to the top bar)" do
    backend = MemoryBackend.new(90, 1)
    Chrome.render_status(Screen.new(backend), Rect.new(0, 0, 90, 1),
      focus: "BODY", hints: "↹ pane · esc tabs")
    backend.contains?("notify").should be_false
  end

  it "colours the top-bar listen chip green while capturing (address text unchanged)" do
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), Rect.new(0, 0, 80, 1),
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:2", capturing: true)
    backend.row(0).should contain("127.0.0.1:8080")
    fx = backend.row(0).index("127.0.0.1:8080").not_nil!
    backend.fg_at(fx, 0).should eq(Theme.green)
    backend.contains?("capture:on").should be_false # merged into the listen chip, not a separate label
  end

  it "dims the top-bar listen chip when capture is paused" do
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), Rect.new(0, 0, 80, 1),
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:2", capturing: false)
    fx = backend.row(0).index("127.0.0.1:8080").not_nil!
    backend.fg_at(fx, 0).should eq(Theme.muted)
  end

  it "turns the top-bar listen chip red with the drop count when writes are failing" do
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), Rect.new(0, 0, 80, 1),
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:2",
      capturing: true, write_failures: 4)
    backend.row(0).should contain("127.0.0.1:8080 (4)")
    fx = backend.row(0).index("127.0.0.1:8080").not_nil!
    backend.fg_at(fx, 0).should eq(Theme.red)
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

  it "rides a right-border scroll gauge whose thumb tracks the scroll offset" do
    box = Rect.new(0, 0, 20, 10)
    inner = box.inset(1, 1) # interior height 8; border column 19
    col = 19

    top_b = MemoryBackend.new(30, 12)
    Frame.card(Screen.new(top_b), box)
    Frame.scroll_gauge(Screen.new(top_b), inner, total: 100, top: 0, focused: true)
    top_b.grid[1][col].should eq('┃')                           # thumb sits at the top
    top_b.grid[8][col].should eq('│')                           # track below it
    (1..8).count { |y| top_b.grid[y][col] == '┃' }.should eq(1) # a huge body → a 1-row thumb

    bot_b = MemoryBackend.new(30, 12)
    Frame.card(Screen.new(bot_b), box)
    Frame.scroll_gauge(Screen.new(bot_b), inner, total: 100, top: 92, focused: true) # max scroll
    bot_b.grid[8][col].should eq('┃')                                                # thumb has ridden to the bottom
    bot_b.grid[1][col].should eq('│')

    # A body that fits the viewport draws no gauge — the plain hairline stays.
    fit_b = MemoryBackend.new(30, 12)
    Frame.card(Screen.new(fit_b), box)
    Frame.scroll_gauge(Screen.new(fit_b), inner, total: 5, top: 0, focused: true)
    (1..8).count { |y| fit_b.grid[y][col] == '┃' }.should eq(0)
  end
end
