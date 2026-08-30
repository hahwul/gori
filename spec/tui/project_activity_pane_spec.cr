require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Project tab's ACTIVITY pane (#864) — the human window over the #124 event feed.
#
# Four of the expectations below exist because the obvious implementation is wrong in a way
# that reads as working:
#
#   * the cursor is anchored to an EVENT ID, not a row index. The list is newest-first and
#     prepends, so an index cursor slides onto a neighbour the moment an agent writes and `↵`
#     then acts on a row nobody selected;
#   * "no activity recorded yet" and "no events match …" are DIFFERENT sentences. Once a chip
#     is on, `rows.empty?` stops meaning the feed is quiet, and the two readings send the
#     operator opposite ways;
#   * the `warn` chip has to match the Sequencer's "warning" spelling too, or half the feed's
#     warnings become invisible;
#   * `act_list_inner` is the single offset source — the filter bar and the detail band both
#     eat interior rows, and a hit-test that knows about only one lands on the wrong event.
private def tmp_store(events_retention : Int32 = Gori::Store::EVENTS_RETENTION, &)
  path = File.tempname("gori-activity-pane", ".db")
  store = Gori::Store.open(path, events_retention: events_retention)
  begin
    yield store, Gori::Project.new("p", path)
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def activity_view(store : Gori::Store, project : Gori::Project) : ProjectView
  view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
  view.reload(project, store)
  view.focus_pane(:activity)
  view
end

# Cycle the source chip until it lands on `name`. By NAME and not by a count of presses:
# adding a chip re-points every counted cycle, which is how three specs started asserting
# about a source they never meant when `config` joined the list.
private def cycle_source_to(view : ProjectView, name : String) : Nil
  ProjectView::ACT_SOURCES.size.times do
    return if view.activity_source == name
    view.activity_cycle_source
  end
  raise "source chip never reached #{name.inspect}"
end

private def cycle_level_to(view : ProjectView, name : String) : Nil
  ProjectView::ACT_LEVELS.size.times do
    return if view.activity_level == name
    view.activity_cycle_level
  end
  raise "level chip never reached #{name.inspect}"
end

private def screen_rows(view : ProjectView, rect : Rect) : Array(String)
  b = MemoryBackend.new(rect.w, rect.h)
  view.render(Screen.new(b), rect, focused: true)
  (0...rect.h).map { |r| b.row(r) }
end

# The screen row a message is drawn on, so a hit-test is asserted against the DRAW rather than
# against a hand-computed offset that would drift with the card geometry.
private def row_of(view : ProjectView, rect : Rect, needle : String) : Int32
  screen_rows(view, rect).index(&.includes?(needle)) || raise "#{needle.inspect} was not drawn"
end

private def seed(store : Gori::Store) : Nil
  store.insert_event("agent", "agent_action", "info", "create_issue ok", payload: "create_issue")
  store.insert_event("agent", "agent_action", "warn", "send_request failed (SCOPE_BLOCKED)", payload: "send_request")
  store.insert_event("bindings", "extract_miss", "warn",
    "$sid: cookie found nothing (no Set-Cookie header in this response) and the rule did not bind, " \
    "so the next request ships the token unexpanded instead of the value the login returned")
  store.insert_event("sequencer", "job_done", "warning", "Sequencer: budget exhausted",
    goto_tab: "sequencer", goto_session_id: 2_i64)
  store.insert_event("probe", "issue_found", "success", "Probe: reflected parameter", goto_tab: "probe")
  store.flush
end

private def ev(goto_tab : String? = nil, goto_session_id : Int64? = nil, flow_id : Int64? = nil)
  Gori::Store::EventRow.new(1_i64, 0_i64, "agent", "agent_action", "info", "m",
    goto_tab, goto_session_id, flow_id)
end

