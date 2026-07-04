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

describe Gori::Tui::FindingsView do
  it "renders the severity-sorted list with badges + a status tag" do
    tmp_store do |store|
      store.insert_finding("SQL injection", Gori::Store::Severity::Critical, "acme.test", nil)
      store.insert_finding("Missing header", Gori::Store::Severity::Low, "acme.test", nil)

      view = FindingsView.new
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

  it "renders an empty-state when there are no findings" do
    tmp_store do |store|
      view = FindingsView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 12)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 12))
      backend.contains?("no findings yet").should be_true
      backend.contains?("FINDINGS").should be_true
      backend.contains?("⇧F").should be_true
    end
  end

  it "cycles triage status independently of severity" do
    tmp_store do |store|
      id = store.insert_finding("IDOR", Gori::Store::Severity::High, "acme.test", nil)
      store.get_finding(id).not_nil!.status.should eq(Gori::Store::Status::Open)

      view = FindingsView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.status_delta(1, store) # open -> confirmed
      f = store.get_finding(id).not_nil!
      f.status.should eq(Gori::Store::Status::Confirmed)
      f.severity.should eq(Gori::Store::Severity::High) # severity untouched

      view.status_delta(-1, store) # back to open
      store.get_finding(id).not_nil!.status.should eq(Gori::Store::Status::Open)
      # clamps at the bottom
      view.status_delta(-1, store)
      store.get_finding(id).not_nil!.status.should eq(Gori::Store::Status::Open)
    end
  end

  it "discards notes edits on cancel (^W) without persisting" do
    tmp_store do |store|
      id = store.insert_finding("XSS", Gori::Store::Severity::Medium, nil, nil)
      view = FindingsView.new
      view.reload(store)
      view.open_detail(store)
      view.start_notes_edit
      "junk".each_char { |c| view.notes_insert(c) }
      view.cancel_notes_edit
      view.editing_notes?.should be_false
      store.get_finding(id).not_nil!.notes.should eq("") # nothing persisted
    end
  end

  it "hscroll_notes scrolls a long notes line sideways into view (shift+←/→)" do
    tmp_store do |store|
      id = store.insert_finding("XSS", Gori::Store::Severity::Medium, "acme.test", nil)
      store.update_finding(id, notes: "HEAD" + ("." * 80) + "TAIL")
      view = FindingsView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.editing_notes?.should be_false # read-only preview — hscroll_notes applies here

      rect = Rect.new(0, 0, 80, 24)
      backend = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend), rect, focused: true)
      backend.contains?("HEAD").should be_true
      backend.contains?("TAIL").should be_false # off the right edge, clipped

      20.times { view.hscroll_notes(1) } # scroll well past the line's width
      backend2 = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend2), rect, focused: true)
      backend2.contains?("TAIL").should be_true
      backend2.contains?("HEAD").should be_false # scrolled off the left edge
    end
  end

  it "moves RELATED link selection with move_links (wheel/↑/↓)" do
    tmp_store do |store|
      f1 = store.insert_finding("A", Gori::Store::Severity::Low, nil, nil)
      f2 = store.insert_finding("B", Gori::Store::Severity::Low, nil, nil)
      fid1 = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "a.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1", head: Bytes[0]))
      fid2 = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "b.test", port: 443,
        method: "GET", target: "/b", http_version: "HTTP/1.1", head: Bytes[0]))
      store.add_link(Gori::Store::LinkOwnerKind::Finding, f1, Gori::Store::LinkRefKind::Flow, fid1)
      store.add_link(Gori::Store::LinkOwnerKind::Finding, f1, Gori::Store::LinkRefKind::Flow, fid2)

      view = FindingsView.new
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
      id = store.insert_finding("XSS", Gori::Store::Severity::Medium, "acme.test", nil)
      view = FindingsView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 14)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 14))
      backend.contains?("NOTES").should be_true
      backend.contains?("MED").should be_true

      view.severity_delta(2, store) # medium -> critical
      store.get_finding(id).not_nil!.severity.should eq(Gori::Store::Severity::Critical)

      view.start_notes_edit
      view.editing_notes?.should be_true
      "poc".each_char { |c| view.notes_insert(c) }
      view.save_notes(store)
      store.get_finding(id).not_nil!.notes.should eq("poc")
    end
  end

  it "filters the list and tab-completes a field without mangling a trailing-space query" do
    tmp_store do |store|
      store.insert_finding("SQL injection", Gori::Store::Severity::Critical, "api.test", nil)
      store.insert_finding("Missing header", Gori::Store::Severity::Low, "app.test", nil)
      view = FindingsView.new
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

  it "deletes a finding" do
    tmp_store do |store|
      store.insert_finding("temp", Gori::Store::Severity::Info, nil, nil)
      view = FindingsView.new
      view.reload(store)
      view.delete(store)
      store.count_findings.should eq(0)
    end
  end
end

describe "FindingForm" do
  it "cycles severity (tab) and carries an edit id for re-titling" do
    form = FindingForm.new("GET /x", "acme.test", 7_i64)
    form.severity.should eq(Gori::Store::Severity::Medium) # default
    form.severity_cycle(1)
    form.severity.should eq(Gori::Store::Severity::High)
    form.severity_cycle(-2)
    form.severity.should eq(Gori::Store::Severity::Low)
    form.edit_id.should be_nil

    edit = FindingForm.new("old", nil, nil, Gori::Store::Severity::Critical, edit_id: 42_i64)
    edit.edit_id.should eq(42_i64)
    edit.severity.should eq(Gori::Store::Severity::Critical)
  end
end

describe "Findings verbs" do
  it "registers finding.create and the findings detail/export verbs in the registry" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("f", shift: true), Gori::Verb::Scope::Body).should eq("finding.create")
    keymap.lookup(Gori::Verb::Chord.new("enter"), Gori::Verb::Scope::Findings).should eq("findings.open")
    keymap.lookup(Gori::Verb::Chord.new("]"), Gori::Verb::Scope::FindingsDetail).should eq("finding.severity-up")
    keymap.lookup(Gori::Verb::Chord.new("}"), Gori::Verb::Scope::FindingsDetail).should eq("finding.status-up")
    keymap.lookup(Gori::Verb::Chord.new("t"), Gori::Verb::Scope::FindingsDetail).should eq("finding.edit-title")
    keymap.lookup(Gori::Verb::Chord.new("o"), Gori::Verb::Scope::FindingsDetail).should eq("finding.open-flow")
    keymap.lookup(Gori::Verb::Chord.new("r"), Gori::Verb::Scope::FindingsDetail).should eq("finding.replay-flow")
    # export is a chord-less Global palette verb
    reg["findings.export-md"]?.try(&.scope).should eq(Gori::Verb::Scope::Global)
    reg["findings.export-json"]?.should_not be_nil
  end
end
