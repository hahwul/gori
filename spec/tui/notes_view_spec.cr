require "../spec_helper"
require "../support/memory_backend"
require "json"

include Gori::Tui

# Type a string into the view, honouring embedded newlines.
private def type(view : NotesView, text : String) : Nil
  text.each_char { |c| c == '\n' ? view.newline : view.insert(c) }
end

# The persisted note bodies (parsed back out of the JSON KV value), or [] when
# nothing has been saved yet.
private def saved_notes(store : Gori::Store) : Array(String)
  Gori::Notes.load(store).texts
end

private def render_text(view : NotesView, w = 80, h = 10) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h))
  backend
end

describe Gori::Tui::NotesView do
  it "shows the scratchpad guide on a blank note" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      backend = render_text(view, 80, 14)
      backend.contains?("NOTES").should be_true
      backend.contains?("scratchpad").should be_true
    end
  end

  it "loads, edits inline, and persists the note set as JSON" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)

      type(view, "hi\nthere")
      view.save(store)

      saved_notes(store).should eq(["hi\nthere"])

      # a fresh view reloads the persisted document
      again = NotesView.new
      again.reload(store)
      backend = render_text(again)
      backend.contains?("there").should be_true
    end
  end

  it "soft-merge reload keeps caret when note text is unchanged (data_version poll)" do
    # Regression: full reload rebuilt every TextArea, zeroing caret/scroll on every
    # store write (capture, ui_state, …) even when the note body was identical.
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      view.enter_insert!
      type(view, "hello world")
      view.move(0, -5) # caret sits on the 'w' of "world"
      cy = view.@notes[0].area.cy
      cx = view.@notes[0].area.cx
      cx.should be > 0
      view.save(store)
      view.dirty?.should be_false

      view.reload(store) # soft-merge: same text → keep TextArea object
      view.@notes[0].area.cy.should eq(cy)
      view.@notes[0].area.cx.should eq(cx)
      view.current_text.should eq("hello world")
    end
  end

  it "reload is a no-op while dirty (never clobbers in-progress typing)" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "draft")
      view.dirty?.should be_true
      view.reload(store)
      view.current_text.should eq("draft")
      view.dirty?.should be_true
    end
  end

  it "soft-merge picks up a peer note body change for a clean buffer" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "local")
      view.save(store)
      id = view.current_note_id

      # Peer wrote a different body for the same note id.
      store.set_setting("notes.docs",
        %({"cur":0,"next_id":#{id + 1},"notes":[{"id":#{id},"text":"from-peer"}]}))
      view.reload(store)
      view.current_text.should eq("from-peer")
      view.dirty?.should be_false
    end
  end

  # `reload` skips the merge when the stored rows are the bytes it last merged. A save must
  # drop that memory: afterwards the list is this session's edits, and a peer writing back the
  # EXACT bytes the list was last merged from is a real change that has to land.
  it "merges a peer's write after a save even when it restores the bytes last merged" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "one")
      view.save(store)
      view.reload(store) # merged from the saved row, which is now remembered
      id = view.current_note_id
      merged_bytes = store.setting("notes.docs").not_nil!

      view.enter_insert!
      type(view, " two")
      view.save(store).should be_true
      view.current_text.should eq("one two")

      store.set_setting("notes.docs", merged_bytes) # a peer puts the old document back
      view.reload(store)
      view.current_text.should eq("one")
      view.current_note_id.should eq(id)
    end
  end

  it "skips the merge for an unchanged row, and still merges the next change" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "stable")
      view.save(store)
      view.reload(store)
      view.@merged_raw.should_not be_nil
      remembered = view.@merged_raw.not_nil![0].not_nil!

      # Nothing moved: the same rows, not re-merged — the remembered row is still the string
      # the FIRST read returned (a merge would have stored this read's copy).
      view.reload(store)
      view.@merged_raw.not_nil![0].not_nil!.same?(remembered).should be_true
      view.current_text.should eq("stable")

      id = view.current_note_id
      store.set_setting("notes.docs",
        %({"cur":0,"next_id":#{id + 1},"notes":[{"id":#{id},"text":"moved"}]}))
      view.reload(store)
      view.current_text.should eq("moved")
    end
  end

  # Regression: NoteEntry#text is whatever was written into the JSON KV, verbatim, and several
  # writers store wire CRLF — MCP create_note/update_note pass the caller's string straight
  # through, and `gori run notes create` takes its body from --text / positional args / STDIN
  # (piping a CRLF file, or `gori run flow N --raw`, stores CRLF). The TextArea buffer is always
  # LF (set_text strips \r), so the old `existing.area.text != e.text` compare was false on EVERY
  # data_version poll (~1.3×/s while capturing) → set_text re-ran → caret + scroll zeroed and the
  # undo stack cleared. Hit whenever Notes was open without body focus (notes_locked? only covers
  # active_tab == :notes && focus == :body), and on every tab-away-and-back.
  it "soft-merge keeps caret, scroll and undo when a CRLF-stored note matches the LF buffer" do
    with_store do |store|
      body = (1..8).map { |i| "line #{i}" }.join('\n')
      view = NotesView.new
      view.reload(store)
      view.enter_insert!
      type(view, body)
      view.save(store) # the poll path is only reached on a clean buffer (reload bails when dirty)
      id = view.current_note_id

      # A peer (MCP update_note) rewrote the SAME content in wire CRLF form.
      store.set_setting("notes.docs",
        %({"cur":0,"next_id":#{id + 1},"notes":[{"id":#{id},"text":#{body.gsub('\n', "\r\n").to_json}}]}))

      area = view.@notes[0].area
      render_text(view, 40, 3) # a rendered viewport height is what scroll_view clamps against
      area.scroll_view(2)
      area.place_cursor(5, 3)
      undo_depth = area.@undo_stack.size
      undo_depth.should be > 0
      cy, cx, scroll = area.cy, area.cx, area.scroll

      view.reload(store) # the data_version poll

      view.@notes[0].area.should be(area) # same TextArea object — never rebuilt
      area.cy.should eq(cy)
      area.cx.should eq(cx)
      area.scroll.should eq(scroll)
      area.@undo_stack.size.should eq(undo_depth) # set_text would have cleared it
      view.current_text.should eq(body)
    end
  end

  # The guard must not swallow a REAL peer edit: normalizing line endings only makes the compare
  # ignore \r, not content. A CRLF peer body with different text still replaces the buffer (and
  # lands as LF, since set_text strips \r).
  it "soft-merge still applies a CRLF-stored peer edit whose content actually changed" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "alpha\nbravo")
      view.save(store)
      id = view.current_note_id

      store.set_setting("notes.docs",
        %({"cur":0,"next_id":#{id + 1},"notes":[{"id":#{id},"text":"alpha\\r\\nCHANGED"}]}))
      view.reload(store)

      view.current_text.should eq("alpha\nCHANGED")
      view.dirty?.should be_false
    end
  end

  it "projects sub-tab filter rows (title + body) per note in chip order" do
    view = NotesView.new
    type(view, "Alpha title\nbody about idor")
    view.new_note
    type(view, "Beta notes\nsecond body")
    rows = view.filter_rows
    rows.size.should eq(2)
    rows[0][0].should eq("Alpha title") # name = the note's first non-blank line
    rows[0][1].should contain("idor")   # body carries the searchable content
    rows[1][0].should eq("Beta notes")
    # End-to-end: free text matches the body, name: matches the title, else hidden.
    subj0 = Gori::Repeater::SubtabFilter::Subject.new(rows[0][0], rows[0][1], "", "", [] of String)
    Gori::Repeater::SubtabFilter.parse("idor").matches?(subj0).should be_true
    Gori::Repeater::SubtabFilter.parse("name:alpha").matches?(subj0).should be_true
    Gori::Repeater::SubtabFilter.parse("name:beta").matches?(subj0).should be_false
  end

  it "keeps multiple notes as independent sub-tabs across a reload" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "first")
      view.new_note
      type(view, "second")
      view.count.should eq(2)
      view.save(store)

      saved_notes(store).should eq(["first", "second"])

      again = NotesView.new
      again.reload(store)
      again.count.should eq(2)
      # the active tab (cur) is restored — last edited was note 2
      render_text(again).contains?("second").should be_true
      # the sub-tab strip is now runner-owned chrome; the view exposes its chip
      # labels (derived from each note's first line) for the Runner to render.
      again.subtab_labels.should eq(["1:first", "2:second"])
    end
  end

  it "does not clobber a peer session's notes on save (concurrent editing)" do
    with_store do |store|
      seed = NotesView.new # an existing note in the project
      seed.reload(store)
      type(seed, "hi")
      seed.save(store)

      a = NotesView.new # two sessions both load the existing set
      a.reload(store)
      b = NotesView.new
      b.reload(store)

      a.new_note # each adds its own note; B saves last
      type(a, "AAA")
      a.save(store)
      b.new_note
      type(b, "BBB")
      b.save(store) # previously overwrote the whole doc, wiping A's "AAA"

      saved = saved_notes(store)
      saved.should contain("hi")
      saved.should contain("AAA") # peer note survives the concurrent save
      saved.should contain("BBB")
    end
  end

  # #1415: a save sent EVERY loaded note into the merge, so an untouched note counted as an
  # edit that wins — and `reload` is skipped while dirty, so that copy is stale exactly when a
  # peer writes during an edit. Only the notes this session changed may be written.
  describe "a save writes only the notes this session changed (#1415)" do
    it "keeps a peer's edit to a note this session never touched" do
      with_store do |store|
        ids = %w(first second third).map { |t| Gori::Notes.create(store, t).not_nil! }
        view = NotesView.new
        view.reload(store)
        view.switch_note_by_id(ids[0]).should be_true
        view.enter_insert!
        type(view, "YY") # dirty and unsaved, so the next reload is skipped

        Gori::Notes.update(store, ids[2], "third EDITED AGAIN").should eq(Gori::Notes::Write::Committed)
        view.save(store).should be_true

        saved = Gori::Notes.load(store).notes.to_h { |n| {n.id, n.text} }
        saved[ids[0]].should eq("YYfirst")
        saved[ids[1]].should eq("second")
        saved[ids[2]].should eq("third EDITED AGAIN")
      end
    end

    it "keeps it across a second save made before any reload" do
      with_store do |store|
        ids = %w(first second).map { |t| Gori::Notes.create(store, t).not_nil! }
        view = NotesView.new
        view.reload(store)
        view.switch_note_by_id(ids[0])
        view.enter_insert!
        type(view, "a")
        Gori::Notes.update(store, ids[1], "peer")
        view.save(store).should be_true
        # The buffer for ids[1] still holds "second"; it must not become "ours" now.
        type(view, "b")
        view.save(store).should be_true

        saved = Gori::Notes.load(store).notes.to_h { |n| {n.id, n.text} }
        saved[ids[0]].should eq("abfirst")
        saved[ids[1]].should eq("peer")
      end
    end

    it "does not resurrect a note a peer deleted while this session edited another" do
      with_store do |store|
        ids = %w(keep gone).map { |t| Gori::Notes.create(store, t).not_nil! }
        view = NotesView.new
        view.reload(store)
        view.switch_note_by_id(ids[0])
        view.enter_insert!
        type(view, "x")
        Gori::Notes.delete(store, ids[1]).should eq(Gori::Notes::Write::Committed)
        view.save(store).should be_true

        Gori::Notes.load(store).notes.map { |n| {n.id, n.text} }.should eq([{ids[0], "xkeep"}])
      end
    end

    it "still lets this session's edit win on the note it did change" do
      with_store do |store|
        id = Gori::Notes.create(store, "base").not_nil!
        view = NotesView.new
        view.reload(store)
        view.enter_insert!
        type(view, "mine ")
        Gori::Notes.update(store, id, "peer")
        view.save(store).should be_true

        Gori::Notes.load(store).notes.map(&.text).should eq(["mine base"])
      end
    end

    it "persists a CRLF-stored note it never touched byte-for-byte" do
      with_store do |store|
        crlf = Gori::Notes.create(store, "a\r\nb").not_nil!
        other = Gori::Notes.create(store, "other").not_nil!
        view = NotesView.new
        view.reload(store)
        view.switch_note_by_id(other)
        view.enter_insert!
        type(view, "z")
        view.save(store).should be_true

        saved = Gori::Notes.load(store).notes.to_h { |n| {n.id, n.text} }
        saved[crlf].should eq("a\r\nb")
        saved[other].should eq("zother")
      end
    end
  end

  it "Notes.merge keeps peer notes, applies my edits, drops my deletions, appends new" do
    persisted = Gori::Notes::Doc.new(0, [
      Gori::Notes::NoteEntry.new(1_i64, "peer-only"),
      Gori::Notes::NoteEntry.new(2_i64, "shared-orig"),
      Gori::Notes::NoteEntry.new(3_i64, "to-delete"),
    ], 4_i64)
    mine = [
      Gori::Notes::NoteEntry.new(2_i64, "shared-EDITED"), # I edited note 2
      Gori::Notes::NoteEntry.new(9_i64, "my-new"),        # I added note 9
    ]
    merged = Gori::Notes.merge(persisted, mine, Set{3_i64}, 2_i64, 4_i64) # I deleted note 3
    merged.notes.map { |n| {n.id, n.text} }.should eq(
      [{1_i64, "peer-only"}, {2_i64, "shared-EDITED"}, {9_i64, "my-new"}])
    merged.next_id.should eq(10_i64) # past the max surviving id
  end

  it "Notes.merge keeps the ACTIVE note active across a peer's insert (id, not index)" do
    # My list is [mine-new]; the peer meanwhile persisted a note of its own. The merge puts
    # the peer's note first (persisted order) and appends mine — so the index I would have
    # passed (0, "my first note") named the PEER's note in the merged list. An id can't drift.
    persisted = Gori::Notes::Doc.new(0, [Gori::Notes::NoteEntry.new(5_i64, "peer")], 6_i64)
    mine = [Gori::Notes::NoteEntry.new(9_i64, "mine-new")]
    merged = Gori::Notes.merge(persisted, mine, Set(Int64).new, 9_i64, 10_i64)
    merged.notes.map(&.id).should eq([5_i64, 9_i64])
    merged.cur.should eq(1) # my note, not the peer's
    merged.notes[merged.cur].text.should eq("mine-new")
  end

  it "Notes.merge falls back to the first note when the active one is gone" do
    persisted = Gori::Notes::Doc.new(1, [
      Gori::Notes::NoteEntry.new(1_i64, "a"),
      Gori::Notes::NoteEntry.new(2_i64, "b"),
    ], 3_i64)
    merged = Gori::Notes.merge(persisted, [] of Gori::Notes::NoteEntry, Set{2_i64}, 2_i64, 3_i64)
    merged.notes.map(&.id).should eq([1_i64])
    merged.cur.should eq(0)
  end

  it "Doc#note_id refuses a negative position instead of wrapping to the last note" do
    # Crystal's Array#[]? counts a negative index from the END, and the delete path walks
    # `cur - 1` looking for the neighbour before the first slot.
    doc = Gori::Notes::Doc.new(0, [
      Gori::Notes::NoteEntry.new(1_i64, "a"),
      Gori::Notes::NoteEntry.new(2_i64, "b"),
    ], 3_i64)
    doc.note_id(-1).should be_nil
    doc.note_id(0).should eq(1_i64)
    doc.note_id(2).should be_nil
  end

  it "migrates a legacy single-note document into the first note" do
    with_store do |store|
      store.set_setting("notes", "legacy body")
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
      render_text(view).contains?("legacy body").should be_true
    end
  end

  it "prefers the JSON set over the legacy key once both exist" do
    with_store do |store|
      store.set_setting("notes", "stale legacy")
      store.set_setting("notes.docs", %({"cur":0,"notes":["fresh"]}))
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
      render_text(view).contains?("fresh").should be_true
    end
  end

  it "switches the active note with switch_note" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "one")
      view.new_note
      type(view, "two")
      view.switch_note(0)
      render_text(view).contains?("one").should be_true
    end
  end

  it "switch_note_by_id selects the matching note" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "one")
      view.new_note
      type(view, "two")
      id0 = view.current_note_id # still on "two" after new_note
      view.switch_note(0)
      id_one = view.current_note_id
      view.switch_note_by_id(id0).should be_true
      view.current_text.should eq("two")
      view.switch_note_by_id(id_one).should be_true
      view.current_text.should eq("one")
      view.switch_note_by_id(999_999_i64).should be_false
    end
  end

  it "duplicate_current clones the active note's text into a new sibling (new id)" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "shared body")
      src_id = view.current_note_id
      view.duplicate_current
      view.count.should eq(2)
      view.current_index.should eq(1)
      view.current_note_id.should_not eq(src_id)
      view.current_text.should eq("shared body")
      view.switch_note(0)
      view.current_text.should eq("shared body")
    end
  end

  it "exposes current_index for arrow-key sub-tab navigation" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      view.current_index.should eq(0)
      view.new_note # appends + makes it current
      view.current_index.should eq(1)
      view.switch_note(0)
      view.current_index.should eq(0)
    end
  end

  it "always keeps at least one note open on close" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
      id_before = view.current_note_id
      closed_id = view.close_note
      view.count.should eq(1)                       # closing the last note leaves a fresh empty one
      closed_id.should eq(id_before)                # the closed note's stable id is returned for link cleanup
      view.current_note_id.should_not eq(id_before) # the replacement is a distinct note
    end
  end

  it "falls back to a single empty note on malformed JSON" do
    with_store do |store|
      store.set_setting("notes.docs", "not json {{{")
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
    end
  end

  it "clears the current note's text without closing the sub-tab" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "scratch")
      view.clear_current
      view.current_text.should eq("")
      view.save(store)
      saved_notes(store).should eq([""])
    end
  end

  it "save is a no-op when nothing was edited" do
    with_store do |store|
      store.set_setting("notes.docs", %({"cur":0,"notes":["kept"]}))
      view = NotesView.new
      view.reload(store)
      view.save(store) # not dirty → must not overwrite
      saved_notes(store).should eq(["kept"])
    end
  end

  # `dirty?` is the lock that keeps a peer's commit from reloading this note (`locked?`), and
  # it is what makes the next esc / sub-tab switch rewrite the whole document — so a key that
  # changed nothing must not raise it. The Repeater and Fuzzer editors gate the same three keys.
  it "does not dirty a clean note on a ⌃Z, ⌫ or ⌦ that changed nothing" do
    with_store do |store|
      store.set_setting("notes.docs", %({"cur":0,"notes":["kept"]}))
      view = NotesView.new
      view.reload(store)
      view.enter_insert!
      view.undo # empty undo stack
      view.dirty?.should be_false
      view.home
      view.backspace # buffer start
      view.dirty?.should be_false
      view.goto_line(1)
      view.end_of_line
      view.delete # buffer end
      view.dirty?.should be_false
      view.current_text.should eq("kept")
      # …and the same keys still dirty it when they do change the buffer.
      view.backspace
      view.current_text.should eq("kep")
      view.dirty?.should be_true
    end
  end

  # A paste is one edit, not N keystrokes: it lands in one splice and one ⌃Z takes all of it
  # back (per-keystroke delivery cost a snapshot per character and undid one at a time).
  it "splices a bulk paste in as one undo step, in INSERT only" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "head")
      view.save(store)
      view.dirty?.should be_false

      view.paste("nope").should be_false # READ has no caret to paste at — the Runner replays it
      view.current_text.should eq("head")
      view.dirty?.should be_false

      view.enter_insert!
      view.paste("\nGET /a HTTP/1.1\nHost: x\n").should be_true
      view.current_text.should eq("head\nGET /a HTTP/1.1\nHost: x\n")
      view.dirty?.should be_true
      view.undo
      view.current_text.should eq("head")
    end
  end

  it "a paste over a selection replaces it and reports how much" do
    with_store do |store|
      view = NotesView.new
      view.reload(store)
      view.enter_insert!
      type(view, "alpha beta")
      view.home
      # ⇧→ ×5 selects "alpha" in the editor's own selection model.
      5.times { view.motion_key(Termisu::Event::Key.new(Termisu::Input::Key::Right, Termisu::Input::Modifier::Shift)) }
      view.selection?.should be_true
      view.paste("omega").should be_true
      view.current_text.should eq("omega beta")
      view.last_replaced.should eq(5)
    end
  end
end

# The pointer's mode contract (#1124). A click AIMS the caret; it does not arm the editor.
# `click_to_cursor` / `select_word_at` used to call `enter_insert!` first, so the next bare
# letter was TYPED rather than run: `y` meant as copy put a `y` in the note, over whatever was
# selected. INS is entered the way the keyboard enters it — `i` / ↵ — or by clicking the
# NOR/INS chip the border draws. Every other read/insert editor in the TUI (Repeater REQUEST,
# Fuzzer TEMPLATE, Decoder / JWT / Cookie INPUT) already split the gesture this way.
describe "NotesView pointer gestures" do
  # The editor body sits one column inside `rect` (render's own inset), so screen column
  # `rect.x + 1 + n` is buffer column n and screen row `rect.y + n` is line n.
  seeded = ->(store : Gori::Store) do
    view = NotesView.new
    view.reload(store)
    view.replace_current("alpha beta\ngamma delta")
    rect = Rect.new(0, 0, 40, 6)
    view.render(Screen.new(MemoryBackend.new(40, 6)), rect)
    {view, rect}
  end

  it "places the caret without arming the editor" do
    with_store do |store|
      view, rect = seeded.call(store)
      view.click_to_cursor(rect, rect.x + 3, rect.y + 1)
      view.insert_mode?.should be_false
      # READ's `y` with nothing selected copies the caret LINE — so this is where it landed.
      view.copy_text.should eq("gamma delta")
    end
  end

  it "takes the word under a double-click in READ, where `y` can reach it" do
    with_store do |store|
      view, rect = seeded.call(store)
      view.select_word_at(rect, rect.x + 3, rect.y + 1).should be_true
      view.insert_mode?.should be_false
      view.selection?.should be_true
      view.copy_text.should eq("gamma")
    end
  end

  it "drags a READ band from the press, still without arming the editor" do
    with_store do |store|
      view, rect = seeded.call(store)
      view.click_to_cursor(rect, rect.x + 1, rect.y)
      view.drag_to_cursor(rect, rect.x + 6, rect.y)
      view.insert_mode?.should be_false
      view.copy_text.should eq("alpha")
    end
  end

  it "collapses a standing READ selection on the next plain click" do
    with_store do |store|
      view, rect = seeded.call(store)
      view.select_word_at(rect, rect.x + 1, rect.y).should be_true
      view.selection?.should be_true
      view.click_to_cursor(rect, rect.x + 8, rect.y)
      view.selection?.should be_false
      view.copy_text.should eq("alpha beta")
    end
  end

  it "keeps placing the EDITOR caret once INS is on" do
    with_store do |store|
      view, rect = seeded.call(store)
      view.enter_insert!
      view.click_to_cursor(rect, rect.x + 3, rect.y + 1)
      view.insert_mode?.should be_true
      view.select_word_at(rect, rect.x + 3, rect.y + 1).should be_true
      view.insert_mode?.should be_true
      view.copy_text.should eq("gamma")
    end
  end
end

# A READ selection is an anchor into ONE document. Notes keeps a single read state for the
# whole sub-tab strip while every note owns its own TextArea, and a note's text is replaced
# in place by a peer reload or by `^E`. In each case the band used to survive the hand-over:
# painted at the old coordinates over text the operator never selected in, and `y` put that
# text on the clipboard. `IssuesView#open_detail_issue` fixed the same leak for an Issue's
# writeup (#1123); here the drop is `TextReadState#bind`'s, so no hand-over site has to
# remember it — `switch_note`, `switch_note_by_id`, `reload`, `replace_current` all go the
# same way.
describe "NotesView READ selection across a document hand-over" do
  # note 1 = "alpha beta / gamma delta", note 2 = "zzzzzzzzzzzzzz", pane in READ on note 1,
  # rendered once so the double-click has a layout to hit-test against.
  two_notes = ->(store : Gori::Store) do
    view = NotesView.new
    view.reload(store)
    view.replace_current("alpha beta\ngamma delta")
    view.new_note
    view.replace_current("zzzzzzzzzzzzzz")
    view.switch_note(0)
    rect = Rect.new(0, 0, 40, 6)
    view.render(Screen.new(MemoryBackend.new(40, 6)), rect)
    {view, rect}
  end

  it "drops the band when the sub-tab switches" do
    with_store do |store|
      view, rect = two_notes.call(store)
      view.select_word_at(rect, rect.x + 1 + 6, rect.y).should be_true
      view.selection?.should be_true
      view.copy_text.should eq("beta")

      view.switch_note(1)
      view.selection?.should be_false
      view.copy_text.should eq("zzzzzzzzzzzzzz") # the caret LINE of note 2, not a 4-cell band
      view.render(Screen.new(MemoryBackend.new(40, 6)), rect)
      view.selection?.should be_false
    end
  end

  it "drops the band when a peer rewrites the note under it" do
    with_store do |store|
      view, rect = two_notes.call(store)
      view.save(store).should be_true # so a peer can find the note by id
      view.select_word_at(rect, rect.x + 1 + 6, rect.y).should be_true
      view.copy_text.should eq("beta")

      peer = NotesView.new
      peer.reload(store)
      peer.switch_note(0)
      peer.replace_current("zzzzzzzzzzzzzzzzzzzz")
      peer.save(store).should be_true

      view.reload(store) # the data_version tick
      view.current_text.should eq("zzzzzzzzzzzzzzzzzzzz")
      view.selection?.should be_false
      view.copy_text.should eq("zzzzzzzzzzzzzzzzzzzz")
    end
  end

  it "keeps the band across a peer reload that changed nothing" do
    with_store do |store|
      view, rect = two_notes.call(store)
      view.save(store).should be_true
      view.select_word_at(rect, rect.x + 1 + 6, rect.y).should be_true
      view.reload(store)
      view.selection?.should be_true
      view.copy_text.should eq("beta")
    end
  end

  it "drops the band when ^E hands a different text back" do
    with_store do |store|
      view, rect = two_notes.call(store)
      view.select_word_at(rect, rect.x + 1 + 6, rect.y).should be_true
      view.replace_current("zzzzzzzzzzzzzzzzzzzz")
      view.selection?.should be_false
      view.copy_text.should eq("zzzzzzzzzzzzzzzzzzzz")
    end
  end
end

# `Note#label` reads the title off the editor's lines (`TextArea#each_line`) instead of the
# joined `text` it used to hand `Notes.title`. Same scan, different source — so the gate is
# that every shape of note gets the label the joined text gave it.
describe "NotesView::Note#label (line source)" do
  it "labels every edge-case note exactly as the joined-text title did" do
    invalid = String.new(Bytes[0x23, 0x20, 0x68, 0x80, 0x0a, 0x62]) # "# h\x80\nb"
    texts = [
      "", "\n", "\n\n\n", "   \n\t\n", "plain", "plain\nsecond",
      "\n\n  leading blanks then text  \nnext",
      "# Heading\n\nbody", "## closed ##\nbody", "#\n\nfalls through", "##   \n#\n  ###  \nreal",
      "#hashtag", "    # indented code", "####### seven",
      "crlf title\r\nbody\r\n", "\r\n\r\n# crlf heading\r\n", "lone\rcr inside\nx",
      "trailing cr\r", "title\r\r\r\nx", "#\r\nafter bare crlf marker",
      "a very long first line that is well past the fifteen column chip width",
      "한국어 제목\n본문", invalid, "x" * 20 + "\n" + "y" * 100_000,
    ]
    texts.each do |text|
      note = Gori::Tui::NotesView::Note.new(1_i64, text)
      want = if t = Gori::Notes.title(note.area.text)
               t.size > 15 ? "#{t[0, 14]}…" : t
             else
               "note 4"
             end
      note.label(3).should eq(want), "label differs for #{text[0, 40].inspect}"
      Gori::Notes.title_and_detail(note.area.each_line)
        .should eq(Gori::Notes.title_and_detail(note.area.text)), "detail differs for #{text[0, 40].inspect}"
    end
  end
end
