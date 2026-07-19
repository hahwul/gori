require "../spec_helper"

include Gori::Tui

private def pkey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def pctrl(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::Ctrl)
end

private ESC   = Termisu::Input::Key::Escape
private DOWN  = Termisu::Input::Key::Down
private RIGHT = Termisu::Input::Key::Right

# Walk from the group strip into the first editable field of the current group.
private def into_fields(v : PreferencesView) : Nil
  v.handle_key(pkey(DOWN))
end

# The unified Preferences modal stacks several sections in one card but ↵ saves only the
# focused one — so it owns the guard against silently discarding the others, plus the
# overlay-wide chords (^P to the palette, Ctrl+, to toggle shut) every other modal has.
describe Gori::Tui::PreferencesView do
  it "closes straight away when nothing was edited" do
    v = PreferencesView.new
    v.open_default
    v.handle_key(pkey(ESC)).kind.should eq(:close)
  end

  it "warns before discarding unsaved edits, and closes on the second esc" do
    v = PreferencesView.new
    v.open_default
    into_fields(v)
    v.handle_key(pkey(RIGHT)) # flip the focused General bool → the section is now dirty
    v.dirty?.should be_true

    v.handle_key(pkey(ESC)).kind.should eq(:none) # first esc warns instead of closing
    v.handle_key(pkey(ESC)).kind.should eq(:close)
  end

  it "expires the warning after any other keystroke, so esc must warn again" do
    v = PreferencesView.new
    v.open_default
    into_fields(v)
    v.handle_key(pkey(RIGHT))
    v.handle_key(pkey(ESC)).kind.should eq(:none) # armed
    v.handle_key(pkey(DOWN))                      # …moving on disarms it
    v.handle_key(pkey(ESC)).kind.should eq(:none) # so this esc warns rather than discarding
  end

  it "guards the group strip's esc/↑ close too" do
    v = PreferencesView.new
    v.open_default
    into_fields(v)
    v.handle_key(pkey(RIGHT))
    v.handle_key(pkey(Termisu::Input::Key::Up)) # back onto the strip, still dirty
    v.handle_key(pkey(ESC)).kind.should eq(:none)
    v.handle_key(pkey(ESC)).kind.should eq(:close)
  end

  it "reopening reloads from disk, dropping the dirty state" do
    v = PreferencesView.new
    v.open_default
    into_fields(v)
    v.handle_key(pkey(RIGHT))
    v.dirty?.should be_true
    v.open_default
    v.dirty?.should be_false
    v.handle_key(pkey(ESC)).kind.should eq(:close)
  end

  it "hands ^P to the host so the palette is reachable from the modal" do
    v = PreferencesView.new
    v.open_default
    v.handle_key(pctrl(Termisu::Input::Key::LowerP)).kind.should eq(:palette)
  end

  it "closes on Ctrl+, — the chord that opened it" do
    v = PreferencesView.new
    v.open_default
    v.handle_key(pctrl(Termisu::Input::Key::Comma)).kind.should eq(:close)
  end

  it "blocks opener rows the host has no editor for instead of emitting :open" do
    # The project picker passes Set{:theme}: Theme opens, everything else stays hidden and
    # Network's Hostname-overrides field is inert rather than opening a dead overlay.
    picker = PreferencesView.new(Set{:theme})
    picker.open(:network)
    # Network's last field is the "Hostname overrides" opener row.
    12.times { picker.handle_key(pkey(DOWN)) }
    picker.handle_key(pkey(Termisu::Input::Key::Enter)).kind.should_not eq(:open)
  end
end
