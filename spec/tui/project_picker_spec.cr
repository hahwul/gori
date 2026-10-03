require "../spec_helper"

include Gori::Tui

describe "ProjectPicker.initial_selection" do
  it "opens on the most recently used project when one exists" do
    ProjectPicker.initial_selection(2).should eq(3) # below New / Temp / Search
  end

  it "opens on + New project when there is nothing to reopen" do
    ProjectPicker.initial_selection(0).should eq(0)
  end
end
