# Drawing the REQUEST column: the editor (plain, hex, or a decode split's two sub-panes), its
# label and badges, the READ-mode selection band, and the marker tint.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # The DECODED split sub-pane: the editable payload (SAML XML / GraphQL query+vars),
  # with a badge naming the codec (+ the SAML param/binding) on the top border.
  private def render_decoded(screen : Screen, rect : Rect, focused : Bool) : Nil
    return if rect.w < 2 || rect.h < 2
    label = if ws_mode?
              "MESSAGES"
            elsif @decode_kind == :saml
              "DECODED · SAML XML"
            else
              "DECODED · GraphQL"
            end
    Frame.card(screen, rect, label, bg: Theme.bg, border: Frame.pane_border(focused))
    if ws_mode?
      # The seeded frames this pane cannot render as a line. Without this the operator sees
      # an empty (or short) MESSAGES pane and has no way to know a PING, a CLOSE 1002 or an
      # RSV1 frame is still in the seed and still going out — which is precisely the
      # difference between reading a result and misreading one. `ws_line_renderable?` owns
      # the rule; this only says so.
      unshown = ws_unshown_seed
      unless unshown.empty?
        badge = " +#{unshown.size} not shown: #{unshown.join(", ")} "
        bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg) if bx > rect.x + label.size + 4
      end
    end
    if @decode_kind == :saml
      badge = " #{@saml_param} · #{@saml_binding == :redirect ? "redirect" : "post"} "
      bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
      screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg) if bx > rect.x + label.size + 4
    end
    # XML/JSON-ish payload / WS messages → plain editing (no HTTP request/header colouring).
    #
    # `cursor` is gated on INSERT, exactly as the plain REQUEST pane gates it, and READ gets
    # the over-painted band + block caret instead. It used to be a bare `focused`: the pane
    # drew an insert caret in both modes, so the operator could not tell which one they were
    # in, and a READ-mode selection — the one `y`/space▸copy actually copies — was invisible
    # while `x`, ⇧arrows and a drag were all quietly building it.
    inner = rect.inset(1, 1)
    ins = focused && request_insert?
    @decoded.render(screen, inner, cursor: ins, highlight: nil, peek: focused, gauge: true, gauge_focused: focused)
    paint_request_read_chrome(screen, inner, @decoded, focused && !ins)
  end

  # The request card's title says WHAT this card is in the pane it sits in. WHICH transport
  # `^R` will dial is the TARGET band's ` ^V:… ` chip, in one place, on every tab.
  #
  # Both facts used to live here — "HANDSHAKE (h1)", "REQUEST (h2)" — because nothing else on
  # screen carried the transport. That cost the card up to five columns of title, and the
  # badge chain measures its left stop from the title: at 100 columns (a 49-wide request
  # column) an h2 tab pushed its own ` ↵:READ ` chip past `min_x` and drew no mode chip at all.
  #
  # An overridden handshake tab is titled REQUEST, not HANDSHAKE: `^R` sends it as an
  # ordinary request and reads a response, the MESSAGES pane is gone, and the card is one
  # card again — it IS a request pane. That the request happens to be an upgrade handshake is
  # the ` ^V:WS→h1 ` chip's line, and the bytes' own.
  private def render_request_label : String
    return "HANDSHAKE REQUEST" if ws_mode? # one of TWO cards here — MESSAGES is the other
    return "GRPC REQUEST" if @grpc_mode
    return "ENVELOPE" if @decode_kind # the full request; the payload is the DECODED split below
    "REQUEST"
  end

  private def render_request(screen : Screen, rect : Rect, focused : Bool) : Nil
    return if rect.w < 2 || rect.h < 2
    label = render_request_label
    ins = focused && request_insert?
    Frame.card(screen, rect, label, bg: Theme.bg, border: Frame.pane_border(focused))
    min_x = rect.x + label.size + 4 # keep clear of the pane title on the top border
    right_edge = rect.right - 1     # leave the right border cell untouched
    # Primary action rides the REQUEST border (discoverable without the footer chord):
    # rightmost, a gold button while idle, recessed while a send is in flight.
    send_edge = Frame.action_badge(screen, right_edge, rect.y, min_x, "^R", "SEND", !@inflight)
    if @grpc_mode # head as text; a unary call's payload is hex-editable (^X → MSG/HEX)
      # `␣F:FRAME` chains left of the hex chip and is drawn in BOTH halves of this branch,
      # because the state it reports matters most exactly while the payload is being hex-edited:
      # off, the five captured length bytes go out in front of the edited payload. Drawn only
      # where it is live (`grpc_reframable?`) — the same condition `chrome_hit` lists it under.
      if h = @req_hex_edit
        hex_edge = Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^X", "HEX", true)
        Frame.toggle_badge(screen, hex_edge, rect.y, min_x, "␣F", "FRAME", @grpc_reframe) if @grpc_reframable
        @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
      else
        msg_edge = send_edge
        if @grpc_reframable
          msg_edge = Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^X", "MSG", false)
          msg_edge = Frame.toggle_badge(screen, msg_edge, rect.y, min_x, "␣F", "FRAME", @grpc_reframe)
        end
        # The gRPC head is a mode-switched text editor like every other non-hex request card
        # (`i`/esc, READ selection, and — since the read chrome landed here — a visible NORMAL
        # caret), so it carries the chip too. It was skipped while its READ caret was invisible;
        # leaving it off now would make this the one pane showing a block caret with nothing on
        # screen naming the mode it belongs to.
        Frame.mode_badge(screen, msg_edge, rect.y, min_x, request_insert?) # the REAL mode — see Frame.mode_badge
        @editor.conceal_spans = [] of {Int32, Int32}                       # gRPC frames aren't §-marker HTTP text — no stale concealment
        @editor.chain_peek_text = nil
        render_plain_request_editor(screen, rect.inset(1, 1), focused, ins)
      end
      return
    end
    if ws_mode?
      # KEY names what happens to the `Sec-WebSocket-Key` line the operator is looking at.
      # OFF (the default) means gori drops it and appends a fresh one, so the key in this
      # editor is NOT the key on the wire — which is worth a badge on its own, because the
      # pane otherwise reads as byte-exact. ON sends the block as written.
      #
      # The NOR/INS chip chains left of it, over the SAME badge list `chrome_hit` measures
      # (`WS_BADGES`), so the click and the draw agree about where each one sits. Without it
      # the WS handshake was the one editor pane in the tree whose input mode was not on
      # screen anywhere — and the pane it belongs to is a `restore`-lands-in-READ tab.
      Frame.mode_badge(screen, Frame.right_badge_edge(right_edge, min_x, WS_BADGES), rect.y, min_x, request_insert?)
      Frame.toggle_badge(screen, send_edge, rect.y, min_x, "␣K", "KEY", @ws_keep_key)
      @editor.conceal_spans = [] of {Int32, Int32} # WS messages aren't §-marker HTTP text — no stale concealment
      @editor.chain_peek_text = nil
      render_plain_request_editor(screen, rect.inset(1, 1), focused, ins)
      return
    end
    if h = @req_hex_edit
      Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^X", "HEX", true)
      @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
      return
    end
    cl_x = Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^L", "CL", @auto_content_length)
    mode_x = Frame.toggle_badge(screen, cl_x, rect.y, min_x, "^U", "PRETTY", false)
    mark_x = Frame.mode_badge(screen, mode_x, rect.y, min_x, request_insert?) # the REAL mode — see Frame.mode_badge
    # The INERT half only. `literal_markers?` is a state nothing else on screen shows: the
    # `§` in this buffer are the capture's own bytes, they will go out verbatim, and `^T`
    # is what declares them markers instead — a warning with its own escape hatch, which is
    # what a border chip is for.
    #
    # The LIT half is gone. Once the markers ARE live they are tinted in the editor, `§N`
    # rides the border, and the chip added nothing but a second name for a key the status
    # strip already advertises — so `^T` on an unmarked request grew a badge that reported
    # no state, which is how it read.
    #
    # NOT on a decode split either. `repeater.toggle-decoded` is context-sensitive: on a
    # SAML/GraphQL tab `^T` switches ENVELOPE ⇄ DECODED instead of inserting a §, so a badge
    # reading `^T:MARK` there names a key that does something else entirely.
    if !decode_mode? && literal_markers?
      Frame.toggle_badge(screen, mark_x, rect.y, min_x, "^T", "MARK", false)
    end
    update_request_marker_tint
    render_plain_request_editor(screen, rect.inset(1, 1), focused, ins)
  end

  # The envelope editor + its READ-mode over-paint, for every non-hex shape of the top
  # request card (plain HTTP, the WS handshake, a gRPC head, a decode tab's ENVELOPE).
  #
  # The two calls belong together and were only paired on the plain-HTTP path: the WS and
  # gRPC branches returned before the over-paint, so in READ mode those panes drew NO caret
  # at all (`cursor` is off outside INS) and no selection band. An operator pressing ↓ or
  # ⇧→ in a WebSocket handshake saw the screen not change — the keyboard was working and
  # only its evidence was missing.
  private def render_plain_request_editor(screen : Screen, inner : Rect, focused : Bool, ins : Bool) : Nil
    @editor.render(screen, inner, cursor: ins, highlight: :request, peek: focused, gauge: true, gauge_focused: focused)
    paint_request_read_chrome(screen, inner, @editor, focused && !ins)
  end

  # READ-mode over-paint (selection tint + block caret) on top of the frame the editor just
  # drew — `TextReadState#paint_chrome`, which carries the reasoning for every line of it.
  #
  # `ed` is passed in rather than read from `req_editor`: the caller knows which card it is
  # drawing, and a split column has two. Deriving it here meant that painting the DECODED
  # card while the ENVELOPE was the active sub-pane would invert the ENVELOPE's `last_rows`
  # into the DECODED rect — two derivations of the same rows, drifting apart. The `active`
  # gate happens to make that unreachable today; the parameter makes it unrepresentable.
  private def paint_request_read_chrome(screen : Screen, rect : Rect, ed : TextArea, active : Bool) : Nil
    @req_read.paint_chrome(screen, rect, ed, active)
  end

  # `row_start` is the char index the drawn row begins at — 0 for an unwrapped line, the
  # wrap break for a continuation row. Columns are measured from THERE, so a tint on a
  # continuation row starts at the pane's left edge like the text it covers.
  private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                 x0 : Int32, x1 : Int32, bg : Color, row_start : Int32 = 0,
                                 clip_x : Int32 = 0, clip_w : Int32 = 0) : Nil
    return if x0 >= x1
    # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
    # CHARS is exactly the retired per-codepoint measure: it drifts right by each
    # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
    # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
    # one of its own. Span edges snap outward so the tint covers whole glyphs.
    a = {Screen.cluster_start(line, {x0, line.size}.min), row_start}.max
    b = Screen.cluster_end(line, {x1, line.size}.min)
    return if a >= b
    px = x + Wrap.row_col(line, nil, row_start, a) - resp_xscroll
    i = a
    while i < b
      e = Screen.cluster_end(line, i + 1)
      seg = line[i...e]
      w = Screen.draw_width(seg)
      # A cluster the h-scroll pushed off either edge is skipped rather than half-painted:
      # those cells belong to the gutter or to the pane next door. Inert with no offset, so
      # a wrapped row draws exactly as it did before the clip existed.
      screen.text(px, y, seg, Theme.text, bg) if resp_xscroll <= 0 || clip_w <= 0 || (px >= clip_x && px + w <= clip_x + clip_w)
      px += w
      i = e
    end
  end
end
