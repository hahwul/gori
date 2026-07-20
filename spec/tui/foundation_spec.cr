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
  it "draw_width counts a raw control char as 1 column (inverse of column_for)" do
    line = "ab\rc" # a lone CR (display width 0) between real chars
    # display_width under-counts the control char (0); draw_width matches the drawn
    # cells + column_for, so the caret after it lands on the right column.
    Screen.display_width(line).should eq(3)                                # CR contributes 0
    Screen.draw_width(line).should eq(4)                                   # CR occupies a cell → counts as 1
    Screen.column_for(line, Screen.draw_width(line)).should eq(line.size)  # round-trips
  end

  it "draw_width equals display_width for plain text and doubles wide glyphs" do
    Screen.draw_width("hello").should eq(5)
    Screen.draw_width("日本").should eq(4) # CJK: 2 columns each, same as display_width
  end

  it "grapheme_cols floors a tab to 1 so draw advance matches the caret model" do
    # display_width is pure Unicode (tab = 0); grapheme_cols / draw_width keep the
    # space cell Screen#cell substitutes for C0 controls (issue #278).
    Screen.display_width("\t").should eq(0)
    Screen.grapheme_cols("\t").should eq(1)
    Screen.draw_width("a\tb").should eq(3)
    Screen.draw_width_upto("a\tb", 10).should eq(3)
    Screen.draw_width_upto("a\tb", 2).should eq(2)
  end

  # The two measures, pinned side by side. They are NOT interchangeable: display_width
  # under-counts a C0 control (Unicode width 0, but `cell` still paints a space there),
  # while draw_width matches the cells actually painted because it floors per CLUSTER —
  # the same walk `#text` / `Highlight.draw` do.
  #
  # `column_width` used to sit between them, flooring every CODEPOINT to ≥1 to serve a
  # per-codepoint caret. The `was` column below is what it returned. draw_width SUBSUMES
  # it: identical wherever column_width mattered (control chars, zero-width chars — each
  # its own cluster, still floored to ≥1) and different only where column_width was wrong
  # against the screen, which is what painted a duplicate glyph past any cluster.
  describe "display_width vs draw_width" do
    skin = "\u{1F44D}\u{1F3FD}"                                             # 👍🏽 thumbs-up + skin-tone modifier (2 cps)
    zwj = "\u{1F468}\u{200D}\u{1F4BB}"                                      # 👨‍💻 man + ZWJ + laptop (3 cps)
    family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}" # 👨‍👩‍👧‍👦 4 people + 3 ZWJ (7 cps)
    nfd_han = "\u{1112}\u{1161}\u{11ab}"                                    # 한 as 3 conjoining jamo

    # {label, string, display_width, draw_width, what column_width used to return}
    cases = [
      {"tab", "a\tb", 2, 3, 3},               # control: display under-counts; the tab owns a cell
      {"ZWSP", "a\u{200B}b", 2, 3, 3},        # zero-width space: same, it still gets a cell
      {"BOM", "a\u{FEFF}b", 3, 3, 3},         # zero-width no-break space: likewise its own cluster
      {"skin tone", skin, 2, 2, 3},           # 1 cluster, 1 glyph → 2 cols drawn, not 3
      {"ZWJ", zwj, 2, 2, 5},                  # column_width drifted 3
      {"family", family, 2, 2, 11},           # column_width drifted 9 — the worst case
      {"keycap", "1\u{FE0F}\u{20E3}", 2, 2, 3},
      {"CJK", "한글", 4, 4, 4},                 # wide but single-codepoint: both agree
      {"NFD Hangul", nfd_han, 2, 2, 4},       # 3 jamo (2 + 0 + 0 floored to 2+1+1), ONE cluster
      {"combining", "e\u{0301}", 1, 1, 2},    # é as e + U+0301: cluster is 1 col, not 2
    ]

    cases.each do |(label, str, dw, gw, was_cw)|
      it "measures #{label} as display=#{dw} draw=#{gw} (column_width was #{was_cw})" do
        Screen.display_width(str).should eq(dw)
        Screen.draw_width(str).should eq(gw)
        # The retired measure, recomputed inline: floor every CODEPOINT to ≥1. Pinned so
        # the divergence this collapse removed stays visible rather than becoming folklore.
        str.each_char.sum { |c| {Screen.display_width(c.to_s), 1}.max }.should eq(was_cw)
      end
    end

    it "draw_width equals the columns Screen#text actually advances" do
      # The authoritative check: whatever `text` returns as its end-x IS the drawn width.
      cases.each do |(label, str, _, gw, _)|
        b = MemoryBackend.new(40, 1)
        Screen.new(b).text(0, 0, str, Theme.text).should eq(gw) # (#{label})
      end
    end

    # THE invariant the collapse buys: draw_width and column_for are exact inverses at
    # every cluster boundary, so the caret column and the click that maps back to it can
    # no longer disagree. Two similar-but-different floored measures is what let #278
    # (tabs) and #285 (emoji) trade off against each other; there is now only one.
    it "column_for inverts draw_width at every cluster boundary" do
      strings = [
        "hello world",          # ASCII (the fast path on both sides)
        "a\tb\tc",              # tabs — the #278 case
        "ab\rc",                # raw control
        "한글",                   # NFC CJK, wide, 1 cp per cluster
        nfd_han + "글",           # NFD Hangul — jamo cluster next to a precomposed one
        "cafe\u{0301} au lait", # NFD Latin, combining mark mid-word
        "x#{skin}y",            # skin tone
        "x#{zwj}y",             # ZWJ pair
        "x#{family}y",          # 4-person ZWJ family — 9 columns of old drift
        "1\u{FE0F}\u{20E3}!",   # keycap
        "a\u{200B}b\u{FEFF}c",  # zero-width chars, each its own cluster
        "a\t한#{skin}e\u{0301}#{family}z", # everything at once
      ]
      strings.each do |s|
        # Walk the cluster boundaries: at each, the column is draw_width of the prefix and
        # column_for must map that column back to exactly that character index.
        i = 0
        s.each_grapheme do |g|
          col = Screen.draw_width(s[0, i])
          Screen.column_for(s, col).should eq(i) # (#{s.inspect} @ #{i})
          i += g.size
        end
        # …including the end of the string.
        Screen.column_for(s, Screen.draw_width(s)).should eq(s.size) # (#{s.inspect} end)
      end
    end

    it "column_for never returns an index inside a cluster" do
      # Every column a click can produce must resolve to a cluster START, so a click can
      # never drop the caret between the `e` and the combining acute of `é`.
      s = "a\t한#{skin}e\u{0301}#{family}z"
      starts = [] of Int32
      i = 0
      s.each_grapheme { |g| starts << i; i += g.size }
      starts << s.size
      (-3..Screen.draw_width(s) + 3).each do |col|
        starts.should contain(Screen.column_for(s, col)) # (col #{col})
      end
    end

    it "cluster_start / cluster_end snap to boundaries and are identity on them" do
      s = "a#{skin}e\u{0301}z"
      starts = [] of Int32
      i = 0
      s.each_grapheme { |g| starts << i; i += g.size }
      starts << s.size
      starts.each do |b|
        Screen.cluster_start(s, b).should eq(b) # already a boundary → unchanged
        Screen.cluster_end(s, b).should eq(b)
      end
      (0..s.size).each do |j|
        st = Screen.cluster_start(s, j)
        en = Screen.cluster_end(s, j)
        starts.should contain(st)
        starts.should contain(en)
        st.should be <= j
        en.should be >= j
      end
    end

    it "draw_width_upto early-exits without walking the rest of the line" do
      # Same contract as display_width_upto / column_width_upto: returns a value >= limit
      # once reached, exact below it. The h-scroll clamps run per frame, so a minified
      # multi-MB line must never be measured in full.
      Screen.draw_width_upto(zwj + "abcdefgh", 100).should eq(10) # exact under the limit
      Screen.draw_width_upto(zwj + "abcdefgh", 4).should be >= 4  # stopped early
      Screen.draw_width_upto("", 5).should eq(0)
      Screen.draw_width_upto("abc", 0).should eq(0)
      # ASCII fast path stays exact and capped
      Screen.draw_width_upto("abcdef", 3).should eq(3)
      Screen.draw_width_upto("abcdef", 99).should eq(6)
    end

    it "draw_width keeps the ASCII fast path exact (1 char == 1 cluster per line)" do
      # The fast path returns str.size. That is EXACT rather than approximate because the
      # only multi-char ASCII grapheme cluster is CRLF, and no rendered line can hold one
      # (every caller splits on '\n' first). Tabs and lone CRs still count as one cell.
      Screen.draw_width("hello").should eq(5)
      Screen.draw_width("a\tb").should eq(3)
      Screen.draw_width("ab\rc").should eq(4)
      Screen.draw_width("").should eq(0)
    end
  end

  # Screen#input_line is the shared single-line field renderer (~30 call sites: Scope,
  # Rules, Palette, the History query bar, every TextField overlay). Its caret and its
  # click inverse have to be exact inverses of each other, or the block caret paints over
  # the neighbouring glyph and a click lands off by the same amount. They drifted: the
  # caret was measured with display_width (a zero-width char = 0 columns) while every
  # field's click-to-cursor goes through Screen.column_for, which floors each CODEPOINT to
  # ≥1. `parse_printable` accepts U+200B / U+FEFF / a combining mark unfiltered, and a URL
  # carrying a zero-width char is a stock filter-bypass payload — reachable input here.
  it "input_line puts the caret exactly where column_for maps that column back" do
    value = "ab\u{200B}cd" # ZWSP at index 2: display_width 0, column_width 1, drawn 1 cell
    (0..value.size).each do |cx|
      b = MemoryBackend.new(40, 3)
      Screen.new(b).input_line(0, 1, value, cx, "", Theme.text)
      # The caret is the single cell painted on the ACCENT background.
      col = (0...40).select { |x| b.bg_at(x, 1) == Theme.accent }
      col.size.should eq(1) # exactly one caret cell (cx=#{cx})
      col[0].should eq(Screen.draw_width(value[0, cx]))  # sits on its own glyph
      Screen.column_for(value, col[0]).should eq(cx)       # a click there returns the same cx
      Screen.display_width(value[0, cx]).should be <= cx   # (the old measure could only under-count)
    end
    # Concretely: past the ZWSP the two measures disagree by one, which is exactly the
    # column the caret used to be short by.
    Screen.display_width(value[0, 3]).should eq(2)
    Screen.draw_width(value[0, 3]).should eq(3)
  end

  it "text draws a tab as a one-column space (ASCII and mixed paths)" do
    # ASCII fast path
    b1 = MemoryBackend.new(10, 1)
    Screen.new(b1).text(0, 0, "a\tb", Theme.text)
    b1.row(0).rstrip.should eq("a b")
    # Non-ASCII path (any multibyte glyph forces grapheme walk) still keeps the tab cell
    b2 = MemoryBackend.new(10, 1)
    Screen.new(b2).text(0, 0, "a\t가", Theme.text)
    b2.row(0).rstrip.should eq("a 가")
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
