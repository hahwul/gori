require "../spec_helper"
require "../support/memory_backend"

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

  it "renders the title, every message line, and both buttons" do
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
