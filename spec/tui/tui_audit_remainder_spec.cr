require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Regressions for the four TUI-audit defects that survived the first fix round:
# the Issues scroll clamp, the History cursor drift on an emptied list, the
# preview-focus soft-lock after a resize collapses the pane, and the two missing
# width clamps. Each `it` here failed before its fix and passes after.

private def tmp_store(&)
  path = File.tempname("gori-audit", ".db")
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

private def add_flow(store, method, target, host = "h.test")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\nbody".to_slice,
    body: "body".to_slice, content_type: "text/plain"))
  id
end

describe "TUI audit remainder — IssuesView scroll clamp" do
  # The list can shrink UNDER a scrolled viewport (a batch delete that takes the cursor row,
  # a `/` query that excludes it): apply_filter re-clamps @selected but never @scroll, and
  # ensure_visible only had the two "bring the cursor into view" rules — neither fires when
  # the cursor is already inside the stale window. IssuesView draws no scroll gauge, so the
  # symptom is silent: a 44-issue result paints 3 rows with 7 rows of dead space below it.
  it "clamps @scroll to the shrunken list so the pane refills instead of showing dead space" do
    prev = Gori::Settings.issues_preview
    begin
      Gori::Settings.issues_preview = false # keep list_split whole: this asserts on list_h
      tmp_store do |store|
        60.times { |i| store.insert_issue("issue #{i}", Gori::Store::Severity::Medium, "h.test", nil) }
        view = IssuesView.new
        view.reload(store)

        rect = Rect.new(0, 0, 100, 13) # rows start at rect.y + 3 ⇒ list_h = 10
        view.move(50)
        view.render(Screen.new(MemoryBackend.new(100, 13)), rect)
        view.@scroll.should eq(41) # ensure_visible pulled the window down to the cursor

        ids = view.@issues.map(&.id)
        view.delete_ids(store, ids[44..]).should be_true # 16 gone, INCLUDING the cursor row
        view.selected_index.should eq(43)                # id anchor lost ⇒ clamped to the new end

        backend = MemoryBackend.new(100, 13)
        view.render(Screen.new(backend), rect)
        view.@scroll.should eq(34) # 44 issues − 10 visible rows
        (3...13).count { |y| backend.row(y).blank? }.should eq(0)
      end
    ensure
      Gori::Settings.issues_preview = prev
    end
  end
end

describe "TUI audit remainder — HistoryView cursor on an emptied list" do
  # `Clear history` leaves @selected at the 0 PLACEHOLDER with @follow already off. The
  # incremental insert path then treated that 0 as a real anchor and shifted it on every
  # prepend, putting the cursor one past the end — selected_id nil, every id-keyed verb a
  # silent no-op, and (off-tab, where nothing re-clamps) a reload that re-targets the
  # cursor onto a row the operator never chose.
  it "does not walk the cursor past the end when inserts land on a cleared (empty) list" do
    tmp_store do |store|
      add_flow(store, "GET", "/a")
      add_flow(store, "GET", "/b")
      view = HistoryView.new
      view.reload(store)
      view.move(1) # off the live tail ⇒ follow off
      view.follow?.should be_false

      view.clear(store).should be_true
      view.rows.size.should eq(0)
      view.follow?.should be_false # clear does not re-arm follow — the drift precondition

      3.times { |i| view.on_event(Gori::Store::FlowEvent.new(add_flow(store, "GET", "/new#{i}"), :inserted), store) }

      view.rows.size.should eq(3)
      view.selected.should be < view.rows.size # 0 <= @selected < @rows.size
      held = view.selected_id
      held.should_not be_nil # a cursor with no row makes ↵/r/t/d/copy silent no-ops

      view.reload(store)               # what on_enter does when the tab comes back
      view.selected_id.should eq(held) # ...and it must not silently re-target the cursor
    end
  end
end

