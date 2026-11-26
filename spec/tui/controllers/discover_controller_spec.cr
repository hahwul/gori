require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"
require "../../support/tui_probes"

include Gori::Tui

private DISCOVER_CTL_CA = File.tempname("gori-discover-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(DISCOVER_CTL_CA) }

private def with_discover_controller(&)
  root = File.tempname("gori-discover-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("discover")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(DISCOVER_CTL_CA), Gori::Verbs.registry, project)
  begin
    yield DiscoverController.new(FakeHost.new(session))
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# With no run yet the footer was one 55-column phrase before `esc sub-tabs`, which no fitting
# rule can shorten: an 80-column row kept the pointer the card already spells and cut the way out.
describe "DiscoverController footer with no run" do
  it "names the route when there is room, and keeps the menu and the way out when there is not" do
    with_discover_controller do |ctl|
      route = ctl.view.start_route
      hint = ctl.body_hint(:body)
      hint.should eq("#{DiscoverView::START_FROM} · #{route} · space cmds · esc sub-tabs")
      Chrome.fit_hints(hint, 59).should eq("#{DiscoverView::START_FROM} · space cmds · esc sub-tabs")
    end
  end
end

describe "DiscoverController footer on the runs list" do
  it "names the run key at 80 columns" do
    with_discover_controller do |ctl|
      ctl.view.add(DiscoverRun.new("http://a.test/", Gori::Discover::Config.new))
      ctl.view.focus_pane(:runs)
      Chrome.status_row(ctl.body_hint(:body), "BODY").should contain("^R run")
    end
  end
end

# Every wordlist path exists and answers slowly, each with a page of its own (so no two hits
# read as one drifting soft-404 run); anything else, the calibrator's bogus paths included,
# is a quick 404.
private class SlowWordlistBackend < Gori::Discover::Backend
  def initialize(@delay : Time::Span)
  end

  def fetch(scheme : String, host : String, port : Int32, target : String) : Gori::Repeater::Result
    if target.matches?(/\A\/word\d+\z/)
      sleep @delay
      page(200, "<html><body>#{Random::Secure.hex(24)} #{target} #{Random::Secure.hex(24)}</body></html>")
    else
      page(404, "<html>nothing here</html>")
    end
  end

  private def page(status : Int32, body : String) : Gori::Repeater::Result
    head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, body.to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64)
  end
end

class Gori::Tui::DiscoverController
  def launch_run_for_spec(run : DiscoverRun, engine : Gori::Discover::Engine) : Nil
    @view.add(run)
    launch_run(run, engine)
  end
end

describe "DiscoverController#stop_all with a crawl in flight" do
  # Leave project: nothing drains @discover_events after stop_all, yet a stopped crawl still
  # handles every in-flight probe and reports each hit, then its Done. 300 findings overran
  # the 256-slot channel, and the forwarder behind it parked for good.
  it "lets the run fiber consume its engine to the end once nothing drains it" do
    with_discover_controller do |ctl|
      words = (1..300).map { |i| "word#{i}" }
      cfg = Gori::Discover::Config.new(spider: false, bruteforce: true, concurrency: words.size,
        calibrate_probes: 1, retries: 0)
      run = DiscoverRun.new("http://t/", cfg)
      engine = Gori::Discover::Engine.new("http://t/", words, SlowWordlistBackend.new(500.milliseconds), cfg)
      ctl.launch_run_for_spec(run, engine)
      sleep 100.milliseconds # calibrated, every probe inside its fetch
      ctl.stop_all
      undelivered = -> { engine.events.@queue.try(&.size) || 0 }
      deadline = Time.instant + 5.seconds
      until (engine.events.closed? && undelivered.call == 0) || Time.instant >= deadline
        sleep 20.milliseconds
      end
      {engine.events.closed?, undelivered.call}.should eq({true, 0})
    end
  end
end

private def detach_spec_crawl(words : Int32, concurrency : Int32, delay : Time::Span) : {DiscoverRun, Gori::Discover::Engine}
  cfg = Gori::Discover::Config.new(spider: false, bruteforce: true, concurrency: concurrency,
    calibrate_probes: 1, retries: 0)
  run = DiscoverRun.new("http://t/", cfg)
  {run, Gori::Discover::Engine.new("http://t/", (1..words).map { |i| "word#{i}" }, SlowWordlistBackend.new(delay), cfg)}
end

describe "DiscoverController after stop_all" do
  # A key handled in the same tick as the exit reaches the controller after stop_all: a
  # crawl it starts would have no reader at all, and nothing would ever stop it.
  it "refuses to start a crawl" do
    with_discover_controller do |ctl|
      ctl.stop_all
      run, engine = detach_spec_crawl(10, 1, 1.millisecond)
      ctl.launch_run_for_spec(run, engine)
      run.running?.should be_false
      run.engine.should be_nil
      ctl.@host.as(FakeHost).statuses.last.should eq("project is closing")
    end
  end

  it "halts a crawl whose feed was detached under it" do
    with_discover_controller do |ctl|
      run, engine = detach_spec_crawl(2000, 4, 10.milliseconds) # ~5 s of work
      ctl.launch_run_for_spec(run, engine)
      sleep 30.milliseconds
      ctl.@run_feed.detach
      deadline = Time.instant + 2.seconds
      until engine.events.closed? || Time.instant >= deadline
        sleep 10.milliseconds
      end
      engine.stopped?.should be_true
      engine.events.closed?.should be_true
    end
  end
end
