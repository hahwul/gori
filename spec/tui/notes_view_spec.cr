require "../spec_helper"
require "../support/memory_backend"

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

describe Gori::Tui::NotesView do
  it "loads, edits inline, and persists to the settings KV" do
    tmp_store do |store|
      view = NotesView.new
      view.reload(store)

      "hi".each_char { |c| view.insert(c) }
      view.newline
      "there".each_char { |c| view.insert(c) }
      view.save(store)

      store.setting("notes").should eq("hi\nthere")

      # a fresh view reloads the persisted document
      again = NotesView.new
      again.reload(store)
      backend = MemoryBackend.new(80, 10)
      again.render(Screen.new(backend), Rect.new(0, 0, 80, 10))
      backend.contains?("NOTES").should be_true
      backend.contains?("there").should be_true
    end
  end

  it "save is a no-op when nothing was edited" do
    tmp_store do |store|
      store.set_setting("notes", "kept")
      view = NotesView.new
      view.reload(store)
      view.save(store) # not dirty → must not overwrite
      store.setting("notes").should eq("kept")
    end
  end
end
