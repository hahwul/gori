require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def sample_picker : NotePicker
  NotePicker.new([
    NotePicker::Row.new(10_i64, "1:XSS notes", "payload details"),
    NotePicker::Row.new(11_i64, "2:Auth flow", "token reuse"),
    NotePicker::Row.new(12_i64, "3:Recon", "subdomains"),
  ])
end

describe Gori::Tui::NotePicker do
  it "pins create at index 0 and defaults selection to the first real note" do
    p = sample_picker
    p.selected.should eq(1)
    p.selected_create?.should be_false
    p.selected_row.try(&.id).should eq(10_i64)
    p.entry_count.should eq(4)
  end

  it "selects create when there are no notes" do
    p = NotePicker.new([] of NotePicker::Row)
    p.selected.should eq(0)
    p.selected_create?.should be_true
    p.selected_row.should be_nil
    p.entry_count.should eq(1)
  end

  it "moves onto the create row and back onto notes" do
    p = sample_picker
    p.move(-1)
    p.selected_create?.should be_true
    p.move(1)
    p.selected_row.try(&.label).should eq("1:XSS notes")
  end

  it "keeps create pinned while filtering" do
    p = sample_picker
    "auth".each_char { |c| p.query_char(c) }
    p.selected_row.try(&.id).should eq(11_i64)
    p.move(-1)
    p.selected_create?.should be_true
  end

  it "falls back to create when the filter matches nothing" do
    p = sample_picker
    "zzz".each_char { |c| p.query_char(c) }
    p.selected_create?.should be_true
    p.entry_count.should eq(1)
  end

  it "renders the create row and note labels" do
    backend = MemoryBackend.new(100, 30)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("PICK NOTE").should be_true
    backend.contains?("+ New note…").should be_true
    backend.contains?("1:XSS notes").should be_true
    backend.contains?("2:Auth flow").should be_true
  end
end
