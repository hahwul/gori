require "../support/tui_contract"

include Gori::Tui

# CONTRACT: a tab body draws only inside the rect it was handed, at every terminal size the
# app admits.
#
# `Runner` hands each controller `layout.body` and draws the chrome — top bar, tab menu,
# hairline rule, status row — itself. A controller that walks `y` past its own rect does not
# fail loudly: it overwrites the shell's chrome, or shares a row with a neighbouring pane, and
# the operator sees a line of two sentences spliced together. `short_pane_clamp_spec` and
# `notes_controller_spec` each pin one instance of this ("clamp one axis, forget the other",
# and a link preview placed at `rect.y - 1` that landed on the `/ filter` bar); the mistake is
# one mistake, and a per-pane spec finds it only after someone reports it.
#
# So: sweep every controller across the supported size range and assert the writes. The sizes
# are real ones — `Layout.usable?` admits 40x8 and up, and `Layout.compute` turns that into a
# body of 36x2, which is where a bottom-anchored row and a card floor have nowhere to go.
#
# `Screen#cell` clips to the SCREEN, not to the rect, so a stray write lands in the recording
# below rather than being swallowed — which is the whole point of recording the screen instead
# of a body-sized grid.
private class BoundsBackend < Gori::Tui::Backend
  getter writes = [] of {Int32, Int32}

  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Gori::Tui::Color,
          bg : Gori::Tui::Color, attr : Gori::Tui::Attribute) : Nil
    @writes << {x, y}
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

# Widths that bracket every layout decision in the tree: the 40 floor, the odd column just
# past it, the narrow-pane thresholds the split panes use, the classic 80, and a wide one.
private WIDTHS = [40, 41, 45, 52, 60, 72, 79, 80, 100, 132]

# 8 is the floor; 8..26 covers every "does this card fit" band, and 40 stands in for a tall
# terminal where nothing is clamped.
private HEIGHTS = (8..26).to_a << 40

describe "TabController contract — a body renders inside its rect" do
  it "writes nothing outside the body rect at any supported terminal size" do
    strays = [] of String
    TuiContract.with_session("render-bounds") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        WIDTHS.each do |w|
          HEIGHTS.each do |h|
            body = Layout.compute(w, h).body
            backend = BoundsBackend.new(w, h)
            controller.render_body(Screen.new(backend), body, :body)
            out = backend.writes.reject { |(x, y)| body.contains?(x, y) }
            next if out.empty?
            strays << "#{controller.class} at #{w}x#{h} (body #{body.x},#{body.y} " \
                      "#{body.w}x#{body.h}) wrote #{out.size} cells outside, first at #{out.first}"
          end
        end
      end
    end
    # One line per (controller, size) so the report names the pane AND the size, which is the
    # pair a fix needs; `.first(8)` keeps a systemic break readable.
    strays.first(8).should be_empty
  end
end
