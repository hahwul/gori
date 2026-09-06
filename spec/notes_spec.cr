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
  # The id allocator is a HIGH-WATER MARK, and `merge` used to rebuild it from the surviving
  # notes alone — so a save could hand it BACK, and the next `create` re-minted an id an
  # earlier note had already used. That breaks the merge's own premise ("`mine` carry
  # cross-session-unique ids, so a peer's new note can't be mistaken for an edit of ours"):
  # the two notes with one id fold into one, and whichever text merged last wins.
  describe ".merge" do
    it "never hands the id allocator back below what the persisted set already spent" do
      # Notes 2..4 were created and deleted by a peer, so nothing surviving carries their ids —
      # only `next_id` remembers them. This session opened before any of that and still counts
      # from 2.
      persisted = Gori::Notes::Doc.new(0, [Gori::Notes::NoteEntry.new(1_i64, "kept")], 5_i64)
      mine = [Gori::Notes::NoteEntry.new(1_i64, "kept, edited")]

      merged = Gori::Notes.merge(persisted, mine, Set(Int64).new, 1_i64, 2_i64)

      merged.notes.map(&.id).should eq([1_i64])
      merged.next_id.should eq(5_i64)
    end

    it "still advances past a surviving id the persisted allocator had not reached" do
      persisted = Gori::Notes::Doc.new(0, [Gori::Notes::NoteEntry.new(1_i64, "kept")], 2_i64)
      mine = [Gori::Notes::NoteEntry.new(1_i64, "kept"), Gori::Notes::NoteEntry.new(9_i64, "new")]
      Gori::Notes.merge(persisted, mine, Set(Int64).new, 9_i64, 10_i64).next_id.should eq(10_i64)
    end
  end
  # `entity_links` rows are keyed by (Note, id), and nothing else ever reclaims them. Only the
  # TUI dropped a closed note's links, and it dropped them on the KEYPRESS — before the
  # document that removes the note had been written — so a refused save left the note alive
  # with its evidence links already destroyed. Both engine entry points do it after the commit
  # now, which also covers `gori run notes delete` and MCP `delete_note`.
  describe "link cleanup" do
    it "drops a deleted note's links once the write has committed" do
      with_store do |store|
        id = Gori::Notes.create(store, "evidence").not_nil!
        store.add_link(Gori::Store::LinkOwnerKind::Note, id, Gori::Store::LinkRefKind::Flow, 7_i64)
        store.list_links(Gori::Store::LinkOwnerKind::Note, id).size.should eq(1)

        Gori::Notes.delete(store, id).should eq(Gori::Notes::Write::Committed)
        store.list_links(Gori::Store::LinkOwnerKind::Note, id).should be_empty
      end
    end

    it "drops them for a whole-session save that closed the note, and leaves a survivor's alone" do
      with_store do |store|
        closed = Gori::Notes.create(store, "closing").not_nil!
        kept = Gori::Notes.create(store, "keeping").not_nil!
        store.add_link(Gori::Store::LinkOwnerKind::Note, closed, Gori::Store::LinkRefKind::Flow, 7_i64)
        store.add_link(Gori::Store::LinkOwnerKind::Note, kept, Gori::Store::LinkRefKind::Flow, 8_i64)

        merged = Gori::Notes.save(store, [Gori::Notes::NoteEntry.new(kept, "keeping")],
          Set{closed}, kept, 3_i64).not_nil!
        merged.notes.map(&.id).should eq([kept])

        store.list_links(Gori::Store::LinkOwnerKind::Note, closed).should be_empty
        store.list_links(Gori::Store::LinkOwnerKind::Note, kept).size.should eq(1)
      end
    end
  end
end
