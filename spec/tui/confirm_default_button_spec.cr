require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# A DANGER card lights cancel — ↵ under "DELETE 40 FLOWS?" must not delete. A card asking
# something recoverable (open / run / save) lights its own verb, so ↵ means go there too,
# and the hint spells what ↵ will do from the buttons rather than a generic `↵ select`.
describe "ConfirmDialog default button" do
  it "lights cancel on a danger card" do
    dlg = ConfirmDialog.new("DELETE FLOWS", "Sure?", confirm_label: "delete", danger: true)
    dlg.confirm_selected?.should be_false
    dlg.hint.should contain("↵ cancel")
    dlg.hint.should contain("y delete")
    OverlayHarness.new(dlg).press(Termisu::Input::Key::Enter).should eq(:closed)
  end

  it "lights the verb on a non-danger card, and ↵ commits" do
    dlg = ConfirmDialog.new("RUN FUZZ", "Send 40 requests?", confirm_label: "run", danger: false)
    dlg.confirm_selected?.should be_true
    dlg.hint.should contain("↵ run")
    h = OverlayHarness.new(dlg)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  it "follows the selection in the hint" do
    dlg = ConfirmDialog.new("OPEN", "Open it?", confirm_label: "open", danger: false)
    dlg.move
    dlg.hint.should contain("↵ cancel")
  end
end