describe "ProjectView ACTIVITY pane" do
  it "is the sixth sub-tab, with a chip label parallel to its symbol" do
    ProjectView::PANES.size.should eq(6)
    ProjectView::PANES.last.should eq(:activity)
    ProjectView::PANE_LABELS.size.should eq(ProjectView::PANES.size)
    ProjectView::PANE_LABELS.last.should eq("Activity")
  end

  it "lists the feed newest-first with the level glyph and the source" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.reload_activity(store)

      view.activity_rows.map(&.message).first(2).should eq(
        ["Probe: reflected parameter", "Sequencer: budget exhausted"])

      rows = screen_rows(view, Rect.new(0, 0, 120, 34))
      probe = rows.find(&.includes?("Probe: reflected parameter")).not_nil!
      probe.should contain("✓")
      probe.should contain("probe")
      rows.find(&.includes?("send_request failed")).not_nil!.should contain("agent")
    end
  end

  # The whole reason the cursor is an id and not an index. Without this, an agent writing while
  # the operator reads moves the selection under them.
  it "keeps the cursor on the same event when newer ones arrive above it" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.reload_activity(store)

      view.activity_select(2) # the bindings miss, third from the top
      picked = view.activity_selected_row.not_nil!
      picked.source.should eq("bindings")

      3.times { |i| store.insert_event("agent", "agent_action", "info", "later #{i}") }
      store.flush
      view.reload_activity(store)

      view.activity_selected_row.not_nil!.id.should eq(picked.id)
      view.activity_rows.first.message.should eq("later 2") # the list really did prepend
    end
  end

  it "says the feed is empty and says a filter is hiding it, in different words" do
    tmp_store do |store, project|
      view = activity_view(store, project)
      view.reload_activity(store)
      rect = Rect.new(0, 0, 100, 30)

      view.activity_feed_empty?.should be_true
      # The onboarding card's own sentence — CENTERED variants draw no headline row, so the
      # card body is what the operator actually reads.
      screen_rows(view, rect).join("\n").should contain("What agents and background jobs did")

      seed(store)
      view.reload_activity(store)
      cycle_source_to(view, "rewriter") # nothing wrote one
      view.reload_activity(store)

      view.activity_rows.should be_empty
      # NOT "no activity recorded yet": the feed has five rows, the chip is hiding them.
      view.activity_feed_empty?.should be_false
      drawn = screen_rows(view, rect).join("\n")
      drawn.should contain("no events match source rewriter")
      drawn.should_not contain("What agents and background jobs did")
    end
  end

  # "warn" and "warning" are one level with two spellings; only the Sequencer writes the second.
  it "catches every spelling of a level under one chip" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      cycle_level_to(view, "warn")
      view.reload_activity(store)

      view.activity_level.should eq("warn")
      view.activity_rows.map(&.source).sort.should eq(["agent", "bindings", "sequencer"])
    end
  end

  # "no events match X" is a claim about what the scan READ. When the bound stopped it short —
  # only reachable on a feed grown past its own retention cap — the sentence has to say how far
  # it got, or it reports events it never looked at as absent.
  it "says how far it looked when the scan stopped short of the feed" do
    tmp_store(events_retention: 40) do |store, project|
      100.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush
      view = activity_view(store, project)
      cycle_source_to(view, "bindings") # no row has one
      view.reload_activity(store)
      rect = Rect.new(0, 0, 100, 30)

      view.activity_rows.should be_empty
      view.activity_more?.should be_true
      drawn = screen_rows(view, rect).join("\n")
      # 39, not 40: both scan bounds are exclusive. The sentence exists to promise the pane
      # looked no FURTHER than this, so overstating it by one defeats the whole point.
      drawn.should contain("no events match source bindings in the newest 39 events")
      # `↓` extends the scan; `r` restarts it from the newest end and throws away every window
      # already walked, so an empty state must not send the operator to it. `c` empties the
      # feed now, so it is not the way out either.
      drawn.should contain("↓ looks further back")
      drawn.should_not contain("r looks further back")
      drawn.should_not contain("c clears")
    end
  end

  it "claims nothing matched, flat, once the scan reached the whole feed" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      cycle_source_to(view, "rewriter") # nothing wrote one
      view.reload_activity(store)

      view.activity_more?.should be_false
      drawn = screen_rows(view, Rect.new(0, 0, 100, 30)).join("\n")
      drawn.should contain("no events match source rewriter")
      drawn.should_not contain("in the newest")
    end
  end

  # Releasing a filter has to RE-QUERY. `activity_filter_cancel` clears the query and the
  # cursor but not the narrowed rows, so a pane that skips the reload shows a subset as the
  # whole feed — under a filter bar that says nothing is on — and pages on from the filtered
  # resume cursor, dropping every event in between.
  it "re-queries when a committed filter is released" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.activity_filter_field.set("create_issue")
      view.reload_activity(store)
      view.activity_rows.size.should eq(1)

      view.activity_filter_cancel.should be_true
      view.activity_filtered?.should be_false
      # The view alone cannot re-query — the controller owns the store handle — so the
      # contract this pins is that the stale rows are still there until someone reloads, and
      # that reloading restores the whole feed. The controller-side spec below drives the key.
      view.reload_activity(store)
      view.activity_rows.size.should eq(5)
    end
  end

  # An append-only feed means new events land ABOVE the loaded set, so a refresh can fold them
  # in without discarding the pages the operator paged in. Re-reading page one instead (which
  # is what the external-change poll used to do, several times a second during live capture)
  # truncates the list and drops the cursor onto an unrelated event.
  it "folds in new events without discarding the pages already loaded" do
    tmp_store do |store, project|
      600.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_load_more(store).should be_true
      view.activity_load_more(store).should be_true
      deep = view.activity_rows.size
      deep.should be > ProjectView::ACT_PAGE

      view.activity_select(deep - 1) # cursor well below page one
      picked = view.activity_selected_row.not_nil!

      3.times { |i| store.insert_event("agent", "agent_action", "info", "newer #{i}") }
      store.flush
      view.refresh_activity(store)

      view.activity_rows.size.should eq(deep + 3)
      view.activity_rows.first.message.should eq("newer 2")
      view.activity_selected_row.not_nil!.id.should eq(picked.id)
      # Still one strictly descending, gapless run — a prepend that guessed would leave a hole.
      ids = view.activity_rows.map(&.id)
      ids.should eq(ids.sort.reverse!)
      (ids.first - ids.last + 1).should eq(ids.size)
    end
  end

  it "falls back to a full reload when the head it was anchored to is gone" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_rows.size.should eq(5)

      store.clear_events.should be_true
      store.insert_event("agent", "agent_action", "info", "after the clear")
      store.flush
      view.refresh_activity(store)

      view.activity_rows.map(&.message).should eq(["after the clear"])
    end
  end

  it "clears every narrowing at once, and reports when there is none" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.activity_clear_filters.should be_false # nothing set yet

      view.activity_cycle_source
      view.activity_filter_field.set("issue")
      view.activity_filtered?.should be_true
      view.activity_clear_filters.should be_true
      view.activity_source.should be_nil
      view.activity_filter_field.value.should eq("")
    end
  end

  it "shows the selected event's whole message under the list" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_select(2) # the long bindings message

      drawn = screen_rows(view, Rect.new(0, 0, 100, 34)).join("\n")
      # The row itself truncates; the band carries the words that explain it.
      drawn.should contain("ships the token unexpanded")
    end
  end

  # A short card keeps the LIST and loses the band, in that order — the same "a fact gets
  # smaller, it never disappears" rule the OVERVIEW band above it follows.
  it "drops the detail band before it drops list rows on a short card" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.reload_activity(store)

      tall = screen_rows(view, Rect.new(0, 0, 100, 34))
      short = screen_rows(view, Rect.new(0, 0, 100, 16))

      # The tee divider is the band's only structural mark, and it is the band that goes.
      tall.count(&.includes?('├')).should be > 0
      short.count(&.includes?('├')).should eq(0)
      # And the log is still a log: rows are drawn, they are just windowed.
      short.count { |r| r.includes?("18:") || r.includes?("Probe:") || r.includes?("agent") }.should be > 0
    end
  end

  # `act_list_inner` folds the filter bar AND the detail band. A hit-test that knew about only
  # one of them would select the event above or below the one under the pointer.
  it "picks the row under the pointer with both the filter bar and the detail band drawn" do
    tmp_store do |store, project|
      seed(store)
      view = activity_view(store, project)
      view.reload_activity(store)
      rect = Rect.new(0, 0, 120, 34)

      view.activity_row_at(rect, 5, row_of(view, rect, "Probe: reflected parameter")).should eq(0)
      view.activity_row_at(rect, 5, row_of(view, rect, "send_request failed")).should eq(3)
      view.activity_row_at(rect, 5, row_of(view, rect, "create_issue ok")).should eq(4)
    end
  end

  # `/` on a feed with nothing in it used to open an edit mode that was never drawn: the empty
  # card returned before the bar, so every keystroke — `s`, `l`, the destructive clear — was
  # swallowed as filter text with nothing on screen to say so.
  it "draws the filter bar it is typing into, even on an empty feed" do
    tmp_store do |store, project|
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_feed_empty?.should be_true
      rect = Rect.new(0, 0, 100, 30)

      # The moment `/` opens the bar and BEFORE anything is typed. Typing a character would
      # trip `activity_filtered?` and light the bar for the wrong reason, hiding the real
      # window: the first keystroke going into a field that is nowhere on screen.
      view.activity_filter_start
      view.activity_filter_field.value.should eq("")
      view.activity_filtered?.should be_false
      # `filter ›` — the bar's EDITING prefix, and the only string unique to it. A bare
      # "filter" also matches the onboarding card's own `s filter by source` bullet, which is
      # drawn in exactly the broken state and would pass this spec while the bar was missing.
      screen_rows(view, rect).join("\n").should contain("filter ›")

      view.activity_filter_field.set("abc")
      screen_rows(view, rect).join("\n").should contain("abc")
    end
  end

  # A chip set over an empty feed must SAY so. The card alone reads as "nothing has happened",
  # which is a different claim from "nothing matches what you asked for".
  it "keeps the bar when a chip narrows an empty feed, and the geometry agrees" do
    tmp_store do |store, project|
      view = activity_view(store, project)
      view.activity_cycle_source # → agent
      view.reload_activity(store)
      rect = Rect.new(0, 0, 100, 30)

      view.activity_feed_empty?.should be_true
      view.activity_filtered?.should be_true
      rows = screen_rows(view, rect)
      # The bar rides the FIRST interior row — the row `act_list_inner` reserves for it. Located
      # from the card's own border rather than from a hardcoded offset, so the assertion cannot
      # drift with the OVERVIEW band above it. If the draw skipped the bar while the geometry
      # reserved it, the two would be one row apart.
      card = rows.index(&.includes?("─ ACTIVITY ")).not_nil!
      rows[card + 1].should contain("/ filter")
      rows.join("\n").should contain("What agents and background jobs did")
    end
  end

  # The number in "in the newest N events" has to count every window walked, not just the
  # first: an operator following the hint down is told less was read than actually was.
  it "counts every window it walked, not only the first" do
    tmp_store(events_retention: 40) do |store, project|
      200.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush
      view = activity_view(store, project)
      cycle_source_to(view, "bindings") # matching nothing
      view.reload_activity(store)

      first = screen_rows(view, Rect.new(0, 0, 100, 30)).join("\n")
      first.should contain("in the newest 39 events")

      view.activity_load_more(store)
      view.activity_load_more(store)
      after = screen_rows(view, Rect.new(0, 0, 100, 30)).join("\n")
      after.should_not contain("in the newest 39 events")
      after.should contain("in the newest 117 events")
    end
  end

  describe ".activity_target" do
    it "honours the tab the producer declared, session and all" do
      t = ProjectView.activity_target(ev(goto_tab: "fuzzer", goto_session_id: 7_i64)).not_nil!
      t.tab.should eq(:fuzzer)
      t.session_id.should eq(7_i64)
      t.flow_id.should be_nil
    end

    # A row carrying both chose its tab deliberately (Probe's H3 notice does exactly this), so
    # the pane must not second-guess it into the flow.
    it "prefers the declared tab over a flow the same row carries" do
      ProjectView.activity_target(ev(goto_tab: "probe", flow_id: 9_i64)).not_nil!.tab.should eq(:probe)
    end

    it "falls back to the flow for a row that names no tab" do
      t = ProjectView.activity_target(ev(flow_id: 9_i64)).not_nil!
      t.tab.should be_nil
      t.flow_id.should eq(9_i64)
    end

    # An unknown string must not become a Symbol `switch_tab` would then fail to find — the
    # feed is written by other processes and outlives any one build's tab catalog.
    it "refuses a goto_tab this build has no tab for" do
      ProjectView.activity_target(ev(goto_tab: "atlantis")).should be_nil
      ProjectView.activity_target(ev(goto_tab: "")).should be_nil
      ProjectView.activity_target(ev).should be_nil
    end

    it "still reaches the flow when the tab name is unknown" do
      ProjectView.activity_target(ev(goto_tab: "atlantis", flow_id: 4_i64)).not_nil!.flow_id.should eq(4_i64)
    end
  end
