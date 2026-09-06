require "../spec_helper"

include Gori::Tui

# `TextArea#replace_from_outside` — the ^E return path. The four external-editor returns all
# went through `set_text`, which puts the caret on line 1 and CLEARS the undo stack: edit
# line 400 of a note in $EDITOR, come back, and you were at the top with no ^Z.
describe "TextArea#replace_from_outside" do
  it "keeps the caret where it was and leaves the old text one undo away" do
    ta = TextArea.new((1..50).map { |i| "line #{i}" }.join("\n"))
    ta.move(40, 0) # read down to line 41
    ta.move(0, 3)
    ta.insert('X') # a prior edit that must survive as undoable
    ta.cy.should eq(40)
    ta.cx.should eq(4)
    before = ta.text
    ta.replace_from_outside((1..50).map { |i| "LINE #{i}" }.join("\n"))
    ta.cy.should eq(40) # still on the line the operator was reading
    ta.cx.should eq(4)
    ta.text.should start_with("LINE 1")
    ta.undo
    ta.text.should eq(before)
    ta.undo
    ta.text.should eq((1..50).map { |i| "line #{i}" }.join("\n"))
  end

  it "clamps the caret into a shorter replacement" do
    ta = TextArea.new("one\ntwo\nthree")
    ta.move(2, 0)
    ta.replace_from_outside("just one line")
    ta.cy.should eq(0)
    ta.cx.should be <= "just one line".size
  end
end
