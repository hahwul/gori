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

describe "Chrome.hidden_tabs" do
  it "returns the tabs hidden from the bar (Miner by default) on empty prefs" do
    hid = Chrome.hidden_tabs([] of {String, Bool}).map(&.first)
    hid.should eq([:miner]) # only the default-hidden tab
  end

  it "excludes the active tab even when its stored visibility is false (it's force-shown)" do
    # Miner is hidden by default but active → force-shown on the bar, so it must NOT
    # also appear in the dropdown list.
    Chrome.hidden_tabs([] of {String, Bool}, force: :miner).map(&.first).should_not contain(:miner)
  end

  it "lists a user-hidden tab and preserves catalog order" do
    prefs = [{"replay", false}, {"convert", false}]
    hid = Chrome.hidden_tabs(prefs).map(&.first)
    hid.includes?(:replay).should be_true
    hid.includes?(:convert).should be_true
    hid.includes?(:miner).should be_true                                 # still default-hidden
    hid.index(:replay).not_nil!.should be < hid.index(:convert).not_nil! # catalog order
  end
end

describe "Chrome.more_button_rect" do
  it "is nil when nothing is hidden" do
    Chrome.more_button_rect(Rect.new(0, 0, 80, 1), hidden_count: 0).should be_nil
  end

  it "reserves a right-anchored pill sized to the ⋯ label when tabs are hidden" do
    rect = Rect.new(0, 0, 80, 1)
    mb = Chrome.more_button_rect(rect, hidden_count: 2).not_nil!
    mb.right.should eq(rect.right)                # flush to the right edge
    mb.w.should eq(Chrome.more_label(2).size + 2) # padded pill
  end

  it "is nil on a row too narrow to host the button" do
    Chrome.more_button_rect(Rect.new(0, 0, 4, 1), hidden_count: 3).should be_nil
  end
end

describe "Chrome.menu_segments" do
  it "keeps tab segments clear of the reserved ⋯ button region" do
    rect = Rect.new(0, 0, 80, 1)
    tabs = Chrome.visible_tabs([] of {String, Bool})
    mb = Chrome.more_button_rect(rect, hidden_count: 1).not_nil!
    segs = Chrome.menu_segments(rect, :project, tabs: tabs, hidden_count: 1)
    segs.each { |(_, seg)| seg.right.should be <= mb.x } # no segment overlaps the button
  end
end

describe "Chrome.scroll_start" do
  it "scrolls active_idx to the end when no prev_start is provided and it doesn't fit" do
    widths = [10, 10, 10, 10, 10]
    Chrome.scroll_start(widths, active_idx: 4, avail: 25).should eq(3)
  end

  it "stabilizes scroll when active_idx is already visible in the window starting at prev_start" do
    widths = [10, 10, 10, 10, 10]
    Chrome.scroll_start(widths, active_idx: 3, avail: 25, prev_start: 2).should eq(2)
  end

  it "scrolls left when active_idx is to the left of prev_start" do
    widths = [10, 10, 10, 10, 10]
    Chrome.scroll_start(widths, active_idx: 1, avail: 25, prev_start: 3).should eq(1)
  end

  it "scrolls right when active_idx is to the right of the window starting at prev_start" do
    widths = [10, 10, 10, 10, 10]
    Chrome.scroll_start(widths, active_idx: 4, avail: 25, prev_start: 1).should eq(3)
  end
end
