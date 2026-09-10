require "./screen"
require "./theme"
require "./frame"

module Gori::Tui
  # The list RAIL a drill-in keeps above itself — the three rows of context (previous,
  # current, next) that stop an opened item from reading as a different screen.
  #
  # Shared by the three tabs that replace their body with one item's detail (History,
  # Issues, Probe), the same three that already share `PreviewSplit`. Before it, opening a
  # row swapped the whole tab body: the card lost its title, the tab bar rendered exactly as
  # it does over the list, and nothing on screen said which list was behind — so the way
  # back was something you had to remember rather than see.
  #
  # The rail is deliberately NOT a re-render of each tab's list. Those renderers draw a
  # filter bar, a column header and a divider before their first data row (four rows of
  # chrome to show three rows of content), and their column geometry is derived per frame
  # from the full pane width. A rail built from `RailRow` costs one row per item, reads the
  # same left-to-right, and — the part that matters — carries the list's own cursor
  # treatment: the `▎` gutter and the accent band, so the eye maps it to the list it came
  # from rather than to a new widget.
  #
  # AXIS, which is the load-bearing choice: the rail is HORIZONTAL (rows above), not a
  # column beside. gori's lists are wide tables and its details are read by width, so a
  # left-hand peek would shrink the thing you opened and turn the list into a truncated
  # shape that no longer looks like the list. Rows are the cheap axis here — the same one
  # `PreviewSplit` already took, and the one every HTTP proxy's master/detail uses.
  module DrillIn
    # Rows of list context: the item before, the item itself, the item after. Three is the
    # fewest that can show a NEIGHBOUR ON EITHER SIDE, which is what makes ⇧N/⇧P legible as
    # "there is more this way" rather than as a key you have to be told about.
    RAIL_ROWS = 3

    # What the rail costs the detail: its rows plus the divider that anchors it.
    RAIL_H = RAIL_ROWS + 1

    # Interior rows the DETAIL must keep for the rail to be affordable. Under this the rail
    # is dropped whole rather than squeezed — the item is what the drill-in is FOR, and a
    # detail reduced to four lines is worse than one with no context above it. `Layout` admits
    # a 40×8 terminal, where the body interior is three rows and there is no choice to make.
    #
    # This is also why the crumb (Frame::Crumb) had to land first and cannot depend on the
    # rail: on a short terminal the crumb is the ONLY thing saying where you are.
    MIN_DETAIL_H = 12

    # One rail row, in the three parts every one of these lists happens to have: a short
    # coloured lead (status code / severity), the identity, and a muted tail (host, type).
    # A view maps its own row onto this; nothing else about its list renderer is involved.
    record RailRow, lead : String, text : String, tail : String? = nil, lead_color : Color? = nil

    # Split a drill-in's framed interior into {rail, detail}. `rail` is nil when the pane is
    # too short to keep both, and then `detail` is the whole interior — byte-identical to
    # what the drill-in drew before the rail existed.
    #
    # ONE derivation: the render calls it, and so does every hit-test, because a body drawn
    # against one rect and clicked against another is a dead row.
    #
    # `count` is how many rows of context there actually ARE. One is not context — a
    # single-row list has no neighbour either side, so the rail would spend four rows to
    # redraw the row the crumb already names.
    def self.rail_split(inner : Rect, count : Int32 = RAIL_ROWS) : {Rect?, Rect}
      return {nil, inner} if count <= 1 || inner.h < RAIL_H + MIN_DETAIL_H
      rail = Rect.new(inner.x, inner.y, inner.w, RAIL_ROWS)
      detail = Rect.new(inner.x, inner.y + RAIL_H, inner.w, inner.h - RAIL_H)
      # The divider between them IS `detail.y - 1`, which is where `Frame.crumb` puts itself
      # by default — so the crumb rides the rail's divider with a rail and the card's own top
      # border without one, and neither the drill-in's render nor its hit-test has to know
      # which case it is in.
      {rail, detail}
    end

    # First index of the window a rail of `size` rows shows around `cursor`. Slides at the
    # ends instead of leaving blank rows: near the top of a list the cursor simply is not in
    # the middle, and padding it there would claim neighbours that do not exist.
    def self.window_start(total : Int32, cursor : Int32, size : Int32 = RAIL_ROWS) : Int32
      return 0 if total <= size
      (cursor - size // 2).clamp(0, total - size)
    end

    # Draw the rail. `cursor` is the index WITHIN `rows` of the open item, so a view hands
    # over its window and does not have to think about the slide above.
    #
    # `focused` gilds the open row the way the list's own cursor row is gilded when the body
    # holds focus — the rail is a readout, not a pane you can move into, so it never takes
    # the gold border, only the band.
    def self.render_rail(screen : Screen, rect : Rect, rows : Array(RailRow), cursor : Int32,
                         focused : Bool = true) : Nil
      return if rect.empty? || rows.empty?
      # Leads share one column so the identities start at the same x — an unaligned status
      # code reads as three ragged rows rather than as a list.
      lead_w = rows.max_of { |r| Screen.draw_width(r.lead) }
      rows.each_with_index do |row, i|
        y = rect.y + i
        break if y >= rect.bottom
        draw_row(screen, rect, y, row, lead_w, here: i == cursor, focused: focused)
      end
    end

    # One rail row. Split out of `render_rail` for the same reason every other renderer in
    # this codebase splits its row draw: the loop is about WHICH rows, the row is about what
    # a row looks like, and only the second one grows.
    private def self.draw_row(screen : Screen, rect : Rect, y : Int32, row : RailRow,
                              lead_w : Int32, *, here : Bool, focused : Bool) : Nil
      bg = here ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if here
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      end
      x = rect.x + 2
      if lead_w > 0
        screen.text(x, y, row.lead, row.lead_color || Theme.muted, bg, width: lead_w)
        x += lead_w + 1
      end
      fg = here ? Theme.text_bright : Theme.text
      # The tail is granted only what is left once the identity has room to be a name rather
      # than an ellipsis; below that it drops whole, like every other cluster here that
      # competes with a path for a narrow pane.
      if (tail = row.tail) && rect.right - x > 24
        tw = {Screen.draw_width(tail), (rect.right - x) // 3}.min
        screen.text(x, y, row.text, fg, bg, width: {rect.right - x - tw - 1, 0}.max)
        screen.text(rect.right - tw, y, tail, Theme.muted, bg, width: tw)
      else
        screen.text(x, y, row.text, fg, bg, width: {rect.right - x, 0}.max)
      end
    end

    # Which rail row (0-based within the drawn window) the pointer is over, or nil. Read off
    # the same `rail_split` rect the render used, so a click cannot land on a row that was
    # never drawn.
    def self.rail_row_at(rail : Rect?, mx : Int32, my : Int32, count : Int32) : Int32?
      r = rail || return nil
      return nil unless r.contains?(mx, my)
      i = my - r.y
      i < count ? i : nil
    end
  end
end
