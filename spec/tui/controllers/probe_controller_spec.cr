require "../../spec_helper"
require "../../support/fake_host"

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
end
