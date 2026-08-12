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

private def add_flow(store, method, target, status = nil, content_type = nil, host = "h.test")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\nbody".to_slice,
      body: "body".to_slice, content_type: content_type))
  end
  id
end

# Counts the two flow read paths, so a spec can prove WHICH one a code path uses. get_flow
# pulls the full request+response bodies (2 MiB each) while flow_row is a cheap row — and the
# multi-select copy paths run on the single-threaded render loop over up to a page of marks
# (#442), so "rows only" is a property worth pinning rather than re-deriving by reading.
private class CountingStore < Gori::Store
  getter get_flow_calls = 0
  getter flow_row_calls = 0

  def reset_counts : Nil
    @get_flow_calls = 0
    @flow_row_calls = 0
  end

  def flow_row(id : Int64) : Gori::Store::FlowRow?
    @flow_row_calls += 1
    super
  end

  def get_flow(id : Int64, *, body_max : Int32? = nil) : Gori::Store::FlowDetail?
    @get_flow_calls += 1
    super
  end
end

private def tmp_counting_store(&)
  path = File.tempname("gori-hvc", ".db")
  store = CountingStore.open(path).as(CountingStore)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Tui::HistoryView do
  # These specs assert on RAW body rendering; keep the display-only pretty-printer off
  # so a (future) valid-JSON/XML fixture can't silently reflow and shift assertions.
  before_each { Gori::Settings.pretty_bodies_default = false }

  # Trigram indexing is off the capture commit (Store V4), so a `body:` filter in a LIVE view
  # can legitimately be answered from an index that hasn't caught up. The view must not stall
  # to fix that (the one-shot CLI/MCP surfaces drain instead) — it must SAY it, or an operator
  # reads "no flows match" as "this traffic doesn't exist", which on a security proxy is how a
  # finding gets missed.
  it "notes a lagging body-search index instead of silently under-reporting" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/submit", http_version: "HTTP/1.1",
        head: "POST /submit HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
        body: "lagindexbodytoken".to_slice))

      view = HistoryView.new
      view.start_query
      "body:lagindexbodytoken".each_char { |c| view.query_insert(c) }
      view.reload(store)

      # Captured but not yet indexed: no rows, and a note that explains WHY there are none.
      view.@rows.should be_empty
      note = view.@query_note
      note.should_not be_nil
      note.not_nil!.should contain("body search")
      note.not_nil!.should contain("1")

      # Once the index catches up the flow appears and the note goes away — the gap is
      # temporary, so the warning must not become permanent furniture.
      store.flush
      view.reload(store)
      view.@rows.map(&.id).should eq([id])
      view.@query_note.should be_nil
    end
  end

  # A filter that never touches flows_fts must not pay for (or display) the backlog probe:
  # its answer is complete the moment the row commits.
  it "does not note the index backlog for a filter that doesn't read it" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200)
      view = HistoryView.new
      view.start_query
      "method:GET".each_char { |c| view.query_insert(c) }
      view.reload(store)
      view.@rows.size.should eq(1)
      view.@query_note.should be_nil
    end
  end

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

  # `Proto` is the single source of truth the PROTO column and the QL `proto:` filter both
  # defer to, and it read only the RESPONSE's content type — so a gRPC call showed as GRPC
  # exactly when it SUCCEEDED. A still-Pending one, and one answered by a proxy's `text/html`
  # 502, both printed HTTPS, and those are the rows an operator is scanning for.
  it "prints GRPCS for a gRPC call the response never confirmed" do
    tmp_store do |store|
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/2",
        head: "POST /svc/M HTTP/2\r\nHost: api.test\r\nContent-Type: application/grpc\r\n\r\n".to_slice,
        body: nil))
      view = HistoryView.new
      view.reload(store)

      backend = MemoryBackend.new(120, 6)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 120, 6))
      backend.contains?("GRPCS").should be_true
    end
  end

  # Every decode pane is keyed on a request or response BODY, and a 101 flow has neither — its
  # bytes live in the ws_messages table. So a GraphQL SUBSCRIPTION, which is how every real
  # GraphQL subscription runs, showed up as raw JSON in MESSAGES with no GRAPHQL pane offered
  # at all: the same "gori did not notice this is GraphQL" the HTTP side had, one transport over.
  it "offers the GRAPHQL pane for a subscription carried in WebSocket frames" do
    tmp_store do |store|
      id = add_flow(store, "GET", "/graphql", 101)
      store.insert_ws_message(id, "out", 1, %({"type":"connection_init","payload":{}}).to_slice)
      store.insert_ws_message(id, "out", 1,
        (%({"id":"1","type":"subscribe","payload":{"operationName":"OnMessage",) +
         %("query":"subscription OnMessage { messageAdded { id } }"}})).to_slice)

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      2.times { view.toggle_pane } # REQUEST → MESSAGES → GRAPHQL (the pane list gained it)

      backend = MemoryBackend.new(100, 16)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 16))
      backend.contains?("operation over websocket").should be_true
      backend.contains?("frame #2 subscribe id=1").should be_true
      backend.contains?("messageAdded").should be_true
    end
  end

  # The WS transcript re-decodes only when its message COUNT grows (a busy socket left open
  # would otherwise re-parse its whole frame log on every refresh poll). The cache must still
  # pick up a NEW subscription frame — proving it invalidates on growth, not that it goes stale.
  it "picks up a new subscription frame on refresh (count-keyed cache invalidates)" do
    tmp_store do |store|
      id = add_flow(store, "GET", "/graphql", 101)
      store.insert_ws_message(id, "out", 1,
        %({"id":"1","type":"subscribe","payload":{"query":"subscription A { a }"}}).to_slice)

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      2.times { view.toggle_pane } # land on GRAPHQL

      backend = MemoryBackend.new(100, 16)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 16))
      backend.contains?("subscription A").should be_true

      # A second operation arrives; a refresh poke must rebuild the transcript pane.
      store.insert_ws_message(id, "out", 1,
        %({"id":"2","type":"subscribe","payload":{"query":"subscription B { b }"}}).to_slice)
      view.refresh_detail(store)

      backend2 = MemoryBackend.new(100, 16)
      view.render_detail(Screen.new(backend2), Rect.new(0, 0, 100, 16))
      backend2.contains?("subscription A").should be_true
      backend2.contains?("subscription B").should be_true
      backend2.contains?("2 operations over websocket").should be_true
    end
  end

  it "does not offer a GRAPHQL pane for a socket carrying ordinary JSON" do
    tmp_store do |store|
      id = add_flow(store, "GET", "/ws", 101)
      store.insert_ws_message(id, "out", 1, %({"type":"search","payload":{"query":"shoes"}}).to_slice)

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      # Only REQUEST and MESSAGES exist, so two toggles come back to REQUEST — a GRAPHQL pane
      # would have made this land somewhere else and would print its header.
      3.times do
        view.toggle_pane
        backend = MemoryBackend.new(100, 12)
        view.render_detail(Screen.new(backend), Rect.new(0, 0, 100, 12))
        backend.contains?("operation over websocket").should be_false
      end
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

      view.detail_at_top?.should be_true # fresh open → caret on row 0
      view.scroll_detail(1)              # caret down one line
      view.detail_at_top?.should be_false
      view.scroll_detail(-1) # back to row 0
      view.detail_at_top?.should be_true
    end
  end

  # Was: "hscroll_detail scrolls a long response body line sideways into view (shift+←/→)".
  # There is no sideways any more — the detail's req/res panes soft-wrap, so the tail of a
  # long line is on the next row with nothing to chase it with. What is still under test is
  # the same requirement the h-scroll spec encoded: BOTH ends of an over-wide line must be
  # reachable, and now they are visible at once.
  it "wraps a long response body line so both ends are on screen without scrolling" do
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
      backend.contains?("TAIL").should be_true # on a continuation row, not clipped away
      # …and on DIFFERENT rows: the tail wrapped rather than being squeezed onto one line.
      head_y = (0...16).find { |y| backend.row(y).includes?("HEAD") }.not_nil!
      tail_y = (0...16).find { |y| backend.row(y).includes?("TAIL") }.not_nil!
      tail_y.should be > head_y
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

  it "opens on the strip, flips to the body level, and resets to the strip on re-open" do
    tmp_store do |store|
      add_flow(store, "GET", "/api", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      view.detail_strip_focus?.should be_true # a fresh open lands on the STRIP
      view.set_detail_focus(:body)            # enters the body (caret/text)
      view.detail_strip_focus?.should be_false
      view.open_detail(store).should be_true # re-opening resets the sub-state to STRIP
      view.detail_strip_focus?.should be_true
    end
  end

  # Was: "follows the caret horizontally as ←/→ walk a long line (no explicit h-scroll)".
  # The caret no longer drags a horizontal offset — the line is wrapped, so walking ←/→ to
  # its end lands the caret on a continuation row that is already drawn. What is still under
  # test is that the walk REACHES the end of the line and the pane keeps showing it.
  it "walks the caret to the end of a wrapped line without scrolling the pane sideways" do
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
      # The first render publishes the body's content width, which the wrap is keyed on.
      b0 = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(b0), rect)
      b0.contains?("HEAD").should be_true
      b0.contains?("TAIL").should be_true # already on a continuation row

      # Park the caret at the start of the long body line, then walk it to end-of-line
      # (the body has no trailing newline, so moving past EOL clamps — it never wraps).
      row = view.detail_search_lines("HEAD").first
      view.goto_detail_line(row + 1)
      130.times { view.detail_move(0, 1) } # plain ←/→ horizontal caret
      view.detail_read.cy.should eq(row)
      view.detail_read.cx.should eq(108) # HEAD + 100 dots + TAIL

      b1 = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(b1), rect)
      b1.contains?("TAIL").should be_true # the caret's row is still on screen …
      b1.contains?("HEAD").should be_true # … and so is the line's start
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

  # Was: "scrolls a tab-filled response line to its end in reveal mode" — a regression test
  # for two measures disagreeing about a tab's width (display_width says 0, draw_width says
  # 1) while one drove the h-scroll clamp and the other the caret-follow. There is no
  # h-scroll left to clamp, but the SAME disagreement would now break the wrap: `Wrap` breaks
  # on `Screen.grapheme_cols`, so a 100-tab line has to occupy several drawn rows rather than
  # the single 14-column one the raw measure would predict.
  it "wraps a tab-filled response line onto continuation rows in reveal mode" do
    tmp_store do |store|
      line = "STARTTOK#{"\t" * 100}ENDTOK"
      Screen.display_width(line).should eq(14) # the raw measure the clamp used to trust
      Screen.draw_width(line).should eq(114)   # what reveal actually paints (tab → '→')
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/t", http_version: "HTTP/1.1",
        head: "GET /t HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n#{line}".to_slice,
        body: line.to_slice, content_type: "text/plain"))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request → response
      view.reveal = true

      rect = Rect.new(0, 0, 80, 16)
      at0 = MemoryBackend.new(80, 16)
      view.render_detail(Screen.new(at0), rect)
      at0.contains?("STARTTOK").should be_true
      at0.contains?("→").should be_true      # reveal is drawing tab markers
      at0.contains?("ENDTOK").should be_true # …and the tail wrapped into view

      # The two must be on different rows: 114 drawn columns cannot fit one ~76-column row.
      start_y = (0...16).find { |y| at0.row(y).includes?("STARTTOK") }.not_nil!
      end_y = (0...16).find { |y| at0.row(y).includes?("ENDTOK") }.not_nil!
      end_y.should be > start_y
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

  # `Grpc.scan`'s residual is the finding in a gRPC parser test — a length prefix claiming
  # more than arrived is one of the standard probes. This pane called `Grpc.messages`, which
  # throws the residual away, so it rendered as "(no complete gRPC messages)" with no byte
  # count: indistinguishable from a body that simply is not gRPC, while `gori run show
  # --format json` reported the whole thing.
  it "reports gRPC bytes that are not a complete frame instead of showing nothing" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "grpc.test", port: 443,
        method: "POST", target: "/svc/Method", http_version: "HTTP/2",
        head: "POST /svc/Method HTTP/2\r\ncontent-type: application/grpc\r\n\r\n".to_slice, body: nil))
      # a length prefix claiming 9999 bytes with 5 arriving: 10 unframeable tail bytes
      gbody = IO::Memory.new
      gbody.write(Bytes[0x00, 0x00, 0x00, 0x27, 0x0f])
      gbody << "short"
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/2 200\r\ncontent-type: application/grpc\r\n\r\n".to_slice, body: gbody.to_slice))

      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # request -> response (gRPC body)

      backend = MemoryBackend.new(120, 14)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 120, 14))
      backend.contains?("10 bytes are not a complete gRPC frame").should be_true
      backend.contains?("no complete gRPC messages").should be_false
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
        listen: {"127.0.0.1", 8070}, capturing: true)
      backend.contains?("waiting for traffic").should be_true
      backend.contains?("localhost:8070").should be_true
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

