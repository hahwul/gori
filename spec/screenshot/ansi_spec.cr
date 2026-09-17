require "../spec_helper"
require "../support/ansi_fixtures"

private alias SS = Gori::Screenshot

private INK   = SS::RGB.hex("#c8c8cc")
private PAPER = SS::RGB.hex("#0a0a0b")

# A 9x3 frame holding everything the serializer has to carry: one cell per attribute bit
# with per-cell colours, a row of wide glyphs, and a run of identical cells. The last row is
# deliberately NOT blank, so the trailing-blank trim is a no-op and the round-trip can be an
# equality rather than a "modulo trimming" comparison.
private def attr_frame : SS::Frame
  bits = [
    Termisu::Attribute::None,
    Termisu::Attribute::Bold,
    Termisu::Attribute::Dim,
    Termisu::Attribute::Cursive,
    Termisu::Attribute::Underline,
    Termisu::Attribute::Blink,
    Termisu::Attribute::Hidden,
    Termisu::Attribute::Strikethrough,
    Termisu::Attribute::Bold | Termisu::Attribute::Underline | Termisu::Attribute::Dim,
  ]
  cells = [] of SS::Cell
  bits.each_with_index do |attr, i|
    fg = SS::RGB.new((10 + i).to_u8, 20_u8, (200 - i).to_u8)
    bg = SS::RGB.new(1_u8, (i * 3).to_u8, 2_u8)
    cells << SS::Cell.new(('A' + i).to_s, fg, bg, attr)
  end
  # Row 1: two wide glyphs (each a lead plus a continuation carrying the lead's style, which
  # is the frame invariant) then five narrow cells.
  band = SS::RGB.hex("#26262c")
  "한글".each_char do |ch|
    cells << SS::Cell.new(ch.to_s, INK, band)
    cells << SS::Cell.new("", INK, band, cont: true)
  end
  "abcde".each_char { |ch| cells << SS::Cell.new(ch.to_s, INK, PAPER) }
  # Row 2: nine identical cells.
  9.times { cells << SS::Cell.new("x", INK, PAPER) }
  SS::Frame.new(9, 3, cells, bg: PAPER, fg: INK)
end

module Gori::Screenshot
  describe Ansi do
    it "round-trips a frame with CJK, per-cell colours and every attribute bit" do
      f = attr_frame
      back = Frame.from_ansi(Ansi.render(f), cols: f.cols)
      back.same_cells?(f).should be_true
    end

    it "round-trips the rich fixture, combining marks and all" do
      f = Frame.from_ansi(AnsiFixtures::RICH_FRAME)
      Frame.from_ansi(Ansi.render(f), cols: f.cols).same_cells?(f).should be_true
    end

    it "closes every row with a reset and a CRLF" do
      dump = Ansi.render(attr_frame)
      rows = dump.split("\r\n")
      rows.size.should eq(4) # three rows and the empty tail after the last CRLF
      rows.pop.should eq("")
      rows.all?(&.ends_with?("\e[0m")).should be_true
    end

    it "emits nothing at all for a cell whose style did not change" do
      # The whole of row 2 is one SGR, nine glyphs and the row's reset — if an unchanged
      # cell re-stated its colours this line would be ten times as long.
      line = Ansi.render(attr_frame).split("\r\n")[2]
      line.should eq("\e[38;2;200;200;204;48;2;10;10;11mxxxxxxxxx\e[0m")
    end

    it "resets and restates when an attribute bit goes away" do
      cells = [
        Cell.new("a", INK, PAPER, Termisu::Attribute::Bold),
        Cell.new("b", INK, PAPER),
      ]
      dump = Ansi.render(Frame.new(2, 1, cells, bg: PAPER, fg: INK))
      # SGR has no targeted "un-bold" that is safe across readers, so the second cell resets
      # — and then has to restate the colours the reset just cleared.
      dump.should eq("\e[38;2;200;200;204;48;2;10;10;11;1ma" \
                     "\e[0;38;2;200;200;204;48;2;10;10;11mb\e[0m\r\n")
    end

    it "drops trailing blank rows and answers empty for a frame with nothing on it" do
      cells = [Cell.new("a", INK, PAPER), Cell.new(" ", INK, PAPER)]
      Ansi.render(Frame.new(1, 2, cells, bg: PAPER, fg: INK))
        .should eq("\e[38;2;200;200;204;48;2;10;10;11ma\e[0m\r\n")
      Ansi.render(Frame.new(1, 1, [Cell.new(" ", INK, PAPER)], bg: PAPER, fg: INK)).should eq("")
    end

    it "writes a wide glyph once and lets the reader rebuild its continuation" do
      cells = [
        Cell.new("中", INK, PAPER),
        Cell.new("", INK, PAPER, cont: true),
      ]
      dump = Ansi.render(Frame.new(2, 1, cells, bg: PAPER, fg: INK))
      dump.count("中").should eq(1)
      Frame.from_ansi(dump, cols: 2).at(1, 0).cont?.should be_true
    end
  end
end
