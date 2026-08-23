require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# ^F over a READ-ONLY pane. `ReadPane` owns the band and the hit list so the panes built on it
# (Decoder OUTPUT, Fuzzer RESULT detail, and the ones that follow) cannot drift into separate
# spellings of the same find — the drift the class comment already records for the draw.
#
# The Repeater's response half answers the same two questions through its own `resp_line_source`
# ladder; these pin that the component agrees with it (case-insensitive substring, 0-based
# indices, empty for an empty query).
private def search_pane(lines : Array(String)) : ReadPane
  pane = ReadPane.new(gutter: true)
  pane.source(lines)
  pane
end

# One column wider than the rect — `Frame.scroll_gauge` rides the border column right of the
# content, exactly as in read_pane_spec.
private def render_pane(pane : ReadPane, w = 40, h = 6, focused = true) : MemoryBackend
  b = MemoryBackend.new(w + 1, h)
  pane.render(Screen.new(b), Rect.new(0, 0, w, h), focused)
  b
end

private def yellow_cols(b : MemoryBackend, y : Int32, w = 40) : Array(Int32)
  (0...w).select { |x| b.bg_at(x, y) == Theme.yellow }
end

describe "Gori::Tui::ReadPane ^F search" do
  describe "#search_lines" do
    it "answers 0-based indices of the matching lines" do
      pane = search_pane(["alpha", "beta token", "gamma", "TOKEN again"])
      pane.search_lines("token").should eq([1, 3])
    end

    it "matches case-insensitively, like every other ^F target" do
      pane = search_pane(["Bearer eyJhbG", "bearer x"])
      pane.search_lines("BEARER").should eq([0, 1])
      pane.search_lines("bearer").should eq([0, 1])
    end

    it "counts a line once however many times the query occurs on it" do
      # Line indices, not occurrences — the prompt's ↑/↓ steps LINES. (`search_match_count`
      # is the occurrence question, and only the editable targets answer it.)
      pane = search_pane(["a a a", "b"])
      pane.search_lines("a").should eq([0])
    end

    it "is empty for an empty query" do
      pane = search_pane(["anything"])
      pane.search_lines("").should be_empty
    end

    it "is empty on a pane with no text" do
      ReadPane.new.search_lines("x").should be_empty
    end

    it "reads through the provider, so a re-source re-answers" do
      pane = ReadPane.new
      pane.source(["old secret"])
      pane.search_lines("secret").should eq([0])
      pane.source(["nothing here", "new secret"])
      pane.search_lines("secret").should eq([1])
    end
  end

  describe "#goto_line" do
    # The shell's prompt is 1-based (it names what the gutter prints) and every VIEW-level
    # wrapper subtracts one before it gets here; the component itself indexes from 0.
    it "moves the caret to the 0-based line it is given" do
      pane = search_pane((0...20).map { |i| "line#{i}" })
      pane.goto_line(11)
      pane.cursor.cy.should eq(11)
    end

    it "clamps past the end instead of raising" do
      pane = search_pane(["one", "two"])
      pane.goto_line(99)
      pane.cursor.cy.should eq(1)
    end

    it "is inert on an empty pane" do
      pane = ReadPane.new
      pane.goto_line(3)
      pane.cursor.cy.should eq(0)
    end
  end

  describe "the band" do
    it "paints the match yellow and leaves the rest of the row alone" do
      pane = search_pane(["xx token yy"])
      pane.search_hl = "token"
      b = render_pane(pane)
      cols = yellow_cols(b, 0)
      cols.size.should eq(5) # exactly the query's width, not the whole line
      # Contiguous — one band, not a cell per matched char scattered by a second measure.
      cols.should eq((cols.first..cols.last).to_a)
    end

    it "paints nothing while the query is empty (the resting state of every pane)" do
      pane = search_pane(["xx token yy"])
      b = render_pane(pane)
      yellow_cols(b, 0).should be_empty
    end

    it "clears when the shell pushes \"\" back on close" do
      pane = search_pane(["xx token yy"])
      pane.search_hl = "token"
      yellow_cols(render_pane(pane), 0).should_not be_empty
      pane.search_hl = ""
      yellow_cols(render_pane(pane), 0).should be_empty
    end

    it "bands every visible row that matches, not just the caret's" do
      pane = search_pane(["hit one", "miss", "hit two"])
      pane.search_hl = "hit"
      b = render_pane(pane)
      yellow_cols(b, 0).should_not be_empty
      yellow_cols(b, 1).should be_empty
      yellow_cols(b, 2).should_not be_empty
    end

    # The band goes UNDER the caret on purpose: the ^F prompt jumps the caret INTO a match, and
    # a band drawn over it would hide where the cursor actually sits.
    it "leaves the caret cell showing the caret, not the band" do
      pane = search_pane(["token here"])
      pane.search_hl = "token"
      pane.goto_line(0)
      b = render_pane(pane, focused: true)
      caret = (0...40).select { |x| b.bg_at(x, 0) == Theme.accent_bg }
      caret.size.should eq(1)
      # "token" is 5 columns; the caret sits on the first of them, so the band shows 4 —
      # which is only true if the chrome is painted AFTER the band.
      yellow = yellow_cols(b, 0)
      yellow.size.should eq(4)
      yellow.first.should eq(caret.first + 1)
    end
  end
end
