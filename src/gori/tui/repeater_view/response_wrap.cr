# The response pane's viewport: the soft-wrap memo (keyed on content width), the walkers that
# turn a {row, sub-row} anchor into drawn rows, and the scrolling that keeps the caret visible
# under wrap or under the horizontal offset that replaces it.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # Keep the caret's VISUAL row inside the pane. Line-indexed scrolling drifts the moment
  # anything wraps — the caret can be on the anchor line and still be a dozen drawn rows
  # off-screen — so the comparison and the re-anchor both happen in rows (Wrap).
  # Falls back to the line-based arithmetic before the first render, when no width is
  # known yet and nothing has been laid out to disagree with.
  private def ensure_resp_visible(view_h : Int32) : Nil
    return if view_h <= 0
    cy = @resp_cursor.cy
    cw = @resp_last_cw
    size, line_at, off = resp_drawn_source
    if cw <= 0 || size <= 0 || !resp_wrap?
      if cy < @scroll
        @scroll = cy
      elsif cy >= @scroll + view_h
        @scroll = cy - view_h + 1
      end
      @scroll = 0 if @scroll < 0
      # The horizontal half, and the only way sideways with wrap off: ⇧←/→ extends the read
      # selection here (the h-scroll binding is gone), so the caret is what pans the view.
      ensure_resp_visible_x(cw, size, line_at, off)
      return
    end
    @resp_xscroll = 0 # nothing sits off to the side of a wrapped row
    @scroll = @scroll.clamp(0, size - 1)
    fn = resp_layout_fn(cw, line_at)
    csub = fn.call(cy).row_of(@resp_cursor.cx + off)
    @scroll, @scroll_sub = Wrap.ensure_visible(@scroll, @scroll_sub, cy, csub, view_h, fn)
  end

  # Slide @resp_xscroll so the caret column stays inside [xscroll, xscroll + cw). Only ever
  # reached with wrap off; the wrapped branch returns before it and the render pins it to 0.
  #
  # Measured on the DRAWN line and at `cx + off`, exactly as the wrapped branch above: in
  # diff mode every row carries a `"+ "`/`"- "` decoration, so the bare column the cursor
  # holds sits `off` cells left of the one the pane actually draws it at. `Wrap.row_col` is
  # the measure — the same one `Highlight.slice_left` consumes the offset in and the draw
  # advances by — and the "is it even too wide" test stops at cw + 1 columns so a multi-MiB
  # minified line is never measured whole to answer "wider than the pane".
  # THE only writer of `@resp_xscroll` — see `HistoryView#ensure_detail_visible_x` for why a
  # second one (a per-frame clamp against the widest visible row) is not merely redundant but
  # actively wrong: its ceiling is one column short of what an end-of-line caret needs, so
  # the caret vanished on exactly the longest line on screen.
  private def ensure_resp_visible_x(cw : Int32, size : Int32,
                                    drawn_at : Int32 -> String, off : Int32) : Nil
    if cw <= 0 || size <= 0
      @resp_xscroll = 0
      return
    end
    line = drawn_at.call(@resp_cursor.cy.clamp(0, size - 1))
    if Screen.draw_width_upto(line, cw + 1) <= cw
      @resp_xscroll = 0 # the line fits whole — never hold an offset for it
      return
    end
    curx = Wrap.row_col(line, nil, 0, (@resp_cursor.cx + off).clamp(0, line.size))
    @resp_xscroll = curx if curx < @resp_xscroll
    @resp_xscroll = curx - cw + 1 if curx >= @resp_xscroll + cw
    @resp_xscroll = 0 if @resp_xscroll < 0
  end

  # The caret's visual row WITHIN its logical line, or 0 when nothing has been laid out yet
  # (hex, or before the first frame published a content width) — `at_top?`'s wrap half, the
  # twin of `HistoryView#detail_caret_sub`.
  #
  # Measured on the DRAWN line and with `cx + off`, exactly as `ensure_resp_visible` above
  # does: in diff mode every row carries a `"+ "`/`"- "` decoration, so the bare column the
  # cursor holds sits `off` cells left of the one the wrap was computed on.
  private def resp_caret_sub : Int32
    cw = @resp_last_cw
    return 0 if resp_hex_active? || cw <= 0 || !resp_wrap?
    size, drawn_at, off = resp_drawn_source
    cy = @resp_cursor.cy
    return 0 if size <= 0 || cy >= size
    resp_layout(cy, cw, drawn_at).row_of(@resp_cursor.cx + off)
  end

  # --- response soft wrap ----------------------------------------------------

  # Ceiling on the response wrap memo — see TextArea::WRAP_CACHE_CAP, same reasoning.
  RESP_WRAP_CACHE_CAP = 512

  # Whether the response pane lays a long line out as continuation rows or as one row per
  # line with the tail off to the right (`Settings.wrap_lines?`). Read LIVE at every mapping
  # rather than latched, so the Display toggle lands on the next frame; the memo survives the
  # flip untouched, a `Wrap::Layout` being a pure function of (line, width) that is simply
  # not consulted while wrap is off.
  private def resp_wrap? : Bool
    Settings.wrap_lines?
  end

  # The h-scroll offset as the ACTIVE model sees it — 0 while the pane wraps. The single gate
  # every consumer reads it through; see `HistoryView#detail_xscroll` for the unfocused-pane
  # hazard it closes.
  private def resp_xscroll : Int32
    resp_wrap? ? 0 : @resp_xscroll
  end

  # Drop the wrap memo and put the anchor back on a first row — BOTH halves of it, since the
  # live preference decides which one is in use. Called from every site that swaps what the
  # pane is showing (a new result, a mode toggle, reveal/pretty, a fresh load) — the same
  # sites that used to zero the horizontal offset, which is not a coincidence: those are
  # exactly the moments the old layout stops describing the pane.
  private def resp_wrap_reset : Nil
    @scroll_sub = 0
    @resp_xscroll = 0
    @resp_wrap.clear
    @resp_text_i = -1 # keyed by row index like the wrap memo — see `resp_line_text`
  end

  # Publish the geometry the active response pane just drew with, so hit-testing and the
  # scroll walkers key the wrap memo on exactly the width the rows were laid out at.
  private def resp_record_metrics(gw : Int32, cw : Int32) : Nil
    @resp_last_gw = gw
    @resp_last_cw = cw
  end

  private def resp_layout(li : Int32, cw : Int32, line_at : Int32 -> String) : Wrap::Layout
    if @resp_wrap_w != cw
      @resp_wrap.clear
      @resp_wrap_w = cw
    end
    if hit = @resp_wrap[li]?
      return hit
    end
    @resp_wrap.clear if @resp_wrap.size >= RESP_WRAP_CACHE_CAP
    @resp_wrap[li] = Wrap.layout(line_at.call(li), cw)
  end

  private def resp_layout_fn(cw : Int32, line_at : Int32 -> String) : Int32 -> Wrap::Layout
    ->(i : Int32) { resp_layout(i, cw, line_at) }
  end

  # The response pane's drawn rows for an `h`-row viewport at content width `cw`. Without
  # wrap this is the identity the pane had before it learned to wrap — one row per logical
  # row from the anchor, holding the WHOLE line — and the horizontal offset is applied at the
  # draw instead, which keeps every consumer of these rows (the click inverse, the caret, the
  # band, the search overdraw) on one model in both modes.
  private def resp_rows(cw : Int32, h : Int32, size : Int32, line_at : Int32 -> String) : Array(Wrap::Row)
    return [] of Wrap::Row if size <= 0 || h <= 0 || cw <= 0
    @scroll = @scroll.clamp(0, size - 1)
    unless resp_wrap?
      @scroll = @scroll.clamp(0, {size - h, 0}.max)
      return Wrap.plain_rows(@scroll, h, size, line_at)
    end
    Wrap.rows(@scroll, @scroll_sub, h, size, resp_layout_fn(cw, line_at))
  end

  # Rows for a response card that is NOT the one holding the cursor — only ever the WS
  # HANDSHAKE/TRANSCRIPT pair, whichever half `@resp_pane` isn't on. Pinned to row 0 with a
  # LOCAL layout: it has no anchor to scroll and none to pan, which is what it always did (7
  # rows showing a 4-5 line head). Both cards render every frame, so an inactive one reaching
  # for the shared anchor would fight the active one for it.
  private def resp_static_rows(cw : Int32, h : Int32, size : Int32,
                               line_at : Int32 -> String) : Array(Wrap::Row)
    return Wrap.plain_rows(0, h, size, line_at) unless resp_wrap?
    Wrap.rows(0, 0, h, size, ->(i : Int32) { Wrap.layout(line_at.call(i), cw) })
  end

  # What the pane actually DRAWS per row, which is what the wrap has to be computed on.
  # Identical to `resp_line_source` in every mode but DIFF, where each row is prefixed
  # with a 2-column "+ "/"- " decoration: those columns shift every break, so wrapping the
  # bare text there would put the anchor, the click inverse and the draw on three
  # different grids. The third element is that decoration's width, the single constant
  # that converts between the two coordinate systems (see `render_diff`).
  private def resp_drawn_source : {Int32, Proc(Int32, String), Int32}
    if transcript_rows?.nil? && !@reveal && @resp_mode == :diff
      data = diff_lines
      return {data.size, ->(i : Int32) do
        d = data[i]
        prefix = case d.kind
                 when .add? then '+'
                 when .del? then '-'
                 else            ' '
                 end
        "#{prefix} #{d.text}"
      end, DIFF_PREFIX_COLS}
    end
    size, line_at = resp_line_source
    {size, line_at, 0}
  end
end
