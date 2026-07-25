require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def render_dialog(dlg : ConfirmDialog, w = 60, h = 20) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  dlg.render(Screen.new(backend), Rect.new(0, 0, w, h))
  backend
end

describe Gori::Tui::ConfirmDialog do
  it "defaults to the cancel (safe) selection" do
    ConfirmDialog.new("DELETE", "Sure?").confirm_selected?.should be_false
  end

  it "toggles the selection with move" do
    dlg = ConfirmDialog.new("DELETE", "Sure?")
    dlg.move
    dlg.confirm_selected?.should be_true
    dlg.move
    dlg.confirm_selected?.should be_false
  end

  it "select_confirm / select_cancel set the choice explicitly" do
    dlg = ConfirmDialog.new("DELETE", "Sure?")
    dlg.select_confirm
    dlg.confirm_selected?.should be_true
    dlg.select_cancel
    dlg.confirm_selected?.should be_false
  end

  it "renders the heading, every message line, and both buttons" do
    dlg = ConfirmDialog.new("DELETE PROJECT", %(Delete "demo"?\nIrreversible.), confirm_label: "delete")
    backend = render_dialog(dlg)
    backend.contains?("DELETE PROJECT").should be_true
    backend.contains?(%(Delete "demo"?)).should be_true
    backend.contains?("Irreversible.").should be_true
    backend.contains?("delete").should be_true
    backend.contains?("cancel").should be_true
  end

  it "no-ops rendering into a too-small area" do
    dlg = ConfirmDialog.new("X", "Y")
    # 10x3 is below the minimum card size — must not raise.
    backend = MemoryBackend.new(10, 3)
    dlg.render(Screen.new(backend), Rect.new(0, 0, 10, 3))
    backend.contains?("X").should be_false
  end
end

