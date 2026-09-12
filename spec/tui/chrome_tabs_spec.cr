require "../spec_helper"

include Gori::Tui

# The tab-bar config layer: Chrome.reconcile normalizes a stored {id,visible} layout
# against the canonical catalog (drop unknown, dedupe, append-new, ≥1 visible, cap at
# MAX_SLOTS), and Chrome.visible_slots derives the rendered/nav strip (with `force:` for the
# active tab) plus how many of its entries own a number.
describe "Chrome.reconcile" do
  it "yields the full catalog with the default-hidden tabs hidden on empty prefs" do
    out = Chrome.reconcile([] of {String, Bool})
    out.map(&.first).should eq(Chrome::TABS.map(&.first)) # canonical order, all present
    visible = out.select { |(_, _, v)| v }.map(&.first)
    Chrome::DEFAULT_HIDDEN.each { |sym| visible.includes?(sym).should be_false }
    out.find { |(s, _, _)| s == :miner }.not_nil![2].should be_false
    out.find { |(s, _, _)| s == :project }.not_nil![2].should be_true
  end

  it "fills the nine slots with the capture → triage → record loop, and nothing else" do
    # The default set IS nine, chosen rather than truncated to: an operator's first session
    # goes Project → Target → History → Intercept → Repeater → Fuzzer → Probe → Issues →
    # Notes and never touches `0`. OAST/Decoder/JWT/Comparer/Rewriter are workbenches you
    # reach FOR; Help is one `?` away from anywhere, which beats a slot.
    visible = Chrome.reconcile([] of {String, Bool}).select { |(_, _, v)| v }.map(&.first)
    visible.should eq([:project, :target, :history, :intercept, :repeater, :fuzzer,
                       :probe, :issues, :notes])
    visible.size.should eq(Chrome::MAX_SLOTS) # the default never needs the cap to fire
  end

  it "reaches that order WITHOUT reordering the catalog" do
    # `TABS` order is what reconcile uses to slot a tab a newer build added next to its
    # catalog neighbours in an OLD config. Rewriting it to spell the default bar would make
    # every future insert land in the wrong place, so the default is expressed in
    # DEFAULT_HIDDEN alone — and this pins that it still can be.
    slotted = Chrome::TABS.map(&.first).reject { |s| Chrome::DEFAULT_HIDDEN.includes?(s) }
    slotted.should eq([:project, :target, :history, :intercept, :repeater, :fuzzer,
                       :probe, :issues, :notes])
  end

  it "caps a hand-written or older-build config by POSITION, in the USER's order" do
    # The bar was unbounded before the nine slots, so a saved layout can ask for twelve. The
    # first nine of the operator's own order survive — not the catalog's — since that order
    # is what their fingers learned.
    prefs = [{"help", true}, {"notes", true}, {"issues", true}] +
            Chrome::TABS.map { |(s, _)| {s.to_s, true} }
    visible = Chrome.reconcile(prefs).select { |(_, _, v)| v }.map(&.first)
    visible.size.should eq(Chrome::MAX_SLOTS)
    visible.first(3).should eq([:help, :notes, :issues])
  end

  it "places Rewriter immediately right of Comparer" do
    order = Chrome.reconcile([] of {String, Bool}).map(&.first)
    order.index(:rewriter).not_nil!.should eq(order.index(:comparer).not_nil! + 1)
  end

  it "honors a stored order and visibility, inserting absent catalog tabs at their position" do
    out = Chrome.reconcile([{"help", true}, {"project", false}])
    out[0][0].should eq(:help) # stored order respected
    out[1][0].should eq(:project)
    out[1][2].should be_false                                         # explicit hide survives
    out.map(&.first).includes?(:history).should be_true               # inserted (was absent from prefs)
    out.find { |(s, _, _)| s == :history }.not_nil![2].should be_true # inserted visible
  end

  it "slots a newly-added catalog tab at its catalog-relative position (Probe left of Authorize)" do
    # An older config saved before Probe existed: the catalog order minus :probe. Reconcile
    # must place Probe where the catalog puts it (immediately left of its catalog neighbour,
    # Authorize), not at the end.
    prefs = Chrome::TABS.reject { |(s, _)| s == :probe }
      .map { |(s, _)| {s.to_s, !Chrome::DEFAULT_HIDDEN.includes?(s)} }
    order = Chrome.reconcile(prefs).map(&.first)
    order.index(:probe).not_nil!.should eq(order.index(:authorize).not_nil! - 1)
    order.index(:probe).not_nil!.should be > order.index(:comparer).not_nil!
  end

  it "drops unknown ids and collapses duplicates to the first occurrence" do
    out = Chrome.reconcile([{"bogus", true}, {"repeater", false}, {"repeater", true}])
    out.map(&.first).includes?(:bogus).should be_false
    out.count { |(s, _, _)| s == :repeater }.should eq(1)
    out.find { |(s, _, _)| s == :repeater }.not_nil![2].should be_false # first wins (hidden)
  end

  it "reveals the first entry when a hand-edited config hides everything" do
    all_hidden = Chrome::TABS.map { |(sym, _)| {sym.to_s, false} }
    out = Chrome.reconcile(all_hidden)
    out.count { |(_, _, v)| v }.should eq(1)
    out[0][2].should be_true
  end
