require "../spec_helper"

private alias SS = Gori::Screenshot

private CANVAS = SS::RGB.hex("#0a0a0b")
private INK    = SS::RGB.hex("#c8c8cc")

# A frame from plain text rows, expanding a wide glyph into lead + continuation exactly as
# ingest and the TUI backend do. Short rows are padded with canvas cells.
private def text_frame(lines : Array(String), canvas = CANVAS, ink = INK) : SS::Frame
  rows = lines.map do |line|
    row = [] of SS::Cell
    line.each_grapheme do |gr|
      g = gr.to_s
      row << SS::Cell.new(g, ink, canvas)
      row << SS::Cell.new("", ink, canvas, cont: true) if Termisu::UnicodeWidth.grapheme_width(g) == 2
    end
    row
  end
  cols = rows.max_of?(&.size) || 0
  cells = [] of SS::Cell
  rows.each { |r| cols.times { |x| cells << (r[x]? || SS::Cell.new(" ", ink, canvas)) } }
  SS::Frame.new(cols, rows.size, cells, bg: canvas, fg: ink)
end

module Gori::Screenshot
  describe RGB do
    it "resolves the terminal default to the caller's fallback, not to black" do
      # `Color.default` is ansi8(-1), and termisu's own to_rgb_components answers {0,0,0}
      # for it. Taking that answer is what would paint a light theme's canvas black.
      Termisu::Color.default.to_rgb_components.should eq({0_u8, 0_u8, 0_u8})

      paper = RGB.hex("#faf9f7")
      RGB.of(Termisu::Color.default, paper).should eq(paper)
      RGB.of(Termisu::Color.default, paper).should_not eq(RGB.new(0_u8, 0_u8, 0_u8))
    end

    it "converts a concrete colour through termisu's own palette" do
      RGB.of(Termisu::Color.rgb(1, 2, 3), CANVAS).to_hex.should eq("#010203")
      # ansi8(1) is termisu's classic red, NOT the VS Code one the reference python held.
      RGB.of(Termisu::Color.ansi8(1), CANVAS).to_hex.should eq("#aa0000")
    end

    it "mixes with half-to-even rounding and reports luminance" do
      # The two values the SVG goldens pin: the outer hairline and the title bar over
      # GORIDARK's canvas.
      CANVAS.mix(RGB.new(255_u8, 255_u8, 255_u8), 0.16).to_hex.should eq("#313132")
      CANVAS.mix(RGB.new(255_u8, 255_u8, 255_u8), 0.06).to_hex.should eq("#19191a")
      CANVAS.luminance.should be < 0.5
      RGB.hex("faf9f7").luminance.should be > 0.5
    end
  end

  describe ".cell" do
    it "swaps a reversed cell's colours and drops the bit" do
      c = Screenshot.cell("x", Termisu::Color.rgb(1, 1, 1), Termisu::Color.rgb(9, 9, 9),
        Termisu::Attribute::Reverse | Termisu::Attribute::Bold, false,
        canvas: CANVAS, ink: INK)
      c.fg.to_hex.should eq("#090909")
      c.bg.to_hex.should eq("#010101")
      c.attr.reverse?.should be_false
      c.attr.bold?.should be_true
    end

    it "inverts a reversed cell that had no explicit colours" do
      # Resolution happens BEFORE the swap, so reverse-on-default is a real inversion —
      # which is what a terminal shows (and where the reference python was a no-op).
      c = Screenshot.cell(" ", Termisu::Color.default, Termisu::Color.default,
        Termisu::Attribute::Reverse, false, canvas: CANVAS, ink: INK)
      c.fg.should eq(CANVAS)
      c.bg.should eq(INK)
    end

    it "keeps every other attribute bit for the renderers to decide about" do
      attr = Termisu::Attribute::Dim | Termisu::Attribute::Underline |
             Termisu::Attribute::Hidden | Termisu::Attribute::Blink |
             Termisu::Attribute::Cursive | Termisu::Attribute::Strikethrough
      c = Screenshot.cell("x", Termisu::Color.default, Termisu::Color.default, attr, false,
        canvas: CANVAS, ink: INK)
      c.attr.should eq(attr)
    end
  end

  describe Frame do
    it "reads a blank canvas cell outside the grid" do
      f = text_frame(["ab"])
      f.at(-1, 0).should eq(f.blank_cell)
      f.at(0, 9).should eq(f.blank_cell)
      f.at(0, 0).grapheme.should eq("a")
    end

    it "maps every character of row_text back to the column its cell starts at" do
      # ASCII, a wide CJK glyph, a ZWJ family (also wide), and a combining cluster.
      f = text_frame(["a한b👨‍👩‍👧‍👦é"])
      f.row_text(0).should eq("a한b👨‍👩‍👧‍👦é")

      cols = f.row_columns(0)
      cols.size.should eq(f.row_text(0).size)
      # a@0  한@1 (wide → next is 3)  b@3  family@4 (wide → next is 6)  e@6  U+0301@6
      family = "👨‍👩‍👧‍👦"
      cols[0].should eq(0)
      cols[1].should eq(1)
      cols[2].should eq(3)
      family.size.times { |i| cols[3 + i].should eq(4) }
      cols[3 + family.size].should eq(6)
      cols[4 + family.size].should eq(6)
      cols.last.should eq(6)
    end

    it "skips continuation columns in row_text and honours the x window" do
      f = text_frame(["a한b"])
      f.cols.should eq(4)
      f.row_text(0, 1, 3).should eq("한")
      f.row_columns(0, 1, 3).should eq([1])
      # The window's right edge cuts the wide glyph's continuation off; the lead still
      # contributes its whole grapheme, which is what keeps a span edge off a half glyph.
      f.row_text(0, 1, 2).should eq("한")
    end

    it "calls a row of spaces over a band content, not blank" do
      band = RGB.hex("#26262c")
      cells = [
        Cell.new(" ", INK, CANVAS), Cell.new(" ", INK, CANVAS),
        Cell.new(" ", INK, band), Cell.new(" ", INK, CANVAS),
      ]
      f = Frame.new(2, 2, cells, bg: CANVAS, fg: INK)
      f.blank_row?(0).should be_true
      f.blank_row?(1).should be_false
      f.last_content_row.should eq(1)
    end

    it "reports -1 for a frame with nothing on it" do
      text_frame(["  ", "  "]).last_content_row.should eq(-1)
      Frame.new(0, 0, [] of Cell, bg: CANVAS, fg: INK).last_content_row.should eq(-1)
    end

    it "trims trailing blank rows before slicing a tail" do
      f = text_frame(["one", "two", "three", "   ", "   "])
      f.rows.should eq(5)

      t = f.tail(2)
      t.rows.should eq(2)
      t.cols.should eq(f.cols)
      t.row_text(0).rstrip.should eq("two")
      t.row_text(1).rstrip.should eq("three")

      # A tail longer than the content is the whole trimmed frame, never padded back out.
      f.tail(99).rows.should eq(3)
      # A blank frame tails to nothing rather than to n rows of empty cells.
      text_frame(["  ", "  "]).tail(1).rows.should eq(0)
    end

    it "re-bases the wrap marks and cursor a tail keeps, and drops the rest" do
      f = text_frame(["one", "two", "three", "   "])
      marks = [WrapSpan.new(1, 0, 3), WrapSpan.new(2, 0, 3)]
      f = f.with(continuations: marks, cursor: {1, 2})

      t = f.tail(2)
      t.continuations.should eq([WrapSpan.new(0, 0, 3), WrapSpan.new(1, 0, 3)])
      t.cursor.should eq({1, 1})

      # A cursor above the slice is gone, not clamped to row 0 — it was not in the strip.
      f.with(cursor: {0, 0}).tail(1).cursor.should be_nil
    end

    it "carries metadata through `with` and compares only cells in same_cells?" do
      at = Time.utc(2026, 9, 17)
      f = Frame.new(1, 1, [Cell.new("x", INK, CANVAS)], bg: CANVAS, fg: INK,
        theme: "goriday", title: "t", captured_at: at, cursor: {0, 0})
      g = f.with(sanitized: 3, title: "u")
      g.theme.should eq("goriday")
      g.captured_at.should eq(at)
      g.cursor.should eq({0, 0})
      g.sanitized.should eq(3)
      g.title.should eq("u")
      f.sanitized.should be_nil

      f.same_cells?(g).should be_true
      f.same_cells?(Frame.new(1, 1, [Cell.new("y", INK, CANVAS)], bg: CANVAS, fg: INK))
        .should be_false
    end
  end
end
