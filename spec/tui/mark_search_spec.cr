require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Draw `text` as the base line at (x, y) exactly as a view would before the
# search overlay runs, then apply the overlay — mirrors the real call order so
# the yellow band lands on cells the base draw actually painted.
#
# The subject is `Wrap.mark_search` over ONE unwrapped row (`[0, size)`, no conceal, no
# h-scroll), which is the shape the retired `SearchHi.mark` had and the shape every pane
# still draws when soft wrap is off. `wrap_spec` covers what only the row form can express
# — a match straddling a break, and a hit's column within a continuation row.
private def base_and_mark(text : String, query : String, max_x : Int32, x = 0, w = 40) : MemoryBackend
  backend = MemoryBackend.new(w, 1)
  screen = Screen.new(backend)
  screen.text(x, 0, text, Theme.text)
  Wrap.mark_search(screen, x, 0, text, 0, text.size, query, max_x)
  backend
end

# Overlay-only: no base draw, so untouched cells keep Color.default. Lets a
# "nothing was painted" assertion distinguish a highlighted cell from a bare one.
private def mark_only(text : String, query : String, max_x : Int32, x = 0, w = 40,
                      conceal : Array({Int32, Int32})? = nil, xoff = 0) : MemoryBackend
  backend = MemoryBackend.new(w, 1)
  Wrap.mark_search(Screen.new(backend), x, 0, text, 0, text.size, query, max_x, conceal, xoff)
  backend
end

# The RETIRED mark loop, kept as the oracle for the rewrite (see the equivalence describe at
# the bottom of the file): `String#index` on character offsets, `Wrap.row_col` re-measured
# from the row start for every match, and a character-index slice for the segment. Every
# line below is the body this file's subject replaced, reaching `row_col` / `slice_left_text`
# from outside the module and carrying its own copy of the private `strip_hidden`.
private def reference_mark(screen : Screen, x : Int32, y : Int32, line : String,
                           a : Int32, b : Int32, query : String, max_x : Int32,
                           conceal : Array({Int32, Int32})? = nil, xoff : Int32 = 0,
                           lower : String? = nil) : Nil
  return if query.empty? || line.empty? || a >= b
  q = query.downcase
  dl = lower || line.downcase
  same = dl.size == line.size
  src = same ? line : dl
  lo, hi = a, b
  unless same
    return unless a <= 0 && b >= line.size
    lo, hi = 0, dl.size
  end
  pos = 0
  while i = dl.index(q, pos)
    pos = i + q.size
    ma = {i, lo}.max
    mb = {pos, hi}.min
    next if ma >= mb
    col = x + Wrap.row_col(src, conceal, lo, ma) - xoff
    seg = src[ma...mb]
    seg = reference_strip_hidden(seg, conceal, ma) if conceal && !conceal.empty?
    if col < x
      seg = Highlight.slice_left_text(seg, x - col)
      col = x
    end
    screen.text(col, y, seg, Theme.bg, Theme.yellow, width: {max_x - col, 0}.max) if col < max_x && !seg.empty?
  end
end

private def reference_strip_hidden(seg : String, conceal : Array({Int32, Int32}), off : Int32) : String
  String.build do |io|
    seg.each_char_with_index do |c, k|
      io << c unless conceal.any? { |(ra, rb)| off + k >= ra && off + k < rb }
    end
  end
end

# The columns [from, to) whose background is the search-match yellow.
private def yellow_cols(b : MemoryBackend, w = 40) : Array(Int32)
  (0...w).select { |x| b.bg_at(x, 0) == Theme.yellow }
end

