require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Regression coverage for ReadCursor's multi-line selection math. The read-only
# panes (History detail, Repeater/Fuzzer response, Notes, Decoder) all share this,
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

    # A VERTICAL ⇧step keeps the caret's column (clamped), so ⇧↓ ends exactly where a plain ↓
    # would. It used to snap to the destination line's EOL, which is what made the upward case
    # below select nothing at all — see `ReadCursor#move`.
    it "keeps the column on a downward ⇧step, ending where a plain ↓ would" do
      down = ReadCursor.new
      down.sync(0, 2)                         # anchor at col 2 of the short top line
      down.move(1, 0, lines, selecting: true) # Shift+Down → caret (1, 2)
      down.cy.should eq(1)
      down.cx.should eq(2)
      down.selection_text(lines).should eq("#{lines[0][2..]}\n#{lines[1][0...2]}")
    end

    # THE REGRESSION THIS PAIR EXISTS FOR. From column 0 the EOL snap made an upward ⇧step
    # collapse to a bare "\n" with NO painted band: the boundary columns belong to their
    # document-order lines, so the caret's column lands on the TOP line, and the caret had been
    # parked at that line's end. Live, in the Comparer: ⇧↓⇧↓ copied 47b and ⇧↑ copied 1b.
    it "selects a real span on an UPWARD ⇧step from column 0 (not a bare newline)" do
      up = ReadCursor.new
      up.sync(1, 0)
      up.move(-1, 0, lines, selecting: true) # Shift+Up → caret (0, 0), anchor (1, 0)
      up.selection_text(lines).should eq("#{lines[0]}\n")
      up.highlight_spans(lines).should_not be_empty
    end

    it "paints a band for an upward ⇧step from mid-line" do
      up = ReadCursor.new
      up.sync(1, 3)
      up.move(-1, 0, lines, selecting: true) # caret (0, 3), anchor (1, 3)
      up.selection_text(lines).should eq("#{lines[0][3..]}\n#{lines[1][0...3]}")
      up.highlight_spans(lines).map(&.[](0)).should eq([0, 1])
    end

    # Document-order boundary assignment, with the two columns DIFFERENT so a swap would show.
    # `move_to` is the soft-wrapped panes' path (History detail, Repeater response), where the
    # caret really can stop at a column the anchor does not share.
    it "applies the CARET column to the top line for an upward selection (not the anchor's)" do
      up = ReadCursor.new
      up.sync(1, 10)                    # caret at col 10 of the long middle line
      up.move_to(0, 2, selecting: true) # ⇧↑ under wrap → caret (0, 2), anchor (1, 10)
      up.selection_text(lines).should eq("#{lines[0][2..]}\n#{lines[1][0...10]}")
      # Reversed, the top line would be sliced at 10 (past its length) and the bottom at 2.
      up.selection_text(lines).should_not eq("\n#{lines[1][0...2]}")
    end

    # A pane whose screen row is not one run of text (Comparer, Miner, Sequencer) asks for whole
    # lines explicitly. Both boundary columns are set by DIRECTION, so this works upward too.
    describe "#extend_lines" do
      it "grows whole lines downward" do
        rc = ReadCursor.new
        rc.sync(0, 2) # a column the caret happened to carry in
        rc.extend_lines(1, lines.size, ->(i : Int32) { lines[i] })
        rc.selection_text(lines).should eq("#{lines[0]}\n#{lines[1]}")
      end

      it "grows whole lines UPWARD" do
        rc = ReadCursor.new
        rc.sync(1, 4)
        rc.extend_lines(-1, lines.size, ->(i : Int32) { lines[i] })
        rc.selection_text(lines).should eq("#{lines[0]}\n#{lines[1]}")
        rc.selected_line_range.should eq({0, 1})
      end
    end
  end

  # An anchor sitting exactly on the caret selects no characters and paints no band, so it must
  # not report a selection: `copy_text` reads `selection_text || current_line` everywhere, and
  # a "" here defeated the fallback — `y` on an invisible selection copied nothing.
  describe "an EMPTY selection" do
    it "is not a selection, and copies as nil rather than an empty string" do
      rc = ReadCursor.new
      rc.sync(1, 4)
      rc.move(0, 1, lines, selecting: true) # ⇧→ …
      rc.selection?.should be_true
      rc.move(0, -1, lines, selecting: true) # … then ⇧← back onto the anchor
      rc.selection?.should be_false
      rc.selection_text(lines).should be_nil
      rc.highlight_spans(lines).should be_empty
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

# `sync_from` and `click` differ in ONE way that decides what a mouse press means, and two
# controllers picked the wrong one: `ReadCursor#sync` moves the caret and deliberately leaves
# the anchor alone ("without disturbing selection", per its own doc), so a Decoder/JWT INPUT
# press in READ mode used to re-shape a ⇧arrow selection instead of dropping it. Every other
# read pane clicks through `TextReadState#click`, which collapses. The drag added in the same
# change depends on this: `sync_to(selecting: true)` plants its anchor with `||=`, so without a
# collapsing press it would extend from wherever an older selection had been left.
describe Gori::Tui::TextReadState do
  it "keeps the selection on sync_from and collapses it on a click" do
    ed = TextArea.new("alpha bravo\ncharlie delta\necho foxtrot")
    rect = Rect.new(0, 0, 40, 5)
    ed.render(Screen.new(MemoryBackend.new(40, 5)), rect, true) # the editor learns its geometry

    read = TextReadState.new
    read.select_line(ed)
    read.selection?.should be_true

    read.sync_from(ed)
    read.selection?.should be_true # a caret adopt is not a selection gesture

    read.click(ed, rect, 3, 1) # a plain press on line 1
    read.selection?.should be_false
    read.cursor.cy.should eq(1)
  end

  it "grows the selection from the press position on a drag" do
    ed = TextArea.new("alpha bravo\ncharlie delta\necho foxtrot")
    rect = Rect.new(0, 0, 40, 5)
    ed.render(Screen.new(MemoryBackend.new(40, 5)), rect, true)

    read = TextReadState.new
    read.click(ed, rect, 0, 0)                  # press at line 0 col 0
    read.click(ed, rect, 7, 1, selecting: true) # drag into line 1
    read.selection?.should be_true
    text = read.copy_text(ed)
    text.should start_with("alpha bravo")
    text.should_not contain("foxtrot") # the drag stopped on line 1
  end
end
