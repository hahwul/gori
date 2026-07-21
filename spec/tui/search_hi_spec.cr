require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Draw `text` as the base line at (x, y) exactly as a view would before the
# search overlay runs, then apply the overlay — mirrors the real call order so
# the yellow band lands on cells the base draw actually painted.
private def base_and_mark(text : String, query : String, max_x : Int32, x = 0, w = 40) : MemoryBackend
  backend = MemoryBackend.new(w, 1)
  screen = Screen.new(backend)
  screen.text(x, 0, text, Theme.text)
  SearchHi.mark(screen, x, 0, text, query, max_x)
  backend
end

# Overlay-only: no base draw, so untouched cells keep Color.default. Lets a
# "nothing was painted" assertion distinguish a highlighted cell from a bare one.
private def mark_only(text : String, query : String, max_x : Int32, x = 0, w = 40) : MemoryBackend
  backend = MemoryBackend.new(w, 1)
  SearchHi.mark(Screen.new(backend), x, 0, text, query, max_x)
  backend
end

# The columns [from, to) whose background is the search-match yellow.
private def yellow_cols(b : MemoryBackend, w = 40) : Array(Int32)
  (0...w).select { |x| b.bg_at(x, 0) == Theme.yellow }
end

describe Gori::Tui::SearchHi do
  describe "early return (empty query or empty text)" do
    it "paints nothing when the query is empty (bg stays default across the row)" do
      b = mark_only("a FOObar", "", 40)
      (0...40).each { |x| b.bg_at(x, 0).should eq(Gori::Tui::Color.default) }
    end

    it "paints nothing when the text is empty (bg stays default across the row)" do
      b = mark_only("", "foo", 40)
      (0...40).each { |x| b.bg_at(x, 0).should eq(Gori::Tui::Color.default) }
    end

    it "paints nothing when BOTH are empty" do
      b = mark_only("", "", 40)
      yellow_cols(b).should be_empty
    end
  end

  describe "a single case-insensitive match" do
    it "paints exactly q.size cells at the right column (\"foo\" in \"a FOObar\")" do
      b = base_and_mark("a FOObar", "foo", 40)
      # "FOO" sits at char/col 2..4; the overlay lowercases the query but positions
      # against the ORIGINAL cells, so cols 2,3,4 get the yellow band.
      yellow_cols(b).should eq([2, 3, 4])
      b.bg_at(1, 0).should_not eq(Theme.yellow) # the space before is untouched
      b.bg_at(5, 0).should_not eq(Theme.yellow) # "bar" after is untouched
    end

    it "matches regardless of the query's own case (\"FOO\" query, \"foo\" text)" do
      b = base_and_mark("x foobar", "FOO", 40)
      yellow_cols(b).should eq([2, 3, 4])
    end

    it "honours the content-x offset x (band = x + column)" do
      b = base_and_mark("a FOObar", "foo", 40, x: 5)
      yellow_cols(b).should eq([7, 8, 9])
    end

    it "paints nothing when the query does not occur" do
      b = base_and_mark("a FOObar", "zzz", 40)
      yellow_cols(b).should be_empty
    end

    it "paints nothing when the query is longer than the text" do
      b = base_and_mark("hi", "hiya", 40)
      yellow_cols(b).should be_empty
    end
  end

  describe "multiple occurrences (guards the O(line) accumulator)" do
    it "highlights every occurrence with column-correct offsets (\"ab\" in \"ab ab ab\")" do
      b = base_and_mark("ab ab ab", "ab", 40)
      yellow_cols(b).should eq([0, 1, 3, 4, 6, 7])
      # the single-space gaps stay unpainted
      b.bg_at(2, 0).should_not eq(Theme.yellow)
      b.bg_at(5, 0).should_not eq(Theme.yellow)
    end

    it "keeps offsets correct when gaps between matches vary in width" do
      # "a" then a 5-space gap then "a" — the accumulator must measure only the gap
      # since the previous match, not re-walk from column 0.
      b = base_and_mark("a     a", "a", 40)
      yellow_cols(b).should eq([0, 6])
    end
  end

  describe "column correctness after a wide (CJK / width-2) prefix" do
    it "lands at x + draw_width(prefix), not the character count (\"世界\" prefix)" do
      # "世界" is two width-2 glyphs ⇒ 4 drawn columns, so "foo" is drawn at cols 4,5,6.
      # A char-count column would have put the band at col 2, over the CJK glyphs.
      b = base_and_mark("世界foo", "foo", 40)
      yellow_cols(b).should eq([4, 5, 6])
      b.bg_at(0, 0).should_not eq(Theme.yellow) # 世
      b.bg_at(2, 0).should_not eq(Theme.yellow) # 界
      # confirm the base draw really placed the CJK glyphs at cols 0 and 2 (col 1 is
      # the wide-glyph continuation), so the col-4 band is genuinely past the prefix.
      b.cluster_grid[0][0].should eq("世")
      b.cluster_grid[0][2].should eq("界")
    end

    it "lands correctly after a ZWJ emoji cluster (the #285 off-by-N bug)" do
      zwj = "\u{1F468}\u{200D}\u{1F4BB}" # 👨‍💻 : 3 codepoints, 2 drawn columns
      b = base_and_mark(zwj + "needle", "needle", 40)
      # The cluster occupies cols 0-1, so "needle" is at cols 2..7 — under column_width
      # (per-codepoint) the band drifted to col 5, painting over unrelated glyphs.
      yellow_cols(b).should eq([2, 3, 4, 5, 6, 7])
      b.bg_at(1, 0).should_not eq(Theme.yellow) # the emoji stays uncoloured
      b.bg_at(8, 0).should_not eq(Theme.yellow) # nothing past the match
    end

    it "lands correctly after a tab (issue #278, ASCII grapheme path)" do
      # A tab is one drawn column, so "needle" begins at col 2.
      b = base_and_mark("a\tneedle", "needle", 40)
      yellow_cols(b).should eq([2, 3, 4, 5, 6, 7])
    end
  end

  describe "U+0130 length-change fallback (dt.size != text.size)" do
    it "does not crash and keeps the column right when downcase expands a glyph" do
      # 'İ' (U+0130) lowercases to "i" + U+0307 (2 codepoints), so the downcased copy
      # is longer than the source; the code falls back to slicing the downcased string.
      text = "İ foo"
      (text.downcase.size != text.size).should be_true # branch is actually live
      b = base_and_mark(text, "foo", 40)
      # 'İ' draws in one column, space in one, so "foo" is at cols 2,3,4 regardless.
      yellow_cols(b).should eq([2, 3, 4])
    end
  end

  describe "clipping at max_x (exclusive)" do
    it "does not paint a match whose start column is at or past max_x" do
      # "foo" would start at col 2; max_x == 2 makes col < max_x false.
      b = base_and_mark("xxfoo", "foo", 2)
      yellow_cols(b).should be_empty
    end

    it "paints only max(max_x - col, 0) cells for a match straddling max_x" do
      # "cdef" starts at col 2; max_x == 4 ⇒ a 2-cell band (cols 2,3). Screen#text
      # renders "c…" there, but the yellow BAND width is what the clamp guarantees.
      b = base_and_mark("abcdef", "cdef", 4)
      yellow_cols(b).should eq([2, 3])
      b.bg_at(4, 0).should_not eq(Theme.yellow)
      b.bg_at(5, 0).should_not eq(Theme.yellow)
    end

    it "paints the whole match when max_x sits exactly at its end (boundary)" do
      # "cdef" occupies cols 2..5; max_x == 6 is exclusive but one past the last cell.
      b = base_and_mark("abcdef", "cdef", 6)
      yellow_cols(b).should eq([2, 3, 4, 5])
    end
  end

  describe "match at position 0 and back-to-back matches" do
    it "highlights a match that starts at column 0" do
      b = base_and_mark("foobar", "foo", 40)
      yellow_cols(b).should eq([0, 1, 2])
    end

    it "advances past adjacent matches without double-paint or an infinite loop (\"aa\" in \"aaaa\")" do
      # Non-overlapping matches at 0 and 2 cover all four cells exactly once; pos jumps
      # by q.size each time so the loop terminates.
      b = base_and_mark("aaaa", "aa", 40)
      yellow_cols(b).should eq([0, 1, 2, 3])
    end

    it "handles a single-character query filling the whole run" do
      b = base_and_mark("aaaa", "a", 40)
      yellow_cols(b).should eq([0, 1, 2, 3])
    end
  end

  describe "adversarial scale (String#index, no regex → no ReDoS)" do
    it "walks a token-dense line with thousands of matches without hanging" do
      # "abab…ab" — every 2 columns is a fresh match. Painting is clipped by a tiny
      # max_x, but the match loop still scans the whole string; it must terminate and
      # stay correct. (A generous bound: this size runs in tens of ms.)
      text = "ab" * 2_000
      backend = MemoryBackend.new(10, 1)
      t0 = Time.instant
      SearchHi.mark(Screen.new(backend), 0, 0, text, "ab", 8)
      # Generous ceiling: normal runs are tens of ms; only a quadratic/hang regression
      # (which would take many seconds) trips it, so a slow CI box can't flake this.
      ((Time.instant - t0).total_milliseconds).should be < 5_000.0
      # Only the first 8 columns are inside max_x, so exactly cols 0..7 are painted.
      yellow_cols(backend, 10).should eq([0, 1, 2, 3, 4, 5, 6, 7])
    end

    it "returns quickly when a long line contains no match (one index scan)" do
      text = "a" * 200_000
      backend = MemoryBackend.new(10, 1)
      t0 = Time.instant
      SearchHi.mark(Screen.new(backend), 0, 0, text, "zzz", 10)
      ((Time.instant - t0).total_milliseconds).should be < 5_000.0
      yellow_cols(backend, 10).should be_empty
    end

    # SUSPECTED BUG (reported as a finding, not an executable test — a big-O claim can only
    # be shown by timing, which is too flaky to assert in CI): the accumulator comment
    # (search_hi.cr:20-23) documents the mark loop as "O(line) total instead of ... O(line²)
    # on token-dense lines". But the loop's `dt.index(q, pos)` takes a CHARACTER offset, and
    # String#index converts it to a byte offset by walking `pos` characters each call — so on
    # a token-dense line the total is still O(line²) (measured: matches 1k→2k→4k→8k gave
    # 0.8→4→14→39 ms, quadrupling per doubling). The draw_width re-walk was removed but an
    # index re-walk remains, so the documented O(line) contract does not hold. Functionally
    # correct (highlighting stays column-correct — covered by the cases above); perf only.
  end
end
