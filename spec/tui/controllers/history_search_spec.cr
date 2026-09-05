require "../../spec_helper"
require "../../support/fake_host"
require "../../support/history_search"
require "../../support/memory_backend"

private class PausedHistoryView < Gori::Tui::HistoryView
  property? pause = false
  getter started = Channel(Nil).new(1)
  getter resume = Channel(Nil).new(1)
  property? pause_hosts = false
  getter hosts_started = Channel(Nil).new(1)
  getter hosts_resume = Channel(Nil).new(1)

  def fetch_search(store : Gori::Store, request : SearchRequest,
                   control : Gori::Store::QueryControl? = nil) : SearchResult
    result = super
    if @pause
      @started.send(nil)
      @resume.receive
    end
    result
  end

  def fetch_host_suggestions(store : Gori::Store, prefix : String,
                             control : Gori::Store::QueryControl? = nil) : Array(String)
    values = super
    if @pause_hosts
      @hosts_started.send(nil)
      @hosts_resume.receive
    end
    control.try(&.check!)
    values
  end
end

private SEARCH_CA = File.tempname("gori-search-ca")
Spec.after_suite { FileUtils.rm_rf(SEARCH_CA) }

private def with_search_controller(&)
  root = File.tempname("gori-search-controller")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("search")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(SEARCH_CA), Gori::Verbs.registry, project)
  view = PausedHistoryView.new
  controller = Gori::Tui::HistoryController.new(FakeHost.new(session), view)
  begin
    3.times do |i|
      session.store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: i.to_i64, scheme: "http", host: "host#{i}.test", port: 80,
        method: "GET", target: "/#{i}", http_version: "HTTP/1.1",
        head: "GET /#{i} HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
    end
    view.reload(session.store)
    settle_history(controller)
    yield controller, view, session
  ensure
    view.pause = false
    view.pause_hosts = false
    controller.cancel_searches
    select
    when view.resume.send(nil)
    else
    end
    select
    when view.hosts_resume.send(nil)
    else
    end
    session.close
    FileUtils.rm_rf(root)
  end
end

