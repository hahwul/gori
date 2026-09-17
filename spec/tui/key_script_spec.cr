require "../spec_helper"

include Gori::Tui

# `KeyScript.parse` writes the events a terminal would have delivered. The assertions therefore
# run each one back through `Keybind.from_event` and compare against `typed_chord` — the
# spec_helper that builds real input — rather than against a hand-spelled `Verb::Chord`. That
# detour is the whole point: a capital arrives as the lowercase KEY with the uppercase CHAR and
# no Shift flag, and an event built the obvious way instead (UpperF + Shift) satisfies an
# equality assertion against its own twin while firing nothing.

private def chords(script : String) : Array(Gori::Verb::Chord?)
  KeyScript.parse(script).flat_map { |s| s.events.map { |ev| Keybind.from_event(ev) } }
end

private def only_event(script : String) : Termisu::Event::Key
  steps = KeyScript.parse(script)
  steps.size.should eq(1)
  steps.first.events.size.should eq(1)
  steps.first.events.first
end

describe Gori::Tui::KeyScript do
  it "maps each named key to the chord pressing it produces" do
    chords("Enter Tab Escape Up Down Left Right BSpace Space").should eq([
      typed_chord("enter"), typed_chord("tab"), typed_chord("escape"),
      typed_chord("up"), typed_chord("down"), typed_chord("left"), typed_chord("right"),
      typed_chord("backspace"), typed_chord("space"),
    ])
  end

  it "reads the navigation and function keys termisu names differently" do
    KeyScript.parse("PgUp PgDn Home End Delete Insert F1 F12").flat_map(&.events).map(&.key)
      .should eq([
        Termisu::Input::Key::PageUp, Termisu::Input::Key::PageDown,
        Termisu::Input::Key::Home, Termisu::Input::Key::End,
        Termisu::Input::Key::Delete, Termisu::Input::Key::Insert,
        Termisu::Input::Key::F1, Termisu::Input::Key::F12,
      ])
  end

  it "reads a named key however it is capitalised" do
    KeyScript.parse("pgdn PGDN PgDn").flat_map(&.events).map(&.key)
      .should eq([Termisu::Input::Key::PageDown] * 3)
  end

  # Ctrl carries NO character: the parser branch that produces a control chord reports the key
  # alone, and an editor that checks `ev.char` before the keymap does would otherwise insert one.
  it "builds a control chord with no character" do
    ev = only_event("C-r")
    ev.key.should eq(Termisu::Input::Key::LowerR)
    ev.modifiers.ctrl?.should be_true
    ev.@char.should be_nil
    Keybind.from_event(ev).should eq(typed_chord("r", ctrl: true))
  end

  it "builds an alt chord that keeps its character" do
    ev = only_event("M-x")
    ev.modifiers.alt?.should be_true
    ev.char.should eq('x')
    Keybind.from_event(ev).should eq(typed_chord("x", alt: true))
  end

  it "combines C- and M- in either order" do
    a = only_event("C-M-p")
    b = only_event("M-C-p")
    a.modifiers.should eq(b.modifiers)
    Keybind.from_event(a).should eq(typed_chord("p", ctrl: true, alt: true))
  end

  # THE shape that is easy to get wrong: ⇧F is the lowercase key plus the CAPITAL char and no
  # Shift flag — `Keybind.from_event` re-derives shift from `ascii_uppercase?`. Both spellings
  # of it have to produce the identical event.
  it "spells a shifted letter as the capital character, not a Shift flag" do
    %w[S-f F].each do |token|
      ev = only_event(token)
      ev.key.should eq(Termisu::Input::Key::LowerF)
      ev.modifiers.should eq(Termisu::Input::Modifier::None)
      ev.char.should eq('F')
      Keybind.from_event(ev).should eq(typed_chord("f", shift: true))
    end
  end

  it "types a bare printable character as itself" do
    ev = only_event("/")
    ev.char.should eq('/')
    Keybind.from_event(ev).should eq(Keybind.from_event(Termisu::Event::Key.new(
      Termisu::Input::Key.from_char('/'), Termisu::Input::Modifier::None, '/')))
    only_event("7").char.should eq('7')
  end

  it "types a quoted run verbatim, as one step" do
    steps = KeyScript.parse(%(Tab "adMin" Enter))
    steps.size.should eq(3)
    steps[1].events.map(&.char).should eq(['a', 'd', 'M', 'i', 'n'])
    # Each character is still the shape the event path produces, capitals included.
    steps[1].events[2].key.should eq(Termisu::Input::Key::LowerM)
    steps[1].events[2].modifiers.should eq(Termisu::Input::Modifier::None)
  end

  it "keeps whitespace and escapes inside a quoted run" do
    steps = KeyScript.parse(%("a b" "say \\"hi\\"" "back\\\\slash"))
    steps.map(&.events.map(&.char).join).should eq(["a b", %(say "hi"), "back\\slash"])
  end

  it "refuses an unterminated quoted run rather than typing the rest of the script" do
    expect_raises(Gori::Error, /unterminated quoted run/) { KeyScript.parse(%(Tab "admin)) }
  end

  it "turns SLEEP into a pause with no events" do
    steps = KeyScript.parse("Tab SLEEP0.5 Enter")
    steps.size.should eq(3)
    steps[1].events.should be_empty
    steps[1].pause.should eq(500.milliseconds)
    steps[0].pause.should be_nil
  end

  it "refuses a SLEEP that names no duration" do
    expect_raises(Gori::Error, /SLEEP takes seconds/) { KeyScript.parse("SLEEPsoon") }
  end

  # A pause is the one token that costs WALL TIME, and both surfaces take the script from
  # somewhere the operator is not: `SLEEP99999` parks the MCP server's single worker fiber for
  # a day, and hangs `gori run screenshot` in a way nothing distinguishes from a deadlock. Both
  # caps, because one long pause and sixty short ones buy the same outcome.
  it "caps one SLEEP, and the pauses a whole script may add up to" do
    KeyScript.parse("SLEEP0.5").first.pause.should eq(500.milliseconds)
    KeyScript.parse("SLEEP5").first.pause.should eq(5.seconds) # the cap itself is allowed

    expect_raises(Gori::Error, /one SLEEP may pause at most 5s/) { KeyScript.parse("SLEEP6") }
    expect_raises(Gori::Error, /at most 5s/) { KeyScript.parse("Tab SLEEP5.001 Enter") }

    # Six at the per-token cap is 30s, which is the total cap; the seventh is past it.
    KeyScript.parse((["SLEEP5"] * 6).join(' ')).size.should eq(6)
    expect_raises(Gori::Error, /pauses add up to 35.0s, past the 30s/) do
      KeyScript.parse((["SLEEP5"] * 7).join(' '))
    end
  end

  # BTab maps to no chord at all, so a script that sent it would press nothing and report
  # success. Refusing names the token and points at what to write instead.
  it "refuses BTab, which reaches no chord" do
    expect_raises(Gori::Error, /BTab/) { KeyScript.parse("BTab") }
    expect_raises(Gori::Error, /BackTab|no chord/) { KeyScript.parse("S-Tab") }
    # And the premise: pressing it really does map to nothing.
    Keybind.from_event(Termisu::Event::Key.new(Termisu::Input::Key::BackTab)).should be_nil
  end

  it "refuses a shifted symbol, which a terminal never sends as Shift" do
    expect_raises(Gori::Error, /shifted character itself/) { KeyScript.parse("S-1") }
  end

  it "names the token it cannot read" do
    expect_raises(Gori::Error, /"Wiggle"/) { KeyScript.parse("Enter Wiggle Tab") }
  end

  it "reads an empty script as no steps" do
    KeyScript.parse("").should be_empty
    KeyScript.parse("   \n\t ").should be_empty
  end
end
