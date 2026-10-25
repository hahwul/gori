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

# The picker re-reads the registry on a poll (`tick_registry`) and reloads only when this moves:
# a peer's create or rename does, the mtime order a capture elsewhere shuffles does not.
describe "ProjectPicker.roster" do
  it "moves on a create or a rename, not on a reorder" do
    a = Gori::Project.new("a", "/r/a/gori.db")
    b = Gori::Project.new("b", "/r/b/gori.db")
    ProjectPicker.roster([a, b]).should eq(ProjectPicker.roster([b, a]))
    ProjectPicker.roster([a, b]).should_not eq(ProjectPicker.roster([a]))
    ProjectPicker.roster([a, b]).should_not eq(ProjectPicker.roster([a, Gori::Project.new("b2", "/r/b/gori.db")]))
  end
end
