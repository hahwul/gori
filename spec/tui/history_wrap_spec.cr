require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The detail body rect the view derives internally, re-derived here so a click spec can aim
# at a real cell. Mirrors `render_detail` and `HistoryController#detail_text_rect`: the pane
# chip strip and the mode row, then a 1-column inset each side. `render_detail` is handed the
# framed card's INNER rect by the controller, so the specs pass their rect straight through.
private def detail_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  Gori::Tui::Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max,
    {rect.bottom - (rect.y + 2), 0}.max)
end

private def tmp_store(&)
  path = File.tempname("gori-hw", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A flow whose RESPONSE carries `body`, opened on the response pane with the body level
# focused. The response's line space is: status line, Content-Type, blank, then the body.
private def response_view(store, body : String, ct : String = "text/plain") : Gori::Tui::HistoryView
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "GET", target: "/api", http_version: "HTTP/1.1",
    head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n\r\n".to_slice,
    body: body.to_slice, content_type: ct))
  view = Gori::Tui::HistoryView.new
  view.reload(store)
  view.open_detail(store)
  view.toggle_pane # request → response
  view.set_detail_focus(:body)
  view
end

# The index of the first BODY line in the response pane's line space (status, header, blank).
private BODY_LI = 3

describe "Gori::Tui::HistoryView detail soft wrap" do
  # The Burp-style contract on the History detail: a body line too wide for the pane spills
  # onto continuation rows, and the line number is printed once, on the first of them.
  it "wraps a long response line and numbers only its first visual row" do
    Gori::Settings.show_gutter = true
    tmp_store do |store|
      view = response_view(store, "HEAD#{"." * 100}TAIL")
      rect = Rect.new(0, 0, 80, 20)
      b = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b), rect)
      body = detail_body_rect(rect)
      gw = Gutter.width(4) # status, header, blank, body
      head_row = (0...20).find { |y| b.row(y).includes?("HEAD") }.not_nil!
      b.row(head_row)[body.x, gw].should_not eq(" " * gw) # numbered
      b.row(head_row + 1)[body.x, gw].should eq(" " * gw) # continuation: no number
      b.contains?("TAIL").should be_true                  # on screen, not clipped away
    end
  ensure
    Gori::Settings.show_gutter = true
  end

  # The inverse of that render. Before wrap, screen row N of the detail WAS logical line
  # @detail_scroll + N, so a click on a continuation row selected a line that isn't even
  # drawn there — and the old path went through ReadCursor, which does exactly that sum.
  it "round-trips a click on a continuation row of the detail body" do
    tmp_store do |store|
      view = response_view(store, "0123456789" * 15) # 150 chars, one body line
      rect = Rect.new(0, 0, 80, 20)
      b = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b), rect)
      body = detail_body_rect(rect)
      gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
      cw = body.w - gw
      view.detail_click_to_cursor(body, body.x + gw + 2, body.y + BODY_LI + 1, focused: true)
      view.detail_read.cy.should eq(BODY_LI) # still the BODY line …
      view.detail_read.cx.should eq(cw + 2)  # … one wrapped row in, plus two columns
    end
  end

  # ↓ steps one VISUAL row. It used to step a logical LINE, which on a wrapped line jumped
  # the caret over every continuation row the pane was showing — from the first row of a
  # 400-char body line straight to SENTINEL, skipping the rows in between. Those rows are
  # drawn; nothing but this arrow could reach them.
  it "moves the detail caret down one visual row at a time, then onto the next line" do
    tmp_store do |store|
      view = response_view(store, "#{"z" * 400}\nSENTINEL")
      rect = Rect.new(0, 0, 80, 14)
      view.render_detail(Screen.new(MemoryBackend.new(80, 14)), rect)
      body = detail_body_rect(rect)
      gw = Gori::Settings.show_gutter ? Gutter.width(5) : 0 # status, header, blank, body ×2
      cw = body.w - gw
      BODY_LI.times { view.detail_move(1, 0) } # status → header → blank → the 400-char line
      view.detail_read.cy.should eq(BODY_LI)
      view.detail_read.cx.should eq(0)
      view.detail_move(1, 0)
      view.detail_read.cy.should eq(BODY_LI) # still the same LINE …
      view.detail_read.cx.should eq(cw)      # … one wrapped row into it, at the same column
      rows = (400 + cw - 1) // cw
      (rows - 2).times { view.detail_move(1, 0) }
      view.detail_read.cy.should eq(BODY_LI)
      view.detail_read.cx.should eq((rows - 1) * cw)
      view.detail_move(1, 0)
      view.detail_read.cy.should eq(BODY_LI + 1) # SENTINEL, many wrapped rows below the fold
      # …and the pane scrolled along with it (ensure_detail_visible counts visual rows too).
      b2 = MemoryBackend.new(80, 14)
      view.render_detail(Screen.new(b2), rect)
      b2.contains?("SENTINEL").should be_true
    end
  end

  # ↑ is the exact inverse: a run of ↓ then the same number of ↑ lands back where it began.
  it "moves the detail caret back up through the wrapped rows it came down" do
    tmp_store do |store|
      view = response_view(store, "#{"z" * 400}\nSENTINEL")
      rect = Rect.new(0, 0, 80, 14)
      view.render_detail(Screen.new(MemoryBackend.new(80, 14)), rect)
      6.times { view.detail_move(1, 0) }
      view.detail_read.cy.should eq(BODY_LI) # inside the wrapped line, not past it
      6.times { view.detail_move(-1, 0) }
      view.detail_read.cy.should eq(0)
      view.detail_read.cx.should eq(0)
    end
  end

  # ↑-at-the-very-top pops focus out to the chip strip (HistoryController#detail_body_up).
  # Gated on the logical line alone, a caret parked three rows into a wrapped line 0 would
  # pop instead of stepping up — skipping the very rows the arrow was asked to walk.
  it "is not 'at top' while the caret sits on a continuation row of line 0" do
    tmp_store do |store|
      # A single over-wide status line, so line 0 itself wraps.
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/#{"q" * 200}", http_version: "HTTP/1.1",
        head: "GET /#{"q" * 200} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: nil, content_type: nil))
      view = Gori::Tui::HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true # REQUEST pane: line 0 is the long request line
      view.set_detail_focus(:body)
      rect = Rect.new(0, 0, 80, 14)
      view.render_detail(Screen.new(MemoryBackend.new(80, 14)), rect)

      view.detail_at_top?.should be_true
      view.detail_move(1, 0) # one VISUAL row down — still on line 0
      view.detail_read.cy.should eq(0)
      view.detail_read.cx.should be > 0
      view.detail_at_top?.should be_false # …so ↑ must step back, not pop to the strip
      view.detail_move(-1, 0)
      view.detail_at_top?.should be_true
    end
  end

  # The wheel steps DRAWN rows. With a line-indexed offset one notch jumped the whole
  # wrapped line, so most of a minified body was unreachable by scrolling.
  it "scrolls the detail by one visual row per notch" do
    tmp_store do |store|
      # Four wrapped body lines: more drawn rows than the pane has, or the anchor clamp
      # (max_anchor) correctly refuses to scroll content that already fits.
      view = response_view(store, (1..4).map { |i| "#{('a' + i - 1)}" * 300 }.join('\n'))
      rect = Rect.new(0, 0, 80, 14)
      b = MemoryBackend.new(80, 14)
      view.render_detail(Screen.new(b), rect)
      body = detail_body_rect(rect)
      row = ->(back : MemoryBackend, y : Int32) { back.row(y)[body.x, body.w] }
      top = row.call(b, body.y)
      view.detail_scroll_view(1)
      b2 = MemoryBackend.new(80, 14)
      view.render_detail(Screen.new(b2), rect)
      # One notch advanced by exactly one drawn row: what was the SECOND row is now the first.
      row.call(b2, body.y).should eq(row.call(b, body.y + 1))
      row.call(b2, body.y).should_not eq(top)
    end
  end

  # A selection that covers a wrap boundary must highlight to the END of the visual row, then
  # continue on the next one. Clipping the span per row is the whole of it, and it is exactly
  # the arithmetic that looks right until you count cells.
  it "tints a selection across a wrap break to the end of the row and onto the next" do
    tmp_store do |store|
      view = response_view(store, "0123456789" * 15)
      rect = Rect.new(0, 0, 80, 20)
      b = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b), rect)
      body = detail_body_rect(rect)
      gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
      cw = body.w - gw
      BODY_LI.times { view.detail_move(1, 0) }
      view.detail_read.cy.should eq(BODY_LI)
      (cw + 5).times { view.detail_move(0, 1, selecting: true) }
      b2 = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b2), rect)
      r0 = body.y + BODY_LI # the body line's first visual row
      b2.bg_grid[r0][body.x + gw].should eq(Theme.accent_bg)
      b2.bg_grid[r0][body.x + gw + cw - 1].should eq(Theme.accent_bg) # …tinted to the row's end
      b2.bg_grid[r0 + 1][body.x + gw].should eq(Theme.accent_bg)      # …and resumed below
      b2.bg_grid[r0 + 1][body.x + gw + 4].should eq(Theme.accent_bg)
      # gw+5 is the caret cell itself (also accent_bg); the tint must stop right after it.
      b2.bg_grid[r0 + 1][body.x + gw + 6].should_not eq(Theme.accent_bg)
    end
  end

  # A double-click on a continuation row must take the word UNDER the pointer. It went
  # through `ReadCursor#select_word_at`, whose own hit test resolves `scroll + row` — so on
  # any wrapped pane it grabbed a word from a line that wasn't even drawn there.
  it "double-click selects the word under a continuation row of the detail body" do
    tmp_store do |store|
      view = response_view(store, "#{"x" * 120}NEEDLE#{"y" * 20}")
      rect = Rect.new(0, 0, 80, 20)
      b = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b), rect)
      body = detail_body_rect(rect)
      # NEEDLE lands on the SECOND visual row of the body line; aim at its first cell there.
      ny = (0...20).find { |y| b.row(y).includes?("NEEDLE") }.not_nil!
      nx = b.row(ny).index("NEEDLE").not_nil!
      view.detail_select_word(body, nx, ny).should be_true
      # The run is x…xNEEDLEy…y — one unbroken word-char token, so the whole line is the word.
      view.detail_copy_text.should eq("#{"x" * 120}NEEDLE#{"y" * 20}")
      view.detail_read.cy.should eq(BODY_LI)
    end
  end

  # Every detail pane is navigable, so FRAMES / EVENTS / MESSAGES / SAML / JWT / GRAPHQL /
  # PARAMS all draw through the same wrapped path as req/res — but they are built as
  # PRE-STYLED head arrays (`log_head` + `wrap`), not as the windowed raw body. The wrap is
  # measured on `DetailView#line_text` while the draw slices `#line_at`, so the two have to
  # agree char-for-char on those lines or the colours land a column off the glyphs and every
  # click on the pane resolves to the wrong column. EVENTS stands in for the family.
  it "wraps a pre-styled decoded pane (EVENTS) on the same grid it draws" do
    tmp_store do |store|
      long = "z" * 300
      view = response_view(store, "data: #{long}\n\n", "text/event-stream")
      view.set_detail_pane_public(:events)
      rect = Rect.new(0, 0, 80, 20)
      b = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b), rect)
      body = detail_body_rect(rect)
      gw = Gori::Settings.show_gutter ? Gutter.width(2) : 0 # "▸ event #1" + its data line
      # The data line wrapped: its number rides the first row, the rest are blank-guttered.
      zrow = (0...20).find { |y| b.row(y).includes?("zzz") }.not_nil!
      b.row(zrow)[body.x, gw].should_not eq(" " * gw)
      b.row(zrow + 1)[body.x, gw].should eq(" " * gw)
      # …and a click on the continuation row resolves onto that same logical line, at the
      # column the row's own text starts from — proving line_text and line_at share a grid.
      view.detail_click_to_cursor(body, body.x + gw, zrow + 1, focused: true)
      view.detail_read.cy.should eq(1) # the data line, not the "▸ event #1" header
      view.detail_read.cx.should eq(body.w - gw)
    end
  end

  # Search highlighting scans the WHOLE logical line and clips each hit to the row, so a match
  # straddling a break lights up on BOTH rows. Marking per-row would light it on NEITHER: the
  # head and the tail are each an incomplete match.
  it "highlights a search match that straddles a wrap break on both rows" do
    tmp_store do |store|
      rect = Rect.new(0, 0, 80, 20)
      body = detail_body_rect(rect)
      gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
      cw = body.w - gw
      # Place "SPLITME" so the break falls in its middle.
      pad = cw - 3
      view = response_view(store, "#{"." * pad}SPLITME#{"." * 20}")
      view.search_hl = "SPLITME"
      b = MemoryBackend.new(80, 20)
      view.render_detail(Screen.new(b), rect)
      r0 = body.y + BODY_LI
      b.bg_at(body.x + gw + pad, r0).should eq(Theme.yellow) # "SPL" on the first row …
      b.bg_at(body.x + gw, r0 + 1).should eq(Theme.yellow)   # … "ITME" on the next
    end
  end
end
