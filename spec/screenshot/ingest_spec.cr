require "../spec_helper"
require "../support/ansi_fixtures"

module Gori::Screenshot
  describe ".from_ansi" do
    it "gives one row per line and never re-wraps" do
      # The framing decision was made by the terminal that drew the dump. A 50-column line
      # is a 50-column row, whatever width anything downstream would have chosen.
      f = Frame.from_ansi(("a" * 50) + "\nb\n")
      f.rows.should eq(2)
      f.cols.should eq(50)
      f.row_text(0).should eq("a" * 50)
      f.row_text(1).should eq("b" + " " * 49)
    end

    it "pads a short row with canvas cells rather than leaving it ragged" do
      f = Frame.from_ansi("abcd\nx\n")
      f.cols.should eq(4)
      f.at(3, 1).should eq(f.blank_cell)
      f.at(3, 1).bg.should eq(f.bg)
      f.blank_row?(1).should be_false
    end

    it "takes the column count the caller knows, clipping or padding to it" do
      f = Frame.from_ansi("abcdef\n", cols: 3)
      f.cols.should eq(3)
      f.row_text(0).should eq("abc")
    end

    it "reads truecolor, the 256 cube, the grey ramp and the basic/bright indices" do
      f = Frame.from_ansi("\e[38;2;1;2;3mA\e[38;5;39mB\e[38;5;244mC\e[31mD\e[91mE\n")
      f.at(0, 0).fg.to_hex.should eq("#010203")
      f.at(1, 0).fg.to_hex.should eq("#00afff")
      f.at(2, 0).fg.to_hex.should eq("#808080")
      # termisu's palette, which is the authority: the frame gori screenshots comes out of
      # termisu, so ansi8(1) is the classic red and ansi256(9) is it plus the bright boost.
      f.at(3, 0).fg.to_hex.should eq("#aa0000")
      f.at(4, 0).fg.to_hex.should eq("#ff5555")
    end

    it "reads a background index and resets it on SGR 0" do
      f = Frame.from_ansi("\e[48;2;38;38;44mAB\e[0mCD\n")
      f.at(0, 0).bg.to_hex.should eq("#26262c")
      f.at(2, 0).bg.should eq(f.bg)
    end

    it "swaps a reversed run's colours and drops the bit" do
      f = Frame.from_ansi("\e[38;2;200;200;204;48;2;10;10;11m\e[7mX\e[27mY\n")
      f.at(0, 0).fg.to_hex.should eq("#0a0a0b")
      f.at(0, 0).bg.to_hex.should eq("#c8c8cc")
      f.at(0, 0).attr.reverse?.should be_false
      f.at(1, 0).fg.to_hex.should eq("#c8c8cc")
    end

    it "gives an unstyled cell the DOMINANT colours, never black" do
      # The light-theme case, and the single highest-risk rule in the whole subsystem:
      # resolving an unstyled cell to termisu's {0,0,0} would paint a paper-white capture's
      # canvas and its unstyled text both black.
      paper = "\e[38;2;51;50;47;48;2;250;249;247m"
      f = Frame.from_ansi("#{paper}painted padding here\n#{paper}painted padding here\nbare\n")
      f.bg.to_hex.should eq("#faf9f7")
      f.fg.to_hex.should eq("#33322f")
      f.at(0, 2).bg.to_hex.should eq("#faf9f7")
      f.at(0, 2).fg.to_hex.should eq("#33322f")
    end

    it "falls back to the reference renderer's reset colours when nothing is styled" do
      f = Frame.from_ansi("plain\n")
      f.bg.should eq(Chrome::RESET_BG)
      f.fg.should eq(Chrome::RESET_FG)
    end

    it "places a wide glyph as a lead plus a continuation carrying its colours" do
      f = Frame.from_ansi("\e[48;2;38;38;44ma한b\n")
      f.cols.should eq(4)
      f.at(1, 0).grapheme.should eq("한")
      f.at(1, 0).cont?.should be_false
      f.at(2, 0).cont?.should be_true
      f.at(2, 0).grapheme.should eq("")
      # The band under a CJK run has to cover both halves, so the continuation carries the
      # lead's colours rather than the canvas.
      f.at(2, 0).bg.to_hex.should eq("#26262c")
      f.at(3, 0).grapheme.should eq("b")
    end

    it "composes a zero-width mark onto the cell before it, even across an SGR split" do
      # An escape between a base and its combining mark breaks the cluster into two parser
      # segments; the mark still belongs to the base's cell, which is what a terminal does.
      f = Frame.from_ansi("e\e[1ḿx\n")
      f.cols.should eq(2)
      f.at(0, 0).grapheme.should eq("é")
      f.at(1, 0).grapheme.should eq("x")
      f.row_text(0).should eq("éx")
    end

    it "drops a mark with nothing to compose onto" do
      f = Frame.from_ansi("́ab\n")
      f.row_text(0).should eq("ab")
    end

    it "reads the parity fixture the SVG goldens were rendered from" do
      f = Frame.from_ansi(AnsiFixtures::PARITY_FRAME)
      f.cols.should eq(20)
      f.rows.should eq(6)
      f.bg.to_hex.should eq("#0a0a0b")
      f.fg.to_hex.should eq("#c8c8cc")
      f.last_content_row.should eq(4)
      f.row_text(0).should eq("╭─ gori capture ───╮")
      f.row_text(2).should eq("│ inherits" + " " * 10)
      # Row 2's tail is bare after a reset, so it inherits — the golden's `inherits` run is
      # drawn in the dominant fg.
      f.at(2, 2).fg.to_hex.should eq("#c8c8cc")
      f.at(0, 0).attr.bold?.should be_false
      f.at(3, 0).attr.bold?.should be_true # the "gori" run
    end
  end
end
