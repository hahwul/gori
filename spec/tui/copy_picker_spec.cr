require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def sample_picker : CopyPicker
  CopyPicker.new("COPY REQUEST AS", [
    CopyMenu::Option.new("URL", 'u', "https://h/p"),
    CopyMenu::Option.new("Headers", 'h', "Host: h"),
    CopyMenu::Option.new("cURL", 'l', "curl 'https://h/p'"),
  ])
end

describe Gori::Tui::CopyPicker do
  it "maps a mnemonic key to its row (case-insensitive), nil for a miss" do
    p = sample_picker
    p.index_for('h').should eq(1)
    p.index_for('L').should eq(2)
    p.index_for('z').should be_nil
  end

  it "returns the selected option's payload" do
    p = sample_picker
    p.set_selected(p.index_for('l').not_nil!)
    p.selected_option.not_nil!.text.should eq("curl 'https://h/p'")
  end

  it "clamps movement at both ends" do
    p = sample_picker
    p.move(-5)
    p.selected.should eq(0)
    p.move(99)
    p.selected.should eq(2)
  end

  it "reports empty for an empty option list" do
    CopyPicker.new("COPY AS", [] of CopyMenu::Option).empty?.should be_true
    sample_picker.empty?.should be_false
  end

  it "renders the title, labels, and byte sizes" do
    backend = MemoryBackend.new(80, 24)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("COPY REQUEST AS").should be_true
    backend.contains?("URL").should be_true
    backend.contains?("cURL").should be_true
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
#
# CopyPicker is PROMPT-TIER: an Overlay like any migrated modal, but the Runner keeps it
# in its own slot rather than @active_overlay so it floats over @overlay (the History
# detail drill-in) instead of replacing it. What it dispatches, though, is the same
# :stay/:commit/:cancel contract, so it is driven through OverlayHarness here.
describe "CopyPicker — Overlay contract" do
  it "names and hints itself exactly as the Runner's deleted ladder arms did" do
    OverlayHarness.new(sample_picker).assert_chrome(OverlayKind::CopyAs, "COPY REQUEST AS")
    sample_picker.hint.should eq("↑/↓ select · ↵ copy · key picks · esc cancel")
  end

  it "copies on ↵ and hands the picked row to the injected closure" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    picked = [] of String
    h.on_commit { picked << (ov.selected_option.try(&.label) || "none"); true }

    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    picked.size.should eq(1)
    picked.first.should eq(ov.selected_option.not_nil!.label)
  end

  it "a row mnemonic selects AND copies in one keystroke" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    idx = ov.index_for('u').not_nil!
    h.press(Termisu::Input::Key::LowerU, 'u').should eq(:closed)
    ov.selected.should eq(idx)
    h.commits.should eq(1)
  end

  it "keeps its j/k vim fallback for keys that are NOT mnemonics" do
    # Deliberately asymmetric with SendPicker, whose 'j' IS a mnemonic (JWT). A shared
    # picker base is exactly where that difference would get quietly unified away.
    ov = sample_picker
    ov.index_for('j').should be_nil
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::LowerJ, 'j').should eq(:open)
    ov.selected.should eq(1)
    h.press(Termisu::Input::Key::LowerK, 'k').should eq(:open)
    ov.selected.should eq(0)
    h.commits.should eq(0)
  end

  it "ignores a mnemonic pressed with a modifier (^B is reveal, not 'copy body')" do
    h = OverlayHarness.new(sample_picker)
    h.press(Termisu::Input::Key::LowerU, 'u', ctrl: true).should eq(:open)
    h.commits.should eq(0)
  end

  it "esc cancels without copying" do
    h = OverlayHarness.new(sample_picker)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  it "a click on a row copies it; a click outside the card dismisses" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    h.click_in_box(3, 1).should eq(:closed) # rows start at box.y + 1
    ov.selected.should eq(0)
    h.commits.should eq(1)

    away = OverlayHarness.new(sample_picker)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
    away.commits.should eq(0)
  end

  it "swallows a click inside the card but off the list (never leaks to the pane below)" do
    h = OverlayHarness.new(sample_picker)
    box = h.box.not_nil!
    h.overlay.handle_click(h.area, box.x, box.y).should eq(:stay) # the border
    h.commits.should eq(0)
  end

  it "scrolls with the wheel (Runner#handle_wheel delegates to move)" do
    ov = sample_picker
    OverlayHarness.new(ov).wheel(1)
    ov.selected.should eq(1)
  end
end
