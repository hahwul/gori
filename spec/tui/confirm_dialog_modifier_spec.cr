require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# `key.y?` / `key.n?` are termisu's CASE-INSENSITIVE macros (input/key.cr) — they compare the
# key enum only and know nothing about Ctrl/Alt. An unguarded `when key.y?` therefore accepts
# `^Y` and `⌥Y` as a destructive confirm on a card whose hint advertises a bare `y` and
# nothing else. `^Y` is not hypothetical: it is a live Repeater/Fuzzer chord
# (repeater.attach-chain), fired in the very pane the marker-removal danger confirm pops up
# in. Every confirm in the app shares this one dialog — DELETE PROJECT, DELETE FLOW,
# REPLACE ALL, QUIT GORI — so the guard is asserted here once, for all of them.
private CD_Y   = Termisu::Input::Key::LowerY
private CD_UPY = Termisu::Input::Key::UpperY
private CD_N   = Termisu::Input::Key::LowerN

private def confirm : ConfirmDialog
  ConfirmDialog.new("DELETE PROJECT", "Delete \"demo\"?", confirm_label: "delete")
end

describe "ConfirmDialog — modifier-guarded mnemonics" do
  it "refuses a modified y so a live chord can never fire the destructive commit" do
    {% for mods in [{true, false}, {false, true}, {true, true}] %}
      ctrl, alt = {{ mods[0] }}, {{ mods[1] }}
      h = OverlayHarness.new(confirm)
      # Swallowed like every other unhandled key — :stay, so nothing leaks to the view
      # behind the card either.
      h.press(CD_Y, ctrl: ctrl, alt: alt).should eq(:open)
      h.commits.should eq(0)
    {% end %}
  end

  it "still commits on the advertised bare y — and on a SHIFTED one" do
    # `key.y?` matches UpperY by design, and the hint says `y confirm`; guarding shift too
    # would break the mnemonic under caps-lock and make the card feel dead.
    bare = OverlayHarness.new(confirm)
    bare.press(CD_Y).should eq(:closed)
    bare.commits.should eq(1)

    upper = OverlayHarness.new(confirm)
    upper.press(CD_UPY, shift: true).should eq(:closed)
    upper.commits.should eq(1)
  end

  it "keeps a modified n / esc cancelling rather than dead-keying them" do
    # Deliberately laxer than `y`: a modified key that CANCELS costs one keystroke, one that
    # COMMITS destroys data. Refusing `^N` would only make the modal feel unresponsive.
    {CD_N, Termisu::Input::Key::Escape}.each do |k|
      h = OverlayHarness.new(confirm)
      h.press(k, ctrl: true).should eq(:closed), "#{k} with ctrl no longer cancels"
      h.commits.should eq(0)
    end
  end

  it "leaves the raw vocabulary intact — a modified y is :stay, not :commit" do
    # Asserted against handle_key directly: the harness collapses :cancel and a truthy
    # :commit to the same :closed, so only this can tell "swallowed" from "cancelled".
    dlg = confirm
    ev = Termisu::Event::Key.new(CD_Y, Termisu::Input::Modifier::Ctrl, 'y')
    dlg.handle_key(ev).should eq(:stay)
    dlg.confirm_selected?.should be_false # and it did not re-aim the lit button either
  end
end
