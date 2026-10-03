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

  it "tells a text editor in READ how to type, from the live keymap" do
    # A first-timer in the Repeater's READ request typed `xd` and lost the request line; the
    # unbound letters in between said "nothing bound here", which reads as "typing is broken".
    line = Gori::Hotkeys.expand(Gori::Verbs.registry,
      Runner.unbound_key_hint(Gori::Verb::Chord.new("e"), read_mode: true).not_nil!)
    line.should eq("‹e› — READ mode: i/↵ to type · space menu")
  end
end

# A Global breath letter that fires from an editor in READ keeps its meaning (#1375), but its
# toast says where it came from: `c` stopping capture mid-"typing" otherwise reads as the
# proxy breaking on its own.
describe "Runner.read_mode_global?" do
  registry = Gori::Verbs.registry
  capture = registry["capture.toggle"]
  lens = registry["scope.toggle-lens"]

  it "tags a bare Global letter from a READ editor" do
    Runner.read_mode_global?(capture, Gori::Verb::Chord.new("c"), true).should be_true
    Runner.read_mode_global?(lens, Gori::Verb::Chord.new("s"), true).should be_true
  end

  it "leaves every other press alone" do
    Runner.read_mode_global?(capture, Gori::Verb::Chord.new("c"), false).should be_false
    Runner.read_mode_global?(registry["editor.insert"], Gori::Verb::Chord.new("i"), true).should be_false
    Runner.read_mode_global?(registry["nav.pos1"], Gori::Verb::Chord.new("1"), true).should be_false
    Runner.read_mode_global?(capture, Gori::Verb::Chord.new("c", ctrl: true), true).should be_false
  end

  it "appends the way to type, resolved against the live keymap" do
    Gori::Hotkeys.expand(registry, Runner.read_mode_note("capture off"))
      .should eq("capture off · from READ mode — i/↵ to type")
  end
end
