require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/comparer_view"

include Gori::Tui

private def flow(method, target, host = "h.test", body = "body",
                 status = 200, size = 50_i64, dur = 1_i64)
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "https", method, host, 443, target,
    status, 100_i64, Gori::Store::FlowState::Complete, size, dur, "text/plain")
  head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice
  resp = "HTTP/1.1 #{status} OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, resp, body.to_slice)
end

# A pair whose bodies differ on exactly one line, so the diff has a same / changed / same shape.
private def diff_view : ComparerView
  v = ComparerView.new
  v.set_pair(flow("GET", "/a", body: "keep\nDROPPED\ntail"),
    flow("GET", "/a", body: "keep\nADDED\ntail"))
  v
end

describe ComparerView do
  it "builds auto labels from slots and prefers a custom name" do
    v = ComparerView.new
    v.label.should eq("empty")
    v.add_flow(flow("GET", "/a"))
    v.label.should contain("GET")
    v.add_flow(flow("POST", "/b"))
    v.label.should contain("⇄")
    v.name = "login vs register"
    v.label.should eq("login vs register")
  end

  # #442 — History's "exactly 2 marked → compare these two". add_flow rings A → B → A, so a
  # caller that wants a specific baseline can't use it: whichever slot the ring happens to be
  # on wins. set_pair fills both and re-arms the ring at A, so the caller decides.
  it "fills both slots at once, re-arming the next-slot ring at A" do
    v = ComparerView.new
    v.add_flow(flow("GET", "/ring")) # ring now points at B
    v.set_pair(flow("GET", "/older"), flow("POST", "/newer"))
    v.both_set?.should be_true
    v.slot(:a).not_nil!.path.should eq("/older")
    v.slot(:b).not_nil!.path.should eq("/newer")
    # Re-armed at A: the next single add replaces the baseline, not the comparison side.
    v.add_flow(flow("GET", "/next")).should eq(:a)
  end

  it "truncates a slot label by display width, not char count" do
    v = ComparerView.new
    # 12 CJK chars ≈ 24 display cols; char-count truncation (path[0,11]) would keep ~22
    # cols and overflow the ~12-col slot. Width-aware truncation must fit the budget.
    v.add_flow(flow("GET", "/日本語テスト日本語ページ路"))
    path = v.label.lchop("GET ")
    path.should end_with("…")
    Screen.display_width(path).should be <= 12
  end

  it "leaves a short ASCII path label untouched (no regression)" do
    v = ComparerView.new
    v.add_flow(flow("GET", "/api/x"))
    v.label.should eq("GET /api/x")
  end

  it "duplicates slots and appends copy to a custom name" do
    v = ComparerView.new
    v.name = "pair"
    a = flow("GET", "/a")
    b = flow("POST", "/b")
    v.set_slot(:a, a)
    v.set_slot(:b, b)
    v.toggle_pane # request mode
    d = v.duplicate
    d.name.should eq("pair copy")
    d.both_set?.should be_true
    d.pane.should eq(:request)
    d.same?(v).should be_false
  end

  it "reset! clears slots and name" do
    v = ComparerView.new
    v.name = "x"
    v.add_flow(flow("GET", "/z"))
    v.reset!
    v.name.should be_nil
    v.both_set?.should be_false
    v.label.should eq("empty")
  end

  it "projects a sub-tab filter subject across both A/B slots (name + host/method)" do
    v = ComparerView.new
    v.set_slot(:a, flow("GET", "/orders", "app.test"))
    v.set_slot(:b, flow("POST", "/login", "api.test"))
    v.name = "auth pair"
    s = v.filter_subject
    s.name.should eq("auth pair")
    s.target.should contain("app.test")
    s.target.should contain("api.test")
    # End-to-end through the matcher: host:/method: narrow either side; free text hits summary.
    Gori::Repeater::SubtabFilter.parse("host:api").matches?(s).should be_true
    Gori::Repeater::SubtabFilter.parse("method:post").matches?(s).should be_true
    Gori::Repeater::SubtabFilter.parse("login").matches?(s).should be_true
    Gori::Repeater::SubtabFilter.parse("host:nope").matches?(s).should be_false
  end

  # Regression: the REQ/RES divider chips were hit-tested one column off the cells
  # they were drawn on — the RES chip's left edge was a dead click and a phantom
  # clickable column sat one past it. render + pane_chip_at now share one geometry
  # helper, so every drawn chip column maps back to its pane.
  #
  # Loaded, not blank, on purpose: a view with NEITHER slot set now spends the whole rect on
  # the onboarding card and draws no divider chrome at all, so a blank view has no chips to
  # be the subject of this example. The state below it pins the other half of that agreement.
  it "pane_chip_at lands on exactly the drawn REQ/RES chip columns" do
    w, h = 80, 20
    backend = MemoryBackend.new(w, h)
    rect = Rect.new(0, 0, w, h)
    v = diff_view
    v.render(Screen.new(backend), rect, focused: true)

    divider_y = rect.y + 1
    row = backend.row(divider_y)
    req = row.index("REQ").not_nil!
    res = row.index("RES").not_nil!

    # " REQ " / " RES " each span one leading + 3 letters + one trailing column.
    (req - 1..req + 3).each do |c|
      v.pane_chip_at(rect, c, divider_y).should eq(:request)
    end
    (res - 1..res + 3).each do |c|
      v.pane_chip_at(rect, c, divider_y).should eq(:response)
    end
    # No phantom hit one column past the RES chip.
    v.pane_chip_at(rect, res + 4, divider_y).should be_nil
    # Wrong row never hits.
    v.pane_chip_at(rect, req, divider_y + 1).should be_nil
  end

  # The other half of that agreement. With neither slot picked, `render` hands the whole rect to
  # the onboarding card and skips the header / divider / selector block — so the selector must
  # not be clickable either. Both read `blank?`, which is what makes them impossible to
  # desynchronise: a hit-test derived from `pane_selector_geom` alone would still report a chip
  # on a row the card is drawing.
  it "declines a selector click while the onboarding card owns the rect" do
    w, h = 80, 20
    backend = MemoryBackend.new(w, h)
    rect = Rect.new(0, 0, w, h)
    v = ComparerView.new
    v.blank?.should be_true
    v.render(Screen.new(backend), rect, focused: true)

    divider_y = rect.y + 1
    backend.row(divider_y).includes?("REQ").should be_false
    (rect.x...rect.right).each do |c|
      v.pane_chip_at(rect, c, divider_y).should be_nil # (col #{c})
    end
    # …and the card it drew instead is the Comparer one, not a bare line.
    backend.contains?("COMPARER").should be_true
    backend.contains?("nothing to compare").should be_true
  end

  # One side loaded is NOT the blank state: the header naming the flow that IS set is worth
  # reading, so that branch keeps the chrome and puts the card in the body — with a title that
  # names the side still missing rather than repeating the generic headline.
  it "keeps the chrome and names the missing side with one slot set" do
    w, h = 80, 20
    backend = MemoryBackend.new(w, h)
    rect = Rect.new(0, 0, w, h)
    v = ComparerView.new
    v.add_flow(flow("GET", "/only"))
    v.blank?.should be_false
    v.both_set?.should be_false
    v.render(Screen.new(backend), rect, focused: true)

    backend.row(rect.y).includes?("/only").should be_true # the loaded side still names its flow
    backend.contains?("pick flow B").should be_true
    v.pane_chip_at(rect, backend.row(rect.y + 1).index("REQ").not_nil!, rect.y + 1).should eq(:request)
  end

  # A body line wider than a diff column used to be clipped with no way to see the tail,
  # which is exactly where a comparison matters (a long JSON line, a JWT, a query string).
  # ⇧←/→ now shifts BOTH columns by one shared offset so the LCS alignment survives.
  describe "horizontal scroll" do
    # 40 filler cols + an 8-col tail = 48, past the 38-col column of a width-80 frame.
    same_line = "#{"x" * 40}SAMETAIL"
    a_line = "#{"y" * 40}LEFTTAIL"
    b_line = "#{"y" * 40}RGHTTAIL"
    left_w = (80 - ComparerView::SEP_W) // 2 # 38

    paint = ->(v : ComparerView) {
      backend = MemoryBackend.new(80, 20)
      v.render(Screen.new(backend), Rect.new(0, 0, 80, 20), focused: true)
      (0...20).map { |y| backend.row(y) }
    }

    pair = ->(v : ComparerView) {
      v.set_pair(
        flow("GET", "/a", body: "#{same_line}\n#{a_line}"),
        flow("GET", "/a", body: "#{same_line}\n#{b_line}"))
    }

    it "reveals the clipped tail in BOTH columns, on the styled and the plain path" do
      v = ComparerView.new
      pair.call(v)
      before = paint.call(v)
      before.any?(&.includes?("SAMETAIL")).should be_false # clipped at col 0
      before.any?(&.includes?("LEFTTAIL")).should be_false

      100.times { v.hscroll(1) } # clamps to the widest visible row
      after = paint.call(v)
      # Unchanged row → the syntax-highlighted path; both columns hold the same text, so
      # the tail must land twice on that one row (once per column).
      same_row = after.select(&.includes?("SAMETAIL"))
      same_row.size.should eq(1)
      (same_row[0].split("SAMETAIL").size - 1).should eq(2)
      # Changed row → the plain-text path (diff colours, no syntax overlay).
      chg = after.find(&.includes?("LEFTTAIL")).not_nil!
      chg.should contain("RGHTTAIL")
    end

    it "clamps to the widest row on screen instead of scrolling into blank space" do
      v = ComparerView.new
      pair.call(v)
      100.times { v.hscroll(1) }
      paint.call(v)
      v.xscroll.should eq(48 - left_w) # widest line is 48 cols
    end

    it "steps 4 columns and never goes negative" do
      v = ComparerView.new
      pair.call(v)
      v.hscroll(2)
      v.xscroll.should eq(8)
      v.hscroll(-5)
      v.xscroll.should eq(0)
    end

    it "returns to the left edge when the compared half changes" do
      v = ComparerView.new
      pair.call(v)
      v.hscroll(1)
      v.xscroll.should eq(4)
      v.toggle_pane # RES → REQ: different content, different widths
      v.xscroll.should eq(0)
      v.hscroll(2)
      v.set_pane(:response)
      v.xscroll.should eq(0)
    end
  end
