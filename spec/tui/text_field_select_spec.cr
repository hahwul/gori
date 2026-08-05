require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# `TextField` — the single-line input behind thirteen modals (import + export paths, the
# scope pattern, the match & replace and extract rule forms, the OAST provider URL, every
# Fuzzer tuning field) — had NO selection of any kind.
#
# ⇧←/→ moved the caret like a bare arrow. ⇧Home/⇧End did the same. There was no ⌥←/→ by
# word, no ⌥⌫, and no pointer route in at all: not one of the thirteen inverted a click to a
# caret, so the only way to replace a long path or a regex was to hold ⌫ down.
#
# The anchor is `LineFieldRead`, the SAME model the Repeater/Fuzzer target rows use, so there
# is one single-line selection in the tree rather than a second one written here. The word
# rule is `TextArea#word_char?`'s, so a field and a buffer break in the same places.
#
# The pointer half works because the field REMEMBERS the x/y/width `render` last drew it at
# and inverts its own clicks. The geometry of a "label value" row lives in the overlay's
# `render` and nowhere else — the alternative was thirteen hand-written row rects, thirteen
# chances to land the caret a column off what was drawn.

private def field_key(k : Termisu::Input::Key, char : Char? = nil,
                      shift : Bool = false, alt : Bool = false,
                      ctrl : Bool = false) : Termisu::Event::Key
  mods = Termisu::Input::Modifier::None
  mods |= Termisu::Input::Modifier::Shift if shift
  mods |= Termisu::Input::Modifier::Alt if alt
  mods |= Termisu::Input::Modifier::Ctrl if ctrl
  Termisu::Event::Key.new(k, mods, char)
end

# A field drawn at (0, 1) with 30 columns, so a spec can click it. Rendering is what
# arms the pointer — an unrendered field must refuse every click.
private def drawn_field(value : String, width : Int32 = 30) : {TextField, MemoryBackend}
  f = TextField.new(value)
  f.home
  b = MemoryBackend.new(40, 3)
  f.render(Screen.new(b), 0, 1, width, true, Theme.text, Theme.bg)
  {f, b}
end

