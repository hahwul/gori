require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# A wrapping editor rendered into a `w` × `h` pane, with the gutter on (the Repeater
# request shape). Returns the editor and the painted screen so a spec can assert both the
# cells and the caret state the same frame produced.
private def wrap_render(text : String, w : Int32, h : Int32, gutter : Bool = true,
                        highlight : Symbol? = nil, cursor : Bool = false,
                        ta : Gori::Tui::TextArea? = nil) : {Gori::Tui::TextArea, MemoryBackend}
  ed = ta || Gori::Tui::TextArea.new(text)
  ed.gutter = gutter
  ed.wrap = true
  b = MemoryBackend.new(w, h)
  ed.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, w, h), cursor: cursor, highlight: highlight)
  {ed, b}
end

describe "Gori::Tui::TextArea soft wrap" do
  # THE Burp-style contract the feature is named for: a logical line spills onto as many
  # rows as it needs, and the line NUMBER appears exactly once — on the first of them. A
  # continuation row is blank in the gutter and its text starts in the same column as the
  # first row's, so the reader can still see at a glance where line 2 begins and ends.
  #
  # Before soft wrap this assertion could not even be posed: line 2's tail was clipped at
  # the pane edge (or reachable only by ⇧→), and screen row 2 held line 3.
  describe "gutter numbering" do
    it "numbers the first visual row of a logical line and leaves continuations blank" do
      _, b = wrap_render("short\n#{"x" * 30}\nlast", 20, 6)
      gw = Gutter.width(3) # 3 lines → 2 number columns + 1 gap
      b.row(0)[0, gw].should eq(" 1 ")
      b.row(0)[gw..].rstrip.should eq("short")
      b.row(1)[0, gw].should eq(" 2 ")
      b.row(1)[gw..].should eq("x" * (20 - gw)) # first row of line 2, filled to the edge
      b.row(2)[0, gw].should eq("   ")          # continuation: NO number
      b.row(2)[gw..].rstrip.should eq("x" * (30 - (20 - gw)))
      b.row(3)[0, gw].should eq(" 3 ") # line 3 got pushed down by the wrap
      b.row(3)[gw..].rstrip.should eq("last")
    end

    # The gutter is sized from the LOGICAL line count. Wrapping multiplies the drawn rows,
    # and if the width tracked those instead, the text column would shift sideways every
    # time a line happened to spill — the numbers name logical lines, and there are still
    # exactly as many of those as before.
    it "does not widen the gutter because wrapping produced more rows" do
      _, b = wrap_render("#{"y" * 200}\nz", 20, 12)
      gw = Gutter.width(2)
      gw.should eq(3)
      # 200 chars over 17 content columns = 12 rows; the second line is off the bottom, so
      # the gutter must still be sized for "2", not for the dozen rows on screen.
      (0...12).each { |r| b.row(r)[0, gw].should eq(r == 0 ? " 1 " : "   ") }
    end
  end

  describe "breaking on display columns" do
    # Width correctness is the whole risk in this layer. A CJK glyph is TWO cells, so a
    # break computed on String#size puts half a glyph past the right edge — the terminal
    # then either drops it or smears it over the pane border.
    it "never splits a wide CJK glyph across the break" do
      # 5 content columns; "한글날" is 6, so the third syllable must move down whole.
      ed, b = wrap_render("한글날개", 8, 4, gutter: true)
      # gutter is 3 wide for a 1-line buffer, leaving 5 content columns for 2 glyphs.
      ed.last_rows.map { |r| "한글날개"[r.a...r.b] }.should eq(["한글", "날개"])
      b.grid[0][3].should eq('한')
      b.grid[0][5].should eq('글')
      b.grid[0][7].should eq(' ') # the odd column stays empty rather than half a glyph
      b.grid[1][3].should eq('날')
    end

    it "never splits a combining sequence or a ZWJ family" do
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
      ed, _ = wrap_render("ab#{family}cd", 10, 4, gutter: false)
      # Every row must reconstruct the source exactly — a split cluster would lose or
      # duplicate codepoints here.
      ed.last_rows.map { |r| ed.lines_snapshot[r.li][r.a...r.b] }.join.should eq("ab#{family}cd")
    end
  end

  # The inverse of render. A click on a continuation row must resolve to the logical
  # column that is actually drawn there — before wrap, screen row 1 WAS logical line 1, so
  # this click landed on the wrong line entirely.
  describe "click hit-testing" do
    it "round-trips a click on a continuation row to the right logical column" do
      line = "0123456789" * 4 # 40 chars, one logical line
      ed, _ = wrap_render(line, 20, 6, gutter: false)
      # 20 content columns ⇒ rows are [0,20), [20,40).
      ed.click_to_cursor(Rect.new(0, 0, 20, 6), 3, 1) # row 1, column 3
      ed.cy.should eq(0)
      ed.cx.should eq(23)
      ed.click_to_cursor(Rect.new(0, 0, 20, 6), 0, 1)
      ed.cx.should eq(20) # column 0 of the continuation row is the break itself
      ed.click_to_cursor(Rect.new(0, 0, 20, 6), 7, 0)
      ed.cx.should eq(7) # …and the first row is unchanged
    end

    it "agrees with where the caret paints, on a continuation row" do
      line = "0123456789" * 4
      ed, _ = wrap_render(line, 20, 6, gutter: false)
      ed.click_to_cursor(Rect.new(0, 0, 20, 6), 5, 1)
      b = MemoryBackend.new(20, 6)
      ed.render(Screen.new(b), Rect.new(0, 0, 20, 6), cursor: true)
      # The caret cell is the one the click named: row 1, column 5, holding '5'.
      b.grid[1][5].should eq('5')
      b.bg_grid[1][5].should eq(Theme.accent)
    end

    it "clamps a click past the end of a wrapped row to the break, not the next row's text" do
      ed, _ = wrap_render("0123456789" * 4, 20, 6, gutter: false)
      ed.click_to_cursor(Rect.new(0, 0, 20, 6), 19, 0)
      ed.cx.should eq(19) # last cell of row 0 …
      ed.click_to_cursor(Rect.new(0, 0, 20, 6), 25, 0)
      ed.cx.should eq(20) # … and past it stops at the break
    end
  end

  describe "caret movement across a wrap boundary" do
    it "steps ↓ onto the continuation row of the SAME logical line" do
      ed, _ = wrap_render("#{"0123456789" * 4}\nnext", 20, 6, gutter: false)
      ed.place_cursor(0, 5)
      ed.move(1, 0)
      ed.cy.should eq(0)  # still logical line 1 …
      ed.cx.should eq(25) # … one visual row down, same display column
      ed.move(1, 0)
      ed.cy.should eq(1) # now onto the next logical line
      ed.cx.should eq(4) # clamped to its length ("next" is 4 wide)
    end

    it "steps ↑ back over the boundary to the column it came from" do
      ed, _ = wrap_render("0123456789" * 4, 20, 6, gutter: false)
      ed.place_cursor(0, 27)
      ed.move(-1, 0)
      ed.cx.should eq(7)
      ed.move(-1, 0)
      ed.cx.should eq(7) # already on the first row — nowhere further up
    end

    # ↑ on a continuation row must NOT pop focus out of the pane: there are still rows
    # above the caret inside it.
    it "reports at_top?/at_bottom? per VISUAL row, not per logical line" do
      ed, _ = wrap_render("0123456789" * 6, 20, 6, gutter: false) # 60 chars ⇒ 3 rows
      ed.place_cursor(0, 25)
      ed.at_top?.should be_false
      ed.at_bottom?.should be_false
      ed.place_cursor(0, 3)
      ed.at_top?.should be_true
      ed.place_cursor(0, 59)
      ed.at_bottom?.should be_true
    end

    it "keeps the caret on a cluster boundary when it crosses onto a CJK row" do
      ed, _ = wrap_render("abcde한글날abc", 11, 4, gutter: false)
      ed.place_cursor(0, 1)
      ed.move(1, 0)
      # Whatever row it lands on, the index must start a cluster — never between the two
      # halves of a wide glyph.
      line = ed.lines_snapshot[0]
      Screen.cluster_start(line, ed.cx).should eq(ed.cx)
    end
  end

  # NORMAL mode drives the caret through `TextReadState`, not `TextArea#move` — and NORMAL is
  # the mode the request pane opens in, so it is the ↓ the operator actually presses. It
  # stepped logical LINES while INSERT stepped visual rows: on a long header or a minified
  # body that jumped the caret over every continuation row the pane was drawing, and the two
  # modes disagreed about what "down" meant in the one pane that wraps.
  describe "READ-mode caret movement (NORMAL)" do
    it "steps ↓ onto the continuation row of the SAME logical line" do
      ed, _ = wrap_render("#{"0123456789" * 4}\nnext", 20, 6, gutter: false)
      read = TextReadState.new
      ed.place_cursor(0, 5)
      read.move(ed, 1, 0)
      ed.cy.should eq(0)  # still logical line 1 …
      ed.cx.should eq(25) # … one visual row down at the same column, exactly as INSERT does
      read.move(ed, 1, 0)
      ed.cy.should eq(1) # only now onto the next logical line
      ed.cx.should eq(4) # clamped to its length
    end

    it "steps ↑ back over the boundary to the column it came from" do
      ed, _ = wrap_render("0123456789" * 4, 20, 6, gutter: false)
      read = TextReadState.new
      ed.place_cursor(0, 27)
      read.move(ed, -1, 0)
      ed.cx.should eq(7)
      read.move(ed, -1, 0)
      ed.cx.should eq(7) # first row already — nowhere further up
    end

    # ⇧↓ has to end where a plain ↓ would or the selection covers rows the operator never
    # crossed. Under wrap that lands mid-line, which the char rectangle already models — the
    # end-of-line snap was only ever what stepping whole lines happened to produce.
    it "extends a selection by one visual row, not to the end of the logical line" do
      line = "0123456789" * 4
      ed, _ = wrap_render(line, 20, 6, gutter: false)
      read = TextReadState.new
      ed.place_cursor(0, 5)
      read.move(ed, 1, 0, selecting: true)
      ed.cx.should eq(25)
      read.copy_text(ed).should eq(line[5...25])
    end

    # A `§value¦chain§` marker's chain segment is concealed: it occupies no cells, so a ↓ that
    # measured the raw text would park the caret on a character that is not on screen — where
    # the operator sees the caret in one place and the next keystroke acts somewhere else.
    # `Wrap.row_index` steps over a run rather than into it; this is the read path proving it.
    it "lands outside a concealed run when it steps onto the row holding one" do
      # Row 0 is the 20 x's; row 1 draws "§v§yyyy", the "¦b64" between them being hidden.
      text = "#{"x" * 20}§v¦b64§yyyy"
      run = {22, 26} # the "¦b64" chars
      ed = TextArea.new(text)
      ed.conceal_spans = [run]
      ed, _ = wrap_render(text, 20, 6, gutter: false, ta: ed)
      read = TextReadState.new
      ed.place_cursor(0, 2)
      read.move(ed, 1, 0)
      ed.cy.should eq(0)
      # Display column 2 of row 1 is the CLOSING §: the hidden run drew nothing, so the two
      # columns before it are "§v". Measuring the raw text instead would stop on the "¦".
      ed.cx.should eq(26)
      (run[0]...run[1]).should_not contain(ed.cx)
    end

    # Every non-wrapping owner — Notes, the project description, the Fuzzer template — keeps
    # the logical step it always had; there are no continuation rows for it to visit.
    it "still steps logical lines when the editor does not wrap" do
      ed = TextArea.new("#{"0123456789" * 4}\nnext")
      ed.gutter = false
      ed.render(Screen.new(MemoryBackend.new(20, 6)), Rect.new(0, 0, 20, 6), cursor: false)
      read = TextReadState.new
      ed.place_cursor(0, 5)
      read.move(ed, 1, 0)
      ed.cy.should eq(1)
      ed.cx.should eq(4)
    end
  end

  describe "vertical scrolling in visual rows" do
    # @scroll indexes LOGICAL lines and would drift the moment anything wrapped; the anchor
    # is (line, sub-row) and the wheel moves it one DRAWN row at a time.
    it "scrolls by one visual row, not one logical line" do
      ed, _ = wrap_render("#{"a" * 60}\n#{"b" * 60}", 20, 4, gutter: false)
      ed.scroll_view(1)
      b = MemoryBackend.new(20, 4)
      ed.render(Screen.new(b), Rect.new(0, 0, 20, 4), cursor: false)
      b.row(0).should eq("a" * 20) # the SECOND row of line 1, not line 2
      ed.last_rows[0].a.should eq(20)
      ed.last_rows[0].li.should eq(0)
    end

    it "scrolls the caret's row into view when it is below the pane" do
      ed, _ = wrap_render("#{"a" * 200}\ntail", 20, 4, gutter: false)
      ed.place_cursor(1, 0)
      b = MemoryBackend.new(20, 4)
      ed.render(Screen.new(b), Rect.new(0, 0, 20, 4), cursor: true)
      b.row(3).rstrip.should eq("tail") # caret's row is the last visible one
      ed.last_rows.last.li.should eq(1)
    end
  end

  describe "search highlight" do
    # A match straddling the break is highlighted on BOTH rows. Per-row scanning would
    # find it on neither, which is strictly worse than the horizontal scrolling this
    # replaced (that at least showed the match once you scrolled to it).
    it "marks both halves of a match that crosses a wrap break" do
      ed, b = wrap_render("aaaaaaaaNEEDLEaaaa", 12, 4, gutter: false)
      ed.search_hl = "needle"
      b = MemoryBackend.new(12, 4)
      ed.render(Screen.new(b), Rect.new(0, 0, 12, 4), cursor: false)
      (8..11).each { |x| b.bg_grid[0][x].should eq(Theme.yellow) } # "NEED"
      (0..1).each { |x| b.bg_grid[1][x].should eq(Theme.yellow) }  # "LE"
      b.bg_grid[0][7].should_not eq(Theme.yellow)
      b.bg_grid[1][2].should_not eq(Theme.yellow)
    end
  end

  describe "coexistence with the request editor's other overlays" do
    it "keeps syntax colours across the break" do
      ed, b = wrap_render("GET /aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1", 20, 6,
        gutter: false, highlight: :request)
      # Whole line reconstructed from the drawn rows, so nothing was dropped at the seam.
      ed.last_rows.map { |r| ed.lines_snapshot[r.li][r.a...r.b] }.join
        .should eq("GET /aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1")
      b.row(0).should eq("GET /aaaaaaaaaaaaaaa")
      b.row(1).should eq("aaaaaaaaaaaaaaa HTTP")
      b.row(2).rstrip.should eq("/1.1")
    end

    # The hidden `¦chain` of a §…§ marker occupies no cells, so it must buy no width in the
    # wrap either — counting it shortens every row on the marked line.
    it "wraps a concealed marker line by what is actually drawn" do
      text = "GET /?a=§v¦b64§ HTTP/1.1"
      ed = Gori::Tui::TextArea.new(text)
      ed.conceal_spans = [{10, 14}] # the "¦b64" run
      ed, b = wrap_render(text, 20, 6, gutter: false, ta: ed)
      # 24 raw chars, 20 drawn (4 concealed) — exactly one row.
      ed.last_rows.size.should eq(1)
      b.row(0).should eq("GET /?a=§v§ HTTP/1.1")
    end
  end
end
