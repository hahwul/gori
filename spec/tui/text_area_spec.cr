require "../spec_helper"

include Gori::Tui

private def env_key(k : Termisu::Input::Key)
  Termisu::Event::Key.new(k)
end

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

  describe "#env_complete ($ENV autocomplete)" do
    before_each do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"HOST", "api.test"}, {"TOKEN", "s3cr3t-value"}, {"TOKEN2", "other"}]
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    after_each do
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
      Gori::Settings.env_prefix = "$"
    end

    it "stays inert until enabled" do
      ta = TextArea.new
      ta.insert('$')
      ta.env_completing?.should be_false
    end

    it "opens on a bare prefix and offers every registered var" do
      ta = TextArea.new
      ta.env_complete = true
      ta.insert('$')
      ta.env_completing?.should be_true
    end

    it "filters as a partial key is typed and Tab accepts the selected var" do
      ta = TextArea.new
      ta.env_complete = true
      "$TO".each_char { |c| ta.insert(c) } # matches TOKEN + TOKEN2
      ta.env_completing?.should be_true
      ta.handle_env_complete_key(env_key(Termisu::Input::Key::Tab)).should be_true
      ta.text.should eq("$TOKEN") # first match (sorted), whole token rewritten
      ta.env_completing?.should be_false
    end

    it "closes once the sole match is fully typed (nothing to complete)" do
      ta = TextArea.new
      ta.env_complete = true
      "$HOST".each_char { |c| ta.insert(c) }
      ta.env_completing?.should be_false
    end

    it "does not treat a non-key partial as an env token ($1 is literal)" do
      ta = TextArea.new
      ta.env_complete = true
      "$1".each_char { |c| ta.insert(c) }
      ta.env_completing?.should be_false
    end

    it "closes when the caret leaves the token (Home/arrow)" do
      ta = TextArea.new
      ta.env_complete = true
      "$TOK".each_char { |c| ta.insert(c) }
      ta.env_completing?.should be_true
      ta.home
      ta.env_completing?.should be_false
    end

    it "↓ then Enter accepts the second match" do
      ta = TextArea.new
      ta.env_complete = true
      "$TO".each_char { |c| ta.insert(c) }
      ta.handle_env_complete_key(env_key(Termisu::Input::Key::Down)).should be_true
      ta.handle_env_complete_key(env_key(Termisu::Input::Key::Enter)).should be_true
      ta.text.should eq("$TOKEN2")
    end

    it "opens nothing when no vars are registered" do
      Gori::Settings.env_vars = [] of {String, String}
      ta = TextArea.new
      ta.env_complete = true
      ta.insert('$')
      ta.env_completing?.should be_false
    end
  end
end