describe "TUI audit remainder — preview focus after a collapsing resize" do
  # list_split hands back no preview below rect.h 12 (an 80x19 terminal), but @preview_focus
  # kept naming the pane that is no longer drawn. preview_scroll_focused? has no geometry
  # check, so ↑/↓, PgUp/PgDn and the wheel all fed an invisible pane's scroll offset and the
  # list stopped moving — a soft-lock only Tab or a row click could clear.
  it "snaps HistoryView preview focus back to the list when the pane collapses" do
    prev = Gori::Settings.history_preview
    begin
      Gori::Settings.history_preview = true
      tmp_store do |store|
        add_flow(store, "GET", "/a")
        add_flow(store, "GET", "/b")
        add_flow(store, "GET", "/c")
        view = HistoryView.new
        view.reload(store)
        view.set_preview_focus(:req)
        view.preview_focus.should eq(:req)

        rect = Rect.new(0, 0, 80, 11) # 80x19 terminal ⇒ body.inset(1,1).h == 11
        view.list_split(rect)[1].should be_nil
        view.render_list(Screen.new(MemoryBackend.new(80, 11)), rect)

        view.preview_focus.should eq(:list)
        before = view.selected
        view.move(1)
        view.selected.should_not eq(before) # arrows drive the list, not an invisible pane
      end
    ensure
      Gori::Settings.history_preview = prev
    end
  end

  it "snaps IssuesView preview focus back to the list when the pane collapses" do
    prev = Gori::Settings.issues_preview
    begin
      Gori::Settings.issues_preview = true
      tmp_store do |store|
        3.times { |i| store.insert_issue("issue #{i}", Gori::Store::Severity::Medium, "h.test", nil) }
        view = IssuesView.new
        view.reload(store)
        view.set_preview_focus(:preview)
        view.preview_focus.should eq(:preview)

        rect = Rect.new(0, 0, 80, 11)
        view.list_split(rect)[1].should be_nil
        view.render(Screen.new(MemoryBackend.new(80, 11)), rect)

        view.preview_focus.should eq(:list)
        before = view.selected_index
        view.move(1)
        view.selected_index.should_not eq(before)
      end
    ensure
      Gori::Settings.issues_preview = prev
    end
  end
end

describe "TUI audit remainder — missing width clamps" do
  # METHOD sits in a fixed 8-column cell (method_x = rect.x + 16, proto_x = rect.x + 24) but
  # was drawn with no `width:` at all, so its limit was the whole screen. RFC 9110 permits
  # any token and the parser caps nothing, so a long method ran through PROTO/HOST/PATH.
  it "clamps an over-long METHOD token to its 8-column cell" do
    tmp_store do |store|
      add_flow(store, "X-CUSTOM-METHOD", "/vc")
      view = HistoryView.new
      view.reload(store)

      backend = MemoryBackend.new(100, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 100, 12))
      line = backend.row(3) # list_top = rect.y + 3 (QL bar, header, divider)

      # Budget is the FULL 8, not 7-in-8 like the neighbouring cells. PROTO draws at its own
      # absolute `proto_x`, so a full 8 columns cannot bleed into it — 7 would only buy a
      # blank gap, and it costs `PROPFIND` and `CHECKOUT` (both exactly 8, both methods this
      # tool is pointed at), which the unclamped code rendered correctly. A clamp that
      # truncates a real method is a regression the clamp introduced; a tight column is not.
      line[16, 8].should eq("X-CUSTO…") # ellipsized inside the cell, not clipped silently
      line[24, 4].should eq("HTTP")     # PROTO starts at its own x, untouched
      line[28, 3].should eq("   ")      # nothing bleeds out of METHOD toward HOST
      line.should contain("h.test")
    end
  end

  # The other half of choosing 8 over 7: the widest REAL methods must survive the clamp. If
  # someone re-tightens this cell to 7 for the sake of a gap column, this fails and says why.
  it "renders an exactly-8-character method in full, without eating PROTO" do
    tmp_store do |store|
      add_flow(store, "PROPFIND", "/dav")
      view = HistoryView.new
      view.reload(store)

      backend = MemoryBackend.new(100, 12)
      view.render_list(Screen.new(backend), Rect.new(0, 0, 100, 12))
      line = backend.row(3)

      line[16, 8].should eq("PROPFIND") # no ellipsis — it fits the cell exactly
      line[24, 4].should eq("HTTP")     # and PROTO is still where it belongs
    end
  end

  # The Issues row right-aligns the host from rect.right, and the leftover feeds the title
  # budget. Both used host.size — CHARACTERS — while the host is the flow's raw wire `Host`
  # with no punycode/IDNA anywhere on the path, so a wide-glyph host started too far right,
  # painted past the card's border, and over-budgeted the title underneath itself.
  it "right-aligns an IDN host by display columns, not characters" do
    tmp_store do |store|
      store.insert_issue("cross-site scripting in the search parameter",
        Gori::Store::Severity::High, "日本語.test", nil)
      view = IssuesView.new
      view.reload(store)

      Screen.display_width("日本語.test").should eq(11) # 8 characters, 11 columns
      backend = MemoryBackend.new(80, 10)            # backend wider than the pane, so an overrun shows
      view.render(Screen.new(backend), Rect.new(0, 0, 40, 10))

      backend.cluster_grid[3][28].should eq("日") # rect.right − 11 − 1
      backend.row(3)[27].should eq(' ')          # title budget stops short of the host
      backend.row(3)[39, 4].should eq("    ")    # nothing at or past the pane's edge
    end
  end
end
