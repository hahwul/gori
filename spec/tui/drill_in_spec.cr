require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def rail_rows(n : Int32) : Array(DrillIn::RailRow)
  (0...n).map { |i| DrillIn::RailRow.new("200", "GET api.test/v1/item/#{i}", "22:59:0#{i}") }
end

# The abstracts `DrillIn::Host` asks a view for, and nothing else — the point is that
# everything the three tabs share is DERIVED from them, so the derivations are spec-able
# without a store, a session or a real view.
#
# `here` is the open item's index in the list behind it (nil = not a row of it at all, the
# deep-link case), `total` the length of that list — deliberately NOT a rail-row count, so
# a list far longer than RAIL_ROWS is expressible and the derivations can be told apart.
private class FakeDrillHost
  include DrillIn::Host

  def initialize(@here : Int32?, @total : Int32)
  end

  def detail_row_index : Int32?
    @here
  end

  def row_count : Int32
    @total
  end

  def rail_rows : Array(DrillIn::RailRow)
    (0...rail_count).map { |i| DrillIn::RailRow.new("200", "GET api.test/v1/item/#{i}") }
  end

  def rail_cursor : Int32
    (@here || 0) - DrillIn.window_start(@total, @here || 0)
  end

  def detail_crumb : Frame::Crumb?
    Frame::Crumb.new("HISTORY", "GET api.test/v1/me", "#{(@here || 0) + 1}/#{@total}")
  end
end

describe Gori::Tui::DrillIn do
  describe ".rail_split" do
    it "gives the rail its rows plus a divider and hands the rest to the detail" do
      rail, detail = DrillIn.rail_split(Rect.new(2, 3, 80, 30), 3)
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
      rail, detail = DrillIn.rail_split(Rect.new(0, 0, 80, short), 3)
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
      rail, detail = DrillIn.rail_split(inner, 3)
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
      DrillIn.rail_row_at(rail, 10, 4).should eq(0)
      DrillIn.rail_row_at(rail, 10, 6).should eq(2)
      DrillIn.rail_row_at(rail, 10, 7).should be_nil # past the rail
      DrillIn.rail_row_at(nil, 10, 4).should be_nil  # no rail at this size
    end
  end

  describe "Host#step_available?" do
    it "is false when the open item is not a row of the list behind" do
      # Probe's and Issues' `o` open a FLOW BY ID, so a flow the current History view or
      # query filters out lands in the drill-in with no index in the list — however long
      # that list is, there is nothing to step THROUGH from here.
      FakeDrillHost.new(nil, 900).step_available?.should be_false
    end

    it "is false on a single-row list, where the only row is the one already open" do
      FakeDrillHost.new(0, 1).step_available?.should be_false
    end

    it "is true as soon as there is one neighbour" do
      FakeDrillHost.new(0, 2).step_available?.should be_true
      FakeDrillHost.new(1, 2).step_available?.should be_true
    end

    it "reads the LIST, not the rail's draw count, so RAIL_ROWS stays a free parameter" do
      # `rail_count` is clamped to RAIL_ROWS, so `rail_count > 1` agrees with this only
      # because RAIL_ROWS happens to be 3. Tune it to 1 and that spelling would silence
      # every step hint in the app over a 900-row list while the keys still worked.
      host = FakeDrillHost.new(400, 900)
      host.rail_count.should eq(DrillIn::RAIL_ROWS) # the draw count saturates…
      host.step_available?.should be_true           # …the predicate does not
    end
  end

  describe "Host#rail_count" do
    it "is the window the rail can draw, and 0 for an item with no place in the list" do
      FakeDrillHost.new(400, 900).rail_count.should eq(DrillIn::RAIL_ROWS)
      FakeDrillHost.new(0, 2).rail_count.should eq(2)
      FakeDrillHost.new(nil, 900).rail_count.should eq(0)
    end
  end

  describe "Host#render_rail_chrome" do
    it "hangs the step keys off the RAIL when there is room for one" do
      backend = MemoryBackend.new(80, 30)
      screen = Screen.new(backend)
      host = FakeDrillHost.new(400, 900)
      host.step_keys = {"^J", "^K"} # sentinels: the defaults would pass a render that ignored them
      _, meta = host.render_rail_chrome(screen, Rect.new(0, 0, 80, 24), true)
      meta.should be_nil                               # the rail carries them, so the crumb must not
      backend.row(0).starts_with?("^K").should be_true # prev, above the cursor row
      backend.row(2).starts_with?("^J").should be_true # next, below it
    end

    it "hands them to the crumb instead when the pane is too short for a rail" do
      backend = MemoryBackend.new(80, 8)
      screen = Screen.new(backend)
      host = FakeDrillHost.new(400, 900)
      host.step_keys = {"^J", "^K"}
      _, meta = host.render_rail_chrome(screen, Rect.new(0, 0, 80, 6), true)
      meta.should eq("^J/^K")
    end

    it "offers them on NEITHER surface when there is nowhere to step" do
      backend = MemoryBackend.new(80, 30)
      screen = Screen.new(backend)
      host = FakeDrillHost.new(nil, 900)
      host.step_keys = {"^J", "^K"}
      _, meta = host.render_rail_chrome(screen, Rect.new(0, 0, 80, 24), true)
      meta.should be_nil
      backend.row(0).strip.should be_empty
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

    it "rides the row above its interior, which is the rail's divider or the card's edge" do
      inner = Rect.new(1, 1, 40, 20)
      Frame.crumb_rect(inner, Frame::Crumb.new("HISTORY", "GET /a")).not_nil!.y.should eq(0)
    end
  end
end
