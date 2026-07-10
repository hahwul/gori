require "../spec_helper"

include Gori::Tui

describe Gori::Tui::TextArea do
  describe "#home / #end_of_line" do
    it "jumps the caret to the start / end of the current line (insert lands there)" do
      ta = TextArea.new("abc")
      ta.end_of_line
      ta.insert('X') # appended at end
      ta.home
      ta.insert('Y') # prepended at start
      ta.text.should eq("YabcX")
    end
  end

  describe "#delete" do
    it "removes the char under the caret" do
      ta = TextArea.new("abc") # caret at column 0 after construction
      ta.delete
      ta.text.should eq("bc")
    end

    it "joins the next line when the caret is at end-of-line" do
      ta = TextArea.new("ab\ncd")
      ta.end_of_line # caret at end of line 0
      ta.delete      # forward-delete across the line break
      ta.text.should eq("abcd")
    end

    it "is a no-op at the very end of the buffer (does not dirty)" do
      ta = TextArea.new("ab")
      ta.end_of_line
      before = ta.edits
      ta.delete
      ta.text.should eq("ab")
      ta.edits.should eq(before)
    end
  end

  describe "#undo (array-snapshot)" do
    it "reverts a single-char insert" do
      ta = TextArea.new("ab")
      ta.end_of_line
      ta.insert('c')
      ta.text.should eq("abc")
      ta.undo
      ta.text.should eq("ab")
    end

    it "reverts a newline split and a subsequent line-join independently (multi-line ops)" do
      ta = TextArea.new("hello world")
      ta.move(0, 5)        # caret after "hello"
      ta.insert_newline    # -> "hello\n world"
      ta.text.should eq("hello\n world")
      ta.backspace         # join back -> "hello world"
      ta.text.should eq("hello world")
      ta.undo              # undo the join -> split again
      ta.text.should eq("hello\n world")
      ta.undo              # undo the split -> original
      ta.text.should eq("hello world")
    end

    it "keeps earlier snapshots intact after editing a restored buffer (no shared-array corruption)" do
      ta = TextArea.new("a\nb\nc")
      ta.end_of_line
      ta.insert('X')       # "aX\nb\nc"
      ta.insert('Y')       # "aXY\nb\nc"
      ta.undo              # back to "aX\nb\nc"
      ta.text.should eq("aX\nb\nc")
      ta.insert('Z')       # edit the restored buffer -> "aXZ\nb\nc"
      ta.text.should eq("aXZ\nb\nc")
      ta.undo              # the Z edit
      ta.text.should eq("aX\nb\nc")
      ta.undo              # the X edit -> original
      ta.text.should eq("a\nb\nc")
    end
  end
end