end

describe "Chrome.visible_tabs" do
  it "returns the nine slotted tabs in order (everything else hidden)" do
    vis = Chrome.visible_tabs([] of {String, Bool}).map(&.first)
    vis.includes?(:miner).should be_false   # default-hidden
    vis.includes?(:decoder).should be_false # a workbench you reach for — behind `0`
    vis.includes?(:issues).should be_true
    vis.first.should eq(:project)
    vis.size.should eq(Chrome::MAX_SLOTS)
  end

  it "force-includes a hidden active tab at the far right of the strip" do
    # Miner hidden by default; forcing it (a jump to a hidden tab) must append it at the
    # END of the visible strip — right next to the ⋯ list — not splice it mid-strip at its
    # catalog position between Fuzzer and Decoder.
    vis = Chrome.visible_tabs([] of {String, Bool}, force: :miner).map(&.first)
    vis.last.should eq(:miner)
    vis.index(:miner).not_nil!.should be > vis.index(:issues).not_nil!
  end

  it "places the default-visible Probe tab between Fuzzer and Issues" do
    # Probe is slotted by default and sits mid-strip; force: is a no-op for it.
    vis = Chrome.visible_tabs([] of {String, Bool}, force: :probe).map(&.first)
    vis.includes?(:probe).should be_true
    vis.index(:probe).not_nil!.should be > vis.index(:fuzzer).not_nil!
    vis.index(:probe).not_nil!.should be < vis.index(:issues).not_nil!
  end

  it "is a no-op for force: when the active tab is already visible" do
    Chrome.visible_tabs([] of {String, Bool}, force: :project).should eq(Chrome.visible_tabs([] of {String, Bool}))
  end
end

# The slot count is what separates a NUMBER from a tab that merely happens to be on the bar.
# A force-shown hidden tab rides past the ninth slot without one, so `nav.posN` can never
# point at it — the digit on the bar and the digit in the keymap must agree or the bar lies.
describe "Chrome.visible_slots" do
  it "counts every slotted tab and nothing else on a default bar" do
    vis, slots = Chrome.visible_slots([] of {String, Bool})
    slots.should eq(Chrome::MAX_SLOTS)
    slots.should eq(vis.size) # nothing appended: the active tab is not hidden
  end

  it "leaves the force-shown hidden tab OUTSIDE the slots" do
    vis, slots = Chrome.visible_slots([] of {String, Bool}, force: :miner)
    vis.last[0].should eq(:miner)
    slots.should eq(vis.size - 1) # the tenth tab is temporary, and wears no number
    slots.should eq(Chrome::MAX_SLOTS)
  end

  it "counts a force that was already slotted once, not twice" do
    vis, slots = Chrome.visible_slots([] of {String, Bool}, force: :history)
    slots.should eq(vis.size)
  end

  it "agrees with visible_tabs on the strip itself" do
    Chrome.visible_slots([] of {String, Bool}, force: :miner)[0]
      .should eq(Chrome.visible_tabs([] of {String, Bool}, force: :miner))
  end
end

describe "Chrome.hidden_tabs" do
  it "returns the specialised tabs hidden from the bar by default" do
    hid = Chrome.hidden_tabs([] of {String, Bool}).map(&.first)
    # Colormarker joins them: it is a niche display lens, and a fresh install should not
    # spend a tab slot on a list that is empty until someone writes a colour rule. Authorize
    # is the same kind of specialised workbench (seeded on demand), so it starts hidden too.
    # Cookie (#863) is a specialised tool tab like the others — a fresh install with 15 tabs
    # already on the bar should not spend a slot on it until a tester reaches for it.
    # JWT was made visible by #747 and is behind `0` again now that the bar is nine slots:
    # it is a workbench you reach FOR once a Bearer token turns up, not one you live in.
    # Evidence is also hidden until the operator opts into the archive after freezing the
    # first exchange (#1039).
    #
    # The list is longer than DEFAULT_HIDDEN because the bar is nine slots: the six above plus
    # the six the cap pushed off a fifteen-tab default strip, in catalog order.
    # Twelve, in catalog order — the six specialised tabs above plus the five workbenches
    # and Help that the nine-slot default moved behind `0` (see DEFAULT_HIDDEN).
    hid.should eq([:miner, :oast, :sequencer, :decoder, :jwt, :cookie, :comparer,
                   :rewriter, :colormarker, :authorize, :evidence, :help])
    hid.size.should eq(Chrome::TABS.size - Chrome::MAX_SLOTS)
  end

  it "excludes the active tab even when its stored visibility is false (it's force-shown)" do
    # Miner is hidden by default but active → force-shown on the bar, so it must NOT
    # also appear in the dropdown list.
    Chrome.hidden_tabs([] of {String, Bool}, force: :miner).map(&.first).should_not contain(:miner)
  end

  it "lists a user-hidden tab and preserves catalog order" do
    prefs = [{"repeater", false}, {"issues", false}]
    hid = Chrome.hidden_tabs(prefs).map(&.first)
    hid.includes?(:repeater).should be_true
    hid.includes?(:issues).should be_true
    hid.includes?(:miner).should be_true                                  # still default-hidden
    hid.index(:repeater).not_nil!.should be < hid.index(:issues).not_nil! # catalog order
  end
