require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"

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
