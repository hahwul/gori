require "../../spec_helper"

# Runner owns a live terminal and is not constructed anywhere under spec/, so pin this open-site
# in source like `spec/tui/subtab_find_key_spec.cr`. The Scope and Store halves are exercised in
# `spec/scope_spec.cr`; this checks that the Comparer actually composes them before the LIMIT.
describe "the Comparer flow picker" do
  it "applies the active project Scope lens before selecting its recent rows" do
    path = File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "comparer.cr")
    source = File.read(path)
    body = source[/def comparer_pick.*?^  end/m]

    body.should_not be_nil
    body.should contain("@session.store.search(@scope.filter, 2000)")
    body.should_not contain("recent_flows(2000)")
  end
end
