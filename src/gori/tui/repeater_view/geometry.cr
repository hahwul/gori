# Where the panes ARE: the target card's chrome chain and height, the request column and its
# decode split, the response column and its WebSocket handshake/transcript split, and the
# gutter/body rects those are drawn into. Pure rect math — a click's MEANING is in
# repeater_view/pointer.cr. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # {scheme, host, port} parsed from the target field.
  # Delegate to the engine's parser so the TUI field and `gori run`/the repeater engine never
  # disagree on host/port (they used to be byte-for-byte duplicate implementations).
  def parse_target : {String, String, Int32}
    Repeater::FlowRequest.parse_target(Env.expand(@target))
  end

  # The TARGET card grows to a second content row (4 high vs 3) whenever an SNI
  # override is set OR is being edited — so the override is always visible, and the
  # input row only appears once you reach for it (^S).
  private def sni_active? : Bool
    !@sni.strip.empty? || (editing_sni? && @focus == :target)
  end

  private def target_card_h : Int32
    sni_active? ? 4 : 3
  end

  # The TARGET card row prefixes (marker + the field value 1 col to its right). Kept
  # as constants so render_target and the click→caret mapping agree on the value base.
  TARGET_PREFIX = "›"
  SNI_PREFIX    = "SNI ›"

  # The TARGET band's SNI override marker (not a toggle — `^S` edits the row below).
  SNI_BADGE = " SNI "

  # Left stop for the TARGET band's right-chained chrome: one column clear of the card
  # title, which `Frame.card` draws at `rect.x + 2`.
  private def target_chip_min(rect : Rect) : Int32
    rect.x + 9
  end

  # The TARGET band's right-to-left chrome after the READ/INS mode chip: the SNI marker,
  # then the `^V` transport chip. Returns `{sni_x, transport_right_edge}` — `sni_x` nil when
  # no override is set or the marker doesn't fit. Pure geometry, shared by `render_target`
  # and `chrome_hit`.
  #
  # The SNI marker used to place itself at `rect.right - size - 1`, which is INSIDE the mode
  # chip's cells: setting an SNI override painted over the right columns of the mode label,
  # leaving a truncated chip behind. Chaining it fixes that too.
  private def target_chrome_chain(rect : Rect) : {Int32?, Int32}
    min_x = target_chip_min(rect)
    edge = rect.right - 1
    mode = Frame.mode_badge_label(target_insert?)
    edge -= mode.size if edge - mode.size >= rect.x + 8 # the mode chip's own stop — see render_target
    sni_x = nil
    if !@sni.strip.empty? && edge - SNI_BADGE.size >= min_x
      edge -= SNI_BADGE.size
      sni_x = edge
    end
    {sni_x, edge}
  end

  private def field_base(rect : Rect, prefix : String) : Int32
    rect.x + 2 + prefix.size + 1
  end

  # Inverts render's layout: a 3-row target band on top, then a half-width
  # request|response split (the column at content.x + half is the divider).
  def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
    return nil unless @loaded && rect.contains?(mx, my)
    target_h = {rect.h, target_card_h}.min
    return :target if my < rect.y + target_h
    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    return nil if content.h <= 0
    half = {(content.w - 1) // 2, 1}.max
    return :request if mx < content.x + half
    mx >= content.x + half + 1 ? :response : nil
  end

  # Whether the request column is split into two editor cards (WS handshake + messages, or
  # a decode tab's envelope + payload). The predicate `req_editor`, `mark_req_edit`,
  # `render` and the hit-tests all branch on — spelled once so they cannot drift.
  private def req_split? : Bool
    !@decode_kind.nil? || ws_mode?
  end

  # Which request sub-pane the point (mx, my) falls in — `:decoded` for the lower card of a
  # split column, `:envelope` otherwise (and always, for a single-pane tab). nil when the
  # column has no room to draw. Geometry only; the caller decides what to do with it.
  private def request_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
    col = request_col_rect(rect) || return nil
    return :envelope unless req_split?
    _, dec = decode_split(col)
    my >= dec.y ? :decoded : :envelope
  end

  # The CONTENT rect (after the card's 1-cell inset) of request sub-pane `pane` inside
  # `rect` — the body rect render() receives. nil when the column is too small to hold one.
  # The click, the drag, the double-click and the wheel all measure with this, so none of
  # them can land on a slightly different rect than the render did.
  private def request_sub_rect(rect : Rect, pane : Symbol) : Rect?
    col = request_col_rect(rect) || return nil
    return col.inset(1, 1) unless req_split?
    env, dec = decode_split(col)
    (pane == :decoded ? dec : env).inset(1, 1)
  end

  # The request half-pane (the whole left column, borders included) — render's own
  # derivation: the target band on top, then a half-width request|response split.
  private def request_col_rect(rect : Rect) : Rect?
    target_h = {rect.h, target_card_h}.min
    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    return nil if content.h <= 0
    half = {(content.w - 1) // 2, 1}.max
    Rect.new(content.x, content.y, half, content.h)
  end

  # Vertical split of the request column into {envelope, decoded} rects for a decode
  # tab — the ACTIVE sub-pane is enlarged (~2/3). Both clamp to ≥1 row so neither
  # vanishes. render() and request_click_to_cursor share this so they never disagree.
  private def decode_split(col : Rect) : {Rect, Rect}
    inactive = {col.h // 3, 1}.max
    env_h = @req_pane == :envelope ? {col.h - inactive, 1}.max : inactive
    env = Rect.new(col.x, col.y, col.w, env_h)
    dec = Rect.new(col.x, col.y + env_h, col.w, {col.h - env_h, 0}.max)
    {env, dec}
  end

  # Vertical split of the RESPONSE column into {handshake, transcript} rects for a WebSocket
  # tab — the request column's `decode_split` on the other side of the divider.
  #
  # The default sizing is deliberately NOT symmetric with `decode_split`: a 101 handshake
  # response is 4-5 header lines, so while the TRANSCRIPT is the active card the handshake
  # keeps the fixed 7 rows it has always had, and the transcript keeps everything else. Only
  # when the handshake becomes the active card does it grow to ~2/3 — which is what makes a
  # long handshake response (a proxy that answers with a full HTML error page, say) readable
  # and selectable instead of a 5-line porthole.
  private def ws_resp_split(col : Rect) : {Rect, Rect}
    handshake_h = if @resp_pane == :handshake
                    {col.h - {col.h // 3, 1}.max, 1}.max
                  else
                    WS_HANDSHAKE_ROWS
                  end
    handshake_h = handshake_h.clamp(1, {col.h - 2, 1}.max)
    handshake = Rect.new(col.x, col.y, col.w, handshake_h)
    transcript = Rect.new(col.x, col.y + handshake_h, col.w, {col.h - handshake_h, 0}.max)
    {handshake, transcript}
  end

  WS_HANDSHAKE_ROWS = 7 # the handshake card's height while the TRANSCRIPT owns the column

  # Whether the RESPONSE column is split into two cards. WebSocket is the only mode that
  # splits it: gRPC and a pipelined group render one transcript over the whole column.
  # `req_split?`'s counterpart, and read by the same shape of hit-test / render code.
  private def resp_split? : Bool
    ws_mode?
  end

  # Which response sub-pane owns the read cursor: `:handshake` | `:transcript`. Always
  # `:transcript` when the column is not split, so a non-WS tab answers exactly as before.
  getter resp_pane : Symbol

  # Whether the response column is a TRANSCRIPT rather than one HTTP response. A flag check —
  # deliberately not `transcript_rows?`, which builds (and caches, and theme-checks) the rows:
  # this is read per drawn row through `resp_navigable?`.
  private def resp_transcript? : Bool
    ws_mode? || @grpc_mode || group_mode?
  end

  # Whether the hex dump is what the response pane is ACTUALLY drawing. `@resp_hex` alone is
  # not that question: `render_response` returns at its WS / gRPC / group branch long before the
  # hex one, so on a transcript the flag describes a pane nobody can see — while
  # `resp_navigable?` still read it and silently killed the caret, the selection and every arrow
  # key with no visual change at all.
  #
  # The flag survives (flip back to a single HTTP response and the dump is still on); only its
  # authority over the transcript is withdrawn. Reachable without any hex chip being clickable
  # on a WS tab: `^X` a plain HTTP response, then edit the request into an upgrade handshake —
  # `apply_request_fields` flips the SAME view into ws_mode and nothing clears `@resp_hex`
  # (`apply_group` is the only place that ever did). With `at_top?` now crossing cards rather
  # than ejecting, that left a response column you could neither navigate nor leave upward.
  private def resp_hex_active? : Bool
    @resp_hex && !resp_transcript?
  end

  # The HANDSHAKE RESPONSE card is the one being read/selected right now. The single
  # predicate `resp_line_source`, `resp_line_count` and the two renderers branch on.
  private def resp_handshake_active? : Bool
    resp_split? && @resp_pane == :handshake
  end

  # The response half-pane (the whole right column, borders included) — render's own
  # derivation, factored out so the click, the drag and the wheel share it.
  private def response_col_rect(rect : Rect) : Rect?
    target_h = {rect.h, target_card_h}.min
    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    return nil if content.h <= 0
    half = {(content.w - 1) // 2, 1}.max
    Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 1}.max, content.h)
  end

  # Which response card the row `my` falls in. `:transcript` for an unsplit column, always.
  private def resp_hit(col : Rect, my : Int32) : Symbol
    return :transcript unless resp_split?
    handshake, _ = ws_resp_split(col)
    my < handshake.bottom ? :handshake : :transcript
  end

  private def resp_body_rect_for(col : Rect, pane : Symbol) : Rect
    return col.inset(1, 1) unless resp_split?
    handshake, transcript = ws_resp_split(col)
    (pane == :handshake ? handshake : transcript).inset(1, 1)
  end

  private def resp_gutter_w(body : Rect) : Int32
    return 0 unless Settings.show_gutter # keep click→cursor mapping aligned with the gutter-less render
    {Gutter.width(resp_line_count), body.w}.min
  end

  # The content rect of the response card the read cursor is on. It used to hard-code the
  # transcript for WS mode, which is why a click on the HANDSHAKE RESPONSE card produced a
  # negative row and was dropped — the card was on screen and unreachable.
  private def response_body_rect(col : Rect) : Rect
    resp_body_rect_for(col, @resp_pane)
  end
end