end

# The external-change poll (`Runner#apply_external_change` → `ProjectController#refresh_activity`).
# It fires on every commit, and on a project nobody is touching it STILL fires every 3 s — the
# capture-lock holder rewrites the intercept-bridge heartbeat on that cadence, which moves
# `PRAGMA data_version`. So everything this refresh does, it does to an operator who is reading.
describe "ProjectView ACTIVITY refresh (the data_version poll)" do
  # The walked scan is the state this poll used to destroy. `↓` on an empty narrowing walks the
  # cursor back one scan window per press; a reload restarts at page one, and at one reload per
  # 3 s the walk could never outrun the heartbeat. The pane then insisted, permanently, that it
  # had looked no further than the newest window — the exact claim `activity_no_match_line`
  # exists to keep honest.
  it "does not rewind a walked-back scan" do
    tmp_store(events_retention: 40) do |store, project|
      200.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush
      view = activity_view(store, project)
      cycle_source_to(view, "bindings") # nothing wrote one
      view.reload_activity(store)
      rect = Rect.new(0, 0, 100, 30)

      view.activity_load_more(store)
      view.activity_load_more(store)
      walked = screen_rows(view, rect).find(&.includes?("no events match"))
      walked.should_not be_nil
      walked.not_nil!.should contain("in the newest 117 events")

      view.refresh_activity(store)
      screen_rows(view, rect).find(&.includes?("no events match")).should eq(walked)
    end
  end

  # Not rewinding must not become not looking: an event that matches the narrowing can still
  # arrive, and `id` being AUTOINCREMENT is what makes the head the only place it can land.
  it "still picks up a new match at the head of a walked, empty list" do
    tmp_store(events_retention: 40) do |store, project|
      200.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush
      view = activity_view(store, project)
      cycle_source_to(view, "bindings")
      view.reload_activity(store)
      view.activity_load_more(store)
      view.activity_rows.should be_empty

      store.insert_event("bindings", "extract_miss", "warn", "$sid found nothing")
      store.flush
      view.refresh_activity(store)

      view.activity_rows.map(&.message).should eq(["$sid found nothing"])
      view.activity_more?.should be_true # and the walk is still below, not restarted
    end
  end

  # The other half of "never move the cursor backwards": a list that is empty because the FEED
  # was empty has no walk to protect, and must adopt page one's resume point or it can never
  # page past the first screenful it ever receives.
  it "adopts a resume point for a feed that was empty when the pane opened" do
    tmp_store(events_retention: 40) do |store, project|
      view = activity_view(store, project)
      view.activity_feed_empty?.should be_true

      500.times { |i| store.insert_event("agent", "agent_action", "info", "event #{i}") }
      store.flush
      view.refresh_activity(store)

      view.activity_feed_empty?.should be_false
      view.activity_more?.should be_true
      before = view.activity_rows.size
      view.activity_load_more(store)
      view.activity_rows.size.should be > before
    end
  end

  # A cursor sitting on the head is an operator watching the newest row. Following it is not the
  # neighbour-slide the id anchor exists to prevent — that one happens to a cursor parked on a
  # particular event further down. Without this the pane silently stopped being a feed.
  it "follows the head when the cursor is on it" do
    tmp_store do |store, project|
      10.times { |i| store.insert_event("agent", "agent_action", "info", "old #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_selected_row.not_nil!.message.should eq("old 9")

      5.times { |i| store.insert_event("agent", "agent_action", "info", "new #{i}") }
      store.flush
      view.refresh_activity(store)

      view.activity_selected_row.not_nil!.message.should eq("new 4")
      view.activity_rows.size.should eq(15)
    end
  end

  # And a cursor parked mid-list keeps its EVENT — but is TOLD, because a list that is quietly
  # no longer at the top of its own feed reads as a feed that has gone quiet.
  it "keeps a parked cursor's event and counts what arrived above it" do
    tmp_store do |store, project|
      10.times { |i| store.insert_event("agent", "agent_action", "info", "old #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_select(3)
      parked = view.activity_selected_row.not_nil!.message

      5.times { |i| store.insert_event("agent", "agent_action", "info", "new #{i}") }
      store.flush
      view.refresh_activity(store)

      view.activity_selected_row.not_nil!.message.should eq(parked)
      rect = Rect.new(0, 0, 120, 30)
      screen_rows(view, rect).join("\n").should contain("↑5 new")
      # Climbing through them empties the note out: what ARRIVED stops being what is unseen the
      # moment the cursor is standing on some of it.
      # Down to row 3: two of the five are now BELOW the cursor, so three are left above it.
      view.activity_select(-5)
      screen_rows(view, rect).join("\n").should contain("↑3 new")
      # Coming back to the head is what makes them seen, so the note goes.
      view.activity_select(-99)
      # By the arrow, not the word: the rows themselves are called "new N".
      screen_rows(view, rect).join("\n").should_not contain("↑")
    end
  end

  # An attached agent writes events faster than the poll runs. Treating "more than one page
  # arrived" as "the list was truncated" reloaded page one, which threw away every page the
  # operator had paged in and dropped the cursor, via `clamp_act_sel`, on a row nobody chose —
  # during exactly the burst this pane exists to show.
  it "catches up over a burst larger than one page without discarding the loaded pages" do
    tmp_store do |store, project|
      1_000.times { |i| store.insert_event("agent", "agent_action", "info", "old #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)
      3.times { view.activity_load_more(store) }
      deep = view.activity_rows.size
      view.activity_select(500)
      parked = view.activity_selected_row.not_nil!.message

      500.times { |i| store.insert_event("agent", "agent_action", "info", "burst #{i}") }
      store.flush
      view.refresh_activity(store)

      view.activity_rows.size.should eq(deep + 500)
      view.activity_selected_row.not_nil!.message.should eq(parked)
    end
  end

  # Bounded, though: chasing an agent mid-fuzz down an unbounded number of pages on the render
  # fiber is a worse trade than the reload, so past the cap the honest restart comes back.
  it "gives up and reloads once the burst outruns the catch-up bound" do
    tmp_store do |store, project|
      500.times { |i| store.insert_event("agent", "agent_action", "info", "old #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_load_more(store)

      flood = ProjectView::ACT_PAGE * ProjectView::ACT_CATCHUP_PAGES + 1
      flood.times { |i| store.insert_event("agent", "agent_action", "info", "flood #{i}") }
      store.flush
      view.refresh_activity(store)

      view.activity_rows.size.should eq(ProjectView::ACT_PAGE)
      view.activity_rows.first.message.should eq("flood #{flood - 1}")
    end
  end

  # The catch-up above is what makes this necessary. `prepend_activity` runs on every poll for
  # as long as the pane is open — and the capture-lock holder moves `data_version` every 3 s on
  # an idle project — so the loaded list only ever GREW: a session left on this card while an
  # agent worked retained every event that agent had ever written, and copied the whole array
  # on the render fiber each time. Nothing is lost by capping it: the resume point moves up to
  # the last row kept, so the trimmed tail pages straight back in.
  it "caps the rows it keeps at the head, and pages the trimmed tail back in" do
    tmp_store do |store, project|
      200.times { |i| store.insert_event("agent", "agent_action", "info", "old #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)

      total = 200
      # Bursts inside ACT_CATCHUP_PAGES, so every round folds in rather than reloading.
      8.times do |t|
        800.times { |i| store.insert_event("agent", "agent_action", "info", "burst #{t}-#{i}") }
        total += 800
        store.flush
        view.refresh_activity(store)
      end
      total.should be > ProjectView::ACT_MAX_ROWS
      view.activity_rows.size.should eq(ProjectView::ACT_MAX_ROWS)
      # Newest-first still: the cap cut the TAIL, not the head the operator is watching.
      view.activity_rows.first.message.should eq("burst 7-799")

      # And the tail is only unloaded, not skipped: walking back down returns every event
      # exactly once, in order.
      while view.activity_more?
        view.activity_select(view.activity_rows.size) # park at the end so nothing trims
        view.activity_load_more(store)
      end
      ids = view.activity_rows.map(&.id)
      ids.size.should eq(total)
      ids.uniq.size.should eq(total)
      ids.should eq(ids.sort.reverse)
    end
  end

  # The cut is below the CURSOR, never at it. Trimming the row an operator parked on would do
  # to the selection exactly what a reload does — hand `↵` a different event — which is the one
  # thing the id anchor exists to prevent.
  it "never trims the row the cursor is parked on" do
    tmp_store do |store, project|
      200.times { |i| store.insert_event("agent", "agent_action", "info", "old #{i}") }
      store.flush
      view = activity_view(store, project)
      view.reload_activity(store)
      view.activity_select(3)
      parked = view.activity_selected_row.not_nil!

      8.times do |t|
        800.times { |i| store.insert_event("agent", "agent_action", "info", "burst #{t}-#{i}") }
        store.flush
        view.refresh_activity(store)
      end

      view.activity_selected_row.not_nil!.id.should eq(parked.id)
      # Everything above it is still there — that growth is the operator's own parking, and
      # cutting into it is what would move the cursor.
      view.activity_rows.size.should be > ProjectView::ACT_MAX_ROWS
    end
  end
end
