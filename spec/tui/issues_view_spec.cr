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
      view.editing_notes?.should be_false
      store.get_issue(id).not_nil!.notes.should eq("") # nothing persisted
    end
  end

  it "hscroll_notes scrolls a long notes line sideways into view (shift+←/→)" do
    tmp_store do |store|
      id = store.insert_issue("XSS", Gori::Store::Severity::Medium, "acme.test", nil)
      store.update_issue(id, notes: "HEAD" + ("." * 80) + "TAIL")
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.enter_notes_insert!
      view.exit_notes_insert!
      view.notes_focused?.should be_true
      view.editing_notes?.should be_false

      rect = Rect.new(0, 0, 80, 24)
      backend = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend), rect, focused: true)
      backend.contains?("HEAD").should be_true
      backend.contains?("TAIL").should be_false

      30.times { view.hscroll_notes(1) }
      backend2 = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend2), rect, focused: true)
      backend2.contains?("TAIL").should be_true
      backend2.contains?("HEAD").should be_false
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
      view.editing_notes?.should be_true
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
      view.delete(store)
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
end

describe "IssueForm" do
  it "cycles severity (tab) and carries an edit id for re-titling" do
    form = IssueForm.new("GET /x", "acme.test", 7_i64)
    form.severity.should eq(Gori::Store::Severity::Medium) # default
    form.severity_cycle(1)
    form.severity.should eq(Gori::Store::Severity::High)
    form.severity_cycle(-2)
    form.severity.should eq(Gori::Store::Severity::Low)
    form.edit_id.should be_nil

    edit = IssueForm.new("old", nil, nil, Gori::Store::Severity::Critical, edit_id: 42_i64)
    edit.edit_id.should eq(42_i64)
    edit.severity.should eq(Gori::Store::Severity::Critical)
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
