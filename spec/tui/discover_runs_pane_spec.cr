require "../spec_helper"
require "../support/memory_backend"

# The Discover pane's RUNS list. Discovery is a BACKGROUND job and several can be in flight
# at once, but the pane used to draw one summary card for the selected run: a second
# "Discover here" moved the selection to the new run and the first one — still crawling —
# had no row, no status, and no reachable ^X. Every example here is about a run OTHER than
# the newest staying visible and selectable.
include Gori::Tui

private def discover_run(target : String, status : Symbol = :running,
                         config : Gori::Discover::Config? = nil) : DiscoverRun
  run = DiscoverRun.new(target, config || Gori::Discover::Config.new)
  run.status = status
  run
end

private def render_runs(view : DiscoverView, w = 120, h = 24) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h), true)
  backend
end

# The screen row the target's own row landed on, so the click hit-test is checked against
# what the renderer actually drew rather than against a hand-copied offset.
private def row_of(backend : MemoryBackend, text : String, h = 24) : Int32
  (0...h).each { |y| return y if backend.row(y).includes?(text) }
  -1
end

describe "Discover RUNS list" do
  it "keeps every launched run on screen, not just the newest" do
    view = DiscoverView.new
    view.add(discover_run("http://a.test/", :running))
    view.add(discover_run("http://b.test/", :paused))
    view.add(discover_run("http://c.test/", :running))
    backend = render_runs(view)

    backend.contains?("http://a.test/").should be_true
    backend.contains?("http://b.test/").should be_true
    backend.contains?("http://c.test/").should be_true
    # The count moved out of the card TITLE and onto `Frame.border_meta`: the run badge's
    # `min_x` is derived from the title's width, so `RUNS (9)` → `RUNS (10)` shifted the chrome.
    # Still on the border, still says how many — just right-aligned and independent of the title.
    backend.row(0).should contain("RUNS")
    backend.row(0).should contain("3")
    # Each row carries its own status, so "which one is still sending" is readable at a glance.
    row_of(backend, "http://b.test/").should_not eq(-1)
    backend.row(row_of(backend, "http://b.test/")).should contain("paused")
    backend.row(row_of(backend, "http://a.test/")).should contain("running")
  end

  it "selects an earlier run with ↑/↓ so ^X/p have something to act on" do
    view = DiscoverView.new
    view.add(discover_run("http://a.test/"))
    view.add(discover_run("http://b.test/"))
    view.current.try(&.target).should eq("http://b.test/") # a launch selects the new run
    view.runs_at_bottom?.should be_true

    view.move_run(-1)
    view.current.try(&.target).should eq("http://a.test/")
    view.runs_at_top?.should be_true
    view.move_run(-1) # clamped: the controller turns this into "leave for the sub-tab strip"
    view.current.try(&.target).should eq("http://a.test/")
  end

  it "selects the run whose row was clicked" do
    view = DiscoverView.new
    view.add(discover_run("http://a.test/"))
    view.add(discover_run("http://b.test/"))
    view.add(discover_run("http://c.test/"))
    rect = Rect.new(0, 0, 120, 24)
    backend = MemoryBackend.new(120, 24)
    view.render(Screen.new(backend), rect, true)

    y = row_of(backend, "http://a.test/")
    y.should_not eq(-1)
    view.click(rect, 10, y)
    view.focus.should eq(:runs)
    view.current.try(&.target).should eq("http://a.test/")
  end

  it "scrolls the list rather than dropping rows when runs outgrow the card" do
    view = DiscoverView.new
    20.times { |i| view.add(discover_run("http://h#{i}.test/")) }
    backend = render_runs(view)
    # The newest run is selected, so the window must have followed the selection down.
    backend.contains?("http://h19.test/").should be_true
    # The count moved out of the card TITLE and onto `Frame.border_meta`: the run badge's
    # `min_x` is derived from the title's width, so `RUNS (9)` → `RUNS (10)` shifted the chrome.
    # Still on the border, still says how many — just right-aligned and independent of the title.
    backend.row(0).should contain("RUNS")
    backend.row(0).should contain("20")

    view.move_run(-19) # back to the first run
    top = render_runs(view)
    top.contains?("http://h0.test/").should be_true
  end

  it "reports the SELECTED run's cost in the detail band, not the newest run's" do
    stopped = discover_run("http://a.test/", :budget_exhausted,
      Gori::Discover::Config.new(max_requests: 8_i64))
    stopped.sent = 8_i64
    stopped.queued = 275
    view = DiscoverView.new
    view.add(stopped)
    view.add(discover_run("http://b.test/", :running))
    render_runs(view).contains?("budget exhausted").should be_false # b is selected

    view.move_run(-1)
    back = render_runs(view)
    back.contains?("budget exhausted").should be_true
    back.contains?("275").should be_true
  end

  it "dismisses a finished run's row and keeps the selection in range" do
    view = DiscoverView.new
    view.add(discover_run("http://a.test/", :done))
    view.add(discover_run("http://b.test/", :stopped))
    b = view.current.not_nil!

    view.dismiss(b).should be_true
    view.count.should eq(1)
    view.current.try(&.target).should eq("http://a.test/") # the selection never dangles past the end
    render_runs(view).contains?("http://b.test/").should be_false

    view.dismiss(b).should be_false # already gone
    view.dismiss(view.current.not_nil!).should be_true
    view.empty?.should be_true
    # Back to the standing empty state, which is now the onboarding card rather than one grey
    # line inside a RUNS frame — same claim ("no runs"), and the same card Sitemap draws in the
    # same situation one sub-tab over.
    b = render_runs(view)
    b.contains?("no runs").should be_true
    b.contains?("DISCOVER").should be_true
  end

  # Render and the mouse must agree about a pane that is not on screen. With no runs the card
  # owns the whole rect and neither pane is drawn, so a click must not focus or select anything.
  # `click` consults the scroll gauges BEFORE `pane_at`, so this covers that ordering too: the
  # gauges decline on an empty list of their own accord (`Frame.scroll_gauge_row` refuses when
  # `total <= track`), which is why one guard in `pane_at` is enough.
  it "declines every mouse hit while the onboarding card owns the rect" do
    view = DiscoverView.new
    view.empty?.should be_true
    rect = Rect.new(0, 0, 120, 24)
    (0...24).step(3) do |y|
      [1, 40, 119].each do |x|
        view.pane_at(rect, x, y).should be_nil # (#{x},#{y})
        view.click(rect, x, y)                 # inert: nothing to focus or select
      end
    end
    view.focus.should eq(:runs) # untouched by any of those clicks
  end

  it "refuses to dismiss a run that is still crawling" do
    view = DiscoverView.new
    running = discover_run("http://a.test/", :running)
    paused = discover_run("http://b.test/", :paused)
    view.add(running)
    view.add(paused)

    # Both count as live (DiscoverRun#running? covers :paused): the engine fiber outlives the
    # row and drain_events drops events for a run that left the list, so dropping either would
    # orphan a crawl that is still sending.
    view.dismiss(running).should be_false
    view.dismiss(paused).should be_false
    view.count.should eq(2)
  end

  it "steps between the RUNS list and the FINDINGS table" do
    view = DiscoverView.new
    view.add(discover_run("http://a.test/"))
    view.focus.should eq(:runs)
    view.pane_advance(1).should be_true
    view.focus.should eq(:findings)
    view.pane_advance(1).should be_false # off the last pane → the ring returns to the tab bar
    view.pane_advance(-1).should be_true
    view.focus.should eq(:runs)
    view.pane_advance(-1).should be_false
  end

  it "keeps the target and status columns at a narrow body width" do
    view = DiscoverView.new
    view.add(discover_run("http://narrow.test/", :running))
    backend = render_runs(view, 40, 16)
    backend.contains?("narrow.test").should be_true
    (0...16).any? { |y| backend.row(y).includes?("running") }.should be_true
  end
end
