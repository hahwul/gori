require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-fnd", ".db")
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

# Four issues whose severity DESC / created_at DESC display order is deliberately NOT the
# insert (id) order — the difference that separates this list from History's, where ids are
# monotonic with the list.
private def marks_view(store, &)
  crit = store.insert_issue("crit", Gori::Store::Severity::Critical, "a.test", nil)
  low = store.insert_issue("low", Gori::Store::Severity::Low, "b.test", nil)
  high = store.insert_issue("high", Gori::Store::Severity::High, "a.test", nil)
  info = store.insert_issue("info", Gori::Store::Severity::Info, "b.test", nil)
  view = IssuesView.new
  view.reload(store)
  yield view, {crit, high, low, info} # display order: CRIT(0), HIGH(1), LOW(2), INFO(3)
end

describe Gori::Tui::IssuesView do
  it "renders the severity-sorted list with badges + a status tag" do
    tmp_store do |store|
      store.insert_issue("SQL injection", Gori::Store::Severity::Critical, "acme.test", nil)
      store.insert_issue("Missing header", Gori::Store::Severity::Low, "acme.test", nil)

      view = IssuesView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 10)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 10))

      backend.contains?("SEV").should be_true
      backend.contains?("CRIT").should be_true
      backend.contains?("SQL injection").should be_true
      backend.contains?("LOW").should be_true
      backend.contains?("open").should be_true # freshly created → Open status tag
      # critical sorts first; rows start at y+3 (filter bar, header, divider above)
      backend.row(3).should contain("CRIT")
    end
  end

  it "renders the '‹ list' back marker on the detail's top frame border (framed path)" do
    tmp_store do |store|
      store.insert_issue("SQL injection", Gori::Store::Severity::Critical, "acme.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 16)
      screen = Screen.new(backend)
      BodyChrome.framed(screen, Rect.new(0, 0, 80, 16), true) do |inner|
        view.render(screen, inner, focused: true)
      end
      backend.row(0).includes?("‹ list").should be_true
    end
  end

  it "renders an empty-state when there are no issues" do
    tmp_store do |store|
      view = IssuesView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("no issues yet").should be_true
      backend.contains?("ISSUES").should be_true
      backend.contains?("⇧F").should be_true
    end
  end

  it "cycles triage status independently of severity" do
    tmp_store do |store|
      id = store.insert_issue("IDOR", Gori::Store::Severity::High, "acme.test", nil)
      store.get_issue(id).not_nil!.status.should eq(Gori::Store::Status::Open)

      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.status_delta(1, store) # open -> confirmed
      f = store.get_issue(id).not_nil!
      f.status.should eq(Gori::Store::Status::Confirmed)
      f.severity.should eq(Gori::Store::Severity::High) # severity untouched

      view.status_delta(-1, store) # back to open
      store.get_issue(id).not_nil!.status.should eq(Gori::Store::Status::Open)
      # clamps at the bottom
      view.status_delta(-1, store)
      store.get_issue(id).not_nil!.status.should eq(Gori::Store::Status::Open)
    end
  end

  it "discards notes edits on cancel (^W) without persisting" do
    tmp_store do |store|
      id = store.insert_issue("XSS", Gori::Store::Severity::Medium, nil, nil)
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store)
      view.start_notes_edit
      "junk".each_char { |c| view.notes_insert(c) }
      view.cancel_notes_edit
      view.notes_insert_mode?.should be_false
      store.get_issue(id).not_nil!.notes.should eq("") # nothing persisted
    end
  end

  # Was "hscroll_notes scrolls a long notes line sideways into view (shift+←/→)". The notes
  # pane soft-wraps now, like the Repeater request pane and the History detail, so the whole
  # `hscroll_notes` chain is retired and BOTH ends of a long line are on screen at once — with
  # no chord to press to see the second one. Still under test: that a line wider than the pane
  # is fully reachable, which is what the h-scroll pair existed to provide.
  it "wraps a long notes line instead of scrolling it sideways" do
    tmp_store do |store|
      id = store.insert_issue("XSS", Gori::Store::Severity::Medium, "acme.test", nil)
      store.update_issue(id, notes: "HEAD" + ("." * 80) + "TAIL")
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.enter_notes_insert!
      view.exit_notes_insert!
      view.notes_focused?.should be_true
      view.notes_insert_mode?.should be_false

      rect = Rect.new(0, 0, 80, 24)
      backend = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend), rect, focused: true)
      backend.contains?("HEAD").should be_true
      backend.contains?("TAIL").should be_true # …on its continuation row, not off the edge
      # …and on DIFFERENT rows: this is a wrap, not a pane that grew wide enough to fit.
      head_row = (0...24).find { |y| backend.row(y).includes?("HEAD") }.not_nil!
      tail_row = (0...24).find { |y| backend.row(y).includes?("TAIL") }.not_nil!
      tail_row.should be > head_row
    end
  end

  it "moves RELATED link selection with move_links (wheel/↑/↓)" do
    tmp_store do |store|
      f1 = store.insert_issue("A", Gori::Store::Severity::Low, nil, nil)
      f2 = store.insert_issue("B", Gori::Store::Severity::Low, nil, nil)
      fid1 = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "a.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1", head: Bytes[0]))
      fid2 = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "b.test", port: 443,
        method: "GET", target: "/b", http_version: "HTTP/1.1", head: Bytes[0]))
      store.add_link(Gori::Store::LinkOwnerKind::Issue, f1, Gori::Store::LinkRefKind::Flow, fid1)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, f1, Gori::Store::LinkRefKind::Flow, fid2)

      view = IssuesView.new
      view.reload(store)
      view.select_index(1) # newest-first sort → f1 (with links) is second in the list
      view.open_detail(store).should be_true
      view.selected_resolved_link.not_nil!.label.should contain("a.test")
      view.move_links(1)
      view.selected_resolved_link.not_nil!.label.should contain("b.test")
    end
  end

  it "opens a detail, changes severity, and edits + saves notes" do
    tmp_store do |store|
      id = store.insert_issue("XSS", Gori::Store::Severity::Medium, "acme.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 14)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 14))
      backend.contains?("NOTES").should be_true
      backend.contains?("MED").should be_true

      view.severity_delta(2, store) # medium -> critical
      store.get_issue(id).not_nil!.severity.should eq(Gori::Store::Severity::Critical)

      view.start_notes_edit
      view.notes_insert_mode?.should be_true
      "poc".each_char { |c| view.notes_insert(c) }
      view.save_notes(store)
      store.get_issue(id).not_nil!.notes.should eq("poc")
    end
  end

  it "filters the list and tab-completes a field without mangling a trailing-space query" do
    tmp_store do |store|
      store.insert_issue("SQL injection", Gori::Store::Severity::Critical, "api.test", nil)
      store.insert_issue("Missing header", Gori::Store::Severity::Low, "app.test", nil)
      view = IssuesView.new
      view.reload(store)

      view.start_query
      "sev".each_char { |c| view.query_insert(c) }
      view.query_complete.should be_true
      view.query.should eq("severity:") # completed the field name

      # trailing space → no adjacent word → don't complete and don't corrupt the query
      view.query_insert(' ')
      view.query.should eq("severity: ")
      view.query_complete.should be_false
      view.query.should eq("severity: ")
    end
  end

  it "deletes an issue" do
    tmp_store do |store|
      store.insert_issue("temp", Gori::Store::Severity::Info, nil, nil)
      view = IssuesView.new
      view.reload(store)
      view.delete_ids(store, view.target_ids).should be_true
      store.count_issues.should eq(0)
    end
  end

  it "re-anchors selection by issue id across reload (not by list index)" do
    # severity DESC: Critical then Low. Selecting Low then inserting High between
    # would leave index 1 on the new High if we only clamped — id-anchor keeps Low.
    tmp_store do |store|
      store.insert_issue("crit-row", Gori::Store::Severity::Critical, "h.test", nil)
      store.insert_issue("low-row", Gori::Store::Severity::Low, "h.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.move(1)
      view.target_issue.not_nil!.title.should eq("low-row")

      store.insert_issue("high-row", Gori::Store::Severity::High, "h.test", nil)
      view.reload(store)
      view.target_issue.not_nil!.title.should eq("low-row")
    end
  end

  # --- multi-select marks ---------------------------------------------------
  it "marks the cursor row with `t` and steps down, so a run of `t` marks consecutive rows" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        crit, high, _, _ = ids
        view.toggle_mark
        view.toggle_mark
        view.mark_count.should eq(2)
        view.marked?(crit).should be_true
        view.marked?(high).should be_true
        view.selected_index.should eq(2) # stepped past both
        # A second `t` on a marked row un-marks it.
        view.select_index(0)
        view.toggle_mark
        view.marked?(crit).should be_false
        view.mark_count.should eq(1)
      end
    end
  end

  it "returns marked ids in DISPLAY order (severity sort), not id order" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        crit, high, low, info = ids
        # Mark bottom-up: INFO(3), LOW(2), HIGH(1) — ids ascending would be crit,low,high,info.
        [3, 2, 1].each { |i| view.select_index(i); view.toggle_mark }
        view.marked_ids.should eq([high, low, info])
        # target_ids is the marks when any are set…
        view.target_ids.should eq([high, low, info])
        # …and the cursor row when none are.
        view.clear_marks
        view.select_index(0)
        view.target_ids.should eq([crit])
      end
    end
  end

  it "⇧T marks what the FILTER shows, and reports the rest of the set as hidden" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        crit, high, _, _ = ids
        "severity:>=high".each_char { |c| view.query_insert(c) }
        view.mark_all
        view.mark_count.should eq(2)
        view.marked_ids.should eq([crit, high])
        view.marked_hidden_count.should eq(0)
        # Narrowing further leaves the off-filter mark in the set, counted as hidden.
        view.cancel_query
        "severity:critical".each_char { |c| view.query_insert(c) }
        view.mark_count.should eq(2)
        view.marked_hidden_count.should eq(1)
        # …and marking again ACCUMULATES rather than replacing.
        view.mark_all
        view.mark_count.should eq(2)
      end
    end
  end

  it "⇧↓/⇧↑ extend and shrink a range from the anchor, sparing a `t` mark it sweeps over" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        crit, high, low, info = ids
        # A deliberate `t` mark on LOW (row 2), then a range from the top.
        view.select_index(2)
        view.toggle_mark
        view.select_index(0)

        view.extend_marks(1) # CRIT..HIGH
        view.extend_marks(1) # CRIT..LOW
        view.extend_marks(1) # CRIT..INFO
        view.marked_ids.should eq([crit, high, low, info])

        view.extend_marks(-1) # back off INFO — the gesture gives its own id back
        view.marked_ids.should eq([crit, high, low])
        view.extend_marks(-1) # back off LOW — but LOW was marked by `t`, so it stays
        view.marked_ids.should eq([crit, high, low])
        view.extend_marks(-1)
        view.marked_ids.should eq([crit, low])
      end
    end
  end

  it "ends the range gesture on a plain move, handing back only what the gesture marked" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        _, _, low, info = ids
        view.select_index(2)
        view.toggle_mark # a `t` mark on LOW
        view.select_index(0)
        view.extend_marks(1)
        view.mark_count.should eq(3) # CRIT + HIGH from the range, LOW from `t`

        view.end_mark_gesture.should eq(2)
        view.marked_ids.should eq([low]) # the deliberate mark survives
        # The anchor went with it, so the next ⇧arrow starts from the CURSOR (INFO) rather
        # than sweeping back to where the ended gesture began.
        view.select_index(3)
        view.extend_marks(-1)
        view.marked_ids.should eq([low, info]) # LOW..INFO only — CRIT/HIGH are not swept in
        view.end_mark_gesture.should eq(1)
        view.marked_ids.should eq([low])
      end
    end
  end

  it "leaves a ⇧T set alone when a range gesture sweeps over it and back off" do
    # ⇧T marks are deliberate tags, exactly like `t` ones, so a range gesture owns only what
    # IT added — here, nothing. Without that rule, ⇧↓⇧↑ after ⇧T would silently un-mark rows
    # the user asked for, and a plain arrow afterwards would clear the whole set.
    tmp_store do |store|
      marks_view(store) do |view, ids|
        crit, high, low, info = ids
        view.mark_all
        view.extend_marks(1)
        view.extend_marks(-1)
        view.marked_ids.should eq([crit, high, low, info])
        view.end_mark_gesture.should eq(0) # nothing to hand back → the caller stays silent
        view.marked_ids.should eq([crit, high, low, info])
      end
    end
  end

  it "deletes every marked issue in one write and prunes the marks" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        _, high, _, info = ids
        [0, 2].each { |i| view.select_index(i); view.toggle_mark } # CRIT + LOW
        view.delete_ids(store, view.target_ids).should be_true
        store.issues.map(&.id).sort!.should eq([high, info].sort)
        view.mark_count.should eq(0)
      end
    end
  end

  it "closes the detail when the batch delete takes the issue it was showing" do
    tmp_store do |store|
      marks_view(store) do |view, ids|
        crit, _, _, _ = ids
        view.open_detail(store).should be_true
        view.detail_open?.should be_true
        view.delete_ids(store, [crit]).should be_true
        view.detail_open?.should be_false
      end
    end
  end

  it "paints a marked row with a fuller gutter bar and shows a live mark chip" do
    tmp_store do |store|
      marks_view(store) do |view, _|
        view.toggle_mark
        view.toggle_mark
        backend = MemoryBackend.new(80, 10)
        view.render(Screen.new(backend), Rect.new(0, 0, 80, 10))
        backend.contains?("2 marked").should be_true
        backend.row(3).starts_with?("▌").should be_true # marked row (CRIT)
        backend.row(5).starts_with?("▎").should be_true # cursor row, unmarked (LOW)
      end
    end
  end

  it "open_by_id reloads, selects, and opens detail for a known issue" do
    tmp_store do |store|
      id = store.insert_issue("target", Gori::Store::Severity::High, "acme.test", nil)
      store.insert_issue("other", Gori::Store::Severity::Low, "acme.test", nil)
      view = IssuesView.new
      view.open_by_id(store, id).should be_true
      view.detail_open?.should be_true
      view.detail_issue.try(&.id).should eq(id)
    end
  end
end

describe "Issues verbs" do
  it "registers issue.create and the issues detail/export verbs in the registry" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("f", shift: true), Gori::Verb::Scope::Body).should eq("issue.create")
    keymap.lookup(Gori::Verb::Chord.new("enter"), Gori::Verb::Scope::Issues).should eq("issues.open")
    keymap.lookup(Gori::Verb::Chord.new("]"), Gori::Verb::Scope::IssuesDetail).should eq("issue.severity-up")
    keymap.lookup(Gori::Verb::Chord.new("}"), Gori::Verb::Scope::IssuesDetail).should eq("issue.status-up")
    keymap.lookup(Gori::Verb::Chord.new("t"), Gori::Verb::Scope::IssuesDetail).should eq("issue.edit-title")
    keymap.lookup(Gori::Verb::Chord.new("o"), Gori::Verb::Scope::IssuesDetail).should eq("issue.open-flow")
    keymap.lookup(Gori::Verb::Chord.new("r"), Gori::Verb::Scope::IssuesDetail).should eq("issue.repeater-flow")
    # export is a chord-less Global palette verb
    reg["issues.export-md"]?.try(&.scope).should eq(Gori::Verb::Scope::Global)
    reg["issues.export-json"]?.should_not be_nil
  end
end
