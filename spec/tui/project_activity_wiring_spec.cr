require "../spec_helper"
require "../support/fake_host"
require "file_utils"

# The CONTROLLER wiring for the ACTIVITY pane (#864) — which key reaches which reload.
#
# This file exists because `project_activity_pane_spec.cr` could not have caught what it
# missed. That one drives the VIEW: it calls `reload_activity(store)` itself and then asserts
# the rows, so it verifies the view's contract and says nothing about whether any key path
# actually calls it. Two defects shipped green underneath it — releasing a `/` filter never
# re-queried, and arriving on the pane never refreshed — because in both cases the view was
# right and nothing called it.
private ACT_CA = File.tempname("gori-activity-ca")

private def with_activity(&)
  root = File.tempname("gori-activity-wiring")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("actwiring")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(ACT_CA), Gori::Verbs.registry, project)
    host = FakeHost.new(session)
    ctl = Gori::Tui::ProjectController.new(host)
    yield ctl, session.store
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
    FileUtils.rm_rf(ACT_CA) if Dir.exists?(ACT_CA)
  end
end

private def seed(store : Gori::Store) : Nil
  store.insert_event("agent", "agent_action", "info", "create_issue ok")
  store.insert_event("bindings", "extract_miss", "warn", "$sid found nothing")
  store.insert_event("probe", "issue_found", "success", "reflected parameter")
  store.flush
end

private def esc : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::Escape)
end

describe "ACTIVITY pane controller wiring" do
  # Releasing a committed filter has to RE-QUERY. Without it the pane keeps the narrowed rows
  # under a bar that says nothing is on — a subset presented as the whole feed.
  it "re-queries when esc releases a committed text filter" do
    with_activity do |ctl, store|
      seed(store)
      ctl.view.focus_pane(:activity)
      ctl.reload_activity
      ctl.view.activity_rows.size.should eq(3)

      ctl.view.activity_filter_field.set("extract")
      ctl.reload_activity
      ctl.view.activity_rows.size.should eq(1)

      ctl.handle_body_key(esc).should be_true
      ctl.view.activity_filtered?.should be_false
      # THE assertion: the rows came back, which only a reload can do.
      ctl.view.activity_rows.size.should eq(3)
    end
  end

  # `on_external_change` refreshes only while the pane is SHOWING, so everything committed
  # while another sub-tab was open is unseen until arrival re-reads.
  it "re-reads the feed on arriving at the pane from another sub-tab" do
    with_activity do |ctl, store|
      ctl.view.focus_pane(:activity)
      ctl.reload_activity
      ctl.view.activity_rows.should be_empty
      ctl.view.activity_feed_empty?.should be_true

      # Leave for a neighbouring pane, and let the feed fill while it is not showing.
      ctl.jump_subtab(Gori::Tui::ProjectView::PANES.index(:scope).not_nil!)
      ctl.view.pane.should eq(:scope)
      seed(store)

      ctl.jump_subtab(Gori::Tui::ProjectView::PANES.index(:activity).not_nil!)
      ctl.view.activity_rows.size.should eq(3)
      ctl.view.activity_feed_empty?.should be_false
    end
  end

  it "re-reads on arriving by stepping the strip, not only by a chip jump" do
    with_activity do |ctl, store|
      ctl.view.focus_pane(:settings) # the neighbour to ACTIVITY's left
      seed(store)
      ctl.move_subtab(1)
      ctl.view.pane.should eq(:activity)
      ctl.view.activity_rows.size.should eq(3)
    end
  end

  # `settle_subtab` drops the text filter on the way past. Arriving must therefore not just
  # refresh, but refresh UNFILTERED — otherwise the rows are narrowed by a filter the bar no
  # longer shows.
  it "arrives unfiltered after a sub-tab round trip drops the query" do
    with_activity do |ctl, store|
      seed(store)
      ctl.view.focus_pane(:activity)
      ctl.view.activity_filter_field.set("extract")
      ctl.reload_activity
      ctl.view.activity_rows.size.should eq(1)

      ctl.jump_subtab(Gori::Tui::ProjectView::PANES.index(:env).not_nil!)
      ctl.jump_subtab(Gori::Tui::ProjectView::PANES.index(:activity).not_nil!)

      ctl.view.activity_filter_field.value.should eq("")
      ctl.view.activity_rows.size.should eq(3)
    end
  end
end
