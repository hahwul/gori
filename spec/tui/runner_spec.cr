require "../support/tui_contract"
require "../support/history_search"

private class RunnerSpecTerminal < Termisu
  def size : {Int32, Int32}
    {100, 40}
  end
end

private class RunnerSpecShell < Gori::Tui::Runner
  def history : Gori::Tui::HistoryController
    history_controller
  end

  def comparer : Gori::Tui::ComparerView
    comparer_controller.view
  end

  def fuzzer : Gori::Tui::FuzzerController
    fuzzer_controller
  end

  def discover : Gori::Tui::DiscoverView
    discover_controller.view
  end

  def toast : String?
    @toast
  end

  def space_frame : MemoryBackend
    open_space_menu
    backend = MemoryBackend.new(100, 40)
    @space_menu.render(Gori::Tui::Screen.new(backend), TuiContract::AREA)
    backend
  end

  def press(key : Termisu::Input::Key) : Nil
    handle_key(TuiContract.key(key))
  end

  def notification_hint : String
    active_overlay.not_nil!.hint
  end
end

private def runner_spec_request(path : String) : String
  "GET #{path} HTTP/1.1\r\nHost: localhost\r\nX-Review: synthetic\r\n\r\n"
end

private def runner_spec_flow(store : Gori::Store, path : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "localhost", port: 80,
    method: "GET", target: path, http_version: "HTTP/1.1",
    head: runner_spec_request(path).to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

describe Gori::Tui::Runner do
  around_each do |example|
    registry = Gori::Tui::TrafficEmptyState.registry
    begin
      example.run
    ensure
      Gori::Tui::TrafficEmptyState.registry = registry
    end
  end

  it "copies a raw request from the cursor and a URL when the same flow is marked" do
    clipboard = Gori::Settings.clipboard_osc52?
    Gori::Settings.clipboard_osc52 = false
    begin
      TuiContract.with_session("runner-copy") do |session|
        runner_spec_flow(session.store, "/one")
        runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
        runner.focus_tab(:history)
        history = runner.history
        settle_history(history, session.store)
        runner.copy_selection
        Gori::Tui::Register.text.should eq(runner_spec_request("/one"))

        history.history_mark_toggle
        runner.space_frame.contains?("Copy 1 URL").should be_true
        runner.copy_selection
        Gori::Tui::Register.text.should eq("http://localhost/one")
      end
    ensure
      Gori::Settings.clipboard_osc52 = clipboard
      Gori::Tui::Register.clear
    end
  end

  it "keeps both comparison slots and explains why a set of three marks cannot be sent" do
    TuiContract.with_session("runner-compare") do |session|
      ids = %w[/old-a /old-b /mark-a /mark-b /mark-c].map { |path| runner_spec_flow(session.store, path) }
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:history)
      history = runner.history
      settle_history(history, session.store)
      ids[2..].each do |id|
        row = (0...ids.size).find! do |i|
          history.view.select_row(i)
          history.view.selected_id == id
        end
        history.view.select_row(row)
        history.history_mark_toggle
      end
      runner.comparer.set_pair(session.store.get_flow(ids[0]).not_nil!, session.store.get_flow(ids[1]).not_nil!)

      runner.comparer_add_selected

      runner.comparer.slot(:a).not_nil!.flow_id.should eq(ids[0])
      runner.comparer.slot(:b).not_nil!.flow_id.should eq(ids[1])
      runner.toast.not_nil!.should contain("mark exactly 2")
    end
  end

  it "keeps Notifications open for a deleted session and still jumps to a live one" do
    TuiContract.with_session("runner-notification") do |session|
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      fuzzer = runner.fuzzer
      fuzzer.fuzz_new
      live = fuzzer.current_session_db_id.not_nil!
      fuzzer.fuzz_new
      deleted = fuzzer.current_session_db_id.not_nil!
      runner.notifications.push(:info, "Live", Gori::Tui::Jobs::Goto.new(:fuzzer, live))
      runner.notifications.push(:info, "Deleted", Gori::Tui::Jobs::Goto.new(:fuzzer, deleted))
      fuzzer.close_tab
      fuzzer.fuzz_new
      runner.focus_tab(:history)
      runner.open_notifications

      runner.press(Termisu::Input::Key::Enter)
      runner.overlay.should eq(:notifications)
      runner.active_tab.should eq(:history)
      runner.notification_hint.should contain("no longer available")

      runner.press(Termisu::Input::Key::Down)
      runner.press(Termisu::Input::Key::Enter)
      runner.overlay.should eq(:none)
      runner.active_tab.should eq(:fuzzer)
      fuzzer.current_session_db_id.should eq(live)
    end
  end

  it "keeps the underlying flow behind a stale link and opens the exact flow from a live link" do
    TuiContract.with_session("runner-flow-link") do |session|
      first = runner_spec_flow(session.store, "/first")
      second = runner_spec_flow(session.store, "/second")
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.open_flow_detail(first).should be_true
      runner.notifications.push(:info, "Live flow", Gori::Tui::Jobs::Goto.new(:history, second))
      runner.notifications.push(:info, "Gone flow", Gori::Tui::Jobs::Goto.new(:history, Int64::MAX))
      runner.open_notifications

      runner.press(Termisu::Input::Key::Enter)
      runner.overlay.should eq(:notifications)
      runner.notification_hint.should contain("no longer available")
      runner.press(Termisu::Input::Key::Escape)
      runner.overlay.should eq(:detail)
      runner.history.view.detail_flow_id.should eq(first)

      runner.open_notifications
      runner.press(Termisu::Input::Key::Down)
      runner.press(Termisu::Input::Key::Enter)
      runner.overlay.should eq(:detail)
      runner.history.view.detail_flow_id.should eq(second)
    end
  end

  it "opens live Discover results from Activity and refuses the old window's counter IDs" do
    TuiContract.with_session("runner-discover-link") do |session|
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      run = Gori::Tui::DiscoverRun.new("http://localhost/first", Gori::Discover::Config.new)
      runner.discover.add(run)
      runner.discover.add(Gori::Tui::DiscoverRun.new("http://localhost/second", Gori::Discover::Config.new))
      session.store.insert_event("discover", "job_done", :info, "Live run", goto_tab: "target", goto_session_id: run.id)
      session.store.insert_event("discover", "job_done", :info, "Old run", goto_tab: "target", goto_session_id: 1_i64)
      runner.focus_tab(:project)
      runner.activity_refresh

      runner.press(Termisu::Input::Key::Enter)
      runner.active_tab.should eq(:project)
      runner.toast.should eq("Result is no longer available")

      runner.press(Termisu::Input::Key::Down)
      runner.press(Termisu::Input::Key::Enter)
      runner.active_tab.should eq(:target)
      runner.discover.current.should be(run)
    end
  end
end
