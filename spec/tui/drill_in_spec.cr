require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def rail_rows(n : Int32) : Array(DrillIn::RailRow)
  (0...n).map { |i| DrillIn::RailRow.new("200", "GET api.test/v1/item/#{i}", "22:59:0#{i}") }
end

describe Gori::Tui::DrillIn do
  describe ".rail_split" do
    it "gives the rail its rows plus a divider and hands the rest to the detail" do
      rail, detail = DrillIn.rail_split(Rect.new(2, 3, 80, 30))
      rail.should_not be_nil
      rail = rail.not_nil!
      rail.y.should eq(3)
      rail.h.should eq(DrillIn::RAIL_ROWS)
      # One row between them: the divider the crumb rides.
      detail.y.should eq(rail.bottom + 1)
      detail.h.should eq(30 - DrillIn::RAIL_H)
    end

    it "drops the rail whole rather than squeezing the item you opened" do
      # One row under the floor. The detail is what the drill-in is FOR; a four-line detail
      # with context above it is worse than a full one with the crumb alone.
      short = DrillIn::RAIL_H + DrillIn::MIN_DETAIL_H - 1
      rail, detail = DrillIn.rail_split(Rect.new(0, 0, 80, short))
      rail.should be_nil
      detail.h.should eq(short) # byte-identical to the pre-rail drill-in
    end

    it "drops the rail when there is no neighbour to show" do
      # A one-row list has nothing either side, so the rail would spend four rows redrawing
      # the row the crumb already names.
      rail, detail = DrillIn.rail_split(Rect.new(0, 0, 80, 40), 1)
      rail.should be_nil
      detail.h.should eq(40)
    end
  end

  describe "the crumb row" do
    it "is the rail's divider, which is also the detail's own top border" do
      # This identity is what lets `Frame.crumb`'s default row be right in BOTH cases, so
      # neither the render nor the hit-test needs a rail-aware branch.
      inner = Rect.new(1, 5, 80, 40)
      rail, detail = DrillIn.rail_split(inner)
      (detail.y - 1).should eq(rail.not_nil!.bottom)

      _, unrailed = DrillIn.rail_split(inner, 1)
      (unrailed.y - 1).should eq(inner.y - 1)
    end
  end

  describe ".window_start" do
    it "centres the cursor and slides at both ends instead of padding blanks" do
      DrillIn.window_start(10, 5).should eq(4) # centred
      DrillIn.window_start(10, 0).should eq(0) # top: no row above to claim
      DrillIn.window_start(10, 9).should eq(7) # bottom: the last three
      DrillIn.window_start(2, 1).should eq(0)  # shorter than the window
    end
  end

  describe ".render_rail" do
    it "carries the list's own cursor treatment onto the open row" do
      backend = MemoryBackend.new(80, 5)
      screen = Screen.new(backend)
      DrillIn.render_rail(screen, Rect.new(0, 0, 80, 3), rail_rows(3), 1)
      # The gutter bar is what makes the rail read as the list rather than as a new widget.
      backend.row(1).starts_with?("▎").should be_true
      backend.row(0).starts_with?("▎").should be_false
      backend.row(0).includes?("GET api.test/v1/item/0").should be_true
      backend.row(2).includes?("GET api.test/v1/item/2").should be_true
    end

    it "labels the immediate neighbours with the key that lands on them" do
      backend = MemoryBackend.new(80, 5)
      screen = Screen.new(backend)
      DrillIn.render_rail(screen, Rect.new(0, 0, 80, 3), rail_rows(3), 1)
      # The key rides the cursor bar's own column, so "press this, land here" is one fact
      # rather than two the operator has to connect.
      backend.row(0).starts_with?("⇧P").should be_true
      backend.row(1).starts_with?("▎").should be_true
      backend.row(2).starts_with?("⇧N").should be_true
    end

    it "labels only rows ONE press away, at either end of the list" do
      backend = MemoryBackend.new(80, 5)
      screen = Screen.new(backend)
      # Cursor at the top of the list: the window cannot slide, so there is no previous row
      # and the row two below must NOT wear ⇧N — one press does not reach it.
      DrillIn.render_rail(screen, Rect.new(0, 0, 80, 3), rail_rows(3), 0)
      backend.row(0).starts_with?("▎").should be_true
      backend.row(1).starts_with?("⇧N").should be_true
      backend.row(2).strip.starts_with?("⇧").should be_false
    end

    it "prints the labels it is given, so a rebind moves what the gutter says" do
      backend = MemoryBackend.new(80, 5)
      screen = Screen.new(backend)
      DrillIn.render_rail(screen, Rect.new(0, 0, 80, 3), rail_rows(3), 1, next_key: "^J", prev_key: "^K")
      backend.row(0).starts_with?("^K").should be_true
      backend.row(2).starts_with?("^J").should be_true
    end

    it "never draws past its rect, however many rows it is handed" do
      backend = MemoryBackend.new(80, 6)
      screen = Screen.new(backend)
      DrillIn.render_rail(screen, Rect.new(0, 0, 80, 2), rail_rows(5), 0)
      backend.row(2).strip.should be_empty
    end
  end

  describe ".rail_row_at" do
    it "answers only for rows that were actually drawn" do
      rail = Rect.new(0, 4, 80, DrillIn::RAIL_ROWS)
      DrillIn.rail_row_at(rail, 10, 4, 3).should eq(0)
      DrillIn.rail_row_at(rail, 10, 6, 3).should eq(2)
      # Near the ends of a short list the window holds fewer rows than the rect has: a click
      # on an undrawn row must miss, not select whatever index the arithmetic yields.
      DrillIn.rail_row_at(rail, 10, 6, 2).should be_nil
      DrillIn.rail_row_at(rail, 10, 7, 3).should be_nil # past the rail
      DrillIn.rail_row_at(nil, 10, 4, 3).should be_nil  # no rail at this size
    end
  end
