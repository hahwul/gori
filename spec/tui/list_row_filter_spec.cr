require "../support/tui_contract"
require "../../src/gori/tui/authorize_view"

include Gori::Tui

# The `/` filter on the three list panes that had none: Discover FINDINGS, Miner RESULTS,
# Authorize requests. Each keeps its source array and walks a visible lens over it.

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

private def type(view, text : String)
  text.each_char { |c| view.handle_filter_key(key(Termisu::Input::Key::LowerA, c)) }
end

private def finding(url : String) : Gori::Discover::Finding
  Gori::Discover::Finding.new(url, "GET", 200, 4_i64, "text/html",
    Gori::Discover::Source::Crawled, 1, 0.95, nil)
end

private def miner_finding(name : String) : Gori::Miner::Finding
  Gori::Miner::Finding.new(name, Gori::Miner::Location::Query, Gori::Miner::Evidence::Status,
    Gori::Miner::Confidence::Confirmed, nil, nil, 0_i64)
end

private def flow(target : String) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 1_i64, "https", "GET", "h.test", 443, target,
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
  head = "GET #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

private def render(view, w = 120, h = 30) : MemoryBackend
  b = MemoryBackend.new(w, h)
  view.render(Screen.new(b), Rect.new(0, 0, w, h), true)
  b
end

describe "the `/` filter on Discover FINDINGS" do
  it "narrows the rows, keeps the cursor on its finding, and restores on esc" do
    view = DiscoverView.new
    run = DiscoverRun.new("http://t", Gori::Discover::Config.new)
    %w[/alpha /beta /gamma].each { |p| run.add_finding(finding("http://t#{p}")) }
    view.add(run)
    view.focus_pane(:findings)
    view.move(1) # on /beta
    view.selected_finding.not_nil!.url.should end_with("/beta")
    view.filter_start
    type(view, "bet")
    render(view).contains?("1/3").should be_true
    view.selected_finding.not_nil!.url.should end_with("/beta")
    view.move(5)
    view.selected_finding.not_nil!.url.should end_with("/beta") # one visible row
    view.handle_filter_key(key(Termisu::Input::Key::Escape))
    view.filter_editing?.should be_false
    view.selected_finding.not_nil!.url.should end_with("/beta")
    view.move(5)
    view.selected_finding.not_nil!.url.should end_with("/gamma")
  end

  it "says so when nothing matches, and a run under a filter empties cleanly" do
    view = DiscoverView.new
    run = DiscoverRun.new("http://t", Gori::Discover::Config.new)
    run.add_finding(finding("http://t/only"))
    view.add(run)
    view.focus_pane(:findings)
    view.filter_start
    type(view, "zzz")
    b = render(view)
    b.contains?("no findings match").should be_true
    view.selected_finding.should be_nil
    run.begin_run
    render(view) # nothing raised with an empty source under a held query
  end
end

describe "the `/` filter on Miner RESULTS" do
  it "narrows the rows and opens the detail on the visible cursor" do
    view = MinerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil, Gori::Miner::Config.new)
    %w[debug admin user].each { |n| view.append_finding(miner_finding(n)) }
    view.focus_pane(:results)
    view.filter_start
    type(view, "adm")
    view.filter_editing?.should be_true
    render(view).contains?("1/3").should be_true
    view.selected_finding.not_nil!.name.should eq("admin")
    view.append_finding(miner_finding("adm2")) # a live append under the lens
    view.results_move(1)
    view.selected_finding.not_nil!.name.should eq("adm2")
    view.open_detail
    view.focus.should eq(:detail)
  end
end

describe "the `/` filter on Authorize requests" do
  it "narrows the rows, numbers them by source ordinal, and removes the right entry" do
    view = AuthorizeView.new
    %w[/one /two /three].each { |t| view.add(flow(t)) }
    view.filter_start
    type(view, "two")
    b = render(view)
    b.contains?("1 match").should be_true
    b.contains?(" 2   GET").should be_true # the `#` column is the source ordinal
    view.selected_entry.not_nil!.host_path.should eq("h.test/two")
    view.remove_selected.should be_true
    view.entries.map(&.host_path).should eq(["h.test/one", "h.test/three"])
    view.selected_entry.should be_nil # the lens now matches nothing
    view.at_top?.should be_true
  end
end

describe "the filter controllers" do
  it "route keys while editing, read as an editor, and leave `/` to the keymap" do
    TuiContract.with_session("row-filter") do |session|
      TuiContract.each_controller(session) do |controller, host|
        case controller
        when AuthorizeController
          controller.querying?.should be_false
          controller.authorize_filter
          host.statuses.last.should contain("nothing to filter")
          controller.view.add(flow("/x"))
          controller.authorize_filter
          controller.querying?.should be_true
          controller.body_badge.should eq(:editor)
          controller.handle_query_key(key(Termisu::Input::Key::Escape)).should be_true
          controller.querying?.should be_false
          controller.handle_body_key(TuiContract.plain('/')).should be_false
        when MinerController
          controller.mine_filter
          host.statuses.last.should contain("no miner session")
          controller.querying?.should be_false
        when TargetController
          controller.discover_active?.should be_false
        end
      end
    end
  end

  it "binds `/` in the three scopes and keeps Miner's menu letter in the results section" do
    keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)
    keymap.lookup(Gori::Verb::Chord.new("/"), Gori::Verb::Scope::Discover).should eq("discover.filter")
    keymap.lookup(Gori::Verb::Chord.new("/"), Gori::Verb::Scope::Miner).should eq("mine.filter")
    keymap.lookup(Gori::Verb::Chord.new("/"), Gori::Verb::Scope::Authorize).should eq("authorize.filter")
    Gori::Verbs.registry["mine.filter"].section.should eq(:results)
  end
end
