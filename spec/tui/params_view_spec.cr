require "../spec_helper"
require "../support/fake_host"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

private alias PVRow = Gori::ParamInventory::Row

private def pv_row(name : String, path = "/a", *, host = "acme.test", reflected = false,
                   samples = ["v"], sensitive = false) : PVRow
  PVRow.new(host, "GET", path, Gori::Miner::Location::Query, name, 1, samples, false,
    1_i64, 7_i64, reflected, reflected ? 7_i64 : nil, sensitive)
end

private def pv_report(rows : Array(PVRow), truncated = false) : Gori::ParamInventory::Report
  Gori::ParamInventory::Report.new(rows, 3, truncated)
end

private def pv_render(v : ParamsView, w = 110, h = 12) : Array(String)
  backend = MemoryBackend.new(w, h)
  v.render(Screen.new(backend), Rect.new(0, 0, w, h), focused: true)
  (0...h).map { |y| backend.row(y) }
end

describe ParamsView do
  it "lists the inventory under a summary and column headings" do
    v = ParamsView.new
    v.report = pv_report([pv_row("q", reflected: true, samples: ["shoes"]), pv_row("page")])
    rows = pv_render(v)
    rows[0].should contain("PARAMS · all endpoints · 2 params · 3 flows read")
    rows[1].should contain("NAME")
    rows[2].should contain("q")
    rows[2].should contain("↩")
    rows[2].should contain("shoes")
    rows[3].should contain("page")
    rows[3].should_not contain("↩")
  end

  it "says TRUNCATED when the flow cap cut the read" do
    v = ParamsView.new
    v.report = pv_report([pv_row("q")], truncated: true)
    pv_render(v)[0].should contain("TRUNCATED")
  end

  it "narrows to a Sitemap node's endpoint paths, and back" do
    v = ParamsView.new
    v.report = pv_report([pv_row("a", "/users/1"), pv_row("b", "/users/2"), pv_row("c", "/orders"),
                          pv_row("d", "/users/1", host: "other.test")])
    v.target = ParamsView::Target.new("acme.test", Set{"/users/1", "/users/2"}, "acme.test/users/{n}")
    v.rows.map(&.name).should eq(["a", "b"])
    pv_render(v)[0].should contain("acme.test/users/{n}")
    v.target = ParamsView::Target.new("acme.test", nil, "acme.test")
    v.rows.map(&.name).should eq(["a", "b", "c"])
    v.target = nil
    v.rows.size.should eq(4)
  end

  # Miner's neighbour names come from the host's OTHER endpoints, which the node filter hides.
  it "still hands the whole host's rows to the Miner seed while narrowed" do
    v = ParamsView.new
    v.report = pv_report([pv_row("a", "/x"), pv_row("b", "/y")])
    v.target = ParamsView::Target.new("acme.test", Set{"/x"}, "acme.test/x")
    v.host_rows("acme.test").map(&.name).should eq(["a", "b"])
  end

  it "keeps the cursor on the same parameter across a rescan" do
    v = ParamsView.new
    v.report = pv_report([pv_row("a"), pv_row("b"), pv_row("c")])
    v.move(2)
    v.selected_row.try(&.name).should eq("c")
    v.report = pv_report([pv_row("z"), pv_row("a"), pv_row("b"), pv_row("c")])
    v.selected_row.try(&.name).should eq("c")
  end

  it "says how to start before the first scan" do
    pv_render(ParamsView.new)[2].should contain("^R")
  end
end

private PARAMS_CA = File.tempname("gori-params-ca")
Spec.after_suite { FileUtils.rm_rf(PARAMS_CA) }

