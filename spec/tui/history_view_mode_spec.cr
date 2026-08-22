require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The History VIEW mode (#776): a named QL query the list ANDs over the filter bar, the way the
# ⇧S scope lens does. What is pinned here is the behaviour that has no visible symptom until it
# has already shown the operator the wrong flows.

private def tmp_store(&)
  path = File.tempname("gori-hv-view", ".db")
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

private def add_flow(store, source : Gori::FlowSource::Kind, host = "h.test", status = 200)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: source))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  id
end

private def history_view : Gori::SavedViews::View
  Gori::SavedViews::BUILTINS.find { |v| v.name == "History" }.not_nil!
end

private def screen_rows(view : HistoryView, w = 110, h = 14) : Array(String)
  backend = MemoryBackend.new(w, h)
  view.render_list(Screen.new(backend), Rect.new(0, 0, w, h))
  (0...h).map { |y| backend.row(y) }
end

private def screen_text(view : HistoryView, w = 110, h = 14) : String
  screen_rows(view, w, h).join("\n")
end

describe "HistoryView — view mode" do
  it "ANDs the view over the filter bar instead of replacing it" do
    tmp_store do |store|
      add_flow(store, Gori::FlowSource::Kind::Proxy, "keep.test", 500)
      add_flow(store, Gori::FlowSource::Kind::Proxy, "keep.test", 200)
      add_flow(store, Gori::FlowSource::Kind::Repeater, "resent.test", 500)

      view = HistoryView.new
      view.set_view(history_view)
      view.set_query("status:500")
      view.reload(store)

      # Both terms held: the view did not survive as the only filter, and the bar did not
      # discard the view. That is the whole point of a lens.
      view.rows.map(&.host).should eq(["keep.test"])
      view.rows.map(&.status).should eq([500])
      view.query.should eq("status:500") # the view never writes to the bar
    end
  end

  it "counts as filtering, so a live capture cannot bypass the view into the list" do
    # THE hazard. `on_event` pushes a newly captured flow straight onto @rows when the list is
    # not filtered — and an unfiltered list may never reload at all. If `filtering?` did not
    # know about views, a `src:proxy` view would fill, permanently, with the repeater sends it
    # exists to exclude, under a chip claiming otherwise.
    tmp_store do |store|
      view = HistoryView.new
      view.set_view(history_view)
      view.filtering?.should be_true

      id = add_flow(store, Gori::FlowSource::Kind::Repeater, "resent.test")
      view.on_event(Gori::Store::FlowEvent.new(id, :inserted), store)
      view.rows.should be_empty # coalesced into a reload, not unshifted

      view.reload(store)
      view.rows.should be_empty # and the reload agrees: the view excludes it
    end
  end

  it "is not filtering under the All view, so the incremental path still applies" do
    tmp_store do |store|
      view = HistoryView.new
      view.set_view(Gori::SavedViews.all_view)
      view.filtering?.should be_false
      view.active_view.should be_nil

      id = add_flow(store, Gori::FlowSource::Kind::Repeater, "resent.test")
      view.on_event(Gori::Store::FlowEvent.new(id, :inserted), store)
      view.rows.map(&.host).should eq(["resent.test"])
    end
  end

  it "refuses a broken view rather than applying it as match-all" do
    # A view can reach the list from a peer's settings.json or a hand edit, where nothing
    # validated it. `QL.and` folds an EMPTY side away, so applying it would show EVERY flow
    # under a `v:` chip asserting a filter — the direction that matters on a security proxy.
    tmp_store do |store|
      add_flow(store, Gori::FlowSource::Kind::Proxy, "would-leak.test")
      view = HistoryView.new
      view.set_view(Gori::SavedViews::View.new("1", "broken", "src:nope", "project"))
      view.reload(store)
      view.rows.should be_empty
      screen_text(view).should contain("not a usable query")
    end
  end

  it "draws v:All muted at rest and v:NAME left of f:follow when one is on" do
    tmp_store do |store|
      view = HistoryView.new
      view.reload(store)
      text = screen_text(view)
      text.should contain("v:All")

      view.set_view(history_view)
      view.reload(store)
      row = screen_rows(view).first
      row.should contain("v:History")
      # `Frame.right_text_chain` draws rightmost-first, so "left of f:follow" is an ordering
      # claim about the rendered row, not about the array.
      row.index("v:History").not_nil!.should be < row.index("f:follow").not_nil!
    end
  end

  it "truncates a long view name so the chain cannot drop it and hand its slot to another chip" do
    tmp_store do |store|
      view = HistoryView.new
      view.set_view(Gori::SavedViews::View.new("1", "a name far too long to fit", "src:proxy", "project"))
      view.reload(store)
      screen_text(view).should contain("v:a name far to…")
    end
  end

  it "names the view on the empty state instead of sending the operator to the scope lens" do
    tmp_store do |store|
      add_flow(store, Gori::FlowSource::Kind::Repeater, "resent.test")
      view = HistoryView.new
      view.set_view(history_view)
      view.reload(store)
      view.rows.should be_empty
      text = screen_text(view)
      text.should contain("no flows match the History view")
      text.should_not contain("scope lens")
    end
  end

  it "says why a src: view is empty on a project captured before provenance was recorded" do
    tmp_store do |store|
      # A pre-V17 row: inserted with a source, then blanked, which is what those rows look like.
      id = add_flow(store, Gori::FlowSource::Kind::Proxy, "old.test")
      store.@db.exec("UPDATE flows SET source = NULL WHERE id = ?", id)

      view = HistoryView.new
      view.set_view(history_view)
      view.reload(store)
      view.rows.should be_empty
      screen_text(view).should contain("before gori recorded provenance")
    end
  end

  it "still shows the first-run card on an empty project, default view and all" do
    # A project now OPENS with a narrowing view on, so without a guard the very first thing a
    # new user saw was "no flows match the History + Repeater view" instead of the card telling
    # them where to point their client — and naming a filter that excluded nothing is useless
    # when there was nothing to exclude.
    tmp_store do |store|
      view = HistoryView.new
      view.set_view(Gori::SavedViews.default_view(store))
      view.reload(store)
      view.rows.should be_empty
      text = screen_text(view)
      text.should_not contain("no flows match")
      text.should contain("proxy") # the first-run card names the listen address
    end
  end

  it "answers a typed query that matched nothing, even on an empty project" do
    # The one exception to the card: the operator just wrote the query and is owed the answer.
    tmp_store do |store|
      view = HistoryView.new
      view.set_view(Gori::SavedViews.default_view(store))
      view.set_query("status:404")
      view.reload(store)
      text = screen_text(view)
      # The bar's own branch, not the first-run card: the note explains WHY (the view is also
      # narrowing) and the hint points back at the thing they just typed.
      text.should contain("/ to edit the filter")
      text.should contain("v:History + Repeater also narrows to")
    end
  end

  it "names the view in the note when the BAR is what the operator can see" do
    tmp_store do |store|
      add_flow(store, Gori::FlowSource::Kind::Proxy, "keep.test", 200)
      view = HistoryView.new
      view.set_view(history_view)
      view.set_query("status:404")
      view.reload(store)
      view.rows.should be_empty
      # The bar is on screen and still does not explain the empty list — the same reason the
      # ⇧S lens gets a note beside it.
      screen_text(view).should contain("v:History also narrows to src:proxy")
    end
  end
end
