require "../spec_helper"

include Gori::Tui

# The "yes" rule for a destructive confirm, as ONE predicate.
#
# There are two key ladders that answer a ConfirmDialog: the Overlay one
# (`ConfirmDialog#handle_key`, used everywhere in the Runner) and ProjectPicker's own
# `handle_confirm`, which drives the same card as a plain state object and never reaches
# `handle_key`. They drifted: the Overlay arm got a ctrl/alt guard and the picker's did not,
# so `^Y` answered "yes" to DELETE PROJECT — `Registry#delete` → `rm_rf` — from a card whose
# hint only ever advertises a bare `y`. The picker's ladder needs a live Termisu and cannot
# be unit-tested, so what is pinned here is the predicate both ladders now call: if this rule
# is right, neither ladder can be wrong about it.
private def key(k : Termisu::Input::Key, mod : Termisu::Input::Modifier = Termisu::Input::Modifier::None)
  Termisu::Event::Key.new(k, mod)
end

describe "ConfirmDialog.affirmative?" do
  it "accepts the advertised mnemonic, bare and shifted" do
    # `key.y?` matches UpperY on purpose — a caps-locked operator is still answering `y`.
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::LowerY)).should be_true
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::UpperY)).should be_true
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::LowerY, Termisu::Input::Modifier::Shift)).should be_true
  end

  it "refuses a modified Y — the chord the hint never advertises" do
    # ^Y is live in the Repeater/Fuzzer panes — `repeater.copy`/`fuzzer.copy`, since #677 moved
    # attach-chain to ^Q — which is exactly where the marker-removal confirm appears.
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::LowerY, Termisu::Input::Modifier::Ctrl)).should be_false
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::LowerY, Termisu::Input::Modifier::Alt)).should be_false
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::UpperY, Termisu::Input::Modifier::Ctrl)).should be_false
  end

  # The root cause, pinned: `key.y?` is a macro over the key ENUM and is blind to modifiers,
  # so the bare `when key.y?` both ladders used to have accepted `^Y`. If termisu ever makes
  # the macro modifier-aware this example fails, which is the signal to re-read the guard —
  # not to delete it.
  it "differs from the bare termisu macro exactly on the modified chords" do
    ctrl_y = key(Termisu::Input::Key::LowerY, Termisu::Input::Modifier::Ctrl)
    ctrl_y.key.y?.should be_true                       # the old rule said yes...
    ConfirmDialog.affirmative?(ctrl_y).should be_false # ...the guard says no
  end

  it "is not fooled by any other key" do
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::LowerN)).should be_false
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::Enter)).should be_false
    ConfirmDialog.affirmative?(key(Termisu::Input::Key::Escape)).should be_false
  end

  # The Overlay ladder must route through the predicate, not re-derive the rule.
  it "governs ConfirmDialog#handle_key" do
    d = ConfirmDialog.new("DELETE PROJECT", "delete?")
    d.handle_key(key(Termisu::Input::Key::LowerY)).should eq(:commit)
    d.handle_key(key(Termisu::Input::Key::LowerY, Termisu::Input::Modifier::Ctrl)).should eq(:stay)
    # A modified key that CANCELS is deliberately still allowed: it costs a keystroke,
    # where a modified COMMIT costs the project.
    d.handle_key(key(Termisu::Input::Key::LowerN, Termisu::Input::Modifier::Ctrl)).should eq(:cancel)
  end
end
