# Drawing the RESPONSE column: its chrome, the WebSocket handshake card, the body (styled per
# visible line, gutter, selection, search), the transcript forms, the whitespace reveal and the
# diff. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # The RESPONSE pane's top-border chrome: keyed toggle chips + the right-aligned
  # latency·size of the last send. Each chip carries its shortcut (history-style:
  # d diff · x hex · p pretty) so the toggle is discoverable in place, and lights
  # when active. Plain response mode needs no chip of its own — it's simply none of
  # these lit (the pane is already titled RESPONSE).
  private def render_response_chrome(screen : Screen, rect : Rect) : Nil
    resp_plain = !@resp_hex && @resp_mode == :response
    diff_lit = !@resp_hex && @resp_mode == :diff
    pretty_lit = resp_plain && !@reveal && resp_pretty_applied?
    # These chips are LEFT-anchored, and `Frame.chip` does not clip (unlike its sibling
    # `Frame.toggle_badge`, which draws nothing when it doesn't fit). RESPONSE is a
    # half-width split pane, so below ~88 cols the cluster ran through this card's own
    # '╮' corner and on over the outer frame's border. Stop at the first chip that would
    # cross `limit`; the meta/⚠ read-out after this was already fit-guarded.
    limit = rect.right - 1 # keep the corner
    chips_end = rect.x + 12
    { {" d:diff ", diff_lit}, {" ^X:hex ", @resp_hex}, {" p:pretty ", pretty_lit} }.each do |label, lit|
      break if chips_end + Screen.draw_width(label) > limit
      chips_end = Frame.chip(screen, chips_end, rect.y, label, lit) + 1
    end
    if result = @result
      meta = result.ok? ? "#{Fmt.dur(result.duration_us)} · #{Fmt.size((result.head.size + (result.body.try(&.size) || 0)).to_i64)}" : Fmt.dur(result.duration_us)
      # `min_x:` because this border's left stop is the CHIP cluster, not the title.
      meta_x = Frame.border_meta(screen, rect, "", meta, min_x: chips_end + 1)
      # A persistent amber marker when the response was cut short (the body the
      # origin sent is incomplete) — the transient send toast scrolls away. Chained off
      # where the meta actually landed; when the meta did not fit there is nothing to
      # hang it on, and the row is already too tight to carry it.
      if result.incomplete? && meta_x
        warn = "⚠ incomplete"
        warn_x = meta_x - warn.size - 2
        screen.text(warn_x, rect.y, warn, Theme.yellow, Theme.bg) if warn_x > chips_end + 1
      end
    end
  end

  # The HANDSHAKE RESPONSE card (the 101 head). `active` says this card owns the response read
  # cursor, and it decides two things:
  #
  #   * the ANCHOR. Active, the card scrolls on the shared `@scroll`/`@scroll_sub` and publishes
  #     the metrics the hit-tests and scroll walkers read, so it is navigable like any other
  #     response pane. Inactive, it stays pinned to row 0 with a local layout and publishes
  #     nothing — the transcript owns the cursor then, and clobbering the metrics with this
  #     card's would send every click and wheel notch to the wrong geometry.
  #   * the CHROME. Only the active card paints the caret + selection band; the other one's
  #     cursor coordinates address a different document.
  private def render_ws_handshake(screen : Screen, rect : Rect, focused : Bool, active : Bool) : Nil
    return if rect.w < 2 || rect.h < 2
    Frame.card(screen, rect, "HANDSHAKE RESPONSE", bg: Theme.bg, border: Frame.pane_border(focused && active))
    if result = @result
      meta = result.ok? ? "#{Fmt.dur(result.duration_us)} · #{Fmt.size((result.head.size + (result.body.try(&.size) || 0)).to_i64)}" : Fmt.dur(result.duration_us)
      # `rect.x + 22` used to stand in for "HANDSHAKE RESPONSE" — the title's width, copied
      # by hand into a guard that would not follow it if the title ever changed.
      Frame.border_meta(screen, rect, "HANDSHAKE RESPONSE", meta)
    end
    body = rect.inset(1, 1)
    rv = resp_view
    total = rv.total
    gw = Settings.show_gutter ? {Gutter.width(total), body.w}.min : 0
    cw = {body.w - gw, 0}.max
    lit = focused && active
    if active
      @resp_last_h = body.h
      resp_record_metrics(gw, cw)
    end
    return if cw <= 0
    line_text = ->(i : Int32) { resp_line_text(rv, i) }
    sel_spans = active ? resp_sel_spans_if(lit) : nil
    # Active: the shared anchor + wrap memo, so this card can be scrolled and the caret walked
    # through it. Inactive: pinned to row 0 with a local layout, which is what it always did
    # (it is 7 rows showing a 4-5 line head — there is nothing to scroll to).
    rows = active ? resp_rows(cw, body.h, total, line_text) : resp_static_rows(cw, body.h, total, line_text)
    xs = active ? resp_xscroll : 0
    rows.each_with_index do |vr, i|
      y = body.y + i
      draw_resp_gutter(screen, body.x, y, gw, vr, lit)
      # slice_chars is the identity for a row that IS the whole line, so an unwrapped
      # handshake header costs nothing extra.
      shown = Highlight.slice_chars(styled_resp_line(rv, vr.li), vr.a, vr.b)
      shown = Highlight.slice_left(shown, xs) if xs > 0
      Highlight.draw(screen, body.x + gw, y, shown, width: cw)
      next unless active
      text = line_text.call(vr.li)
      paint_resp_line_chrome(screen, body.x + gw, y, vr.li, text, lit, sel_spans, vr.a, vr.b,
        clip_x: body.x + gw, clip_w: cw)
      Wrap.mark_search(screen, body.x + gw, y, text, vr.a, vr.b, @search_hl, body.x + gw + cw, xoff: xs) unless @search_hl.empty?
    end
    Frame.scroll_gauge(screen, body, total, @scroll, lit) if active
  end

  private def render_response(screen : Screen, rect : Rect, focused : Bool) : Nil
    return if rect.w < 2 || rect.h < 2
    if ws_mode?
      handshake_rect, transcript_rect = ws_resp_split(rect)
      on_handshake = @resp_pane == :handshake
      render_ws_handshake(screen, handshake_rect, focused, active: on_handshake)
      render_transcript(screen, transcript_rect, focused, "TRANSCRIPT", ws_transcript_lines,
        @ws_result.try(&.duration_us), active: !on_handshake)
      return
    end
    if @grpc_mode
      render_transcript(screen, rect, focused, "GRPC RESPONSE", grpc_transcript_lines, @result.try(&.duration_us))
      return
    end
    if group_mode?
      g = @group_results.not_nil!
      total = g.sum(&.[1].duration_us)
      render_transcript(screen, rect, focused, "GROUP · #{g.size} req", group_transcript_lines, total)
      return
    end
    Frame.card(screen, rect, "RESPONSE", bg: Theme.bg, border: Frame.pane_border(focused))
    render_response_chrome(screen, rect)
    body = rect.inset(1, 1)
    if @resp_hex
      (b = resp_hex_bytes) ? HexView.render(screen, body, b, @scroll) : screen.text(body.x, body.y, "— not sent — press ^R to resend —", Theme.muted)
    elsif @resp_mode == :diff
      render_diff(screen, body, focused)
    elsif @reveal && (rl = reveal_lines)
      render_reveal(screen, body, rl, focused)
    else
      render_response_body(screen, body, focused)
    end
    Frame.scroll_gauge(screen, body, resp_line_count, @scroll, focused)
  end

  # Shared windowed renderer for the WS / gRPC / group transcript panes (a list of
  # {text, colour} rows, scrolled by @scroll). `dur_us` rides the top border.
  #
  # `active` is only ever false for the WS transcript while the HANDSHAKE RESPONSE card above
  # it owns the cursor — gRPC and a pipelined group fill the whole column and are always
  # active. It gates the same two things it gates on the handshake card: the shared anchor +
  # published metrics, and the caret/selection chrome. Both cards render every frame, so
  # whichever one wrote the metrics LAST would otherwise win regardless of which one the
  # cursor is actually on.
  private def render_transcript(screen : Screen, rect : Rect, focused : Bool,
                                title : String, lines : Array({String, Color}), dur_us : Int64?,
                                active : Bool = true) : Nil
    lit = focused && active
    Frame.card(screen, rect, title, bg: Theme.bg, border: Frame.pane_border(lit))
    if d = dur_us
      meta = Fmt.dur(d)
      Frame.border_meta(screen, rect, title, meta)
    end
    body = rect.inset(1, 1)
    return if body.h <= 0
    if lines.empty?
      screen.text(body.x, body.y, "— not sent — press ^R to resend —", Theme.muted)
      return
    end
    gw = Settings.show_gutter ? {Gutter.width(lines.size), body.w}.min : 0
    cw = {body.w - gw, 0}.max
    if active
      @resp_last_h = body.h
      resp_record_metrics(gw, cw)
    end
    return if cw <= 0
    sel_spans = active ? resp_sel_spans_if(lit) : nil
    line_text = ->(i : Int32) { lines[i][0] }
    rows = active ? resp_rows(cw, body.h, lines.size, line_text) : resp_static_rows(cw, body.h, lines.size, line_text)
    xs = active ? resp_xscroll : 0
    rows.each_with_index do |vr, i|
      text, color = lines[vr.li]
      y = body.y + i
      draw_resp_gutter(screen, body.x, y, gw, vr, lit)
      shown = text[vr.a...vr.b]
      shown = Highlight.slice_left_text(shown, xs) if xs > 0
      screen.text(body.x + gw, y, shown, color, width: cw)
      next unless active
      paint_resp_line_chrome(screen, body.x + gw, y, vr.li, text, lit, sel_spans, vr.a, vr.b,
        clip_x: body.x + gw, clip_w: cw)
      Wrap.mark_search(screen, body.x + gw, y, text, vr.a, vr.b, @search_hl, body.x + gw + cw, xoff: xs) unless @search_hl.empty?
    end
    Frame.scroll_gauge(screen, body, lines.size, @scroll, lit) if active
  end

  # Windowed render of revealed (whitespace-visible) response lines.
  private def render_reveal(screen : Screen, rect : Rect, lines : Array(String), focused : Bool) : Nil
    total = lines.size
    @resp_last_h = rect.h
    gw = Settings.show_gutter ? {Gutter.width(total), rect.w}.min : 0
    cw = {rect.w - gw, 0}.max
    resp_record_metrics(gw, cw)
    return if cw <= 0
    sel_spans = resp_sel_spans_if(focused)
    # Reveal substitutes a 1-column marker for every control char (tab → '→', CR → '␍'),
    # which is exactly what `Screen.grapheme_cols` already scores them, so the wrap of the
    # RAW line and the wrap of the revealed line are the same break — no second layout.
    rows = resp_rows(cw, rect.h, total, ->(i : Int32) { lines[i] })
    xs = resp_xscroll
    rows.each_with_index do |vr, i|
      y = rect.y + i
      line = lines[vr.li]
      draw_resp_gutter(screen, rect.x, y, gw, vr, focused)
      # `last` only on the row that actually ends the line — the ␊ marker belongs at the
      # true end of the line, not at every wrap break inside it.
      eol = vr.b >= line.size && vr.li < total - 1
      styled = Reveal.styled(line[vr.a...vr.b], eol, cw + xs)
      styled = Highlight.slice_left(styled, xs) if xs > 0
      Highlight.draw(screen, rect.x + gw, y, styled, width: cw)
      paint_resp_line_chrome(screen, rect.x + gw, y, vr.li, line, focused, sel_spans, vr.a, vr.b,
        clip_x: rect.x + gw, clip_w: cw)
      Wrap.mark_search(screen, rect.x + gw, y, line, vr.a, vr.b, @search_hl, rect.x + gw + cw, xoff: xs) unless @search_hl.empty?
    end
  end

  # Revealed response lines, cached + rebuilt only when the response bytes change.
  private def reveal_lines : Array(String)?
    bytes = resp_hex_bytes
    return nil unless bytes
    cached = @reveal_lines
    return cached if cached && @reveal_lines_src == bytes.to_unsafe
    @reveal_lines_src = bytes.to_unsafe
    @reveal_lines = Reveal.lines(bytes)
  end

  # Ceiling on the styled-body memo. A visible window is ~tens of lines, so this covers
  # many screens of local scroll while capping memory on a huge response; on overflow the
  # whole memo is dropped (the next frame re-styles just the visible window — cheap).
  RESP_STYLED_CACHE_CAP = 2048

  # The styled line at absolute index `li`, memoized for BODY lines. Head lines are already
  # materialised (RespView#line_at returns the pre-built array), so they skip the memo.
  private def styled_resp_line(rv : RespView, li : Int32) : Highlight::Line
    return rv.line_at(li) if li < rv.head.size
    if cached = @resp_styled_cache[li]?
      return cached
    end
    @resp_styled_cache.clear if @resp_styled_cache.size >= RESP_STYLED_CACHE_CAP
    @resp_styled_cache[li] = rv.line_at(li)
  end

  # Steady-scroll hot path: only materialises/styles VISIBLE lines. Selection spans
  # are computed once per frame (lazy line_at over the selected range only).
  private def render_response_body(screen : Screen, rect : Rect, focused : Bool) : Nil
    rv = resp_view
    total = rv.total
    @resp_last_h = rect.h
    gw = Settings.show_gutter ? {Gutter.width(total), rect.w}.min : 0
    cw = {rect.w - gw, 0}.max
    resp_record_metrics(gw, cw)
    return if cw <= 0
    sel_spans = resp_sel_spans_if(focused)
    # The wrap is computed on the PLAIN text (`line_text`) and the styled overlay is then
    # sliced to the same char range — Highlight is a 1:1 colour overlay, so one layout
    # describes both and the colours cannot land a column off the glyphs.
    rows = resp_rows(cw, rect.h, total, ->(i : Int32) { resp_line_text(rv, i) })
    xs = resp_xscroll
    rows.each_with_index do |vr, i|
      li = vr.li
      y = rect.y + i
      need_plain = (focused && resp_navigable? && (li == @resp_cursor.cy || sel_spans)) || !@search_hl.empty?
      text = need_plain ? resp_line_text(rv, li) : nil
      draw_resp_gutter(screen, rect.x, y, gw, vr, focused)
      shown = Highlight.slice_chars(styled_resp_line(rv, li), vr.a, vr.b)
      shown = Highlight.slice_left(shown, xs) if xs > 0
      Highlight.draw(screen, rect.x + gw, y, shown, width: cw)
      paint_resp_line_chrome(screen, rect.x + gw, y, li, text, focused, sel_spans, vr.a, vr.b,
        clip_x: rect.x + gw, clip_w: cw) if text
      if (t = text) && !@search_hl.empty?
        Wrap.mark_search(screen, rect.x + gw, y, t, vr.a, vr.b, @search_hl, rect.x + gw + cw, xoff: xs)
      end
    end
  end

  # Response-pane gutter: the row number rides the FIRST visual row of a logical row only
  # (Burp style); a continuation gets a blank of the same width so the text column stays
  # put and no stale digits survive there.
  private def draw_resp_gutter(screen : Screen, x : Int32, y : Int32, gw : Int32,
                               vr : Wrap::Row, focused : Bool) : Nil
    return if gw <= 0
    if vr.sub == 0
      Gutter.draw(screen, x, y, vr.li, gw, current: focused && vr.li == @resp_cursor.cy)
    else
      screen.text(x, y, " " * {gw - 1, 0}.max, Theme.muted, width: gw)
    end
  end

  # Selection tint + block caret for ONE drawn row. `rs`/`re` bound the row's slice of the
  # line (the whole line when nothing wrapped), so a selection spanning a wrap break is
  # painted on each row it covers and the caret paints on exactly one of them — the row
  # that STARTS at its column, matching Wrap::Layout#row_of.
  # `clip_x`/`clip_w` bound the pane's visible content column, which the h-scroll offset can
  # push the caret and the tint outside of (0/0 ⇒ no clip, which is what every wrapped row
  # wants — it cannot exceed the width it was laid out at). They are passed rather than
  # derived from `x`, because the diff pane's `x` is the TEXT's start, two columns inside the
  # pane, and clipping there would blank two cells that are on screen.
  private def paint_resp_line_chrome(screen : Screen, x : Int32, y : Int32, li : Int32, line : String,
                                     focused : Bool, sel_spans : Array({Int32, Int32, Int32})? = nil,
                                     rs : Int32 = 0, re : Int32 = -1,
                                     clip_x : Int32 = 0, clip_w : Int32 = 0) : Nil
    return unless focused && resp_navigable?
    re = line.size if re < 0
    if spans = sel_spans
      spans.each do |(l, x0, x1)|
        next unless l == li
        a = {x0, rs}.max
        b = {x1, re}.min
        paint_char_span_bg(screen, x, y, line, a, b, Theme.accent_bg, rs, clip_x, clip_w) if a < b
      end
    end
    return unless li == @resp_cursor.cy
    cx = @resp_cursor.cx.clamp(0, line.size)
    return unless cx >= rs && (cx < re || re >= line.size)
    px = x + Wrap.row_col(line, nil, rs, cx) - resp_xscroll
    # Clipped only while the pane is PANNED: with no offset the caret is inside the row by
    # construction, except for an end-of-line caret on a row exactly as wide as the pane —
    # which lands on the border cell and has always been drawn there. Clipping that one
    # unconditionally would trade a caret a column too far right for no caret at all.
    return if resp_xscroll > 0 && clip_w > 0 && (px < clip_x || px >= clip_x + clip_w)
    ch = cx < line.size ? line[cx] : ' '
    screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
    screen.cursor(px, y)
  end

  # Selection spans once per frame (lazy line_at; only selected range materialised).
  private def resp_sel_spans_if(focused : Bool) : Array({Int32, Int32, Int32})?
    return nil unless focused && resp_navigable? && @resp_cursor.selection?
    size, line_at = resp_line_source
    @resp_cursor.highlight_spans(size, line_at)
  end

  # The diff pane draws a 2-column "+ "/"- " decoration in front of each line, so the
  # wrapped row is a slice of `full` (decoration + text) while the caret, selection and
  # search all address `text`. The two coordinate systems differ by exactly 2 characters
  # of width 1 each — that constant is the ONLY place they are reconciled, here.
  DIFF_PREFIX_COLS = 2

  private def render_diff(screen : Screen, rect : Rect, focused : Bool) : Nil
    data = diff_lines
    gw = Settings.show_gutter ? {Gutter.width(data.size), rect.w}.min : 0
    cw = {rect.w - gw, 0}.max
    @resp_last_h = rect.h
    resp_record_metrics(gw, cw)
    return if cw <= 0
    sel_spans = resp_sel_spans_if(focused)
    # The pane scrolls in rows of the DECORATED line, so that is what the anchor, the wrap
    # memo and the click inverse all index — `resp_line_source` hands out the bare text,
    # which is 2 columns narrower and would wrap at different offsets. `resp_drawn_source`
    # is the single definition of that; using it here keeps render and hit-testing on one
    # grid instead of two that agree until a line is exactly pane-wide.
    _, decorated, _ = resp_drawn_source
    rows = resp_rows(cw, rect.h, data.size, decorated)
    xs = resp_xscroll
    rows.each_with_index do |vr, i|
      d = data[vr.li]
      y = rect.y + i
      color = case d.kind
              when .add? then Theme.green
              when .del? then Theme.red
              else            Theme.muted
              end
      draw_resp_gutter(screen, rect.x, y, gw, vr, focused)
      shown = decorated.call(vr.li)[vr.a...vr.b]
      shown = Highlight.slice_left_text(shown, xs) if xs > 0
      screen.text(rect.x + gw, y, shown, color, width: cw)
      # Re-base the row onto `text`: on the first row the text starts DIFF_PREFIX_COLS in,
      # on a continuation it starts at the pane edge. The h-scroll offset is NOT folded in
      # here — the chrome subtracts it itself, in the decorated line's column space, which is
      # where it was measured.
      tx = rect.x + gw + {DIFF_PREFIX_COLS - vr.a, 0}.max
      ts = {vr.a - DIFF_PREFIX_COLS, 0}.max
      te = {vr.b - DIFF_PREFIX_COLS, 0}.max
      paint_resp_line_chrome(screen, tx, y, vr.li, d.text, focused, sel_spans, ts, te,
        clip_x: rect.x + gw, clip_w: cw)
      # Mark only the line text, so the highlights match what response_search_lines
      # counts (d.text) rather than the diff decoration.
      Wrap.mark_search(screen, tx, y, d.text, ts, te, @search_hl, rect.x + gw + cw, xoff: xs) unless @search_hl.empty?
    end
  end
end
