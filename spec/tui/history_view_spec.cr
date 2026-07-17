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

  it "splits the list rect for Req/Res preview when history_preview is on" do
    prev = Gori::Settings.history_preview
    begin
      Gori::Settings.history_preview = true
      view = HistoryView.new
      list, prev_r = view.list_split(Rect.new(0, 0, 80, 24))
      prev_r.should_not be_nil
      list.h.should be < 24
      list.h.should be >= 6
      (list.h + prev_r.not_nil!.h).should eq(24)

      Gori::Settings.history_preview = false
      list2, prev2 = view.list_split(Rect.new(0, 0, 80, 24))
      prev2.should be_nil
      list2.h.should eq(24)
    ensure
      Gori::Settings.history_preview = prev
    end
  end

  it "loads a preview detail for the selected flow" do
    prev = Gori::Settings.history_preview
    begin
      Gori::Settings.history_preview = true
      tmp_store do |store|
        add_flow(store, "GET", "/preview-me", 200, "text/plain")
        view = HistoryView.new
        view.reload(store)
        view.refresh_preview(store)
        view.preview_enabled?.should be_true
        # Render list with preview — must not raise and should paint REQUEST
        backend = MemoryBackend.new(100, 30)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 100, 30))
        rows = (0...30).map { |y| backend.row(y) }.join("\n")
        rows.should contain("REQUEST")
        rows.should contain("RESPONSE")
      end
    ensure
      Gori::Settings.history_preview = prev
    end
  end

  it "re-fetches the preview of a still-pending flow after its response lands" do
    # The refresh_preview cache guard skips the per-frame get_flow ONLY for a Complete,
    # non-streaming flow (whose bytes are immutable). A pending flow must keep refreshing
    # so the preview picks up the response once it arrives — a guard keyed on the wrong
    # state would freeze the pane on "(empty)".
    prev = Gori::Settings.history_preview
    begin
      Gori::Settings.history_preview = true
      tmp_store do |store|
        id = add_flow(store, "GET", "/pending") # no response yet → Pending
        view = HistoryView.new
        view.reload(store)
        view.refresh_preview(store) # caches the pending detail (no RESPONSE body)

        backend = MemoryBackend.new(100, 30)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 100, 30))
        before = (0...30).map { |y| backend.row(y) }.join("\n")
        before.should contain("(empty)") # RESPONSE side empty while pending
        before.should_not contain("200")

        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\nhi".to_slice,
          body: "hi".to_slice, content_type: "text/plain"))
        view.refresh_preview(store) # NOT skipped: cached detail was pending → re-fetch

        backend2 = MemoryBackend.new(100, 30)
        view.render_list(Screen.new(backend2), Rect.new(0, 0, 100, 30))
        after = (0...30).map { |y| backend2.row(y) }.join("\n")
        after.should contain("200") # RESPONSE now shows the landed response
      end
    ensure
      Gori::Settings.history_preview = prev
    end
  end

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

  it "loads flows oldest-first when history_list_order is oldest" do
    prev = Gori::Settings.history_list_order
    begin
      Gori::Settings.history_list_order = "oldest"
      tmp_store do |store|
        add_flow(store, "GET", "/a", 200)
        last = add_flow(store, "POST", "/b", 500)
        view = HistoryView.new
        view.reload(store)
        view.rows.map(&.target).should eq(["/a", "/b"]) # oldest at top
        view.selected_id.should eq(last)                # follow still tracks newest (bottom)
      end
    ensure
      Gori::Settings.history_list_order = prev
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

  it "renders the '‹ list' back marker on the detail's top frame border (framed path)" do
    tmp_store do |store|
      add_flow(store, "GET", "/api", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 16)
      screen = Screen.new(backend)
      # Render via the real framed path so inner.y - 1 lands on the drawn top border
      # (existing detail specs render at rect.y == 0, where the marker is correctly skipped).
      BodyChrome.framed(screen, Rect.new(0, 0, 80, 16), true) do |inner|
        view.render_detail(screen, inner, focused: true)
      end
      backend.row(0).includes?("‹ list").should be_true
    end
  end

  it "detail_at_top? tracks the caret so ↑ escapes to the tab bar only at the very top" do
    tmp_store do |store|
      add_flow(store, "GET", "/api", 200) # multi-line request head → caret can move
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      view.detail_at_top?.should be_true  # fresh open → caret on row 0
      view.scroll_detail(1)               # caret down one line
      view.detail_at_top?.should be_false
      view.scroll_detail(-1)              # back to row 0
      view.detail_at_top?.should be_true
    end
  end

  it "hscroll_detail scrolls a long response body line sideways into view (shift+←/→)" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/api", http_version: "HTTP/1.1",
        head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
        body: ("HEAD" + ("." * 100) + "TAIL").to_slice, content_type: "text/plain"))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response

      rect = Rect.new(0, 0, 80, 16)
      backend = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(backend), rect)
      backend.contains?("HEAD").should be_true
      backend.contains?("TAIL").should be_false # off the right edge, clipped

      20.times { view.hscroll_detail(1) } # scroll well past the line's width
      backend2 = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(backend2), rect)
      backend2.contains?("TAIL").should be_true
      backend2.contains?("HEAD").should be_false # scrolled off the left edge
    end
  end

  it "^G go-to-line in the detail view also moves the caret (not just the scroll)" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/api", http_version: "HTTP/1.1",
        head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
        body: "LINE1\nLINE2\nLINE3\nLINE4".to_slice, content_type: "text/plain"))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane                                # request -> response
      line3 = view.detail_search_lines("LINE3").first # 0-based row of the body's 3rd line

      view.goto_detail_line(line3 + 1) # 1-based
      view.detail_copy_text.should eq("LINE3")
      view.detail_move(-1, 0) # ↑ should step to LINE2, not jump from a stale pre-goto caret
      view.detail_copy_text.should eq("LINE2")
    end
  end

  it "opens in the body, flips to the strip level, and resets to the body on re-open" do
    tmp_store do |store|
      add_flow(store, "GET", "/api", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      view.detail_strip_focus?.should be_false # a fresh open lands in the BODY
      view.set_detail_focus(:strip)            # ↑-at-top ascends to the chip strip
      view.detail_strip_focus?.should be_true
      view.open_detail(store).should be_true   # re-opening resets the sub-state
      view.detail_strip_focus?.should be_false
    end
  end

  it "follows the caret horizontally as ←/→ walk a long line (no explicit h-scroll)" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/api", http_version: "HTTP/1.1",
        head: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
        body: ("HEAD" + ("." * 100) + "TAIL").to_slice, content_type: "text/plain"))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response

      rect = Rect.new(0, 0, 80, 16)
      # The first render records the body's content width so caret moves can follow-x.
      b0 = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(b0), rect)
      b0.contains?("HEAD").should be_true
      b0.contains?("TAIL").should be_false # off the right edge at xscroll 0

      # Park the caret at the start of the long body line, then walk it to end-of-line
      # (the body has no trailing newline, so moving past EOL clamps — it never wraps).
      row = view.detail_search_lines("HEAD").first
      view.goto_detail_line(row + 1)
      130.times { view.detail_move(0, 1) } # plain ←/→ horizontal caret; ensure_detail_visible_x tracks it

      b1 = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(b1), rect)
      b1.contains?("TAIL").should be_true  # caret-follow scrolled the tail into view
      b1.contains?("HEAD").should be_false # the start slid off the left edge
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

  it "shows a placeholder for a binary response body instead of rendering it as text" do
    tmp_store do |store|
      # A webp-ish body: RIFF header + a NUL byte (the binary marker) + bytes that,
      # decoded as UTF-8, would be terminal-corrupting garbage.
      binary = Bytes[0x52, 0x49, 0x46, 0x46, 0x00, 0x1b, 0x5b, 0x32, 0x4a, 0xff, 0xfe]
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
        method: "GET", target: "/img", http_version: "HTTP/1.1",
        head: "GET /img HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: image/webp\r\n\r\n".to_slice,
        body: binary, content_type: "image/webp"))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response

      backend = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 16))
      backend.contains?("binary body").should be_true # placeholder shown
      backend.contains?("hex view").should be_true    # points at the hex view
      backend.contains?("RIFF").should be_false       # raw bytes NOT rendered as text

      # The byte-exact hex view is still one keypress away (x).
      view.toggle_detail_hex
      hex = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(hex), Rect.new(0, 0, 80, 16))
      hex.contains?("00000000").should be_true     # offset column of the hex dump
      hex.contains?("binary body").should be_false # placeholder gone in hex mode

      # Reveal-whitespace (b) must NOT re-render the raw binary as text — it renders
      # bytes as text just like the normal path, so it stays gated to the placeholder.
      view.toggle_detail_hex # back to text
      view.reveal = true
      ws = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(ws), Rect.new(0, 0, 80, 16))
      ws.contains?("binary body").should be_true # placeholder, not raw bytes
      ws.contains?("RIFF").should be_false
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

  it "reload is page-capped and list rows never carry body BLOBs" do
    tmp_store do |store|
      1_200.times { |i| add_flow(store, "GET", "/p/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.rows.size.should eq(HistoryView::PAGE)
      view.rows.each do |r|
        r.responds_to?(:request_body).should be_false
        r.responds_to?(:response_body).should be_false
      end
    end
  end

  it "opens a large multi-line response detail and paints a scroll window without hang" do
    tmp_store do |store|
      # ~0.75 MiB of short lines — representative near-cap text body for open+scroll.
      line = ("y" * 30) + "\n"
      n = 25_000
      io = IO::Memory.new(line.bytesize * n)
      n.times { io << line }
      body = io.to_slice
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/big", http_version: "HTTP/1.1",
        head: "GET /big HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
        body: body, content_type: "text/plain"))

      view = HistoryView.new
      view.reload(store)
      t0 = Time.instant
      view.open_detail(store).should be_true
      open_ms = (Time.instant - t0).total_milliseconds
      open_ms.should be < 3_000.0

      backend = MemoryBackend.new(100, 30)
      t1 = Time.instant
      5.times do |frame|
        view.scroll_detail(20) if frame > 0
        view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 30), focused: true)
      end
      paint_ms = (Time.instant - t1).total_milliseconds
      paint_ms.should be < 3_000.0
      (backend.contains?("RESPONSE") || backend.contains?("REQUEST")).should be_true

      # Caret steps must not rematerialise every BodyLines string (was detail_plain_lines).
      t2 = Time.instant
      200.times { view.detail_move(1, 0) }
      move_ms = (Time.instant - t2).total_milliseconds
      move_ms.should be < 500.0
    end
  end

  it "preview refresh uses capped body load (not full multi-MiB BLOB)" do
    prev = Gori::Settings.history_preview
    begin
      Gori::Settings.history_preview = true
      tmp_store do |store|
        big = Bytes.new(300_000) { 65_u8 }
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "GET", target: "/preview-big", http_version: "HTTP/1.1",
          head: "GET /preview-big HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
          body: big, content_type: "text/plain"))
        view = HistoryView.new
        view.reload(store)
        view.refresh_preview(store)
        # Render must not raise; preview path only needs a prefix of the body.
        backend = MemoryBackend.new(100, 30)
        view.render_list(Screen.new(backend), Rect.new(0, 0, 100, 30))
        backend.contains?("REQUEST").should be_true
        backend.contains?("RESPONSE").should be_true
        # Cap invariant: store API used by preview is body_max-aware
        cap = Gori::Settings.preview_body_cap
        d = store.get_flow(id, body_max: cap + 1).not_nil!
        d.response_body.not_nil!.size.should eq(cap + 1)
      end
    ensure
      Gori::Settings.history_preview = prev
    end
  end

  it "syntax-highlights the request line and headers in the detail view" do
    tmp_store do |store|
      add_flow(store, "GET", "/secret", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 12)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 12), focused: false)
      # the request line: GET coloured by verb, host header name accented
      ry = (0...12).find { |y| backend.row(y).includes?("GET /secret HTTP") }.not_nil!
      gx = backend.row(ry).index("GET /secret HTTP").not_nil!
      backend.fg_at(gx, ry).should eq(Theme.method_color("GET")) # GET → green
      hy = (0...12).find { |y| backend.row(y).includes?("Host") }.not_nil!
      hx = backend.row(hy).index("Host").not_nil!
      backend.fg_at(hx, hy).should eq(Theme.syn_header)
    end
  end

  it "renders an empty-state when no flows are captured" do
    tmp_store do |store|
      view = HistoryView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 14)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 14),
        listen: "127.0.0.1:8070", capturing: true)
      backend.contains?("waiting for traffic").should be_true
      backend.contains?("127.0.0.1:8070").should be_true
      backend.contains?("Open browser").should be_true
      backend.contains?("FLOW LOG").should be_true
    end
  end

  it "does not fall back to the 101 handshake bytes for hex/reveal on the WS MESSAGES pane" do
    tmp_store do |store|
      id = add_flow(store, "GET", "/ws", 101) # response head = the 101 handshake
      store.insert_ws_message(id, "out", 1, "hello".to_slice)
      store.insert_ws_message(id, "in", 1, "world".to_slice)

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response (= MESSAGES for a WS flow)

      # x (hex) must be a no-op on a synthetic transcript — never a hex dump of the
      # bare "HTTP/1.1 101" handshake (whose bytes hold neither "hello" nor "world").
      view.toggle_detail_hex
      hexb = MemoryBackend.new(80, 12)
      view.render_detail(Screen.new(hexb), Rect.new(0, 0, 80, 12))
      hexb.contains?("hello").should be_true
      hexb.contains?("world").should be_true

      # w (reveal) likewise stays on the message log, not the handshake.
      view.toggle_detail_hex # back to text
      view.reveal = true
      wsb = MemoryBackend.new(80, 12)
      view.render_detail(Screen.new(wsb), Rect.new(0, 0, 80, 12))
      wsb.contains?("hello").should be_true
      wsb.contains?("world").should be_true
    end
  end

  it "gates reveal-whitespace on a gRPC body (keeps the framed view, avoids raw-protobuf desync)" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "grpc.test", port: 443,
        method: "POST", target: "/svc/Method", http_version: "HTTP/2",
        head: "POST /svc/Method HTTP/2\r\ncontent-type: application/grpc\r\n\r\n".to_slice, body: nil))
      gbody = IO::Memory.new
      gbody.write(Bytes[0x00, 0x00, 0x00, 0x00, 0x02]) # flag 0 + len 2
      gbody << "hi"
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/2 200\r\ncontent-type: application/grpc\r\n\r\n".to_slice, body: gbody.to_slice))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response (gRPC body)

      view.reveal = true # 'w' — must NOT swap the framed view for reveal-glyphed protobuf
      backend = MemoryBackend.new(100, 14)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 14))
      backend.contains?("message #1").should be_true # still the framed view
    end
  end

  it "keeps the newest capture visible after a live insert while not following" do
    tmp_store do |store|
      add_flow(store, "GET", "/A", 200)
      add_flow(store, "GET", "/B", 200)
      view = HistoryView.new
      view.reload(store) # newest-first [B, A], following (top)
      view.select_row(1) # click the older row A → follow off, scroll 0
      view.follow?.should be_false

      cid = add_flow(store, "GET", "/C", 200)
      view.on_event(Gori::Store::FlowEvent.new(cid, :inserted), store) # [C,B,A]; @scroll bumped to 1

      backend = MemoryBackend.new(80, 30) # ample room for all 3 rows
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 30))
      body = (0...30).map { |y| backend.row(y) }.join("\n")
      body.should contain("/C") # newest row must not be stranded above the top
      body.should contain("/A")
    end
  end

  it "Tab-completes method/scheme/status statically and host from the store" do
    tmp_store do |store|
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.example.com", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: api.example.com\r\n\r\n".to_slice, body: nil))
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "app.example.com", port: 443,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: app.example.com\r\n\r\n".to_slice, body: nil))

      view = HistoryView.new
      view.reload(store)
      view.start_query

      "me".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should eq(["method:"])
      view.query_complete.should be_true
      view.query.should eq("method:")

      view.cancel_query
      view.start_query
      "method:P".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should eq(["method:POST", "method:PUT", "method:PATCH"])
      view.query_complete.should be_true
      view.query.should eq("method:POST")

      view.cancel_query
      view.start_query
      "scheme:h".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should eq(["scheme:http", "scheme:https"])

      view.cancel_query
      view.start_query
      "status:4".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should contain("status:4xx")
      view.query_suggestions.should contain("status:401")

      view.cancel_query
      view.start_query
      "host:ap".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should eq(["host:api.example.com", "host:app.example.com"])
      view.query_complete.should be_true
      view.query.should eq("host:api.example.com")

      # Negation prefix is preserved.
      view.cancel_query
      view.start_query
      "-host:app".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should eq(["-host:app.example.com"])
    end
  end

  it "rejects an all-invalid QL query instead of matching every flow" do
    tmp_store do |store|
      3.times { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.rows.size.should eq(3)

      view.start_query
      "dur:>2sec".each_char { |c| view.query_insert(c) } # every term invalid → compiles to match-all EMPTY
      view.reload(store)
      view.rows.empty?.should be_true # must NOT show all flows behind an "active" filter

      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      rows = (0...12).map { |y| backend.row(y) }.join("\n")
      rows.should contain("invalid filter")
    end
  end

  it "flags an invalid regex filter term in the empty-state (not a bare no-match)" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200)
      view = HistoryView.new
      view.reload(store)
      view.start_query
      "body~[bad".each_char { |c| view.query_insert(c) } # unterminated class → never-match "0"
      view.reload(store)
      view.rows.empty?.should be_true

      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      rows = (0...12).map { |y| backend.row(y) }.join("\n")
      rows.should contain("invalid regex")
    end
  end

  it "shows the scope-lens empty hint (not the filter hint) when querying with a blank query" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200) # captured on host h.test
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test") # excludes the h.test flow → in-scope set empty
      scope.enable
      view = HistoryView.new
      view.set_scope(scope)
      view.reload(store)
      view.rows.empty?.should be_true
      view.start_query # filter bar open, query still blank

      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      rows = (0...12).map { |y| backend.row(y) }.join("\n")
      rows.should contain("no flows in scope")
      rows.should contain("⇧S clears the scope lens")
      rows.should_not contain("esc clears the filter") # would be misleading — esc won't unfilter
    end
  end

  it "delete_by_id removes one flow and reloads the list" do
    tmp_store do |store|
      keep = add_flow(store, "GET", "/keep", 200)
      gone = add_flow(store, "GET", "/gone", 200)
      view = HistoryView.new
      view.reload(store)
      view.rows.size.should eq(2)
      view.flow_summary(gone).should contain("GET")
      view.flow_summary(gone).should contain("/gone")

      view.delete_by_id(store, gone)
      view.rows.map(&.id).should eq([keep])
      store.get_flow(gone).should be_nil
    end
  end

  it "clear wipes every flow and empties the list" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200)
      add_flow(store, "POST", "/b", 201)
      view = HistoryView.new
      view.reload(store)
      view.rows.size.should eq(2)

      view.clear(store)
      view.empty?.should be_true
      store.count.should eq(0)
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
