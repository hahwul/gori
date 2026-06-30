require "../spec_helper"

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
end