end

# The Comparer was the one tab you could read and not get a byte out of: no caret, no selection,
# no `y` — no copy verb in `Verb::Scope::Comparer` at all. It has a ROW cursor now
# (`ReadPane(line_select_only: true)`): a screen row is two columns of the same diff, so a char
# rectangle would address cells that are not adjacent, and the copy payload is the row projected
# to unified-diff text (`  same` / `- left` / `+ right` / `~ left → right`).
describe "ComparerView row cursor" do
  it "copies the cursor's row as unified text, and the whole diff with nothing selected" do
    v = diff_view
    v.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20), true)
    v.selection?.should be_false
    first = v.copy_text
    first.should_not be_empty
    first[0].should eq(' ') # an unchanged row carries the two-space unified prefix

    all = v.copy_all
    all.lines.size.should be > 1
    all.should contain("DROPPED")
    all.should contain("ADDED")
  end

  it "grows a WHOLE-ROW selection on ⇧↓ and never a partial column span" do
    v = diff_view
    v.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20), true)
    v.move_rows(1, true)
    v.selection?.should be_true
    text = v.copy_text
    text.lines.size.should eq(2)
    text.lines.each { |l| l.size.should be > 1 } # each is a full projected row, not a fragment
    v.clear_selection
    v.selection?.should be_false
  end

  it "places the row cursor at a click inside the diff body" do
    v = diff_view
    rect = Rect.new(0, 0, 100, 20)
    v.render(Screen.new(MemoryBackend.new(100, 20)), rect, true)
    body = v.body_rect(rect)
    v.click_row(body, body.x + 3, body.y + 2)
    v.rowsel.cursor.cy.should eq(2)
    v.copy_text.should eq(v.rowsel.line(2))
  end

  # A wheel notch is a reading gesture: it must move the viewport and leave the cursor put,
  # which is the split every other read pane in the tree makes.
  it "scrolls on the wheel without moving the row cursor" do
    v = ComparerView.new
    long_a = (1..60).map { |i| "line#{i}" }.join("\n")
    long_b = (1..60).map { |i| i == 30 ? "CHANGED" : "line#{i}" }.join("\n")
    v.set_pair(flow("GET", "/a", body: long_a), flow("GET", "/a", body: long_b))
    rect = Rect.new(0, 0, 100, 12)
    v.render(Screen.new(MemoryBackend.new(100, 12)), rect, true)
    v.rowsel.cursor.cy.should eq(0)

    5.times { v.wheel(1) }
    v.rowsel.scroll.should be > 0
    v.rowsel.cursor.cy.should be >= v.rowsel.scroll # pulled into the window, not dragged along
  end

  it "drops the row cursor when the pair or the diffed half changes" do
    v = diff_view
    v.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20), true)
    v.move_rows(2, true)
    v.selection?.should be_true
    v.toggle_pane # request ⇄ response renumbers every row
    v.selection?.should be_false
    v.rowsel.cursor.cy.should eq(0)
  end

  it "carries the intra-line diff to a CHANGED row: shared runs dim, the differing run lit" do
    v = ComparerView.new
    v.set_pair(flow("GET", "/a", body: %({"role":"user"})),
      flow("GET", "/a", body: %({"role":"admin"})))
    b = MemoryBackend.new(100, 20)
    v.render(Screen.new(b), Rect.new(0, 0, 100, 20), true)
    y = (0...20).find { |i| b.row(i).includes?("\"role\":\"user\"") }.not_nil!
    row = b.row(y)
    shared = row.index("\"role\"").not_nil! # the run both sides hold
    diff = row.index("user").not_nil!       # the run only A holds
    b.fg_grid[y][shared].should eq(Theme.muted)
    b.fg_grid[y][diff].should eq(Theme.red)
    # …and the B column's own changed run is the green one.
    gi = row.index("admin").not_nil!
    b.fg_grid[y][gi].should eq(Theme.green)
  end

  it "tints the whole cursor row, both columns and the marker band" do
    v = diff_view
    rect = Rect.new(0, 0, 100, 20)
    b = MemoryBackend.new(100, 20)
    v.render(Screen.new(b), rect, true)
    body = v.body_rect(rect)
    # The cursor is on row 0 of the body; the band must reach the right-hand column too.
    b.bg_grid[body.y][2].should eq(Theme.accent_bg)
    b.bg_grid[body.y][body.right - 3].should eq(Theme.accent_bg)
    b.bg_grid[body.y + 1][2].should_not eq(Theme.accent_bg) # and only that row
  end
