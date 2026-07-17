require "../spec_helper"
require "../support/memory_backend"

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
