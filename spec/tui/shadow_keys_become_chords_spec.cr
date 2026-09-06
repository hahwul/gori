require "../spec_helper"

# Keys that controllers used to match by hand (`c == 'a'`) and that the hotkey editor
# therefore offered as free: they are chords now, so a rebind reaches them and the hint
# strips read them off the keymap.
describe "keys the hint names are chords the keymap knows" do
  keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)

  it "OAST providers: a / e / x / d" do
    keymap.lookup(Gori::Verb::Chord.new("a"), Gori::Verb::Scope::OastProviders).should eq("oast.add-provider")
    keymap.lookup(Gori::Verb::Chord.new("e"), Gori::Verb::Scope::OastProviders).should eq("oast.edit-provider")
    keymap.lookup(Gori::Verb::Chord.new("x"), Gori::Verb::Scope::OastProviders).should eq("oast.toggle-provider")
    keymap.lookup(Gori::Verb::Chord.new("d"), Gori::Verb::Scope::OastProviders).should eq("oast.delete-provider")
  end

  it "Discover: p pauses" do
    keymap.lookup(Gori::Verb::Chord.new("p"), Gori::Verb::Scope::Discover).should eq("discover.pause")
  end

  it "Fuzzer results: o / m / v" do
    keymap.lookup(Gori::Verb::Chord.new("o"), Gori::Verb::Scope::Fuzzer).should eq("fuzz.sort")
    keymap.lookup(Gori::Verb::Chord.new("m"), Gori::Verb::Scope::Fuzzer).should eq("fuzz.matched")
    keymap.lookup(Gori::Verb::Chord.new("v"), Gori::Verb::Scope::Fuzzer).should eq("fuzz.dist")
  end
end