end

# A long response whose diff is one line put that line hundreds of ↓ presses from the top,
# with nothing that could ask for it directly. `n`/`⇧N` cross the distance; `f` removes it.
describe "ComparerView change navigation and folding" do
  # 60 identical lines with a single edit in the middle — the shape both features exist for.
  private_long = ->(marker : String) {
    (1..60).map { |i| i == 30 ? marker : "line#{i}" }.join("\n")
  }

  long_pair = -> {
    v = ComparerView.new
    v.set_pair(flow("GET", "/a", body: private_long.call("BEFORE")),
      flow("GET", "/a", body: private_long.call("AFTER")))
    v.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20), true)
    v
  }

  it "jumps the cursor onto the changed row and wraps back to it" do
    v = long_pair.call
    v.rowsel.cursor.cy.should eq(0)
    v.jump_change(1).should be_true
    at = v.rowsel.cursor.cy
    at.should be > 20 # past the first screenful — unreachable without this verb
    v.copy_text.should start_with("~")
    # One change only, so the next/previous jump both wrap back onto it.
    v.jump_change(1).should be_true
    v.rowsel.cursor.cy.should eq(at)
    v.jump_change(-1).should be_true
    v.rowsel.cursor.cy.should eq(at)
  end

  it "reports no change to jump to when the two are identical" do
    v = ComparerView.new
    v.set_pair(flow("GET", "/a", body: "same"), flow("GET", "/a", body: "same"))
    v.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20), true)
    v.jump_change(1).should be_false
  end

  it "folds the unchanged runs to a marker that keeps context around the change" do
    v = long_pair.call
    v.fold?.should be_false
    v.toggle_fold.should be_true
    b = MemoryBackend.new(100, 20)
    v.render(Screen.new(b), Rect.new(0, 0, 100, 20), true)
    screen = (0...20).map { |y| b.row(y) }
    # The whole diff now fits: the change AND its context AND the collapse markers.
    screen.any?(&.includes?("BEFORE")).should be_true
    screen.any?(&.includes?("AFTER")).should be_true
    screen.any?(&.includes?("unchanged line")).should be_true
    screen.count(&.includes?("line29")).should eq(1)  # context kept
    screen.any?(&.includes?("line5")).should be_false # …and the rest collapsed
    v.toggle_fold.should be_false
  end

  # Folding renumbers every row after the first collapsed run, so a cursor carried across by
  # INDEX would silently land somewhere else in the message.
  it "keeps the cursor on the same diff row across a fold toggle" do
    v = long_pair.call
    v.jump_change(1)
    before = v.copy_text
    v.toggle_fold
    v.copy_text.should eq(before)
    v.toggle_fold
    v.copy_text.should eq(before)
  end

  it "projects a fold marker into the copy text rather than dropping the rows silently" do
    v = long_pair.call
    v.toggle_fold
    v.copy_all.should contain("unchanged lines @@")
  end
