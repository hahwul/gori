require "../spec_helper"

# Builds a Termisu key event. Positional order matches the struct constructor
# (key, modifiers, char) so tests can construct any raw event the parser might
# hand Keybind.from_event.
private def key_event(k : Termisu::Input::Key,
                      mods : Termisu::Input::Modifier = Termisu::Input::Modifier::None,
                      char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

# Runs the unit under test.
private def chord(k : Termisu::Input::Key,
                  mods : Termisu::Input::Modifier = Termisu::Input::Modifier::None,
                  char : Char? = nil) : Gori::Verb::Chord?
  Gori::Tui::Keybind.from_event(key_event(k, mods, char))
end

private alias Key = Termisu::Input::Key
private alias Mod = Termisu::Input::Modifier
private alias Chord = Gori::Verb::Chord

describe Gori::Tui::Keybind do
  describe ".from_event named special keys" do
    it "maps Enter to \"enter\"" do
      chord(Key::Enter).should eq(Chord.new("enter"))
    end

    it "maps Escape to \"escape\"" do
      chord(Key::Escape).should eq(Chord.new("escape"))
    end

    it "maps Tab to \"tab\"" do
      chord(Key::Tab).should eq(Chord.new("tab"))
    end

    it "maps Up to \"up\"" do
      chord(Key::Up).should eq(Chord.new("up"))
    end

    it "maps Down to \"down\"" do
      chord(Key::Down).should eq(Chord.new("down"))
    end

    it "maps Left to \"left\"" do
      chord(Key::Left).should eq(Chord.new("left"))
    end

    it "maps Right to \"right\"" do
      chord(Key::Right).should eq(Chord.new("right"))
    end

    it "maps Backspace to \"backspace\"" do
      chord(Key::Backspace).should eq(Chord.new("backspace"))
    end

    it "maps Space to \"space\" (not the literal space char)" do
      # Space is caught by the named-key ladder before the char branch, so the
      # chord key is the multi-char name, never " ".
      chord(Key::Space).should eq(Chord.new("space"))
    end

    it "gives a bare named key no modifiers" do
      c = chord(Key::Enter).not_nil!
      c.ctrl.should be_false
      c.alt.should be_false
      c.shift.should be_false
    end
  end

  describe ".from_event uppercase normalisation" do
    it "normalises a typed uppercase letter with NO shift modifier to shift+lowercase" do
      # Terminals deliver a shifted letter as the char itself with no shift bit;
      # the contract is to synthesise shift + lowercase so \"shift-f\" binds.
      chord(Key::UpperF).should eq(Chord.new("f", shift: true))
    end

    it "normalises every letter of the alphabet the same way" do
      ('A'..'Z').each do |ch|
        k = Key.from_char(ch)
        chord(k).should eq(Chord.new(ch.downcase.to_s, shift: true))
      end
    end

    it "keeps shift true when uppercase AND the shift modifier are both present" do
      chord(Key::UpperF, Mod::Shift).should eq(Chord.new("f", shift: true))
    end

    it "honours an explicitly attached uppercase @char over the key's own char" do
      # @char takes precedence over key.to_char; an uppercase override still
      # triggers the shift synthesis even though the key is a lowercase letter.
      chord(Key::LowerA, char: 'A').should eq(Chord.new("a", shift: true))
    end
  end

  describe ".from_event lowercase letters" do
    it "maps a plain lowercase letter to shift:false" do
      chord(Key::LowerF).should eq(Chord.new("f", shift: false))
    end

    it "carries the shift modifier through even when the char stays lowercase" do
      # Some terminals send lowercase char + a real shift bit; shift ||= false
      # leaves the already-true modifier intact.
      chord(Key::LowerA, Mod::Shift).should eq(Chord.new("a", shift: true))
    end

    it "maps the whole lowercase alphabet with no synthesised shift" do
      ('a'..'z').each do |ch|
        chord(Key.from_char(ch)).should eq(Chord.new(ch.to_s, shift: false))
      end
    end
  end

  describe ".from_event non-ASCII printable chars" do
    it "returns nil for a CJK char (Hangul)" do
      chord(Key::Unknown, char: '안').should be_nil
    end

    it "returns nil for a CJK char (Han)" do
      chord(Key::Unknown, char: '世').should be_nil
    end

    it "returns nil for an emoji" do
      chord(Key::Unknown, char: '🔥').should be_nil
    end

    it "returns nil for a combining mark" do
      chord(Key::Unknown, char: '́').should be_nil
    end

    it "returns nil for an accented Latin-1 char just past the ASCII boundary" do
      # 'ÿ' is U+00FF — first codepoint above the 0x7F ASCII ceiling.
      chord(Key::Unknown, char: 'ÿ').should be_nil
    end

    it "accepts the char exactly at the ASCII ceiling (0x7E '~')" do
      chord(Key::Unknown, char: '~').should eq(Chord.new("~", shift: false))
    end
  end

  describe ".from_event digits and punctuation" do
    it "passes a digit through unchanged" do
      chord(Key::Num1).should eq(Chord.new("1"))
    end

    it "maps every digit key to its own char" do
      ('0'..'9').each do |ch|
        chord(Key.from_char(ch)).should eq(Chord.new(ch.to_s, shift: false))
      end
    end

    it "passes an unshifted punctuation key through" do
      chord(Key::LeftBracket).should eq(Chord.new("["))
    end

    it "passes the literal minus key through (so \"ctrl--\" can round-trip)" do
      chord(Key::Minus).should eq(Chord.new("-"))
    end

    it "does NOT synthesise shift for a shifted-symbol key (only ascii_uppercase? triggers it)" do
      # '!' is not ascii_uppercase?, so shift stays whatever the modifier said —
      # here None. The contract keys shift off letter case, not symbol shiftiness.
      chord(Key::Exclaim).should eq(Chord.new("!", shift: false))
    end

    it "carries a real shift modifier on a symbol key without touching the key name" do
      chord(Key::Exclaim, Mod::Shift).should eq(Chord.new("!", shift: true))
    end
  end

  describe ".from_event modifier propagation" do
    it "propagates ctrl into a named-key chord (ctrl+Enter)" do
      chord(Key::Enter, Mod::Ctrl).should eq(Chord.new("enter", ctrl: true))
    end

    it "propagates alt into a letter chord (alt+a)" do
      chord(Key::LowerA, Mod::Alt).should eq(Chord.new("a", alt: true))
    end

    it "propagates ctrl into a letter chord (ctrl+a)" do
      chord(Key::LowerA, Mod::Ctrl).should eq(Chord.new("a", ctrl: true))
    end

    it "propagates alt into a named-key chord (alt+Left)" do
      chord(Key::Left, Mod::Alt).should eq(Chord.new("left", alt: true))
    end

    it "combines ctrl+alt on a letter" do
      chord(Key::LowerA, Mod::Ctrl | Mod::Alt).should eq(Chord.new("a", ctrl: true, alt: true))
    end

    it "combines ctrl+shift on an uppercase letter (shift already true, ctrl added)" do
      chord(Key::UpperF, Mod::Ctrl).should eq(Chord.new("f", ctrl: true, shift: true))
    end

    it "carries all three modifiers on a named key" do
      chord(Key::Tab, Mod::Ctrl | Mod::Alt | Mod::Shift)
        .should eq(Chord.new("tab", ctrl: true, alt: true, shift: true))
    end

    it "ignores the meta modifier (Keybind reads only ctrl/alt/shift)" do
      # Meta has no field on Chord; a meta-only Enter is still a bare \"enter\".
      chord(Key::Enter, Mod::Meta).should eq(Chord.new("enter"))
    end
  end

  describe ".from_event shift on named keys" do
    it "carries shift on shift+Tab (Tab key + shift bit)" do
      chord(Key::Tab, Mod::Shift).should eq(Chord.new("tab", shift: true))
    end

    it "carries shift on shift+Enter" do
      chord(Key::Enter, Mod::Shift).should eq(Chord.new("enter", shift: true))
    end
  end

  describe ".from_event unrecognised keys" do
    it "returns nil for a function key (F1) — no name, no printable char" do
      chord(Key::F1).should be_nil
    end

    it "returns nil for a high function key (F24)" do
      chord(Key::F24).should be_nil
    end

    it "returns nil for BackTab (its own key, not Tab; no printable char)" do
      # Shift+Tab arrives as a distinct BackTab key on some terminals. It is not
      # Key::Tab, so key.tab? is false, and BackTab has no to_char — final else.
      chord(Key::BackTab).should be_nil
    end

    it "returns nil for Home / navigation keys with no char and no name" do
      chord(Key::Home).should be_nil
      chord(Key::PageUp).should be_nil
      chord(Key::Delete).should be_nil
    end

    it "returns nil for an Unknown key with no attached char" do
      chord(Key::Unknown).should be_nil
    end

    it "returns nil for CapsLock and other protocol-only keys" do
      chord(Key::CapsLock).should be_nil
      chord(Key::PrintScreen).should be_nil
    end
  end

  describe ".from_event completeness" do
    it "resolves every declared NAMED_KEY of a Chord to a non-nil chord with that name" do
      # The named-key ladder must emit exactly the names Chord advertises as legal.
      name_to_key = {
        "enter"     => Key::Enter,
        "escape"    => Key::Escape,
        "tab"       => Key::Tab,
        "up"        => Key::Up,
        "down"      => Key::Down,
        "left"      => Key::Left,
        "right"     => Key::Right,
        "backspace" => Key::Backspace,
        "space"     => Key::Space,
      }
      Chord::NAMED_KEYS.each do |name|
        k = name_to_key[name]? || fail("no key mapping for NAMED_KEY #{name}")
        chord(k).should eq(Chord.new(name))
      end
    end

    it "returns a value-equal Chord (record equality) rather than an identity" do
      chord(Key::LowerG).should eq(Chord.new("g", ctrl: false, alt: false, shift: false))
    end
  end
end
