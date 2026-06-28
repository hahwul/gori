require "../spec_helper"

include Gori::Tui

# The tab-bar config layer: Chrome.reconcile normalizes a stored {id,visible} layout
# against the canonical catalog (drop unknown, dedupe, append-new, ≥1 visible), and
# Chrome.visible_tabs derives the rendered/nav strip (with `force:` for the active tab).
describe "Chrome.reconcile" do
  it "yields the full catalog with the default-hidden tabs hidden on empty prefs" do
    out = Chrome.reconcile([] of {String, Bool})
    out.map(&.first).should eq(Chrome::TABS.map(&.first)) # canonical order, all present
    visible = out.select { |(_, _, v)| v }.map(&.first)
    Chrome::DEFAULT_HIDDEN.each { |sym| visible.includes?(sym).should be_false } # only :agent hidden
    out.find { |(s, _, _)| s == :agent }.not_nil![2].should be_false
    out.find { |(s, _, _)| s == :comparer }.not_nil![2].should be_true # now a default-visible tab
    out.find { |(s, _, _)| s == :convert }.not_nil![2].should be_true  # now a default-visible tab
    out.find { |(s, _, _)| s == :project }.not_nil![2].should be_true
  end

  it "honors a stored order and visibility, appending catalog tabs absent from prefs" do
    out = Chrome.reconcile([{"help", true}, {"project", false}])
    out[0][0].should eq(:help)    # stored order respected
    out[1][0].should eq(:project)
    out[1][2].should be_false     # explicit hide survives
    out.map(&.first).includes?(:history).should be_true # appended (was absent from prefs)
    out.find { |(s, _, _)| s == :history }.not_nil![2].should be_true # appended visible
  end

  it "drops unknown ids and collapses duplicates to the first occurrence" do
    out = Chrome.reconcile([{"bogus", true}, {"replay", false}, {"replay", true}])
    out.map(&.first).includes?(:bogus).should be_false
    out.count { |(s, _, _)| s == :replay }.should eq(1)
    out.find { |(s, _, _)| s == :replay }.not_nil![2].should be_false # first wins (hidden)
  end

  it "reveals the first entry when a hand-edited config hides everything" do
    all_hidden = Chrome::TABS.map { |(sym, _)| {sym.to_s, false} }
    out = Chrome.reconcile(all_hidden)
    out.count { |(_, _, v)| v }.should eq(1)
    out[0][2].should be_true
  end
end

describe "Chrome.visible_tabs" do
  it "returns only the visible tabs in order (default-hidden tabs excluded)" do
    vis = Chrome.visible_tabs([] of {String, Bool}).map(&.first)
    vis.includes?(:agent).should be_false # only Agent is hidden by default now
    vis.includes?(:comparer).should be_true
    vis.includes?(:convert).should be_true
    vis.first.should eq(:project)
    vis.size.should eq(Chrome::TABS.size - Chrome::DEFAULT_HIDDEN.size)
  end

  it "force-includes a hidden active tab at its catalog-relative position" do
    # Agent hidden by default; forcing it must slot it where it sits in the catalog (last).
    vis = Chrome.visible_tabs([] of {String, Bool}, force: :agent).map(&.first)
    vis.includes?(:agent).should be_true
    vis.index(:agent).not_nil!.should be > vis.index(:notes).not_nil!
    vis.index(:agent).not_nil!.should be < vis.index(:help).not_nil!
  end

  it "places the default-visible Convert tab between Fuzzer and Comparer" do
    # Convert is visible by default and sits mid-strip; force: is a no-op for it.
    vis = Chrome.visible_tabs([] of {String, Bool}, force: :convert).map(&.first)
    vis.includes?(:convert).should be_true
    vis.index(:convert).not_nil!.should be > vis.index(:fuzzer).not_nil!
    vis.index(:convert).not_nil!.should be < vis.index(:comparer).not_nil!
  end

  it "is a no-op for force: when the active tab is already visible" do
    Chrome.visible_tabs([] of {String, Bool}, force: :project).should eq(Chrome.visible_tabs([] of {String, Bool}))
  end
end
