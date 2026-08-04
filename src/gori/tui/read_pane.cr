require "./screen"
require "./theme"
require "./frame"
require "./gutter"
require "./highlight"
require "./read_cursor"
require "./geometry"

module Gori::Tui
  # A scrollable READ-ONLY text pane: the state (`ReadCursor` + vertical scroll + horizontal
  # scroll + last drawn height), the draw (gutter, h-slice, selection band, block caret, scroll
  # gauge) and every gesture (arrows, ⇧arrows, Home/End/PgUp/PgDn, wheel, click, drag,
  # double-click, select-line, copy) in one place.
  #
  # WHY THIS EXISTS. Three panes had already grown their own copy of exactly this — the Decoder
  # OUTPUT, the Fuzzer RESULT detail and the History detail — each ~90 lines of the same
  # arithmetic, and the drift between them was a real bug: `DecoderView#output_scroll_view`
  # clamped `cx` against the line the caret was LEAVING while `FuzzerView#detail_scroll_view`,
  # the same method over the same widget, clamped it against the line it lands on (and carried a
  # comment about the `IndexError` that costs). Six MORE panes are scrollable and readable today
  # with nothing selectable — Comparer, Miner detail, Sequencer analysis/detail, Probe detail,
  # OAST callback detail, the Intercept read-only preview, Rewriter preview-out — so the choice
  # was one home or nine.
  #
  # THE SOURCE IS `(size, line_at)`, NEVER AN ARRAY. `ReadCursor` carries both shapes and says
  # why: the lazy provider is what keeps caret moves, wheel notches and selection painting from
  # materialising every off-screen line of a multi-MiB body. The Intercept preview reads through
  # a `Highlight::Windowed`; a pane holding `Array(String)` would have to build one.
  #
  # The PLAIN text is what the caret addresses, the selection spans and a copy produces.
  # `styled_at` is an OPTIONAL second provider for the draw only — the Fuzzer detail's coloured
  # overlay, the Intercept preview's syntax highlighting — because the two must be allowed to
  # disagree about colour while agreeing exactly about columns. Where a pane has only styled
  # lines (the windowed message views), `Highlight.plain` is the bridge.
  #
  # `styled_at` must be COLOUR ONLY: its span texts have to concatenate back to the same line
  # `line_at` returns, which is `Highlight`'s own cardinal rule (see its header). The component
  # leans on it — the block caret paints `plain[cx]`, and that is the glyph the reader sees
  # precisely because the two agree. A provider that changed the characters would put a different
  # letter in the caret cell than in the row around it.
  class ReadPane
    getter cursor : ReadCursor
    # First visible line, clamped by `render` against the height it actually drew.
    getter scroll : Int32 = 0
    # Horizontal offset in display columns (⇧←/→). Clamped by `render` to the widest row on
    # screen, so a pane whose long line scrolls off can always be scrolled back.
    getter xscroll : Int32 = 0
    # Interior height of the last `render`. `0` before the first frame — every gesture that
    # needs a viewport (page, wheel) is inert until then, which is what the panes did already.
    getter last_h : Int32 = 0

    @size = 0
    @line_at : (Int32 -> String) = ->(_i : Int32) { "" }

    # `gutter` draws 1-based line numbers (`Gutter`), like the Decoder OUTPUT and the Repeater
    # panes; a pane whose rows are not source lines (the Comparer's diff rows, a field list)
    # leaves it off.
    #
    # `line_select_only` drops the horizontal half of the selection: ←/→ still move the caret,
    # but a selection is always whole lines and a double-click takes nothing. For a pane whose
    # screen row is not one run of text — the Comparer draws TWO columns per row — a char
    # rectangle would address cells that are not next to each other on screen.
    def initialize(*, @gutter : Bool = false, @line_select_only : Bool = false)
      @cursor = ReadCursor.new
    end

    # Point the pane at its text. Call this when the CONTENT changes (a recompute, a new
    # selection in the list above, a mode flip), not every frame: it is the one place the
    # caret's bounds come from, and `reset_cursor` is how a pane says "this is different text".
    def source(size : Int32, line_at : Int32 -> String) : Nil
      @size = {size, 0}.max
      @line_at = line_at
    end

    def source(lines : Array(String)) : Nil
      source(lines.size, ->(i : Int32) { lines[i]? || "" })
    end

    def size : Int32
      @size
    end

    def empty? : Bool
      @size <= 0
    end

    def line(i : Int32) : String
      i >= 0 && i < @size ? @line_at.call(i) : ""
    end

    # Drop the caret, the selection and both scroll offsets — the pane is showing different
    # text now, so a line index from the old text means nothing in the new one.
    def reset : Nil
      @cursor.reset
      @scroll = 0
      @xscroll = 0
    end

    # --- keyboard -------------------------------------------------------------

    def move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if empty?
      if @line_select_only && dr != 0 && selecting
        # Whole-line growth: `ReadCursor#move`'s selecting branch already parks the caret at
        # EOL on a vertical step, which IS the line selection this mode wants.
        @cursor.move(dr, 0, @size, @line_at, selecting: true)
      else
        @cursor.move(dr, dc, @size, @line_at, selecting: selecting && !@line_select_only)
      end
      ensure_visible
    end

    # Home / End / PageUp / PageDown, with ⇧ extending. Returns false when `ev` is none of
    # them, so a caller can fall through to its own keymap.
    def motion_key(ev : Termisu::Event::Key) : Bool
      return false if empty?
      key = ev.key
      shift = ev.shift?
      page = {@last_h - 2, 1}.max
      case
      when key.home?      then @cursor.move_to(@cursor.cy, 0, selecting: shift)
      when key.end?       then @cursor.move_to(@cursor.cy, line(@cursor.cy.clamp(0, @size - 1)).size, selecting: shift)
      when key.page_up?   then @cursor.move(-page, 0, @size, @line_at, selecting: shift)
      when key.page_down? then @cursor.move(page, 0, @size, @line_at, selecting: shift)
      else                     return false
      end
      ensure_visible
      true
    end

    def select_line : Nil
      return if empty?
      @cursor.select_line(@size, @line_at)
      ensure_visible
    end

    def clear_selection : Nil
      @cursor.clear_selection
    end

    def selection? : Bool
      @cursor.selection?
    end

    # The selection, or — with nothing selected — the caret's own line. The `y` payload every
    # read pane in the tree offers.
    def copy_text : String
      return "" if empty?
      @cursor.selection_text(@size, @line_at) || @cursor.current_line(@size, @line_at)
    end

    # Every line, for the "copy the whole pane" fallback. Materialises the text on purpose —
    # it is going to the clipboard, which is one string either way.
    def copy_all : String
      return "" if empty?
      String.build do |io|
        (0...@size).each do |i|
          io << '\n' if i > 0
          io << @line_at.call(i)
        end
      end
    end

    # Viewport scroll (the wheel), independent of the caret: shift the window, then pull the
    # caret into it so `render`'s `ensure_visible` cannot snap the view back. `cy` is clamped
    # into the window BEFORE `cx` is measured, so the column is measured against the line the
    # caret lands on — the `IndexError` `FuzzerView#detail_scroll_view` documents.
    def scroll_view(step : Int32) : Nil
      return if @last_h <= 0 || @size <= @last_h
      @scroll = (@scroll + step).clamp(0, @size - @last_h)
      lo = @scroll
      hi = {@scroll + @last_h - 1, @size - 1}.min
      cy = @cursor.cy.clamp(lo, hi)
      @cursor.sync(cy, @cursor.cx.clamp(0, line(cy).size))
    end

    # ⇧←/→. Floored at 0 here; `render` clamps the upper bound to the widest row on screen.
    def hscroll(step : Int32) : Nil
      @xscroll = {@xscroll + step * 4, 0}.max
    end

    # At the top of the pane — the test a controller uses to decide whether ↑ should leave for
    # the pane above rather than move the caret.
    def at_top? : Bool
      @scroll <= 0 && @cursor.cy <= 0
    end

    # --- mouse ----------------------------------------------------------------

    # Place the caret at (mx, my) inside `rect` — the SAME rect `render` was given.
    # `selecting` is the drag half: the anchor stays where the press left it.
    def click(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      return if empty? || rect.empty?
      @cursor.click_to_cursor(rect, mx, my, @scroll, @size, @line_at, gutter_w(rect), @xscroll, selecting)
      # A line-select pane has no meaningful column, so a drag there grows whole lines.
      @cursor.select_line(@size, @line_at) if @line_select_only && selecting && @cursor.selection?
      ensure_visible
    end

    # Double-click: take the word under the pointer. Always false in `line_select_only` mode —
    # there is no single run of text under the pointer to take.
    def select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      return false if empty? || rect.empty? || @line_select_only
      took = @cursor.select_word_at(rect, mx, my, @scroll, @size, @line_at, gutter_w(rect), @xscroll)
      ensure_visible
      took
    end

    # --- render ---------------------------------------------------------------

    # The state half of `render`, for a pane that draws its OWN rows and so never calls it: the
    # Comparer paints two diff columns per row, and the Miner / Probe / Sequencer details paint
    # label-and-value fields. They still need a viewport height (pages, the wheel and the
    # selection-follow scroll are all measured in it) and they still need `scroll` clamped to the
    # text — so they call this where `render` would have gone, then read `scroll` and `cursor` to
    # place their own rows and their own band.
    #
    # Returns the first visible line, which is what such a painter loops from.
    def viewport_top(h : Int32) : Int32
      @last_h = h
      @scroll = @scroll.clamp(0, {@size - h, 0}.max)
      @scroll
    end

    # Whether `li` is inside the selection (or, with nothing selected, is the caret's row) — the
    # row-band test for a self-drawing pane. Char columns are deliberately not exposed here: a
    # pane that draws its own rows is one whose screen row is not a single run of the text.
    def row_marked?(li : Int32) : Bool
      if r = @cursor.selected_line_range
        li >= r[0] && li <= r[1]
      else
        li == @cursor.cy
      end
    end

    # Draw the pane into `rect` (the framed INTERIOR — pass what a `Frame.card` left inside).
    # `styled_at` supplies a coloured overlay per line; without it the plain line is drawn in
    # `fg`. The caret and the band are painted from the PLAIN line either way, so they land on
    # the cells the draw advanced over.
    def render(screen : Screen, rect : Rect, focused : Bool,
               styled_at : (Int32 -> Highlight::Line)? = nil,
               fg : Color = Theme.text, bg : Color = Theme.bg) : Nil
      return if rect.empty?
      viewport_top(rect.h)
      gw = gutter_w(rect)
      cw = {rect.w - gw, 0}.max
      ensure_visible if focused

      shown = (0...rect.h).compact_map { |i| (li = @scroll + i) < @size ? li : nil }
      # draw_width_upto, not display_width: these rows go out through `screen.text` /
      # `Highlight.draw`, which advance ≥1 cell per grapheme. A control byte scores 0 on the raw
      # measure, which used to pin the clamp short and leave the tail of such a line
      # unreachable. `_upto` keeps the per-frame early exit on a huge single line.
      widest = shown.max_of? { |li| Screen.draw_width_upto(@line_at.call(li), @xscroll + cw + 1) } || 0
      @xscroll = @xscroll.clamp(0, {widest - cw, 0}.max)

      # Built ONCE per frame rather than per row: this used to sit inside the per-row chrome
      # painter in two of the panes, i.e. rebuilt and thrown away `rect.h` times.
      spans = focused && @cursor.selection? ? @cursor.highlight_spans(@size, @line_at) : nil
      shown.each_with_index do |li, i|
        y = rect.y + i
        plain = @line_at.call(li)
        Gutter.draw(screen, rect.x, y, li, gw, current: focused && li == @cursor.cy) if gw > 0
        if styled_at
          sl = styled_at.call(li)
          sl = Highlight.slice_left(sl, @xscroll) if @xscroll > 0
          Highlight.draw(screen, rect.x + gw, y, sl, bg: bg, width: cw)
        else
          text = @xscroll > 0 ? Highlight.slice_left_text(plain, @xscroll) : plain
          screen.text(rect.x + gw, y, text, fg, bg, width: cw)
        end
        paint_chrome(screen, rect.x + gw, y, li, plain, spans, focused, cw)
      end
      Frame.scroll_gauge(screen, rect, @size, @scroll, focused, bg: bg)
    end

    # The selection band + the block caret for one drawn row, over whatever the base draw put
    # there. Both measure the PLAIN line with `Screen.draw_width`, which is what `screen.text`
    # and `Highlight.draw` advance by — so the tint covers the glyphs it addresses.
    private def paint_chrome(screen : Screen, x : Int32, y : Int32, li : Int32, plain : String,
                             spans : Array({Int32, Int32, Int32})?, focused : Bool, cw : Int32) : Nil
      return unless focused
      spans.try &.each do |(l, x0, x1)|
        paint_span_bg(screen, x, y, plain, x0, x1, cw) if l == li
      end
      return unless li == @cursor.cy
      cx = @cursor.cx.clamp(0, plain.size)
      px = x + Screen.draw_width(plain[0, cx]) - @xscroll
      return if px < x || px >= x + cw
      ch = cx < plain.size ? plain[cx] : ' '
      screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, y)
    end

    # Cluster-wise, matching the base draw and the caret. Summing `draw_width` over single
    # CHARS is the retired per-codepoint measure: it drifts right by each cluster's inflation
    # (1 column for a skin tone, 9 for a ZWJ family) and drawing char-by-char also shreds a
    # cluster across cells. Span edges snap outward so the tint covers whole glyphs.
    private def paint_span_bg(screen : Screen, x : Int32, y : Int32, plain : String,
                              x0 : Int32, x1 : Int32, cw : Int32) : Nil
      return if x0 >= x1
      a = Screen.cluster_start(plain, {x0, plain.size}.min)
      b = Screen.cluster_end(plain, {x1, plain.size}.min)
      px = x + Screen.draw_width(plain[0, a]) - @xscroll
      i = a
      while i < b
        e = Screen.cluster_end(plain, i + 1)
        seg = plain[i...e]
        w = Screen.draw_width(seg)
        screen.text(px, y, seg, Theme.text, Theme.accent_bg) if px >= x && px + w <= x + cw
        px += w
        i = e
      end
    end

    private def gutter_w(rect : Rect) : Int32
      @gutter ? {Gutter.width(@size), rect.w}.min : 0
    end

    # Keep the caret's line inside the window. Selection-follow, like every list in the tree.
    private def ensure_visible : Nil
      return if @last_h <= 0
      cy = @cursor.cy
      if cy < @scroll
        @scroll = cy
      elsif cy >= @scroll + @last_h
        @scroll = cy - @last_h + 1
      end
      @scroll = @scroll.clamp(0, {@size - @last_h, 0}.max)
    end
  end
end
