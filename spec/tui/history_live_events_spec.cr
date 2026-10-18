require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private LE_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"

private def le_flow(store : Gori::Store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "le.test", port: 80, method: "GET",
    target: "/events", http_version: "HTTP/1.1",
    head: "GET /events HTTP/1.1\r\nHost: le.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def le_head(id : Int64) : Gori::Store::CapturedResponse
  Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: LE_HEAD.to_slice,
    content_type: "text/event-stream", state: Gori::Store::FlowState::Pending)
end

private def le_row(store : Gori::Store, view : HistoryView) : String
  view.forget_all_row_memos # what a data_version change does
  view.reload(store)
  backend = MemoryBackend.new(120, 8)
  view.render_list(Screen.new(backend), Rect.new(0, 0, 120, 8))
  (0...8).map { |y| backend.row(y) }.find(&.includes?("/events")).not_nil!
end

# An open event stream in History (#1631): the row says it is open and how many events it has
# delivered, and EVENTS shows when each one arrived.
describe "HistoryView — an open event stream" do
  it "shows ● and the events so far on the row while the flow is Pending" do
    with_store do |store|
      id = le_flow(store)
      store.append_live(id, 0_i64, Bytes.empty, le_head(id))
      store.flush
      view = HistoryView.new
      view.set_column_store(store)
      le_row(store, view).should match(/● *$/) # open, nothing counted yet

      store.append_live(id, 0_i64, "data: a\n\ndata: b\n\n".to_slice, nil, 0,
        Gori::Sse::Arrivals.pack([1_i64, 2_i64]))
      store.flush
      le_row(store, view).should contain("● 2")

      store.append_live(id, 18_i64, "data: c\n\n".to_slice, nil, 2, Gori::Sse::Arrivals.pack([3_i64]))
      store.flush
      le_row(store, view).should contain("● 3")

      done = Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: LE_HEAD.to_slice,
        body: "data: a\n\ndata: b\n\ndata: c\n\n".to_slice, content_type: "text/event-stream",
        duration_us: 1_000_000_i64)
      done.live = true
      store.update_response(done)
      le_row(store, view).should_not contain("●")
    end
  end

  it "shows each event's arrival in EVENTS, and none for a stream captured untimed" do
    with_store do |store|
      id = le_flow(store)
      store.append_live(id, 0_i64, "event: message\ndata: a\n\nevent: message\ndata: b\n\n".to_slice,
        le_head(id), 0, Gori::Sse::Arrivals.pack([5_000_i64, 417_900_i64]))
      store.flush
      untimed = le_flow(store)
      store.append_live(untimed, 0_i64, "data: a\n\n".to_slice, le_head(untimed))
      store.flush

      view = HistoryView.new
      view.reload(store)
      {id      => ["▸ event #1  +0.000s  type=message", "▸ event #2  +0.412s  type=message"],
       untimed => ["▸ event #1"]}.each do |flow, rows|
        view.open_detail_id(flow, store)
        view.set_detail_pane_public(:events)
        backend = MemoryBackend.new(100, 20)
        view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 20))
        (0...20).compact_map { |y| backend.row(y)[/▸ event.*\S/]? }.should eq(rows)
      end
    end
  end
end