end

describe "ComparerView meta readout" do
  it "prints each side's status/size/time and the A→B delta" do
    v = ComparerView.new
    v.set_pair(flow("GET", "/admin", status: 403, size: 1234_i64, dur: 31_000_i64),
      flow("GET", "/admin", status: 200, size: 1250_i64, dur: 402_000_i64))
    b = MemoryBackend.new(120, 20)
    v.render(Screen.new(b), Rect.new(0, 0, 120, 20), true)
    header = b.row(0)
    header.should contain("403")
    header.should contain("200")
    header.should contain("1.2 KB")
    header.should contain("31 ms")
    # The pair-level delta rides the divider row, left of the REQ/RES chips.
    divider = b.row(1)
    divider.should contain("403 → 200")
    divider.should contain("+16 B")
    divider.should contain("+371 ms")
    divider.should contain("REQ") # …without displacing the pane selector
  end

  it "drops the readout instead of half-printing it in a narrow column" do
    v = ComparerView.new
    v.set_pair(flow("GET", "/a", status: 403, size: 1234_i64, dur: 31_000_i64),
      flow("GET", "/a", status: 200, size: 1250_i64, dur: 402_000_i64))
    b = MemoryBackend.new(34, 12) # ~15 cols per column: no room for label + meta
    v.render(Screen.new(b), Rect.new(0, 0, 34, 12), true)
    b.row(0).should contain("A:")
    b.row(0).should_not contain("31 ms")
  end
end
