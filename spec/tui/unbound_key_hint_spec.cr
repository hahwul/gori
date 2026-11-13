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
    hint.should contain("{help.hotkeys} help")
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
    line.should_not contain("{help.hotkeys}")
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
    Gori::Hotkeys.expand(registry, Runner.read_mode_note(Runner::CAPTURE_OFF_TOAST))
      .should eq("proxy stopped · READ: i/↵ to type")
  end
end

# `c` and `i` are bare letters live on the tab bar a session lands on: one closes the listener,
# the other holds every request, and neither shows on the tab being looked at. When a KEY
# tripped one, its toast names that key as the way back.
describe "Runner.undo_key_note" do
  it "keeps the key on the toast's own segment, where a narrow status row cannot drop it" do
    note = Runner.undo_key_note("intercept ON — held traffic waits", "i", "turns it off")
    note.should eq("intercept ON — held traffic waits (i turns it off)")
    note.should_not contain(" · ")
    # 80×24 leaves the tab bar 59 hint columns beside the companion chip.
    note.size.should be <= 59
    read = Runner.read_mode_note(Runner.undo_key_note(Runner::CAPTURE_OFF_TOAST, "c", "turns it back on"))
    Gori::Hotkeys.expand(Gori::Verbs.registry, read).size.should be <= 59
  end

  # The tab bar's footer names the palette `^P palette`; three columns longer than `^P cmds`,
  # so one more segment has to go at 80×24, and it is `q projects` (the head's last), not
  # `↹/↵ enter`.
  it "drops q projects first when the tab bar has its 59 columns" do
    row = "←/→ switch tab · ↹/↵ enter · {capture.toggle} capture · {intercept.toggle} intercept · q projects · ^P palette · {help.hotkeys} help"
    File.read("src/gori/tui/runner.cr").should contain(row)
    Gori::Tui::Chrome.fit_hints(Gori::Hotkeys.expand(Gori::Verbs.registry, row), 59)
      .should eq("←/→ switch tab · ↹/↵ enter · ^P palette · ? help")
  end

  # The add-rule toast's lens clause is the part a narrow status row drops whole, so it has to
  # fit beside any rule count.
  it "keeps the add-rule toast's lens clause inside 59 columns" do
    tail = " · {space:scope.lens-toggle} filters to scope"
    File.read("src/gori/tui/controllers/project_controller.cr").should contain(tail)
    toast = Gori::Hotkeys.expand_menu_paths(Gori::Verbs.registry, "scope rule added — 1000 rules#{tail}")
    toast.size.should be <= 59
  end
end
