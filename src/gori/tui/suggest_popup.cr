require "./screen"
require "./theme"
require "./query_suggest"
require "./viewport"

module Gori::Tui
  # The filter bars' opt-in completion dropdown: the same candidates the inline row already
  # shows, given a row each so every one of them can carry its meaning, and a selection so Tab
  # takes the one you want instead of always the first.
  #
  # OPT-IN is the whole design. A dropdown is not cheaper than the inline row — it is dearer:
  # the row costs exactly one line of the list (`list_top` adds it only while querying), where a
  # dropdown covers up to `MAX_ROWS` of the rows you are trying to read. On an 80x12 terminal the
  # History list body is one row, and neither shape has anywhere to go. So the inline row stays
  # the default and this opens on `↓` — a key every filter bar's controller left dead. The
  # occlusion is then something the operator asked for, and it arrives together with the
  # selection that makes it worth asking for.
  #
  # Modelled on `EnvComplete`, deliberately not shared with it: that one anchors to a caret that
  # can be anywhere in a two-dimensional editor and has no notion of a description column, where
  # this one hangs off a known bar row and its second column is the point.
  class SuggestPopup
    MAX_ROWS =  8
    MIN_W    = 20
    # The polarity marker, as ONE constant read by both the drawer and the width calculator.
    EXCLUDES = " excludes"

    getter? open : Bool = false
    getter selected : Int32 = 0

    @items = [] of String
    @scroll = 0

    # Replace the candidate set. Keeps the popup's OPEN state (the operator opened it; a
    # keystroke that narrows the list should not shut it) but closes when nothing is left,
    # since an empty dropdown is a hole punched in the list for no content. The selection
    # re-anchors to the same candidate when it survived the edit, so typing another character
    # does not silently move what Tab would take.
    def set(items : Array(String)) : Nil
      keep = @items[@selected]?
      @items = items
      if items.empty?
        @open = false
        @selected = 0
      else
        @selected = (keep ? items.index(keep) : nil) || 0
      end
      @scroll = @scroll.clamp(0, {items.size - 1, 0}.max)
    end

    # `↓` on a closed bar. Opens only when there is something to show — otherwise the key falls
    # through to whatever the surface does with it.
    def open! : Bool
      return false if @items.empty?
      @open = true
    end

    def close : Nil
      @open = false
    end

    # `&&`, not `||`: an empty list must return BEFORE the clamp, whose max would be -1 and which
    # raises on min > max rather than saturating. Unreachable through the current callers (`set`
    # closes on empty and `open!` refuses it), which is exactly why it would have been a crash
    # nobody found until a fourth caller appeared.
    def move(d : Int32) : Nil
      return unless @open && !@items.empty?
      @selected = (@selected + d).clamp(0, @items.size - 1)
    end

    # What Tab should splice: the SELECTED candidate while open, else the first — so a bar whose
    # popup was never opened behaves exactly as it did before this existed.
    def choice(fallback : Array(String)) : String?
      return @items[@selected]? if @open
      fallback.first?
    end

    # Draw anchored under (ax, ay), clamped inside `bounds` — the list area the popup is allowed
    # to cover.
    #
    # CLOSES ITSELF rather than silently declining when there is no room. `open?` gates Esc and
    # ↵ in three controllers, so an open-but-undrawable popup hijacks both: Esc stops clearing the
    # filter and ↵ stops applying it, with nothing on screen to explain why. A pane narrower than
    # `MIN_W`, or one where `list_top` has reached the bottom, is exactly that state — and it is
    # reachable by resizing the terminal while the list is open. Shutting on the frame that cannot
    # draw costs one wasted keypress at worst and self-heals.
    def render(screen : Screen, ax : Int32, ay : Int32, bounds : Rect,
               help : Proc(String, String?) = QuerySuggest::QL_HELP) : Nil
      return unless @open
      return @open = false if @items.empty? || bounds.w < MIN_W || bounds.h < 1
      down, h = placement(ay, bounds)
      return @open = false if h <= 0
      # `desc_col` scans every candidate; computed ONCE here rather than per row, which is what
      # `draw_row` calling it did — up to nine full scans of the list per frame.
      col = desc_col
      w = box_width(bounds, help, col)
      sync_scroll(h)
      x = ax.clamp(bounds.x, {bounds.right - w, bounds.x}.max)
      y0 = down ? ay + 1 : ay - h
      h.times { |i| draw_row(screen, x, y0 + i, w, @scroll + i, help, col) }
    end

    # Which way to grow, and how far. The flip-above branch does NOT fire for any current caller:
    # all three filter bars sit at the TOP of their pane and pass `bounds.y == ay + 1`, so `above`
    # is always -1 and the card always opens downward. It is kept because it is the only correct
    # answer for a caller that anchors lower, and because getting `h` right is what makes a short
    # pane close the popup (above) instead of painting outside its bounds.
    private def placement(ay : Int32, bounds : Rect) : {Bool, Int32}
      below = bounds.bottom - (ay + 1)
      above = ay - bounds.y
      down = below >= above
      {down, {@items.size, MAX_ROWS, {down ? below : above, 0}.max}.min}
    end

    # Wide enough for the widest ROW, floored so a one-word list still reads as a card and
    # clamped to what the pane can give. Measured by summing the same pieces `draw_row` paints,
    # in the same order: a width calculator that forgets one of them silently truncates the
    # piece that happens to be last — which is how the polarity marker cost every negated
    # candidate the tail of its description.
    private def box_width(bounds : Rect, help : Proc(String, String?), col : Int32) : Int32
      desc_w = @items.max_of { |c| QuerySuggest.describe_for(c, help).try(&.size) || 0 }
      ({1 + col + 1 + desc_w + 1, MIN_W}.max).clamp(1, bounds.w)
    end

    # Where the description column starts, relative to the candidate's own left edge. ONE column
    # for every row rather than wherever each candidate happens to end: a ragged second column in
    # a card this small reads as noise, and the whole reason the dropdown is worth its occlusion
    # is that the meanings are scannable.
    private def desc_col : Int32
      @items.max_of { |c| c.size + (QuerySuggest.negated?(c) ? EXCLUDES.size : 0) }
    end

    # `@items` is the candidate list `render` windows and `draw_row` indexes.
    private def sync_scroll(h : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@selected, @scroll, h, @items.size)
    end

    # One row: selection bar, the candidate, then its meaning. A NEGATED candidate says so, in
    # the same colour the inline row uses — the popup is a second view of one model, not a
    # second opinion about it.
    private def draw_row(screen : Screen, x : Int32, y : Int32, w : Int32, idx : Int32,
                         help : Proc(String, String?), col : Int32) : Nil
      cand = @items[idx]? || return
      active = idx == @selected
      bg = active ? Theme.accent_bg : Theme.elevated
      screen.fill(Rect.new(x, y, w, 1), bg)
      screen.cell(x, y, active ? '▎' : ' ', Theme.accent, bg)
      cx = screen.text(x + 1, y, cand, active ? Theme.text_bright : Theme.text, bg,
        width: {w - 1, 1}.max)
      # No `cx =`: the description below is placed at the SHARED column, not after this marker,
      # so the returned x is genuinely unused.
      screen.text(cx, y, EXCLUDES, Theme.focus_gold, bg, width: {x + w - cx, 0}.max) if QuerySuggest.negated?(cand)
      return unless why = QuerySuggest.describe_for(cand, help)
      # Aligned to the shared column, never to where THIS candidate ended.
      dx = x + 1 + col + 1
      screen.text(dx, y, why, Theme.muted, bg, width: {x + w - dx, 0}.max) if dx < x + w
    end
  end
end
