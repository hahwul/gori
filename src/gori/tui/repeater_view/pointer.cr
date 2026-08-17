# What a click MEANS: chrome hit-testing (the badges and chips on a card's border) and the
# press/drag/double-click caret placement for the target field, the request editor and the
# response pane. Coordinates arrive 0-based, already decoded by the Runner.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # The HANDSHAKE REQUEST card's right-chained badges, right-to-left — ONE list, read by the
  # draw (`render_request`, for both the badges and where the mode chip chains to) and by the
  # hit-test below. `␣K:KEY` was drawn from one place and hit-tested from another, and the
  # second one did not list it: the badge was a dead cell, while HTTP's `^L:CL`/`^U:PRETTY`
  # next to it have always been clickable.
  WS_BADGES = [{:send, "^R", "SEND"}, {:ws_key, "␣K", "KEY"}] of {Symbol, String, String}

  # Border-chrome hit-test for REQUEST/RESPONSE toggle chips. Shares geometry with
  # render_request / render_response_chrome (label strings + start_x / right chain).
  # Returns a chip id, or nil so the caller can fall through to caret placement.
  def chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
    return nil unless @loaded && rect.contains?(mx, my)
    target_h = {rect.h, target_card_h}.min
    # TARGET NOR/INS chip (top band) — click toggles insert like ↵/esc. The `^V` transport
    # chip chains left of it (past the SNI marker) and cycles the transport on click.
    if my == rect.y && target_h >= 2
      if Frame.mode_badge_hit(mx, my, rect.y, rect.right - 1, rect.x + 8, target_insert?)
        return :target_mode
      end
      if transport_switchable?
        _, tr_edge = target_chrome_chain(rect)
        if hit = Frame.right_badge_hit(mx, my, rect.y, tr_edge, target_chip_min(rect),
             [{:transport, "^V", transport_label}] of {Symbol, String, String})
          return hit
        end
      end
    end
    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    return nil if content.h <= 0
    half = {(content.w - 1) // 2, 1}.max
    left = Rect.new(content.x, content.y, half, content.h)
    right = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 0}.max, content.h)

    if hit = grpc_chrome_hit(right, mx, my)
      return hit
    end

    # RESPONSE: d:diff / x:hex / p:pretty (not drawn in WS/gRPC/group transcript modes)
    unless ws_mode? || @grpc_mode || group_mode?
      if right.w >= 2 && my == right.y
        # `limit:` is render_response's own `rect.right - 1` stop. The draw breaks at the
        # first chip that would cross the card's '╮'; without the same stop here the hit
        # walked all three anyway, so on a half-width RESPONSE below ~88 columns hex and
        # pretty answered clicks on the border and past it.
        if hit = Frame.left_chip_hit(mx, my, right.y, right.x + 12, [
             {:diff, " d:diff "},
             {:hex, " ^X:hex "},
             {:pretty, " p:pretty "},
           ] of {Symbol, String}, limit: right.right - 1)
          return hit
        end
      end
    end

    # REQUEST badges: ^R:SEND is always rightmost (primary action). Then CL/PRETTY (or HEX,
    # or gRPC's ^X:MSG, or WS's ␣K:KEY) when drawn; the NOR/INS mode chip chains left of
    # those. Decode / CHAIN splits keep chrome on the top card.
    req_card = req_split? ? decode_split(left)[0] : left
    if req_card.w >= 2 && my == req_card.y
      label = render_request_label
      min_x = req_card.x + label.size + 4
      right_edge = req_card.right - 1
      badges = if @grpc_mode
                 b = [{:send, "^R", "SEND"}] of {Symbol, String, String}
                 if @req_hex_edit
                   b << {:req_hex, "^X", "HEX"} # editing the payload
                 elsif @grpc_reframable
                   b << {:req_hex, "^X", "MSG"} # click to hex-edit the unary payload
                 end
                 # Chains left of whichever hex chip is drawn — in BOTH states, matching
                 # render_request. Recompute the 5-byte length prefix over the payload, or send
                 # the captured one in front of it (DESIGN.md §7).
                 b << {:grpc_reframe, "␣F", "FRAME"} if @grpc_reframable
                 b
               elsif ws_mode?
                 WS_BADGES # ^R:SEND + ␣K:KEY — the list render_request draws from
               elsif @req_hex_edit
                 [{:send, "^R", "SEND"}, {:req_hex, "^X", "HEX"}] of {Symbol, String, String}
               else
                 [{:send, "^R", "SEND"}, {:cl, "^L", "CL"}, {:pretty_req, "^U", "PRETTY"}] of {Symbol, String, String}
               end
      if hit = Frame.right_badge_hit(mx, my, req_card.y, right_edge, min_x, badges)
        return hit
      end
      # Mode chip: drawn on every non-hex request card — plain HTTP, the WS handshake and the
      # gRPC head are all mode-switched text editors. Hex is the exception and draws none (a
      # nibble cursor has no READ/INS), so hit-testing one there would invent a live cell over
      # a badge that was never painted — the inverse of the dead `␣K:KEY` this pass fixed.
      unless @req_hex_edit
        mode_edge = Frame.right_badge_edge(right_edge, min_x, badges)
        if Frame.mode_badge_hit(mx, my, req_card.y, mode_edge, min_x, request_insert?)
          return :mode
        end
        # ` ^T:MARK ` chains LEFT of the mode chip, under exactly the condition
        # render_request draws it: only while the buffer's `§` are still INERT capture bytes.
        # It was the one badge on this border missing from the hit list while its four
        # neighbours all answered.
        if !@grpc_mode && !ws_mode? && !decode_mode? && literal_markers?
          mark_edge = Frame.mode_badge_edge(mode_edge, min_x, request_insert?)
          if Frame.right_badge_hit(mx, my, req_card.y, mark_edge, min_x,
               [{:mark, "^T", "MARK"}] of {Symbol, String, String})
            return :mark
          end
        end
      end
    end
    nil
  end

  # GRPC RESPONSE: the one transcript pane that carries a chip — ` p:tree ` / ` p:bytes `,
  # which picks the schema-less protobuf tree over a hex preview. All THREE numbers come from
  # `render_grpc_chrome`'s own helpers — `grpc_chip_x`, `grpc_chip_label` and, since #741's
  # review, `grpc_chrome_limit` — so the live cells are exactly the painted ones.
  #
  # That last one is the whole point: this used to pass its own `right.right - 1`, one column
  # short of the card's '╮', while the draw stopped at the LATENCY meta's left edge instead.
  # On a half-width pane with a duration on the border the two disagreed, and `Frame.chip`
  # draws nothing at all when it does not fit — so the ` p:` region answered clicks on the
  # duration text, and on a narrower pane on bare border. Asking `grpc_chrome_limit` closes
  # both: `left_chip_hit` BREAKS at the same chip the draw refuses, which is nil here.
  private def grpc_chrome_hit(right : Rect, mx : Int32, my : Int32) : Symbol?
    return nil unless @grpc_mode && right.w >= 2 && my == right.y
    Frame.left_chip_hit(mx, my, right.y, grpc_chip_x(right),
      [{:pretty, grpc_chip_label}] of {Symbol, String}, limit: grpc_chrome_limit(right))
  end

  # Mouse: place the request-editor caret (text) or nibble cursor (hex) at a click. A split
  # tab (WS HANDSHAKE/MESSAGES, SAML/GraphQL ENVELOPE/DECODED) first adopts the sub-pane the
  # pointer is in, then places the caret in it — through the SAME mode branch a single-pane
  # tab uses, which is the whole point of the seam below.
  #
  # The split used to call `TextArea#click_to_cursor` directly, bypassing `@req_read`. That
  # left READ mode's cursor model untouched by a click, so its anchor kept whatever an
  # earlier selection had planted — invisible only because nothing painted the read band in
  # those panes. Both halves are fixed together.
  def request_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
    return unless @loaded
    pane = request_hit(rect, mx, my) || return
    # The rect comes out BEFORE the switch: `decode_split` sizes the two cards from
    # `@req_pane` (the active one is enlarged), so switching first would invert the click
    # against a layout that has not been drawn yet. The caret goes in AFTER, because
    # `switch_req_pane` can `set_text` an editor (commit/re-decode) and reset its caret.
    inner = request_sub_rect(rect, pane) || return
    switch_req_pane(pane)
    commit_chain_pane if @chain_focused # a click outside the ^Q modal commits + dismisses it, then places the caret
    place_request_caret(inner, mx, my)
  end

  # Mouse DRAG in the request pane — extend the selection to the pointer. The two modes keep
  # their own selection models (INS: the editor's own anchor, painted by `TextArea#render`;
  # READ: `@req_read`, painted by the owner), and each is extended through the model that
  # owns it.
  #
  # Always the ACTIVE sub-pane's rect, never the one under the pointer: a drag that wanders
  # into the other half of a split column must keep extending the selection it started, not
  # jump buffers mid-gesture (neither `cut_selection` nor the band painter can express a
  # selection spanning two buffers). `TextArea#click_to_cursor` clamps a row past the pane's
  # bottom to its last visible row and pins one above the top when `selecting`, so leaving
  # the sub-pane vertically extends to its edge — which is what a drag off a 1/3-height
  # sub-pane means.
  #
  # Hex stays excluded: a nibble cursor has no selection to extend.
  def request_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
    return unless @loaded && !@req_hex_edit
    inner = request_sub_rect(rect, @req_pane) || return
    place_request_caret(inner, mx, my, selecting: true)
  end

  # Mouse DOUBLE-CLICK in the request pane — spread to the word under the CARET, which the
  # press of the pair has already placed at the pointer (`handle_click` runs first, always).
  # No geometry, and that is the point: a second hit-test would have to invert the same screen
  # row again, and in a split column the layout MOVED in between — press 1 adopts the lower
  # sub-pane, which grows the active card to ~2/3 and lifts the lower card's top edge by ~1/3
  # of the column. (The upper card's `y` is `col.y` whatever its height, so only this
  # direction was ever wrong.) Inverting against the new rect selected a token about a third of
  # a column below the pointer; spreading from the caret inherits press 1's correct inverse.
  def request_select_word : Bool
    return false unless @loaded && !@req_hex_edit
    ed = req_editor
    request_insert? ? ed.select_word_at_cursor : @req_read.select_word_at_cursor(ed)
  end

  # The one place a pointer position becomes a caret in the request column. INS drives the
  # editor's own anchor; READ drives `@req_read` (whose `click` runs the editor's hit test
  # and then owns the selection). Hex has neither, so it places its nibble cursor instead.
  private def place_request_caret(inner : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
    if h = @req_hex_edit
      return if selecting # a nibble cursor has no selection to drag
      h.click_to_nibble(inner, mx, my, @scroll_req)
      return
    end
    ed = req_editor
    if request_insert?
      ed.click_to_cursor(inner, mx, my, selecting: selecting)
    else
      @req_read.click(ed, inner, mx, my, selecting: selecting)
    end
  end

  # Mouse: focus the URL or SNI field of the TARGET band by which row was clicked,
  # and place that field's caret. The value bases mirror render_target (field_base).
  # `selecting` is the DRAG half: it extends the read selection from wherever the press
  # planted the anchor, and — unlike a press — it never switches FIELDS. A drag that
  # crossed from the URL row down onto the SNI row would otherwise re-aim the anchor at a
  # different string, so the band would be measured in one value and painted over another.
  #
  # A bare press goes through `move_cx` too, rather than assigning the caret: that is what
  # COLLAPSES a standing selection. Assigning left the anchor behind, so a click after a
  # ⇧←/→ run repainted the band from the old anchor to the new caret — a selection the
  # operator had just clicked away from.
  def target_click_to_cursor(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
    return unless @loaded
    # The SNI row is at exactly rect.y+2 (bottom border is rect.y+3) — match it
    # precisely, so a click on the card's border doesn't route edits into @sni.
    @target_field = (sni_active? && my == rect.y + 2) ? :sni : :url unless selecting
    prefix = @target_field == :sni ? SNI_PREFIX : TARGET_PREFIX
    line = target_active_line
    to = Screen.column_for_click(line, mx - field_base(rect, prefix))
    cx = @target_read.move_cx(target_active_cx, to - target_active_cx, line.size, selecting: selecting)
    @target_field == :sni ? (@scx = cx) : (@tcx = cx)
  end

  # Pointer moved with the button held over the target card — extend from the press.
  #
  # READ mode only, because that is the only mode whose band `draw_target_row` paints
  # (`active && !insert`). Extending in INSERT would plant an anchor nothing draws and
  # `target_copy_text` would then hand back a slice the operator never saw selected — a
  # silent selection is worse than none. The INSERT half of this field has no selection at
  # all yet; when it grows one, this guard is what lifts.
  def target_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
    return if target_insert?
    target_click_to_cursor(rect, mx, my, selecting: true)
  end

  # Double-click: take the word the press already placed the caret on. Spreads from THAT
  # caret rather than hit-testing again (the same rule the request/response panes follow),
  # so the two presses of the pair cannot disagree about which character was under the
  # pointer. False on whitespace or an empty field, leaving the press's caret standing.
  def target_select_word : Bool
    return false unless @loaded && !target_insert?
    cx = @target_read.select_word_at_cursor(target_active_line, target_active_cx)
    return false unless cx
    @target_field == :sni ? (@scx = cx) : (@tcx = cx)
    true
  end

  # Mouse PRESS in the response column. On a split (WebSocket) column the press first adopts
  # the card it landed in — the response half of what `request_click_to_cursor` does — and the
  # body rect is taken BEFORE the switch, because `ws_resp_split` sizes the two cards from
  # `@resp_pane` and switching first would invert the click against a layout not yet drawn.
  def resp_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
    return unless resp_navigable? && @loaded
    col = response_col_rect(rect) || return
    return unless col.contains?(mx, my)
    pane = resp_hit(col, my)
    body = resp_body_rect_for(col, pane)
    switch_resp_pane(pane)
    resp_place_caret(body, mx, my, selecting: false)
  end

  # Mouse DRAG in the response pane — extend the read selection to the pointer. Always the
  # ACTIVE card, never the one under the pointer: a drag that wanders across the divider keeps
  # extending the selection it started, because an anchor cannot span two documents.
  def resp_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
    return unless resp_navigable? && @loaded
    col = response_col_rect(rect) || return
    resp_place_caret(response_body_rect(col), mx, my, selecting: true)
  end

  # Mouse DOUBLE-CLICK in the response pane — spread to the word under the CARET, which the
  # press of the pair already placed (`handle_click` always runs first). No second hit test,
  # for the reason `request_select_word` spells out: adopting a card resizes the column, so
  # re-inverting the same screen row would address a rect that has since moved.
  def resp_select_word : Bool
    return false unless resp_navigable? && @loaded
    size, line_at = resp_line_source
    return false if size <= 0
    @resp_cursor.select_word_at_cursor(size, line_at)
  end

  private def resp_place_caret(body : Rect, mx : Int32, my : Int32, selecting : Bool) : Nil
    # Render's own numbers, not a re-derivation — see @resp_last_gw. Falls back to the
    # gutter estimate only before the first frame, when nothing has been laid out yet.
    gw = @resp_last_cw > 0 ? @resp_last_gw : resp_gutter_w(body)
    cw = @resp_last_cw > 0 ? @resp_last_cw : {body.w - gw, 0}.max
    size, drawn_at, off = resp_drawn_source
    _, line_at = resp_line_source
    return if size <= 0
    row = my - body.y
    # A drag above the pane pins to its first visible row — the pointer left the top edge
    # with the button held, which is an upward selection, not a miss.
    if row < 0
      return unless selecting
      row = 0
    end
    rows = resp_rows(cw, body.h, size, drawn_at)
    return if rows.empty?
    # The wrap inverse, not `@scroll + row`: a screen row is a VISUAL row now, and the
    # continuation rows between it and the anchor are exactly what the old arithmetic
    # skipped. `Wrap.row_index` clamps to the row it was given, so a click past the end of
    # a wrapped row stops at the break rather than selecting the next row's first char.
    vr = rows[row]? || rows[rows.size - 1]
    drawn = drawn_at.call(vr.li)
    # `+ @resp_xscroll` puts the pointer back into the DRAWN line's column space: it is 0
    # under wrap, and without it a click on a sideways-panned line lands that many columns
    # early.
    hit = Wrap.row_index(drawn, nil, vr.a, vr.b, mx - (body.x + gw) + resp_xscroll)
    cx = {hit - off, 0}.max.clamp(0, line_at.call(vr.li).size)
    if selecting
      @resp_cursor.move_to(vr.li, cx, selecting: true) # keeps (or plants) the anchor
    else
      @resp_cursor.clear_selection
      @resp_cursor.sync(vr.li, cx)
    end
    ensure_resp_visible(body.h)
  end
end
