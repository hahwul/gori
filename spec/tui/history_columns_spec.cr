require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# User-defined History columns (#819) as the LIST draws them: the header, the value, the miss,
# and the read budget. The last one is the acceptance criterion with no visible symptom — a
# column that quietly extracted every row in the window instead of every row on screen would
# look identical and cost a frame per scroll.

private class CountingStore < Gori::Store
  getter get_flow_calls = 0
  # The body budget the last read asked for — 0 means "no BLOB at all", which is what a
  # head-only column set (or one whose body-scoped columns were dropped) must produce.
  getter last_body_max : Int32? = nil

  def reset_counts : Nil
    @get_flow_calls = 0
    @last_body_max = nil
  end

  def get_flow(id : Int64, *, body_max : Int32? = nil) : Gori::Store::FlowDetail?
    @get_flow_calls += 1
    @last_body_max = body_max
    super
  end
end

private def tmp_store(&)
  path = File.tempname("gori-hcol", ".db")
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

# Each flow gets its own `created_at`, as real capture does (unix micros at the moment of the
# request) — the column memo is keyed on it, and a fixture that stamped every row with the same
# instant would be testing a store that does not exist.
private CLOCK = [1_700_000_000_000_000_i64]

private def add_flow(store, id_header : String?, *, complete = true, body : String? = nil)
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "http", host: "h.test", port: 80,
    method: "GET", target: "/x", http_version: "HTTP/1.1",
    head: "GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  if complete
    head = String.build do |io|
      io << "HTTP/1.1 200 OK\r\n"
      io << "X-Request-Id: " << id_header << "\r\n" if id_header
      io << "\r\n"
    end
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 200, head: head.to_slice, body: body.try(&.to_slice)))
  end
  id
end

private def header_column(label = "RID", selector = "x-request-id",
                          kind = Gori::ExtractKind::Header, width = 0) : Gori::Store::DisplayColumn
  Gori::Store::DisplayColumn.new(1_i64, 0, label, Gori::MessageSide::Response, kind, selector, 0, 0, width)
end

private def screen_rows(view : HistoryView, w = 120, h = 14) : Array(String)
  backend = MemoryBackend.new(w, h)
  view.render_list(Screen.new(backend), Rect.new(0, 0, w, h))
  (0...h).map { |y| backend.row(y) }
end

private def screen_text(view : HistoryView, w = 120, h = 14) : String
  screen_rows(view, w, h).join("\n")
end

