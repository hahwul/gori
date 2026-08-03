require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Every row of `line` under `width`, as text — the projection the render loop draws.
private def rows_of(line : String, width : Int32, conceal = nil) : Array(String)
  lay = Wrap.layout(line, width, conceal)
  (0...lay.rows).map { |r| line[lay.start_of(r)...lay.end_of(r)] }
end

describe Gori::Tui::Wrap do
  describe "layout" do
    it "keeps a line that fits on a single row" do
      lay = Wrap.layout("GET /x HTTP/1.1", 40)
      lay.rows.should eq(1)
      lay.start_of(0).should eq(0)
      lay.end_of(0).should eq(15)
    end

    # An empty line still occupies one row: it is where the caret goes, and every mapping
    # below (row_of, start_of) assumes row 0 exists.
    it "gives an empty line one row" do
      lay = Wrap.layout("", 40)
      lay.rows.should eq(1)
      lay.start_of(0).should eq(0)
      lay.end_of(0).should eq(0)
    end

    it "breaks an ASCII line every `width` columns and loses nothing" do
      line = ("abcdefghij" * 5) # 50 chars
      rows_of(line, 12).should eq(["abcdefghijab", "cdefghijabcd", "efghijabcdef", "ghijabcdefgh", "ij"])
      rows_of(line, 12).join.should eq(line)
    end

    # The rows must always concatenate back to the source, at every width — a wrap that
    # drops or duplicates a character corrupts every offset downstream of it (caret,
    # click, selection, search).
    it "is a lossless partition at every width" do
      line = "a\t한글x#{"\u{1F44D}\u{1F3FD}"}e\u{0301},{\"k\":\"v\"}"
      (1..24).each do |w|
        rows_of(line, w).join.should eq(line) # (width #{w})
      end
    end

    it "never returns a start inside a grapheme cluster" do
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
      line = "ab#{family}cd#{family}ef"
      starts = [] of Int32
      i = 0
      line.each_grapheme { |g| starts << i; i += g.size }
      starts << line.size
      (1..20).each do |w|
        lay = Wrap.layout(line, w)
        (0...lay.rows).each { |r| starts.should contain(lay.start_of(r)) } # (width #{w})
      end
    end

    # The requirement that motivates measuring in DISPLAY COLUMNS rather than String#size:
    # a wide CJK glyph is two cells, so an odd width must push it whole to the next row
    # rather than leave half of it hanging over the edge.
    it "never lets a wide CJK glyph straddle the break" do
      line = "한글날abc"
      # width 5 fits 두 glyphs (4 cols); the third would need cols 5-6.
      rows_of(line, 5).should eq(["한글", "날abc"])
      (2..10).each do |w|
        lay = Wrap.layout(line, w)
        (0...lay.rows).each do |r|
          seg = line[lay.start_of(r)...lay.end_of(r)]
          # Either the row fits, or it holds exactly one cluster too wide for any row.
          (Screen.draw_width(seg) <= w || seg.each_grapheme.size == 1).should be_true # (w #{w} row #{r})
        end
      end
    end

    it "gives a cluster wider than the whole row a row of its own rather than splitting it" do
      rows_of("한글", 1).should eq(["한", "글"])
    end

    it "maps a char index back to the row that starts it" do
      lay = Wrap.layout("0123456789", 4)
      lay.rows.should eq(3)
      lay.row_of(0).should eq(0)
      lay.row_of(3).should eq(0)
      lay.row_of(4).should eq(1) # a break offset belongs to the row it STARTS
      lay.row_of(7).should eq(1)
      lay.row_of(8).should eq(2)
      lay.row_of(10).should eq(2) # end-of-line terminates the last row
    end

    it "round-trips row_of against start_of/end_of at every index, ASCII and not" do
      ["0123456789abcdefghij", "한글날abc한글날abc", "a\tb\u{0301}c한d"].each do |line|
        (1..9).each do |w|
          lay = Wrap.layout(line, w)
          (0..line.size).each do |cx|
            r = lay.row_of(cx)
            (lay.start_of(r) <= cx).should be_true                   # (#{line.inspect} w#{w} cx#{cx})
            (cx <= lay.end_of(r)).should be_true                     # (#{line.inspect} w#{w} cx#{cx})
            (r == lay.rows - 1 || cx < lay.end_of(r)).should be_true # (#{line.inspect} w#{w} cx#{cx})
          end
        end
      end
    end

    # Concealed chars (the hidden `¦chain` of a §…§ marker) draw no cells, so they must
    # buy no width: counting them shortens every row on the marked line by the chain's
    # length and the break lands left of the pane edge.
    it "gives concealed chars no width" do
      line = "§v¦chain§tail"
      conceal = [{3, 8}] # the "chain" run
      rows_of(line, 20, conceal).size.should eq(1)
      Wrap.layout(line, 20, conceal).rows.should eq(1)
      # Without the conceal the same line is 13 drawn columns and needs two rows at 8.
      Wrap.layout(line, 8).rows.should eq(2)
      Wrap.layout(line, 8, conceal).rows.should eq(1) # 8 visible columns exactly
    end
  end

  describe "row_col / row_index" do
    it "are exact inverses at every cluster boundary within a row" do
      line = "a\t한#{"\u{1F44D}\u{1F3FD}"}e\u{0301}z글"
      lay = Wrap.layout(line, 6)
      (0...lay.rows).each do |r|
        a = lay.start_of(r)
        b = lay.end_of(r)
        i = a
        while i <= b
          col = Wrap.row_col(line, nil, a, i)
          Wrap.row_index(line, nil, a, b, col).should eq(i) # (row #{r} idx #{i})
          i = i >= b ? b + 1 : Screen.cluster_end(line, i + 1)
        end
      end
    end

    it "clamps a click past the end of a wrapped row to the break, not into the next row" do
      line = "0123456789"
      lay = Wrap.layout(line, 4)
      a, b = lay.start_of(1), lay.end_of(1)
      Wrap.row_index(line, nil, a, b, 99).should eq(b)
      Wrap.row_index(line, nil, a, b, 0).should eq(a)
      Wrap.row_index(line, nil, a, b, 2).should eq(a + 2)
    end
  end

  describe "mark_search" do
    # A match straddling a wrap break used to be highlighted on NEITHER row when each row
    # was scanned in isolation (its head is an incomplete match, so is its tail). Both
    # halves must light up.
    it "highlights both halves of a match that crosses the break" do
      line = "aaaaNEEDLEaaaa"
      lay = Wrap.layout(line, 7) # break falls inside "NEEDLE" (cols 0-6 = "aaaaNEE")
      b = MemoryBackend.new(20, 2)
      s = Screen.new(b)
      (0...lay.rows).each do |r|
        a0, b0 = lay.start_of(r), lay.end_of(r)
        s.text(0, r, line[a0...b0], Theme.text)
        Wrap.mark_search(s, 0, r, line, a0, b0, "needle", 20)
      end
      # "NEE" on row 0 (cols 4-6), "DLE" on row 1 (cols 0-2), all yellow.
      (4..6).each { |x| b.bg_grid[0][x].should eq(Theme.yellow) }
      (0..2).each { |x| b.bg_grid[1][x].should eq(Theme.yellow) }
      b.bg_grid[0][3].should_not eq(Theme.yellow)
      b.bg_grid[1][3].should_not eq(Theme.yellow)
    end

    it "places a within-row match at the drawn column, not the char index" do
      line = "한글NEEDLE"
      b = MemoryBackend.new(20, 1)
      s = Screen.new(b)
      s.text(0, 0, line, Theme.text)
      Wrap.mark_search(s, 0, 0, line, 0, line.size, "needle", 20)
      b.bg_grid[0][3].should_not eq(Theme.yellow) # still the second CJK glyph's cells
      (4..9).each { |x| b.bg_grid[0][x].should eq(Theme.yellow) }
    end
  end
end
