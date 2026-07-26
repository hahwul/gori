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

  describe ".export_basename" do
    it "derives the filename from the note's title" do
      Gori::Notes.export_basename("My Note\nbody text", 0).should eq("My-Note.md")
      Gori::Notes.export_basename("  leading blank\n\nfirst real line", 0).should eq("leading-blank.md")
    end

    it "PRESERVES Korean/CJK titles instead of collapsing them to ASCII" do
      # The anti-regression against reaching for ProjectRegistry#slugify, which must emit an
      # ASCII directory slug and so hashes a non-ASCII name to project-<sha256>. A note titled
      # in Korean has to stay findable in a file listing.
      Gori::Notes.export_basename("인증 우회\n상세 내용", 0).should eq("인증-우회.md")
      Gori::Notes.export_basename("日本語のメモ", 0).should eq("日本語のメモ.md")
    end

    it "replaces path separators, so a title can never traverse" do
      Gori::Notes.export_basename("../../etc/passwd", 0).should eq("etc-passwd.md")
      Gori::Notes.export_basename("a/b\\c:d", 0).should eq("a-b-c-d.md")
      Gori::Notes.export_basename("re*port?<>|\"", 0).should eq("re-port.md")
    end

    it "falls back to note-N when the title yields nothing usable" do
      # The index is the sub-tab position, matching NotesView::Note#label's "note N" — a bare
      # ".md" (hidden, nameless) must be impossible.
      Gori::Notes.export_basename("", 2).should eq("note-3.md")
      Gori::Notes.export_basename("   \n\t ", 0).should eq("note-1.md")
      Gori::Notes.export_basename("..", 4).should eq("note-5.md")
      Gori::Notes.export_basename(".", 0).should eq("note-1.md")
      Gori::Notes.export_basename("///", 0).should eq("note-1.md")
    end

    it "strips control bytes that can never reach a filename" do
      esc = 27.chr
      bel = 7.chr
      out = Gori::Notes.export_basename("ti#{esc}tle#{bel}x", 0)
      out.includes?(esc).should be_false
      out.includes?(bel).should be_false
      out.should eq("ti-tle-x.md")
    end

    it "caps the length in CHARACTERS with no trailing separator, and always ends in .md" do
      long = Gori::Notes.export_basename("a" * 200, 0)
      long.size.should eq(Gori::Notes::FILENAME_MAX_CHARS + 3) # + ".md"
      long.should end_with(".md")

      # A cut landing on a '-' must not leave one dangling before the extension.
      cut = Gori::Notes.export_basename("#{"b" * (Gori::Notes::FILENAME_MAX_CHARS - 1)} tail", 0)
      cut.should_not contain("-.md")
      cut.should end_with(".md")

      # The cap is chars, not bytes: 48 multi-byte chars stay 48 chars.
      cjk = Gori::Notes.export_basename("가" * 200, 0)
      cjk.should eq("#{"가" * Gori::Notes::FILENAME_MAX_CHARS}.md")
    end
  end
end
