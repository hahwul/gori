require "../spec_helper"
require "../support/ansi_fixtures"

module Gori::Screenshot
  describe Text do
    it "writes the rows a reader would retype, right-stripped and newline-terminated" do
      f = Frame.from_ansi(AnsiFixtures::PARITY_FRAME)
      Text.render(f).should eq(<<-TXT + "\n")
        ╭─ gori capture ───╮
        │ GET /a&b <x>     │
        │ inherits
        │  band REV        │
         12:34  ready
        TXT
    end

    it "drops the trailing blank rows and answers empty for a frame with nothing on it" do
      ink = RGB.hex("#c8c8cc")
      paper = RGB.hex("#0a0a0b")
      cells = [Cell.new("a", ink, paper), Cell.new(" ", ink, paper), Cell.new(" ", ink, paper)]
      Text.render(Frame.new(1, 3, cells, bg: paper, fg: ink)).should eq("a\n")
      Text.render(Frame.new(1, 1, [Cell.new(" ", ink, paper)], bg: paper, fg: ink)).should eq("")
    end

    it "emits a wide glyph once, not once per column it occupies" do
      f = Frame.from_ansi("a한b\n")
      f.cols.should eq(4)
      Text.render(f).should eq("a한b\n")
    end
  end
end
