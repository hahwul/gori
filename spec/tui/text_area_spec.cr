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
end
