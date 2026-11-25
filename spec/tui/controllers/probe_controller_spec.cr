require "../../spec_helper"
require "../../support/fake_host"
require "../../support/tui_contract"

include Gori::Tui

# ProbeController — the triage toasts. The list itself is pinned in spec/tui/probe_view_spec.cr.

private PROBE_CTL_CA = File.tempname("gori-probe-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(PROBE_CTL_CA) }

private def with_probe_controller(&)
  root = File.tempname("gori-probe-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("probe")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(PROBE_CTL_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield ProbeController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe ProbeController do
  # A dismissed finding leaves the open-only list at once, so the toast names the way back:
  # the show-closed lens, then the key that re-opens it — both from the live keymap.
  it "says how to get a dismissed finding back" do
    with_probe_controller do |ctl, host, session|
      session.store.upsert_probe_issue(
        Gori::Probe::Detection.new("missing_csp", "headers", "x.test", "https://x.test/", "t", Gori::Store::Severity::High))
      ctl.view.reload(session.store)
      ctl.probe_dismiss
      host.statuses.last.should eq("finding dismissed (a shows closed · c re-opens)")
      ctl.view.toggle_show_closed
      ctl.probe_dismiss
      host.statuses.last.should eq("finding re-opened")
      # Closed rows already shown: the row stayed, and `a` would now HIDE it.
      ctl.probe_dismiss
      host.statuses.last.should eq("finding dismissed (c re-opens)")
    end
  end

  # The list is ~40 rows long and custom rules sit at the bottom, so a new rule the cursor did
  # not follow was off screen until End.
  it "selects a custom rule it just added" do
    with_probe_controller do |ctl, _host, session|
      ctl.rules.reload(session.store)
      ctl.apply_custom_rule(CustomRuleOverlay.new(title: "w3 needle", description: "d", scope: "project",
        side: "response", region: "body", kind: "string", severity: "low", pattern: "zzneedle")).should be_true
      ctl.rules.selected_row.try(&.title).should eq("w3 needle")
    end
  end
end

# A saved custom rule the RULES `/` query hides: "added custom rule" over a list that did not
# change read as a write that never happened, while the rule was scanning every flow.
describe "ProbeController custom rules under a `/` filter" do
  it "says a new rule is hidden by the filter" do
    with_probe_controller do |ctl, host, session|
      ctl.rules.reload(session.store)
      ctl.rules_filter
      "zzqq".each_char { |c| ctl.handle_list_filter_key(TuiContract.plain(c)) }
      ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Enter))
      ctl.apply_custom_rule(CustomRuleOverlay.new(title: "w3 needle", description: "d", scope: "project",
        side: "response", region: "body", kind: "string", severity: "low", pattern: "zzneedle")).should be_true
      host.statuses.last.should eq("custom rule added · hidden by /")
    end
  end

  it "keeps the plain toast when the query shows the rule" do
    with_probe_controller do |ctl, host, session|
      ctl.rules.reload(session.store)
      ctl.rules_filter
      "needle".each_char { |c| ctl.handle_list_filter_key(TuiContract.plain(c)) }
      ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Enter))
      ctl.apply_custom_rule(CustomRuleOverlay.new(title: "w3 needle", description: "d", scope: "project",
        side: "response", region: "body", kind: "string", severity: "low", pattern: "zzneedle")).should be_true
      host.statuses.last.should eq("added custom rule")
      ctl.rules.selected_row.try(&.title).should eq("w3 needle")
    end
  end
end

describe "ProbeController custom-rule toasts" do
  it "say an edit the query hides, inside the 80×24 status row" do
    with_probe_controller do |ctl, host, session|
      id = session.store.insert_probe_custom_rule("w3 needle", "d", "response", "body", "string",
        "zzneedle", Gori::Store::Severity::Low)
      ctl.rules.reload(session.store)
      ctl.rules_filter
      "needle".each_char { |c| ctl.handle_list_filter_key(TuiContract.plain(c)) }
      ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Enter))
      ctl.apply_custom_rule(CustomRuleOverlay.new(title: "renamed", description: "d", scope: "project",
        side: "response", region: "body", kind: "string", severity: "low", pattern: "zzpin",
        edit_id: id.to_s, edit_scope: "project")).should be_true
      host.statuses.last.should eq("custom rule updated · hidden by /")
      host.statuses.each { |toast| Screen.display_width(toast).should be <= RowFilter::TOAST_COLS }
      host.notifications.all.last.detail.not_nil!.should contain("“needle”")
    end
  end
end
