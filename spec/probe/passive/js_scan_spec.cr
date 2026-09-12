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

  # `strip` and `strip_comments` are two VIEWS of one walk (`strip_both`): the lexer consumes a
  # script exactly once and emits the strings-blanked projection into one builder and the
  # comments-only projection into the other. So the property to pin is that the fused walk still
  # produces what two separate walks produced — a token consumed on one side but not the other
  # would desync the two views' offsets, and DOM-XSS's window arithmetic is measured against
  # those offsets.
  describe ".strip_both" do
    # Every token kind in one fragment: a line comment, a block comment, an escaped quote, a URL
    # literal whose `//` must NOT read as a comment, and a template with a nested interpolation.
    fragment = %(a = "x//y"; /* c */ b = 'it\\'s'; t = `p ${loc + "q"} s`; // tail\nz = 1;)

    it "blanks string contents on one side and keeps them on the other" do
      code, kept = JsScan.strip_both(fragment)
      # The strings-blanked view: delimiters kept, contents gone, `${…}` still readable as code.
      code.includes?("x//y").should be_false
      code.includes?("loc + ").should be_true
      # The comments-only view: string contents survive, comments do not.
      kept.includes?("x//y").should be_true
      kept.includes?("/* c */").should be_false
      kept.includes?("// tail").should be_false
      # Both are offset-preserving, which is the whole contract.
      code.size.should eq(fragment.size)
      kept.size.should eq(fragment.size)
    end

    it "returns exactly what the two separate entry points return" do
      JsScan.strip_both(fragment).should eq({JsScan.strip(fragment), JsScan.strip_comments(fragment)})
    end

    it "agrees with the separate entry points over randomised token soup" do
      # Bare delimiters, escapes and interpolation openers in every order — the shapes that
      # expose a desync, which hand-written samples reliably miss.
      alphabet = ['a', '/', '*', '\'', '"', '`', '$', '{', '}', '\\', '\n', ';', 'é']
      rng = Random.new(20_260_912)
      2_000.times do
        src = String.build { |io| (rng.rand(1..40)).times { io << alphabet[rng.rand(alphabet.size)] } }
        JsScan.strip_both(src).should eq({JsScan.strip(src), JsScan.strip_comments(src)})
      end
    end

    it "handles an empty script without lexing it" do
      JsScan.strip_both("").should eq({"", ""})
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
