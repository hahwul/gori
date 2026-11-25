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

  def repeater : Gori::Tui::RepeaterController
    repeater_controller
  end

  def issues : Gori::Tui::IssuesController
    issues_controller
  end

  def feed(ev : Termisu::Event::Key) : Nil
    handle_key(ev)
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

  def type(text : String) : Nil
    text.each_char { |char| handle_key(TuiContract.plain(char)) }
  end

  def resize_terminal(width : Int32, height : Int32) : Nil
    handle(Termisu::Event::Resize.new(width, height))
  end

  def space_menu_level : Gori::Verb::Family?
    @space_menu.level
  end

  def space_menu_open? : Bool
    @space_menu_open
  end

  def refresh_after_peer_write : Nil
    apply_external_change
  end

  def notification_hint : String
    active_overlay.not_nil!.hint
  end

  # Run a verb as the space menu runs its row: the menu closes, then the verb reads its target.
  def run_from_space_menu(id : String) : Nil
    run_space_verb(@session.registry[id])
  end

  def close_palette : Nil
    close_overlay
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

# A capture tick as the Runner's drain runs it: the flow event, then the debounced flush a
# filtered or lensed list takes instead, then whatever search that flush started.
private def runner_spec_capture(history : Gori::Tui::HistoryController, store : Gori::Store,
                                path : String) : Int64
  id = runner_spec_flow(store, path)
  history.view.on_event(Gori::Store::FlowEvent.new(id, :inserted), store)
  sleep Gori::Tui::HistoryView::FILTER_FLUSH_INTERVAL
  history.view.flush_filter(store)
  settle_history(history, store)
  id
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

  it "exports the selected note when a peer deletes it while the destination dialog is open" do
    TuiContract.with_session("runner-note-export") do |session|
      Gori::Notes.create(session.store, "Other note").should_not be_nil
      original = "Selected note\noriginal text"
      selected = Gori::Notes.create(session.store, original).not_nil!
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:notes, :subtabs)
      runner.notes_export
      card = runner.@active_overlay.as(Gori::Tui::ExportOverlay)
      card.default_basename.should eq("Selected-note.md")
      path = File.join(session.project.dir, card.default_basename)
      card.text_fields.first.set(path)

      Gori::Notes.delete(session.store, selected).committed?.should be_true
      runner.refresh_after_peer_write
      runner.press(Termisu::Input::Key::Enter)

      File.read(path).should eq("#{original}\n")
    end
  end

  it "exports the selected report when a peer removes its session before the write" do
    TuiContract.with_session("runner-sequence-export") do |session|
      store = session.store
      ids = ["Selected session", "Other session"].map_with_index do |name, i|
        store.insert_sequencer_session("http://localhost", runner_spec_request("/").to_slice,
          false, nil, "{}", nil, i, name)
      end
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:sequencer, :subtabs)
      ctl = runner.@tabs[:sequencer].as(Gori::Tui::SequencerController)
      ids.size.times do |i|
        view = ctl.view_at(i).not_nil!
        (20 + i).times do |k|
          view.append_sample(Gori::Sequencer::Sample.new(k, "sample-#{k}", nil, 0, 0_i64, nil))
        end
      end
      runner.sequence_export(:markdown)
      path = File.join(session.project.dir, "sequence.md")
      runner.@active_overlay.as(Gori::Tui::ExportOverlay).text_fields.first.set(path)

      store.delete_sequencer_session(ids.first).should be_true
      runner.refresh_after_peer_write
      ctl.current_view.not_nil!.subject.session.should eq("Other session")
      runner.press(Termisu::Input::Key::Enter)

      report = File.read(path)
      report.should contain("Selected session")
      report.should contain("20 usable / 20 collected")
    end
  end

  it "blocks a hidden palette selection and runs the same selection once it fits" do
    TuiContract.with_session("runner-short-palette") do |session|
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:history)
      runner.resize_terminal(80, 9)
      runner.open_palette
      runner.press(Termisu::Input::Key::Escape)
      runner.overlay.should eq(:none)

      runner.resize_terminal(80, 24)
      runner.open_palette
      runner.type("go to project")
      runner.resize_terminal(80, 9)
      runner.press(Termisu::Input::Key::Enter)
      runner.overlay.should eq(:palette)
      runner.active_tab.should eq(:history)

      runner.resize_terminal(80, 12)
      runner.press(Termisu::Input::Key::Enter)
      runner.overlay.should eq(:none)
      runner.active_tab.should eq(:project)
    end
  end

  it "blocks Enter and mnemonics in a hidden Space menu and keeps Escape available" do
    TuiContract.with_session("runner-short-space") do |session|
      runner_spec_flow(session.store, "/one")
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:history)
      settle_history(runner.history, session.store)
      runner.resize_terminal(40, 8)
      runner.open_space_menu
      runner.space_menu_open?.should be_false

      runner.resize_terminal(80, 24)
      runner.open_space_menu
      runner.space_menu_open?.should be_true
      runner.resize_terminal(40, 8)
      runner.press(Termisu::Input::Key::Enter)
      runner.type("Z")
      runner.space_menu_open?.should be_true
      runner.space_menu_level.should be_nil

      runner.resize_terminal(80, 24)
      runner.type("Z")
      runner.space_menu_level.should_not be_nil
      runner.resize_terminal(40, 8)
      runner.press(Termisu::Input::Key::Escape)
      runner.space_menu_open?.should be_false
    end
  end

  # chrome.md #3 / loop.md #2: with follow on, a capture landing while `space` (or `^P`) was
  # open moved the cursor to the new row, and the verb then ran on it. The card holds the
  # cursor on the row it was opened over; with nothing open, follow behaves as before.
  it "runs a space-menu verb on the row the menu was opened over, not a capture that landed under it" do
    clipboard = Gori::Settings.clipboard_osc52?
    Gori::Settings.clipboard_osc52 = false
    begin
      TuiContract.with_session("runner-follow-hold") do |session|
        store = session.store
        runner_spec_flow(store, "/old")
        looked_at = runner_spec_flow(store, "/looked-at")
        runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
        runner.focus_tab(:history)
        history = runner.history
        settle_history(history, store)
        history.view.follow?.should be_true
        history.view.selected_id.should eq(looked_at)

        runner.open_space_menu
        runner.space_menu_open?.should be_true
        arrived = runner_spec_capture(history, store, "/arrived-under-menu")
        history.view.rows.first.id.should eq(arrived)
        history.view.selected_id.should eq(looked_at)
        runner.run_from_space_menu("history.copy")
        Gori::Tui::Register.text.should eq(runner_spec_request("/looked-at"))

        # The palette holds it the same way.
        runner.open_palette
        palette_arrival = runner_spec_capture(history, store, "/arrived-under-palette")
        history.view.rows.first.id.should eq(palette_arrival)
        history.view.selected_id.should eq(looked_at)
        runner.close_palette

        # Nothing open: follow takes the next capture, as it always did.
        newest = runner_spec_capture(history, store, "/after-close")
        history.view.selected_id.should eq(newest)
      end
    ensure
      Gori::Settings.clipboard_osc52 = clipboard
      Gori::Tui::Register.clear
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

  # ^A/^E/^U/^W over the Repeater/Fuzzer TARGET in INS are the shell's line keys (#1379), not
  # the shell's ^W close or the tab's ^U pretty / ^A auto-mark on the same letters.
  it "hands the line keys to a TARGET being typed into, ahead of ^W close" do
    TuiContract.with_session("runner-target-line-keys") do |session|
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:repeater)
      runner.repeater.repeater_from_request("https://h.test", "POST / HTTP/1.1\r\nHost: h.test\r\n\r\n{\"a\":1}", false, nil)
      v = runner.repeater.current_view.not_nil!
      v.focus_pane(:target)
      v.enter_target_insert!
      body = v.request_text
      runner.feed(TuiContract.ctrl('a'))
      runner.type("X")
      runner.feed(TuiContract.ctrl('e'))
      runner.type("/p")
      v.target.should eq("Xhttps://h.test/p")
      runner.feed(TuiContract.ctrl('w'))
      v.target.should eq("Xhttps://h.test/")
      runner.feed(TuiContract.ctrl('u'))
      v.target.should eq("")
      runner.overlay.should eq(:none) # no close confirm
      runner.repeater.subtab_labels.size.should eq(1)
      v.request_text.should eq(body) # ^U did not pretty-print the request

      runner.focus_tab(:fuzzer)
      runner.fuzzer.fuzz_new
      fv = runner.fuzzer.current_view.not_nil!
      fv.focus_first
      fv.enter_target_insert!
      runner.feed(TuiContract.ctrl('u'))
      fv.target.should eq("")
      runner.feed(TuiContract.ctrl('w'))
      runner.overlay.should eq(:none)
      runner.fuzzer.current_view.should be(fv)
    end
  end
  # The EDIT ISSUE form is seeded once, at open. A peer that re-scored the issue while it was
  # up must keep that score when the operator saves only a new title (and vice versa).
  it "writes only the fields EDIT ISSUE changed, keeping a peer's re-score" do
    TuiContract.with_session("runner-issue-retitle") do |session|
      store = session.store
      id = store.insert_issue("Reflected XSS", Gori::Store::Severity::Low, "localhost", nil)
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:issues)
      runner.issues.view.open_detail_id(id, store).should be_true
      runner.issue_edit_title
      runner.@active_overlay.should be_a(Gori::Tui::IssueForm)

      peer = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
      store.update_issue(id, severity: Gori::Store::Severity::Critical, cvss: peer).should be_true
      runner.type(" in search")
      runner.press(Termisu::Input::Key::Enter)

      issue = store.get_issue(id).not_nil!
      issue.title.should eq("Reflected XSS in search")
      issue.severity.should eq(Gori::Store::Severity::Critical)
      issue.cvss.should eq(peer)
      runner.toast.should eq("issue updated")

      # The other way round: a severity changed here leaves a peer's new title alone.
      runner.issue_edit_title
      store.update_issue(id, title: "Peer title").should be_true
      runner.press(Termisu::Input::Key::Tab) # cvss
      runner.press(Termisu::Input::Key::Tab) # severity
      runner.press(Termisu::Input::Key::Left)
      runner.press(Termisu::Input::Key::Enter)
      issue = store.get_issue(id).not_nil!
      issue.title.should eq("Peer title")
      issue.severity.should eq(Gori::Store::Severity::High)
      issue.cvss.should eq(peer)

      # And an untouched save writes nothing at all.
      runner.issue_edit_title
      store.update_issue(id, severity: Gori::Store::Severity::Low).should be_true
      runner.press(Termisu::Input::Key::Enter)
      store.get_issue(id).not_nil!.severity.should eq(Gori::Store::Severity::Low)
      runner.toast.should eq("issue unchanged")
    end
  end

  # Set CVSS on an issue with no vector opens on the least-severe placeholder. ↵ on it used to
  # score the issue 0.0 and derive Info, so a Critical finding became Info on one key.
  it "refuses Set CVSS on an untouched calculator and names a severity the vector moves" do
    TuiContract.with_session("runner-issue-cvss") do |session|
      store = session.store
      id = store.insert_issue("SQL injection", Gori::Store::Severity::Critical, "localhost", nil)
      runner = RunnerSpecShell.new(session, RunnerSpecTerminal.allocate)
      runner.focus_tab(:issues)
      runner.issues.view.open_detail_id(id, store).should be_true
      runner.issue_set_cvss
      calc = runner.@active_overlay.as(Gori::Tui::CvssCalculatorOverlay)

      runner.press(Termisu::Input::Key::Enter)
      runner.@active_overlay.should be(calc) # still up
      runner.toast.should eq(Gori::Tui::CvssCalculatorOverlay::UNTOUCHED_REFUSAL)
      issue = store.get_issue(id).not_nil!
      issue.severity.should eq(Gori::Store::Severity::Critical)
      issue.cvss.should be_nil

      # The refusal landed on the first metric; walk to C and pick High: 7.5, High.
      calc.sel.should eq(Gori::Tui::CvssCalculatorOverlay::ROW_FIRST_M)
      5.times { runner.press(Termisu::Input::Key::Down) }
      runner.type("3")
      runner.press(Termisu::Input::Key::Enter)
      issue = store.get_issue(id).not_nil!
      issue.cvss.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N")
      issue.severity.should eq(Gori::Store::Severity::High)
      runner.toast.should eq("severity critical → high")
    end
  end

  it "words the Set CVSS toast for a batch and for a severity that did not move" do
    Gori::Tui::Runner.cvss_applied_toast(false, 1, [Gori::Store::Severity::High], Gori::Store::Severity::High).should be_nil
    Gori::Tui::Runner.cvss_applied_toast(false, 1, [Gori::Store::Severity::Critical], Gori::Store::Severity::Info)
      .should eq("severity critical → info")
    Gori::Tui::Runner.cvss_applied_toast(false, 3, [Gori::Store::Severity::Critical, Gori::Store::Severity::Critical, Gori::Store::Severity::Info], Gori::Store::Severity::Info)
      .should eq("cvss set · 3 issues · severity critical → info on 2")
    Gori::Tui::Runner.cvss_applied_toast(false, 3, [Gori::Store::Severity::Critical, Gori::Store::Severity::High, Gori::Store::Severity::Low], Gori::Store::Severity::Low)
      .should eq("cvss set · 3 issues · severity → low on 2")
    Gori::Tui::Runner.cvss_applied_toast(false, 2, [Gori::Store::Severity::Low, Gori::Store::Severity::Low], Gori::Store::Severity::Low)
      .should eq("cvss set · 2 issues")
    Gori::Tui::Runner.cvss_applied_toast(true, 2, [] of Gori::Store::Severity, nil)
      .should eq("cvss cleared · 2 issues")
  end
end
