require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-hv", ".db")
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

private def add_flow(store, method, target, status = nil, content_type = nil)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\nbody".to_slice,
      body: "body".to_slice, content_type: content_type))
  end
  id
end

describe Gori::Tui::HistoryView do
  # These specs assert on RAW body rendering; keep the display-only pretty-printer off
  # so a (future) valid-JSON/XML fixture can't silently reflow and shift assertions.
  before_each { Gori::Settings.pretty_bodies_default = false }

  it "loads flows newest-first with the newest selected (follow)" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200)
      last = add_flow(store, "POST", "/b", 500)
      view = HistoryView.new
      view.reload(store)
      view.rows.map(&.target).should eq(["/b", "/a"]) # newest first (Burp/Caido style)
      view.selected_id.should eq(last)                # newest selected, at the top
    end
  end

  it "prepends on :inserted (newest on top) and fills status on :updated" do
    tmp_store do |store|
      view = HistoryView.new
      view.reload(store)
      id = add_flow(store, "GET", "/live") # pending
      view.on_event(Gori::Store::FlowEvent.new(id, :inserted), store)
      view.rows.first.target.should eq("/live")
      view.rows.first.status.should be_nil

      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 204, head: "HTTP/1.1 204 No Content\r\n\r\n".to_slice))
      view.on_event(Gori::Store::FlowEvent.new(id, :updated), store)
      view.rows.first.status.should eq(204)
    end
  end

  it "reports at_top? (drives the ↑-at-top → tab-bar focus flow)" do
    tmp_store do |store|
      3.times { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.at_top?.should be_true # newest is selected at the top (follow)
      view.move(1)
      view.at_top?.should be_false
      view.move(-1)
      view.at_top?.should be_true
    end
  end

  it "moves the selection and disengages follow" do
    tmp_store do |store|
      3.times { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.follow?.should be_true
      view.move(1) # down toward older — newest-first, so this disengages follow
      view.follow?.should be_false
      view.selected_id.should_not be_nil
    end
  end

  it "renders the traffic list with method/path/status columns" do
    tmp_store do |store|
      add_flow(store, "GET", "/search", 200, "application/json; charset=utf-8")
      add_flow(store, "POST", "/orders", 500)
      view = HistoryView.new
      view.reload(store)

      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("METHOD").should be_true
      backend.contains?("STA").should be_true  # status column header (3-wide, sized to the code)
      backend.contains?("TYPE").should be_true # MIME column header
      backend.contains?("json").should be_true # application/json → compact "json" (params dropped)
      backend.contains?("GET").should be_true
      backend.contains?("/search").should be_true
      backend.contains?("500").should be_true
    end
  end

  it "normalizes absolute-form targets to origin-form and shows host + proto columns" do
    tmp_store do |store|
      # plaintext forward-proxy requests are captured absolute-form (the truth)
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "www.hahwul.com", port: 80,
        method: "GET", target: "http://www.hahwul.com/about", http_version: "HTTP/1.1",
        head: "GET http://www.hahwul.com/about HTTP/1.1\r\n\r\n".to_slice, body: nil))
      view = HistoryView.new
      view.reload(store)

      backend = MemoryBackend.new(120, 6)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 120, 6))
      backend.contains?("PROTO").should be_true
      backend.contains?("HOST").should be_true
      backend.contains?("www.hahwul.com").should be_true # host column
      backend.contains?("/about").should be_true         # origin-form path
      backend.contains?("http://").should be_false       # absolute-form stripped from the list
    end
  end

  it "drops trailing columns on a narrow pane without clobbering PATH or overflowing" do
    tmp_store do |store|
      add_flow(store, "GET", "/search", 200, "application/json")
      view = HistoryView.new
      view.reload(store)

      # production-like inset (rect.x=3) at a 65-col terminal: STA stays, TYPE/SIZE/DUR
      # drop, and PATH must remain legible — not collapsed to "/" or overwritten ("PSTA").
      backend = MemoryBackend.new(65, 8)
      view.render_list(Screen.new(backend), Rect.new(3, 0, 59, 8))
      backend.contains?("STA").should be_true
      backend.contains?("PATH").should be_true    # header intact
      backend.contains?("PSTA").should be_false   # STA did not overwrite the PATH header
      backend.contains?("/search").should be_true # PATH value not squeezed to a bare "/"
    end
  end

  it "shows captured WebSocket messages in the detail view" do
    tmp_store do |store|
      id = add_flow(store, "GET", "/ws", 101)
      store.insert_ws_message(id, "out", 1, "hello".to_slice)
      store.insert_ws_message(id, "in", 1, "world".to_slice)

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response (= MESSAGES for a WS flow)

      backend = MemoryBackend.new(80, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("MESSAGES").should be_true
      backend.contains?("hello").should be_true
      backend.contains?("world").should be_true
    end
  end

  it "pretty-prints a JSON response body when enabled, and restores raw when off" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/api", http_version: "HTTP/1.1",
        head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
        body: %({"a":1,"b":[1,2]}).to_slice, content_type: "application/json"))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response

      view.pretty = true
      backend = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 16))
      backend.contains?(%("a": 1)).should be_true # reflowed (space after colon)
      backend.contains?("PRETTY").should be_true  # indicator

      view.pretty = false # display-only toggle restores the raw, single-line body
      raw = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(raw), Rect.new(0, 0, 80, 16))
      raw.contains?(%("a": 1)).should be_false
      raw.contains?("RAW").should be_true
    end
  end

  it "refresh_detail picks up a Pending flow's response but skips a stable Complete one" do
    tmp_store do |store|
      pid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/p", http_version: "HTTP/1.1",
        head: "GET /p HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true # the (only) Pending flow

      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: pid, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
        body: "done".to_slice, content_type: "text/plain"))
      view.refresh_detail(store).should be_true # Pending → picks up the now-Complete response

      # Now Complete + non-streaming → immutable; further pokes are skipped (no rebuild).
      view.refresh_detail(store).should be_false
    end
  end

  it "shows the raw h2 frame log in the detail FRAMES pane" do
    tmp_store do |store|
      conn = store.insert_h2_connection("h.test", 443, "h2")
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/2",
        head: "GET / HTTP/2\r\n\r\n".to_slice, body: nil,
        h2_conn_id: conn, h2_stream_id: 1_i64))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/2 200\r\n\r\n".to_slice))
      store.insert_h2_frame(conn, "out", 0x4_u8, 0_u8, 0_u32, Bytes.new(18))    # SETTINGS stream 0
      store.insert_h2_frame(conn, "out", 0x1_u8, 0x5_u8, 1_u32, "hdr".to_slice) # HEADERS stream 1
      store.flush                                                               # h2 frames are fire-and-forget — barrier before the view reads them

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response
      view.toggle_pane # response -> frames (h2)

      backend = MemoryBackend.new(100, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.contains?("FRAMES (h2)").should be_true
      backend.contains?("Settings").should be_true
      backend.contains?("Headers").should be_true
      backend.contains?("stream=1").should be_true
    end
  end

  it "walks detail panes REQ→RES→FRAMES with ←/→, stopping at the ends" do
    tmp_store do |store|
      conn = store.insert_h2_connection("h.test", 443, "h2")
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/2",
        head: "GET / HTTP/2\r\n\r\n".to_slice, body: nil,
        h2_conn_id: conn, h2_stream_id: 1_i64))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/2 200\r\n\r\n".to_slice))
      store.insert_h2_frame(conn, "out", 0x1_u8, 0x5_u8, 1_u32, "hdr".to_slice)
      store.flush

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true # starts on REQUEST

      view.detail_pane_advance(-1).should be_false # ← at REQUEST steps off (Runner closes)
      view.detail_pane_advance(1).should be_true   # REQ → RES
      view.detail_pane_advance(1).should be_true   # RES → FRAMES
      view.detail_pane_advance(1).should be_false  # → at FRAMES steps off (no-op)

      backend = MemoryBackend.new(100, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.contains?("FRAMES (h2)").should be_true # right walked all the way to FRAMES

      view.detail_pane_advance(-1).should be_true  # FRAMES → RES
      view.detail_pane_advance(-1).should be_true  # RES → REQ
      view.detail_pane_advance(-1).should be_false # ← past REQUEST steps off again
    end
  end

  it "has only REQ↔RES panes when there are no h2 frames" do
    tmp_store do |store|
      add_flow(store, "GET", "/x", status: 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true      # REQUEST
      view.detail_pane_advance(1).should be_true  # REQ → RES
      view.detail_pane_advance(1).should be_false # no FRAMES pane → stop at RES
      view.detail_pane_advance(-1).should be_true # RES → REQ
    end
  end

  it "shows ALL pane chips in the detail header (not just the active one)" do
    tmp_store do |store|
      add_flow(store, "GET", "/x", status: 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true # active = REQUEST

      backend = MemoryBackend.new(100, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.contains?("REQUEST").should be_true  # active chip
      backend.contains?("RESPONSE").should be_true # inactive chip still shown — "there's more behind"
    end
  end

  it "renders a gRPC response body as framed messages" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "grpc.test", port: 443,
        method: "POST", target: "/svc/Method", http_version: "HTTP/2",
        head: "POST /svc/Method HTTP/2\r\ncontent-type: application/grpc\r\n\r\n".to_slice, body: nil))
      # one gRPC message "hi": flag 0 + len 2 + "hi"
      gbody = IO::Memory.new
      gbody.write(Bytes[0x00, 0x00, 0x00, 0x00, 0x02])
      gbody << "hi"
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/2 200\r\ncontent-type: application/grpc\r\n\r\n".to_slice, body: gbody.to_slice))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response (gRPC body)

      backend = MemoryBackend.new(100, 14)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 14))
      backend.contains?("message #1").should be_true
      backend.contains?("2b").should be_true
    end
  end

  it "opens detail and renders the raw request bytes" do
    tmp_store do |store|
      add_flow(store, "GET", "/secret", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("REQUEST").should be_true
      backend.contains?("GET /secret HTTP/1.1").should be_true
    end
  end

  it "bounds the in-memory window during long live capture (drops oldest, keeps newest)" do
    tmp_store do |store|
      view = HistoryView.new(max_rows: 10, trim_slack: 4)
      view.reload(store)
      last_id = 0_i64
      # append well past the window via live :inserted events
      20.times do
        last_id = add_flow(store, "GET", "/x", 200)
        view.on_event(Gori::Store::FlowEvent.new(last_id, :inserted), store)
      end
      view.rows.size.should be <= 10 + 4 # never grows without bound
      view.follow?.should be_true
      view.selected_id.should eq(last_id) # following stays pinned to the newest flow
      # the oldest rows have left the window; the newest sits at the top (newest-first)
      view.rows.first.id.should eq(last_id)
    end
  end

  it "syntax-highlights the request line and headers in the detail view" do
    tmp_store do |store|
      add_flow(store, "GET", "/secret", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 12))
      # the request line: GET coloured by verb, host header name accented
      ry = (0...12).find { |y| backend.row(y).includes?("GET /secret HTTP") }.not_nil!
      gx = backend.row(ry).index("GET /secret HTTP").not_nil!
      backend.fg_at(gx, ry).should eq(Theme.method_color("GET")) # GET → green
      hy = (0...12).find { |y| backend.row(y).includes?("Host") }.not_nil!
      hx = backend.row(hy).index("Host").not_nil!
      backend.fg_at(hx, hy).should eq(Theme.syn_header)
    end
  end
end

describe Gori::Tui::Keybind do
  it "maps termisu key events to verb chords" do
    ctrl_p = Termisu::Event::Key.new(Termisu::Input::Key::LowerP, Termisu::Input::Modifier::Ctrl)
    Keybind.from_event(ctrl_p).should eq(Gori::Verb::Chord.new("p", ctrl: true))

    enter = Termisu::Event::Key.new(Termisu::Input::Key::Enter)
    Keybind.from_event(enter).should eq(Gori::Verb::Chord.new("enter"))

    up = Termisu::Event::Key.new(Termisu::Input::Key::Up)
    Keybind.from_event(up).should eq(Gori::Verb::Chord.new("up"))
  end
end
