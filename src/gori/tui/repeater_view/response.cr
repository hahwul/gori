# The response pane's own state: which card of a split column is active, response ⇄ diff, the
# hex dump, and every way the anchor/caret moves through it (arrows, page, edges, the wheel,
# and the crossings into the neighbouring card).
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # ^T on the RESPONSE column: toggle the active card (handshake ⇄ transcript). No-op outside
  # a WebSocket tab. Returns the new active pane so the controller can name it in a toast.
  def toggle_resp_pane : Symbol
    switch_resp_pane(@resp_pane == :transcript ? :handshake : :transcript)
    @resp_pane
  end

  # Change the active RESPONSE card. The two panes are different DOCUMENTS behind one cursor
  # and one scroll anchor, so the swap has three parts and all three are load-bearing:
  #
  #   * the outgoing pane's {scroll, scroll_sub, cy, cx} is parked and the incoming pane's is
  #     restored, so crossing back lands where you left (what the request column gets for
  #     free from each TextArea holding its own);
  #   * the wrap memo is dropped. It is keyed by LINE INDEX (guarded only on width), so line 3
  #     of the transcript would otherwise hand back a layout computed for line 3 of the
  #     handshake head — the anchor, the click inverse and the draw all reading one memo built
  #     from the wrong text; and
  #   * the selection is cleared. An anchor cannot span two documents, exactly as on the
  #     request side.
  private def switch_resp_pane(to : Symbol) : Nil
    return unless resp_split?
    return if to == @resp_pane
    parked = @resp_alt
    @resp_alt = {@scroll, @scroll_sub, @resp_cursor.cy, @resp_cursor.cx}
    @resp_pane = to
    @resp_cursor.clear_selection
    resp_wrap_reset # drops the memo AND zeroes @scroll_sub — restore after, not before
    @scroll = parked[0]
    @resp_cursor.sync(parked[2], parked[3])
    clamp_resp_cursor
  end

  # Pull the parked anchor + caret back inside the pane being restored into. Both documents
  # change out from under a parked position — a resend rebuilds the transcript AND re-seeds the
  # handshake head — so a caret parked at line 40 can come back to a 3-line document.
  #
  # `@scroll_sub` is deliberately NOT restored, only zeroed (by `resp_wrap_reset` above): a
  # sub-row is an index INTO a specific line's wrap layout, so the only way to carry one across
  # a park is to prove the line still wraps the same way, and nothing here can. Reading a stale
  # one is exactly what `scroll`'s own comment refuses to do ("a carried sub-row would be read
  # against a line that was never laid out at that row"). The cost is at most one wrapped row of
  # remembered scroll position; the alternative is tracking invalidation across every site that
  # replaces either document.
  private def clamp_resp_cursor : Nil
    size, line_at = resp_line_source
    if size <= 0
      @resp_cursor.sync(0, 0)
      @scroll = 0
      return
    end
    cy = @resp_cursor.cy.clamp(0, size - 1)
    @resp_cursor.sync(cy, @resp_cursor.cx.clamp(0, line_at.call(cy).size))
    @scroll = @scroll.clamp(0, size - 1)
  end

  # --- response pane (focus == :response) ---
  def toggle_resp_mode : Nil
    @resp_mode = @resp_mode == :response ? :diff : :response
    @scroll = 0
    resp_wrap_reset
  end

  # 'x' toggles a raw hex dump of the response bytes (overrides response/diff).
  def toggle_resp_hex : Nil
    @resp_hex = !@resp_hex
    @scroll = 0 # row-based offset differs from the line-based one
    resp_wrap_reset
  end

  getter? resp_hex : Bool

  # Whether Pretty actually reflowed the current response body (drives the chip).
  # resp_view memoizes it; reading forces the (memoized) build so it's current.
  def resp_pretty_applied? : Bool
    resp_view
    @resp_pretty_applied
  end

  # Combined head+body of the last result (hex source), cached; nil when not sent
  # or errored. Invalidated when a new result is applied (reset_result_caches).
  private def resp_hex_bytes : Bytes?
    return @resp_hex_bytes if @resp_hex_bytes
    result = @result
    return nil unless result && result.ok?
    @resp_hex_bytes = combine(result.head, result.body)
  end

  # Scroll the response pane by `delta` DRAWN rows. In hex the pane draws its own fixed
  # rows and there is nothing to wrap, so that mode keeps the plain row offset.
  def scroll(delta : Int32) : Nil
    if resp_hex_active? || @resp_last_cw <= 0 || !resp_wrap?
      @scroll = (@scroll + delta).clamp(0, {resp_line_count - 1, 0}.max)
      @scroll_sub = 0 # the anchor line moved by whole lines; a carried sub-row would
      return          # be read against a line that was never laid out at that row
    end
    size, line_at, _ = resp_drawn_source
    return if size <= 0
    fn = resp_layout_fn(@resp_last_cw, line_at)
    @scroll = @scroll.clamp(0, size - 1)
    @scroll, @scroll_sub = if delta < 0
                             Wrap.step_back(@scroll, @scroll_sub, -delta, fn)
                           else
                             Wrap.step_forward(@scroll, @scroll_sub, delta, size, fn)
                           end
  end

  # Response READ: move caret (and optional selection). Scroll follows the caret.
  # Lazy line source — vertical steps only materialise the destination line.
  #
  # ↑/↓ step one VISUAL row (see `resp_visual_target`), like the request editor's.
  def resp_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
    return unless resp_navigable?
    return if dc == 0 && try_cross_resp_pane(dr)
    size, line_at = resp_line_source
    return if size <= 0
    if target = resp_visual_target(dr)
      @resp_cursor.move_to(target[0], target[1], selecting: selecting)
    else
      @resp_cursor.move(dr, dc, size, line_at, selecting)
    end
    ensure_resp_visible(@resp_last_h) if @resp_last_h > 0
  end

  # Home / End in the response pane: the LOGICAL line's edges, with ⇧ extending.
  #
  # This pane had NO Home/End, and no PgUp/PgDn either: all four reached
  # `handle_repeater_response`, matched none of its arms, and were swallowed by the
  # trailing `true` — so the four keys did nothing at all, and ⇧Home/⇧End selected nothing
  # while the footer advertised "⇧arrows select". Every other multi-line pane in the tree
  # (the request editor beside it via `TextArea#handle_motion_key`, `HistoryView#
  # detail_line_edge`, and `ReadPane#motion_key` for the other nine) already spells them
  # this way; the response pane was the lone hold-out.
  #
  # Logical line ends, not visual row ends — the rule `ReadPane#motion_key` states, so a
  # wrapped line's End lands on its last row and Home on its first, with the shared
  # `ensure_resp_visible` scrolling to whichever row that turned out to be.
  #
  # False on a hex dump: it has no lines to have edges. The controller then returns false
  # too, and the shell's ±JUMP_ROWS reaches `RepeaterController#body_scroll` — the same
  # top/bottom buffer jump History's hex dump falls through to.
  def resp_line_edge(dir : Int32, selecting : Bool = false) : Bool
    return false unless resp_navigable?
    size, line_at = resp_line_source
    return false if size <= 0
    cy = @resp_cursor.cy.clamp(0, size - 1)
    @resp_cursor.move_to(cy, dir < 0 ? 0 : line_at.call(cy).size, selecting: selecting)
    ensure_resp_visible(@resp_last_h) if @resp_last_h > 0
    true
  end

  # One screenful of the response pane, for PgUp/PgDn. The same "minus a couple of rows of
  # overlap" step `ReadPane#motion_key` and `HistoryView#detail_page_rows` use, measured
  # from THIS pane's own last drawn height rather than the shell's `@body_h`: the response
  # column is half the body's width but carries its own header and borders, so the body's
  # height pages past the end of what the operator is looking at.
  def resp_page_rows : Int32
    {@resp_last_h - 2, 1}.max
  end

  # A vertical step off the end of one response card crosses into the other — ↓ off the
  # HANDSHAKE RESPONSE bottom lands on the TRANSCRIPT's first line, ↑ off the TRANSCRIPT top
  # lands on the handshake's last — so the column reads as one document, exactly as
  # `try_cross_req_pane` makes the request column read as one. Returns true when it crossed.
  #
  # (↑ off the HANDSHAKE top still pops to the tab bar, via `at_top?`.)
  private def try_cross_resp_pane(dr : Int32) : Bool
    return false unless resp_split?
    size, _ = resp_line_source
    return false if size <= 0
    if dr > 0 && @resp_pane == :handshake && @resp_cursor.cy >= size - 1
      switch_resp_pane(:transcript)
      resp_goto_edge(:first)
      return true
    end
    if dr < 0 && @resp_pane == :transcript && @resp_cursor.cy == 0
      switch_resp_pane(:handshake)
      resp_goto_edge(:last)
      return true
    end
    false
  end

  # Park the read cursor on the arriving pane's first or last line, column 0, with the view
  # following. `switch_resp_pane` restores a PARKED caret; this overrides it for the crossing
  # case, where the caret has to land at the boundary the step arrived through.
  private def resp_goto_edge(edge : Symbol) : Nil
    size, _ = resp_line_source
    return if size <= 0
    cy = edge == :first ? 0 : size - 1
    @resp_cursor.clear_selection
    @resp_cursor.sync(cy, 0)
    @scroll = cy
    @scroll_sub = 0
    ensure_resp_visible(@resp_last_h) if @resp_last_h > 0
  end

  # The caret `dr` visual rows away, in the BARE line coordinates `@resp_cursor` holds, or
  # nil when this pane has no wrap to walk — hex draws its own fixed rows, and before the
  # first frame there is no content width to have laid anything out at (`scroll` guards on
  # the same pair). The caller then steps logical lines, which is what a row is there.
  #
  # The walk runs on the DRAWN line, because that is what the wrap was computed on: in
  # diff mode every row carries a `"+ "`/`"- "` decoration whose columns shift each break.
  # So the column goes in as `cx + off` and the result comes back out through the same
  # `{cx - off, 0}.max.clamp(…)` the click and the wheel already use — a caret that lands
  # on the decoration belongs at column 0 of the text, the only place it can be drawn.
  private def resp_visual_target(dr : Int32) : {Int32, Int32}?
    return nil if dr == 0 || resp_hex_active? || @resp_last_cw <= 0 || !resp_wrap?
    size, drawn_at, off = resp_drawn_source
    return nil if size <= 0
    _, line_at = resp_line_source
    li, dcx = Wrap.step_caret(@resp_cursor.cy, @resp_cursor.cx + off, dr, size,
      drawn_at, resp_layout_fn(@resp_last_cw, drawn_at))
    {li, {dcx - off, 0}.max.clamp(0, line_at.call(li).size)}
  end

  # The INS half of the guard is gone: the wheel scrolls the request editor in insert
  # mode exactly as it does in normal mode. There were TWO guards for this, one here and
  # one in the controller's handle_wheel, so removing either alone changed nothing — they
  # landed together in the replay→repeater migration rather than as a decision, and the
  # neighbours disagree with them (Notes and the Decoder input scroll in insert mode with
  # no mode guard at all).
  #
  # `scroll_view` moves the viewport and drags the caret only when the window would
  # otherwise leave it behind — that is what NOR already uses, and mode consistency is the
  # point. A pure detached viewport is not available here: `render` calls `ensure_visible`
  # on EVERY frame, so a detached scroll would snap back on the next one.
  #
  # The hex half stays. `@req_hex_edit` is a different widget and the TextArea behind it
  # holds stale bytes, so scrolling it would move a buffer the operator is not looking at.
  def request_scroll_view(step : Int32) : Nil
    return if request_hex?
    req_editor.scroll_view(step)
  end

  # The same wheel notch, aimed at the sub-pane the POINTER is over rather than the active
  # one. A single-pane column answers identically (the hit is always `:envelope`), so this
  # only changes a split column — where wheeling over MESSAGES used to scroll HANDSHAKE
  # because that was the sub-pane holding the caret. `scroll_view` drags the caret into the
  # window it moved, exactly as it does for the focused pane, so the inactive pane keeps a
  # caret consistent with what it is showing.
  def request_scroll_view_at(step : Int32, rect : Rect, mx : Int32, my : Int32) : Nil
    return if request_hex?
    pane = request_hit(rect, mx, my)
    return request_scroll_view(step) unless pane
    (pane == :decoded ? @decoded : @editor).scroll_view(step)
  end

  # Wheel: `step` is DRAWN rows. Still O(viewport) — the anchor walk never counts the
  # response's total rows (see @scroll_sub) and only the caret line is materialised.
  def resp_scroll_view(step : Int32) : Nil
    return unless resp_navigable?
    size, drawn_at, off = resp_drawn_source
    _, line_at = resp_line_source
    return if @resp_last_h <= 0 || size <= 0
    cw = @resp_last_cw
    if cw <= 0 || !resp_wrap?
      return if size <= @resp_last_h
      @scroll = (@scroll + step).clamp(0, size - @resp_last_h)
      @scroll_sub = 0 # see `scroll`: no layout to carry a sub-row against (none yet, or wrap off)
    else
      fn = resp_layout_fn(cw, drawn_at)
      @scroll = @scroll.clamp(0, size - 1)
      @scroll, @scroll_sub = if step < 0
                               Wrap.step_back(@scroll, @scroll_sub, -step, fn)
                             else
                               Wrap.step_forward(@scroll, @scroll_sub, step, size, fn)
                             end
      mli, msub = Wrap.max_anchor(size, @resp_last_h, fn)
      if @scroll > mli || (@scroll == mli && @scroll_sub > msub)
        @scroll = mli
        @scroll_sub = msub
      end
    end
    # Pull the caret into the window, compared in VISUAL rows: a caret on the anchor LINE
    # can still be several wrapped rows above the anchor ROW, and the line-only clamp let
    # it sit there and drag the view straight back on the next ensure_resp_visible.
    rows = resp_rows(cw, @resp_last_h, size, drawn_at)
    return if rows.empty?
    first = rows[0]
    last = rows[rows.size - 1]
    cy = @resp_cursor.cy
    cx = @resp_cursor.cx + off # compare in the DRAWN line's coordinates (diff decoration)
    if cy < first.li || (cy == first.li && cx < first.a)
      cy, cx = first.li, first.a
    elsif cy > last.li || (cy == last.li && cx > last.b)
      cy, cx = last.li, last.a
    end
    @resp_cursor.sync(cy, {cx - off, 0}.max.clamp(0, line_at.call(cy).size))
  end
end
