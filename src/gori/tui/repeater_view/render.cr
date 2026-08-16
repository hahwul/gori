# The frame: `render` splits the rect into the target card and the request | response columns,
# and draws the target card itself (URL row, SNI row, transport chip).
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- rendering -----------------------------------------------------------

  def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
    return if rect.empty?
    unless @loaded
      TrafficEmptyState.render(screen, rect, variant: :repeater, title: "no flow loaded")
      return
    end

    # target pane: a 3-row card on top (4 when an SNI override is set/edited);
    # request | response cards fill the rest.
    target_h = {rect.h, target_card_h}.min
    render_target(screen, Rect.new(rect.x, rect.y, rect.w, target_h), focused && @focus == :target)

    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    return if content.h <= 0
    half = {(content.w - 1) // 2, 1}.max
    left = Rect.new(content.x, content.y, half, content.h)
    right = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 0}.max, content.h)
    req_focused = focused && @focus == :request
    if req_split? # split the request column into ENVELOPE/HANDSHAKE (top) + DECODED/MESSAGES (bottom)
      env, dec = decode_split(left)
      render_request(screen, env, req_focused && @req_pane == :envelope)
      render_decoded(screen, dec, req_focused && @req_pane == :decoded)
    else
      render_request(screen, left, req_focused && !@chain_focused) # dimmed while the ^Q modal owns focus
    end
    render_response(screen, right, focused && @focus == :response)
    render_chain_overlay(screen, rect) if @chain_focused # centered modal ON TOP (replaces the old split)
  end

  # The ^Q chain editor: a centered modal over the whole tab, bound to the marker the
  # cursor sat in when ^Q was pressed. Shows the marker's value, the editable chain, and
  # a live transform preview. Keys route here via the controller (chain_pane_active?).
  private def render_chain_overlay(screen : Screen, area : Rect) : Nil
    value = Fuzz::Template.value_at(@editor.text, @chain_marker_cursor) || ""
    ChainOverlay.render(screen, area, "CHAIN · #{marker_label}", value, @chain_pane)
  end

  private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
    return if rect.h < 2
    Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: Frame.pane_border(focused))
    Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 8, target_insert?) # the REAL mode, not focused&&mode — see Frame.mode_badge
    sni_x, tr_edge = target_chrome_chain(rect)
    # An at-a-glance SNI marker on the top border (right of the title) whenever an
    # override is set, so a custom SNI is visible even before the row is reached.
    screen.text(sni_x, rect.y, SNI_BADGE, Theme.text_bright, Theme.accent_bg) if sni_x
    # ` ^V:h1 ` / ` ^V:h2 ` / ` ^V:WS ` — the transport `^R` will dial, and the only thing on
    # screen saying `^V` has anything to offer. It rides the TARGET band rather than the
    # REQUEST border because that is where the rest of "how do we connect" already lives
    # (the URL, the SNI override) and because the request border is a half-width column that
    # already drops its NOR/INS chip when a fifth badge is chained onto it.
    #
    # Two dresses, no third: a filled chip at rest (the NAME is the state, so muted grey
    # would read as "disabled"), and a BOLD ACCENT pill when the operator has overridden
    # auto-detection — a handshake tab that will NOT speak WebSocket is the one thing on this
    # band worth interrupting a glance for.
    #
    # Accent, not the ^R:SEND gold it used to borrow. This chip rides the TARGET card's top
    # border, and that border IS `focus_gold` when the card has focus — so an overridden
    # transport on a focused card put two golds on one edge and "gold means focus is here"
    # stopped being readable. Gold is focus and the brand mark; nothing else.
    if transport_switchable?
      fg, bg, attr = if transport_badge_lit?
                       {Theme.ink_on(Theme.accent), Theme.accent, Attribute::Bold}
                     else
                       {Theme.text_bright, Theme.accent_bg, Attribute::None}
                     end
      Frame.state_badge(screen, tr_edge, rect.y, target_chip_min(rect), "^V", transport_label, fg, bg, attr)
    end
    url_active = focused && @target_field == :url
    sni_active_row = focused && @target_field == :sni
    draw_target_row(screen, rect, rect.y + 1, TARGET_PREFIX, @target, @tcx, url_active, target_insert?)
    draw_target_row(screen, rect, rect.y + 2, SNI_PREFIX, @sni, @scx, sni_active_row, target_insert?) if sni_active? && rect.h >= 4
  end

  # One single-line field row of the TARGET card: a marker prefix, then the value,
  # with the block caret + terminal cursor when this row is the active field.
  private def draw_target_row(screen : Screen, rect : Rect, row : Int32, prefix : String, value : String,
                              cx : Int32, active : Bool, insert : Bool) : Nil
    screen.text(rect.x + 2, row, prefix, active ? Theme.accent : Theme.muted)
    base = field_base(rect, prefix)
    w = {rect.right - base - 1, 1}.max
    Highlight.draw(screen, base, row, Highlight.env_line(value, Theme.text_bright), width: w)
    # AFTER the value, and before the caret below. `Highlight.draw` writes its own `bg`
    # into every cell it touches, so a band painted first was applied and erased on the
    # same frame: ⇧←/→ on this row selected, `y` copied the right slice, and the operator
    # saw nothing. The caret still goes last, because when the selection grows LEFTWARD
    # the caret cell is inside the span and the band would otherwise erase it.
    if active && !insert
      if span = @target_read.selection_span(cx)
        paint_char_span_bg(screen, base, row, value, span[0], span[1], Theme.accent_bg)
      end
    end
    if active
      # column_width — the measure paint_char_span_bg (the selection tint, a few lines up)
      # already uses on this same value in this same render, and the exact inverse of the
      # Screen.column_for that target_click_to_cursor uses to turn a click back into `cx`.
      # display_width scored a zero-width char as 0, so the three disagreed: the tint
      # covered one span, the caret sat a column left of its glyph, and a click landed a
      # character off. A URL carrying U+200B is ordinary traffic for this tool (it is a
      # stock filter-bypass payload), so this is reachable, not theoretical.
      cursor_x = base + Screen.draw_width(value[0, cx])
      if cursor_x < rect.right - 1
        ch = cx < value.size ? value[cx] : ' '
        screen.cell(cursor_x, row, ch, Theme.bg, insert ? Theme.accent : Theme.accent_bg)
        screen.cursor(cursor_x, row)
      end
    end
  end
end