describe "History cooperative searches" do
  it "publishes host suggestions before a coalesced capture refresh finishes" do
    with_search_controller do |controller, view, _session|
      view.pause_hosts = true
      view.set_query("host:host1")
      view.query_suggestions.should be_empty
      receive_within(view.hosts_started)
      view.invalidate_host_suggest_cache
      view.query_suggestions.should be_empty
      view.hosts_resume.send(nil)
      deadline = Time.instant + 10.seconds
      loop do
        Fiber.yield
        controller.flush_query_reload_if_due(Time.instant)
        started = select
        when view.hosts_started.receive then true
        else
          false
        end
        break if started
        raise "host refresh did not start" if Time.instant >= deadline
      end
      view.query_suggestions.should eq(["host:host1.test"])
      view.pause_hosts = false
      view.hosts_resume.send(nil)
    end
  end

  it "coalesces capture events during an unfiltered search without losing them" do
    with_search_controller do |controller, view, session|
      view.set_view(nil)
      view.reload(session.store)
      settle_history(controller)
      view.pause = true
      view.reload(session.store)
      receive_within(view.started)
      id = session.store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 4_i64, scheme: "http", host: "new.test", port: 80,
        method: "GET", target: "/new", http_version: "HTTP/1.1",
        head: "GET /new HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      view.on_event(Gori::Store::FlowEvent.new(id, :inserted), session.store)
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      sleep Gori::Tui::HistoryView::FILTER_FLUSH_INTERVAL
      view.flush_filter(session.store).should be_true
      settle_history(controller)
      view.rows.first.id.should eq(id)
    end
  end

  it "uses the displayed sort order until the replacement rows arrive" do
    previous = Gori::Settings.history_list_order
    begin
      with_search_controller do |controller, view, session|
        ids = view.rows.map(&.id)
        view.pause = true
        Gori::Settings.history_list_order = Gori::Settings.history_newest_first? ? "oldest" : "newest"
        view.reload(session.store)
        receive_within(view.started)
        ids.each_with_index { |id, index| view.row_index(id).should eq(index) }
        view.select_row(1)
        view.pause = false
        view.resume.send(nil)
        settle_history(controller)
        view.rows.map(&.id).should eq(ids.reverse)
        view.selected_id.should eq(ids[1])
      end
    ensure
      Gori::Settings.history_list_order = previous
    end
  end

  it "does not let a deferred click override a later selection" do
    with_search_controller do |controller, view, session|
      rect = Gori::Tui::Rect.new(0, 0, 80, 24)
      view.render_list(Gori::Tui::Screen.new(MemoryBackend.new(80, 24)), rect)
      view.pause = true
      view.set_query("path:/")
      view.reload(session.store)
      receive_within(view.started)
      view.start_query
      controller.handle_click(rect, 10, 6) # middle row, while editing
      controller.move_selection(2)         # a newer navigation gesture
      selected = view.selected_id
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.selected_id.should eq(selected)
    end
  end

  it "removes committed deletions immediately while their replacement search is pending" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.reload(session.store)
      receive_within(view.started)
      deleted = view.rows.first.id
      view.delete_by_id(session.store, deleted).should be_true
      view.rows.map(&.id).should_not contain(deleted)
      view.selected_id.should_not eq(deleted)
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.rows.size.should eq(2)
    end
  end

  it "clears old rows immediately and never republishes the pre-clear snapshot" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.reload(session.store)
      receive_within(view.started)
      view.clear(session.store).should be_true
      view.rows.should be_empty
      view.selected_id.should be_nil
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.rows.should be_empty
    end
  end

  it "loads host suggestions asynchronously and rejects an obsolete prefix" do
    with_search_controller do |controller, view, _session|
      view.set_query("host:host0")
      view.query_suggestions.should be_empty
      view.set_query("host:host1")
      view.query_suggestions.should be_empty
      deadline = Time.instant + 10.seconds
      loop do
        Fiber.yield
        controller.flush_query_reload_if_due(Time.instant)
        break unless view.query_suggestions.empty?
        raise "host suggestions did not arrive" if Time.instant >= deadline
      end
      view.query_suggestions.should eq(["host:host1.test"])
      # Repeated lookups use the cached result until explicitly invalidated.
      view.query_suggestions.should eq(["host:host1.test"])
      controller.cancel_searches
      view.apply_host_suggestions("host1", ["host1.test"])
      view.query_suggestions.should be_empty # departure invalidated the prefix
    end
  end

  it "invalidates on editing before the replacement debounce expires" do
    with_search_controller do |controller, view, session|
      before = view.rows.map(&.id)
      view.pause = true
      view.set_query("path:/")
      view.reload(session.store)
      receive_within(view.started)
      controller.handle_query_key(Termisu::Event::Key.new(Termisu::Input::Key::Num1, char: '1'))
      view.pause = false
      view.resume.send(nil)
      Fiber.yield
      controller.flush_query_reload_if_due(Time.instant - 1.second)
      view.rows.map(&.id).should eq(before)
      view.searching?.should be_true
      settle_history(controller)
      view.rows.map(&.target).should eq(["/1"])
    end
  end

  it "keeps old rows navigable, then anchors to the selection made while searching" do
    with_search_controller do |controller, view, session|
      before = view.rows.map(&.id)
      view.pause = true
      view.set_query("path:/")
      view.reload(session.store)
      receive_within(view.started)
      view.rows.map(&.id).should eq(before)
      view.searching?.should be_true
      view.select_row(1)
      selected = view.selected_id
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.selected_id.should eq(selected)
    end
  end

  it "discards a completed result superseded before publication" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.set_query("path:/0")
      view.reload(session.store)
      receive_within(view.started)
      view.set_query("path:/1")
      view.reload(session.store)
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.rows.map(&.target).should eq(["/1"])
    end
  end

  it "finishes a search despite capture updates and keeps a subsequent refresh pending" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.set_query("path:/")
      view.reload(session.store)
      receive_within(view.started)
      id = session.store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 4_i64, scheme: "http", host: "new.test", port: 80,
        method: "GET", target: "/new", http_version: "HTTP/1.1",
        head: "GET /new HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      10.times do
        view.on_event(Gori::Store::FlowEvent.new(id, :inserted), session.store)
        controller.on_external_change
        view.flush_filter(session.store).should be_false
      end
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.rows.size.should eq(3) # publish the completed snapshot first
      sleep Gori::Tui::HistoryView::FILTER_FLUSH_INTERVAL
      view.flush_filter(session.store).should be_true
      settle_history(controller)
      view.rows.first.id.should eq(id)
    end
  end

  it "invalidates an in-flight result when a peer changes the active view" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.reload(session.store)
      receive_within(view.started)
      session.store.insert_saved_view("one", "path:/1")
      chosen = Gori::SavedViews.merged(session.store).find(&.project?).not_nil!
      Gori::SavedViews.set_active(session.store, chosen)
      controller.on_external_change
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.rows.map(&.target).should eq(["/1"])
    end
  end

  it "does not publish results after departure, and refreshes on return" do
    with_search_controller do |controller, view, session|
      before = view.rows.map(&.id)
      view.pause = true
      view.set_query("path:/1")
      view.reload(session.store)
      receive_within(view.started)
      controller.cancel_searches
      view.pause = false
      view.resume.send(nil)
      Fiber.yield
      controller.flush_query_reload_if_due(Time.instant)
      view.rows.map(&.id).should eq(before)
      controller.on_enter
      settle_history(controller)
      view.rows.map(&.target).should eq(["/1"])
    end
  end

  it "keeps invalid queries distinct from searching and does not expose hidden chips" do
    with_search_controller do |controller, view, session|
      view.set_query("status:nope")
      view.reload(session.store)
      view.searching?.should be_false
      view.rows.should be_empty
      view.set_query("host:missing")
      view.reload(session.store)
      view.reveal_searching(Time.instant + 1.second)
      backend = MemoryBackend.new(100, 20)
      rect = Gori::Tui::Rect.new(0, 0, 100, 20)
      view.render_list(Gori::Tui::Screen.new(backend), rect)
      (0...20).map { |y| backend.row(y) }.join.should contain("searching")
      (0...100).each { |x| view.ql_chip_at(rect, x, 0).should be_nil }
      settle_history(controller)
    end
  end

  it "labels previous results while searching on a narrow terminal" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.set_query("path:/")
      view.reload(session.store)
      receive_within(view.started)
      view.reveal_searching(Time.instant + 1.second)
      backend = MemoryBackend.new(32, 20)
      view.render_list(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 32, 20))
      backend.contains?("searching").should be_true
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
    end
  end
  it "paints the chips, not the searching label, until a search outlives the grace" do
    with_search_controller do |controller, view, session|
      view.pause = true
      view.set_query("path:/")
      view.reload(session.store)
      receive_within(view.started)
      view.searching?.should be_true
      rect = Gori::Tui::Rect.new(0, 0, 120, 20)
      render = -> do
        backend = MemoryBackend.new(120, 20)
        view.render_list(Gori::Tui::Screen.new(backend), rect)
        (0...20).map { |y| backend.row(y) }.join
      end
      started = Time.instant
      # A refresh that finishes inside the grace (every coalesced capture reload on a small
      # project) must not blink the bar: the chips stay up and stay clickable.
      controller.flush_query_reload_if_due(started).should be_false
      screen = render.call
      screen.should_not contain("searching")
      screen.should contain("scope:")
      (0...120).any? { |x| view.ql_chip_at(rect, x, 0) }.should be_true
      # Past the grace the tick reports a dirty frame once, and the label replaces the chips.
      controller.flush_query_reload_if_due(started + Gori::Tui::HistoryView::SEARCHING_GRACE).should be_true
      controller.flush_query_reload_if_due(started + 1.second).should be_false
      screen = render.call
      screen.should contain("searching")
      screen.should_not contain("scope:")
      view.pause = false
      view.resume.send(nil)
      settle_history(controller)
      view.searching_shown?.should be_false
      render.call.should contain("scope:")
    end
  end
end
