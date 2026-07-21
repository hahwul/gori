require "../spec_helper"

private alias D = Gori::Repeater::Diff
private alias DK = Gori::Repeater::DiffKind
private alias DLine = Gori::Repeater::DiffLine

# Rebuild the original `a` from a diff: the lines that were present in `a` are
# exactly the Same and Del rows, in order.
private def rebuild_a(diff : Array(DLine)) : Array(String)
  diff.select { |d| d.kind == DK::Same || d.kind == DK::Del }.map(&.text)
end

# Rebuild the new `b` from a diff: the lines present in `b` are the Same and Add
# rows, in order.
private def rebuild_b(diff : Array(DLine)) : Array(String)
  diff.select { |d| d.kind == DK::Same || d.kind == DK::Add }.map(&.text)
end

private def kinds(diff : Array(DLine)) : Array(DK)
  diff.map(&.kind)
end

describe Gori::Repeater::Diff do
  describe "identical / disjoint extremes" do
    it "marks a fully-identical pair as all Same with change_count 0" do
      a = ["alpha", "beta", "gamma"]
      diff = D.lines(a, a)
      diff.size.should eq(3)
      kinds(diff).all? { |k| k == DK::Same }.should be_true
      D.change_count(diff).should eq(0)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(a)
    end

    it "reports change_count == a.size + b.size for a fully-disjoint pair" do
      a = ["a1", "a2", "a3"]
      b = ["b1", "b2"]
      diff = D.lines(a, b)
      D.change_count(diff).should eq(a.size + b.size)
      # No Same rows at all when nothing is shared.
      diff.any? { |d| d.kind == DK::Same }.should be_false
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end

    it "returns an empty diff for two empty inputs" do
      D.lines([] of String, [] of String).should be_empty
    end
  end

  describe "one empty side (emit_middle mm==0 / nn==0)" do
    it "emits pure Add rows when the original side is empty" do
      diff = D.lines([] of String, ["a", "b"])
      kinds(diff).should eq([DK::Add, DK::Add])
      diff.map(&.text).should eq(["a", "b"])
      D.change_count(diff).should eq(2)
      rebuild_a(diff).should eq([] of String)
      rebuild_b(diff).should eq(["a", "b"])
    end

    it "emits pure Del rows when the new side is empty" do
      diff = D.lines(["a", "b"], [] of String)
      kinds(diff).should eq([DK::Del, DK::Del])
      diff.map(&.text).should eq(["a", "b"])
      D.change_count(diff).should eq(2)
      rebuild_a(diff).should eq(["a", "b"])
      rebuild_b(diff).should eq([] of String)
    end

    it "treats a single-element vs empty as one Add / one Del" do
      D.lines([] of String, ["only"]).map(&.kind).should eq([DK::Add])
      D.lines(["only"], [] of String).map(&.kind).should eq([DK::Del])
    end
  end

  describe "documented tie-break: Del before Add on an LCS-length tie" do
    it "emits Del then Add for a single replaced line" do
      diff = D.lines(["X"], ["Y"])
      kinds(diff).should eq([DK::Del, DK::Add])
      diff.map(&.text).should eq(["X", "Y"])
      rebuild_a(diff).should eq(["X"])
      rebuild_b(diff).should eq(["Y"])
    end

    it "keeps Del ahead of Add across a changed middle with common prefix/suffix" do
      diff = D.lines(["ctx", "old", "tail"], ["ctx", "new", "tail"])
      kinds(diff).should eq([DK::Same, DK::Del, DK::Add, DK::Same])
      diff.map(&.text).should eq(["ctx", "old", "new", "tail"])
    end

    it "orders every Del before the Adds when several lines are replaced" do
      a = ["p", "o1", "o2", "s"]
      b = ["p", "n1", "n2", "s"]
      diff = D.lines(a, b)
      # first non-Same row after the peeled prefix must be a Del
      middle = diff.reject { |d| d.kind == DK::Same }
      middle.first.kind.should eq(DK::Del)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end
  end

  describe "insertions and deletions preserve reconstruction" do
    it "reconstructs both sides for a pure insertion" do
      a = ["a", "b"]
      b = ["a", "x", "y", "b"]
      diff = D.lines(a, b)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
      D.change_count(diff).should eq(2)
    end

    it "reconstructs both sides for a pure deletion" do
      a = ["a", "x", "y", "b"]
      b = ["a", "b"]
      diff = D.lines(a, b)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
      D.change_count(diff).should eq(2)
    end
  end

  describe "empty-string lines mixed with content" do
    it "keeps blank prefix/suffix Same and diffs only the changed middle" do
      a = ["", "content", ""]
      b = ["", "changed", ""]
      diff = D.lines(a, b)
      kinds(diff).should eq([DK::Same, DK::Del, DK::Add, DK::Same])
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end

    it "distinguishes blank lines added/removed from surrounding content" do
      a = ["head", "body"]
      b = ["head", "", "body", ""]
      diff = D.lines(a, b)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
      # two blank lines are additions
      D.change_count(diff).should eq(2)
    end

    it "handles an all-blank vs mixed-blank pair" do
      a = ["", "", ""]
      b = ["", "x", ""]
      diff = D.lines(a, b)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end
  end

  describe "multibyte / duplicate-heavy stress" do
    it "diffs CJK and emoji lines and reconstructs both sides" do
      a = ["안녕", "世界", "🎉", "shared"]
      b = ["안녕", "세계", "🎉", "shared"]
      diff = D.lines(a, b)
      # only the second line changed (世界 -> 세계)
      D.change_count(diff).should eq(2)
      kinds(diff).should eq([DK::Same, DK::Del, DK::Add, DK::Same, DK::Same])
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end

    it "handles a line repeated many times with an interior change" do
      dup = "😀 반복되는 줄"
      a = Array.new(20) { dup }
      b = Array.new(20) { dup }
      b[10] = "🚀 changed"
      diff = D.lines(a, b)
      # exactly one Del + one Add for the single altered occurrence
      D.change_count(diff).should eq(2)
      diff.count { |d| d.kind == DK::Del }.should eq(1)
      diff.count { |d| d.kind == DK::Add }.should eq(1)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end

    it "reconstructs when many duplicate lines are inserted" do
      a = ["x"]
      b = Array.new(50) { "x" }
      diff = D.lines(a, b)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
      # 49 duplicate lines added
      D.change_count(diff).should eq(49)
    end

    it "treats combining-mark variants as distinct lines" do
      # precomposed e-acute (U+00E9) vs decomposed e + combining acute (U+0301)
      a = ["caf\u{00E9}"]
      b = ["cafe\u{0301}"]
      # sanity: these are genuinely different byte sequences
      a.first.should_not eq(b.first)
      diff = D.lines(a, b)
      # not byte-identical, so it is a change
      D.change_count(diff).should eq(2)
      rebuild_a(diff).should eq(a)
      rebuild_b(diff).should eq(b)
    end
  end

  describe "MAX_LINES = 1500 truncation" do
    it "exposes the documented cap constant" do
      Gori::Repeater::Diff::MAX_LINES.should eq(1500)
    end

    it "considers only the first 1500 lines of each side" do
      a = Array.new(1600) { |i| "L#{i}" }
      b = a
      diff = D.lines(a, b)
      # identical within the cap => all Same, one row per considered line
      diff.size.should eq(1500)
      kinds(diff).all? { |k| k == DK::Same }.should be_true
      D.change_count(diff).should eq(0)
      # lines at index 1500 and beyond never appear
      diff.any? { |d| d.text == "L1500" }.should be_false
      diff.any? { |d| d.text == "L1599" }.should be_false
      diff.last.text.should eq("L1499")
    end

    it "keeps all lines when each side has exactly 1500 (boundary)" do
      a = Array.new(1500) { |i| "n#{i}" }
      diff = D.lines(a, a)
      diff.size.should eq(1500)
      diff.last.text.should eq("n1499")
      D.change_count(diff).should eq(0)
    end

    it "drops the 1501st line (off-by-one over the cap)" do
      a = Array.new(1501) { |i| "n#{i}" }
      diff = D.lines(a, a)
      diff.size.should eq(1500)
      diff.last.text.should eq("n1499")
      diff.any? { |d| d.text == "n1500" }.should be_false
    end

    it "diffs only within the cap when the sole difference is past line 1500" do
      a = Array.new(1600) { |i| "c#{i}" }
      b = a.dup
      b[1550] = "MUTATED" # beyond the cap -> invisible to the diff
      diff = D.lines(a, b)
      diff.size.should eq(1500)
      D.change_count(diff).should eq(0)
      diff.any? { |d| d.text == "MUTATED" }.should be_false
    end

    it "completes quickly on large near-identical adversarial inputs" do
      # Two 1500-line bodies differing only in the middle: peeling keeps the
      # O(n*m) table tiny, so this must finish well under the timeout.
      a = Array.new(1500) { |i| "line-#{i}" }
      b = a.dup
      b[750] = "line-750-CHANGED"
      elapsed = Time.measure do
        diff = D.lines(a, b)
        D.change_count(diff).should eq(2)
      end
      elapsed.should be < 2.seconds
    end
  end

  describe "change_count" do
    it "counts only non-Same rows" do
      diff = [
        DLine.new(DK::Same, "s"),
        DLine.new(DK::Add, "a"),
        DLine.new(DK::Del, "d"),
        DLine.new(DK::Same, "s2"),
      ]
      D.change_count(diff).should eq(2)
    end

    it "is 0 for an empty diff" do
      D.change_count([] of DLine).should eq(0)
    end
  end
end
