require "../spec_helper"

include Gori::Tui

private alias Key = Termisu::Input::Key
private alias Verdict = PasteGate::Verdict

private def k(c : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Key.from_char(c), char: c)
end

private def start : Termisu::Event::Key
  Termisu::Event::Key.new(Key::PasteStart)
end

private def finish : Termisu::Event::Key
  Termisu::Event::Key.new(Key::PasteEnd)
end

# Takes letters only, the way a one-line field takes text but not ↵.
private def letters(gate : PasteGate, ev : Termisu::Event::Any, now : Time::Instant = Time.instant) : Verdict
  gate.filter(ev, now) { |key| !key.key.enter? }
end

describe PasteGate do
  it "delivers everything outside a paste, and swallows the markers" do
    gate = PasteGate.new
    gate.filter(k('y')) { false }.should eq(Verdict::Deliver)
    letters(gate, start).should eq(Verdict::Absorb)
    gate.pasting?.should be_true
    letters(gate, finish).should eq(Verdict::Absorb)
    gate.pasting?.should be_false
  end

  it "refuses the first key the screen does not take, then the rest of that paste" do
    gate = PasteGate.new
    letters(gate, start)
    letters(gate, k('a')).should eq(Verdict::Deliver)
    letters(gate, k('\r')).should eq(Verdict::Refuse)
    gate.note.should eq(PasteGate::LINE_BREAK)
    # Letting the next line through would glue it onto the first.
    letters(gate, k('b')).should eq(Verdict::Absorb)
    letters(gate, finish)
    # The next paste starts clean.
    letters(gate, start)
    letters(gate, k('c')).should eq(Verdict::Deliver)
  end

  it "says ignored, not stopped, when nothing of the paste went in" do
    gate = PasteGate.new
    gate.filter(start) { false }
    gate.filter(k('y')) { false }.should eq(Verdict::Refuse)
    gate.note.should eq(PasteGate::IGNORED)
  end

  it "swallows a click mid-paste but delivers a resize" do
    gate = PasteGate.new
    letters(gate, start)
    click = Termisu::Event::Mouse.new(3, 3, Termisu::Event::Mouse::Button::Left)
    letters(gate, click).should eq(Verdict::Absorb)
    letters(gate, Termisu::Event::Resize.new(80, 24)).should eq(Verdict::Deliver)
  end

  it "drops the LF half of a pasted CRLF before asking the screen" do
    gate = PasteGate.new
    gate.filter(start) { true }
    gate.filter(Termisu::Event::Key.new(Key::Enter, char: '\r')) { true }.should eq(Verdict::Deliver)
    gate.filter(Termisu::Event::Key.new(Key::Enter, char: '\n')) { true }.should eq(Verdict::Absorb)
  end

  it "starts over on a start marker that arrives while a paste is open" do
    gate = PasteGate.new
    letters(gate, start)
    letters(gate, k('\r')).should eq(Verdict::Refuse)
    # The first paste lost its end marker; the second must not inherit its refusal.
    letters(gate, start)
    letters(gate, k('a')).should eq(Verdict::Deliver)
  end

  it "ends a paste whose end marker never comes" do
    gate = PasteGate.new
    t0 = Time.instant
    letters(gate, start, t0)
    letters(gate, k('\r'), t0).should eq(Verdict::Refuse)
    gate.end_if_stalled(t0 + 100.milliseconds).should be_false
    gate.end_if_stalled(t0 + PasteStall::DEFAULT_STALL).should be_true
    gate.pasting?.should be_false
    # Keys pressed afterwards are the operator's again.
    gate.filter(k('\r')) { false }.should eq(Verdict::Deliver)
  end

  it "reports a refused paste still arriving, so a loop can skip its frames" do
    gate = PasteGate.new
    letters(gate, start)
    gate.refusing?.should be_false
    letters(gate, k('\r'))
    gate.refusing?.should be_true
    letters(gate, finish)
    gate.refusing?.should be_false
  end

  it "recognises its own notes" do
    PasteGate.note?(PasteGate::LINE_BREAK).should be_true
    PasteGate.note?(PasteGate::IGNORED).should be_true
    PasteGate.note?("deleted 2 projects").should be_false
    PasteGate.note?(nil).should be_false
  end
end
