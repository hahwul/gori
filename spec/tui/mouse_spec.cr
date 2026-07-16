require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Mouse hit-testing is factored into PURE helpers shared by render and the click
# path (the anti-drift contract), so they can be unit-tested without a terminal.
# These guard the geometry the Runner's handle_mouse relies on.

private def tmp_store(&)
  path = File.tempname("gori-mouse", ".db")
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

private def capture(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

private def add_flow(store, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
end

describe "Chrome.menu_segments" do
  it "lays out every tab left-to-right, non-overlapping, on a wide row" do
    rect = Rect.new(2, 1, 140, 1)
    segs = Chrome.menu_segments(rect, :project)
    segs.size.should eq(Chrome::TABS.size) # all tabs fit on a wide row
    segs.map(&.first).should eq(Chrome::TABS.map(&.first))
    segs.each { |(_, r)| r.y.should eq(1) }
    # each segment is to the right of the previous one (no overlap)
    segs.each_cons(2) { |pair| (pair[0][1].right <= pair[1][1].x).should be_true }
  end

  it "maps a click inside a segment back to that tab" do
    rect = Rect.new(2, 1, 120, 1)
    segs = Chrome.menu_segments(rect, :history)
    hist = segs.find { |(s, _)| s == :history }.not_nil![1]
    hit = segs.find { |(_, r)| r.contains?(hist.x + 1, 1) }
    hit.not_nil![0].should eq(:history)
  end

  it "keeps the active tab visible on a narrow row (scroll window)" do
    rect = Rect.new(0, 1, 22, 1)
    # :notes sits near the right end — the windowing must still include it.
    Chrome.menu_segments(rect, :notes).map(&.first).includes?(:notes).should be_true
  end

  it "returns no segments for an empty rect" do
    Chrome.menu_segments(Rect.new(0, 0, 0, 0), :project).empty?.should be_true
  end
end

describe "Chrome.strip_segments" do
  it "indexes the visible sub-tab chips and keeps the active one on-screen" do
    rect = Rect.new(0, 3, 18, 1)
    labels = (1..8).map { |i| "#{i}:tab" }
    segs = Chrome.strip_segments(rect, labels, 7) # active near the end
    segs.map(&.first).includes?(7).should be_true
    segs.each { |(_, r)| r.contains?(r.x, 3).should be_true }
    segs.each_cons(2) { |pair| (pair[0][1].right <= pair[1][1].x).should be_true }
  end

  it "returns no chips for empty labels" do
    Chrome.strip_segments(Rect.new(0, 3, 40, 1), [] of String, 0).empty?.should be_true
  end
end

describe "ConfirmDialog#button_at" do
  it "maps clicks to the confirm/cancel buttons and nil off them" do
    dlg = ConfirmDialog.new("DELETE", "Delete this?", confirm_label: "delete", cancel_label: "cancel")
    area = Rect.new(0, 0, 80, 24)
    box = dlg.overlay_box(area)
    confirm_rect, cancel_rect = dlg.button_rects(box)

    dlg.button_at(box, confirm_rect.x, confirm_rect.y).should eq(:confirm)
    dlg.button_at(box, cancel_rect.x + 1, cancel_rect.y).should eq(:cancel)
    dlg.button_at(box, confirm_rect.right, confirm_rect.y).should be_nil # the gap between buttons
    dlg.button_at(box, box.x, box.y).should be_nil                       # off the button row
  end

  it "returns an empty box when the area is too small to draw (no phantom modal)" do
    dlg = ConfirmDialog.new("T", "msg")
    dlg.overlay_box(Rect.new(0, 0, 12, 4)).empty?.should be_true # too narrow/short → render declines
  end
end

describe "SitemapView#row_at / #marker_hit?" do
  it "maps a click row to the visible node, and the marker cell toggles" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      view = SitemapView.new
      view.reload(store)
      rect = Rect.new(0, 0, 70, 20)
      view.render(Screen.new(MemoryBackend.new(70, 20)), rect)

      # not querying → the tree starts at rect.y + 3 (filter bar + header + divider)
      view.row_at(rect, 5, rect.y + 3).should eq(0)           # first tree row = host node
      view.row_at(rect, 5, rect.y).should be_nil              # the QL bar row, above the tree
      view.row_at(rect, 5, rect.y + 19).should be_nil         # past the populated rows
      view.row_at(rect, rect.right, rect.y + 1).should be_nil # past the right frame column (mx bound)

      view.marker_hit?(rect, rect.x + 1, 0).should be_true  # host marker at depth 0 → x+1
      view.marker_hit?(rect, rect.x + 9, 0).should be_false # elsewhere on the row
    end
  end
end

describe "HistoryView#list_row_at / select-first" do
  it "maps a click to the flow row (newest-first) and select_row updates the selection" do
    tmp_store do |store|
      add_flow(store, "GET", "/a")
      add_flow(store, "POST", "/b")
      view = HistoryView.new
      view.reload(store)
      rect = Rect.new(0, 0, 80, 20)
      view.render_list(Screen.new(MemoryBackend.new(80, 20)), rect, focused: false)

      # not querying → the flow list starts at rect.y + 3 (QL bar + header + divider)
      view.list_row_at(rect, 5, rect.y + 3).should eq(0)   # /b (newest, top)
      view.list_row_at(rect, 5, rect.y + 4).should eq(1)   # /a
      view.list_row_at(rect, 5, rect.y).should be_nil      # the QL bar row, above the list
      view.list_row_at(rect, 5, rect.y + 12).should be_nil # past the 2 populated rows

      view.select_row(1)
      view.selected_index.should eq(1)
    end
  end
end

describe "TextArea#click_to_cursor" do
  it "places the caret at the clicked line/column (a subsequent insert lands there)" do
    rect = Rect.new(0, 0, 40, 10)
    ta = TextArea.new("hello\nworld")
    ta.click_to_cursor(rect, 2, 0); ta.insert('X')
    ta.text.should eq("heXllo\nworld") # row 0, col 2
    ta = TextArea.new("hello\nworld")
    ta.click_to_cursor(rect, 3, 1); ta.insert('Y')
    ta.text.should eq("hello\nworYld") # row 1, col 3
  end

  it "clamps a click past the end of a line / below the text" do
    rect = Rect.new(0, 0, 40, 10)
    ta = TextArea.new("hi\nthere")
    ta.click_to_cursor(rect, 99, 0); ta.insert('!')
    ta.text.should eq("hi!\nthere") # past end → end of line 0
    ta = TextArea.new("hi\nthere")
    ta.click_to_cursor(rect, 0, 7); ta.insert('!')
    ta.text.should eq("hi\n!there") # below text → last line, col 0
  end

  it "maps display columns across a wide (width-2) char" do
    rect = Rect.new(0, 0, 40, 10)
    ta = TextArea.new("あいbo") # あ,い are width 2; b,o width 1 → 'b' starts at display col 4
    ta.click_to_cursor(rect, 4, 0); ta.insert('X')
    ta.text.should eq("あいXbo")
  end

  it "accounts for the line-number gutter offset" do
    rect = Rect.new(0, 0, 40, 10)
    ta = TextArea.new("ab\ncd")
    ta.gutter = true                               # 2 lines → gutter width 3
    ta.click_to_cursor(rect, 4, 0); ta.insert('X') # mx 4 − gutter 3 = content col 1
    ta.text.should eq("aXb\ncd")
  end
end

describe "HexEdit#click_to_nibble" do
  it "maps a hex-digit click to that byte and nibble" do
    he = HexEdit.new(Bytes.new(3) { |i| (0xAA + i * 0x11).to_u8 }) # AA BB CC
    rect = Rect.new(0, 0, 80, 10)
    he.click_to_nibble(rect, 10, 0, 0); he.nib.should eq(0) # byte 0 high (x+10)
    he.click_to_nibble(rect, 11, 0, 0); he.nib.should eq(1) # byte 0 low
    he.click_to_nibble(rect, 13, 0, 0); he.nib.should eq(2) # byte 1 high (+3)
    he.click_to_nibble(rect, 14, 0, 0); he.nib.should eq(3) # byte 1 low
  end

  it "accounts for the mid-row gap after byte 7" do
    he = HexEdit.new(Bytes.new(16) { |i| i.to_u8 })
    rect = Rect.new(0, 0, 80, 10)
    he.click_to_nibble(rect, 35, 0, 0) # byte 8 high = x+10+8*3+1
    he.nib.should eq(16)
  end

  it "maps an ASCII-gutter click to the byte's high nibble" do
    he = HexEdit.new("ABC".to_slice)
    rect = Rect.new(0, 0, 80, 10)
    he.click_to_nibble(rect, 63, 0, 0) # 'C' (byte 2) at x+61+2
    he.nib.should eq(4)
  end

  it "uses scroll + row to resolve the byte offset" do
    he = HexEdit.new(Bytes.new(40) { |i| i.to_u8 }) # 3 rows (16,16,8)
    rect = Rect.new(0, 0, 80, 4)
    he.click_to_nibble(rect, 10, 1, 0); he.nib.should eq(32) # row 1, byte 0 = byte 16
    he.click_to_nibble(rect, 10, 0, 1); he.nib.should eq(32) # scroll 1, row 0 = byte 16
  end

  it "ignores clicks on inter-byte gaps and the offset column" do
    he = HexEdit.new(Bytes.new(3) { |i| i.to_u8 })
    rect = Rect.new(0, 0, 80, 10)
    he.click_to_nibble(rect, 13, 0, 0); he.nib.should eq(2) # byte 1 high
    he.click_to_nibble(rect, 5, 0, 0); he.nib.should eq(2)  # offset column → no-op
    he.click_to_nibble(rect, 12, 0, 0); he.nib.should eq(2) # space between bytes → no-op
  end
end

describe "RepeaterView#pane_at" do
  it "splits the body into target / request / response panes" do
    view = RepeaterView.new
    view.load_blank
    rect = Rect.new(0, 0, 80, 24)
    view.render(Screen.new(MemoryBackend.new(80, 24)), rect, focused: false)

    view.pane_at(rect, rect.x, rect.y).should eq(:target)              # top band
    content_y = rect.y + {rect.h, 3}.min                               # below the target band
    view.pane_at(rect, rect.x + 1, content_y).should eq(:request)      # left half
    view.pane_at(rect, rect.right - 2, content_y).should eq(:response) # right half
  end
end

describe "Frame.left_chip_hit / right_badge_hit" do
  it "maps left-run chip labels with a 1-col gap between them" do
    chips = [{:diff, " d:diff "}, {:hex, " x:hex "}, {:pretty, " p:pretty "}] of {Symbol, String}
    y = 5
    sx = 10
    # " d:diff " is 8 cols → [10,18); gap at 18; " x:hex " [19,26); gap; " p:pretty " [27,37)
    Frame.left_chip_hit(10, y, y, sx, chips).should eq(:diff)
    Frame.left_chip_hit(17, y, y, sx, chips).should eq(:diff)
    Frame.left_chip_hit(18, y, y, sx, chips).should be_nil # the 1-col gap
    Frame.left_chip_hit(19, y, y, sx, chips).should eq(:hex)
    Frame.left_chip_hit(27, y, y, sx, chips).should eq(:pretty)
    Frame.left_chip_hit(10, y + 1, y, sx, chips).should be_nil # wrong row
  end

  it "maps right-chained badges right-to-left and skips ones past min_x" do
    # Rightmost first (matches successive toggle_badge calls).
    badges = [{:cl, "^L", "CL"}, {:mark, "^K", "MARK"}, {:pretty_req, "^U", "PRETTY"}] of {Symbol, String, String}
    y = 3
    right = 40
    # " ^L:CL " = 7 → [33,40); " ^K:MARK " = 9 → [24,33); " ^U:PRETTY " = 11 → [13,24)
    Frame.right_badge_hit(35, y, y, right, 0, badges).should eq(:cl)
    Frame.right_badge_hit(28, y, y, right, 0, badges).should eq(:mark)
    Frame.right_badge_hit(15, y, y, right, 0, badges).should eq(:pretty_req)
    Frame.right_badge_hit(12, y, y, right, 0, badges).should be_nil
    # min_x that clips the leftmost badge(s)
    Frame.right_badge_hit(15, y, y, right, 20, badges).should be_nil # PRETTY would start at 13 < 20
    Frame.right_badge_hit(28, y, y, right, 20, badges).should eq(:mark)
  end
end

describe "RepeaterView#chrome_hit" do
  it "hits response d/x/p chips and request SEND/CL/PRETTY badges on the border row" do
    view = RepeaterView.new
    view.load_blank
    rect = Rect.new(0, 0, 100, 24)
    view.render(Screen.new(MemoryBackend.new(100, 24)), rect, focused: false)

    target_h = {rect.h, 3}.min
    content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
    half = {(content.w - 1) // 2, 1}.max
    resp = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 0}.max, content.h)
    req = Rect.new(content.x, content.y, half, content.h)

    # RESPONSE chips start at resp.x + 12
    view.chrome_hit(rect, resp.x + 12, resp.y).should eq(:diff)
    view.chrome_hit(rect, resp.x + 12 + 9, resp.y).should eq(:hex) # past " d:diff " + gap
    view.chrome_hit(rect, resp.x + 12 + 9 + 9, resp.y).should eq(:pretty)

    # REQUEST right-chain: rightmost is SEND, then CL, PRETTY
    send_label = " ^R:SEND "
    send_x = (req.right - 1) - send_label.size
    view.chrome_hit(rect, send_x + 1, req.y).should eq(:send)
    cl_label = " ^L:CL "
    cl_x = send_x - cl_label.size
    view.chrome_hit(rect, cl_x + 1, req.y).should eq(:cl)
    pretty_label = " ^U:PRETTY "
    pretty_x = cl_x - pretty_label.size
    view.chrome_hit(rect, pretty_x + 1, req.y).should eq(:pretty_req)

    # Body click (not on border chrome) → nil so caret path still runs
    view.chrome_hit(rect, resp.x + 2, resp.y + 2).should be_nil
  end
end

describe "InterceptView#bar_zone_at" do
  it "maps i:CATCH / direction / condition to separate zones" do
    view = InterceptView.new
    rect = Rect.new(0, 0, 80, 1)
    # " i:CATCH " at x+1 (cols 1..9), then gap, then "c:ALL" (default)
    view.bar_zone_at(rect, 2, 0).should eq(:catch)
    view.bar_zone_at(rect, 1 + " i:CATCH ".size + 1, 0).should eq(:direction) # start of c:ALL
    view.bar_zone_at(rect, 40, 0).should eq(:condition)
    view.bar_zone_at(rect, 2, 1).should be_nil # off the bar row
  end
end

describe "Chrome.top_bar_chip_rect" do
  it "returns nil for :notify when there's no unread, and a rect matching the drawn badge otherwise" do
    rect = Rect.new(0, 0, 80, 1)
    Chrome.top_bar_chip_rect(rect, :notify, scope: "scope:2", listen: "127.0.0.1:8080",
      time: "01:37 PM", unread: 0).should be_nil

    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), rect,
      project: "acme", listen: "127.0.0.1:8080", time: "01:37 PM", scope: "scope:2", unread: 3)
    nrect = Chrome.top_bar_chip_rect(rect, :notify, scope: "scope:2", listen: "127.0.0.1:8080",
      time: "01:37 PM", unread: 3).not_nil!
    backend.row(0)[nrect.x, nrect.w].should eq("notify:3")
  end

  it "returns a rect matching the drawn scope chip whether it's on or off" do
    rect = Rect.new(0, 0, 80, 1)
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), rect,
      project: "acme", listen: "127.0.0.1:8080", time: "01:37 PM", scope: "scope:2")
    srect = Chrome.top_bar_chip_rect(rect, :scope, scope: "scope:2", listen: "127.0.0.1:8080",
      time: "01:37 PM").not_nil!
    backend.row(0)[srect.x, srect.w].should eq("scope:2")

    backend2 = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend2), rect,
      project: "acme", listen: "127.0.0.1:8080", time: "01:37 PM", scope: "scope:off")
    srect2 = Chrome.top_bar_chip_rect(rect, :scope, scope: "scope:off", listen: "127.0.0.1:8080",
      time: "01:37 PM").not_nil!
    backend2.row(0)[srect2.x, srect2.w].should eq("scope:off")
  end

  it "keeps notify/scope hit-test rects in sync with the drawn row even when the project name is squeezed" do
    # Narrow rect: chips (notify:3 · scope:99 · 127.0.0.1:8080 · 01:37 PM · ⌘) leave the
    # project name almost no room — exercises the "name squeezed to zero width" branch.
    rect = Rect.new(0, 0, 45, 1)
    backend = MemoryBackend.new(45, 1)
    Chrome.render_top_bar(Screen.new(backend), rect,
      project: "a very long project name", listen: "127.0.0.1:8080", time: "01:37 PM",
      scope: "scope:99", unread: 3)

    nrect = Chrome.top_bar_chip_rect(rect, :notify, scope: "scope:99", listen: "127.0.0.1:8080",
      time: "01:37 PM", unread: 3).not_nil!
    backend.row(0)[nrect.x, nrect.w].should eq("notify:3")

    srect = Chrome.top_bar_chip_rect(rect, :scope, scope: "scope:99", listen: "127.0.0.1:8080",
      time: "01:37 PM", unread: 3).not_nil!
    backend.row(0)[srect.x, srect.w].should eq("scope:99")
  end

  it "returns a rect matching the drawn far-right palette chip (⌘)" do
    rect = Rect.new(0, 0, 80, 1)
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), rect,
      project: "acme", listen: "127.0.0.1:8080", time: "01:37 PM", scope: "scope:2")
    prect = Chrome.top_bar_chip_rect(rect, :palette, scope: "scope:2", listen: "127.0.0.1:8080",
      time: "01:37 PM").not_nil!
    backend.row(0)[prect.x, prect.w].should eq("⌘")
    # Right of the clock chip.
    trect = Chrome.top_bar_chip_rect(rect, :time, scope: "scope:2", listen: "127.0.0.1:8080",
      time: "01:37 PM").not_nil!
    prect.x.should be > trect.x
  end
end

describe "ComparerView#pane_chip_at" do
  it "hits REQ / RES chips on the divider row" do
    view = ComparerView.new
    rect = Rect.new(0, 0, 80, 10)
    # geometry: sx = right - ("←/→ ".dw + 10) - 1; chips after the hint
    hint = "←/→ "
    total = Screen.display_width(hint) + 10
    sx = rect.right - total - 1
    start = sx + Screen.display_width(hint)
    view.pane_chip_at(rect, start, rect.y + 1).should eq(:request)
    view.pane_chip_at(rect, start + 6, rect.y + 1).should eq(:response) # past " REQ " + gap
    view.pane_chip_at(rect, start, rect.y).should be_nil                # header row, not divider
  end
end
