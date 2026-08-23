require "../spec_helper"

include Gori::Tui

# The Colormarker list's geometry, which is really ONE invariant stated three times:
# `render`, `row_capacity` and `row_at` must agree about whether the interior's bottom row
# belongs to the rules or to the "first enabled match wins" note.
#
# They did not. `render` stole that row whenever a second rule existed, while capacity
# reported the full interior and `row_at` mapped every row inside it — so the last rule
# scrolled underneath the note with no way to reach it, and a click on the prose selected a
# rule that was not under the pointer. The twin next door (`RewriterView#list_row_capacity` /
# `#row_at`) had always subtracted its own stolen row; this list was the copy that never
# caught up. These examples exist to keep the three answers in step.
describe Gori::Tui::ColormarkerView do
  view = Gori::Tui::ColormarkerView.new

  # A card whose framed interior is `h` rows tall — `render` insets by 1 on every side.
  card = ->(h : Int32) { Rect.new(0, 0, 60, h + 2) }

  describe "#row_capacity" do
    it "keeps the whole interior when a lone rule cannot contend with anything" do
      # The note only means something once two rules can both match, so with 0 or 1 rules
      # `render` draws no note and the list is free to use every row.
      view.row_capacity(card.call(6), 0).should eq(6)
      view.row_capacity(card.call(6), 1).should eq(6)
    end

    it "gives the note its row back once two rules can contend" do
      view.row_capacity(card.call(6), 2).should eq(5)
    end

    it "keeps every row in a card too short to spare one for the note" do
      # `render` skips the note at an interior of 2 or less rather than leave a single
      # rule row, so capacity must not subtract one either.
      view.row_capacity(card.call(2), 5).should eq(2)
      view.row_capacity(card.call(1), 5).should eq(1)
    end
  end

  describe "#row_at" do
    it "maps interior rows to rule indices from the scroll offset" do
      rect = card.call(6)
      view.row_at(rect, 1, 0, 4).should eq(0)
      view.row_at(rect, 3, 0, 4).should eq(2)
      view.row_at(rect, 1, 2, 4).should eq(2)
    end

    it "refuses the note's row instead of resolving it to a rule" do
      # Interior spans y 1..6 and the note takes y 6, leaving five rows for rules. With five
      # rules every one of them is reachable and the note is still not: clicking the prose
      # used to select whatever index that row happened to land on.
      rect = card.call(6)
      view.row_at(rect, 5, 0, 5).should eq(4)
      view.row_at(rect, 6, 0, 5).should be_nil
    end

    it "refuses a row past the last rule" do
      # Six rows of interior, two rules: rows 3..5 are empty canvas, not rule 2/3/4.
      rect = card.call(6)
      view.row_at(rect, 3, 0, 2).should be_nil
    end

    it "refuses anything outside the framed interior" do
      rect = card.call(6)
      view.row_at(rect, 0, 0, 4).should be_nil # the top border
      view.row_at(rect, 7, 0, 4).should be_nil # the bottom border
    end

    it "never resolves a row the capacity does not admit" do
      # The invariant the two methods broke, stated directly: every row `row_at` accepts has
      # to be one `row_capacity` claimed exists, at every size the card can take.
      (1..8).each do |h|
        rect = card.call(h)
        [0, 1, 2, 5].each do |count|
          cap = view.row_capacity(rect, count)
          (rect.y...rect.bottom).each do |my|
            next unless idx = view.row_at(rect, my, 0, count)
            idx.should be < cap
            idx.should be < count
          end
        end
      end
    end
  end

  # The row's own width arithmetic. Every field right of the swatch is user text, and `render_row`
  # used to advance `x` by `String#size` — CHARACTERS — after drawing it. For a rule named in
  # Hangul that is half the cells it actually painted, so the match filter behind the name was
  # written back over it and the row came out as
  # `[한글 규칙 이름 — 아주 길게 늘 host:      .  국 ]`. The fix is to advance by what
  # `screen.text` returns (the x it reached, in columns), which is what the Sitemap's tag column
  # already does.
  describe "#render" do
    it "does not draw a rule's filter back over a name written in wide characters" do
      backend = MemoryBackend.new(90, 5)
      rule = Gori::Store::ColorRule.new(1_i64, true, "host:쇼핑몰.한국", "cyan",
        Gori::Store::MarkerStyle::Strip, "한글 규칙 이름")
      view.render(Screen.new(backend), Rect.new(0, 0, 90, 5), [rule], 0, 0, 1, false)
      # Compacted, because a width-2 glyph owns two grid cells and only fills the first: what
      # matters is that every glyph of both runs survives, in order, with the filter AFTER the
      # closing bracket instead of on top of the name.
      backend.row(1).delete(' ').should contain("[한글규칙이름]host:쇼핑몰.한국")
    end
  end
end