describe "Gori::Tui::Wrap.mark_search (single unwrapped row)" do
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
      Wrap.mark_search(Screen.new(backend), 0, 0, text, 0, text.size, "ab", 8)
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
      Wrap.mark_search(Screen.new(backend), 0, 0, text, 0, text.size, "zzz", 10)
      ((Time.instant - t0).total_milliseconds).should be < 5_000.0
      yellow_cols(backend, 10).should be_empty
    end

    # The GROWTH RATE those two bound is asserted in `bench/mark_search_bench.cr`, not here:
    # a big-O claim can only be shown by timing, and a wall-clock threshold in CI either
    # flakes on a loaded box or is so generous it catches nothing. The bench charts µs per
    # match at 1k → 16k matches, which must stay flat; it used to quadruple per doubling
    # (`String#index` re-walked the prefix from byte 0 per match, `row_col` re-walked from
    # the row start, and a char-index slice re-walked from byte 0 again). The ceilings above
    # are the CI-safe half of that: they only catch a hang.
    it "stays correct on a dense line marked for a row in the MIDDLE of it" do
      # The wrapped shape of the same input: every match before the row is still scanned (it
      # has to be — the non-overlapping match phase is set from char 0), but only the ones
      # touching [a, b) may paint, and they must paint at their column WITHIN the row.
      text = "ab" * 4_000
      a = 1_000
      backend = MemoryBackend.new(10, 1)
      Wrap.mark_search(Screen.new(backend), 0, 0, text, a, a + 10, "ab", 8)
      yellow_cols(backend, 10).should eq([0, 1, 2, 3, 4, 5, 6, 7])
    end

    it "survives a line of invalid UTF-8 bytes (P7: the operator's octets are the payload)" do
      # A captured body is arbitrary octets. `downcase` folds an invalid byte to U+FFFD, so
      # the scan's haystack and the drawn line disagree about bytes while agreeing about
      # characters — exactly the case the byte cursors have to keep straight.
      raw = String.new(Bytes[0x61, 0xFF, 0x62, 0x4E, 0x45, 0x45, 0x44, 0x4C, 0x45, 0x80])
      backend = MemoryBackend.new(20, 1)
      screen = Screen.new(backend)
      screen.text(0, 0, raw, Theme.text)
      Wrap.mark_search(screen, 0, 0, raw, 0, raw.size, "needle", 20)
      yellow_cols(backend, 20).empty?.should be_false # it found the match and painted SOMETHING
    end

    it "does not paint past a conceal run that swallows the whole line" do
      line = "needle"
      b = mark_only(line, "needle", 40, conceal: [{0, line.size}])
      yellow_cols(b).should be_empty
    end

    it "drops a match scrolled entirely off the left edge (xoff past its end)" do
      b = mark_only("needle" + "." * 30, "needle", 40, xoff: 20)
      yellow_cols(b).should be_empty
    end
  end

  # --- equivalence with the retired algorithm -------------------------------
  # The rewrite changed only HOW three things are computed — the match scan (`String#index`
  # on CHARACTER offsets → `String#byte_index`), the column (`Wrap.row_col` re-measured from
  # the row start per match → a forward-only cursor) and the segment slice (a char-index
  # slice → a byte slice) — never WHAT they answer. `reference_mark` is the retired shape,
  # kept here as the oracle for that claim, and the corpus is the shapes the three cursors
  # can disagree on: a non-ASCII haystack, a downcase that changes bytesize without changing
  # length, a match starting INSIDE a grapheme cluster, concealed runs, h-scroll, and the
  # right clip the new early exit rests on.
  describe "matches the retired per-match-rewalk algorithm cell for cell" do
    zwj = "\u{1F468}\u{200D}\u{1F4BB}" # 👨‍💻 : 3 codepoints, 2 columns

    # {name, line, query, a, b, x, max_x, conceal, xoff}
    cases = [
      {"plain ASCII", "a FOObar", "foo", nil, nil, 0, 40, nil, 0},
      {"dense ASCII", "ab" * 12, "ab", nil, nil, 0, 40, nil, 0},
      {"dense ASCII, tight clip", "ab" * 12, "ab", nil, nil, 0, 5, nil, 0},
      {"dense ASCII, clip mid-match", "ab" * 12, "ab", nil, nil, 0, 7, nil, 0},
      {"dense ASCII, clip at 0", "ab" * 12, "ab", nil, nil, 0, 0, nil, 0},
      {"dense ASCII, x offset", "ab" * 12, "ab", nil, nil, 6, 40, nil, 0},
      {"dense ASCII, h-scrolled", "ab" * 12, "ab", nil, nil, 0, 40, nil, 7},
      {"dense ASCII, h-scroll + x", "ab" * 12, "ab", nil, nil, 4, 30, nil, 9},
      {"wrapped row, whole match inside", "aaaaNEEDLEaaaa", "needle", 7, 14, 0, 40, nil, 0},
      {"wrapped row, match straddles head", "aaaaNEEDLEaaaa", "needle", 0, 7, 0, 40, nil, 0},
      {"wrapped row of a dense line", "ab" * 40, "ab", 20, 40, 0, 40, nil, 0},
      {"wrapped row, odd start", "ab" * 40, "ab", 21, 41, 0, 40, nil, 0},
      {"CJK prefix", "世界foo世界foo", "foo", nil, nil, 0, 40, nil, 0},
      {"CJK haystack, dense", "世界" * 10, "世", nil, nil, 0, 40, nil, 0},
      {"CJK, wrapped row", "世界" * 10, "界", 6, 14, 0, 40, nil, 0},
      {"ZWJ cluster prefix", zwj + "needle" + zwj + "needle", "needle", nil, nil, 0, 40, nil, 0},
      {"combining mark, match mid-cluster", "e\u0301x e\u0301x", "\u0301", nil, nil, 0, 40, nil, 0},
      {"NFD Hangul", "\u1112\u1161\u11AB\u1100\u1173\u11AFneedle", "needle", nil, nil, 0, 40, nil, 0},
      {"tab before the match", "a\tneedle\tneedle", "needle", nil, nil, 0, 40, nil, 0},
      {"U+0130 (downcase grows)", "İ foo İ foo", "foo", nil, nil, 0, 40, nil, 0},
      {"U+212A (downcase shrinks bytes only)", "aK bK", "k", nil, nil, 0, 40, nil, 0},
      {"U+212A, wrapped row", "aK bK cK", "k", 3, 8, 0, 40, nil, 0},
      {"ſ long s (folds into ASCII)", "aſb aſb", "ſ", nil, nil, 0, 40, nil, 0},
      {"conceal before the match", "a¦hid§needle", "needle", nil, nil, 0, 40, [{1, 6}], 0},
      {"conceal inside the match", "needle", "needle", nil, nil, 0, 40, [{2, 4}], 0},
      {"conceal at the row start", "¦hid§needle", "needle", nil, nil, 0, 40, [{0, 5}], 0},
      {"two conceal runs", "a¦h§b¦h§needle", "needle", nil, nil, 0, 40, [{1, 4}, {5, 8}], 0},
      {"conceal + h-scroll", "a¦hid§needleneedle", "needle", nil, nil, 0, 40, [{1, 6}], 4},
      {"conceal, ASCII line", "aXXXbneedle", "needle", nil, nil, 0, 40, [{1, 4}], 0},
      {"no match", "hello world", "zzz", nil, nil, 0, 40, nil, 0},
      {"query longer than the line", "hi", "hiya", nil, nil, 0, 40, nil, 0},
      {"adjacent matches", "aaaa", "aa", nil, nil, 0, 40, nil, 0},
      {"single-char query, whole run", "aaaa", "a", nil, nil, 0, 40, nil, 0},
      # `x` at or past the clip: nothing can be drawn, and the new early exit takes it on
      # the first match rather than after walking the line.
      {"x at the clip", "ab" * 12, "ab", nil, nil, 4, 4, nil, 0},
      {"x past the clip", "ab" * 12, "ab", nil, nil, 8, 4, nil, 0},
      {"h-scroll past the whole line", "needle" + "." * 20, "needle", nil, nil, 0, 40, nil, 60},
      # The TextArea shape: soft wrap AND a concealed ¦chain run on the same line.
      {"conceal on a wrapped row", "a¦hid§needleneedleneedle", "needle", 0, 12, 0, 40, [{1, 6}], 0},
      {"conceal on a later wrapped row", "a¦hid§needleneedleneedle", "needle", 12, 24, 0, 40, [{1, 6}], 0},
      {"wide cluster at the row start", "世needle世needle", "needle", 1, 8, 0, 40, nil, 0},
    ]

    cases.each do |(name, line, query, a, b, x, max_x, conceal, xoff)|
      it "agrees on #{name}" do
        a0 = a || 0
        b0 = b || line.size
        got = MemoryBackend.new(48, 1)
        want = MemoryBackend.new(48, 1)
        [got, want].each { |bk| Screen.new(bk).text(x, 0, line[a0...b0], Theme.text) }
        Wrap.mark_search(Screen.new(got), x, 0, line, a0, b0, query, max_x, conceal, xoff)
        reference_mark(Screen.new(want), x, 0, line, a0, b0, query, max_x, conceal, xoff)
        got.bg_grid.should eq(want.bg_grid)
        got.fg_grid.should eq(want.fg_grid)
        got.cluster_grid.should eq(want.cluster_grid)
        got.cont_grid.should eq(want.cont_grid)
      end
    end

    it "agrees when the caller hoists `lower` beside the line" do
      # `read_pane` hands in `line.downcase` so a wrapped line is not downcased once per
      # drawn row; the scan must be the same either way.
      line = "AB" * 20
      got = MemoryBackend.new(48, 1)
      want = MemoryBackend.new(48, 1)
      Wrap.mark_search(Screen.new(got), 0, 0, line, 0, line.size, "ab", 40, lower: line.downcase)
      reference_mark(Screen.new(want), 0, 0, line, 0, line.size, "ab", 40)
      got.bg_grid.should eq(want.bg_grid)
      got.cluster_grid.should eq(want.cluster_grid)
    end
  end
end
