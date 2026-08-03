require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# INSERT-mode selection in the shared `TextArea` — the model behind the Repeater request
# pane's "⇧arrows select, Del removes it" once the view forwards the shift (see
# `RepeaterController#edit_repeater_request`, which names the one missing seam).
#
# READ mode has had a selection since ReadCursor; INS had none, so ⇧→ moved the caret like a
# bare → and ⌫ always took exactly one character. Everything here is about the INS half:
# where the anchor lives, what collapses it, what a delete does with it, and — the part the
# soft-wrap layer makes non-obvious — which CELLS the band covers when the selected run
# crosses a wrap break.

# An editor rendered into a `w` × `h` pane with the block caret on (i.e. INSERT), so a spec
# can assert the painted cells and the model in the same frame. Mirrors `text_area_wrap_spec`.
private def ins_render(ed : Gori::Tui::TextArea, w : Int32, h : Int32,
                       gutter : Bool = false, cursor : Bool = true) : MemoryBackend
  ed.gutter = gutter
  b = MemoryBackend.new(w, h)
  ed.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, w, h), cursor: cursor)
  b
end

describe "Gori::Tui::TextArea INSERT-mode selection" do
  describe "extending and collapsing" do
    it "⇧→ selects from the caret and a plain → collapses it" do
      ed = TextArea.new("hello")
      ed.selection?.should be_false
      ed.move(0, 1, selecting: true)
      ed.selection?.should be_true
      ed.selection_text.should eq("h")
      ed.move(0, 1, selecting: true)
      ed.selection_text.should eq("he")
      ed.move(0, 1) # unmodified arrow
      ed.selection?.should be_false
      ed.selection_text.should be_nil
    end

    # ⇧→ then ⇧← puts the caret back ON the anchor. If that still counted as a selection the
    # next ⌫ would delete the empty run and stop there — a key that visibly does nothing.
    it "reports no selection once the caret returns to the anchor" do
      ed = TextArea.new("hello")
      ed.move(0, 1, selecting: true)
      ed.move(0, -1, selecting: true)
      ed.selection?.should be_false
      ed.backspace # falls through to the ordinary one-character delete
      ed.text.should eq("hello")
      ed.move(0, 1)
      ed.backspace
      ed.text.should eq("ello")
    end

    # The anchor is shared with the read model's shape; the MOTION is this editor's own. A
    # ⇧↓ on a wrapped line steps ONE VISUAL ROW and keeps the display column — it does not
    # take the whole logical line the way `ReadCursor#move` does for a read-only pane, which
    # here would select 20 characters the caret never crossed.
    it "⇧↓ extends by one visual row on a wrapped line, not to end-of-line" do
      ed = TextArea.new("0123456789ABCDEFGHIJ")
      ed.wrap = true
      ins_render(ed, 12, 4)
      ed.move(1, 0, selecting: true)
      ed.selection_text.should eq("0123456789AB") # exactly the first visual row
    end

    it "extends across a line break" do
      ed = TextArea.new("hello\nworld")
      ed.place_cursor(0, 3)
      ed.move(1, 0, selecting: true)
      ed.selection_text.should eq("lo\nwor")
    end

    # Upward selections are where a hand-rolled copy goes wrong: the CARET column belongs to
    # the top line and the ANCHOR column to the bottom one, the reverse of a downward drag.
    # `selection_text` defers to ReadCursor precisely so that fix is not re-derived here.
    it "copies an upward selection in document order" do
      ed = TextArea.new("hello\nworld")
      ed.place_cursor(1, 1)
      ed.move(-1, 0, selecting: true)
      ed.selection_text.should eq("ello\nw")
    end
  end

  describe "deleting a selection" do
    it "⌫ removes the whole selection instead of one character" do
      ed = TextArea.new("hello world")
      ed.place_cursor(0, 1)
      4.times { ed.move(0, 1, selecting: true) }
      before = ed.edits
      ed.backspace
      ed.text.should eq("h world")
      ed.cx.should eq(1)
      ed.selection?.should be_false
      # The owner gates `mark_req_edit` on @edits changing — a cut that did not bump it
      # would delete the text and leave the tab clean, so the edit is never persisted.
      ed.edits.should_not eq(before)
    end

    it "Del removes the whole selection instead of the character under the caret" do
      ed = TextArea.new("hello world")
      ed.place_cursor(0, 1)
      4.times { ed.move(0, 1, selecting: true) }
      ed.delete
      ed.text.should eq("h world")
    end

    it "undoes the cut as one step" do
      ed = TextArea.new("hello world")
      ed.place_cursor(0, 1)
      4.times { ed.move(0, 1, selecting: true) }
      ed.backspace
      ed.text.should eq("h world")
      ed.undo
      ed.text.should eq("hello world")
    end

    # ⌫ at the very start of the buffer returns early ("no character before the caret"), and
    # that early return must not swallow a selection that begins there.
    it "removes a selection anchored at the buffer start" do
      ed = TextArea.new("hello")
      3.times { ed.move(0, 1, selecting: true) }
      ed.backspace
      ed.text.should eq("lo")
    end

    # The merged line keeps the LAST consumed line's terminator, exactly as a backspace-join
    # does. Keeping the first line's instead would put an LF where the capture had CRLF (or
    # the reverse) on a line the operator never touched — bytes on the wire, not a rendering
    # detail.
    it "keeps the trailing line's ending when the cut joins lines" do
      ed = TextArea.new("a\nbb\r\nccc")
      ed.place_cursor(0, 1)
      ed.move(1, 0, selecting: true) # caret to (1, 1)
      ed.selection_text.should eq("\nb")
      ed.backspace
      ed.text.should eq("ab\nccc")
      ed.wire_text.should eq("ab\r\nccc")
    end
  end

  describe "replace on type" do
    it "a printable typed over a selection replaces it, undoable as one step" do
      ed = TextArea.new("hello world")
      ed.place_cursor(0, 1)
      4.times { ed.move(0, 1, selecting: true) }
      ed.insert('X')
      ed.text.should eq("hX world")
      ed.selection?.should be_false
      ed.undo
      ed.text.should eq("hello world")
    end

    it "↵ over a selection replaces it with the break" do
      ed = TextArea.new("hello world")
      ed.place_cursor(0, 5)
      6.times { ed.move(0, 1, selecting: true) }
      ed.insert_newline
      ed.text.should eq("hello\n")
    end
  end

  describe "what collapses the selection" do
    # The wheel DRAGS the caret when the viewport would leave it behind. That drag is not a
    # selecting move: left alone it would stretch the selection to wherever the operator
    # scrolled, and the next keystroke would replace all of it.
    it "drops the selection when the wheel drags the caret, keeps it when it does not" do
      ed = TextArea.new((0...10).map { |i| "line#{i}" }.join("\n"))
      ins_render(ed, 20, 3)
      ed.place_cursor(2, 0)
      ed.move(0, 1, selecting: true)
      ed.scroll_view(1) # rows 1..3 — the caret on line 2 is still inside
      ed.selection?.should be_true
      ed.scroll_view(5) # the caret cannot stay on line 2
      ed.selection?.should be_false
    end

    it "drops the selection on a click, a goto and a read-mode caret write" do
      {->(e : TextArea) { e.click_to_cursor(Rect.new(0, 0, 20, 3), 2, 0) },
       ->(e : TextArea) { e.goto_line(2) },
       ->(e : TextArea) { e.place_cursor(1, 1) },
       ->(e : TextArea) { e.home },
       ->(e : TextArea) { e.end_of_line }}.each do |act|
        ed = TextArea.new("hello\nworld")
        ins_render(ed, 20, 3)
        ed.move(0, 1, selecting: true)
        ed.selection?.should be_true
        act.call(ed)
        ed.selection?.should be_false
      end
    end
  end

  describe "painting the band" do
    # THE wrap contract for an over-painter: a selection running past the right edge must
    # tint its row TO THE END and carry on at column 0 of the continuation row. Clipping to
    # the logical line instead paints one band at the first row's columns and leaves the
    # rest of the selected text looking unselected.
    it "tints to the end of a visual row and continues on the next" do
      ed = TextArea.new("0123456789ABCDEFGHIJ")
      ed.wrap = true
      ed.place_cursor(0, 8)
      8.times { ed.move(0, 1, selecting: true) } # chars 8…15, across the break at 12
      b = ins_render(ed, 12, 4)
      b.row(0).should eq("0123456789AB")
      b.row(1)[0, 8].should eq("CDEFGHIJ")
      (0...8).each { |x| b.bg_at(x, 0).should_not eq(Theme.accent_bg) } # before the anchor
      (8...12).each { |x| b.bg_at(x, 0).should eq(Theme.accent_bg) }    # to the row's end
      (0...4).each { |x| b.bg_at(x, 1).should eq(Theme.accent_bg) }     # and on into row 1
      b.bg_at(4, 1).should_not eq(Theme.accent_bg)                      # the caret cell, not the band
    end

    it "tints whole intermediate lines of a multi-line selection" do
      ed = TextArea.new("aaa\nbbb\nccc")
      ed.place_cursor(0, 2)
      ed.move(1, 0, selecting: true)
      ed.move(1, 0, selecting: true) # caret at (2, 2)
      b = ins_render(ed, 8, 3)
      b.bg_at(1, 0).should_not eq(Theme.accent_bg)
      b.bg_at(2, 0).should eq(Theme.accent_bg)
      (0...3).each { |x| b.bg_at(x, 1).should eq(Theme.accent_bg) } # the whole middle line
      (0...2).each { |x| b.bg_at(x, 2).should eq(Theme.accent_bg) }
      b.bg_at(2, 2).should_not eq(Theme.accent_bg)
    end

    # READ mode paints its OWN selection over this editor (`paint_request_read_chrome`), and
    # it is called with `focused && !insert`. Drawing this band there too would double-tint
    # in one mode and show a stale INS band in the other, so the block caret — on only in
    # INSERT — is the gate.
    it "does not paint the band while the block caret is off (READ mode)" do
      ed = TextArea.new("hello")
      3.times { ed.move(0, 1, selecting: true) }
      b = ins_render(ed, 8, 2, cursor: false)
      (0...8).each { |x| b.bg_at(x, 0).should_not eq(Theme.accent_bg) }
    end

    # A concealed `¦chain` occupies no cells, so the band has to be laid down as the VISIBLE
    # runs between the hidden ones. Painting straight through would tint the cells the
    # chain's neighbours stand in and shift the rest of the row right by its length.
    it "skips concealed characters instead of tinting through them" do
      ed = TextArea.new("abcdef")
      ed.conceal_spans = [{2, 4}] # "cd" is in the buffer but off the screen
      4.times { ed.move(0, 1, selecting: true) }
      ed.cx.should eq(6) # the caret hops the whole hidden run in one press
      b = ins_render(ed, 8, 2)
      b.row(0)[0, 4].should eq("abef")
      (0...4).each { |x| b.bg_at(x, 0).should eq(Theme.accent_bg) }
      b.bg_at(4, 0).should_not eq(Theme.accent_bg) # nothing was drawn past the last glyph
    end
  end
end
