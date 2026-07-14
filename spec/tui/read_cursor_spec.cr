require "../spec_helper"

include Gori::Tui

# Regression coverage for ReadCursor's multi-line selection math. The read-only
# panes (History detail, Replay/Fuzzer response, Notes, Decoder) all share this,
# so a wrongly-assigned boundary column corrupts copied text everywhere at once —
# and, for an upward selection over a short top line, used to crash on copy.
describe Gori::Tui::ReadCursor do
  lines = ["short", "a much longer line here", "another line"]

  describe "#selection_text over multiple lines" do
    it "copies an UPWARD selection without crashing when the top line is short" do
      rc = ReadCursor.new
      rc.sync(1, 20)                         # caret on the long line, col 20 (like a click)
      rc.move(-1, 0, lines, selecting: true) # Shift+Up → caret to line 0 (len 5), anchor stays (1,20)
      # Previously: line0[20..] → IndexError (20 > 5). Must not raise.
      txt = rc.selection_text(lines)
      txt.should_not be_nil
    end

    it "copies a downward selection from the anchor column to the caret column" do
      down = ReadCursor.new
      down.sync(0, 2)                         # anchor at col 2 of the short top line
      down.move(1, 0, lines, selecting: true) # Shift+Down → caret (1, EOL)
      # Top line from col 2 to end, then the whole bottom line (caret parked at EOL).
      down.selection_text(lines).should eq("#{lines[0][2..]}\n#{lines[1]}")
    end

    it "applies the CARET column to the top line for an upward selection (not the anchor's)" do
      up = ReadCursor.new
      up.sync(1, 3)                          # click at col 3 of the long middle line
      up.move(-1, 0, lines, selecting: true) # Shift+Up → caret (0, EOL of the short line)
      # Document order top→bottom is (0, EOL0) → (1, 3): the top line contributes nothing
      # (caret at its EOL), the bottom line runs from col 0 to the anchor's col 3.
      # The pre-fix code applied the anchor col (3) to line 0 and the caret col to line 1,
      # copying "rt\na m" instead.
      up.selection_text(lines).should eq("\n#{lines[1][0...3]}")
    end

    it "copies a clean full-line multi-line selection as whole lines" do
      rc = ReadCursor.new
      rc.sync(0, 0)                         # start at col 0
      rc.move(1, 0, lines, selecting: true) # Shift+Down → (1, EOL)
      rc.selection_text(lines).should eq("#{lines[0]}\n#{lines[1]}")
    end
  end

  describe "#highlight_spans" do
    it "paints the correct top-line span for an upward selection (no negative/oversized span)" do
      rc = ReadCursor.new
      rc.sync(1, 4)
      rc.move(-1, 0, lines, selecting: true) # caret → line 0 (len 5), anchor (1,4)
      spans = rc.highlight_spans(lines)
      spans.each do |(li, x0, x1)|
        x0.should be >= 0
        x1.should be <= lines[li].size
        x0.should be < x1
      end
    end
  end
end
