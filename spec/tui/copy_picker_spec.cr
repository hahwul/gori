require "../spec_helper"
require "../support/memory_backend"

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
