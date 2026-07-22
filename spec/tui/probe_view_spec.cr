require "../spec_helper"
require "../support/memory_backend"

private def view_store(&)
  path = File.tempname("gori-probeview", ".db")
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

private def seed(store, code, host)
  store.upsert_probe_issue(
    Gori::Probe::Detection.new(code, "headers", host, "https://#{host}/", "t", Gori::Store::Severity::Low))
end

describe Gori::Tui::ProbeView do
  it "defaults to an open-only lens: dismissing empties the visible list but keeps the rows" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_csp", "a.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      view.empty?.should be_false
      view.target_issue.should_not be_nil

      view.toggle_dismiss(store)      # mute the current target
      view.toggle_dismiss(store)      # selection clamps to the remaining open one → mute it too
      view.target_issue.should be_nil # nothing left in the open-only lens
      view.empty?.should be_false     # ...but @all still holds the two dismissed rows

      view.toggle_show_closed.should be_true # reveal triaged rows
      view.target_issue.should_not be_nil
    end
  end

  it "toggles a single issue open ⇄ false-positive" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      view.target_issue.not_nil!.status.open?.should be_true

      view.toggle_dismiss(store).try(&.false_positive?).should be_true
      view.target_issue.should be_nil # dropped from the open-only lens

      view.toggle_show_closed                                # reveal it
      view.toggle_dismiss(store).try(&.open?).should be_true # un-dismiss
    end
  end

  it "renders the '‹ list' back marker on the detail's top frame border (framed path)" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      view.open_detail(store).should be_true

      backend = MemoryBackend.new(80, 16)
      screen = Gori::Tui::Screen.new(backend)
      Gori::Tui::BodyChrome.framed(screen, Gori::Tui::Rect.new(0, 0, 80, 16), true) do |inner|
        view.render(screen, inner)
      end
      backend.row(0).includes?("‹ list").should be_true
    end
  end

  it "honours an explicit status: filter even with the open-only lens (bypasses the default)" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      view.toggle_dismiss(store) # now false-positive, hidden by default
      view.target_issue.should be_nil

      "status:fp".each_char { |c| view.query_insert(c) }
      view.target_issue.should_not be_nil # the explicit status term reveals it
    end
  end

  it "filters the issue list to in-scope hosts once the scope lens is ON" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test")
      scope.active?.should be_false # configured but not enabled yet

      view = Gori::Tui::ProbeView.new
      view.set_scope(scope)
      view.reload(store)
      view.empty?.should be_false

      # Lens off ⇒ both hosts show up.
      b0 = MemoryBackend.new(80, 20)
      view.render(Gori::Tui::Screen.new(b0), Gori::Tui::Rect.new(0, 0, 80, 20))
      b0.contains?("a.test").should be_true
      b0.contains?("b.test").should be_true

      scope.enable
      view.reload(store)
      b1 = MemoryBackend.new(80, 20)
      view.render(Gori::Tui::Screen.new(b1), Gori::Tui::Rect.new(0, 0, 80, 20))
      b1.contains?("a.test").should be_true
      b1.contains?("b.test").should be_false
    end
  end

  it "shows the scope-lens empty hint (not the triage hint) when the lens empties the list" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test") # excludes a.test → in-scope set empty
      scope.enable

      view = Gori::Tui::ProbeView.new
      view.set_scope(scope)
      view.reload(store)

      b = MemoryBackend.new(80, 20)
      view.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 80, 20))
      rows = (0...20).map { |y| b.row(y) }.join("\n")
      rows.should contain("no issues in scope")
      rows.should contain("⇧S clears the scope lens")
    end
  end

  it "drops the MODE band tech chip for a fingerprint seen only on an out-of-scope host" do
    view_store do |store|
      store.upsert_probe_issue(
        Gori::Probe::Detection.new("tech_grpc", "tech", "a.test", "https://a.test/", "gRPC detected", Gori::Store::Severity::Info))

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      scope.enable

      view = Gori::Tui::ProbeView.new
      view.set_scope(scope)
      view.reload(store)

      b = MemoryBackend.new(80, 20)
      view.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 80, 20))
      b.contains?("gRPC").should be_false
    end
  end

  it "re-anchors selection by issue id across reload (not by list index)" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_csp", "b.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      first = view.target_issue.not_nil!.id
      view.move(1)
      second = view.target_issue.not_nil!
      second.id.should_not eq(first)

      # A new higher-severity (or newer) issue can reshuffle indices; id stays put.
      seed(store, "cookie_secure", "c.test")
      view.reload(store)
      view.target_issue.not_nil!.id.should eq(second.id)
    end
  end

  it "bulk-dismiss-by-code respects the scope lens (mutes only in-scope hosts)" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test") # in scope
      seed(store, "missing_hsts", "b.test") # out of scope
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test")
      scope.enable
      view = Gori::Tui::ProbeView.new
      view.set_scope(scope)
      view.reload(store)
      view.dismiss_by_code(store).should eq(1)                                        # only the in-scope host counted…
      store.probe_issues.find! { |i| i.host == "b.test" }.status.open?.should be_true # …and muted
      store.probe_issues.find! { |i| i.host == "a.test" }.status.false_positive?.should be_true
    end
  end

  it "bulk-dismiss-by-code mutes every host when the scope lens is off" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_hsts", "b.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      view.dismiss_by_code(store).should eq(2)
      store.probe_issues.select(&.code.== "missing_hsts").all?(&.status.false_positive?).should be_true
    end
  end

  it "delete_by_id removes the chosen issue even after the selection has moved" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_csp", "a.test")
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      chosen = view.target_issue.not_nil!
      view.move(1) # selection now points at the OTHER issue
      view.target_issue.not_nil!.id.should_not eq(chosen.id)
      view.delete_by_id(store, chosen.id) # deletes the captured id, not the current selection
      store.probe_issues.map(&.id).should_not contain(chosen.id)
      store.probe_issues.size.should eq(1)
    end
  end

  it "keeps the MODE chip visible on a narrow band when all severities are present" do
    view_store do |store|
      sevs = [Gori::Store::Severity::Info, Gori::Store::Severity::Low, Gori::Store::Severity::Medium,
              Gori::Store::Severity::High, Gori::Store::Severity::Critical]
      sevs.each_with_index do |sv, si|
        20.times do |k|
          store.upsert_probe_issue(Gori::Probe::Detection.new("c#{si}x#{k}", "headers",
            "h#{si}-#{k}.test", "https://h/", "t", sv))
        end
      end
      view = Gori::Tui::ProbeView.new
      view.reload(store)
      b = MemoryBackend.new(30, 20) # narrow: tallies would otherwise overpaint the mode chip
      view.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 30, 20))
      b.row(0).should contain("m:PASSIVE") # the mode chip text survives intact
    end
  end
end
