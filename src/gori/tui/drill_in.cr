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
    # fewest that can show a NEIGHBOUR ON EITHER SIDE, which is what makes the step keys legible as
    # "there is more this way" rather than as a key you have to be told about.
    RAIL_ROWS = 3

    # What a FULL rail costs the detail: its rows plus the divider that anchors it. The real
    # cost is `{count, RAIL_ROWS}.min + 1` — see `rail_split`, which sizes to the window.
    RAIL_H = RAIL_ROWS + 1

    # Interior rows the DETAIL must keep for the rail to be affordable. Under this the rail
    # is dropped whole rather than squeezed — the item is what the drill-in is FOR, and a
    # detail reduced to four lines is worse than one with no context above it. `Layout` admits
    # a 40×8 terminal, where the body interior is three rows and there is no choice to make.
    #
    # This is also why the crumb (Frame::Crumb) had to land first and cannot depend on the
    # rail: on a short terminal the crumb is the ONLY thing saying where you are.
    MIN_DETAIL_H = 12

    # Default labels for the two chords that step the drill-in through the list — `n` forward
    # and `⇧N` back, which is what `comparer.next-change` / `comparer.prev-change` already
    # mean one tab over (and what vim and less mean everywhere). The first spelling here was
    # ⇧N/⇧P, which made ⇧N move FORWARD in a drill-in and BACKWARD in the Comparer; the boot
    # gate cannot see that, because `Registry#validate_chords!` builds its seen-set per Scope.
    #
    # Literals,
    # because the rail renders with no registry in reach — the fallback every registry-less
    # render in this codebase keeps. A controller that HAS the registry pushes the effective
    # labels down instead (see the `step_keys` setter on each view), so a rebind moves what
    # the gutter prints.
    NEXT_KEY = "n"
    PREV_KEY = "⇧N"

    # One rail row, in the three parts every one of these lists happens to have: a short
    # coloured lead (status code / severity), the identity, and a muted tail (host, type).
    # A view maps its own row onto this; nothing else about its list renderer is involved.
    record RailRow, lead : String, text : String, tail : String? = nil, lead_color : Color? = nil

    # Split a drill-in's framed interior into {rail, detail}. `rail` is nil when the pane is
    # too short to keep both or there is no context to show, and then `detail` is the whole
    # interior — byte-identical to what the drill-in drew before the rail existed.
    #
    # ONE derivation: the render calls it, and so does every hit-test, because a body drawn
    # against one rect and clicked against another is a dead row.
    #
    # `count` is how many rows of context there actually ARE, and it SIZES the rail as well
    # as gating it. A fixed RAIL_ROWS-tall rail on a two-item list left an undrawn row
    # between the last entry and the divider, and forced every hit-test to carry `count` a
    # second time just to reject clicks on it.
    def self.rail_split(inner : Rect, count : Int32) : {Rect?, Rect}
      h = {count, RAIL_ROWS}.min
      return {nil, inner} if count <= 1 || inner.h < h + 1 + MIN_DETAIL_H
      rail = Rect.new(inner.x, inner.y, inner.w, h)
      # The divider between them IS `detail.y - 1`, which is where `Frame.crumb` puts itself
      # — so the crumb rides the rail's divider with a rail and the card's own top border
      # without one, and neither the drill-in's render nor its hit-test has to know which
      # case it is in.
      detail = Rect.new(inner.x, inner.y + h + 1, inner.w, inner.h - h - 1)
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
                         focused : Bool = true, next_key : String = NEXT_KEY,
                         prev_key : String = PREV_KEY) : Nil
      return if rect.empty? || rows.empty?
      # Leads share one column so the identities start at the same x — an unaligned status
      # code reads as three ragged rows rather than as a list.
      lead_w = rows.max_of { |r| Screen.draw_width(r.lead) }
      rows.each_with_index do |row, i|
        y = rect.y + i
        break if y >= rect.bottom
        # Only the IMMEDIATE neighbours carry a key: the label says "one press lands here",
        # and a row two steps away wearing the same label would be a lie. At the ends of the
        # list the window slides and the cursor is not centred, so one side simply has none.
        step = case i - cursor
               when -1 then prev_key
               when  1 then next_key
               end
        draw_row(screen, rect, y, row, lead_w, step: step, here: i == cursor, focused: focused)
      end
    end

    # One rail row. Split out of `render_rail` for the same reason every other renderer in
    # this codebase splits its row draw: the loop is about WHICH rows, the row is about what
    # a row looks like, and only the second one grows.
    private def self.draw_row(screen : Screen, rect : Rect, y : Int32, row : RailRow,
                              lead_w : Int32, *, step : String?, here : Bool, focused : Bool) : Nil
      bg = here ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if here
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      elsif step
        # The step key rides the CURSOR'S OWN COLUMN, so the key and the row it moves to line
        # up instead of being two facts the operator has to connect — the position readout in
        # the crumb says a next one exists, this says which press gets there. Muted, because
        # the cursor bar has to stay the brightest thing in the gutter.
        screen.text(rect.x, y, step, Theme.muted, bg, width: 2)
      end
      # 3, not 2: the gutter holds either the cursor bar (1 cell) or a step key (2), and a
      # 2-cell gutter left `⇧P` flush against the status code — `⇧P200`, the same fusing the
      # History list's METHOD/PROTO columns buy a blank column to avoid.
      x = rect.x + 3
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
    # the same `rail_split` rect the render used — and that rect is exactly as tall as the
    # window has rows, so every row inside it was drawn.
    def self.rail_row_at(rail : Rect?, mx : Int32, my : Int32) : Int32?
      r = rail || return nil
      r.contains?(mx, my) ? my - r.y : nil
    end

    # The half of the drill-in every one of the three tabs implements identically: the
    # split's two rects, the rail draw, and the step-key labels the controller pushes down.
    # Included by HistoryView, IssuesView and ProbeView, the same three that already share
    # `PreviewSplit` — and for the same reason. Three copies of this had already drifted
    # apart on the day they were written (one gilded the rail's divider and two did not).
    #
    # The includer supplies `rail_count`, `rail_window` and `detail_crumb`; everything below
    # is derived, so a fourth drill-in gets the whole contract by including this.
    module Host
      # The effective labels for the item-step chords, pushed down each frame by the
      # controller — the side that can read the keymap. Literal defaults so a registry-less
      # render (every view spec) still prints something, which is the fallback convention
      # every such render in this codebase keeps.
      property step_keys : {String, String} = {DrillIn::NEXT_KEY, DrillIn::PREV_KEY}

      # How many rows the rail would draw — answered WITHOUT building them. Every geometry
      # caller needs only this, and `rail_window` allocates a record and a string per row:
      # a single click used to rebuild it four times, and a drag once per motion event.
      abstract def rail_count : Int32

      # The rows themselves, and — separately, so a caller that only needs the index pays
      # nothing — where the OPEN row sits within them. A click on rail row `i` steps by
      # `i - rail_cursor`.
      abstract def rail_rows : Array(RailRow)
      abstract def rail_cursor : Int32

      abstract def detail_crumb : Frame::Crumb?

      # The RAIL's rect, or nil when it is not shown.
      def rail_rect(inner : Rect) : Rect?
        DrillIn.rail_split(inner, rail_count)[0]
      end

      # The DETAIL's rect inside the drill-in. `inset` alone stopped being the answer once
      # the rail could sit above it, and every hit-test measures against this.
      def detail_body_rect(inner : Rect) : Rect
        DrillIn.rail_split(inner, rail_count)[1]
      end

      # Draw the rail and its divider; answer {detail rect, crumb meta}.
      #
      # `focused` is the frame's own state (it colours the divider, so the line matches the
      # border it meets); `active` is "the drill-in has the keyboard at all", which is what
      # lights the open row's band — on History those differ, because the chip strip holds
      # focus without the body frame gilding.
      def render_rail_chrome(screen : Screen, inner : Rect, focused : Bool,
                             active : Bool = focused) : {Rect, String?}
        rail, body = DrillIn.rail_split(inner, rail_count)
        unless rail
          # No rail to hang the step keys off, so they ride the crumb's row instead — the
          # affordance must not depend on the terminal being tall enough. Nothing to step
          # to on a single-row list, and then neither surface offers them.
          return {body, rail_count <= 1 ? nil : "#{@step_keys[0]}/#{@step_keys[1]}"}
        end
        DrillIn.render_rail(screen, rail, rail_rows, rail_cursor, focused: active,
          next_key: @step_keys[0], prev_key: @step_keys[1])
        Frame.inner_divider(screen, inner, rail.bottom, border: Frame.pane_border(focused))
        {body, nil}
      end
    end
  end
end
