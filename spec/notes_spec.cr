require "./spec_helper"
require "../src/gori/notes"

describe Gori::Notes do
  describe "Doc#texts" do
    it "strips terminal control sequences from note bodies but preserves newlines/tabs and leaves stored text raw" do
      # `gori run notes` (and --all) print doc.texts straight to STDOUT. A note body carrying an
      # OSC "set window title" (ESC ] 0 ; … BEL) would drive the terminal — texts is the CLI
      # listing accessor, so it neutralizes the control bytes while keeping the note's own line
      # breaks/tabs. The STORED NoteEntry text must stay raw (persistence + TUI editing see it).
      esc = 27.chr # ESC 0x1B
      bel = 7.chr  # BEL 0x07
      raw = "line1#{esc}]0;INJECTED#{bel}\nline2\twith tab"
      entries = [Gori::Notes::NoteEntry.new(1_i64, raw)]
      doc = Gori::Notes::Doc.new(0, entries, 2_i64)

      out = doc.texts.first
      out.includes?(esc).should be_false # ESC stripped
      out.includes?(bel).should be_false # BEL stripped
      out.should contain("line1")
      out.should contain("INJECTED")   # payload text remains (defanged)
      out.should contain("\nline2")    # newline preserved (multi-line notes stay intact)
      out.should contain("\twith tab") # tab preserved

      doc.notes.first.text.should eq(raw) # stored entry untouched — round-trips raw for persistence
    end
  end
end
