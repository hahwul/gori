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

  it "still scrolls to keep the caret visible when the value holds zero-width chars" do
    # window_start decides when to scroll, so it has to measure in the SAME units
    # Screen#input_line places the caret in. It measured with display_width, which scores
    # a zero-width char 0 while input_line's caret (column_width) and the drawn cell both
    # count it as 1. The window therefore under-counted, concluded the value still fit,
    # and left start at 0 — putting the caret at column == width, one past the right edge,
    # where input_line's `caret_x < right` guard drops it entirely. The field then had NO
    # visible caret and no hardware cursor, so IME composition had nowhere to anchor.
    # (This pins window_start specifically: it only fails once input_line itself measures
    # with column_width. With BOTH on display_width the two under-counts cancelled and the
    # caret was merely in the wrong column rather than missing — so the pair must move
    # together, and the assertion below is on the caret EXISTING and being in-field.)
    value = "#{"a" * 6}#{"\u{200B}" * 5}b" # 12 chars: display_width 7, column_width 12
    Screen.display_width(value).should eq(7)
    Screen.draw_width(value).should eq(12)
    f = TextField.new(value) # TextField.new parks the caret at the end
    f.caret.should eq(12)
    backend = MemoryBackend.new(40, 3)
    f.render(Screen.new(backend), 0, 1, 12, true, Theme.text, Theme.bg)
    # The caret cell is the one on the ACCENT background; it must exist and be in-field.
    caret = (0...40).select { |x| backend.bg_at(x, 1) == Theme.accent }
    caret.size.should eq(1)
    caret[0].should be < 12 # inside the 12-column field, not off its right edge
  end

  it "seeds the caret at the end on construction" do
    TextField.new("hello").caret.should eq(5)
    TextField.new.caret.should eq(0)
  end
end
