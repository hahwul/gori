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
  it "renders the severity-sorted list with badges" do
    tmp_store do |store|
      store.insert_finding("SQL injection", Gori::Store::Severity::Critical, "acme.test", nil)
      store.insert_finding("Missing header", Gori::Store::Severity::Low, "acme.test", nil)

      view = FindingsView.new
      view.reload(store)
      backend = MemoryBackend.new(80, 10)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 10))

      backend.contains?("SEVERITY").should be_true
      backend.contains?("CRIT").should be_true
      backend.contains?("SQL injection").should be_true
      backend.contains?("LOW").should be_true
      # critical sorts first
      backend.row(2).should contain("CRIT")
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

describe "Findings verbs (P1)" do
  it "registers finding.create and findings verbs in the registry" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("f", shift: true), Gori::Verb::Scope::Body).should eq("finding.create")
    keymap.lookup(Gori::Verb::Chord.new("enter"), Gori::Verb::Scope::Findings).should eq("findings.open")
    keymap.lookup(Gori::Verb::Chord.new("]"), Gori::Verb::Scope::FindingsDetail).should eq("finding.severity-up")
  end
end
