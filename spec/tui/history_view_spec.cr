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

private def add_flow(store, method, target, status = nil)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\nbody".to_slice, body: "body".to_slice))
  end
  id
end

describe Gori::Tui::HistoryView do
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
      add_flow(store, "GET", "/search", 200)
      add_flow(store, "POST", "/orders", 500)
      view = HistoryView.new
      view.reload(store)

      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("METHOD").should be_true
      backend.contains?("STATUS").should be_true
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
      backend.fg_at(hx, hy).should eq(Theme::SYN_HEADER)
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
