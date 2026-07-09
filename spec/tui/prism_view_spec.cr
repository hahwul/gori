require "../spec_helper"
require "../support/memory_backend"

private def view_store(&)
  path = File.tempname("gori-prismview", ".db")
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
  store.upsert_prism_issue(
    Gori::Prism::Detection.new(code, "headers", host, "https://#{host}/", "t", Gori::Store::Severity::Low))
end

describe Gori::Tui::PrismView do
  it "defaults to an open-only lens: dismissing empties the visible list but keeps the rows" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      seed(store, "missing_csp", "a.test")
      view = Gori::Tui::PrismView.new
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
      view = Gori::Tui::PrismView.new
      view.reload(store)
      view.target_issue.not_nil!.status.open?.should be_true

      view.toggle_dismiss(store).try(&.false_positive?).should be_true
      view.target_issue.should be_nil # dropped from the open-only lens

      view.toggle_show_closed                                # reveal it
      view.toggle_dismiss(store).try(&.open?).should be_true # un-dismiss
    end
  end

  it "honours an explicit status: filter even with the open-only lens (bypasses the default)" do
    view_store do |store|
      seed(store, "missing_hsts", "a.test")
      view = Gori::Tui::PrismView.new
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

      view = Gori::Tui::PrismView.new
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

      view = Gori::Tui::PrismView.new
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
      store.upsert_prism_issue(
        Gori::Prism::Detection.new("tech_grpc", "tech", "a.test", "https://a.test/", "gRPC detected", Gori::Store::Severity::Info))

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      scope.enable

      view = Gori::Tui::PrismView.new
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
      view = Gori::Tui::PrismView.new
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
end
