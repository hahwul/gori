require "../spec_helper"

include Gori::Tui

# `TextReadState#bind` — the READ selection is dropped when the state is handed a different
# document, whether that is another `TextArea` (Notes: one read state, one editor per sub-tab)
# or the same editor with its bytes replaced (a peer reload, `^E`'s hand-back, a project
# switch). The anchor is a (line, column) pair into the text it was made in; carried across,
# it painted a band the operator never made and `y` put the other document on the clipboard.
private def area(text : String) : TextArea
  ta = TextArea.new
  ta.set_text(text)
  ta
end

private def select_word(state : TextReadState, ed : TextArea, cy : Int32, cx : Int32) : Nil
  ed.place_cursor(cy, cx)
  state.select_word_at_cursor(ed).should be_true
end

describe Gori::Tui::TextReadState do
  it "drops the band when asked about a different editor" do
    a = area("alpha beta\ngamma delta")
    b = area("zzzzzzzzzzzzzz")
    state = TextReadState.new
    select_word(state, a, 0, 7)
    state.selection?(a).should be_true
    state.copy_text(a).should eq("beta")

    state.selection?(b).should be_false
    state.copy_text(b).should eq("zzzzzzzzzzzzzz") # the caret LINE, not a band clamped into it
    state.cursor.cy.should eq(b.cy)
    state.cursor.cx.should eq(b.cx)
  end

  it "drops the band when the same editor's text is replaced" do
    ed = area("alpha beta gamma")
    state = TextReadState.new
    select_word(state, ed, 0, 7)
    state.copy_text(ed).should eq("beta")

    ed.set_text("zzzzzzzzzzzzzzzzzzzz")
    state.selection?(ed).should be_false
    state.copy_text(ed).should eq("zzzzzzzzzzzzzzzzzzzz")
  end

  it "drops the band on an outside replacement that keeps the caret" do
    ed = area("alpha beta gamma")
    state = TextReadState.new
    select_word(state, ed, 0, 7)
    ed.replace_from_outside("zzzzzzzzzzzzzzzzzzzz")
    state.selection?(ed).should be_false
  end

  it "keeps the band while the document is the one it was made in" do
    ed = area("alpha beta\ngamma delta")
    state = TextReadState.new
    select_word(state, ed, 0, 7)
    # Painting-adjacent calls that do not touch the text: the same state, the same revision.
    state.sync_from(ed)
    state.selection?(ed).should be_true
    state.move(ed, 1, 0, selecting: true)
    state.selection?(ed).should be_true
    state.copy_text(ed).should eq("beta\ngamma delt")
  end

  it "adopts an INSERT selection made after typing moved the revision" do
    ed = area("alpha beta")
    state = TextReadState.new
    state.sync_from(ed) # INS entered: bound at this revision
    ed.place_cursor(0, 10)
    ed.insert('!') # the revision moves under the bound state
    ed.home(true)  # ⇧Home: the editor's own band over the whole line
    state.adopt_editor_selection(ed).should be_true
    # The adoption is what the next paint sees — a stale binding would drop it there.
    state.sync_from(ed)
    state.selection?(ed).should be_true
    state.copy_text(ed).should eq("alpha beta!")
  end
end
