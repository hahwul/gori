require "./spec_helper"
require "file_utils"

private def pending_request(target : String)
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "acme.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
end

describe Gori::Session, "#close" do
  # Pending rows are project-wide and belong to the instance holding the capture lock. A second,
  # view-only instance closing must not turn the capturer's in-flight flows into errors.
  it "leaves the capturer's Pending flows alone when a view-only instance closes" do
    root = File.tempname("gori-session-close")
    Dir.mkdir_p(root)
    prev_host = Gori::Settings.bind_host
    prev_port = Gori::Settings.bind_port
    begin
      Gori::Settings.path_override = File.join(root, "settings.json")
      Gori::Settings.project_bind_host = nil
      Gori::Settings.project_bind_port = nil
      Gori::Settings.bind_host = "127.0.0.1"
      Gori::Settings.bind_port = 0
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
      project = Gori::ProjectRegistry.new(File.join(root, "projects")).create("close")
      config = Gori::Config.new(listen: "127.0.0.1", port: 0)
      capturer = Gori::Session.open(config, ca, Gori::Verbs.registry, project)
      begin
        capturer.capturing_lock_held?.should be_true
        flow = capturer.store.insert_flow(pending_request("/long-poll"))
        viewer = Gori::Session.open(config, ca, Gori::Verbs.registry, project)
        viewer.capturing_lock_held?.should be_false
        viewer.close
        capturer.store.get_flow(flow).not_nil!.row.state.should eq(Gori::Store::FlowState::Pending)
      ensure
        capturer.close
      end
    ensure
      Gori::Settings.path_override = nil
      Gori::Settings.bind_host = prev_host
      Gori::Settings.bind_port = prev_port
      FileUtils.rm_rf(root)
    end
  end
end
