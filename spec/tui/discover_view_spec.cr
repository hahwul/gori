require "../spec_helper"

include Gori::Tui

private def finding(url : String, status : Int32? = 200) : Gori::Discover::Finding
  Gori::Discover::Finding.new(url, "GET", status, 10_i64, "text/html",
    Gori::Discover::Source::Crawled, 1, 1.0, nil)
end

private def type_filter(view : DiscoverView, text : String) : Nil
  view.filter_start
  text.each_char do |c|
    view.handle_filter_key(Termisu::Event::Key.new(Termisu::Input::Key::Unknown, Termisu::Input::Modifier::None, c))
  end
  view.handle_filter_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)) # keep it, leave the bar
end

# Every row the FINDINGS cursor can reach, top to bottom: the `visible` list, read through
# the public walk the operator makes.
private def walk(view : DiscoverView) : Array(String)
  view.focus_pane(:findings)
  view.select_finding(0)
  urls = [] of String
  while f = view.selected_finding
    urls << f.url
    view.move(1)
    break if view.selected_finding.try(&.url) == urls.last # the cursor is on the last row
  end
  urls
end

# The reference: what the retired full rebuild answered — every finding whose row text
# contains the query, in order.
private def expected(run : DiscoverRun, q : String) : Array(String)
  run.findings.select { |f| q.empty? || "#{f.status.try(&.to_s) || "—"} #{f.source.label} #{f.method} #{f.url}".downcase.includes?(q) }.map(&.url)
end

# `visible` is memoised over {run, rev, query} and, while a crawl appends, only filters the
# findings added since its last answer. The list the cursor walks must stay exactly the full
# rebuild's through appends, a restart (`begin_run` clears then appends), a query change and
# the empty query.
describe "Gori::Tui::DiscoverView findings filter" do
  it "matches a full rebuild through appends, a restart and query changes" do
    view = DiscoverView.new
    run = DiscoverRun.new("http://t.test", Gori::Discover::Config.new)
    view.add(run)
    5.times { |i| run.add_finding(finding("http://t.test/#{i.even? ? "admin" : "page"}#{i}")) }
    walk(view).should eq(expected(run, ""))

    type_filter(view, "ADMIN")
    walk(view).should eq(expected(run, "admin"))
    3.times { |i| run.add_finding(finding("http://t.test/admin-new#{i}")) }
    run.add_finding(finding("http://t.test/other"))
    walk(view).should eq(expected(run, "admin")) # appended rows filtered in
    walk(view).size.should eq(6)

    # A restart clears and re-appends: fewer findings, same query, rev moved by more than
    # the list grew — the tail must not be reused.
    run.begin_run
    2.times { |i| run.add_finding(finding("http://t.test/page#{i}")) }
    run.add_finding(finding("http://t.test/admin-z"))
    walk(view).should eq(["http://t.test/admin-z"])

    run.begin_run # a restart that grows past the old size again
    8.times { |i| run.add_finding(finding("http://t.test/p#{i}#{i == 7 ? "admin" : ""}")) }
    walk(view).should eq(expected(run, "admin"))

    view.filter_start
    view.handle_filter_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)) # esc clears
    walk(view).should eq(expected(run, ""))
    run.add_finding(finding("http://t.test/late", nil))
    walk(view).should eq(expected(run, ""))
  end
end
