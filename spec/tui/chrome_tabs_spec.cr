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
    Chrome::DEFAULT_HIDDEN.each { |sym| visible.includes?(sym).should be_false } # only :miner hidden
    out.find { |(s, _, _)| s == :miner }.not_nil![2].should be_false
    out.find { |(s, _, _)| s == :comparer }.not_nil![2].should be_true # now a default-visible tab
    out.find { |(s, _, _)| s == :convert }.not_nil![2].should be_true  # now a default-visible tab
    out.find { |(s, _, _)| s == :project }.not_nil![2].should be_true
  end

  it "honors a stored order and visibility, inserting absent catalog tabs at their position" do
    out = Chrome.reconcile([{"help", true}, {"project", false}])
    out[0][0].should eq(:help) # stored order respected
    out[1][0].should eq(:project)
    out[1][2].should be_false                                         # explicit hide survives
    out.map(&.first).includes?(:history).should be_true               # inserted (was absent from prefs)
    out.find { |(s, _, _)| s == :history }.not_nil![2].should be_true # inserted visible
  end

  it "slots a newly-added catalog tab at its catalog-relative position (Prism left of Findings)" do
    # An older config saved before Prism existed: the catalog order minus :prism. Reconcile
    # must place Prism where the catalog puts it (immediately left of Findings), not at the end.
    prefs = Chrome::TABS.reject { |(s, _)| s == :prism }
      .map { |(s, _)| {s.to_s, !Chrome::DEFAULT_HIDDEN.includes?(s)} }
    order = Chrome.reconcile(prefs).map(&.first)
    order.index(:prism).not_nil!.should eq(order.index(:findings).not_nil! - 1)
    order.index(:prism).not_nil!.should be > order.index(:comparer).not_nil!
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
    vis.includes?(:miner).should be_false # only Miner is hidden by default now
    vis.includes?(:comparer).should be_true
    vis.includes?(:convert).should be_true
    vis.first.should eq(:project)
    vis.size.should eq(Chrome::TABS.size - Chrome::DEFAULT_HIDDEN.size)
  end

  it "force-includes a hidden active tab at its catalog-relative position" do
    # Miner hidden by default; forcing it must slot it where it sits in the catalog
    # (between Fuzzer and Convert).
    vis = Chrome.visible_tabs([] of {String, Bool}, force: :miner).map(&.first)
    vis.includes?(:miner).should be_true
    vis.index(:miner).not_nil!.should be > vis.index(:fuzzer).not_nil!
    vis.index(:miner).not_nil!.should be < vis.index(:convert).not_nil!
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
