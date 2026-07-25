require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def sample_picker : SendPicker
  SendPicker.new("Send selection to", "SGVsbG8=", [
    SendMenu::Destination.new("Decoder", 'd', :decoder, "decode / encode input"),
    SendMenu::Destination.new("Sequencer", 's', :sequencer, "analyze tokens"),
  ])
end

describe Gori::Tui::SendPicker do
  it "maps a mnemonic key to its row (case-insensitive), nil for a miss" do
    p = sample_picker
    p.index_for('d').should eq(0)
    p.index_for('S').should eq(1)
    p.index_for('z').should be_nil
  end

  it "returns the selected destination and shares one payload across rows" do
    p = sample_picker
    p.set_selected(p.index_for('d').not_nil!)
    dest = p.selected_destination.not_nil!
    dest.tab.should eq(:decoder)
    p.payload.should eq("SGVsbG8=")
  end

  it "clamps movement at both ends" do
    p = sample_picker
    p.move(-5)
    p.selected.should eq(0)
    p.move(99)
    p.selected.should eq(1)
  end

  it "reports empty for an empty destination list" do
    SendPicker.new("Send selection to", "x", [] of SendMenu::Destination).empty?.should be_true
    sample_picker.empty?.should be_false
  end

  it "renders the sized title, labels, and hints" do
    backend = MemoryBackend.new(80, 24)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("Send selection to").should be_true
    backend.contains?("Decoder").should be_true
    backend.contains?("decode / encode input").should be_true
  end
end

describe Gori::Tui::SendMenu do
  it "offers Decoder as a string-handling destination" do
    dests = SendMenu.destinations
    dests.any? { |d| d.tab == :decoder }.should be_true
    dests.map(&.key).uniq.size.should eq(dests.size) # mnemonics are unique
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
#
# Prompt-tier, exactly like CopyPicker: an Overlay the Runner keeps in its own slot so it
# floats over @overlay rather than replacing it.
describe "SendPicker — Overlay contract" do
  it "names itself SEND TO, not by the card's own sentence heading" do
    # focus_label showed the literal "SEND TO"; the card says "Send selection to · 8 B".
    # A region badge is a name, not a sentence — keep them distinct.
    OverlayHarness.new(sample_picker).assert_chrome(OverlayKind::SendTo, "SEND TO")
    sample_picker.hint.should eq("↑/↓ select · ↵ send · key picks · esc cancel")
    OverlayHarness.new(sample_picker).rendered?("Send selection to").should be_true
  end

  it "sends on ↵ and hands the picked destination to the injected closure" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    sent = [] of Symbol
    h.on_commit { sent << ov.selected_destination.not_nil!.tab; true }
    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    sent.should eq([:sequencer])
  end

  it "has NO j/k fallback — 'j' is the JWT mnemonic and must send" do
    # The real destination list includes JWT at 'j'. A j/k nav fallback (which CopyPicker
    # does keep) would shadow that mnemonic and be asymmetric: k moves up, j sends.
    dests = SendMenu.destinations
    ov = SendPicker.new("Send selection to", "abc", dests)
    ov.index_for('j').should_not be_nil
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::LowerJ, 'j').should eq(:closed)
    ov.selected_destination.try(&.tab).should eq(:jwt)
    h.commits.should eq(1)
  end

  it "swallows a non-mnemonic key rather than navigating" do
    ov = sample_picker
    ov.index_for('k').should be_nil
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::LowerK, 'k').should eq(:open)
    ov.selected.should eq(0)
    h.commits.should eq(0)
  end

  it "esc cancels without sending; a click on a row sends; a click away dismisses" do
    esc = OverlayHarness.new(sample_picker)
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)

    ov = sample_picker
    click = OverlayHarness.new(ov)
    click.click_in_box(3, 2).should eq(:closed) # rows start at box.y + 1 → second row
    ov.selected.should eq(1)
    click.commits.should eq(1)

    away = OverlayHarness.new(sample_picker)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
    away.commits.should eq(0)
  end
end
