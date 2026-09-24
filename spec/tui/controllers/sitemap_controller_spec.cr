require "../../spec_helper"
require "../../support/fake_host"

include Gori::Tui

# SitemapController — the OpenAPI export's worker (#1241). The tree itself is pinned in
# spec/tui/sitemap_view_spec.cr; this file owns what the controller adds on top: the export
# runs off the event loop, writes the file, and lands ONE toast through `drain_export`.

private SITEMAP_CTL_CA = File.tempname("gori-sitemap-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(SITEMAP_CTL_CA) }

private def with_sitemap_controller(&)
  root = File.tempname("gori-sitemap-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("sitemap")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(SITEMAP_CTL_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield SitemapController.new(host), host, session, root
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed(store, url : String, method = "GET") : Nil
  pair = Gori::Import::Builder.complete_flow(
    Time.utc.to_unix_ms * 1000, url, method,
    Gori::Import::Builder::Headers.new, nil, "HTTP/1.1",
    200, "OK", Gori::Import::Builder::Headers.new, nil, "text/html", nil,
    source: Gori::FlowSource::Kind::Import)
  store.insert_import_batch([{pair.request, pair.response}])
end

private def drain_export(ctl : SitemapController) : Nil
  deadline = Time.instant + 10.seconds
  until ctl.drain_export
    raise "export never landed" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe SitemapController do
  it "exports off the event loop, writes the file, and toasts the result" do
    with_sitemap_controller do |ctl, host, session, root|
      seed(session.store, "https://acme.test/users/1")
      seed(session.store, "https://acme.test/users/2")
      seed(session.store, "https://other.test/x")
      path = File.join(root, "api.json")
      ctl.export_openapi(path, Gori::QL::EMPTY, {"acme.test" => nil.as(Set(String)?)}, "acme.test")
      host.statuses.last.should contain("exporting")
      # Nothing has run yet: the build is a spawned fiber, not a call the event loop waits on.
      File.exists?(path).should be_false
      drain_export(ctl)
      host.statuses.last.should start_with("OpenAPI: 1 operation on 1 path from 2 flows")
      host.statuses.last.should contain(path)
      doc = JSON.parse(File.read(path))
      doc["paths"].as_h.keys.should eq(["/users/{userId}"])
    end
  end

  it "writes YAML for a .yaml destination" do
    with_sitemap_controller do |ctl, _, session, root|
      seed(session.store, "https://acme.test/a")
      path = File.join(root, "api.yaml")
      ctl.export_openapi(path, Gori::QL::EMPTY, {"acme.test" => nil.as(Set(String)?)}, "acme.test")
      drain_export(ctl)
      YAML.parse(File.read(path))["openapi"].should eq("3.0.3")
    end
  end

  it "reports a write failure instead of claiming success" do
    with_sitemap_controller do |ctl, host, session, root|
      seed(session.store, "https://acme.test/a")
      ctl.export_openapi(File.join(root, "missing-dir", "api.json"), Gori::QL::EMPTY,
        {"acme.test" => nil.as(Set(String)?)}, "acme.test")
      drain_export(ctl)
      host.statuses.last.should start_with("OpenAPI export failed")
    end
  end

  describe ".export_toast" do
    it "names the caps that cut the document short" do
      report = Gori::Export::OpenApi::Report.new
      report.operations = 3
      report.paths = 2
      report.flows_read = 9
      report.endpoints_dropped = 4
      report.skip(Gori::Export::OpenApi::Skip::WebSocket)
      toast = SitemapController.export_toast(report, "/tmp/x.json")
      toast.should eq("OpenAPI: 3 operations on 2 paths from 9 flows · " \
                      "TRUNCATED (4 operations left out (max endpoints)) · 1 skipped → /tmp/x.json")
    end

    it "says why an export is empty" do
      report = Gori::Export::OpenApi::Report.new
      report.skip(Gori::Export::OpenApi::Skip::Grpc)
      SitemapController.export_toast(report, "/tmp/x.json")
        .should eq("OpenAPI: nothing to export — skipped 1 gRPC; no file written")
      SitemapController.export_toast(Gori::Export::OpenApi::Report.new, "/tmp/x.json")
        .should eq("OpenAPI: nothing to export — no captured request under the selection; no file written")
    end
  end

  it "writes no file when the selection holds nothing to export" do
    with_sitemap_controller do |ctl, host, session, root|
      seed(session.store, "https://acme.test/a")
      path = File.join(root, "api.json")
      ctl.export_openapi(path, Gori::QL::EMPTY, {"other.test" => nil.as(Set(String)?)}, "other.test")
      drain_export(ctl)
      host.statuses.last.should start_with("OpenAPI: nothing to export")
      File.exists?(path).should be_false
    end
  end
end