end

describe Gori::Tui::Frame::Crumb do
  it "names where you are, which row of it, and what is open" do
    Frame::Crumb.new("HISTORY", "GET api.test/v1/me", "12/123").text
      .should eq(" ‹ HISTORY · 12/123 · GET api.test/v1/me ")
  end

  it "drops the position when the list behind is empty" do
    Frame::Crumb.new("ISSUES", "Deployed .env readable").text
      .should eq(" ‹ ISSUES · Deployed .env readable ")
  end

  describe ".crumb_rect" do
    it "clips to the frame rather than overwriting its top-right corner" do
      inner = Rect.new(1, 1, 30, 10)
      crumb = Frame::Crumb.new("HISTORY", "GET a-very-long-host.example/some/deep/path", "9/99")
      rect = Frame.crumb_rect(inner, crumb).not_nil!
      rect.y.should eq(0)
      rect.x.should eq(2)
      (rect.right <= inner.right - 1).should be_true
    end

    it "declines rather than drawing a clipped crumb on a narrow pane" do
      Frame.crumb_rect(Rect.new(0, 2, 8, 5), Frame::Crumb.new("PROBE", "x")).should be_nil
    end

    it "declines when the border row would be off-screen" do
      Frame.crumb_rect(Rect.new(0, 0, 40, 5), Frame::Crumb.new("PROBE", "x")).should be_nil
    end

    it "hangs the step keys off the same row, right-aligned" do
      backend = MemoryBackend.new(80, 6)
      screen = Screen.new(backend)
      inner = Rect.new(1, 1, 78, 4)
      Frame.crumb(screen, inner, Frame::Crumb.new("HISTORY", "GET /a", "4/120"), meta: "⇧N/⇧P")
      row = backend.row(0)
      row.includes?("‹ HISTORY").should be_true
      row.includes?("⇧N/⇧P").should be_true
      # Right-aligned, clear of the frame's top-right corner.
      row.rstrip.ends_with?("⇧N/⇧P").should be_true
    end

    it "drops the step keys rather than colliding with the crumb" do
      backend = MemoryBackend.new(40, 6)
      screen = Screen.new(backend)
      inner = Rect.new(1, 1, 38, 4)
      long = Frame::Crumb.new("HISTORY", "GET a-very-long-host.example/deep/path/here", "9/99")
      Frame.crumb(screen, inner, long, meta: "⇧N/⇧P")
      backend.row(0).includes?("⇧N/⇧P").should be_false
    end

    it "rides an explicit row — the rail's divider — when given one" do
      inner = Rect.new(1, 1, 40, 20)
      Frame.crumb_rect(inner, Frame::Crumb.new("HISTORY", "GET /a"), 7).not_nil!.y.should eq(7)
    end
  end
end
