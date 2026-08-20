require "../spec_helper"
require "../support/memory_backend"

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

  it "puts ^P through the same unsaved-edit guard as esc" do
    # ^P closes the modal just as surely (the host sets @overlay = :none), so skipping the
    # guard meant this one exit silently discarded pending edits at the next reload_all.
    v = PreferencesView.new
    v.open_default
    into_fields(v)
    v.handle_key(pkey(RIGHT))
    v.dirty?.should be_true

    v.handle_key(pctrl(Termisu::Input::Key::LowerP)).kind.should eq(:none) # warns first
    v.handle_key(pctrl(Termisu::Input::Key::LowerP)).kind.should eq(:palette)
  end

  it "does not report a rejected save as saved" do
    # A failed validation persists nothing, so a :saved outcome would have the host
    # live-apply — rebinding the proxy — for input that was just refused.
    v = PreferencesView.new
    v.open(:network)
    v.handle_key(pkey(DOWN)) # Bind Host -> Bind Port
    8.times { v.handle_key(pkey(Termisu::Input::Key::Backspace)) }
    "abc".each_char { |ch| v.handle_key(pkey(Termisu::Input::Key::Space, ch)) }
    v.handle_key(pkey(Termisu::Input::Key::Enter)).kind.should eq(:none)
  end

  it "keeps the modal's focus and the section's focus together across ^R" do
    # `reset_to_defaults` snaps the FORM's own cursor back to field 0 while the modal keeps
    # its separate flat index, so without a re-sync the row drawn as focused and the row
    # that receives the next keystroke are different rows. Typing after ^R proves which.
    v = PreferencesView.new
    v.open(:network)
    v.handle_key(pkey(DOWN)) # Bind Host -> Bind Port
    v.handle_key(pctrl(Termisu::Input::Key::LowerR))
    v.handle_key(pkey(Termisu::Input::Key::Space, '9'))

    backend = MemoryBackend.new(100, 40)
    v.render(Screen.new(backend), Rect.new(0, 0, 100, 40))
    backend.contains?("#{Gori::Settings::DEFAULT_BIND_PORT}9").should be_true
    backend.contains?("#{Gori::Settings::DEFAULT_BIND_HOST}9").should be_false
  end

  it "closes on Ctrl+, — the chord that opened it" do
    v = PreferencesView.new
    v.open_default
    v.handle_key(pctrl(Termisu::Input::Key::Comma)).kind.should eq(:close)
  end

  # ^R used to fall through to silence on every OPENER row while the footer advertised it —
  # the Tabs, Theme and Hotkeys rows all HAVE a factory default, just not one this view holds
  # (there is no working copy behind an opener here, so restoring one is a disk write, which
  # is the host's to confirm and perform).
  it "hands the host a :reset for an opener row that has a factory default" do
    v = PreferencesView.new
    v.open(:tabs)
    out = v.handle_key(pctrl(Termisu::Input::Key::LowerR))
    out.kind.should eq(:reset)
    out.section.should eq(:tabs)
  end

  it "refuses, out loud, on an opener that holds the operator's own entries" do
    # Env's "default" is empty — i.e. deleting typed token values. That is the full factory
    # reset's job to offer and to warn about, not a quiet side effect of a chord.
    v = PreferencesView.new
    v.open(:env)
    v.handle_key(pctrl(Termisu::Input::Key::LowerR)).kind.should eq(:none)

    backend = MemoryBackend.new(120, 40)
    v.render(Screen.new(backend), Rect.new(0, 0, 120, 40))
    backend.contains?("nothing to restore").should be_true
  end

  it "runs the factory-reset row from ↵ and ^R alike" do
    # An :action row IS its verb, so both keys have to reach the host — a Reset row that
    # only answered ↵ would be a dead end for anyone who reached it with the advertised ^R.
    [pkey(Termisu::Input::Key::Enter), pctrl(Termisu::Input::Key::LowerR)].each do |ev|
      v = PreferencesView.new
      v.open(:reset_all)
      out = v.handle_key(ev)
      out.kind.should eq(:reset)
      out.section.should eq(:reset_all)
    end
  end

  # `reload_all` runs only in `initialize`, so after the host reset settings.json behind this
  # modal the working copies are older than the file. Left alone, ↵ on any form section writes
  # the PRE-reset values back and `apply_settings_saved` pushes them at the live proxy — and
  # `dirty?` compares against the equally stale baseline, so esc does not warn either.
  it "re-pulls every section after the host resets settings behind it" do
    prev = Gori::Settings.bind_port
    begin
      Gori::Settings.bind_port = 9191
      v = PreferencesView.new # builds its working copies from 9191
      v.open(:network)
      Gori::Settings.bind_port = Gori::Settings::DEFAULT_BIND_PORT # the host's reset

      v.reload_from_settings

      backend = MemoryBackend.new(120, 40)
      v.render(Screen.new(backend), Rect.new(0, 0, 120, 40))
      backend.contains?("9191").should be_false
      backend.contains?(Gori::Settings::DEFAULT_BIND_PORT.to_s).should be_true
      v.dirty?.should be_false
    ensure
      Gori::Settings.bind_port = prev
    end
  end

  # The cue is pinned to the card's right edge and the label is clipped to what is left. The
  # 43-character :action label used to push the cue PAST `content.right` — `screen.text` clips
  # at the screen, not the card — so the row ate the right border and the cue vanished.
  it "keeps the reset row inside the card on a narrow terminal" do
    v = PreferencesView.new
    v.open(:reset_all)
    backend = MemoryBackend.new(50, 30)
    v.render(Screen.new(backend), Rect.new(0, 0, 50, 30))
    backend.contains?("↵ reset").should be_true
    # …and the card's right border survives on every row it draws.
    box = v.overlay_box(Rect.new(0, 0, 50, 30))
    ((box.y + 1)...(box.bottom - 1)).each do |y|
      "│┤".includes?(backend.row(y)[box.right - 1]).should be_true # side border or the strip's tee
    end
  end

  it "hides the factory-reset row where the host cannot live-apply it" do
    # The project picker has no shell to re-theme, rebuild a keymap or rebind the proxy, so
    # offering the verb there would half-work. It is gated with the openers it cannot host.
    picker = PreferencesView.new(Set{:theme})
    picker.open_default
    backend = MemoryBackend.new(120, 40)
    picker.render(Screen.new(backend), Rect.new(0, 0, 120, 40))
    backend.contains?("factory default").should be_false
  end

  # The picker has no :reset arm and no shell to confirm in, so a :reset outcome there would
  # be swallowed — the same silence on the Theme row that this change set removed elsewhere.
  it "blocks a reset where the host cannot perform one, out loud" do
    picker = PreferencesView.new(Set{:theme})
    picker.open(:theme)
    picker.handle_key(pctrl(Termisu::Input::Key::LowerR)).kind.should eq(:none)

    backend = MemoryBackend.new(120, 40)
    picker.render(Screen.new(backend), Rect.new(0, 0, 120, 40))
    backend.contains?("open a project to reset this").should be_true
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
