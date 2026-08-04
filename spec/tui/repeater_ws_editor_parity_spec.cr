require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Repeater's REQUEST column is one pane for plain HTTP and TWO for a WebSocket flow
# (HANDSHAKE REQUEST over MESSAGES) or a decode tab (ENVELOPE over DECODED). Every editor
# gesture the single-pane case had was gated off, painted for the wrong mode, or simply
# missing in the split one:
#
#   * `request_drag_to_cursor` / `request_select_word` returned early on `@ws_mode ||
#     @decode_kind`, so a drag selected nothing and a double-click took no word;
#   * the WS/gRPC render branches returned before `paint_request_read_chrome`, so READ mode
#     drew no caret and no selection band — an operator pressing ↓ or ⇧→ saw the screen not
#     change and read that as "the keyboard does nothing here";
#   * `render_decoded` passed `cursor: focused` unconditionally, so MESSAGES drew an INSERT
#     caret in both modes and its READ selection — the one `y` copies — was invisible;
#   * the cross-pane arrow step lived inline in `edit_move` (INS only), so a WebSocket tab —
#     which `restore` leaves in READ mode — could not reach HANDSHAKE from MESSAGES with the
#     arrows at all; and
#   * `␣K:KEY` was drawn by `render_request` but absent from `chrome_hit`'s badge list, so
#     the badge was a dead cell.
#
# The shared seam is `request_sub_rect` / `request_hit` / `place_request_caret` /
# `try_cross_req_pane`: the split and the single pane walk the same code now, so a fix on one
# cannot land on only one of them.
describe "RepeaterView WebSocket editor parity" do
  ws_head = "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\n\r\n"

  msgs = -> {
    [
      Gori::Store::WsOutMessage.text("hello world"),
      Gori::Store::WsOutMessage.text("second frame"),
      Gori::Store::WsOutMessage.text("third frame"),
    ]
  }

  # The two request sub-pane CONTENT rects, re-derived exactly as `render` does (target band →
  # left half → `decode_split`, the ACTIVE pane enlarged to ~2/3 → the card's 1-cell inset).
  # Reads `view.req_pane` rather than taking it as an argument: a WS tab opens on MESSAGES
  # (`apply_request_fields` / `load_ws` both set `@req_pane = :decoded`), and hard-coding the
  # other one aims every click a few rows off.
  sub_rects = ->(view : RepeaterView, rect : Rect) {
    target_h = {rect.h, 3}.min # target_card_h with no SNI override
    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    half = {(content.w - 1) // 2, 1}.max
    col = Rect.new(content.x, content.y, half, content.h)
    inactive = {col.h // 3, 1}.max
    env_h = view.req_pane == :envelope ? {col.h - inactive, 1}.max : inactive
    env = Rect.new(col.x, col.y, col.w, env_h)
    dec = Rect.new(col.x, col.y + env_h, col.w, {col.h - env_h, 0}.max)
    {env.inset(1, 1), dec.inset(1, 1)}
  }

  # A rendered WS repeater, optionally switched to the HANDSHAKE pane first. The render pass is
  # load-bearing, not decoration: `@last_cw`, `last_rows` and the wrap memo are all set there,
  # and every geometry inverse below (and `paint_request_read_chrome` itself) is inert until
  # one has run.
  render_ws = ->(rect : Rect, on_handshake : Bool) {
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: msgs.call)
    view.focus_pane(:request)
    view.toggle_req_pane if on_handshake # ^T — the tab opens on MESSAGES
    b = MemoryBackend.new(rect.w, rect.h)
    view.render(Screen.new(b), rect)
    {view, b}
  }

  # The screen column a known token was drawn at, so a click aims at a real cell instead of at
  # a re-derived gutter width (which depends on the buffer's line count and the gutter setting).
  col_of = ->(b : MemoryBackend, y : Int32, token : String) {
    b.row(y).index(token).not_nil!
  }

  describe "mouse drag" do
    it "extends a READ-mode selection inside the MESSAGES pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      _, dec = sub_rects.call(view, rect)
      x0 = col_of.call(b, dec.y, "hello")

      view.request_click_to_cursor(rect, x0, dec.y)
      view.request_drag_to_cursor(rect, x0 + 5, dec.y)

      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("hello")
    end

    it "extends a READ-mode selection inside the HANDSHAKE REQUEST pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true)
      env, _ = sub_rects.call(view, rect)
      x0 = col_of.call(b, env.y, "GET")

      view.request_click_to_cursor(rect, x0, env.y)
      view.request_drag_to_cursor(rect, x0 + 3, env.y)

      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("GET")
    end

    it "extends an INSERT-mode selection in the MESSAGES pane through the editor's own anchor" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      _, dec = sub_rects.call(view, rect)
      x0 = col_of.call(b, dec.y, "hello")

      view.enter_request_insert!
      view.request_click_to_cursor(rect, x0, dec.y)
      view.request_drag_to_cursor(rect, x0 + 5, dec.y)

      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("hello")
    end

    # A drag that wanders out of a 1/3-height sub-pane must keep extending the selection it
    # started rather than jumping buffers — a selection spanning two documents is not something
    # either the band painter or a copy can express.
    it "keeps a drag out of the MESSAGES pane on the MESSAGES buffer" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      _, dec = sub_rects.call(view, rect)
      x0 = col_of.call(b, dec.y, "hello")

      view.request_click_to_cursor(rect, x0, dec.y)
      view.req_pane.should eq(:decoded)
      view.request_drag_to_cursor(rect, x0 + 4, rect.y) # far ABOVE the card

      view.req_pane.should eq(:decoded) # still the pane the press claimed
      view.pane_copy_text.should_not contain("HTTP/1.1")
    end

    # The click is the one gesture that DOES switch panes — and it must invert the layout that
    # was drawn, so the rect comes out before `switch_req_pane` resizes the two cards.
    it "adopts the sub-pane the press landed in" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false) # MESSAGES active
      env, _ = sub_rects.call(view, rect)
      x0 = col_of.call(b, env.y, "GET")

      view.request_click_to_cursor(rect, x0 + 1, env.y)
      view.req_pane.should eq(:envelope)
      view.pane_copy_text.should eq("GET /ws HTTP/1.1") # caret line, no selection
    end
  end

  describe "double-click" do
    it "selects the word under the pointer in the MESSAGES pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      _, dec = sub_rects.call(view, rect)
      x = col_of.call(b, dec.y, "world") + 2 # inside the token

      view.request_click_to_cursor(rect, x, dec.y)
      view.request_select_word.should be_true
      view.pane_copy_text.should eq("world")
    end

    it "selects the word under the pointer in the HANDSHAKE REQUEST pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true)
      env, _ = sub_rects.call(view, rect)
      x = col_of.call(b, env.y, "GET") + 1

      view.request_click_to_cursor(rect, x, env.y)
      view.request_select_word.should be_true
      view.pane_copy_text.should eq("GET")
    end

    # The real two-press sequence ACROSS a pane switch, at ONE physical (mx, my) — the case a
    # spec that re-derives the rect between the presses cannot see. Press 1 adopts the lower
    # card and the split resizes under it: the active pane grows to ~2/3, so the LOWER card's
    # top edge moves UP by ~1/3 of the column (`env.y` is always `col.y`, which is why the
    # upper card is immune and only this direction was ever wrong). A second hit-test would
    # therefore invert the same screen row against a rect that has since moved and spread a
    # word ~10 rows below the pointer. The double-click spreads from the caret press 1 placed
    # instead, so no second inverse exists to disagree.
    it "takes the word actually under the pointer when the press crossed into MESSAGES" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true) # HANDSHAKE active → MESSAGES is the small lower card
      view.req_pane.should eq(:envelope)
      _, dec = sub_rects.call(view, rect)
      y = dec.y + 1 # "second frame", the 2nd message line
      x = col_of.call(b, y, "second") + 2

      view.request_click_to_cursor(rect, x, y) # press 1: adopts MESSAGES, split resizes
      view.req_pane.should eq(:decoded)
      view.request_select_word.should be_true # press 2: SAME cell, no re-derive
      view.pane_copy_text.should eq("second")
    end
  end

  describe "READ-mode chrome" do
    # The functional heart of "the keyboard does nothing": both panes paint a block caret in
    # NORMAL now, so a caret move is visible. `Theme.accent_bg` is the caret/selection tint the
    # plain REQUEST pane has always used.
    it "paints a NORMAL-mode block caret in the MESSAGES pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      view.request_insert?.should be_false
      _, dec = sub_rects.call(view, rect)
      b.bg_grid[dec.y][col_of.call(b, dec.y, "hello")].should eq(Theme.accent_bg)
    end

    it "paints a NORMAL-mode block caret in the HANDSHAKE REQUEST pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true)
      env, _ = sub_rects.call(view, rect)
      b.bg_grid[env.y][col_of.call(b, env.y, "GET")].should eq(Theme.accent_bg)
    end

    it "paints the READ selection band across the MESSAGES pane" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      view.pane_select_line # `x` — the whole caret line
      b2 = MemoryBackend.new(rect.w, rect.h)
      view.render(Screen.new(b2), rect)

      _, dec = sub_rects.call(view, rect)
      x0 = col_of.call(b, dec.y, "hello")
      # "hello world" is 11 chars — the band covers them, tinted like the plain pane's.
      (0...11).each do |i|
        b2.bg_grid[dec.y][x0 + i].should eq(Theme.accent_bg)
      end
      view.pane_copy_text.should eq("hello world")
    end

    # INSERT keeps the editor's own caret + band. The two painters are mutually exclusive by
    # construction (`cursor` is the gate on one, `!ins` on the other), so a mode switch must
    # not leave two carets on screen.
    it "does not paint the READ band while the MESSAGES pane is in INSERT" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, false)
      view.pane_select_line
      view.enter_request_insert!
      b2 = MemoryBackend.new(rect.w, rect.h)
      view.render(Screen.new(b2), rect)

      _, dec = sub_rects.call(view, rect)
      x0 = col_of.call(b, dec.y, "hello")
      b2.bg_grid[dec.y][x0 + 6].should_not eq(Theme.accent_bg) # mid-"world": the READ band is gone
    end
  end

  describe "cross-pane arrows" do
    # `restore` leaves the tab in READ mode, which is exactly the state in which the arrows
    # used to clamp: ↓ stopped at the bottom of HANDSHAKE and ↑ at the top of MESSAGES, so
    # `^T` was the only way between the two panes.
    it "steps ↓ off the HANDSHAKE bottom into MESSAGES in READ mode" do
      rect = Rect.new(0, 0, 100, 30)
      view, _ = render_ws.call(rect, true)
      view.request_insert?.should be_false
      view.req_pane.should eq(:envelope)

      12.times { view.request_read_move(1, 0) } # past the handshake's last line
      view.req_pane.should eq(:decoded)
    end

    it "steps ↑ off the MESSAGES top back into HANDSHAKE in READ mode" do
      rect = Rect.new(0, 0, 100, 30)
      view, _ = render_ws.call(rect, false)
      view.req_pane.should eq(:decoded)

      view.request_read_move(-1, 0)
      view.req_pane.should eq(:envelope)
    end

    # A page is a viewport gesture: it clamps inside its own sub-pane, matching `edit_page` in
    # INSERT (which never went through `edit_move`'s cross-pane branch either).
    it "does not cross panes on PageDown" do
      rect = Rect.new(0, 0, 100, 30)
      view, _ = render_ws.call(rect, true)
      5.times { view.request_read_page(1) }
      view.req_pane.should eq(:envelope)
    end

    # Crossing ends the selection: one `@req_read` serves both buffers, so an anchor carried
    # across would paint a band using one document's coordinates over another's text.
    it "drops the read selection when the arrows cross panes" do
      rect = Rect.new(0, 0, 100, 30)
      view, _ = render_ws.call(rect, false)
      view.pane_select_line
      view.pane_selection?.should be_true

      view.request_read_move(-1, 0)
      view.req_pane.should eq(:envelope)
      view.pane_selection?.should be_false
    end
  end

  describe "READ-mode Home/End" do
    # These move the EDITOR caret directly, so READ has to adopt the result. Without
    # `sync_to`, a plain Home left the anchor where it was and painted a band the operator had
    # just collapsed, while ⇧Home planted no anchor and extended nothing.
    it "extends the read selection on ⇧End and collapses it on a plain Home" do
      rect = Rect.new(0, 0, 100, 30)
      view, _ = render_ws.call(rect, false)

      view.edit_end(selecting: true)
      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("hello world")

      view.edit_home
      view.pane_selection?.should be_false
    end
  end

  describe "border chrome" do
    it "hit-tests the ␣K:KEY badge that render_request draws" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true)
      env, _ = sub_rects.call(view, rect)
      border_y = env.y - 1 # the card's top border, one row above its content
      col = col_of.call(b, border_y, "␣K:KEY")
      view.chrome_hit(rect, col + 2, border_y).should eq(:ws_key)
    end

    it "hit-tests the NOR/INS mode badge on the HANDSHAKE card" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true)
      env, _ = sub_rects.call(view, rect)
      border_y = env.y - 1
      col = col_of.call(b, border_y, "↵:NOR")
      view.chrome_hit(rect, col + 1, border_y).should eq(:mode)
    end

    it "still reports ^R:SEND" do
      rect = Rect.new(0, 0, 100, 30)
      view, b = render_ws.call(rect, true)
      env, _ = sub_rects.call(view, rect)
      border_y = env.y - 1
      col = col_of.call(b, border_y, "^R:SEND")
      view.chrome_hit(rect, col + 2, border_y).should eq(:send)
    end
  end

  describe "pointer-aware wheel" do
    # The wheel used to scroll whichever sub-pane held the caret, so a notch over HANDSHAKE
    # moved MESSAGES. `request_hit` answers the same question the click asks.
    it "scrolls the sub-pane under the pointer, not the active one" do
      rect = Rect.new(0, 0, 100, 20)
      long_head = String.build do |io|
        io << "GET /ws HTTP/1.1\r\n"
        (1..20).each { |i| io << "X-Pad-#{i}: v\r\n" }
        io << "\r\n"
      end
      view = RepeaterView.new
      view.restore("https://ws.test", long_head, false, true, ws_messages: msgs.call)
      view.focus_pane(:request)
      view.req_pane.should eq(:decoded) # MESSAGES is active
      b = MemoryBackend.new(rect.w, rect.h)
      view.render(Screen.new(b), rect)
      b.contains?("GET /ws").should be_true

      env, _ = sub_rects.call(view, rect)
      view.request_scroll_view_at(3, rect, env.x + 1, env.y) # wheel over HANDSHAKE
      b2 = MemoryBackend.new(rect.w, rect.h)
      view.render(Screen.new(b2), rect)

      view.req_pane.should eq(:decoded)          # the wheel is not a focus change
      b2.contains?("GET /ws").should be_false    # HANDSHAKE scrolled off its first line
      b2.contains?("hello world").should be_true # MESSAGES did not move
    end
  end

  describe "response transcript" do
    # ←/→ were gated off for WS / gRPC / group transcripts, leaving vertical motion only —
    # while a mouse drag over the same rows selected by character and `resp_copy_text` copied
    # exactly that span. `resp_drawn_source` reports a 0-column decoration offset for a
    # transcript (only DIFF has one), so the caret columns are the row's own.
    it "moves the read caret horizontally with ←/→ and extends with ⇧→" do
      view = RepeaterView.new
      view.restore("https://ws.test", ws_head, false, true, ws_messages: msgs.call)
      view.apply_ws(Gori::Repeater::WsEngine::Result.new(
        "HTTP/1.1 101 Switching Protocols\r\n\r\n".to_slice,
        [Gori::Repeater::WsEngine::Message.new("out", 1, "ping-payload".to_slice)],
        100_i64, upgraded: true))
      view.focus_pane(:response)
      rect = Rect.new(0, 0, 100, 30)
      view.render(Screen.new(MemoryBackend.new(rect.w, rect.h)), rect)

      view.resp_move(0, 1)
      view.resp_move(0, 1)
      view.resp_cursor.cx.should eq(2)

      view.resp_move(0, 1, selecting: true)
      view.pane_selection?.should be_true
      view.resp_copy_text.should_not be_empty
    end
  end

  # The RESPONSE column is split too — HANDSHAKE RESPONSE over TRANSCRIPT — and the handshake
  # card was on screen and completely unreachable: `response_body_rect` hard-coded the transcript
  # rect, so a click there produced a negative row and was dropped, and `resp_line_source`
  # answered with transcript rows whatever the pointer was over. No caret, no selection, no copy.
  #
  # It now works the same way the request column does: `@resp_pane` picks the line source, the
  # press adopts the card it landed in, and `switch_resp_pane` parks the outgoing pane's
  # {scroll, cursor} while dropping the line-indexed wrap memo that describes the other document.
  describe "response column split" do
    handshake = "HTTP/1.1 101 Switching Protocols\r\n" \
                "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"

    sent = -> {
      view = RepeaterView.new
      view.restore("https://ws.test", ws_head, false, true, ws_messages: msgs.call)
      view.apply_ws(Gori::Repeater::WsEngine::Result.new(
        handshake.to_slice,
        [
          Gori::Repeater::WsEngine::Message.new("out", 1, "ping-payload".to_slice),
          Gori::Repeater::WsEngine::Message.new("in", 1, "pong-payload".to_slice),
        ],
        100_i64, upgraded: true))
      view.focus_pane(:response)
      view
    }

    # Same derivation as `ws_resp_split`: the handshake keeps a fixed 7 rows while the transcript
    # is active, and grows to ~2/3 when it becomes active.
    resp_rects = ->(view : RepeaterView, rect : Rect) {
      target_h = {rect.h, 3}.min
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      half = {(content.w - 1) // 2, 1}.max
      col = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 1}.max, content.h)
      hs_h = view.resp_pane == :handshake ? {col.h - {col.h // 3, 1}.max, 1}.max : 7
      hs_h = hs_h.clamp(1, {col.h - 2, 1}.max)
      hs = Rect.new(col.x, col.y, col.w, hs_h)
      tr = Rect.new(col.x, col.y + hs_h, col.w, {col.h - hs_h, 0}.max)
      {hs.inset(1, 1), tr.inset(1, 1)}
    }

    render = ->(view : RepeaterView, rect : Rect) {
      b = MemoryBackend.new(rect.w, rect.h)
      view.render(Screen.new(b), rect)
      b
    }

    # A token's column WITHIN the response card — the search starts at the card's left edge.
    # A bare `row.index(token)` finds the REQUEST column's copy on the same screen row: row 4
    # holds `GET /ws HTTP/1.1` on the left and `HTTP/1.1 101 …` on the right, and the first
    # match is the one in the pane this spec is not clicking.
    col_in = ->(b : MemoryBackend, card : Rect, y : Int32, token : String) {
      b.row(y).index(token, card.x).not_nil!
    }

    it "opens on the transcript, leaving a non-split column's behaviour untouched" do
      view = sent.call
      view.resp_pane.should eq(:transcript)
      plain = RepeaterView.new
      plain.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      plain.resp_pane.should eq(:transcript)
    end

    it "adopts the HANDSHAKE card on a click and places its caret there" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, _ = resp_rects.call(view, rect)
      x = col_in.call(b, hs, hs.y, "HTTP/1.1")

      view.resp_click_to_cursor(rect, x, hs.y)
      view.resp_pane.should eq(:handshake)
      view.resp_cursor.cy.should eq(0)
      view.resp_copy_text.should eq("HTTP/1.1 101 Switching Protocols")
    end

    it "drag-selects inside the HANDSHAKE card" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, _ = resp_rects.call(view, rect)
      x = col_in.call(b, hs, hs.y, "HTTP/1.1")

      view.resp_click_to_cursor(rect, x, hs.y) # adopts + places
      view.resp_drag_to_cursor(rect, x + 8, hs.y)

      view.pane_selection?.should be_true
      view.resp_copy_text.should eq("HTTP/1.1")
    end

    it "double-clicks a word in the HANDSHAKE card" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, _ = resp_rects.call(view, rect)
      y = hs.y + 3 # the Sec-WebSocket-Accept line
      b.row(y).should contain("Sec-WebSocket-Accept")
      x = col_in.call(b, hs, y, "Accept") + 2

      view.resp_click_to_cursor(rect, x, y)
      view.resp_select_word.should be_true
      view.resp_copy_text.should eq("Sec-WebSocket-Accept")
    end

    it "selects a whole handshake line with x and copies it" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, _ = resp_rects.call(view, rect)
      view.resp_click_to_cursor(rect, col_in.call(b, hs, hs.y + 1, "Upgrade"), hs.y + 1)
      view.resp_pane.should eq(:handshake)

      view.pane_select_line
      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("Upgrade: websocket")
    end

    it "copies the whole handshake head, not the transcript, while that card is active" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, _ = resp_rects.call(view, rect)
      view.resp_click_to_cursor(rect, col_in.call(b, hs, hs.y, "HTTP"), hs.y)

      all = view.pane_copy_all_text
      all.should contain("Sec-WebSocket-Accept")
      all.should_not contain("ping-payload") # that is the transcript's

      # And "copy as" offers the head/body split, because this card really is an HTTP head.
      view.response_parts.should_not be_nil
      view.response_parts.not_nil![0].should contain("101 Switching Protocols")
    end

    it "paints the caret + selection band on the ACTIVE card only" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, tr = resp_rects.call(view, rect)
      # Transcript active: its first row carries the block caret, the handshake's does not.
      b.bg_grid[tr.y][col_in.call(b, tr, tr.y, "→")].should eq(Theme.accent_bg)
      b.bg_grid[hs.y][col_in.call(b, hs, hs.y, "HTTP")].should_not eq(Theme.accent_bg)

      view.toggle_resp_pane.should eq(:handshake)
      b2 = render.call(view, rect)
      hs2, tr2 = resp_rects.call(view, rect)
      b2.bg_grid[hs2.y][col_in.call(b2, hs2, hs2.y, "HTTP")].should eq(Theme.accent_bg)
      b2.bg_grid[tr2.y][col_in.call(b2, tr2, tr2.y, "→")].should_not eq(Theme.accent_bg)
    end

    it "grows the handshake card when it becomes active and shrinks it back" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      render.call(view, rect)
      hs_before, _ = resp_rects.call(view, rect)
      view.toggle_resp_pane
      render.call(view, rect)
      hs_after, _ = resp_rects.call(view, rect)
      hs_after.h.should be > hs_before.h
      view.toggle_resp_pane
      render.call(view, rect)
      resp_rects.call(view, rect)[0].h.should eq(hs_before.h)
    end

    describe "cross-card arrows" do
      it "steps ↓ off the handshake bottom into the transcript" do
        view = sent.call
        rect = Rect.new(0, 0, 100, 30)
        render.call(view, rect)
        view.toggle_resp_pane.should eq(:handshake)

        # Step until it crosses, then stop — further ↓ presses would keep walking DOWN the
        # transcript and the landing line is what this pins.
        20.times { break if view.resp_pane == :transcript; view.resp_move(1, 0) }
        view.resp_pane.should eq(:transcript)
        view.resp_cursor.cy.should eq(0) # landed on the transcript's first line
      end

      it "steps ↑ off the transcript top back into the handshake, at its last line" do
        view = sent.call
        rect = Rect.new(0, 0, 100, 30)
        render.call(view, rect)
        view.resp_pane.should eq(:transcript)

        view.resp_move(-1, 0)
        view.resp_pane.should eq(:handshake)
        view.resp_copy_text.should_not contain("ping-payload")
      end

      # ↑ at the very top of the UPPER card still ejects to the tab bar — that is the only
      # remaining upward exit, and `at_top?` is what the Runner reads for it.
      it "reports at_top? only on the handshake's first line" do
        view = sent.call
        rect = Rect.new(0, 0, 100, 30)
        render.call(view, rect)
        view.at_top?.should be_false # on the transcript: ↑ crosses instead of ejecting
        view.toggle_resp_pane
        20.times { view.resp_move(-1, 0) }
        view.resp_pane.should eq(:handshake)
        view.at_top?.should be_true
      end

      it "drops the selection when the arrows cross cards" do
        view = sent.call
        rect = Rect.new(0, 0, 100, 30)
        render.call(view, rect)
        view.pane_select_line
        view.pane_selection?.should be_true
        view.resp_move(-1, 0)
        view.resp_pane.should eq(:handshake)
        view.pane_selection?.should be_false
      end
    end

    # Each card keeps its own place, like the two TextAreas of the request column do.
    it "parks and restores each card's scroll + caret across a switch" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      render.call(view, rect)
      view.resp_move(1, 0) # transcript, line 1
      view.resp_cursor.cy.should eq(1)

      view.toggle_resp_pane
      render.call(view, rect)
      view.resp_move(1, 0)
      view.resp_move(1, 0) # handshake, line 2
      view.resp_cursor.cy.should eq(2)

      view.toggle_resp_pane # back to the transcript
      view.resp_cursor.cy.should eq(1)
      view.toggle_resp_pane # and back to the handshake
      view.resp_cursor.cy.should eq(2)
    end

    # A parked caret can outlive the document it was parked in: a resend rebuilds the transcript.
    it "clamps a parked caret that no longer exists in its document" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      render.call(view, rect)
      2.times { view.resp_move(1, 0) } # transcript, line 2
      view.toggle_resp_pane            # park it

      # A resend with a single-row transcript (error only) shrinks it under the parked line.
      view.apply_ws(Gori::Repeater::WsEngine::Result.new(
        Bytes.empty, [] of Gori::Repeater::WsEngine::Message, 5_i64, "connect failed"))
      render.call(view, rect)
      view.toggle_resp_pane.should eq(:transcript)
      size, _ = view.resp_line_source
      view.resp_cursor.cy.should be < size # inside the new document, not past its end
    end

    # `bg_grid` proves the CHROME half of the `active` gate. This proves the METRICS half, which
    # is the more dangerous one: both cards render every frame, so whichever wrote
    # `@resp_last_gw`/`@resp_last_cw`/`@resp_last_h` last would win regardless of which card the
    # cursor is on — and every click and wheel notch would then invert against the wrong geometry
    # while the caret still looked correct. A click that lands on the row it aimed at, in the
    # ENLARGED handshake card, can only work if that card published its own numbers.
    it "publishes the active card's own geometry, so a click lands on the row it aimed at" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      render.call(view, rect)
      view.toggle_resp_pane.should eq(:handshake)
      b = render.call(view, rect) # the card is now ~2/3 of the column, with its own gutter width
      hs, _ = resp_rects.call(view, rect)

      # Aim at each of the four head lines in turn; each must resolve to its own index.
      ["HTTP/1.1", "Upgrade:", "Connection:", "Sec-WebSocket-Accept"].each_with_index do |token, li|
        y = hs.y + li
        view.resp_click_to_cursor(rect, col_in.call(b, hs, y, token), y)
        view.resp_cursor.cy.should eq(li)
      end
      view.resp_copy_text.should contain("Sec-WebSocket-Accept")
    end

    # A parked anchor is an index into a document that a resend replaces. `@scroll_sub` is the
    # sharp edge: it indexes INTO a specific line's wrap layout, so restoring one across a park is
    # only meaningful if that line still wraps identically — which nothing can prove. It is zeroed
    # rather than restored, and `apply_ws` clears the whole parked anchor because a send replaces
    # both documents at once.
    it "does not carry a parked sub-row anchor into a rebuilt document" do
      view = sent.call
      rect = Rect.new(0, 0, 60, 30) # narrow, so a transcript row wraps and a sub-row exists
      render.call(view, rect)
      2.times { view.scroll(1) } # walk the anchor into a CONTINUATION row of a wrapped line
      view.toggle_resp_pane.should eq(:handshake)

      view.apply_ws(Gori::Repeater::WsEngine::Result.new(
        handshake.to_slice,
        [Gori::Repeater::WsEngine::Message.new("out", 1, "x".to_slice)],
        7_i64, upgraded: true))
      render.call(view, rect)
      view.toggle_resp_pane.should eq(:transcript)

      # `apply_ws` cleared the parked anchor, so the rebuilt transcript comes back at its top —
      # first logical line, FIRST visual row. A carried sub-row would open the pane part-way into
      # a line that the new document never laid out at that row.
      size, _ = view.resp_line_source
      view.resp_cursor.cy.should be < size
      b = render.call(view, rect)
      _, tr = resp_rects.call(view, rect)
      b.row(tr.y).should contain("→ x") # line 1 from its start, not mid-wrap
      view.resp_cursor.cy.should eq(0)
    end

    # `@resp_hex` can be set on a plain HTTP response and then survive the SAME view becoming a
    # WebSocket tab (edit the request into an upgrade handshake — `apply_request_fields` flips
    # `@ws_mode` and nothing clears the flag). The hex dump is never what a transcript draws, so
    # letting the flag speak for navigability killed the caret, the selection and every arrow key
    # with no visual change — and, with `at_top?` now crossing cards, left a column with no way out.
    it "stays navigable when a stale response-hex flag survives into WebSocket mode" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      view.focus_pane(:response)
      view.toggle_resp_hex
      view.resp_hex?.should be_true
      view.resp_navigable?.should be_false # a real HTTP response: the dump IS what is drawn

      # The same view becomes a WebSocket tab, flag and all.
      view.restore("https://ws.test", ws_head, false, true, ws_messages: msgs.call)
      view.focus_pane(:response)
      view.ws_mode?.should be_true
      view.resp_hex?.should be_true       # the flag survived, as it always did …
      view.resp_navigable?.should be_true # … but it no longer speaks for a pane it cannot draw

      rect = Rect.new(0, 0, 100, 30)
      b = render.call(view, rect)
      hs, _ = resp_rects.call(view, rect)
      view.resp_click_to_cursor(rect, col_in.call(b, hs, hs.y, "not sent"), hs.y)
      view.resp_pane.should eq(:handshake)
      view.at_top?.should be_true # and it can still be left upward
    end

    # ^F over the handshake card searches the handshake, not the transcript.
    it "searches the active card" do
      view = sent.call
      rect = Rect.new(0, 0, 100, 30)
      render.call(view, rect)
      view.response_search_lines("payload").should_not be_empty # transcript
      view.response_search_lines("Sec-WebSocket-Accept").should be_empty

      view.toggle_resp_pane
      view.response_search_lines("Sec-WebSocket-Accept").should_not be_empty
      view.response_search_lines("payload").should be_empty
    end
  end
end
