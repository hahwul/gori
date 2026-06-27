require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::ChoicePicker do
  it "opens on the row whose value is current" do
    ChoicePicker.for_severity(3).selected_value.should eq(3) # High
    ChoicePicker.for_status(2).selected_value.should eq(2)   # false-positive
  end

  it "maps a mnemonic key to its row (case-insensitive), nil for a miss" do
    p = ChoicePicker.for_severity(0)
    p.index_for('h').should eq(1) # HIGH
    p.set_selected(p.index_for('C').not_nil!)
    p.selected_value.should eq(4) # CRITICAL
    p.index_for('z').should be_nil
  end

  it "clamps movement at both ends" do
    p = ChoicePicker.for_status(0)
    p.move(-5)
    p.selected.should eq(0)
    p.move(99)
    p.selected_value.should eq(3) # resolved (last)
  end

  it "renders the title, labels, and a current marker" do
    backend = MemoryBackend.new(80, 24)
    ChoicePicker.for_severity(2).render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("SET SEVERITY").should be_true
    backend.contains?("MEDIUM").should be_true
    backend.contains?("current").should be_true
  end
end
