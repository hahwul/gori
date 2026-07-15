require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def sample_issue(id : Int64, title : String, host : String = "app.test") : Gori::Store::Issue
  Gori::Store::Issue.new(id, 0_i64, 0_i64, title, Gori::Store::Severity::High, host, nil, "")
end

private def sample_picker : IssuePicker
  IssuePicker.new([
    sample_issue(1_i64, "Reflected XSS"),
    sample_issue(2_i64, "SQL injection"),
    sample_issue(3_i64, "Missing header"),
  ])
end

describe Gori::Tui::IssuePicker do
  it "pins create at index 0 and defaults selection to the first real issue" do
    p = sample_picker
    p.selected.should eq(1)
    p.selected_create?.should be_false
    p.selected_issue.try(&.id).should eq(1_i64)
    p.entry_count.should eq(4) # create + 3 issues
  end

  it "selects create when the project has no issues" do
    p = IssuePicker.new([] of Gori::Store::Issue)
    p.selected.should eq(0)
    p.selected_create?.should be_true
    p.selected_issue.should be_nil
    p.entry_count.should eq(1)
  end

  it "moves onto the create row and back onto issues" do
    p = sample_picker
    p.move(-1)
    p.selected_create?.should be_true
    p.selected_issue.should be_nil
    p.move(1)
    p.selected_issue.try(&.title).should eq("Reflected XSS")
  end

  it "keeps create pinned while filtering and lands on the first match" do
    p = sample_picker
    "sql".each_char { |c| p.query_char(c) }
    p.selected_create?.should be_false
    p.selected_issue.try(&.title).should eq("SQL injection")
    p.move(-1)
    p.selected_create?.should be_true
  end

  it "falls back to create when the filter matches nothing" do
    p = sample_picker
    "zzz".each_char { |c| p.query_char(c) }
    p.selected_create?.should be_true
    p.selected_issue.should be_nil
    p.entry_count.should eq(1)
  end

  it "restores the list on backspace with selection on the first issue" do
    p = sample_picker
    "sql".each_char { |c| p.query_char(c) }
    3.times { p.backspace }
    p.selected.should eq(1)
    p.selected_issue.try(&.id).should eq(1_i64)
  end

  it "renders the create row and issue titles" do
    backend = MemoryBackend.new(100, 30)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("PICK ISSUE").should be_true
    backend.contains?("+ New issue…").should be_true
    backend.contains?("Reflected XSS").should be_true
    backend.contains?("SQL injection").should be_true
  end
end
