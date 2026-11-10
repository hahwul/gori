require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"

include Gori::Tui

private COMPARER_CTL_CA = File.tempname("gori-comparer-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(COMPARER_CTL_CA) }

private def with_comparer_controller(&)
  root = File.tempname("gori-comparer-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("comparer")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(COMPARER_CTL_CA), Gori::Verbs.registry, project)
  begin
    yield ComparerController.new(FakeHost.new(session))
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "ComparerController#body_hint" do
  it "names the two picks, not the diff keys, while neither side is picked" do
    with_comparer_controller do |ctl|
      ctl.view.blank?.should be_true
      hint = ctl.body_hint(:body)
      hint.should contain("pick flow A")
      hint.should contain("pick flow B")
      hint.should contain("esc sub-tabs")
      hint.should_not contain("h-scroll")
      hint.should_not contain("req|res")
    end
  end
end
