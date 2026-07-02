require "../spec_helper"
require "../support/memory_backend"
require "json"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-notes", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Type a string into the view, honouring embedded newlines.
private def type(view : NotesView, text : String) : Nil
  text.each_char { |c| c == '\n' ? view.newline : view.insert(c) }
end

# The persisted note bodies (parsed back out of the JSON KV value), or [] when
# nothing has been saved yet.
private def saved_notes(store : Gori::Store) : Array(String)
  raw = store.setting("notes.docs")
  return [] of String unless raw
  JSON.parse(raw)["notes"].as_a.map(&.as_s)
end

private def render_text(view : NotesView, w = 80, h = 10) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h))
  backend
end

describe Gori::Tui::NotesView do
  it "loads, edits inline, and persists the note set as JSON" do
    tmp_store do |store|
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

  it "keeps multiple notes as independent sub-tabs across a reload" do
    tmp_store do |store|
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

  it "migrates a legacy single-note document into the first note" do
    tmp_store do |store|
      store.set_setting("notes", "legacy body")
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
      render_text(view).contains?("legacy body").should be_true
    end
  end

  it "prefers the JSON set over the legacy key once both exist" do
    tmp_store do |store|
      store.set_setting("notes", "stale legacy")
      store.set_setting("notes.docs", %({"cur":0,"notes":["fresh"]}))
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
      render_text(view).contains?("fresh").should be_true
    end
  end

  it "switches the active note with switch_note" do
    tmp_store do |store|
      view = NotesView.new
      view.reload(store)
      type(view, "one")
      view.new_note
      type(view, "two")
      view.switch_note(0)
      render_text(view).contains?("one").should be_true
    end
  end

  it "exposes current_index for arrow-key sub-tab navigation" do
    tmp_store do |store|
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
    tmp_store do |store|
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
      view.close_note
      view.count.should eq(1) # closing the last note leaves a fresh empty one
    end
  end

  it "falls back to a single empty note on malformed JSON" do
    tmp_store do |store|
      store.set_setting("notes.docs", "not json {{{")
      view = NotesView.new
      view.reload(store)
      view.count.should eq(1)
    end
  end

  it "clears the current note's text without closing the sub-tab" do
    tmp_store do |store|
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
    tmp_store do |store|
      store.set_setting("notes.docs", %({"cur":0,"notes":["kept"]}))
      view = NotesView.new
      view.reload(store)
      view.save(store) # not dirty → must not overwrite
      saved_notes(store).should eq(["kept"])
    end
  end
end