describe "HistoryView — user-defined columns" do
  it "draws the label as a column head and the extracted value on each row" do
    tmp_store do |store|
      add_flow(store, "alpha-1")
      add_flow(store, "beta-2")

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)

      text = screen_text(view)
      text.should contain("RID")
      text.should contain("alpha-1")
      text.should contain("beta-2")
    end
  end

  # BLANK, never the selector, and never `—`: `—` is already SRC's word for "gori does not
  # know", and a column whose descriptor simply did not match this message is not that.
  it "leaves the cell empty for a flow the descriptor does not match" do
    tmp_store do |store|
      add_flow(store, "alpha-1")
      add_flow(store, nil)

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)

      text = screen_text(view)
      text.should contain("alpha-1")
      text.should_not contain("x-request-id")
    end
  end

  # P8, and the acceptance criterion this feature is most likely to quietly break: the window
  # holds up to MAX_ROWS, the screen holds a dozen, and only the dozen may be read.
  it "extracts only the rows on screen, and remembers what it extracted" do
    tmp_store do |store|
      40.times { |i| add_flow(store, "id-#{i}") }

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)
      view.rows.size.should eq(40)

      # A 14-row card leaves ~10 list rows after the filter bar, the header and the divider.
      store.reset_counts
      screen_text(view)
      drawn = store.get_flow_calls
      drawn.should be > 0
      drawn.should be < 20

      # Second frame, same rows: nothing re-read. Without the memo this list would pay `drawn`
      # SQLite round-trips per frame, forever.
      store.reset_counts
      screen_text(view)
      store.get_flow_calls.should eq(0)
    end
  end

  # A Pending flow's response has not landed, so its answer is provisional — but the memo is
  # keyed on STATE, so it is cached like any other row and re-extracted exactly once, when the
  # response arrives. Refusing to cache Pending at all instead re-read the TOP of the list on
  # every frame, which during live capture is precisely where the Pending rows are.
  it "re-reads a pending flow once — when it settles — and not once per frame" do
    tmp_store do |store|
      id = add_flow(store, nil, complete: false)

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)
      screen_text(view).should_not contain("later-1")

      # Still Pending, still on screen: the second frame must cost nothing.
      store.reset_counts
      screen_text(view)
      store.get_flow_calls.should eq(0)

      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nX-Request-Id: later-1\r\n\r\n".to_slice))
      view.reload(store)
      store.reset_counts
      screen_text(view).should contain("later-1")
      store.get_flow_calls.should eq(1) # the state changed, so exactly one re-extract
      store.reset_counts
      screen_text(view)
      store.get_flow_calls.should eq(0)
    end
  end

  # The pane grants a PREFIX of the set. A column too narrow to draw must not cost the 512 KiB
  # BLOB read and the content-decode that come with it — the budget is asked of what is drawn.
  it "does not read the body for a body-scoped column the pane is too narrow to draw" do
    tmp_store do |store|
      add_flow(store, "alpha-1", body: %({"id":"json-9"}))

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([
        header_column(label: "FIRST", width: 10),
        Gori::Store::DisplayColumn.new(2_i64, 1, "JID", Gori::MessageSide::Response,
          Gori::ExtractKind::JsonPath, "id", 0, 0, 10),
      ])
      view.reload(store)

      # Wide: both drawn, so the body is read and the jsonpath resolves.
      screen_text(view, w: 140).should contain("json-9")

      # Narrow: only FIRST is granted, so the jsonpath column is neither drawn nor evaluated —
      # and `get_flow` is asked for no body at all.
      view.forget_column_values
      narrow = screen_text(view, w: 78)
      narrow.should contain("alpha-1")
      narrow.should_not contain("json-9")
      store.last_body_max.should eq(0)
    end
  end

  # Each column is granted `width + 1` and drawn one cell in, so the spare cell is a LEADING gap.
  # Charged at the back instead, the last column's final cell fell off the frame's hairline and
  # the row's right margin moved by one the moment a column was configured.
  it "ends the column block flush with the frame, exactly where DUR ends without one" do
    tmp_store do |store|
      add_flow(store, "abcdefgh")

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column(label: "RID", width: 8)])
      view.reload(store)
      row = screen_rows(view, w: 120).find! { |r| r.includes?("h.test") }

      # An 8-wide column holding an 8-character value fills its cell exactly, so the row's last
      # painted cell IS the block's last cell. Flush with the frame means the rstripped row is
      # the full pane width; charged at the back it was 119 — one dead cell at the hairline, and
      # a right margin that moved the moment a column was configured.
      row.should contain("abcdefgh")
      row.rstrip.size.should eq(120)
    end
  end

  # `flows.id` is a REUSABLE rowid: a clear restarts numbering, and the next capture lands on
  # an id the memo may still be holding. Keying on the id alone painted the CLEARED flow's
  # value on the new one's row — the one failure a display column must never have.
  it "does not serve a cleared flow's value to a new flow that reuses its rowid" do
    tmp_store do |store|
      old_id = add_flow(store, "before-clear")

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)
      screen_text(view).should contain("before-clear")

      # Straight at the STORE, not through `HistoryView#clear` — the view drops the memo on its
      # own clear/delete paths, and this is the case those two cannot cover: a peer process
      # wiping the project. The `{id, created_at}` key is what has to hold here.
      store.clear_flows
      new_id = add_flow(store, "after-clear")
      new_id.should eq(old_id) # the rowid really was reused — otherwise this proves nothing

      view.reload(store)
      text = screen_text(view)
      text.should contain("after-clear")
      text.should_not contain("before-clear")
    end
  end

  # The other half of the same hazard, and the one the view CAN close outright: gori's own
  # delete/clear drop the memo, so the next capture onto a reused rowid is read fresh whatever
  # its timestamp.
  it "forgets what it extracted when the view itself clears the project" do
    tmp_store do |store|
      add_flow(store, "before-clear")

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)
      screen_text(view).should contain("before-clear")

      view.clear(store)
      view.@col_values.empty?.should be_true
    end
  end

  # Every cached value was extracted by the OLD descriptors; keeping them would paint one
  # column's values under another's header for as long as the rows stayed on screen.
  it "forgets what it extracted when the column set changes" do
    tmp_store do |store|
      add_flow(store, "alpha-1", body: %({"id":"json-9"}))

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([header_column])
      view.reload(store)
      screen_text(view).should contain("alpha-1")

      view.set_columns([header_column(label: "JID", selector: "id", kind: Gori::ExtractKind::JsonPath)])
      text = screen_text(view)
      text.should contain("JID")
      text.should contain("json-9")
      text.should_not contain("alpha-1")
    end
  end

  # The grant is a PREFIX and never a gap: the set is read left to right, and a middle column
  # silently missing would make the row lie about which value is which. The columns outrank
  # TYPE/SIZE/DUR, which are the cells nobody asked for.
  it "keeps the leftmost columns and drops the built-in cluster when the pane is narrow" do
    tmp_store do |store|
      add_flow(store, "alpha-1")

      view = HistoryView.new
      view.set_column_store(store)
      view.set_columns([
        header_column(label: "FIRST", width: 10),
        Gori::Store::DisplayColumn.new(2_i64, 1, "SECOND", Gori::MessageSide::Response,
          Gori::ExtractKind::Header, "x-request-id", 0, 0, 10),
      ])
      view.reload(store)

      wide = screen_text(view, w: 140)
      wide.should contain("FIRST")
      wide.should contain("SECOND")
      wide.should contain("DUR")

      narrow = screen_text(view, w: 78)
      narrow.should contain("FIRST")
      narrow.should_not contain("DUR")
    end
  end

  # The list holds no store of its own; a controller that never handed one over must cost the
  # columns, not the tab.
  it "renders blank cells rather than raising when no store was handed over" do
    tmp_store do |store|
      add_flow(store, "alpha-1")
      view = HistoryView.new
      view.set_columns([header_column])
      view.reload(store)
      # `reload` is not what feeds the columns — only `set_column_store` is, and it was never
      # called here.
      text = screen_text(view)
      text.should contain("RID")
      text.should_not contain("alpha-1")
    end
  end
end
