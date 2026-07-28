require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/comparer_view"

include Gori::Tui

private def flow(method, target, host = "h.test", body = "body")
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "https", method, host, 443, target,
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
  head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice
  resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, resp, body.to_slice)
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
    v.@slot_a.not_nil!.row.target.should eq("/older")
    v.@slot_b.not_nil!.row.target.should eq("/newer")
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
  it "pane_chip_at lands on exactly the drawn REQ/RES chip columns" do
    w, h = 80, 20
    backend = MemoryBackend.new(w, h)
    rect = Rect.new(0, 0, w, h)
    v = ComparerView.new
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
