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
    # Each ZWSP now occupies the width of its named badge in drawing and caret geometry.
    value = "#{"a" * 6}#{"\u{200B}" * 5}b" # 12 source chars, 37 display columns
    Screen.display_width(value).should eq(37)
    Screen.draw_width(value).should eq(37)
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

private def shell_key(key : Termisu::Input::Key, shift : Bool = false, alt : Bool = false) : Termisu::Event::Key
  mods = Termisu::Input::Modifier::Ctrl
  mods |= Termisu::Input::Modifier::Shift if shift
  mods |= Termisu::Input::Modifier::Alt if alt
  Termisu::Event::Key.new(key, mods)
end

describe "TextField shell editing" do
  it "moves to either end with Ctrl-A and Ctrl-E" do
    field = TextField.new("한글 /tmp/file.har")
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerA)).should be_true
    field.caret.should eq(0)
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerE)).should be_true
    field.caret.should eq(field.value.size)
  end

  it "deletes the prefix at the caret as one undo step, preserving the suffix" do
    field = TextField.new("한글 /tmp/file.har")
    field.move(-4)
    caret = field.caret
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerU)).should be_true
    field.value.should eq(".har")
    field.caret.should eq(0)
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerZ))
    field.value.should eq("한글 /tmp/file.har")
    field.caret.should eq(caret)
  end

  it "deletes the previous word or selection and can undo either" do
    field = TextField.new("alpha beta")
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerW)).should be_true
    field.value.should eq("alpha ")
    field.undo
    field.home
    field.move(5, selecting: true)
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerW)).should be_true
    field.value.should eq(" beta")
    field.undo
    field.value.should eq("alpha beta")
  end

  it "extends the selection for shifted shell motions" do
    field = TextField.new("alpha")
    field.move(-2)
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerA, shift: true)).should be_true
    field.delete_selection.should be_true
    field.value.should eq("ha")
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerE, shift: true)).should be_true
    field.delete_selection.should be_true
    field.value.should be_empty
  end

  it "consumes shell keys even on an empty field and leaves other chords alone" do
    field = TextField.new
    {Termisu::Input::Key::LowerA, Termisu::Input::Key::LowerE,
     Termisu::Input::Key::LowerU, Termisu::Input::Key::LowerW}.each do |key|
      field.handle_edit_key(shell_key(key)).should be_true
      field.handle_edit_key(shell_key(key, alt: true)).should be_false
    end
    field.handle_edit_key(shell_key(Termisu::Input::Key::LowerP)).should be_false
    field.value.should be_empty
  end
end

describe "TextField grapheme boundaries" do
  it "moves and deletes whole committed glyphs in either direction" do
    {"e\u0301", "한", "👩‍💻", "👨‍👩‍👧‍👦", "🇰🇷", "\u{0600}7"}.each do |glyph|
      field = TextField.new("a#{glyph}b")
      field.home
      field.move(1)
      field.move(1)
      field.caret.should eq(1 + glyph.size)
      field.move(-1)
      field.caret.should eq(1)
      field.delete
      field.value.should eq("ab")
      field.undo
      field.end_of_line
      field.move(-1)
      field.backspace
      field.value.should eq("ab")
      field.undo
      field.value.should eq("a#{glyph}b")
    end
  end

  it "selects and replaces a whole glyph with shifted arrows" do
    field = TextField.new("a👩‍💻b")
    field.home
    field.move(1)
    field.move(1, selecting: true)
    field.selection_text.should eq("👩‍💻")
    field.insert('Z')
    field.value.should eq("aZb")
    field.undo
    field.value.should eq("a👩‍💻b")
    field.set("🇦X🇧")
    field.home
    field.move(1)
    field.move(1, selecting: true)
    field.insert('Y')
    field.value.should eq("🇦Y🇧")
    field.selection?.should be_false
  end

  it "does not leave an accent behind after a word deletion" do
    field = TextField.new("cafe\u0301")
    field.delete_word_left.should be_true
    field.value.should eq("caf")
    field.undo
    field.value.should eq("cafe\u0301")
  end

  it "snaps a supplied caret and follows a cluster formed by insertion" do
    field = TextField.new
    field.set("e\u0301", caret: 1)
    field.caret.should eq(0)
    field.set("\u0301x")
    field.home
    field.insert('e')
    field.caret.should eq(2)
    field.insert('Z')
    field.value.should eq("eZ\u0301x")
  end

  it "keeps the caret outside clusters joined by deletion" do
    field = TextField.new("🇦X🇧")
    field.home
    field.move(1)
    field.delete
    field.value.should eq("🇦🇧")
    field.caret.should eq(2)
    field.undo
    field.move(1)
    field.backspace
    field.value.should eq("🇦🇧")
    field.caret.should eq(2)
  end

  it "includes a word's combining marks in a double-click selection" do
    field = TextField.new("cafe\u0301")
    field.home
    field.render(Screen.new(MemoryBackend.new(20, 2)), 0, 0, 20, true, Theme.text, Theme.bg)
    field.select_word_at(0, 0).should be_true
    field.selection_text.should eq("cafe\u0301")
  end
end

describe "TextField streamed insertion" do
  it "keeps consecutive inserted characters before an untouched combining suffix" do
    field = TextField.new("🇧")
    field.home
    "🇦X".each_char { |char| field.insert(char) }
    field.value.should eq("🇦X🇧")
    field.undo
    field.insert('Y')
    field.value.should eq("🇦Y🇧")
    field.set("\u0301")
    field.home
    "eX".each_char { |char| field.insert(char) }
    field.value.should eq("eX\u0301")
    field.caret.should eq(3)
    field.backspace
    field.value.should eq("e")
    field.undo
    field.value.should eq("eX\u0301")
    field.home
    field.caret.should eq(0)
  end
end

describe "TextField resolved caret" do
  it "resolves Home and pointer selection before using an insertion offset" do
    field = TextField.new("long 🇧x")
    field.home
    field.move(5)
    field.insert('🇦')
    field.caret.should eq(7)
    field.home
    field.caret.should eq(0)

    field.set("🇧")
    field.home
    field.insert('🇦')
    backend = MemoryBackend.new(20, 2)
    field.render(Screen.new(backend), 0, 0, 20, true, Theme.text, Theme.bg)
    backend.cluster_row(0).should contain("🇦🇧")
    field.click_to_cursor(0, 0, selecting: true).should be_true
    field.selection_text.should eq("🇦🇧")
  end
end

describe "TextField pointer geometry after scrolling out of view" do
  it "stops accepting pointer input until the field is drawn again" do
    field = TextField.new("authored value")
    screen = Screen.new(MemoryBackend.new(40, 4))
    field.render(screen, 3, 1, 20, true, Theme.text, Theme.bg)
    field.hit?(5, 1).should be_true
    caret = field.caret
    field.forget_geometry
    field.hit?(5, 1).should be_false
    field.click_to_cursor(5, 1).should be_false
    field.caret.should eq(caret)
    field.render(screen, 3, 2, 20, true, Theme.text, Theme.bg)
    field.hit?(5, 2).should be_true
  end
end
