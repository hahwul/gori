require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `ReadPane`'s opt-in soft wrap — the same Burp-style contract the Repeater request pane, the
# History detail and the Fuzzer template carry, reached through one component instead of a
# hand-rolled copy per pane. Its five consumers (Decoder OUTPUT, Intercept preview, Probe
# AFFECTED, the OAST callback detail, the Rewriter PREVIEW OUTPUT) all take it; the four that
# self-draw through `viewport_top` deliberately do not.

# One column wider than the rect: `Frame.scroll_gauge` rides the border column immediately right
# of the content, so a rect flush to the backend's edge silently drops it (see read_pane_spec).
private def render_wrapped(pane : Gori::Tui::ReadPane, w = 40, h = 8, focused = true,
                           styled_at : (Int32 -> Gori::Tui::Highlight::Line)? = nil) : MemoryBackend
  b = MemoryBackend.new(w + 1, h)
  pane.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, w, h), focused, styled_at)
  b
end

private def wrapped_pane(lines : Array(String), gutter = false) : Gori::Tui::ReadPane
  pane = Gori::Tui::ReadPane.new(gutter: gutter, wrap: true)
  pane.source(lines)
  pane
end

describe "Gori::Tui::ReadPane soft wrap" do
  # The contract: a line too wide for the pane spills onto continuation rows, and the line
  # number is printed once, on the first of them.
  it "wraps a long line and numbers only its first visual row" do
    pane = wrapped_pane(["short", "HEAD#{"." * 80}TAIL", "last"], gutter: true)
    b = render_wrapped(pane, w: 40, h: 8)
    gw = Gutter.width(3)
    head_row = (0...8).find { |y| b.row(y).includes?("HEAD") }.not_nil!
    b.row(head_row)[0, gw].should_not eq(" " * gw) # numbered
    b.row(head_row + 1)[0, gw].should eq(" " * gw) # continuation: no number
    b.contains?("TAIL").should be_true             # on screen, not clipped off the right edge
    # …and the number that IS printed is the logical line's, not the drawn row's.
    b.row(head_row)[0, gw].strip.should eq("2")
    b.contains?("last").should be_true # the next logical line still follows below the wrap
  end

  # A wrapping pane has no sideways: `hscroll` is inert and `xscroll` stays pinned, so a stored
  # offset the renderer no longer reads can never fight the clamp.
  it "ignores hscroll once wrapping" do
    pane = wrapped_pane(["HEAD#{"." * 80}TAIL"])
    render_wrapped(pane)
    10.times { pane.hscroll(1) }
    pane.xscroll.should eq(0)
    b = render_wrapped(pane)
    b.row(0)[0, 4].should eq("HEAD") # still starts at column 0 of the buffer's own row
  end

  # ↓ steps one VISUAL row. Stepping a logical LINE jumped the caret over every continuation
  # row the pane was drawing — rows that are on screen and that nothing but this arrow reaches.
  it "moves the caret down one visual row at a time, then onto the next line" do
    pane = wrapped_pane(["#{"z" * 200}", "SENTINEL"])
    b = render_wrapped(pane, w: 40, h: 8)
    cw = 40 # no gutter
    b.contains?("zzz").should be_true
    pane.cursor.cy.should eq(0)
    pane.move(1, 0)
    pane.cursor.cy.should eq(0)  # still the same LINE …
    pane.cursor.cx.should eq(cw) # … one wrapped row into it, at the same column
    rows = (200 + cw - 1) // cw
    (rows - 2).times { pane.move(1, 0) }
    pane.cursor.cy.should eq(0)
    pane.cursor.cx.should eq((rows - 1) * cw)
    pane.move(1, 0)
    pane.cursor.cy.should eq(1) # SENTINEL, several wrapped rows below the first
  end

  # ↑ is the exact inverse: a run of ↓ then the same number of ↑ lands back where it began.
  it "moves the caret back up through the wrapped rows it came down" do
    pane = wrapped_pane(["#{"z" * 200}", "SENTINEL"])
    render_wrapped(pane, w: 40, h: 8)
    3.times { pane.move(1, 0) }
    pane.cursor.cy.should eq(0)
    pane.cursor.cx.should be > 0
    3.times { pane.move(-1, 0) }
    pane.cursor.cy.should eq(0)
    pane.cursor.cx.should eq(0)
  end

  # `at_top?` is what a controller consults to decide whether ↑ should leave for the pane above.
  # Gated on the logical line alone, a caret three rows into a wrapped line 0 answers true — so
  # ↑ pops focus instead of walking the rows it was asked to walk.
  it "is not 'at top' while the caret sits on a continuation row of line 0" do
    pane = wrapped_pane(["#{"q" * 200}", "next"])
    render_wrapped(pane, w: 40, h: 8)
    pane.at_top?.should be_true
    pane.move(1, 0)
    pane.cursor.cy.should eq(0)
    pane.cursor.cx.should be > 0
    pane.at_top?.should be_false
    pane.move(-1, 0)
    pane.at_top?.should be_true
  end

  # Home is a LOGICAL line start, so from a caret parked several rows into a wrapped line it
  # has to pull the ANCHOR back with it — otherwise the caret jumps to a row above the window
  # and the next frame's `ensure_visible` is the only thing that saves it.
  it "scrolls the anchor back when Home leaves a continuation row" do
    pane = wrapped_pane([(0...12).map { |i| "R#{i}".ljust(40, '.') }.join])
    render_wrapped(pane, w: 40, h: 8)
    20.times { pane.move(1, 0) } # walk well past the first viewport of wrapped rows
    pane.scroll_sub.should be > 0
    pane.motion_key(Termisu::Event::Key.new(Termisu::Input::Key::Home)).should be_true
    pane.cursor.cx.should eq(0)
    pane.scroll_sub.should eq(0) # …and the pane is showing the row the caret is on again
    b = render_wrapped(pane, w: 40, h: 8)
    b.row(0)[0, 2].should eq("R0")
  end

  # The wheel steps DRAWN rows. With a line-indexed offset one notch jumped a whole wrapped
  # line, so most of a long body was unreachable by scrolling.
  it "scrolls by one visual row per notch" do
    # ONE logical line, built so that every 40-column visual row starts with its own marker —
    # otherwise the rows of a uniform filler line are textually identical and "the second row is
    # now the first" holds vacuously.
    pane = wrapped_pane([(0...12).map { |i| "R#{i}".ljust(40, '.') }.join])
    b = render_wrapped(pane, w: 40, h: 8)
    b.row(0)[0, 2].should eq("R0")
    b.row(1)[0, 2].should eq("R1")
    pane.scroll_view(1)
    b2 = render_wrapped(pane, w: 40, h: 8)
    b2.row(0)[0, 2].should eq("R1") # one notch = exactly one drawn row
    b2.row(1)[0, 2].should eq("R2")
    pane.scroll_view(3)
    b3 = render_wrapped(pane, w: 40, h: 8)
    b3.row(0)[0, 2].should eq("R4")
  end

  # …and it stops one viewport short of the end rather than scrolling the content off the top.
  it "clamps the wheel at the last visual row" do
    pane = wrapped_pane(["#{"m" * 400}", "ENDLINE"])
    render_wrapped(pane, w: 40, h: 8)
    500.times { pane.scroll_view(1) }
    b = render_wrapped(pane, w: 40, h: 8)
    b.contains?("ENDLINE").should be_true # the last row is on screen …
    b.row(7)[0, 7].should eq("ENDLINE")   # … on the pane's BOTTOM line, not above it
    b.row(0)[0, 3].should_not eq("   ")   # …and the pane is still full, not scrolled past
  end

  # A click on a continuation row must resolve to the logical line drawn there, at the column
  # the row's own text starts from. `ReadCursor`'s own hit test resolves `scroll + row`, which
  # on a wrapping pane names a line that is not drawn under the pointer at all.
  it "round-trips a click on a continuation row" do
    pane = wrapped_pane(["short", "0123456789" * 12])
    render_wrapped(pane, w: 40, h: 8)
    cw = 40
    pane.click(Rect.new(0, 0, 40, 8), 2, 2) # row 2 = the second visual row of line 1
    pane.cursor.cy.should eq(1)
    pane.cursor.cx.should eq(cw + 2)
  end

  # A click past the end of a wrapped row stops at the break rather than running into the next
  # row's characters — `Wrap.row_index` clamps to the row it was given.
  it "clamps a click past the end of a wrapped row to that row's break" do
    pane = wrapped_pane(["#{"x" * 50}"]) # wraps once: 40 cols, then 10
    render_wrapped(pane, w: 40, h: 8)
    pane.click(Rect.new(0, 0, 40, 8), 39, 1) # far right of the SECOND row, past its 10 chars
    pane.cursor.cy.should eq(0)
    pane.cursor.cx.should eq(50) # the line's end, not into a row below
  end

  # Where wrap meets #592's pointer rounding. `Screen.column_for_click` / `Wrap.row_index(
  # nearest:)` round a POINTER to the CLOSER edge of the cluster its column lands in, so the
  # right half of a 2-cell glyph resolves to the position AFTER it; without that, half of every
  # pointer position over CJK or Hangul lands a character short. The wrapped click path is a
  # second inverse of the same rule, so it has to round the same way — on a CONTINUATION row,
  # where the columns are measured from the wrap break rather than from the line's start.
  it "rounds a click on a wide glyph to the nearer edge on a continuation row" do
    # 30 glyphs × 2 columns = 60, so 20 land on row 0 and 10 wrap onto row 1.
    pane = wrapped_pane(["#{"한" * 30}"])
    render_wrapped(pane, w: 40, h: 8)
    rect = Rect.new(0, 0, 40, 8)
    # Row 1 holds glyphs 20.. — its first glyph occupies columns 0-1.
    pane.click(rect, 0, 1) # LEFT half of glyph 20 → in front of it
    pane.cursor.cy.should eq(0)
    pane.cursor.cx.should eq(20)
    pane.click(rect, 1, 1) # RIGHT half of the same glyph → after it, not short of it
    pane.cursor.cx.should eq(21)
    pane.click(rect, 2, 1) # left half of glyph 21
    pane.cursor.cx.should eq(21)
  end

  # A double-click on a continuation row takes the word UNDER the pointer.
  it "double-click selects the word under a continuation row" do
    pane = wrapped_pane(["#{"x" * 60}NEEDLE#{"y" * 10}"])
    b = render_wrapped(pane, w: 40, h: 8)
    ny = (0...8).find { |y| b.row(y).includes?("NEEDLE") }.not_nil!
    nx = b.row(ny).index("NEEDLE").not_nil!
    pane.select_word(Rect.new(0, 0, 40, 8), nx, ny).should be_true
    # The run is x…xNEEDLEy…y — one unbroken word-char token, so the whole line is the word.
    pane.copy_text.should eq("#{"x" * 60}NEEDLE#{"y" * 10}")
    pane.cursor.cy.should eq(0)
  end

  # A selection covering a wrap break must tint to the END of the visual row, then resume on the
  # next one. Clipped to the LINE instead it is painted once, at the first row's columns, and
  # the rest of the selection reads as unselected.
  it "tints a selection across a wrap break to the end of the row and onto the next" do
    pane = wrapped_pane(["0123456789" * 12])
    cw = 40
    render_wrapped(pane, w: cw, h: 8)
    (cw + 5).times { pane.move(0, 1, selecting: true) }
    b = render_wrapped(pane, w: cw, h: 8)
    b.bg_grid[0][0].should eq(Theme.accent_bg)
    b.bg_grid[0][cw - 1].should eq(Theme.accent_bg) # …tinted to the row's end
    b.bg_grid[1][0].should eq(Theme.accent_bg)      # …and resumed below
    b.bg_grid[1][4].should eq(Theme.accent_bg)
    # column 5 is the caret cell itself (also accent_bg); the tint must stop right after it.
    b.bg_grid[1][6].should_not eq(Theme.accent_bg)
  end

  # The block caret has to be drawn on the row it is actually on. Measured from column 0 of the
  # LINE it rides the line's first visual row forever, addressing text it is not on.
  it "draws the caret on the continuation row it walked onto" do
    pane = wrapped_pane(["#{"c" * 60}NEEDLE"])
    b = render_wrapped(pane, w: 40, h: 8)
    60.times { pane.move(0, 1) }
    b2 = render_wrapped(pane, w: 40, h: 8)
    ny = (0...8).find { |y| b2.row(y).includes?("NEEDLE") }.not_nil!
    nx = b2.row(ny).index("NEEDLE").not_nil!
    b2.bg_grid[ny][nx].should eq(Theme.accent_bg)
    b.contains?("NEEDLE").should be_true # it was already drawn there before the caret arrived
  end

  # A STYLED pane (the Intercept preview, the Fuzzer detail overlay) must wrap on the same grid
  # it draws: the layout is measured on the plain line while the draw slices the styled one, so
  # the two have to agree char-for-char or the colours land a column off the glyphs.
  it "slices a styled line to the same row the plain layout wrapped it at" do
    text = "#{"a" * 50}RED#{"b" * 10}"
    pane = Gori::Tui::ReadPane.new(wrap: true)
    pane.source(1, ->(_i : Int32) { text })
    styled = ->(_i : Int32) do
      line = Highlight::Line.new
      line << Highlight::Span.new("a" * 50, Theme.text)
      line << Highlight::Span.new("RED", Theme.red)
      line << Highlight::Span.new("b" * 10, Theme.text)
      line
    end
    b = render_wrapped(pane, w: 40, h: 8, styled_at: styled)
    # RED starts at char 50 → column 10 of the SECOND visual row, and keeps its colour there.
    b.row(1)[10, 3].should eq("RED")
    b.fg_at(10, 1).should eq(Theme.red)
    b.fg_at(9, 1).should eq(Theme.text)
  end

  # A single grapheme cluster wider than the pane still gets a row of its own — `Wrap.layout`
  # places a cluster whole or moves it whole, so it can never be cut in half.
  it "keeps a wide cluster whole across the break" do
    # 2 columns per glyph, so 30 glyphs are 60 columns: the line wraps at glyph 20 and the
    # remaining 10 land on the second row. `row` gives a wide glyph its lead cell plus a blank
    # continuation, so each glyph is ONE character of the joined row string.
    pane = wrapped_pane(["#{"한" * 30}"])
    b = render_wrapped(pane, w: 40, h: 8)
    b.row(0)[0, 1].should eq("한")
    b.row(0).count('한').should eq(20) # exactly 20 glyphs fit in 40 columns …
    b.row(1).count('한').should eq(10) # … and the other 10 wrapped, none of them split
    b.row(1)[0, 1].should eq("한")
  end

  # `source` re-points the pane AND drops the wrap memo: the same line index holding different
  # bytes must not be sliced at the old line's breaks.
  it "re-wraps after the content changes under the same line indices" do
    pane = wrapped_pane(["#{"w" * 100}"])
    render_wrapped(pane, w: 40, h: 8)
    pane.source(["SHORT"])
    b = render_wrapped(pane, w: 40, h: 8)
    b.row(0)[0, 5].should eq("SHORT")
    b.row(1)[0, 5].should eq("     ") # nothing left over from the wrapped line it replaced
  end
end
