require "../spec_helper"
require "../support/memory_backend"
require "../support/tui_contract"

include Gori::Tui

# src/gori/tui/keyset_playground_overlay.cr — Preferences → Keys → Keyset playground. The pad
# is `KeysetPad` (keyset_pad_spec.cr covers its grammar); these examples pin the card around
# it: which part holds the keys, what ↵ and esc mean, the key list, and the paste register.
private REGISTRY = Gori::Verbs.registry

private alias Kind = Gori::Verb::Keyset::Kind

private def playground(kind : Kind = Kind::Helix) : KeysetPlaygroundOverlay
  pad = KeysetPad.new(kind, REGISTRY, "auto", {} of String => Array(Gori::Verb::Chord))
  KeysetPlaygroundOverlay.new(kind, pad)
end

private def key(k : Termisu::Input::Key) : Termisu::Event::Key
  TuiContract.key(k)
end

private def screen_text(ov : KeysetPlaygroundOverlay, w : Int32, h : Int32) : String
  b = MemoryBackend.new(w, h)
  ov.render(Screen.new(b), Rect.new(0, 0, w, h))
  (0...h).map { |y| b.row(y) }.join('\n')
end

describe KeysetPlaygroundOverlay do
  before_each { Gori::Tui::Register.clear }

  it "switches the keyset tried with ↑/↓, and only tries: ↵ moves into the pad" do
    ov = playground
    ov.handle_key(key(Termisu::Input::Key::Down)).should eq(:stay)
    ov.keyset.should eq(Kind::Vim)
    ov.handle_key(key(Termisu::Input::Key::Up))
    ov.keyset.should eq(Kind::Helix)
    ov.handle_key(key(Termisu::Input::Key::Enter)).should eq(:stay)
    ov.pad_focused?.should be_true
  end

  it "hands a typed letter to the pad, and ⇥ / an unclaimed esc back to the keyset rows" do
    ov = playground(Kind::Vim)
    ov.handle_key(TuiContract.plain('V'))
    ov.pad_focused?.should be_true
    ov.handle_key(key(Termisu::Input::Key::Escape)).should eq(:stay) # clears the selection
    ov.pad_focused?.should be_true
    ov.handle_key(key(Termisu::Input::Key::Escape)).should eq(:stay) # nothing left: leaves the pad
    ov.pad_focused?.should be_false
    ov.handle_key(key(Termisu::Input::Key::Tab))
    ov.pad_focused?.should be_true
    ov.handle_key(key(Termisu::Input::Key::Tab))
    ov.pad_focused?.should be_false
    ov.handle_key(key(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "lists every key of the keyset being tried, expanded from the keymap" do
    {Kind::Helix, Kind::Vim}.each do |kind|
      pad = KeysetPad.new(kind, REGISTRY, "auto", {} of String => Array(Gori::Verb::Chord))
      rows = pad.cheat_sheet(kind)
      rows.size.should eq(KeysetPad::CHEAT[kind].size)
      rows.each { |(label, keys)| keys.should_not contain('{'), "#{kind} #{label}" }
    end
    text = screen_text(playground(Kind::Vim), 110, 30)
    text.should contain("KEYS · vim-ish")
    text.should contain("dd delete")
    text.should contain("w/b word")
  end

  it "puts the paste register back as it found it" do
    Gori::Tui::Register.store("real copy", linewise: false)
    ov = playground(Kind::Vim)
    ov.handle_key(TuiContract.plain('y'))
    ov.handle_key(TuiContract.plain('y')) # yy in the pad: the register now holds sample text
    Gori::Tui::Register.text.should_not eq("real copy")
    ov.restore_register
    Gori::Tui::Register.text.should eq("real copy")
    Gori::Tui::Register.linewise?.should be_false
  end

  it "says so on a window too small for the card" do
    screen_text(playground, 50, 12).should contain("needs a larger window")
  end
end
