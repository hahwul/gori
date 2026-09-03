require "../spec_helper"

include Gori::Tui

# Two stand-ins for the sub-tab view classes that include the marker module. Distinct classes
# on purpose: a strip's marks may be asked about any of the nine view types, and the set must
# never confuse two objects of different kinds either.
private class FakeChipA
  include SubtabRef
end

private class FakeChipB
  include SubtabRef
end

# Multi-select on a sub-tab strip (#683). `TabController` cannot be built without a live
# `Host`, so the rule that decides WHICH sub-tabs a confirmed `^W` closes is pinned on the
# state object it reads — the same reason `ProjectMarks` has a spec of its own.
describe Gori::Tui::SubtabMarks do
  chips = [FakeChipA.new, FakeChipB.new, FakeChipA.new] of SubtabRef

  it "toggles a mark on and back off" do
    m = SubtabMarks.new
    m.empty?.should be_true
    m.toggle(chips[1])
    m.marked?(chips[1]).should be_true
    m.size.should eq(1)
    m.toggle(chips[1])
    m.marked?(chips[1]).should be_false
    m.empty?.should be_true
  end

  it "keys on identity, not on what the view looks like" do
    # Two fresh instances of the same class are two sub-tabs. A Set of the views would call
    # `==`/`hash`, which a view class is free to define by content; object_id cannot be.
    m = SubtabMarks.new
    m.toggle(chips[0])
    m.marked?(chips[2]).should be_false
    m.marked?(chips[0]).should be_true
  end

  it "marks everything the filter shows, unioning with what is already marked" do
    m = SubtabMarks.new
    m.toggle(chips[2])
    m.mark_all([chips[0], chips[1]] of SubtabRef) # ⇧T over a narrowed strip
    m.size.should eq(3)
    chips.each { |c| m.marked?(c).should be_true }
  end

  it "clears everything on esc" do
    m = SubtabMarks.new
    m.mark_all(chips)
    m.clear
    m.empty?.should be_true
  end

  it "hands back exactly the marks a batch acted on, and keeps the rest" do
    # `unmark` is what a bulk close calls with the views it actually removed. A refused
    # sub-tab is NOT in that list, so its mark stays and the retry is still assembled.
    m = SubtabMarks.new
    m.mark_all(chips)
    m.unmark([chips[0], chips[2]] of SubtabRef)
    m.size.should eq(1)
    m.marked?(chips[1]).should be_true
  end

  it "retains only the marks whose sub-tab is still open" do
    m = SubtabMarks.new
    m.mark_all(chips)
    m.retain([chips[1]] of SubtabRef) # chips 0 and 2 were closed by a peer session
    m.size.should eq(1)
    m.marked?(chips[1]).should be_true
    m.marked?(chips[0]).should be_false
  end

  it "pins the marked object, so a later allocation cannot inherit its mark" do
    # The whole reason the set is a Hash with the object as VALUE: a bare object_id is an
    # address, and `reconcile` allocates fresh views on the same tick a closed one becomes
    # garbage. Hold a mark on an object the spec then drops every other reference to; run a
    # collection; allocate more. None of the newcomers may read as marked.
    m = SubtabMarks.new
    m.toggle(FakeChipA.new) # the spec keeps no reference — only the mark set does
    GC.collect
    newcomers = Array.new(64) { FakeChipA.new.as(SubtabRef) }
    newcomers.none? { |c| m.marked?(c) }.should be_true
    m.size.should eq(1) # and the original is still there to be retained or unmarked
  end
end