describe Gori::Tui::TextField do
  describe "⇧ extends every caret motion" do
    it "⇧→ selects forward and a bare → collapses it" do
      f = TextField.new("hello world")
      f.home
      f.selection?.should be_false
      f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true))
      f.selection_text.should eq("h")
      f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true))
      f.selection_text.should eq("he")
      f.handle_edit_key(field_key(Termisu::Input::Key::Right))
      f.selection?.should be_false
    end

    it "⇧← selects backward from the end" do
      f = TextField.new("hello")
      f.handle_edit_key(field_key(Termisu::Input::Key::Left, shift: true))
      f.handle_edit_key(field_key(Termisu::Input::Key::Left, shift: true))
      f.selection_text.should eq("lo")
    end

    it "⇧End selects to the end of the value" do
      f = TextField.new("hello world")
      f.home
      f.handle_edit_key(field_key(Termisu::Input::Key::End, shift: true))
      f.selection_text.should eq("hello world")
    end

    it "⇧Home selects back to column 0" do
      f = TextField.new("hello world")
      f.handle_edit_key(field_key(Termisu::Input::Key::Home, shift: true))
      f.selection_text.should eq("hello world")
    end

    it "a BARE Home collapses the selection" do
      f = TextField.new("hello")
      f.handle_edit_key(field_key(Termisu::Input::Key::Home, shift: true))
      f.selection?.should be_true
      f.handle_edit_key(field_key(Termisu::Input::Key::End))
      f.selection?.should be_false
    end
  end

  describe "word motion, the same rule TextArea walks" do
    it "⌥← steps back one token of a URL, not to the start" do
      f = TextField.new("https://example.com/a")
      f.handle_edit_key(field_key(Termisu::Input::Key::Left, alt: true))
      f.caret.should eq("https://example.com/".size)
    end

    it "⌃→ is accepted too — ⌥ is the macOS spelling of the same modifier" do
      f = TextField.new("alpha beta")
      f.home
      f.handle_edit_key(field_key(Termisu::Input::Key::Right, ctrl: true))
      f.caret.should eq("alpha ".size)
    end

    it "⇧⌥← extends by a whole word" do
      f = TextField.new("alpha beta")
      f.handle_edit_key(field_key(Termisu::Input::Key::Left, shift: true, alt: true))
      f.selection_text.should eq("beta")
    end

    it "⌥⌫ deletes the word behind the caret in one step" do
      f = TextField.new("alpha beta")
      f.handle_edit_key(field_key(Termisu::Input::Key::Backspace, alt: true))
      f.value.should eq("alpha ")
    end

    it "⌥⌫ arriving as Unknown+Alt carrying DEL is still a word delete" do
      # A terminal sends ⌥⌫ as ESC + 0x7F; termisu maps the payload through Key.from_char,
      # which has no name for DEL — so it lands as Unknown with the char attached.
      f = TextField.new("alpha beta")
      f.handle_edit_key(field_key(Termisu::Input::Key::Unknown, '\u{7F}', alt: true))
      f.value.should eq("alpha ")
    end
  end

  describe "editing replaces the selection" do
    it "typing over a selection substitutes it" do
      f = TextField.new("hello world")
      f.home
      5.times { f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true)) }
      f.handle_edit_key(field_key(Termisu::Input::Key::LowerX, 'x'))
      f.value.should eq("x world")
      f.selection?.should be_false
    end

    it "⌫ takes the whole selection, not one character" do
      f = TextField.new("hello world")
      f.home
      6.times { f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true)) }
      f.handle_edit_key(field_key(Termisu::Input::Key::Backspace))
      f.value.should eq("world")
    end

    it "Del takes the whole selection too" do
      f = TextField.new("hello world")
      f.home
      6.times { f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true)) }
      f.handle_edit_key(field_key(Termisu::Input::Key::Delete))
      f.value.should eq("world")
    end

    it "^Z after deleting a selection restores the run, not the already-cut buffer" do
      f = TextField.new("hello world")
      f.home
      6.times { f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true)) }
      f.handle_edit_key(field_key(Termisu::Input::Key::Backspace))
      f.value.should eq("world")
      f.undo
      f.value.should eq("hello world")
    end

    it "replacing the value drops the anchor — it indexed a string that is gone" do
      f = TextField.new("hello world")
      f.home
      5.times { f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true)) }
      f.selection?.should be_true
      f.set("/tmp/x")
      f.selection?.should be_false
    end
  end

  describe "the pointer" do
    it "an UNRENDERED field refuses every click — nothing knows where it is yet" do
      f = TextField.new("hello world")
      f.click_to_cursor(3, 1).should be_false
      f.hit?(3, 1).should be_false
    end

    it "a click places the caret at the column pointed at" do
      f, _ = drawn_field("hello world")
      f.click_to_cursor(6, 1).should be_true
      f.caret.should eq(6)
      f.selection?.should be_false
    end

    it "a click on another ROW misses the field entirely" do
      f, _ = drawn_field("hello world")
      f.click_to_cursor(6, 0).should be_false
      f.click_to_cursor(6, 2).should be_false
    end

    it "a click past the field's right edge misses it" do
      f, _ = drawn_field("hello world", width: 8)
      f.click_to_cursor(9, 1).should be_false
    end

    it "a drag from the press extends a selection" do
      f, _ = drawn_field("hello world")
      f.click_to_cursor(0, 1)
      f.click_to_cursor(5, 1, selecting: true)
      f.selection_text.should eq("hello")
    end

    it "a press COLLAPSES a standing selection rather than re-anchoring it" do
      f, _ = drawn_field("hello world")
      f.handle_edit_key(field_key(Termisu::Input::Key::End, shift: true))
      f.selection?.should be_true
      f.click_to_cursor(2, 1)
      f.selection?.should be_false
    end

    it "a double-click takes the word under the pointer" do
      f, _ = drawn_field("hello world")
      f.select_word_at(8, 1).should be_true
      f.selection_text.should eq("world")
    end

    it "a double-click on whitespace takes nothing" do
      f, _ = drawn_field("hello world")
      f.select_word_at(5, 1).should be_false
      f.selection?.should be_false
    end

    it "a double-click keeps a hyphenated token whole — `-` is a word char" do
      f, _ = drawn_field("X-Custom-Header")
      f.select_word_at(3, 1).should be_true
      f.selection_text.should eq("X-Custom-Header")
    end

    # The single-line half of the wide-glyph pointer rule (`LineFieldRead#select_word_at_cursor`
    # is the one home the thirteen fields share). A pointer past the midpoint of a 2-cell glyph
    # rounds to the position AFTER it, which for a word's last glyph is past the word — so the
    # spread steps back over that one wide cluster. ASCII is unaffected: the whitespace case
    # above still takes nothing.
    it "a double-click takes the word from either half of a wide glyph" do
      f, _ = drawn_field("한글 선택")           # 한 cols 0-1, 글 2-3, sp 4, 선 5-6, 택 7-8
      f.select_word_at(5, 1).should be_true # LEFT half of 선
      f.selection_text.should eq("선택")
      f.select_word_at(8, 1).should be_true # RIGHT half of 택 — the value's last glyph
      f.selection_text.should eq("선택")
    end

    it "an UNFOCUSED field is still clickable — that click is how it gets focused" do
      f = TextField.new("hello world")
      b = MemoryBackend.new(40, 3)
      f.render(Screen.new(b), 0, 1, 30, false, Theme.text, Theme.bg)
      f.click_to_cursor(6, 1).should be_true
      f.caret.should eq(6)
    end
  end

  describe "the band is actually on screen" do
    # REGRESSION GUARD. `Screen#input_line` writes its own `bg` into every cell it touches,
    # so a band painted BEFORE it was applied and erased on the same frame — which is
    # exactly what the Repeater/Fuzzer target rows were doing, giving them a selection that
    # copied correctly and was invisible. The band now rides inside `input_line`, between
    # the value and the block caret.
    it "paints the selected cells and leaves the caret cell to the caret" do
      f, _ = drawn_field("hello world")
      f.handle_edit_key(field_key(Termisu::Input::Key::Home))
      5.times { f.handle_edit_key(field_key(Termisu::Input::Key::Right, shift: true)) }
      b = MemoryBackend.new(40, 3)
      f.render(Screen.new(b), 0, 1, 30, true, Theme.text, Theme.bg)
      (0..4).each { |x| b.bg_grid[1][x].should eq(Theme.accent_bg) }
      b.bg_grid[1][5].should eq(Theme.accent) # the block caret, not the band
      b.bg_grid[1][6].should eq(Theme.bg)     # past the selection: untouched
    end

    it "draws no band when there is no selection" do
      f, _ = drawn_field("hello world")
      b = MemoryBackend.new(40, 3)
      f.render(Screen.new(b), 0, 1, 30, true, Theme.text, Theme.bg)
      (1..4).each { |x| b.bg_grid[1][x].should eq(Theme.bg) }
    end
  end
end
