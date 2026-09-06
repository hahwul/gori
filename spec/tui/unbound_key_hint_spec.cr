require "../spec_helper"

include Gori::Tui

# A bare printable that nothing in the current scope (or Global) binds used to vanish — and
# the letters that WERE Global breath keys fired instead (`s` flipped the scope lens, `c`
# stopped capture) with nothing on screen tying the flip to the typing. `Runner.new` owns a
# terminal, so the rule is pinned through the pure class method the key tail defers to.
describe "Runner.unbound_key_hint" do
  it "names a bare letter and the two ways out" do
    hint = Runner.unbound_key_hint(Gori::Verb::Chord.new("x")).not_nil!
    hint.should contain("‹x›")
    hint.should contain("space menu")
    hint.should contain("{tab.help} help")
  end

  it "spells a typed capital as the shifted chord it arrived as" do
    Runner.unbound_key_hint(Gori::Verb::Chord.new("x", shift: true)).not_nil!.should contain("‹⇧X›")
  end

  it "stays silent for a modified chord — those are deliberate" do
    Runner.unbound_key_hint(Gori::Verb::Chord.new("x", ctrl: true)).should be_nil
    Runner.unbound_key_hint(Gori::Verb::Chord.new("x", alt: true)).should be_nil
  end

  it "stays silent for every named key — navigation is legitimately unbound in some scopes" do
    Gori::Verb::Chord::NAMED_KEYS.each do |name|
      Runner.unbound_key_hint(Gori::Verb::Chord.new(name)).should be_nil
      Runner.unbound_key_hint(Gori::Verb::Chord.new(name, shift: true)).should be_nil
    end
  end

  it "resolves the help token against the live keymap" do
    registry = Gori::Verbs.registry
    line = Gori::Hotkeys.expand(registry, Runner.unbound_key_hint(Gori::Verb::Chord.new("x")).not_nil!)
    line.should contain("? help")
    line.should_not contain("{tab.help}")
  end
end
