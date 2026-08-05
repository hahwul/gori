require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The TEMPLATE editor's content rect the view derives internally, re-derived here so a click
# spec can aim at a real cell. Mirrors `FuzzerView#template_editor_rect`: the TARGET card band,
# then the 45%-tall top row, then its left half, then the card's 1-cell inset.
private def template_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  target_h = {rect.h, 3}.min # target_card_h with no SNI override
  rest = Gori::Tui::Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
  top_h = {rest.h * 45 // 100, 5}.max
  top_h = rest.h if rest.h < 6
  half = {(rest.w - 1) // 2, 1}.max
  Gori::Tui::Rect.new(rest.x, rest.y, half, top_h).inset(1, 1)
end

private def template_view(wire : String) : Gori::Tui::FuzzerView
  view = Gori::Tui::FuzzerView.new
  view.load_request("https://h.test", wire, false, "")
  view.focus_pane(:template)
  view
end

# A request whose FIRST line is `"GET /?q=" + pad + " HTTP/1.1"` — the shape an operator
# actually hits this with (a long query string), long enough to wrap in a half-width pane.
private def long_query_wire(pad : String) : String
  "GET /?q=#{pad} HTTP/1.1\r\nHost: h.test\r\n\r\n"
end

describe "Gori::Tui::FuzzerView template soft wrap" do
  # The Burp-style contract on the Fuzzer template, the same one the Repeater request pane and
  # the History detail carry: a line too wide for the pane spills onto continuation rows, and
  # the line number is printed once, on the first of them.
  it "wraps a long request line and numbers only its first visual row" do
    Gori::Settings.show_gutter = true
    view = template_view(long_query_wire("#{"a" * 200}TAIL"))
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    body = template_body_rect(rect)
    gw = Gutter.width(4) # request line, Host, blank, trailing blank
    get_row = (0...30).find { |y| b.row(y).includes?("GET /?q=") }.not_nil!
    b.row(get_row)[body.x, gw].should_not eq(" " * gw) # numbered
    b.row(get_row + 1)[body.x, gw].should eq(" " * gw) # continuation: no number
    b.contains?("TAIL").should be_true                 # on screen, not clipped off the right edge
  ensure
    Gori::Settings.show_gutter = true
  end

  # …and nothing runs off the right edge any more: the pane used to carry `follow_x`, so the
  # tail of a long line was only reachable by driving the caret into it and letting the whole
  # pane slide sideways. `wrap=` pins @xscroll at 0, so column 0 of every row is column 0 of
  # the buffer's own row.
  it "never scrolls the template sideways once the caret walks a long line" do
    view = template_view(long_query_wire("b" * 300))
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    view.enter_template_insert!
    view.template_end # caret to the far end of the (wrapped) request line
    b2 = MemoryBackend.new(120, 30)
    view.render(Screen.new(b2), rect)
    body = template_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    # The FIRST row still starts with the request line's own first bytes.
    get_row = (0...30).find { |y| b2.row(y).includes?("GET /?q=") }.not_nil!
    b2.row(get_row)[body.x + gw, 8].should eq("GET /?q=")
  end

  # The inverse of that render. Screen row N of the template WAS logical line
  # `@editor.scroll + N`; on a wrapped line that sum names a line which is not drawn there, so
  # a click on a continuation row placed the caret on the wrong line entirely.
  it "round-trips a click on a continuation row of the template" do
    view = template_view(long_query_wire("0123456789" * 20))
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    body = template_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    cw = body.w - gw
    view.template_click_to_cursor(rect, body.x + gw + 2, body.y + 1)
    view.template_read.cy.should eq(0)      # still the request LINE …
    view.template_read.cx.should eq(cw + 2) # … one wrapped row in, plus two columns
  end

  # ↓ steps one VISUAL row in READ mode. Stepping a logical LINE jumped the caret over every
  # continuation row the pane was drawing — from the first row of a long request line straight
  # to `Host:`, skipping rows that nothing else could reach.
  it "moves the READ caret down one visual row at a time, then onto the next line" do
    view = template_view(long_query_wire("z" * 300))
    rect = Rect.new(0, 0, 120, 30)
    view.render(Screen.new(MemoryBackend.new(120, 30)), rect)
    body = template_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    cw = body.w - gw
    line0 = view.template_text.lines.first
    view.template_read.cy.should eq(0)
    view.template_read_move(1, 0)
    view.template_read.cy.should eq(0)  # still the same LINE …
    view.template_read.cx.should eq(cw) # … one wrapped row into it, at the same column
    rows = (line0.size + cw - 1) // cw
    (rows - 2).times { view.template_read_move(1, 0) }
    view.template_read.cy.should eq(0)
    view.template_read.cx.should eq((rows - 1) * cw)
    view.template_read_move(1, 0)
    view.template_read.cy.should eq(1) # Host:, many wrapped rows below the first number
  end

  # ↑ is the exact inverse: a run of ↓ then the same number of ↑ lands back where it began.
  it "moves the READ caret back up through the wrapped rows it came down" do
    view = template_view(long_query_wire("z" * 300))
    rect = Rect.new(0, 0, 120, 30)
    view.render(Screen.new(MemoryBackend.new(120, 30)), rect)
    4.times { view.template_read_move(1, 0) }
    view.template_read.cy.should eq(0) # inside the wrapped line, not past it
    view.template_read.cx.should be > 0
    4.times { view.template_read_move(-1, 0) }
    view.template_read.cy.should eq(0)
    view.template_read.cx.should eq(0)
  end

  # ↑-at-the-very-top pops focus out to the TARGET pane (FuzzerController's `template_up`).
  # Gated on the logical line alone, a caret parked three rows into a wrapped line 0 would pop
  # instead of stepping up — skipping the very rows the arrow was asked to walk. `TextArea#at_top?`
  # already measures the first VISUAL row; this pins it for the pane that just started wrapping.
  it "is not 'at top' while the READ caret sits on a continuation row of line 0" do
    view = template_view(long_query_wire("q" * 300))
    rect = Rect.new(0, 0, 120, 30)
    view.render(Screen.new(MemoryBackend.new(120, 30)), rect)
    view.template_at_top?.should be_true
    view.template_read_move(1, 0) # one VISUAL row down — still on line 0
    view.template_read.cy.should eq(0)
    view.template_read.cx.should be > 0
    view.template_at_top?.should be_false # …so ↑ must step back, not pop to TARGET
    view.template_read_move(-1, 0)
    view.template_at_top?.should be_true
  end

  # The wheel steps DRAWN rows. With a line-indexed offset one notch jumped a whole wrapped
  # line, so most of a long body was unreachable by scrolling.
  it "scrolls the template by one visual row per notch" do
    body_text = (1..6).map { |i| "#{('a' + i - 1)}" * 200 }.join("\r\n")
    view = template_view("POST / HTTP/1.1\r\nHost: h.test\r\n\r\n#{body_text}")
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    body = template_body_rect(rect)
    row = ->(back : MemoryBackend, y : Int32) { back.row(y)[body.x, body.w] }
    top = row.call(b, body.y)
    view.template_scroll_view(1)
    b2 = MemoryBackend.new(120, 30)
    view.render(Screen.new(b2), rect)
    # One notch advanced by exactly one drawn row: what was the SECOND row is now the first.
    row.call(b2, body.y).should eq(row.call(b, body.y + 1))
    row.call(b2, body.y).should_not eq(top)
  end

  # A READ selection that covers a wrap boundary must tint to the END of the visual row, then
  # continue on the next one. `paint_template_read_chrome` used to clip every span to the LINE
  # and paint it at the row of that line's FIRST visual row — so a selection running past a
  # break was banded once, in the wrong cells.
  it "tints a READ selection across a wrap break to the end of the row and onto the next" do
    view = template_view(long_query_wire("0123456789" * 20))
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    body = template_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    cw = body.w - gw
    (cw + 5).times { view.template_read_move(0, 1, selecting: true) }
    b2 = MemoryBackend.new(120, 30)
    view.render(Screen.new(b2), rect)
    r0 = body.y # the request line's first visual row
    b2.bg_grid[r0][body.x + gw].should eq(Theme.accent_bg)
    b2.bg_grid[r0][body.x + gw + cw - 1].should eq(Theme.accent_bg) # …tinted to the row's end
    b2.bg_grid[r0 + 1][body.x + gw].should eq(Theme.accent_bg)      # …and resumed below
    b2.bg_grid[r0 + 1][body.x + gw + 4].should eq(Theme.accent_bg)
    # gw+5 is the caret cell itself (also accent_bg); the tint must stop right after it.
    b2.bg_grid[r0 + 1][body.x + gw + 6].should_not eq(Theme.accent_bg)
  end

  # The READ block caret has to be drawn on the row it is actually on. With `li - scroll` it
  # rode the line's FIRST visual row forever, so walking into a wrapped line left a caret
  # sitting on text it was not addressing.
  it "draws the READ caret on the continuation row it walked onto" do
    view = template_view(long_query_wire("#{"c" * 200}NEEDLE"))
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    line0 = view.template_text.lines.first
    line0.index("NEEDLE").not_nil!.times { view.template_read_move(0, 1) }
    b2 = MemoryBackend.new(120, 30)
    view.render(Screen.new(b2), rect)
    ny = (0...30).find { |y| b2.row(y).includes?("NEEDLE") }.not_nil!
    nx = b2.row(ny).index("NEEDLE").not_nil!
    b2.bg_grid[ny][nx].should eq(Theme.accent_bg) # the caret is ON the N, on NEEDLE's own row
  end

  # A double-click on a continuation row must take the word UNDER the pointer.
  it "double-click selects the word under a continuation row of the template" do
    view = template_view("POST / HTTP/1.1\r\nHost: h.test\r\n\r\n#{"x" * 120}NEEDLE#{"y" * 20}")
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    body = template_body_rect(rect)
    ny = (0...30).find { |y| b.row(y).includes?("NEEDLE") }.not_nil!
    nx = b.row(ny).index("NEEDLE").not_nil!
    view.template_select_word(rect, nx, ny).should be_true
    # The run is x…xNEEDLEy…y — one unbroken word-char token, so the whole line is the word.
    view.template_copy_text.should eq("#{"x" * 120}NEEDLE#{"y" * 20}")
    view.template_read.cy.should eq(3)
    body.w.should be > 0
  end

  # A `§value¦chain§` marker whose band spans a wrap break must be tinted on EVERY row it
  # covers, and the concealed `¦chain` must stay concealed on all of them. Both fall out of
  # `TextArea#paint_bg_regions`' per-row clipping, but this pane is THE place markers are
  # written, so the wrap flip is pinned here.
  it "bands a marker that straddles a wrap break on both of its rows" do
    pad = "p" * 200
    view = template_view("GET /?q=#{pad}§#{"m" * 90}¦b64§ HTTP/1.1\r\nHost: h.test\r\n\r\n")
    rect = Rect.new(0, 0, 120, 30)
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), rect)
    body = template_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    marker_bg = Theme.marker_bg(0)
    banded = (0...30).select { |y| (body.x + gw...body.x + body.w).any? { |x| b.bg_grid[y][x] == marker_bg } }
    banded.size.should be > 1           # the band continues onto the row(s) below its first
    b.contains?("¦b64").should be_false # …and the chain stays concealed on every one of them
  end