# ConfirmDialog is the archetype the Overlay seam was modelled on, and the only modal
# routinely raised from INSIDE another one — so its contract carries two things nothing
# else does: `y`/`n` as first-class accept/reject keys, and the return-to state the shell
# reads to put the parent modal back up.
describe "ConfirmDialog — Overlay contract" do
  it "supplies the chrome the shell's collapsed title/hint ladders read off it" do
    # The badge is the constant "CONFIRM" — the card's varying heading ("DELETE ISSUE")
    # must NOT leak into the top bar, which is exactly what a `title` getter would do.
    h = OverlayHarness.new(ConfirmDialog.new("DELETE ISSUE", "Sure?"))
    h.assert_chrome(OverlayKind::Confirm, "CONFIRM")
    h.overlay.as(ConfirmDialog).heading.should eq("DELETE ISSUE")
  end

  it "commits on y and cancels on n / esc" do
    yes = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    yes.press(Termisu::Input::Key::LowerY).should eq(:closed)
    yes.commits.should eq(1)

    no = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    no.press(Termisu::Input::Key::LowerN).should eq(:closed)
    no.commits.should eq(0)

    esc = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  # The safe default is the whole point of this modal: a reflexive ↵ must NEVER destroy
  # anything. Both branches are asserted, because a spec that only pressed ↵ after moving
  # would still pass if the default flipped to :confirm.
  it "acts on the selection for ↵ — cancel by default, confirm once moved onto it" do
    plain = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    plain.overlay.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)).should eq(:cancel)

    moved = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    moved.press(Termisu::Input::Key::Right) # ←/→/tab all just flip the two buttons
    moved.overlay.as(ConfirmDialog).confirm_selected?.should be_true
    moved.press(Termisu::Input::Key::Enter).should eq(:closed)
    moved.commits.should eq(1)
  end

  # Driven with REAL Input::Keys, not the harness's `type` (which rides every char on
  # LowerA): `y`/`n` branch on the key, so a char-only spec would prove nothing about the
  # neighbouring letters actually reaching the confirm.
  it "swallows every other key so nothing leaks to the view behind the card" do
    h = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    [Termisu::Input::Key::LowerQ, Termisu::Input::Key::LowerZ,
     Termisu::Input::Key::LowerD, Termisu::Input::Key::Space].each do |k|
      h.press(k).should eq(:open)
      # Checked per key, not once at the end: `move` is a direction-ignoring TOGGLE, so an
      # even number of stray moves lands back on the default and a single trailing
      # assertion would see nothing.
      h.overlay.as(ConfirmDialog).confirm_selected?.should be_false
    end
    h.commits.should eq(0)
  end

  # The base default routes a wheel notch to `move`, which HERE flips the lit button — a
  # stray scroll must never re-aim a destructive choice onto the danger button. The
  # pre-seam shell had no wheel arm for :confirm either.
  it "ignores the scroll wheel rather than flipping the lit button" do
    h = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    h.wheel(3) # ONE notch: `move` toggles regardless of direction, so two would cancel out
    h.overlay.as(ConfirmDialog).confirm_selected?.should be_false
  end

  it "routes clicks: the buttons act, the card body holds, outside dismisses" do
    dlg = ConfirmDialog.new("DELETE", "Delete this?", confirm_label: "delete")
    h = OverlayHarness.new(dlg)
    box = h.box.not_nil!
    confirm_rect, cancel_rect = dlg.button_rects(box)
    # Pin the row against the box, not against button_rects — handle_click resolves through
    # that same method, so a spec that only asks it where the buttons are would follow them
    # anywhere they moved, including off the card's last drawn line.
    confirm_rect.y.should eq(box.bottom - 3)
    cancel_rect.y.should eq(box.bottom - 3)

    dlg.handle_click(h.area, confirm_rect.x, confirm_rect.y).should eq(:commit)
    dlg.handle_click(h.area, cancel_rect.x, cancel_rect.y).should eq(:cancel)
    # In the box but off both buttons: a destructive action needs the button itself.
    dlg.handle_click(h.area, box.x + 2, box.y + 1).should eq(:stay)
    dlg.handle_click(h.area, box.x - 1, box.y - 1).should eq(:cancel)
  end

  # An undrawn card has an empty box (see overlay_box), so a click must dismiss rather
  # than land on a phantom button — firing a destructive action on a modal the user
  # cannot even see.
  it "dismisses a click when the area is too small to draw the card" do
    dlg = ConfirmDialog.new("T", "msg")
    tiny = Rect.new(0, 0, 12, 4)
    dlg.handle_click(tiny, 6, 2).should eq(:cancel)
  end

  # The other half of what @confirm_return used to hold in the Runner: `on_close` is what
  # the shell runs after dropping the modal, so a confirm raised from inside another one
  # puts that one back. Nil by default — a palette-launched confirm lands on the bare body.
  it "leaves on_close unset until an open-site asks for a parent restore" do
    ConfirmDialog.new("T", "m").on_close.should be_nil
  end

  # Runner#confirm hangs BOTH halves of the old run_confirm off this hook — the parent
  # restore and the action itself — so it has to fire on either way out. Asserted through
  # the harness (which mirrors close_active_overlay) and against the closure's OWN side
  # effect, not the harness's `closes` counter, which increments per close however the
  # overlay behaves.
  it "runs its on_close when the shell closes it, on cancel and on accept alike" do
    ran = [] of Symbol

    cancelled = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    cancelled.overlay.on_close = -> { ran << :cancelled; nil }
    cancelled.press(Termisu::Input::Key::Escape).should eq(:closed)
    ran.should eq([:cancelled])

    accepted = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    accepted.overlay.on_close = -> { ran << :accepted; nil }
    accepted.press(Termisu::Input::Key::LowerY).should eq(:closed)
    ran.should eq([:cancelled, :accepted])
  end

  it "does not run on_close while it stays up" do
    h = OverlayHarness.new(ConfirmDialog.new("T", "m"))
    ran = 0
    h.overlay.on_close = -> { ran += 1; nil }
    h.press(Termisu::Input::Key::Right).should eq(:open) # a button move keeps it open
    ran.should eq(0)
  end
end
