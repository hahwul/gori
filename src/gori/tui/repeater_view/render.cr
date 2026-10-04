# The frame: `render` splits the rect into the target card and the request | response columns,
# and draws the target card itself (URL row, SNI row, transport chip).
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- rendering -----------------------------------------------------------

  def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
    if rect.empty?
      @target_drawn = @columns_drawn = false
      return
    end
    unless @loaded
      TrafficEmptyState.render(screen, rect, variant: :repeater, title: "no flow loaded")
      return
    end

    # target pane: a 3-row card on top (4 when an SNI override is set/edited);
    # request | response cards fill the rest.
    target_h = {rect.h, target_card_h}.min
    @target_drawn = target_h >= TARGET_MIN_H
    content = columns_rect(rect)
    @columns_drawn = !content.nil?
    # Before the target draws, so its card is lit as the pane that now has the keys.
    settle_focus_on_drawn_pane
    render_target(screen, Rect.new(rect.x, rect.y, rect.w, target_h), focused && @focus == :target)

    return render_columns_note(screen, rect, target_h) unless content
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

  # Too short for the columns (#1421). Say so on the rows that are left, rather than leaving
  # a blank band under TARGET that reads as an empty request.
  private def render_columns_note(screen : Screen, rect : Rect, target_h : Int32) : Nil
    return unless rect.h > target_h
    screen.text(rect.x + 2, rect.y + target_h, "REQUEST · RESPONSE need a taller window",
      Theme.muted, width: {rect.w - 4, 0}.max)
  end

  # The ^Q chain editor: a centered modal over the whole tab, bound to the marker the
  # cursor sat in when ^Q was pressed. Shows the marker's value, the editable chain, and
  # a live transform preview. Keys route here via the controller (chain_pane_active?).
  private def render_chain_overlay(screen : Screen, area : Rect) : Nil
    value = Fuzz::Template.value_at(@editor.text, @chain_marker_cursor) || ""
    ChainOverlay.render(screen, area, "CHAIN · #{marker_label}", value, @chain_pane)
  end

  # The TARGET card's floor: a border and the URL row. `@target_drawn` records it.
  TARGET_MIN_H = 2

  private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
    return if rect.h < TARGET_MIN_H
    Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: Frame.pane_border(focused))
    Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 8, target_insert?) # the REAL mode, not focused&&mode — see Frame.mode_badge
    sni_x, tls_x, tr_edge = target_chrome_chain(rect)
    # An at-a-glance SNI marker on the top border (right of the title) whenever an
    # override is set, so a custom SNI is visible even before the row is reached.
    screen.text(sni_x, rect.y, SNI_BADGE, Theme.text_bright, Theme.accent_bg) if sni_x
    # ` ␣Pt:tls ` / ` ␣Pt:chrome ` — the TLS fingerprint THIS TAB will present (#844), and the
    # only thing on screen saying `␣Pt` has anything to offer. It rides the TARGET band for the
    # same reason `^V` does: this is where "how do we connect" already lives.
    #
    # Three dresses. Muted while no override is set — this one really does have an off state,
    # unlike `^V`, and the off state is "the destination's own policy". Accent-filled when an
    # override is in play, because two tabs against one host differing only here is the whole
    # feature and it must be readable at a glance. And MUTED AGAIN when the override cannot
    # apply (an http:// target has no ClientHello): the chip still NAMES it, so the operator
    # can see the value is set and see that it is doing nothing, which is exactly the state a
    # lit chip would lie about.
    if tls_x
      fg, bg = tls_preset_live? ? {Theme.text_bright, Theme.accent_bg} : {Theme.muted, Theme.bg}
      screen.text(tls_x, rect.y, tls_chip_label, fg, bg)
    end
    # ` ^V:HTTP/1.1 ` / ` ^V:HTTP/2 ` / ` ^V:WS ` — the transport `^R` will dial, and the only thing on
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
      Frame.state_badge(screen, tr_edge, rect.y, target_chip_min(rect), key_label("repeater.toggle-http2", "^V"), transport_label, fg, bg, attr)
    end
    url_active = focused && @target_field == :url
    sni_active_row = focused && @target_field == :sni
    draw_target_row(screen, rect, rect.y + 1, TARGET_PREFIX, @target, @tcx, url_active, target_insert?)
    draw_target_row(screen, rect, rect.y + 2, SNI_PREFIX, @sni, @scx, sni_active_row, target_insert?) if sni_active? && rect.h >= 4
  end
end
