require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::TextField do
  it "parks the caret at the end when the value is replaced" do
    # REGRESSION: `set` used to CLAMP the old caret into the new string
    # (`{@caret, v.size}.min`). Replacing a value wholesale makes an offset into the
    # PREVIOUS string meaningless, and it broke every path-completion overlay: Tab on
    # "/tmp/imp/" → "/tmp/imp/sample.har" left the caret at 9, so the next keystroke
    # landed mid-filename.
    f = TextField.new("/tmp/imp/")
    f.caret.should eq(9) # caret starts at the end of the seeded value
    f.set("/tmp/imp/sample.har")
    f.caret.should eq("/tmp/imp/sample.har".size)
  end

  it "parks the caret at the end even when the caret was left short of it" do
    f = TextField.new("abcdef")
    f.home
    f.caret.should eq(0)
    f.set("xyz")
    f.caret.should eq(3) # NOT 0 — typing continues after the new value
  end

  it "keeps typing appending after a replace" do
    f = TextField.new("/tmp/")
    f.set("/tmp/dir/")
    f.insert('a')
    f.value.should eq("/tmp/dir/a") # not "/tmp/adir/" or similar mid-string damage
  end

  it "draws the IME preedit at the caret" do
    # The field STORED composing text but rendered with a plain `text` call, so every
    # TextField overlay dropped it: a Hangul/CJK name typed into the import popup was
    # invisible until each syllable committed.
    f = TextField.new("ab")
    f.set_preedit("\uD55C")
    backend = MemoryBackend.new(40, 3)
    f.render(Screen.new(backend), 0, 0, 20, true, Theme.text, Theme.bg)
    backend.contains?("ab\uD55C").should be_true
  end

  it "scrolls horizontally to keep the caret visible" do
    # The import card's field is at most 64 columns; an absolute path easily exceeds it.
    # Rendering always started at index 0, so past the width the tail, the caret and the
    # hardware-cursor sync all disappeared.
    long = "/very/long/path/segment/that/exceeds/the/field/width/file.har"
    f = TextField.new(long)
    backend = MemoryBackend.new(40, 3)
    f.render(Screen.new(backend), 0, 0, 20, true, Theme.text, Theme.bg)
    backend.contains?("file.har").should be_true # the caret end, not the "/very/long" head
    backend.contains?("/very/long").should be_false
  end

  it "does not scroll while the value still fits" do
    f = TextField.new("/tmp/x")
    backend = MemoryBackend.new(40, 3)
    f.render(Screen.new(backend), 0, 0, 20, true, Theme.text, Theme.bg)
    backend.contains?("/tmp/x").should be_true
  end

  it "seeds the caret at the end on construction" do
    TextField.new("hello").caret.should eq(5)
    TextField.new.caret.should eq(0)
  end
end
