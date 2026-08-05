require "./screen"
require "./theme"
require "./frame"
require "./gutter"
require "./highlight"
require "./read_cursor"
require "./geometry"
require "./wrap"

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
    # Ceiling on the per-line wrap memo — mirrors `TextArea::WRAP_CACHE_CAP` and exists for the
    # same reason: a viewport is tens of rows, so this covers it many times over while a pane
    # scrolled through a huge body can never accumulate an entry per line.
    WRAP_CACHE_CAP = 512

    getter cursor : ReadCursor
    # First visible line, clamped by `render` against the height it actually drew. Under wrap it
    # is the first half of the `(line, sub-row)` anchor — see `scroll_sub`.
    getter scroll : Int32 = 0
    # Which VISUAL row of line `scroll` sits on the pane's top line. Always 0 without wrap.
    #
    # The pair is the anchor rather than a flat visual-row index for the reason `Wrap`'s header
    # gives: a flat index can only be produced by wrapping every line from the top of the
    # document, an O(document) pass on every width change over bodies that reach multiple MB.
    # Every walk below is O(the rows it is asked to move).
    getter scroll_sub : Int32 = 0
    # Horizontal offset in display columns (⇧←/→). Clamped by `render` to the widest row on
    # screen, so a pane whose long line scrolls off can always be scrolled back. Pinned at 0
    # for good on a wrapping pane — there is nothing off to the side of a wrapped row.
    getter xscroll : Int32 = 0
    # Interior height of the last `render`. `0` before the first frame — every gesture that
    # needs a viewport (page, wheel) is inert until then, which is what the panes did already.
    getter last_h : Int32 = 0
    # Content width (past the gutter) of the last `render`. The wrap mappings that run OUTSIDE
    # render — a caret step, a wheel notch, `at_top?` — all need it, and guessing one would put
    # the caret on a different row than the draw did.
    getter last_cw : Int32 = 0
    # The rows `render` last laid down, for a caller that needs to invert the draw.
    getter last_rows : Array(Wrap::Row) = [] of Wrap::Row

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
    #
    # `wrap` turns on Burp-style soft wrap: a line too wide for the pane spills onto
    # continuation rows and the line number rides the first of them. It is opt-in, and it is
    # mutually exclusive with the `viewport_top` self-drawing shape below — those panes place
    # their own rows from a logical line index, so a wrapped anchor would name a row they never
    # draw. Every pane that calls `render` should take it; the four that self-draw must not.
    def initialize(*, @gutter : Bool = false, @line_select_only : Bool = false,
                   @wrap : Bool = false)
      @cursor = ReadCursor.new
      # Per-line wrap memo, keyed on the content width it was built for. Dropped by `source`
      # (the content is different text now) and by a width change.
      @wrap_cache = {} of Int32 => Wrap::Layout
      @wrap_w = -1
    end

    # Point the pane at its text. Call this when the CONTENT changes (a recompute, a new
    # selection in the list above, a mode flip), not every frame: it is the one place the
    # caret's bounds come from, and `reset_cursor` is how a pane says "this is different text".
    #
    # It also drops the wrap memo, which is why "not every frame" is worth more than style here:
    # a pane that re-points itself each frame re-wraps its visible window each frame. That is
    # still correct and still bounded by the viewport — the three panes that do it hold a URL
    # list, a callback dump and a preview sample — but the two that can hold megabytes (the
    # Decoder output, the Intercept preview) call this only when the bytes actually change, and
    # they are the ones the memo is for.
    def source(size : Int32, line_at : Int32 -> String) : Nil
      @size = {size, 0}.max
      @line_at = line_at
      drop_wrap_cache
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
      @scroll_sub = 0
      @xscroll = 0
      drop_wrap_cache
    end

    # --- keyboard -------------------------------------------------------------

    def move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if empty?
      if @line_select_only && dr != 0 && selecting
        # Whole-line growth, asked for explicitly. This used to lean on `ReadCursor#move`'s
        # selecting branch parking the caret at EOL, which only produced a line selection
        # going DOWN and from column 0 — see `ReadCursor#move`. `extend_lines` sets both
        # boundary columns by direction, so ⇧↑ selects whole lines too.
        #
        # This arm is checked FIRST, and it never wraps: a `line_select_only` pane draws its
        # own rows through `viewport_top`, so `wrapping?` is false there by construction.
        @cursor.extend_lines(dr, @size, @line_at)
      elsif dr != 0 && (target = visual_row_target(dr))
        # ↑/↓ step one VISUAL row under wrap, matching what the arrow does in every other
        # wrapped pane. Stepping a logical LINE would jump the caret over every continuation
        # row the pane is drawing between one line number and the next — rows that are on
        # screen and that nothing but this arrow could reach.
        @cursor.move_to(target[0], target[1], selecting: selecting && !@line_select_only)
      else
        @cursor.move(dr, dc, @size, @line_at, selecting: selecting && !@line_select_only)
      end
      ensure_visible
    end

    # Home / End / PageUp / PageDown, with ⇧ extending. Returns false when `ev` is none of
    # them, so a caller can fall through to its own keymap.
    #
    # Home/End are LOGICAL line ends, not visual row ends — matching `TextArea#home` /
    # `#end_of_line`, so the two modes of a pane that has both agree. On a wrapped line that
    # means End lands on its LAST row and Home on its first, and the shared `ensure_visible`
    # below scrolls the anchor to whichever visual row the caret ended up on.
    #
    # The two page arms `return true` early ON PURPOSE: they go through `move`, which already
    # ran `ensure_visible` (and, on a wrapping pane, paged by DRAWN rows rather than logical
    # lines — the reason ↑/↓ step visual rows too). Falling through would run it twice.
    def motion_key(ev : Termisu::Event::Key) : Bool
      return false if empty?
      key = ev.key
      shift = ev.shift?
      page = {@last_h - 2, 1}.max
      case
      when key.home?      then @cursor.move_to(@cursor.cy, 0, selecting: shift)
      when key.end?       then @cursor.move_to(@cursor.cy, line(@cursor.cy.clamp(0, @size - 1)).size, selecting: shift)
      when key.page_up?   then move(-page, 0, selecting: shift); return true
      when key.page_down? then move(page, 0, selecting: shift); return true
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
      return if @last_h <= 0
      if wrapping?
        scroll_view_wrapped(step)
        return
      end
      return if @size <= @last_h
      @scroll = (@scroll + step).clamp(0, @size - @last_h)
      lo = @scroll
      hi = {@scroll + @last_h - 1, @size - 1}.min
      cy = @cursor.cy.clamp(lo, hi)
      @cursor.sync(cy, @cursor.cx.clamp(0, line(cy).size))
    end

    # ⇧←/→. Floored at 0 here; `render` clamps the upper bound to the widest row on screen.
    # Inert on a wrapping pane: nothing sits off to the side of a wrapped row, and a stored
    # offset the renderer no longer reads would only fight the clamp every frame.
    def hscroll(step : Int32) : Nil
      return if @wrap
      @xscroll = {@xscroll + step * 4, 0}.max
    end

    # At the top of the pane — the test a controller uses to decide whether ↑ should leave for
    # the pane above rather than move the caret.
    #
    # Under wrap that is the first VISUAL row, not the first logical line: a caret three rows
    # into a wrapped line 0 still has three rows above it inside this pane, and stealing its ↑
    # would make exactly those rows unreachable from the keyboard.
    def at_top? : Bool
      return false unless @scroll <= 0 && @scroll_sub <= 0 && @cursor.cy <= 0
      return true unless wrapping?
      layout_of(0, @last_cw).row_of(@cursor.cx) == 0
    end

    # --- mouse ----------------------------------------------------------------

    # Place the caret at (mx, my) inside `rect` — the SAME rect `render` was given.
    # `selecting` is the drag half: the anchor stays where the press left it.
    def click(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      return if empty? || rect.empty?
      # A drag that has left the pane through the TOP scrolls the view up under it, one row per
      # motion report, so a selection can be grown past the first visible row. Downward already
      # worked — the hit test puts the caret past the window's last row and `ensure_visible`
      # follows it — while upward pinned to row 0 and stopped there, so a range taller than the
      # pane could only ever be dragged in one direction. The anchor is moved DIRECTLY rather
      # than through `scroll_view`, which ends by pulling the caret into the window and would
      # undo the placement two lines below.
      #
      # Under wrap the step is in VISUAL rows, walked through the anchor: `@scroll + row` is a
      # logical line index, and on a wrapped pane that skips a whole line's worth of rows per
      # motion report instead of one.
      row = my - rect.y
      if row < 0 && selecting
        if wrapping?
          @scroll, @scroll_sub = Wrap.step_back(@scroll, @scroll_sub, -row, layout_fn(@last_cw))
        else
          @scroll = {@scroll + row, 0}.max
        end
      end
      place_caret_at(rect, mx, my, selecting)
      # A line-select pane has no meaningful column, so a drag there grows whole lines — from
      # the row the PRESS landed on. It used to call `select_line`, which re-anchors at the
      # caret's own row: every motion event destroyed the press anchor, so dragging across
      # eight rows of the Comparer selected (and copied) only the row under the pointer.
      @cursor.extend_lines_to(@cursor.cy, @size, @line_at) if @line_select_only && selecting
      ensure_visible
    end

    # Double-click: take the word under the pointer. Always false in `line_select_only` mode —
    # there is no single run of text under the pointer to take.
    def select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      return false if empty? || rect.empty? || @line_select_only
      # The hit test is `place_caret_at`'s, not `ReadCursor#select_word_at`'s: that one resolves
      # the row as `scroll + row`, which on a wrapping pane names a line that is not drawn
      # there — so a double-click on a continuation row took a word out of the wrong line.
      place_caret_at(rect, mx, my, false)
      took = @cursor.select_word_at_cursor(@size, @line_at)
      ensure_visible
      took
    end

    # The caret half of both mouse gestures. Without wrap this is `ReadCursor`'s own hit test;
    # with it, the row list the draw laid down is inverted instead.
    private def place_caret_at(rect : Rect, mx : Int32, my : Int32, selecting : Bool) : Nil
      gw = gutter_w(rect)
      unless wrapping?
        @cursor.click_to_cursor(rect, mx, my, @scroll, @size, @line_at, gw, @xscroll, selecting)
        return
      end
      row = my - rect.y
      # A drag above the pane pins to its first visible row (the pointer left the top edge with
      # the button down); a plain click there belongs to whatever is drawn above.
      if row < 0
        return unless selecting
        row = 0
      end
      # Rebuilt from the same rect and the same anchor `render` used rather than read off
      # `last_rows`, so the mapping also holds for a click that arrives before the first frame
      # and there is exactly one definition of where a row begins.
      rows = visible_rows({rect.w - gw, 0}.max, rect.h)
      return if rows.empty?
      vr = rows[row]? || rows[rows.size - 1]
      # `Wrap.row_index` is the exact inverse of `Wrap.row_col`, the measure the draw, the
      # caret and the band all share — so a click lands on the cell the caret would paint, on
      # a continuation row as much as on a first one. It clamps to the row's own end, so a
      # click past the text of a wrapped row stops at the break instead of running into the
      # next row's characters.
      #
      # `nearest: true` because this is a POINTER: it rounds to the closer edge of the cluster
      # the column lands in, so the right half of a wide glyph resolves to the position AFTER
      # it. Without it half of every pointer position over CJK or Hangul lands a character
      # short. Same rule the unwrapped branch gets from `Screen.column_for_click`, and the same
      # one `TextArea#click_to_cursor` passes; the caret's own ↓ deliberately does not (a goal
      # column rounded up drifts one glyph right per row).
      @cursor.move_to(vr.li,
        Wrap.row_index(line(vr.li), nil, vr.a, vr.b, mx - (rect.x + gw), nearest: true),
        selecting: selecting)
    end

    # --- render ---------------------------------------------------------------

    # The state half of `render`, for a pane that draws its OWN rows and so never calls it: the
    # Comparer paints two diff columns per row, and the Miner / Probe / Sequencer details paint
    # label-and-value fields. They still need a viewport height (pages, the wheel and the
    # selection-follow scroll are all measured in it) and they still need `scroll` clamped to the
    # text — so they call this where `render` would have gone, then read `scroll` and `cursor` to
    # place their own rows and their own band.
    #
    # Returns the first visible line, which is what such a painter loops from. A pane on this
    # path must not enable `wrap`: it maps a logical line index straight onto a screen row, and
    # under wrap that mapping is exactly the one that stops holding.
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
      @last_h = rect.h
      gw = gutter_w(rect)
      cw = {rect.w - gw, 0}.max
      @last_cw = cw
      clamp_anchor(cw, rect.h)
      ensure_visible if focused

      rows = visible_rows(cw, rect.h)
      @last_rows = rows
      clamp_xscroll(rows, cw)
      # Built ONCE per frame rather than per row: this used to sit inside the per-row chrome
      # painter in two of the panes, i.e. rebuilt and thrown away `rect.h` times.
      spans = focused && @cursor.selection? ? @cursor.highlight_spans(@size, @line_at) : nil
      # `line_at` is called once per LOGICAL line, not once per drawn row: a wrapped line can
      # fill the whole viewport, and materialising it per row would multiply the cost of the one
      # case wrap exists to display.
      cached_li = -1
      cached_line = ""
      rows.each_with_index do |vr, i|
        if vr.li != cached_li
          cached_li = vr.li
          cached_line = @line_at.call(vr.li)
        end
        draw_row(screen, rect, rect.y + i, vr, cached_line, gw, cw, focused, styled_at, fg, bg)
        paint_chrome(screen, rect.x + gw, rect.y + i, vr, cached_line, spans, focused, cw)
      end
      # The gauge stays in LOGICAL lines under wrap — a deliberate approximation, matching
      # `TextArea#render`: it is a proportion indicator, not a coordinate.
      Frame.scroll_gauge(screen, rect, @size, @scroll, focused, bg: bg)
    end

    # The vertical anchor, clamped to the text: a plain line index without wrap, the
    # `(line, sub-row)` pair with it.
    private def clamp_anchor(cw : Int32, h : Int32) : Nil
      if wrapping?
        @xscroll = 0 # `wrap` has no sideways — pinned here as well as in `hscroll`
        clamp_wrapped_anchor(cw, h)
      else
        @scroll = @scroll.clamp(0, {@size - h, 0}.max)
      end
    end

    # The h-scroll ceiling: the widest row currently on screen, so a pane whose long line
    # scrolled off can always be scrolled back. Inert under wrap (nothing is off to the side).
    #
    # draw_width_upto, not display_width: these rows go out through `screen.text` /
    # `Highlight.draw`, which advance ≥1 cell per grapheme. A control byte scores 0 on the raw
    # measure, which used to pin the clamp short and leave the tail of such a line unreachable.
    # `_upto` keeps the per-frame early exit on a huge single line.
    private def clamp_xscroll(rows : Array(Wrap::Row), cw : Int32) : Nil
      return if wrapping?
      widest = rows.max_of? { |vr| Screen.draw_width_upto(@line_at.call(vr.li), @xscroll + cw + 1) } || 0
      @xscroll = @xscroll.clamp(0, {widest - cw, 0}.max)
    end

    # One drawn row: its gutter cell and its slice of `plain`, coloured through `styled_at` when
    # the caller supplied one. The chrome (band + caret) goes over the top of it separately.
    private def draw_row(screen : Screen, rect : Rect, y : Int32, vr : Wrap::Row, plain : String,
                         gw : Int32, cw : Int32, focused : Bool,
                         styled_at : (Int32 -> Highlight::Line)?, fg : Color, bg : Color) : Nil
      if gw > 0
        # The line number rides the FIRST visual row of a logical line and nothing else (Burp
        # style). A continuation row gets a blank of the same width rather than no write at all,
        # so the text column stays put and no stale digits survive there.
        if vr.sub == 0
          Gutter.draw(screen, rect.x, y, vr.li, gw, current: focused && vr.li == @cursor.cy)
        else
          screen.text(rect.x, y, " " * {gw - 1, 0}.max, Theme.muted, width: gw)
        end
      end
      whole = vr.a == 0 && vr.b >= plain.size
      if styled_at
        sl = styled_at.call(vr.li)
        # Char offsets, not columns: `Wrap::Layout` decided the break by walking clusters and
        # handed back char indices, so slicing by column here would re-derive it with a second
        # measure — and the colours would land off the glyphs they belong to.
        sl = Highlight.slice_chars(sl, vr.a, vr.b) unless whole
        sl = Highlight.slice_left(sl, @xscroll) if @xscroll > 0
        Highlight.draw(screen, rect.x + gw, y, sl, bg: bg, width: cw)
      else
        text = whole ? plain : plain[vr.a...vr.b]
        text = Highlight.slice_left_text(text, @xscroll) if @xscroll > 0
        screen.text(rect.x + gw, y, text, fg, bg, width: cw)
      end
    end

    # The selection band + the block caret for one drawn row, over whatever the base draw put
    # there. Both measure the PLAIN line with `Wrap.row_col`, which is what `screen.text` and
    # `Highlight.draw` advance by — so the tint covers the glyphs it addresses.
    private def paint_chrome(screen : Screen, x : Int32, y : Int32, vr : Wrap::Row, plain : String,
                             spans : Array({Int32, Int32, Int32})?, focused : Bool, cw : Int32) : Nil
      return unless focused
      # Each span is clipped to the ROW, so a selection crossing a wrap break tints to the end
      # of one row and resumes on the next; clipped to the LINE it would be painted once, at
      # the first row's columns, and the rest would read as unselected.
      spans.try &.each do |(l, x0, x1)|
        next unless l == vr.li
        paint_span_bg(screen, x, y, plain, {x0, vr.a}.max, {x1, vr.b}.min, vr.a, cw)
      end
      return unless vr.li == @cursor.cy
      cx = @cursor.cx.clamp(0, plain.size)
      # The caret belongs to exactly one row: the one whose slice contains it, with the end of
      # a wrapped row losing to the row it starts (`Wrap::Layout#row_of`'s rule, spelled out
      # here because `ReadCursor` holds no layout of its own).
      return unless cx >= vr.a && (cx < vr.b || vr.b >= plain.size)
      px = x + Wrap.row_col(plain, nil, vr.a, cx) - @xscroll
      return if px < x || px >= x + cw
      ch = cx < plain.size ? plain[cx] : ' '
      screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, y)
    end

    # Cluster-wise, matching the base draw and the caret. Summing `draw_width` over single
    # CHARS is the retired per-codepoint measure: it drifts right by each cluster's inflation
    # (1 column for a skin tone, 9 for a ZWJ family) and drawing char-by-char also shreds a
    # cluster across cells. Span edges snap outward so the tint covers whole glyphs.
    #
    # `row_start` is the char index the drawn row begins at — 0 for an unwrapped line, the wrap
    # break for a continuation row. Columns are measured from THERE, so a tint on a
    # continuation row starts at the pane's left edge like the text it covers.
    private def paint_span_bg(screen : Screen, x : Int32, y : Int32, plain : String,
                              x0 : Int32, x1 : Int32, row_start : Int32, cw : Int32) : Nil
      return if x0 >= x1
      a = Screen.cluster_start(plain, {x0, plain.size}.min)
      b = Screen.cluster_end(plain, {x1, plain.size}.min)
      px = x + Wrap.row_col(plain, nil, row_start, a) - @xscroll
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
      if wrapping?
        cw = @last_cw
        @scroll = @scroll.clamp(0, {@size - 1, 0}.max)
        csub = layout_of(@cursor.cy, cw).row_of(@cursor.cx)
        @scroll, @scroll_sub = Wrap.ensure_visible(@scroll, @scroll_sub, @cursor.cy, csub, @last_h, layout_fn(cw))
        return
      end
      cy = @cursor.cy
      if cy < @scroll
        @scroll = cy
      elsif cy >= @scroll + @last_h
        @scroll = cy - @last_h + 1
      end
      @scroll = @scroll.clamp(0, {@size - @last_h, 0}.max)
    end

    # --- soft-wrap layout ------------------------------------------------------
    # Everything below is inert (or trivially one-row-per-line) while `wrap` is off.

    # Wrap is only meaningful once a render has told us how wide the content column is — every
    # mapping outside render needs that width, and guessing one would put the caret on a
    # different row than the draw did.
    private def wrapping? : Bool
      @wrap && @last_cw > 0 && @size > 0
    end

    private def drop_wrap_cache : Nil
      @wrap_cache.clear
      @wrap_w = -1
    end

    # The wrap of line `li` at content width `cw`, memoized on (content, cw). See `source` for
    # what invalidates it and why the invalidation is the caller's to time.
    private def layout_of(li : Int32, cw : Int32) : Wrap::Layout
      if @wrap_w != cw
        @wrap_cache.clear
        @wrap_w = cw
      end
      if hit = @wrap_cache[li]?
        return hit
      end
      @wrap_cache.clear if @wrap_cache.size >= WRAP_CACHE_CAP
      @wrap_cache[li] = Wrap.layout(line(li), cw)
    end

    private def layout_fn(cw : Int32) : Int32 -> Wrap::Layout
      ->(i : Int32) { layout_of(i, cw) }
    end

    # The rows the pane shows, top to bottom. Without wrap this is the identity it always was:
    # one row per logical line from `@scroll`, `sub` 0, the whole line.
    private def visible_rows(cw : Int32, h : Int32) : Array(Wrap::Row)
      unless wrapping?
        rows = Array(Wrap::Row).new({h, 0}.max)
        return rows if h <= 0
        (0...h).each do |i|
          li = @scroll + i
          break if li >= @size
          rows << Wrap::Row.new(li, 0, 0, line(li).size)
        end
        return rows
      end
      @scroll = @scroll.clamp(0, @size - 1)
      Wrap.rows(@scroll, @scroll_sub, h, @size, layout_fn(cw))
    end

    # The wrapped equivalent of clamping `@scroll` to `size - h`: refuse an anchor further down
    # than the one that puts the buffer's LAST visual row on the pane's bottom line. Found by
    # walking back one viewport from that row, so it costs O(h) and never counts the document.
    private def clamp_wrapped_anchor(cw : Int32, h : Int32) : Nil
      @scroll = @scroll.clamp(0, @size - 1)
      mli, msub = Wrap.max_anchor(@size, h, layout_fn(cw))
      if @scroll > mli || (@scroll == mli && @scroll_sub > msub)
        @scroll = mli
        @scroll_sub = msub
      end
    end

    # Wheel under soft wrap: `step` is VISUAL rows, so one notch moves one drawn row even when
    # that row is the middle of a wrapped line. The anchor walks; nothing counts the buffer's
    # total rows.
    private def scroll_view_wrapped(step : Int32) : Nil
      cw = @last_cw
      return if cw <= 0
      fn = layout_fn(cw)
      @scroll, @scroll_sub = if step < 0
                               Wrap.step_back(@scroll, @scroll_sub, -step, fn)
                             else
                               Wrap.step_forward(@scroll, @scroll_sub, step, @size, fn)
                             end
      clamp_wrapped_anchor(cw, @last_h)
      # Pull the caret into the new window so `render`'s `ensure_visible` doesn't snap the view
      # straight back (mirrors the unwrapped branch). The comparison has to be in VISUAL rows: a
      # caret on line 0 is "inside" a window starting at row 3 of line 0 only by logical-line
      # arithmetic, and that arithmetic is what made the wheel fight `ensure_visible` to a halt.
      rows = visible_rows(cw, @last_h)
      return if rows.empty?
      first = rows[0]
      last = rows[rows.size - 1]
      cy, cx = @cursor.cy, @cursor.cx
      if cy < first.li || (cy == first.li && cx < first.a)
        cy, cx = first.li, first.a
      elsif cy > last.li || (cy == last.li && layout_of(last.li, cw).row_of(cx) > last.sub)
        cy, cx = last.li, last.a
      end
      @cursor.sync(cy, cx.clamp(0, line(cy).size))
    end

    # Where the caret would land `dr` VISUAL rows away, or nil when this pane has nothing to
    # wrap (soft wrap off, or no render has measured the content width yet) — in which case a
    # visual row IS a logical line and the caller's plain step is already right.
    private def visual_row_target(dr : Int32) : {Int32, Int32}?
      return nil unless wrapping?
      return nil if dr == 0
      cw = @last_cw
      Wrap.step_caret(@cursor.cy, @cursor.cx, dr, @size, @line_at, layout_fn(cw))
    end
  end
end
