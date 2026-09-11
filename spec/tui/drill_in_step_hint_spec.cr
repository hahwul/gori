require "../spec_helper"
require "../support/fake_host"
require "../support/history_search"
require "file_utils"
require "../../src/gori/tui/controllers/history_controller"
require "../../src/gori/tui/controllers/issues_controller"
require "../../src/gori/tui/controllers/probe_controller"

include Gori::Tui

# The step keys (⇧N/⇧P) are named by THREE surfaces at once — the rail's gutter, the crumb's
# chip and the status line — and only the first two could ever tell that there is nowhere to
# step. `DrillIn::Host#step_available?` is what the third one now asks, and these examples
# pin it where it is read: `body_hint`, on each of the three tabs.
#
# Two states make the pair inert, and both are reachable:
#   • the open item is NOT a row of the list behind it. Probe's and Issues' `o` open a flow
#     BY ID, so a flow the current History view or query filters out drills in with no index.
#     The crumb already dropped its `12/123` there and no rail was drawn — the status line
#     was the one surface still claiming a key that did nothing.
#   • the list holds exactly one row, which is the one already open.
private STEP_HINT_CA = File.tempname("gori-step-hint-ca")
Spec.after_suite { FileUtils.rm_rf(STEP_HINT_CA) }

# History keeps the drill-in's OPEN state in the shell, so the controller has to be told.
private class StepDetailHost < FakeHost
  def overlay : Symbol
    :detail
  end
end

private def with_step_session(name : String, &)
  root = File.tempname("gori-step-hint")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp(name)
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(STEP_HINT_CA), Gori::Verbs.registry, project)
  begin
    yield session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed_flow(store : Gori::Store, n : Int32) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: n.to_i64, scheme: "http", host: "h.test", port: 80,
    method: "GET", target: "/p#{n}", http_version: "HTTP/1.1",
    head: "GET /p#{n} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy,
    source_surface: Gori::FlowSource::Surface::Tui, source_ref: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, duration_us: 1_000_i64))
  store.flush
  id
end

private def seed_finding(store : Gori::Store, n : Int32) : Nil
  store.upsert_probe_issue(Gori::Probe::Detection.new(
    "missing_csp_#{n}", Gori::Probe::Category::HEADERS, "h#{n}.test",
    "http://h#{n}.test/", "Missing Content-Security-Policy",
    Gori::Store::Severity::Low, "no CSP header", nil))
end

describe "the drill-in's step hint" do
  describe "History" do
    it "names the pair while the open flow is a row of the list" do
      with_step_session("stephist") do |session|
        ctl = HistoryController.new(StepDetailHost.new(session))
        2.times { |i| seed_flow(session.store, i + 1) }
        ctl.view.reload(session.store)
        settle_history(ctl)
        ctl.view.open_detail(session.store).should be_true

        ctl.view.step_available?.should be_true
        ctl.body_hint(:body).should contain("⇧N/⇧P")
      end
    end

    it "drops it for a flow the list behind does not contain" do
      with_step_session("stepdeep") do |session|
        ctl = HistoryController.new(StepDetailHost.new(session))
        seed_flow(session.store, 1)
        ctl.view.reload(session.store)
        settle_history(ctl)
        # The deep link: a flow captured AFTER the list was built, opened by id. Same shape
        # as Probe's `o` into a flow the active view filters out — `@rows` has no index for
        # it, so the crumb loses its position and the rail is not drawn.
        later = seed_flow(session.store, 2)
        ctl.view.open_detail_id(later, session.store).should be_true

        ctl.view.detail_row_index.should be_nil
        ctl.view.step_available?.should be_false
        ctl.body_hint(:body).should_not contain("⇧N")
        ctl.body_hint(:body).should_not contain("⇧P")
      end
    end

    it "drops it on a single-row list, from BOTH levels of the detail" do
      with_step_session("stepone") do |session|
        ctl = HistoryController.new(StepDetailHost.new(session))
        seed_flow(session.store, 1)
        ctl.view.reload(session.store)
        settle_history(ctl)
        ctl.view.open_detail(session.store).should be_true

        ctl.body_hint(:body).should_not contain("⇧N") # the chip strip, where a fresh open lands
        ctl.view.set_detail_focus(:body)
        ctl.body_hint(:body).should_not contain("⇧N") # …and the body below it
      end
    end
  end

  describe "Issues" do
    it "names the pair with a neighbour and drops it without one" do
      with_step_session("stepissue") do |session|
        ctl = IssuesController.new(FakeHost.new(session))
        session.store.insert_issue("first", Gori::Store::Severity::Medium, "h.test", nil)
        ctl.view.reload(session.store)
        ctl.issues_open
        ctl.view.step_available?.should be_false
        ctl.body_hint(:body).should_not contain("⇧N")

        session.store.insert_issue("second", Gori::Store::Severity::Medium, "h.test", nil)
        ctl.view.reload(session.store)
        ctl.issues_open
        ctl.view.step_available?.should be_true
        ctl.body_hint(:body).should contain("⇧N/⇧P")
      end
    end
  end

  describe "Probe" do
    it "names the pair with a neighbour and drops it without one" do
      with_step_session("stepprobe") do |session|
        ctl = ProbeController.new(FakeHost.new(session))
        seed_finding(session.store, 1)
        ctl.view.reload(session.store)
        ctl.probe_open
        ctl.view.step_available?.should be_false
        ctl.body_hint(:body).should_not contain("⇧N")

        seed_finding(session.store, 2)
        ctl.view.reload(session.store)
        ctl.probe_open
        ctl.view.step_available?.should be_true
        ctl.body_hint(:body).should contain("⇧N/⇧P")
      end
    end
  end
end
