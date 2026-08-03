require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The response body rect the view derives internally, re-derived here so a click spec can
# aim at a real cell. Mirrors `resp_click_to_cursor` / `render`: the TARGET card band, then
# the right half of what is left, then the card's 1-cell inset.
private def resp_body_rect(rect : Gori::Tui::Rect) : Gori::Tui::Rect
  target_h = {rect.h, 3}.min # target_card_h with no SNI override
  content = Gori::Tui::Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
  half = {(content.w - 1) // 2, 1}.max
  Gori::Tui::Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 1}.max, content.h).inset(1, 1)
end

private def loaded_view(body : String, ct : String = "text/plain") : Gori::Tui::RepeaterView
  view = Gori::Tui::RepeaterView.new
  view.load_blank
  view.focus_pane(:response)
  hdr = "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n\r\n"
  view.apply(Gori::Repeater::Result.new(hdr.to_slice, body.to_slice, nil, 1000_i64))
  view
end

describe "Gori::Tui::RepeaterView soft wrap" do
  # The Burp-style contract, on the RESPONSE side: a body line too wide for the pane spills
  # onto continuation rows, and the row number is printed once, on the first of them.
  it "wraps a long response line and numbers only its first visual row" do
    Gori::Settings.show_gutter = true
    view = loaded_view("HEAD#{"." * 80}TAIL")
    rect = Rect.new(0, 0, 80, 20)
    b = MemoryBackend.new(80, 20)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    # Find the row holding HEAD; the row under it is a continuation with a blank gutter.
    head_row = (0...20).find { |y| b.row(y).includes?("HEAD") }.not_nil!
    gw = Gutter.width(4)                                # status line + header + blank + body
    b.row(head_row)[body.x, gw].should_not eq(" " * gw) # numbered
    b.row(head_row + 1)[body.x, gw].should eq(" " * gw) # continuation: no number
    b.contains?("TAIL").should be_true                  # the tail is on screen, not clipped away
  ensure
    Gori::Settings.show_gutter = true
  end

  # The inverse of that render. Before wrap, screen row N of the response WAS logical line
  # scroll+N, so a click on a continuation row selected a line that isn't even drawn there.
  it "round-trips a click on a continuation row of the response body" do
    view = loaded_view("0123456789" * 12) # 120 chars, one body line
    rect = Rect.new(0, 0, 80, 20)
    b = MemoryBackend.new(80, 20)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    cw = body.w - gw
    # The body line is the 4th row of the message (status, header, blank, body), so its
    # first visual row is at body.y + 3; the one under it is its continuation.
    view.resp_click_to_cursor(rect, body.x + gw + 2, body.y + 4)
    view.resp_cursor.cy.should eq(3)      # still the BODY line …
    view.resp_cursor.cx.should eq(cw + 2) # … one wrapped row in, plus two columns
  end

  # ↓ steps one VISUAL row. It used to step a logical LINE, which on a wrapped line jumped
  # the caret over every continuation row the pane was showing — from the first row of a
  # 400-char body line straight to SENTINEL, skipping the eleven rows in between. Those rows
  # are drawn; nothing but this arrow could reach them.
  it "moves the response caret down one visual row at a time, then onto the next line" do
    view = loaded_view("#{"z" * 400}\nSENTINEL")
    rect = Rect.new(0, 0, 80, 14)
    b = MemoryBackend.new(80, 14)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(5) : 0 # status, header, blank, body ×2
    cw = body.w - gw
    view.resp_move(1, 0) # header
    view.resp_move(1, 0) # blank
    view.resp_move(1, 0) # the 400-char body line, first visual row
    view.resp_cursor.cy.should eq(3)
    view.resp_cursor.cx.should eq(0)
    view.resp_move(1, 0)
    view.resp_cursor.cy.should eq(3)  # still the same LINE …
    view.resp_cursor.cx.should eq(cw) # … one wrapped row into it, at the same column
    # Every remaining continuation row is its own press; only the last one leaves the line.
    rows = (400 + cw - 1) // cw
    (rows - 2).times { view.resp_move(1, 0) }
    view.resp_cursor.cy.should eq(3)
    view.resp_cursor.cx.should eq((rows - 1) * cw)
    view.resp_move(1, 0)
    view.resp_cursor.cy.should eq(4) # SENTINEL, many wrapped rows below the fold
    # …and the pane scrolled along with it (ensure_visible counts visual rows too).
    b2 = MemoryBackend.new(80, 14)
    view.render(Screen.new(b2), rect)
    b2.contains?("SENTINEL").should be_true
  end

  # Diff mode prefixes every row with a 2-column "+ "/"- ", so the DECORATED line is two
  # columns longer than the text and can need one more row than the bare text would. The
  # caret must be walked in those decorated coordinates — the grid the pane was laid out and
  # drawn on — and handed back in the bare ones the cursor holds.
  #
  # A body of exactly 2×cw is the case that tells the two apart: bare it is 2 rows, decorated
  # it is 3, and that third row IS drawn. Wrapping the bare text would leave the line one
  # press early and make the row unreachable — the same class of bug as skipping wrapped rows
  # entirely, just one row wide.
  it "steps the response caret by visual rows in diff mode, across the +/- decoration" do
    rect = Rect.new(0, 0, 80, 14)
    body = resp_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(7) : 0
    cw = body.w - gw
    payload = "#{"z" * (cw * 2)}\nTAIL"
    view = loaded_view(payload)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
    # A second send gives diff a baseline (the first response) to compare against.
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, payload.to_slice, nil, 1000_i64))
    view.toggle_resp_mode # response → diff
    view.render(Screen.new(MemoryBackend.new(80, 14)), rect)
    # The diff's own line list: status, header, its blank separators, then the two body lines.
    body_li = 5
    body_li.times { view.resp_move(1, 0) }
    view.resp_cursor.cy.should eq(body_li)
    view.resp_cursor.cx.should eq(0)
    view.resp_move(1, 0)
    view.resp_cursor.cy.should eq(body_li) # the SAME diff line, one row down …
    view.resp_cursor.cx.should eq(cw)      # … directly under the column it held
    view.resp_move(1, 0)
    # The third row: the two chars the decoration pushed past the second break. Bare-text
    # wrapping has no such row and would already have moved on to TAIL.
    view.resp_cursor.cy.should eq(body_li)
    view.resp_cursor.cx.should eq(cw * 2)
    view.resp_move(1, 0)
    view.resp_cursor.cy.should eq(body_li + 1) # only now onto TAIL
  end

  # The two grids disagree about the last DIFF_PREFIX_COLS columns of a diff row: text index
  # cw-2 is the start of the decorated line's second row, but would still be on the first row
  # of a bare-text wrap. A click resolves it the decorated way (that is the row it was drawn
  # on), so an arrow that measured the bare text would think the caret was one row higher
  # than it is — and ↑ from there leaves the line entirely instead of moving within it.
  it "agrees with the click about which diff row the caret is on" do
    rect = Rect.new(0, 0, 80, 14)
    body = resp_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(7) : 0
    cw = body.w - gw
    payload = "#{"z" * (cw * 2)}\nTAIL"
    view = loaded_view(payload)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, payload.to_slice, nil, 1000_i64))
    view.toggle_resp_mode
    view.render(Screen.new(MemoryBackend.new(80, 14)), rect)
    body_li = 5
    # Column 0 of that line's SECOND drawn row — the five short lines above it take one row
    # each, so it is the sixth row of the pane.
    view.resp_click_to_cursor(rect, body.x + gw, body.y + body_li + 1)
    view.resp_cursor.cy.should eq(body_li)
    view.resp_cursor.cx.should eq(cw - 2) # the decoration ate two columns of this row
    view.resp_move(-1, 0)
    view.resp_cursor.cy.should eq(body_li) # back to the line's FIRST row, still the same line
    view.resp_cursor.cx.should eq(0)
  end

  # ↑ is the exact inverse: a run of ↓ then the same number of ↑ lands back where it began.
  it "moves the response caret back up through the wrapped rows it came down" do
    view = loaded_view("#{"z" * 400}\nSENTINEL")
    rect = Rect.new(0, 0, 80, 14)
    view.render(Screen.new(MemoryBackend.new(80, 14)), rect)
    6.times { view.resp_move(1, 0) }
    view.resp_cursor.cy.should eq(3) # inside the wrapped line, not past it
    6.times { view.resp_move(-1, 0) }
    view.resp_cursor.cy.should eq(0)
    view.resp_cursor.cx.should eq(0)
  end

  # The wheel steps DRAWN rows. With a line-indexed offset one notch jumped the whole
  # wrapped line, so most of the response was unreachable by scrolling.
  it "scrolls the response by one visual row per notch" do
    view = loaded_view("#{"a" * 300}\n#{"b" * 300}")
    rect = Rect.new(0, 0, 80, 14)
    b = MemoryBackend.new(80, 14)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    resp = ->(back : MemoryBackend, y : Int32) { back.row(y)[body.x, body.w] }
    top = resp.call(b, body.y)
    view.resp_scroll_view(1)
    b2 = MemoryBackend.new(80, 14)
    view.render(Screen.new(b2), rect)
    # One notch advanced by exactly one drawn row: what was the SECOND row is now the first.
    resp.call(b2, body.y).should eq(resp.call(b, body.y + 1))
    resp.call(b2, body.y).should_not eq(top)
  end

  # The diff pane prefixes every row with a 2-column "+ "/"- " decoration, so its wrap runs
  # on a line two columns wider than the one the caret and search address. Getting that
  # conversion wrong puts render and hit-testing on two different grids — which only shows
  # up once a line is wide enough to wrap.
  it "wraps the diff pane on the DECORATED line and still hit-tests the bare text" do
    view = Gori::Tui::RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, "first".to_slice, nil, 1000_i64))
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, ("Q" * 150).to_slice, nil, 1000_i64))
    view.toggle_resp_mode # → diff
    rect = Rect.new(0, 0, 80, 20)
    b = MemoryBackend.new(80, 20)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(view.resp_plain_lines.size) : 0
    row = (0...20).find { |y| b.row(y).includes?("+ QQ") }.not_nil!
    # A click 4 columns into the row BELOW the "+ " one: that row carries no decoration, so
    # its first char is at (row 0's content width - 2) into the bare text.
    view.resp_click_to_cursor(rect, body.x + gw + 4, row + 1)
    cw = body.w - gw
    view.resp_cursor.cx.should eq(cw - 2 + 4)
  end
  # Requirement: a selection that covers a wrap boundary highlights to the END of the
  # visual row, then continues on the next one. Clipping the span per row is the whole of
  # it, and it is exactly the arithmetic that looks right until you count cells.
  it "tints a selection across a wrap break to the end of the row and onto the next" do
    view = loaded_view("0123456789" * 12)
    rect = Rect.new(0, 0, 80, 20)
    b = MemoryBackend.new(80, 20)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    gw = Gori::Settings.show_gutter ? Gutter.width(4) : 0
    cw = body.w - gw
    3.times { view.resp_move(1, 0) } # status, header, blank → the body line
    view.resp_cursor.cy.should eq(3)
    view.resp_move(0, cw + 5, selecting: true) # anchor at col 0, caret 5 columns past the break
    b2 = MemoryBackend.new(80, 20)
    view.render(Screen.new(b2), rect)
    r0 = body.y + 3 # the body line's first visual row
    b2.bg_grid[r0][body.x + gw].should eq(Theme.accent_bg)
    b2.bg_grid[r0][body.x + gw + cw - 1].should eq(Theme.accent_bg) # …tinted to the row's end
    b2.bg_grid[r0 + 1][body.x + gw].should eq(Theme.accent_bg)      # …and resumed below
    b2.bg_grid[r0 + 1][body.x + gw + 4].should eq(Theme.accent_bg)
    # gw+5 is the caret cell itself (also accent_bg); the tint must stop right after it.
    b2.bg_grid[r0 + 1][body.x + gw + 6].should_not eq(Theme.accent_bg)
  end

  # The gutter is sized from a per-mode line count, and those counts are NOT all the same:
  # `resp_line_count` (what the old click path measured with) has no group-transcript
  # branch and falls through to the plain response view's total. A click that re-derived
  # its own content width from that would key the wrap memo at a width the rows were never
  # laid out at — flushing and rebuilding it every click, against a stale anchor. Hit
  # testing reads back the geometry render published instead; this pins that in the one
  # mode where the two counts genuinely disagree.
  it "hit-tests a group transcript at the width RENDER used, not a re-derived one" do
    view = Gori::Tui::RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
    res = Gori::Repeater::Result.new(hdr.to_slice, ("W" * 200).to_slice, nil, 1000_i64)
    view.apply_group([{"req 1", res}])
    rect = Rect.new(0, 0, 80, 20)
    b = MemoryBackend.new(80, 20)
    view.render(Screen.new(b), rect)
    body = resp_body_rect(rect)
    row = (0...20).find { |y| b.row(y).includes?("WWWW") }.not_nil!
    before = view.resp_plain_lines.size
    view.resp_click_to_cursor(rect, body.x + 6, row + 1) # a continuation row of the W line
    view.resp_plain_lines.size.should eq(before)         # sanity: same transcript
    # The caret must be on the W row, one wrapped row in — not on some other transcript row.
    view.resp_plain_lines[view.resp_cursor.cy].should start_with("WWWW")
    view.resp_cursor.cx.should be > 0
  end
end
