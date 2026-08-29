require "../spec_helper"

# `events_recent` is the human mirror of `events_after` (#864): newest-first, narrowed in SQL,
# and bounded so a predicate that matches nothing cannot walk all 50k retained rows on the
# fiber that paints the screen.
#
# The three properties worth pinning, because each was a live defect in an earlier shape:
#   * the level filter is a SET — the feed carries both "warn" and the Sequencer's "warning";
#   * a short page means the WINDOW ran out, not the feed, so `next_before` must name the
#     window edge rather than nil (paging stops early otherwise);
#   * `next_before` is nil only at the true oldest row.
# `Store.open` and not a bare `DB.open` + `Store.new`: `configure_connections` is what installs
# `gori_ci_contains` (and REGEXP) on each pooled connection, and the free-text arm below runs
# through it for a non-ASCII needle. A hand-built pool answers "no such function" — which is
# also the shape of the bug this would miss in the app.
private def events_store(events_retention : Int32 = Gori::Store::EVENTS_RETENTION, &)
  path = File.tempname("gori-events-recent", ".db")
  store = Gori::Store.open(path, events_retention: events_retention)
  begin
    yield store
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Store#events_recent" do
  it "returns the newest rows first" do
    events_store do |store|
      5.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush

      page = store.events_recent(10)
      page.rows.map(&.message).should eq(["event 4", "event 3", "event 2", "event 1", "event 0"])
      page.next_before.should be_nil # reached the oldest row
    end
  end

  it "pages backwards with before_id into contiguous, disjoint pages" do
    events_store do |store|
      9.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush

      first = store.events_recent(4)
      first.rows.map(&.message).should eq(["event 8", "event 7", "event 6", "event 5"])
      before = first.next_before
      before.should_not be_nil

      second = store.events_recent(4, before)
      second.rows.map(&.message).should eq(["event 4", "event 3", "event 2", "event 1"])

      third = store.events_recent(4, second.next_before)
      third.rows.map(&.message).should eq(["event 0"])
      third.next_before.should be_nil

      ids = (first.rows + second.rows + third.rows).map(&.id)
      ids.uniq.size.should eq(9)
    end
  end

  it "narrows by source" do
    events_store do |store|
      store.insert_event("agent", "agent_action", "info", "create_issue ok")
      store.insert_event("bindings", "extract_miss", "warn", "$sid found nothing")
      store.insert_event("agent", "agent_action", "warn", "send_request failed (SCOPE_BLOCKED)")
      store.flush

      rows = store.events_recent(50, source: "agent").rows
      rows.size.should eq(2)
      rows.all? { |r| r.source == "agent" }.should be_true
    end
  end

  # The Sequencer writes `level.to_s` of :warning; everything else writes "warn". A chip that
  # matched one spelling would silently hide the other half of the feed's warnings, and rows
  # already on disk cannot be respelled.
  it "matches every spelling of a level the feed actually carries" do
    events_store do |store|
      store.insert_event("bindings", "extract_miss", "warn", "spelled warn")
      store.insert_event("sequencer", "job_done", "warning", "spelled warning")
      store.insert_event("probe", "scan_complete", "info", "not a warning at all")
      store.flush

      rows = store.events_recent(50, levels: ["warn", "warning"]).rows
      rows.map(&.message).sort.should eq(["spelled warn", "spelled warning"])

      # And the single-spelling filter really is the thing that would have hidden one:
      store.events_recent(50, levels: ["warn"]).rows.size.should eq(1)
    end
  end

  it "matches the free-text query against source, kind and message, case-insensitively" do
    events_store do |store|
      store.insert_event("agent", "agent_action", "info", "create_issue ok")
      store.insert_event("bindings", "extract_miss", "warn", "$sid found nothing")
      store.insert_event("probe", "hook_failed", "warn", "./sign.sh exited 1")
      store.flush

      store.events_recent(50, query: "EXTRACT").rows.map(&.kind).should eq(["extract_miss"])
      store.events_recent(50, query: "probe").rows.map(&.source).should eq(["probe"])
      store.events_recent(50, query: "create_issue").rows.size.should eq(1)
      store.events_recent(50, query: "nothing at all here").rows.should be_empty
    end
  end

  # A non-ASCII needle takes the `gori_ci_contains` UDF arm of QL.contains_cond rather than the
  # native LIKE; SQLite's own `lower()` is ASCII-only, so this row is unreachable without it.
  it "matches a non-ASCII needle case-insensitively" do
    events_store do |store|
      store.insert_event("rewriter", "hook_failed", "warn", "rule \"Überweisung\" not applied")
      store.flush

      store.events_recent(50, query: "überweisung").rows.size.should eq(1)
    end
  end

  it "combines narrowings" do
    events_store do |store|
      store.insert_event("agent", "agent_action", "info", "create_issue ok")
      store.insert_event("agent", "agent_action", "warn", "send_request failed (SCOPE_BLOCKED)")
      store.insert_event("bindings", "unbound", "warn", "send_request-ish text")
      store.flush

      rows = store.events_recent(50, source: "agent", levels: ["warn"], query: "send_request").rows
      rows.size.should eq(1)
      rows.first.message.should contain("SCOPE_BLOCKED")
    end
  end

  # The bound exists because nothing indexes `events`: a narrowing that matches nothing cannot
  # short-circuit on the LIMIT, so without it the scan runs until the table does.
  #
  # Its SIZE is the store's retention cap, which is what keeps the bound from lying: in a store
  # being trimmed the whole feed fits inside one window, so "no rows matched" is a statement
  # about the whole feed. The window is exercised here with a tiny retention because that is
  # the only way to reach the case at all — and reaching it is what proves `next_before` names
  # the window edge rather than reporting the end of a feed that has more below it.
  it "bounds one page at the retention cap and resumes at the window edge" do
    events_store(events_retention: 40) do |store|
      # Oldest row in the feed, and the only match — deliberately below the first window.
      store.insert_event("bindings", "extract_miss", "warn", "$sid found nothing")
      100.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush

      page = store.events_recent(50, source: "bindings")
      page.rows.should be_empty # out of reach of ONE page, by construction
      # BOTH scan bounds are exclusive (`id > floor AND id < anchor`), so a 40-id window reads
      # 39 ids. Asserted as the ids covered rather than as the retention constant: pinning the
      # constant is what let an off-by-one through, and this number is rendered to the operator
      # in a sentence promising the scan looked no further.
      page.window.should eq(39)

      # Not nil: rows still sit below the window, and a nil here would read as "end of feed"
      # and stop the pane's paging short of a row that exists.
      nxt = page.next_before
      nxt.should_not be_nil
      max_id = store.events_recent(1).rows.first.id
      nxt.should eq(max_id + 1 - 40 + 1)

      # And paging from it does reach the row the window could not.
      found = [] of Gori::Store::EventRow
      cursor = nxt
      while cursor
        p = store.events_recent(50, cursor, source: "bindings")
        found.concat(p.rows)
        cursor = p.next_before
      end
      found.map(&.message).should eq(["$sid found nothing"])
    end
  end

  # The healthy case, and the reason the window is the retention cap rather than a slice of it:
  # a store under its cap answers "nothing matched" about the WHOLE feed, with no resume point
  # left dangling for a caller to misread as more rows.
  it "does not truncate a feed that is inside its retention cap" do
    events_store do |store|
      500.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush

      page = store.events_recent(50, source: "bindings")
      page.rows.should be_empty
      page.next_before.should be_nil # the scan really did reach the oldest row
    end
  end

  # A cleared feed must not hand a REUSED id to an agent whose `events_after` watermark is
  # still parked above it — that would silently skip real events, or replay one id as two
  # different events. `AUTOINCREMENT` is what prevents it, and this is the spec that says so.
  it "keeps ids climbing across a clear, so a forward cursor stays sound" do
    events_store do |store|
      3.times { |i| store.insert_event("agent", "agent_action", "info", "before #{i}") }
      store.flush
      high = store.events_recent(1).rows.first.id

      store.clear_events.should be_true
      store.flush
      store.events_recent(50).rows.should be_empty

      store.insert_event("agent", "agent_action", "info", "after")
      store.flush
      after = store.events_recent(1).rows.first
      after.message.should eq("after")
      after.id.should be > high

      # And the agent's watermark still means what it meant: nothing before it comes back.
      store.events_after(high, 50).map(&.message).should eq(["after"])
    end
  end

  it "answers an empty feed with no rows and no resume point" do
    events_store do |store|
      page = store.events_recent(50)
      page.rows.should be_empty
      page.next_before.should be_nil
    end
  end

  # `window` is rendered to the operator as "the newest N events", and `activity_load_more`
  # ACCUMULATES it across every page a `↓` walk covers. A page that filled at the LIMIT stopped
  # reading at its last row, so crediting it with the whole scan bound counted ids nothing ever
  # looked at: walking a 200k feed reported 43.7M. The sum over a full walk has to be the feed.
  it "counts the ids a page actually read, not the width of its bound" do
    events_store do |store|
      2_000.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush

      first = store.events_recent(200)
      first.rows.size.should eq(200)
      # 200 rows read, NOT the 50k the scan was allowed to cover.
      first.window.should eq(200)

      total = 0
      cursor = nil.as(Int64?)
      loop do
        page = store.events_recent(200, cursor)
        total += page.window
        cursor = page.next_before
        break if cursor.nil?
      end
      total.should eq(2_000)
    end
  end
end
