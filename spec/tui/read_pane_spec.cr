require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `ReadPane` is the one home for a scrollable read-only text pane: the ReadCursor, both scroll
# axes, the last drawn height, the draw (gutter / h-slice / selection band / block caret / scroll
# gauge) and every gesture. It was extracted from three hand-rolled copies (Decoder OUTPUT,
# Fuzzer RESULT detail, History detail) whose drift was already a bug — see the class comment —
# and it is what six read-only-but-unselectable panes are being built on.
private def pane_source(n : Int32) : Array(String)
  (0...n).map { |i| i == 3 ? "LONG#{"." * 60}TAIL" : "line#{i} word#{i}" }
end

# The backend is one column WIDER than the rect: `Frame.scroll_gauge` rides the border column
# immediately right of the content (real callers pass `card.inset(1, 1)`), so a rect flush to the
# backend's edge would push the gauge off-grid and silently drop it from every assertion.
private def render_pane(pane : ReadPane, w = 40, h = 6, focused = true,
                        styled_at : (Int32 -> Highlight::Line)? = nil) : MemoryBackend
  b = MemoryBackend.new(w + 1, h)
  pane.render(Screen.new(b), Rect.new(0, 0, w, h), focused, styled_at)
  b
end

describe Gori::Tui::ReadPane do
  describe "source" do
    # The whole reason the API is `(size, line_at)` and not `Array(String)`: the Intercept
    # preview reads through a `Highlight::Windowed` over a multi-MiB body, and a render that
    # touched every line would stall the UI fiber. Pin that a frame is viewport-bounded.
    it "only asks for the lines it draws" do
      asked = [] of Int32
      pane = ReadPane.new
      pane.source(5_000, ->(i : Int32) { asked << i; "line#{i}" })
      render_pane(pane, h: 6)
      asked.uniq.size.should be <= 12 # 6 drawn rows, each read for the draw + the width clamp
      asked.max.should be < 20        # never walks past the window
    end

    it "reports its size and answers out-of-range lines as empty" do
      pane = ReadPane.new
      pane.source(pane_source(4))
      pane.size.should eq(4)
      pane.empty?.should be_false
      pane.line(-1).should eq("")
      pane.line(9).should eq("")
      ReadPane.new.empty?.should be_true
    end
  end

  describe "render" do
    it "draws the window from the scroll offset, with numbers when the gutter is on" do
      pane = ReadPane.new(gutter: true)
      pane.source(pane_source(20))
      b = render_pane(pane, h: 4)
      b.row(0).should contain("1") # 1-based gutter for line index 0
      b.contains?("line0").should be_true
      b.contains?("line3").should be_false # below the 4-row fold (line 3 is the long one)

      12.times { pane.scroll_view(1) }
      pane.scroll.should eq(12)
      b2 = render_pane(pane, h: 4)
      b2.contains?("line0").should be_false
      b2.contains?("line15").should be_true # window 12..15, clamped at size - h = 16
    end

    # `styled_at` is colour ONLY: `Highlight`'s cardinal rule is that a styled line's span texts
    # concatenate back to the plain line, and the component leans on that — the block caret paints
    # `plain[cx]`, which is the glyph on screen precisely because the two agree.
    it "colours the row from styled_at while the caret and the copy read the plain line" do
      pane = ReadPane.new
      pane.source(["plain text here"])
      styled = ->(_i : Int32) {
        [Highlight::Span.new("plain ", Theme.red), Highlight::Span.new("text here", Theme.green)] of Highlight::Span
      }
      b = render_pane(pane, styled_at: styled)
      b.contains?("plain text here").should be_true
      b.fg_grid[0][8].should eq(Theme.green) # inside the second span
      b.fg_grid[0][2].should eq(Theme.red)   # inside the first, minus the caret cell at 0
      pane.copy_text.should eq("plain text here")
    end

    it "leaves the gauge off a pane that fits and on one that overflows" do
      short = ReadPane.new
      short.source(pane_source(3))
      render_pane(short, h: 8).contains?("┃").should be_false

      tall = ReadPane.new
      tall.source(pane_source(80))
      render_pane(tall, h: 8).contains?("┃").should be_true
    end
  end

  describe "keyboard" do
    it "moves the caret and grows a selection on ⇧ vertical steps" do
      pane = ReadPane.new
      pane.source(pane_source(10))
      pane.move(1, 0)
      pane.copy_text.should eq("line1 word1") # no selection → the caret's line
      pane.move(1, 0, selecting: true)
      pane.selection?.should be_true
      pane.copy_text.should contain("line1")
      pane.copy_text.should contain("line2")
    end

    it "selects the current line and clears it" do
      pane = ReadPane.new
      pane.source(pane_source(5))
      pane.move(2, 0)
      pane.select_line
      pane.selection?.should be_true
      pane.copy_text.should eq("line2 word2")
      pane.clear_selection
      pane.selection?.should be_false
    end

    it "handles Home / End / PageUp / PageDown, with ⇧ extending" do
      pane = ReadPane.new
      pane.source(pane_source(40))
      render_pane(pane, h: 6) # the pane learns its height, so a page is a real screenful

      pane.motion_key(key(Termisu::Input::Key::PageDown)).should be_true
      pane.cursor.cy.should be > 0
      pane.motion_key(key(Termisu::Input::Key::PageUp)).should be_true
      pane.cursor.cy.should eq(0)

      pane.motion_key(key(Termisu::Input::Key::End)).should be_true
      pane.cursor.cx.should eq("line0 word0".size)
      pane.motion_key(key(Termisu::Input::Key::Home, shift: true)).should be_true
      pane.selection?.should be_true # ⇧Home from EOL selects the line's text
      pane.copy_text.should eq("line0 word0")

      pane.motion_key(key(Termisu::Input::Key::LowerA)).should be_false # not a motion key
    end

    it "copies every line for the whole-pane fallback" do
      pane = ReadPane.new
      pane.source(["a", "b", "c"])
      pane.copy_all.should eq("a\nb\nc")
      ReadPane.new.copy_all.should eq("")
    end
  end

  describe "#scroll_view" do
    # The drift the extraction closed: the two hand-rolled copies disagreed about WHICH line the
    # column is clamped against, and the one that read the line the caret was leaving indexed a
    # position its own `cy` clamp had just ruled out of range.
    it "clamps the caret into the new window and measures the column against the line it lands on" do
      pane = ReadPane.new
      pane.source(pane_source(40))
      render_pane(pane, h: 6)
      pane.motion_key(key(Termisu::Input::Key::End)) # caret at EOL of a long-ish line
      long_cx = pane.cursor.cx

      pane.scroll_view(20)
      pane.cursor.cy.should be >= pane.scroll
      pane.cursor.cy.should be < pane.scroll + 6
      pane.cursor.cx.should be <= pane.line(pane.cursor.cy).size
      pane.cursor.cx.should be <= long_cx
    end

    it "is inert before the first frame and on a pane that fits" do
      pane = ReadPane.new
      pane.source(pane_source(40))
      pane.scroll_view(5) # no height yet
      pane.scroll.should eq(0)

      fits = ReadPane.new
      fits.source(pane_source(3))
      render_pane(fits, h: 8)
      fits.scroll_view(5)
      fits.scroll.should eq(0)
    end
  end

  describe "mouse" do
    it "places the caret at a click and takes the word on a double-click" do
      pane = ReadPane.new(gutter: true)
      pane.source(pane_source(6))
      b = render_pane(pane)
      y = (0...6).find { |r| b.row(r).includes?("word2") }.not_nil!
      x = b.row(y).index("word2").not_nil!

      pane.click(Rect.new(0, 0, 40, 6), x + 1, y)
      pane.cursor.cy.should eq(2)
      pane.select_word(Rect.new(0, 0, 40, 6), x + 1, y).should be_true
      pane.copy_text.should eq("word2")
    end

    it "extends the selection to the pointer on a drag" do
      pane = ReadPane.new
      pane.source(pane_source(6))
      rect = Rect.new(0, 0, 40, 6)
      render_pane(pane)
      pane.click(rect, 0, 0)                  # press on line 0 col 0
      pane.click(rect, 5, 1, selecting: true) # drag into line 1
      pane.selection?.should be_true
      pane.copy_text.should start_with("line0 word0")
      pane.copy_text.should_not contain("line2")
    end

    it "takes nothing on a double-click over whitespace past the line" do
      pane = ReadPane.new
      pane.source(pane_source(6))
      render_pane(pane)
      pane.select_word(Rect.new(0, 0, 40, 6), 38, 0).should be_false
    end
  end

  # The hand-rolled copies painted the caret and the band at `x + draw_width(line[0, cx])` with
  # no `- xscroll` term, so with the pane scrolled sideways both landed that many cells right of
  # the glyph they addressed — or off the pane entirely, drawing over a neighbour. The component
  # subtracts the offset and clips to the content width.
  describe "horizontal scroll" do
    it "keeps the caret inside the pane when the content is scrolled sideways" do
      pane = ReadPane.new
      pane.source(pane_source(6))
      rect = Rect.new(0, 0, 40, 6)
      pane.move(3, 0) # the long line
      pane.motion_key(key(Termisu::Input::Key::End))
      render_pane(pane)

      b = MemoryBackend.new(40, 6)
      pane.render(Screen.new(b), rect, true)
      b.contains?("LONG").should be_true

      15.times { pane.hscroll(1) }
      b2 = MemoryBackend.new(40, 6)
      pane.render(Screen.new(b2), rect, true)
      b2.contains?("TAIL").should be_true
      b2.contains?("LONG").should be_false # scrolled off the left
      pane.xscroll.should be > 0
    end
  end

  describe "line_select_only" do
    # For the Comparer: a screen row is TWO columns of a diff, so a char rectangle would address
    # cells that are not adjacent on screen. Selection is whole lines, and there is no word.
    it "selects whole lines and never a word" do
      pane = ReadPane.new(line_select_only: true)
      pane.source(pane_source(6))
      rect = Rect.new(0, 0, 40, 6)
      render_pane(pane)

      pane.select_word(rect, 3, 1).should be_false
      pane.move(1, 0, selecting: true)
      pane.selection?.should be_true
      # Whole first line, then the whole second — not a partial column span.
      pane.copy_text.should eq("line0 word0\nline1 word1")
    end
  end

  describe "#reset" do
    it "drops the caret, the selection and both scroll offsets" do
      pane = ReadPane.new
      pane.source(pane_source(40))
      render_pane(pane)
      pane.move(5, 0)
      pane.select_line
      10.times { pane.hscroll(1) }
      pane.scroll_view(10)

      pane.reset
      pane.cursor.cy.should eq(0)
      pane.cursor.cx.should eq(0)
      pane.selection?.should be_false
      pane.scroll.should eq(0)
      pane.xscroll.should eq(0)
    end
  end
end

private def key(k : Termisu::Input::Key, shift : Bool = false) : Termisu::Event::Key
  mods = shift ? Termisu::Input::Modifier::Shift : Termisu::Input::Modifier::None
  Termisu::Event::Key.new(k, mods, nil)
end
