require "../spec_helper"
require "../support/memory_backend"

# End-to-end simulation of the Runner's probe_generation poll + ProbeView paint path.
# This is the path that must show a new reflected_param row WITHOUT leaving the tab.
describe "Probe live list refresh (generation poll)" do
  it "shows a newly upserted issue on the next poll+render without on_enter" do
    path = File.tempname("gori-probe-live", ".db")
    store = Gori::Store.open(path)
    begin
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "xss.test")

      view = Gori::Tui::ProbeView.new
      view.set_scope(scope)
      view.reload(store)
      view.@issues.size.should eq(0)

      last_gen = store.probe_generation
      active_tab = :probe # user is watching Probe

      # Scanner writes an issue (same path as Analyzer#run_active)
      d = Gori::Probe::Detection.new(
        "reflected_param", Gori::Probe::Category::ACTIVE, "xss.test",
        "https://xss.test/level1/frame?query=12",
        "Reflected parameter", Gori::Store::Severity::Medium, "query (query)", 1_i64)
      store.upsert_probe_issue(d)
      store.probe_generation.should eq(last_gen + 1)

      # --- Runner poll (exact shape) ---
      dirty = false
      resized = false
      if (pgen = store.probe_generation) != last_gen
        last_gen = pgen
        view.reload(store) # refresh_from_store
        if active_tab == :probe
          dirty = true
          resized = true
        end
      end

      dirty.should be_true
      resized.should be_true
      view.@issues.any?(&.code.==("reflected_param")).should be_true

      # --- paint: list must contain the title ---
      backend = MemoryBackend.new(100, 30)
      screen = Gori::Tui::Screen.new(backend)
      rect = Gori::Tui::Rect.new(0, 0, 100, 30)
      view.render(screen, rect, focused: true, listen: "127.0.0.1:8080", capturing: true)
      backend.contains?("Reflected parameter").should be_true
      backend.contains?("xss.test").should be_true
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "hides a deleted issue on the next poll+render" do
    path = File.tempname("gori-probe-del", ".db")
    store = Gori::Store.open(path)
    begin
      view = Gori::Tui::ProbeView.new
      d = Gori::Probe::Detection.new(
        "reflected_param", Gori::Probe::Category::ACTIVE, "xss.test",
        "https://xss.test/", "Reflected parameter", Gori::Store::Severity::Medium, "q", 1_i64)
      store.upsert_probe_issue(d)
      view.reload(store)
      view.@issues.size.should eq(1)

      last_gen = store.probe_generation
      id = store.probe_issues.first.id
      store.delete_probe_issue(id)

      if (pgen = store.probe_generation) != last_gen
        view.reload(store)
      end
      view.@issues.size.should eq(0)

      backend = MemoryBackend.new(100, 24)
      view.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 100, 24), focused: true)
      backend.contains?("Reflected parameter").should be_false
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "keeps a hard-deleted issue gone after simulated project re-open + re-upsert" do
    path = File.tempname("gori-probe-dur", ".db")
    store = Gori::Store.open(path)
    begin
      d = Gori::Probe::Detection.new(
        "reflected_param", Gori::Probe::Category::ACTIVE, "xss.test",
        "https://xss.test/level1/frame?query=1",
        "Reflected parameter", Gori::Store::Severity::Medium, "query (query)", 1_i64)
      store.upsert_probe_issue(d)
      store.delete_probe_issue(store.probe_issues.first.id)

      # New process / Session would re-run Active backfill → upsert again
      store.upsert_probe_issue(d)
      store.probe_issues.any?(&.code.==("reflected_param")).should be_false

      view = Gori::Tui::ProbeView.new
      view.reload(store)
      view.@issues.any?(&.code.==("reflected_param")).should be_false
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
