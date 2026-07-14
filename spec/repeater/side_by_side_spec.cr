require "../spec_helper"

include Gori::Repeater

describe Gori::Repeater::SideBySide do
  it "marks identical inputs as all Same" do
    a = ["one", "two", "three"]
    rows = SideBySide.rows(Diff.lines(a, a))
    rows.size.should eq(3)
    rows.all? { |r| r.kind.same? }.should be_true
    rows.map(&.left).should eq(a)
    rows.map(&.right).should eq(a)
  end

  it "aligns a replaced line as Changed (old left / new right)" do
    rows = SideBySide.rows(Diff.lines(["a", "X", "c"], ["a", "Y", "c"]))
    rows.size.should eq(3)
    rows[0].kind.same?.should be_true
    rows[1].kind.changed?.should be_true
    rows[1].left.should eq("X")
    rows[1].right.should eq("Y")
    rows[2].kind.same?.should be_true
  end

  it "emits AddOnly rows for pure insertions" do
    rows = SideBySide.rows(Diff.lines(["a", "b"], ["a", "x", "y", "b"]))
    added = rows.select(&.kind.add_only?)
    added.map(&.right).should eq(["x", "y"])
    added.all? { |r| r.left.nil? }.should be_true
  end

  it "emits DelOnly rows for pure deletions" do
    rows = SideBySide.rows(Diff.lines(["a", "x", "y", "b"], ["a", "b"]))
    deleted = rows.select(&.kind.del_only?)
    deleted.map(&.left).should eq(["x", "y"])
    deleted.all? { |r| r.right.nil? }.should be_true
  end

  it "handles empty inputs" do
    SideBySide.rows(Diff.lines([] of String, [] of String)).should be_empty
  end

  it "counts changed rows" do
    rows = SideBySide.rows(Diff.lines(["a", "X"], ["a", "Y"]))
    SideBySide.change_count(rows).should eq(1)
  end
end