private def with_params_controller(&)
  root = File.tempname("gori-params-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("params")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(PARAMS_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    sitemap = SitemapController.new(host)
    yield ParamsController.new(host, sitemap.view), sitemap, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed_params_flow(store, url : String) : Nil
  pair = Gori::Import::Builder.complete_flow(
    Time.utc.to_unix_ms * 1000, url, "GET",
    Gori::Import::Builder::Headers.new, nil, "HTTP/1.1",
    200, "OK", Gori::Import::Builder::Headers.new, nil, "text/html", nil,
    source: Gori::FlowSource::Kind::Import)
  store.insert_import_batch([{pair.request, pair.response}])
end

# Spin the scheduler until the worker's answer lands (the Runner does this once per tick).
private def drain_until_landed(ctl : ParamsController) : Nil
  deadline = Time.instant + 10.seconds
  until ctl.drain_build
    raise "params scan never landed" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe ParamsController do
  it "scans off the event loop and lands the report" do
    with_params_controller do |ctl, _, session|
      seed_params_flow(session.store, "https://acme.test/search?q=shoes")
      ctl.run
      ctl.view.scanning?.should be_true
      drain_until_landed(ctl)
      ctl.view.scanning?.should be_false
      ctl.view.rows.map(&.name).should eq(["q"])
    end
  end

  # A superseded scan must not land LAST and replace the newer answer.
  it "drops a superseded scan's answer" do
    with_params_controller do |ctl, _, session|
      seed_params_flow(session.store, "https://acme.test/a?first=1")
      ctl.run
      stale = ctl.generation
      seed_params_flow(session.store, "https://acme.test/b?second=1")
      ctl.run
      ctl.generation.should_not eq(stale)
      # The older scan was spawned first and answers first: its answer must be dropped, so
      # nothing is on screen yet and the newer scan is still what the header waits on.
      drain_until_landed(ctl)
      ctl.view.ready?.should be_false
      ctl.view.scanning?.should be_true
      drain_until_landed(ctl)
      ctl.view.rows.map(&.name).sort!.should eq(["first", "second"])
    end
  end

  # The inventory answers about the Sitemap's flow set; once the tree's query moved, the
  # scan on screen answers about a different one and a revisit rescans.
  it "rescans on entry when the Sitemap query changed since the scan" do
    with_params_controller do |ctl, sitemap, session|
      seed_params_flow(session.store, "https://acme.test/a?x=1")
      seed_params_flow(session.store, "https://other.test/b?y=1")
      ctl.on_enter
      drain_until_landed(ctl)
      ctl.view.rows.map(&.name).sort!.should eq(["x", "y"])
      gen = ctl.generation
      ctl.on_enter # nothing changed: the scan on screen stands
      ctl.generation.should eq(gen)
      "host:acme.test".each_char { |c| sitemap.view.query_insert(c) }
      ctl.on_enter
      ctl.generation.should_not eq(gen)
      drain_until_landed(ctl)
      ctl.view.rows.map(&.name).should eq(["x"])
    end
  end

  it "narrows the scan to the Sitemap row the operator came from" do
    with_params_controller do |ctl, sitemap, session|
      seed_params_flow(session.store, "https://acme.test/users/1?x=1")
      seed_params_flow(session.store, "https://acme.test/orders?y=1")
      seed_params_flow(session.store, "https://other.test/z?w=1")
      sitemap.reload
      t = sitemap.view.selected_params_target.not_nil!
      t.host.should eq("acme.test") # the first row is the first host
      t.paths.should be_nil
      ctl.set_target(t)
      drain_until_landed(ctl)
      ctl.view.rows.map(&.name).sort!.should eq(["x", "y"])
    end
  end

  it "passes subtree path_prefix to avoid starvation by newer flows on other endpoints" do
    with_params_controller do |ctl, _, session|
      seed_params_flow(session.store, "https://acme.test/old/endpoint?old_param=1")
      seed_params_flow(session.store, "https://acme.test/new/endpoint?new_param=1")
      t = ParamsView::Target.new("acme.test", Set{"/old/endpoint"}, "acme.test/old/endpoint", path_prefix: "/old/endpoint")
      ctl.set_target(t)
      drain_until_landed(ctl)
      ctl.view.rows.map(&.name).should eq(["old_param"])
    end
  end

  it "matches target host case-insensitively in view projection" do
    v = ParamsView.new
    v.report = pv_report([pv_row("a", "/a", host: "acme.test")])
    v.target = ParamsView::Target.new("ACME.TEST", nil, "ACME.TEST")
    v.rows.map(&.name).should eq(["a"])
    v.host_rows("Acme.Test").map(&.name).should eq(["a"])
  end
end