# Multi-select marks (#442) — the state the space menu's batch verbs read through
# ExecContext#selected_flow_ids. The whole point of keying on FLOW ID rather than row index is
# that the list reloads, re-sorts and re-filters under the user constantly, so most of these
# assert that a mark survives exactly that.
describe "Gori::Tui::HistoryView marks" do
  it "starts with no marks, so verbs target the cursor row" do
    tmp_store do |store|
      id = add_flow(store, "GET", "/a", 200)
      view = HistoryView.new
      view.reload(store)
      view.mark_count.should eq(0)
      view.marked?(id).should be_false
      view.target_ids.should eq([id]) # cursor fallback
    end
  end

  it "toggles the cursor row's mark and advances, so a run of `t` marks consecutive rows" do
    tmp_store do |store|
      ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store) # newest-first: the cursor starts on the newest row
      view.toggle_mark
      view.toggle_mark
      view.mark_count.should eq(2)
      view.marked_ids.should eq([ids[2], ids[1]]) # display order — newest first
      view.target_ids.should eq([ids[2], ids[1]]) # …and that IS the target set now
      # Toggling a marked row again clears it.
      view.select_row(0)
      view.toggle_mark
      view.marked?(ids[2]).should be_false
    end
  end

  # `t` steps toward OLDER, not "down the screen". Under oldest-first the follow cursor parks on
  # the BOTTOM row (newest), where stepping down is a clamp — so a hardcoded +1 made the second
  # `t` land on the same row and un-mark what the first just marked, i.e. a run of `t` marked
  # nothing. Every other mark spec runs the default order, so this is the only cover for it.
  it "marks consecutive rows under oldest-first order too" do
    prev = Gori::Settings.history_list_order
    begin
      Gori::Settings.history_list_order = "oldest"
      tmp_store do |store|
        ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
        view = HistoryView.new
        view.reload(store)
        view.selected_id.should eq(ids[2]) # follow → newest, which is the BOTTOM row here
        view.toggle_mark
        view.toggle_mark
        view.mark_count.should eq(2)
        view.marked?(ids[2]).should be_true
        view.marked?(ids[1]).should be_true
      end
    ensure
      Gori::Settings.history_list_order = prev
    end
  end

  # The privileged single target must not follow a DISPLAY preference: it decides which flow
  # names an issue, donates Discover's cookies, and seeds the Miner's checkboxes.
  it "picks the same primary target under either list order" do
    tmp_store do |store|
      ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      %w[newest oldest].each do |order|
        prev = Gori::Settings.history_list_order
        begin
          Gori::Settings.history_list_order = order
          view = HistoryView.new
          view.reload(store)
          row_of = ->(id : Int64) { view.rows.index { |r| r.id == id }.not_nil! }
          # Mark the two OLDER flows, then park the cursor on the newest (unmarked) one.
          [ids[0], ids[1]].each do |id|
            view.select_row(row_of.call(id))
            view.toggle_mark
          end
          view.select_row(row_of.call(ids[2]))
          view.marked?(ids[2]).should be_false
          view.primary_target_id.should eq(ids[0]) # the oldest mark, in BOTH orders

          # And the cursor wins outright once it is itself a target.
          view.toggle_mark
          view.select_row(row_of.call(ids[2]))
          view.primary_target_id.should eq(ids[2])
        ensure
          Gori::Settings.history_list_order = prev
        end
      end
    end
  end

  it "saturates the cursor at the last row instead of wrapping" do
    tmp_store do |store|
      ids = (0...2).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      # Only 2 rows, so the 3rd `t` lands back on the bottom row and un-marks it.
      3.times { view.toggle_mark }
      view.selected_id.should eq(ids[0])
      view.mark_count.should eq(1)
      view.marked?(ids[1]).should be_true
    end
  end

  it "keeps a mark across a reload, a re-sort and a filter change" do
    tmp_store do |store|
      keep = add_flow(store, "GET", "/keep", 200)
      add_flow(store, "GET", "/other", 500)
      view = HistoryView.new
      view.reload(store)
      view.select_row(view.rows.index { |r| r.id == keep }.not_nil!)
      view.toggle_mark
      view.marked?(keep).should be_true

      view.reload(store)
      view.marked?(keep).should be_true

      # Re-sort: oldest-first flips the row order, and an INDEX-keyed mark would retarget here.
      prev = Gori::Settings.history_list_order
      begin
        Gori::Settings.history_list_order = "oldest"
        view.reload(store)
        view.marked?(keep).should be_true
      ensure
        Gori::Settings.history_list_order = prev
      end

      # Filter the marked flow OUT: the mark set is independent of the visible window, so it
      # survives and is REPORTED as hidden rather than silently lost.
      "status:500".each_char { |c| view.query_insert(c) }
      view.reload(store)
      view.rows.map(&.id).should_not contain(keep)
      view.marked?(keep).should be_true
      view.mark_count.should eq(1)
      view.marked_hidden_count.should eq(1)
    end
  end

  it "marks every row the CURRENT filter shows, unioned with what is already marked" do
    tmp_store do |store|
      ok = add_flow(store, "GET", "/ok", 200)
      err1 = add_flow(store, "GET", "/e1", 500)
      err2 = add_flow(store, "GET", "/e2", 500)
      view = HistoryView.new
      view.reload(store)
      view.select_row(view.rows.index { |r| r.id == ok }.not_nil!)
      view.toggle_mark # one mark that the filter below excludes

      "status:500".each_char { |c| view.query_insert(c) }
      view.reload(store)
      view.mark_all
      view.mark_count.should eq(3) # the 2 errors PLUS the pre-existing /ok mark
      [ok, err1, err2].each { |id| view.marked?(id).should be_true }
      view.marked_hidden_count.should eq(1) # /ok is marked but filtered out
    end
  end

  it "extends a contiguous range from the anchor, re-seeding it after a plain move" do
    tmp_store do |store|
      ids = (0...5).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(0) # newest row
      view.extend_marks(1)
      view.extend_marks(1)
      view.marked_ids.should eq([ids[4], ids[3], ids[2]]) # anchor + two steps, inclusive

      # A plain move clears the anchor, so the next shift-arrow starts from the NEW cursor
      # instead of silently sweeping everything back to the old one.
      view.clear_marks
      view.select_row(0)
      view.move(1)
      view.move(1) # plain moves → cursor two rows down, anchor cleared
      view.extend_marks(1)
      view.marked_ids.should eq([ids[2], ids[1]])
    end
  end

  # A GUI shift+click SHRINKS the selection when you come back; a plain union would only ever
  # grow, leaving a row marked that the gesture no longer covers and no way to un-mark a range.
  it "gives back what the range gesture added when the range shrinks" do
    tmp_store do |store|
      ids = (0...4).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(0)
      view.extend_marks(1)
      view.extend_marks(1)
      view.marked_ids.should eq([ids[3], ids[2], ids[1]]) # rows 0..2
      view.extend_marks(-1)
      view.marked_ids.should eq([ids[3], ids[2]]) # row 2 handed back
    end
  end

  it "never hands back a mark the range gesture did not make" do
    tmp_store do |store|
      ids = (0...4).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(2)
      view.toggle_mark # an independent mark, made by `t`
      view.select_row(0)
      view.extend_marks(1)
      view.extend_marks(1)  # the range sweeps OVER the `t` mark at row 2
      view.extend_marks(-1) # …and back off it
      # Rows 0..1 from the range, plus row 2 which was never the gesture's to remove.
      view.marked_ids.should eq([ids[3], ids[2], ids[1]])
    end
  end

  # Releasing ⇧ mid-selection and pressing a plain arrow collapses the highlight in every GUI
  # list. Leaving the range marked behind the cursor is the surprising half.
  it "hands the whole range back when a plain cursor move ends the gesture" do
    tmp_store do |store|
      ids = (0...4).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(0)
      view.extend_marks(1)
      view.extend_marks(1)
      view.mark_count.should eq(3)

      view.end_mark_gesture.should eq(3) # the count is what the toast reports
      view.mark_count.should eq(0)

      # …and the next ⇧arrow opens a fresh range from wherever the cursor now is.
      view.move(-1)
      view.extend_marks(1)
      view.marked_ids.should eq([ids[2], ids[1]])
    end
  end

  # The other half of the split extend_marks already honours: `t`/⇧T marks are deliberate tags,
  # and with no ctrl+arrow to step past them, dropping them here would put a discontiguous set
  # out of reach ("mark this one, skip three, mark that one").
  it "keeps `t` marks when a plain cursor move ends the range gesture" do
    tmp_store do |store|
      ids = (0...4).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(2)
      view.toggle_mark # an independent mark, made by `t`
      view.select_row(0)
      view.extend_marks(1)
      view.extend_marks(1) # the range sweeps OVER the `t` mark at row 2
      view.mark_count.should eq(3)

      view.end_mark_gesture.should eq(2) # rows 0..1 only — row 2 was never the gesture's
      view.marked_ids.should eq([ids[1]])
    end
  end

  it "reports nothing handed back when no range gesture is in flight" do
    tmp_store do |store|
      ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(1)
      view.toggle_mark

      # A plain arrow over a `t`-marked list must stay silent (0) rather than toast on
      # every keystroke — and must not touch the mark.
      view.end_mark_gesture.should eq(0)
      view.marked_ids.should eq([ids[1]])
    end
  end

  it "re-seeds the range anchor on a click, like a plain keyboard move" do
    tmp_store do |store|
      ids = (0...4).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(0)
      view.toggle_mark   # anchors on the newest row
      view.select_row(2) # the MOUSE path — must not leave that anchor behind
      view.extend_marks(1)
      # Rows 2..3 only. A stale row-0 anchor would have swept in ids[2] as well.
      view.marked_ids.should eq([ids[3], ids[1], ids[0]])
      view.marked?(ids[2]).should be_false
    end
  end

  it "does not pop focus or scroll a focused preview when extending" do
    tmp_store do |store|
      ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.select_row(0)
      view.extend_marks(-1) # already at the top: clamps, marks just this row
      view.selected_id.should eq(ids[2])
      view.marked_ids.should eq([ids[2]])

      # With a preview pane focused, `move` scrolls the PREVIEW; extend must still move the
      # list cursor, or shift-down would silently do nothing.
      prev = Gori::Settings.history_preview
      begin
        Gori::Settings.history_preview = true
        view.set_preview_focus(:req)
        view.clear_marks
        view.extend_marks(1)
        view.selected_id.should eq(ids[1])
        view.mark_count.should eq(2)
      ensure
        Gori::Settings.history_preview = prev
      end
    end
  end

  it "prunes the marks it deletes, and drops every mark on a clear" do
    tmp_store do |store|
      ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      view.mark_all
      view.mark_count.should eq(3)

      # True ⇒ the write COMMITTED. A rollback returns false and leaves the marks alone, since
      # they are the only remaining handle on the set the user asked to delete.
      view.delete_ids(store, [ids[0], ids[1]]).should be_true
      store.count.should eq(1)
      view.mark_count.should eq(1) # deleted ids can't linger and inflate the next count
      view.marked?(ids[2]).should be_true

      view.clear(store)
      view.mark_count.should eq(0)
    end
  end

  it "renders a marked row distinctly from the cursor row, with a live count" do
    tmp_store do |store|
      3.times { |i| add_flow(store, "GET", "/p#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("marked").should be_false # nothing marked ⇒ no chip
      backend.contains?("▌").should be_false      # …and no mark gutter

      view.select_row(1)
      view.toggle_mark
      view.toggle_mark
      view.select_row(0) # park the cursor on an UNMARKED row so all three states render
      backend2 = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend2), Rect.new(0, 0, 80, 12))
      backend2.contains?("2 marked").should be_true
      backend2.contains?("▌").should be_true # the fuller mark bar, on the 2 marked rows
      backend2.contains?("▎").should be_true # the cursor bar still reads differently
    end
  end

  it "reports the hidden split on the count chip, so the count never outruns the screen" do
    tmp_store do |store|
      add_flow(store, "GET", "/ok", 200)
      add_flow(store, "GET", "/err", 500)
      view = HistoryView.new
      view.reload(store)
      view.mark_all
      "status:500".each_char { |c| view.query_insert(c) }
      view.reload(store)
      backend = MemoryBackend.new(80, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("2 marked").should be_true
      backend.contains?("1 hidden").should be_true
    end
  end

  # "Copy as…" over the target SET. One flow keeps the familiar single-message format list;
  # N flows get the set-shaped formats, because concatenating N raw dumps is never the ask.
  it "offers single-message formats for one flow and set formats for many" do
    tmp_store do |store|
      a = add_flow(store, "GET", "/a", 200, host: "one.test")
      b = add_flow(store, "POST", "/b", 200, host: "two.test")
      view = HistoryView.new
      view.reload(store)

      title, opts = view.list_copy_as_menu(store, [a])
      title.should eq("COPY REQUEST AS")
      opts.map(&.key).should contain('u') # URL
      opts.map(&.key).should contain('r') # Raw request

      title, opts = view.list_copy_as_menu(store, [a, b])
      title.should eq("COPY 2 FLOWS AS")
      by_key = opts.to_h { |o| {o.key, o} }
      by_key['u'].label.should eq("URLs")
      by_key['u'].text.lines.size.should eq(2)
      by_key['h'].label.should eq("Host list")
      by_key['h'].text.lines.sort!.should eq(["one.test", "two.test"])
      by_key['l'].label.should eq("cURL")
      # Raw messages contain blank lines, so each is prefixed with a labelled separator
      # rather than joined on a blank line (which would be ambiguous).
      by_key['r'].text.should contain("===== flow ##{a}")
      by_key['r'].text.should contain("===== flow ##{b}")
    end
  end

  # The exchange, which neither raw variant carries alone: request then response, both verbatim.
  it "offers the req+res pair for one flow and per-flow pairs for a set" do
    tmp_store do |store|
      a = add_flow(store, "GET", "/a", 200, host: "one.test")
      b = add_flow(store, "POST", "/b", 500, host: "two.test")
      view = HistoryView.new
      view.reload(store)

      _, opts = view.list_copy_as_menu(store, [a])
      pair = opts.find { |o| o.key == 'p' }.not_nil!
      pair.label.should eq("Req + Res pair")
      pair.text.should eq("GET /a HTTP/1.1\r\nHost: one.test\r\n\r\n\n\nHTTP/1.1 200 X\r\n\r\nbodybody")

      _, opts = view.list_copy_as_menu(store, [a, b])
      pairs = opts.find { |o| o.key == 'p' }.not_nil!
      pairs.label.should eq("Req + Res pairs")
      pairs.text.should contain("===== flow ##{a}")
      pairs.text.should contain("===== flow ##{b}")
      pairs.text.should contain("HTTP/1.1 500 X") # the response rides along with its request
    end
  end

  # The drill-in offers the pair from BOTH panes. The pane-local format list says what that
  # pane shows; it is not a rule that the exchange must be reassembled by hand.
  it "offers the req+res pair from both detail panes" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true

      title, opts = view.detail_copy_as_menu
      title.should eq("COPY REQUEST AS")
      pair = opts.find { |o| o.key == 'p' }.not_nil!
      pair.label.should eq("Req + Res pair")
      pair.text.should eq("GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n\n\nHTTP/1.1 200 X\r\n\r\nbodybody")

      view.toggle_pane # request → response
      title, opts = view.detail_copy_as_menu
      title.should eq("COPY RESPONSE AS")
      opts.find { |o| o.key == 'p' }.not_nil!.text.should eq(pair.text) # same exchange, same key
    end
  end

  it "offers no pair for a flow with no response yet" do
    tmp_store do |store|
      add_flow(store, "GET", "/pending", nil)
      view = HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      _, opts = view.detail_copy_as_menu
      opts.map(&.key).should contain('r')     # the raw request is still there
      opts.map(&.key).should_not contain('p') # …but there is no exchange to copy
    end
  end

  # A flow still in flight has no response — it contributes its request rather than dropping out.
  it "keeps a response-less flow in the pair set, request only" do
    tmp_store do |store|
      a = add_flow(store, "GET", "/pending", nil)
      b = add_flow(store, "GET", "/done", 200)
      view = HistoryView.new
      view.reload(store)

      _, opts = view.list_copy_as_menu(store, [a, b])
      pairs = opts.find { |o| o.key == 'p' }.not_nil!
      pairs.text.should contain("GET /pending HTTP/1.1")
      pairs.text.should contain("HTTP/1.1 200 X")

      # …and with no response at all there is no pair to offer for a single flow.
      _, one = view.list_copy_as_menu(store, [a])
      one.map(&.key).should_not contain('p')
      one.map(&.key).should_not contain('s')
    end
  end

  # Past the cap the byte-carrying formats are not offered — AND the bodies are never read.
  # get_flow pulls the full request+response (2 MiB each); ⇧T can hand this a whole page, and
  # this all runs on the single-threaded render loop, so loading N bodies to print N URLs would
  # freeze for the length of the keypress. The counting store below is the regression guard.
  it "drops the byte-carrying copy formats past the cap without loading any body" do
    tmp_counting_store do |store|
      ids = (0..HistoryView::COPY_BYTES_CAP).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      store.reset_counts
      _, opts = view.list_copy_as_menu(store, ids)
      keys = opts.map(&.key)
      keys.should contain('u')
      keys.should contain('h')
      keys.should_not contain('l')      # cURL
      keys.should_not contain('r')      # raw requests
      keys.should_not contain('s')      # raw responses
      keys.should_not contain('p')      # req+res pairs
      store.get_flow_calls.should eq(0) # rows only — no body reads past the cap
      store.flow_row_calls.should eq(ids.size)
    end
  end

  it "loads one body per flow for the byte formats inside the cap" do
    tmp_counting_store do |store|
      ids = (0...3).map { |i| add_flow(store, "GET", "/#{i}", 200) }
      view = HistoryView.new
      view.reload(store)
      store.reset_counts
      _, opts = view.list_copy_as_menu(store, ids)
      opts.map(&.key).should contain('r')
      store.get_flow_calls.should eq(ids.size)
    end
  end

  it "resolves marks through the store, so a mark for a vanished flow is skipped" do
    tmp_store do |store|
      add_flow(store, "GET", "/a", 200)
      b = add_flow(store, "GET", "/b", 200)
      view = HistoryView.new
      view.reload(store)
      view.mark_all
      store.delete_flow(b) # gone behind the view's back (another surface, a trim)
      _, opts = view.list_copy_as_menu(store, view.target_ids)
      opts.find { |o| o.key == 'u' }.not_nil!.text.lines.size.should eq(1)
    end
  end
end

describe "HistoryView::QL_FIELDS" do
  # Tab-completion must offer exactly what QL implements. `flag:` used to head the list, so
  # `f` + Tab deterministically produced a field with no store behind it (Store#flags_for is
  # a stub): it free-texts, matches nothing, and the empty list reads as "no flows match".
  # `url:` was the reverse — real and working, but never suggested. Pin both directions.
  it "offers no field QL cannot compile, and hides no field it can" do
    fields = Gori::Tui::HistoryView::QL_FIELDS
    fields.should_not contain("flag") # no flow-flag store exists (ql.cr's else branch says so)
    fields.should contain("url")      # a real field that was missing from the suggestions
    fields.should eq(fields.uniq)
  end

  it "suggests a working field for `f`, and never completes to `flag:`" do
    tmp_store do |store|
      add_flow(store, "GET", "/x", 200)
      view = HistoryView.new
      view.reload(store)
      view.start_query
      "f".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should_not contain("flag:")
      view.query_complete
      view.query.should_not eq("flag:")
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
