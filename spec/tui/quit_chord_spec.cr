require "../spec_helper"

include Gori::Tui

# The shell's ^C/^D pre-filter, and the one thing it must stop doing: claiming the chord out
# from under a modal.
#
# `Runner#handle_key` armed the global quit BEFORE overlay dispatch, so a modal that binds the
# chord itself could never see it. The Fuzzer's payload-set editor advertises "^D favorite" on
# its wordlist row and toggles the typed path in and out of favorites on `ev.ctrl_d?`
# (fuzz_set_overlay.cr; the overlay's own half of that is pinned in fuzz_set_overlay_spec.cr).
# In the running TUI ^D instead armed a quit and a second ^D EXITED gori, discarding a
# half-composed payload set that `commit_pending_edits` does not cover — with the card's hint
# and the status bar's "press ^D again to quit" contradicting each other on screen.
#
# `Runner.quit_chord_claimed?` is that pre-filter, extracted (the Runner needs a live tty).
# Asserted HERE rather than through `OverlayHarness` deliberately: that harness's own header
# says it does not model the shell's pre-filter, that ^C/^D "will 'work' here and be dead in
# the TUI", and to assert them against the Runner ladder instead. This is that ladder.

private def chord(k : Termisu::Input::Key, ctrl : Bool = true) : Termisu::Event::Key
  mods = ctrl ? Termisu::Input::Modifier::Ctrl : Termisu::Input::Modifier::None
  Termisu::Event::Key.new(k, mods, nil)
end

describe "Runner.quit_chord_claimed?" do
  ctrl_d = chord(Termisu::Input::Key::LowerD)
  ctrl_c = chord(Termisu::Input::Key::LowerC)

  it "claims both chords on the bare tab body, where the quit arm is the only reader" do
    Runner.quit_chord_claimed?(ctrl_d, modal: false).should be_true
    Runner.quit_chord_claimed?(ctrl_c, modal: false).should be_true
  end

  it "YIELDS both chords while a modal is up, so the overlay's own binding can run" do
    Runner.quit_chord_claimed?(ctrl_d, modal: true).should be_false
    Runner.quit_chord_claimed?(ctrl_c, modal: true).should be_false
  end

  it "ignores the un-modified letters — the arm is Ctrl-only, so `d` still types a `d`" do
    Runner.quit_chord_claimed?(chord(Termisu::Input::Key::LowerD, ctrl: false), modal: false).should be_false
    Runner.quit_chord_claimed?(chord(Termisu::Input::Key::LowerC, ctrl: false), modal: false).should be_false
  end

  it "ignores every other Ctrl chord, including the ones claimed later in the ladder" do
    # ^G/^F/^B/^P are handled further down `handle_key`; the arm must not swallow them.
    {Termisu::Input::Key::LowerG, Termisu::Input::Key::LowerF,
     Termisu::Input::Key::LowerB, Termisu::Input::Key::LowerP}.each do |k|
      Runner.quit_chord_claimed?(chord(k), modal: false).should be_false
    end
  end
end

describe "the exit path that makes the quit-chord yield safe" do
  # Yielding is only defensible because a modal can ALWAYS be dropped: press esc and the very
  # next ^D/^C arms again. That is a property of each concrete Overlay rather than of the
  # shell, so pin it on a sample that includes the modal this fix is about. An overlay added
  # later that swallowed esc would, for the first time, be able to hold the chord hostage.
  it "closes on esc, handing the chord back to the quit arm" do
    esc = chord(Termisu::Input::Key::Escape, ctrl: false)
    ([FuzzSetOverlay.for_list, TabsOverlay.new] of Overlay).each do |ov|
      # :cancel or :commit — the shell drops the modal either way (dispatch_overlay_key).
      ov.handle_key(esc).should_not eq(:stay)
    end
  end

  it "drops on a click outside the card, the base Overlay's other universal exit" do
    ov = FuzzSetOverlay.for_list
    area = Rect.new(0, 0, 120, 30)
    ov.overlay_box(area).should_not be_nil # the card really is drawn inside `area`
    # :cancel for most modals; this one applies-and-closes (:commit) on click-away instead.
    # Either outcome closes it, which is all the exit path needs.
    ov.handle_click(area, area.x, area.bottom - 1).should_not eq(:stay)
  end
end
