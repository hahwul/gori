require "../../spec_helper"

# JsScan is pure (no Store/Scope), so this needs no flow harness — it drives the lexers and
# the source↔sink correlator directly. Everything here is deterministic: the two properties
# being pinned are "does not crash" and "offsets stay aligned", never a timing.

private alias JsScan = Gori::Probe::Passive::JsScan

# Nesting deeper than MAX_INTERP_DEPTH, UNTERMINATED so no closing delimiters are needed —
# the recursion happens on the way in, which is what made 3 bytes per level enough to blow
# an 8 MiB fiber stack from a single 256 KiB response body.
private def deep_unterminated(levels : Int32) : String
  "x=" + ("`${" * levels)
end

private def deep_terminated(levels : Int32) : String
  "x=" + ("`${" * levels) + "1" + ("}`" * levels) + ";"
end

describe Gori::Probe::Passive::JsScan do
  describe "template-literal nesting depth guard" do
    # Regression: `x=` + "`${" * 87381 (what CLIENT_BODY_CAP / 3 allows) recursed one frame per
    # level and killed the PROCESS — a Crystal stack overflow is a fatal signal, so the
    # Analyzer's per-flow `rescue` could not contain it. Well past both the cap and the old
    # ~87k-frame limit here, so it fails loudly if the guard is ever removed.
    it "survives nesting far deeper than a response body could carry" do
      src = deep_unterminated(200_000)
      JsScan.strip(src).should_not be_empty
      JsScan.strip_comments(src).should_not be_empty
    end

    it "survives deep TERMINATED nesting too (the copy_/emit_ interpolation pair)" do
      src = deep_terminated(100_000)
      JsScan.strip(src).should_not be_empty
      JsScan.strip_comments(src).should_not be_empty
    end

    # The guard blanks the rest of the fragment rather than declining to descend in place, so
    # the one-char-in-one-char-out invariant the whole file rests on must still hold. This is
    # what keeps source_in_window's window arithmetic meaningful.
    it "preserves offsets when the guard trips" do
      {deep_unterminated(200_000), deep_terminated(100_000)}.each do |src|
        JsScan.strip(src).size.should eq(src.size)
        JsScan.strip_comments(src).size.should eq(src.size)
      end
    end

    # Nesting a real bundle actually uses must keep working — the guard must not blank code
    # that sits under the cap.
    it "still correlates a source through ordinary shallow interpolation" do
      code = JsScan.strip(%(o.innerHTML = `hello ${location.hash} there`;))
      JsScan.source_sink_pairs(code).should eq([{"location.hash", "innerHTML"}])
    end

    it "still correlates a source nested a few interpolations deep" do
      code = JsScan.strip(%(o.innerHTML = `a${`b${location.hash}c`}d`;))
      JsScan.source_sink_pairs(code).should eq([{"location.hash", "innerHTML"}])
    end
  end

  # source_in_window works on BYTE offsets: char-index slicing was O(1) only while the script
  # stayed all-ASCII, and one non-ASCII byte turned every window slice into a walk from the
  # start of the string (measured 9ms -> 1765ms per flow). The pairs must be identical either
  # way — that equivalence is what the byte-offset rewrite had to preserve, and it is the part
  # a spec can pin. The COST is guarded by bench/probe_passive_bench.cr's JS fixture.
  describe "source↔sink correlation is independent of encoding" do
    it "finds the same pair with and without a non-ASCII regex literal in scope" do
      ascii = JsScan.strip(%(var r=/[abc]/g; o.innerHTML=location.hash;))
      utf8 = JsScan.strip(%(var r=/[éèê]/g; o.innerHTML=location.hash;))
      utf8.ascii_only?.should be_false # the literal survives `strip` by design
      utf8_pairs = JsScan.source_sink_pairs(utf8)
      utf8_pairs.should eq(JsScan.source_sink_pairs(ascii))
      utf8_pairs.should eq([{"location.hash", "innerHTML"}])
    end

    it "keeps the statement boundary exact when a multi-byte char sits in the window" do
      # The `;` before the sink ends the previous statement, so the source on its far side must
      # NOT be picked up — a byte scan that mis-handled a multi-byte char would over-reach.
      code = JsScan.strip(%(var s=location.hash; var t=/[가-힣]/; o.innerHTML=safe;))
      JsScan.source_sink_pairs(code).should be_empty
    end

    it "correlates across a multi-byte char inside the same statement" do
      code = JsScan.strip(%(o.innerHTML=/[가-힣]/.test(x)?location.hash:y;))
      JsScan.source_sink_pairs(code).should eq([{"location.hash", "innerHTML"}])
    end
  end
end