end

describe "Chrome.menu_geometry" do
  nine = Chrome.visible_tabs([] of {String, Bool})

  # The pill used to vanish when nothing was off the bar — a `0` key with nothing on screen
  # pointing at it, on the one row whose job is to teach its own digits. `0` opens the whole
  # catalog whatever the layout, so the stop is unconditional too.
  it "is drawn even when every tab is on the bar" do
    Chrome.menu_geometry(Rect.new(0, 0, 80, 1), :project).more.should_not be_nil
  end

  # The stop FOLLOWS the tabs. Pinned to the right edge it left the row with two anchors and a
  # void between them that grew with the terminal — 46 empty columns at 160, 87 at 200.
  it "sets the stop two columns past the last tab on a wide row" do
    rect = Rect.new(0, 0, 200, 1)
    geo = Chrome.menu_geometry(rect, :project, tabs: nine)
    last = geo.segments.last[1]
    mb = geo.more.not_nil!
    mb.x.should eq(last.right + Chrome::STOP_GAP)
    mb.w.should eq(Chrome.more_label.size + 2) # padded pill, like a tab segment
    mb.right.should be < rect.right            # …and nowhere near the far edge
  end

  # The free run past the stop is RESERVED, not spare: it comes back as a rect so whoever
  # claims it (a readout, the palette key) inherits this same geometry.
  it "hands back the free run past the stop" do
    rect = Rect.new(0, 0, 200, 1)
    geo = Chrome.menu_geometry(rect, :project, tabs: nine)
    mb = geo.more.not_nil!
    geo.trailing.x.should eq(mb.right + 1)
    geo.trailing.right.should eq(rect.right)
    geo.trailing.w.should be > 0 # 200 columns leaves a lot of it
  end

  it "pins the stop to the right edge once the strip stops fitting beside it" do
    rect = Rect.new(0, 0, 80, 1) # nine tabs do not fit in eighty columns
    geo = Chrome.menu_geometry(rect, :project, tabs: nine)
    mb = geo.more.not_nil!
    mb.right.should eq(rect.right)
    geo.trailing.w.should eq(0)
    geo.segments.each { |(_, seg)| seg.right.should be <= mb.x } # no segment overlaps it
  end

  it "draws no stop on a row too narrow to host one" do
    Chrome.menu_geometry(Rect.new(0, 0, 4, 1), :project).more.should be_nil
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

# split_tabs folds visible_slots + hidden_tabs into ONE reconcile pass (the render path needs
# all three every frame). It MUST return exactly what calling them separately returns — this
# locks that hand-merged equivalence across the force/all-hidden edge cases.
describe "Chrome.split_tabs" do
  user_hidden = [{"repeater", false}, {"decoder", false}]
  all_hidden = Chrome::TABS.map { |(sym, _)| {sym.to_s, false} }
  configs = {
    "empty"                => {[] of {String, Bool}, nil.as(Symbol?)},
    "force visible active" => {[] of {String, Bool}, :project.as(Symbol?)},
    "force hidden active"  => {[] of {String, Bool}, :miner.as(Symbol?)},
    "user-hidden"          => {user_hidden, nil.as(Symbol?)},
    "user-hidden + force"  => {user_hidden, :repeater.as(Symbol?)},
    "all-hidden"           => {all_hidden, nil.as(Symbol?)},
    "all-hidden + force"   => {all_hidden, :issues.as(Symbol?)},
  }
  configs.each do |name, (prefs, force)|
    it "equals {visible_tabs, hidden_tabs, slots} for #{name}" do
      vis, slots = Chrome.visible_slots(prefs, force: force)
      Chrome.split_tabs(prefs, force: force).should eq(
        {vis, Chrome.hidden_tabs(prefs, force: force), slots})
    end
  end
end

# `split_tabs` is called once per frame and memoized on (prefs, force). The memo has to
# answer a CHANGED layout with a fresh reconcile, including an in-place edit of the very
# array it was handed — the tabs overlay mutates `Settings.tab_prefs` entries in place.
describe "Chrome.split_tabs memo" do
  it "returns the same visible strip for the same inputs and a new one after a prefs edit" do
    prefs = [{"history", true}, {"project", true}, {"miner", false}]
    vis1, hid1, _ = Chrome.split_tabs(prefs, force: :history)
    vis1.map(&.first).should contain(:project)
    hid1.map(&.first).should contain(:miner)
    prefs[1] = {"project", false} # in place, the shape the overlay writes
    vis2, hid2, _ = Chrome.split_tabs(prefs, force: :history)
    vis2.map(&.first).should_not contain(:project)
    hid2.map(&.first).should contain(:project)
    # a different `force` with the same prefs is a different answer too
    vis3, _, _ = Chrome.split_tabs(prefs, force: :project)
    vis3.map(&.first).should contain(:project)
  end
end
