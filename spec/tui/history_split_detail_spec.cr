require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# A History detail at least DETAIL_SPLIT_MIN_W columns wide draws the request beside the
# response. ←/→ walk the same pane chain as ever; only what is drawn changes.

private def split_flow(store) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: "GET", target: "/orders/9", http_version: "HTTP/1.1",
    head: "GET /orders/9 HTTP/1.1\r\nHost: h.test\r\nX-Req-Marker: left-side\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
  body = (1..80).map { |i| "resp-line-#{i}" }.join("\n")
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    body: body.to_slice, content_type: "text/plain"))
  id
end

private def with_split(on : Bool, &)
  prev = Gori::Settings.history_split_detail?
  Gori::Settings.history_split_detail = on
  yield
ensure
  Gori::Settings.history_split_detail = prev.not_nil!
end

private def opened(store, w : Int32) : HistoryView
  split_flow(store)
  view = HistoryView.new
  view.reload(store)
  # The list draws first, as it does on screen: it tells the open how wide the pane is.
  view.render_list(Screen.new(MemoryBackend.new(w, 30)), Rect.new(0, 0, w, 30))
  view.open_detail(store).should be_true
  view
end

private def drawn(view : HistoryView, w : Int32) : MemoryBackend
  b = MemoryBackend.new(w, 30)
  view.render_detail(Screen.new(b), Rect.new(0, 0, w, 30))
  b
end

describe "HistoryView split detail" do
  it "opens where the default detail pane says, with the other side beside it" do
    with_split(true) do
      with_store do |store|
        view = opened(store, 140)
        view.detail_pane.should eq(:request) # Settings.default_detail_pane, split or not
        b = drawn(view, 140)
        b.contains?("X-Req-Marker: left-side").should be_true
        b.contains?("resp-line-1").should be_true
        # Two cards, as the Repeater draws its panes: the pane chips ride their top borders.
        b.row(0).should contain("╭─ REQUEST ")
        b.row(0).should contain("╭─ RESPONSE ")
        # The request sits in the left half, the response in the right.
        req_row = (0...30).find! { |y| b.row(y).includes?("X-Req-Marker") }
        b.row(req_row).index("X-Req-Marker").not_nil!.should be < 70
        resp_row = (0...30).find! { |y| b.row(y).includes?("resp-line-1") }
        b.row(resp_row).index("resp-line-1").not_nil!.should be > 70
      end
    end
  end

  it "keeps one pane at a time on a narrow pane, and when the setting is off" do
    with_store do |store|
      with_split(true) do
        view = opened(store, 100)
        drawn(view, 100).contains?("resp-line-1").should be_false
      end
    end
    with_store do |store|
      with_split(false) do
        view = opened(store, 140)
        drawn(view, 140).row(0).should_not contain("╭─ REQUEST ")
      end
    end
  end

  it "walks the same ←/→ chain, and the half it leaves keeps its place" do
    with_split(true) do
      with_store do |store|
        view = opened(store, 140)
        view.detail_pane_advance(1).should be_true
        view.detail_pane.should eq(:response)
        drawn(view, 140)
        view.scroll_detail(60) # read down the response
        drawn(view, 140)       # the focused render scrolls the caret's line into view
        view.detail_pane_advance(-1).should be_true
        view.detail_pane.should eq(:request)
        # The response half is not focused now, and it shows where it was left.
        b = drawn(view, 140)
        b.contains?("X-Req-Marker").should be_true
        b.contains?("resp-line-58").should be_true
        b.contains?("HTTP/1.1 200 OK").should be_false
        # …and focusing it again comes back there, not to the top.
        view.detail_pane_advance(1).should be_true
        drawn(view, 140).contains?("resp-line-58").should be_true
        view.detail_pane_advance(-1).should be_true
        view.detail_pane_advance(-1).should be_false # left of REQUEST still closes the detail
      end
    end
  end

  # The focus has to be readable at a glance: the focused card is gold, the other card and
  # the shell are not (`HistoryController` frames the shell plain while `split_shown?`).
  it "gilds only the focused card" do
    with_split(true) do
      with_store do |store|
        view = opened(store, 140)
        b = drawn(view, 140)
        row = b.row(0)
        lx = row.index("╭").not_nil!
        rx = row.index("╭", lx + 1).not_nil!
        b.fg_at(lx, 0).should eq(Theme.focus_gold) # REQUEST, where the detail opened
        b.fg_at(rx, 0).should_not eq(Theme.focus_gold)
        view.split_shown?.should be_true
        view.detail_pane_advance(1)
        b = drawn(view, 140)
        b.fg_at(rx, 0).should eq(Theme.focus_gold)
        b.fg_at(lx, 0).should_not eq(Theme.focus_gold)
      end
    end
  end

  it "hit-tests the chips where the split draws them, and the other half's text" do
    with_split(true) do
      with_store do |store|
        view = opened(store, 140)
        b = drawn(view, 140)
        y = 0
        rx = b.row(y).index(" RESPONSE ").not_nil!
        view.detail_pane_at(Rect.new(0, 0, 140, 30), rx + 2, y).should eq(:response)
        lx = b.row(y).index(" REQUEST ").not_nil!
        view.detail_pane_at(Rect.new(0, 0, 140, 30), lx + 2, y).should eq(:request)
        other = view.split_companion_rect(Rect.new(0, 0, 140, 30)).not_nil!
        other.x.should be > 70 # REQUEST is focused, so the other half is the right one
        view.focus_split_companion
        view.detail_pane.should eq(:response)
      end
    end
  end
end
