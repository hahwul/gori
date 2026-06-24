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
    rect = Rect.new(2, 1, 120, 1)
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

      view.row_at(rect, 5, rect.y).should eq(0)           # first row = host node
      view.row_at(rect, 5, rect.y - 1).should be_nil      # above the list
      view.row_at(rect, 5, rect.y + 19).should be_nil     # past the populated rows
      view.row_at(rect, rect.right, rect.y).should be_nil # past the right frame column (mx bound)

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

describe "ReplayView#pane_at" do
  it "splits the body into target / request / response panes" do
    view = ReplayView.new
    view.load_blank
    rect = Rect.new(0, 0, 80, 24)
    view.render(Screen.new(MemoryBackend.new(80, 24)), rect, focused: false)

    view.pane_at(rect, rect.x, rect.y).should eq(:target)              # top band
    content_y = rect.y + {rect.h, 3}.min                               # below the target band
    view.pane_at(rect, rect.x + 1, content_y).should eq(:request)      # left half
    view.pane_at(rect, rect.right - 2, content_y).should eq(:response) # right half
  end
end