end

# The RESULT detail card's interior, re-derived here so a click spec can aim at a real cell.
# Mirrors `FuzzerView#detail_card_rect` → `stack_rects`' third slice, then the card's 1-cell
# inset: the TARGET band, then the 45%-tall top row, and the detail is what is left below.
private def detail_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  target_h = {rect.h, 3}.min # target_card_h with no SNI override
  rest_h = {rect.h - target_h, 0}.max
  rest_y = rect.y + target_h
  top_h = {rest_h * 45 // 100, 5}.max
  top_h = rest_h if rest_h < 6
  Gori::Tui::Rect.new(rect.x, rest_y + top_h, rect.w, {rest_h - top_h, 0}.max).inset(1, 1)
end

# The index of the first line of `body` in the RESPONSE pane's line space. Derived from the
# pane's own lines rather than assumed: `detail_response_lines` splits the raw head, so the
# number of blank rows between the status line and the body follows the captured CRLFs.
private def body_li(view : Gori::Tui::FuzzerView, marker : String) : Int32
  view.detail_plain_lines.index { |l| l.starts_with?(marker) }.not_nil!
end

# A view with its RESULT detail open on `body`, on the RESPONSE pane.
private def detail_view(body : String) : Gori::Tui::FuzzerView
  view = Gori::Tui::FuzzerView.new
  view.load_request("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, "")
  r = Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 1200_i64, 40, 5, 1000_i64, nil, false, false, nil,
    "HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice)
  view.append_result(r)
  view.open_detail
  view
end

describe "Gori::Tui::FuzzerView RESULT detail soft wrap" do
  # The RESULT detail was the last of the three hand-rolled read panes still carrying its own
  # scroll/caret/h-scroll; it is a `ReadPane` now, wrapping like every other reading surface.
  # A fuzz response is attacker-shaped, so "one enormous line" is the normal case here.
  it "wraps a long response line and numbers only its first visual row" do
    Gori::Settings.show_gutter = true
    view = detail_view("HEAD#{"." * 200}TAIL")
    rect = Rect.new(0, 0, 100, 30)
    b = MemoryBackend.new(100, 30)
    view.render(Screen.new(b), rect)
    body = detail_body_rect(rect)
    gw = Gutter.width(view.detail_plain_lines.size)
    head_row = (0...30).find { |y| b.row(y).includes?("HEAD") }.not_nil!
    b.row(head_row)[body.x, gw].should_not eq(" " * gw) # numbered
    b.row(head_row + 1)[body.x, gw].should eq(" " * gw) # continuation: no number
    b.contains?("TAIL").should be_true                  # on screen, not clipped off the right edge
  ensure
    Gori::Settings.show_gutter = true
  end

  # ↓ steps one VISUAL row. It used to step a logical LINE, jumping the caret over every
  # continuation row the pane was drawing.
  it "moves the detail caret down one visual row at a time" do
    view = detail_view("#{"z" * 300}\nSENTINEL")
    rect = Rect.new(0, 0, 100, 30)
    view.render(Screen.new(MemoryBackend.new(100, 30)), rect)
    body = detail_body_rect(rect)
    gw = Gutter.width(view.detail_plain_lines.size)
    cw = body.w - gw
    li = body_li(view, "z")
    li.times { view.detail_move(1, 0) } # down to the 300-char body line
    view.detail_cursor.cy.should eq(li)
    view.detail_cursor.cx.should eq(0)
    view.detail_move(1, 0)
    view.detail_cursor.cy.should eq(li) # still the same LINE …
    view.detail_cursor.cx.should eq(cw) # … one wrapped row into it
    rows = (300 + cw - 1) // cw
    (rows - 1).times { view.detail_move(1, 0) }
    view.detail_cursor.cy.should eq(li + 1) # SENTINEL, several wrapped rows below
  end

  # `detail_cursor_at_top?` decides whether ↑ pops focus back to the RESULTS list. Gated on the
  # logical line alone, a caret three rows into a wrapped line would pop instead of stepping — but
  # here it must also stay true while the caret is genuinely on row 0 of line 0.
  it "reports 'at top' only on the first visual row" do
    view = detail_view("#{"q" * 300}")
    rect = Rect.new(0, 0, 100, 30)
    view.render(Screen.new(MemoryBackend.new(100, 30)), rect)
    view.detail_cursor_at_top?.should be_true
    li = body_li(view, "q")
    li.times { view.detail_move(1, 0) } # onto the long body line
    view.detail_cursor.cy.should eq(li)
    view.detail_cursor_at_top?.should be_false
    li.times { view.detail_move(-1, 0) }
    view.detail_cursor.cy.should eq(0)
    view.detail_cursor_at_top?.should be_true
  end

  # A click on a continuation row must resolve onto the line drawn there. The old path went
  # through `ReadCursor#click_to_cursor`, which resolves `scroll + row`.
  it "round-trips a click on a continuation row of the detail" do
    view = detail_view("0123456789" * 20)
    rect = Rect.new(0, 0, 100, 30)
    b = MemoryBackend.new(100, 30)
    view.render(Screen.new(b), rect)
    body = detail_body_rect(rect)
    gw = Gutter.width(view.detail_plain_lines.size)
    cw = body.w - gw
    li = body_li(view, "0123")
    view.detail_click_to_cursor(rect, body.x + gw + 2, body.y + li + 1) # 2nd visual row of it
    view.detail_cursor.cy.should eq(li)
    view.detail_cursor.cx.should eq(cw + 2)
  end

  # A double-click on a continuation row takes the word UNDER the pointer.
  it "double-click selects the word under a continuation row of the detail" do
    view = detail_view("#{"x" * 120}NEEDLE#{"y" * 20}")
    rect = Rect.new(0, 0, 100, 30)
    b = MemoryBackend.new(100, 30)
    view.render(Screen.new(b), rect)
    ny = (0...30).find { |y| b.row(y).includes?("NEEDLE") }.not_nil!
    nx = b.row(ny).index("NEEDLE").not_nil!
    view.detail_select_word(rect, nx, ny).should be_true
    view.detail_copy_text.should eq("#{"x" * 120}NEEDLE#{"y" * 20}")
    view.detail_cursor.cy.should eq(body_li(view, "xxx"))
  end

  # ⇧←/→ used to h-scroll this pane, so it had NO way to select characters at all (plain ←/→
  # step the pane chain). `FuzzerController#handle_detail` gives the chord to the selection now
  # that there is nothing off to the side to pan to.
  it "extends a character selection across a wrap break instead of h-scrolling" do
    view = detail_view("0123456789" * 20)
    rect = Rect.new(0, 0, 100, 30)
    b = MemoryBackend.new(100, 30)
    view.render(Screen.new(b), rect)
    body = detail_body_rect(rect)
    gw = Gutter.width(view.detail_plain_lines.size)
    cw = body.w - gw
    li = body_li(view, "0123")
    li.times { view.detail_move(1, 0) }
    view.pane_selection?.should be_false
    (cw + 5).times { view.detail_move(0, 1, selecting: true) }
    view.pane_selection?.should be_true
    # The selection ran PAST the wrap break, so the copy carries both rows' worth of bytes.
    view.detail_copy_text.size.should eq(cw + 5)
    # …and it is tinted on the continuation row, not only on the line's first visual row.
    b2 = MemoryBackend.new(100, 30)
    view.render(Screen.new(b2), rect)
    r0 = body.y + li
    b2.bg_grid[r0][body.x + gw + cw - 1].should eq(Theme.accent_bg) # to the end of row 0 …
    b2.bg_grid[r0 + 1][body.x + gw].should eq(Theme.accent_bg)      # … and resumed below
  end

  # The styled overlay is sliced to the SAME row the plain layout wrapped at. The two are
  # measured on different strings (`Wrap` on the plain line, `Highlight.slice_chars` on the
  # styled one), so if they disagreed by even one char the colours would land off the glyphs and
  # every click on the pane would resolve to the wrong column.
  it "keeps the styled overlay aligned with the wrapped rows it draws" do
    src = "0123456789" * 20
    view = detail_view(src)
    rect = Rect.new(0, 0, 100, 30)
    b = MemoryBackend.new(100, 30)
    view.render(Screen.new(b), rect)
    body = detail_body_rect(rect)
    gw = Gutter.width(view.detail_plain_lines.size)
    cw = body.w - gw
    li = body_li(view, "0123")
    # The continuation row's first cell must hold the char the wrap broke AT, not the line's
    # first char (unsliced) and not one off it (a column-based slice).
    b.row(body.y + li + 1)[body.x + gw].should eq(src[cw])
  end
end
