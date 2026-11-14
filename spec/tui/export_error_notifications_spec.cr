require "../spec_helper"
require "../support/fake_host"
require "file_utils"

include Gori::Tui

private EXPORT_ERROR_CA = File.tempname("gori-export-errors-ca")
Spec.after_suite { FileUtils.rm_rf(EXPORT_ERROR_CA) }

private class ExportErrorHost < FakeHost
  getter kinds = [] of Symbol

  def status(message : String, kind : Symbol) : Nil
    @kinds << kind
    super
  end
end

private def with_export_error_host(&)
  root = File.tempname("gori-export-errors")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("export-errors")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(EXPORT_ERROR_CA), Gori::Verbs.registry, project)
  begin
    yield ExportErrorHost.new(session), root
  ensure
    session.close
    FileUtils.rm_rf(root)
  end
end

describe "export failures use the persistent error notification path" do
  it "marks a Notes write failure as an error and keeps the export open" do
    with_export_error_host do |host, directory|
      NotesController.new(host).notes_export_to(directory).should be_false
      host.kinds.last?.should eq(:error)
      host.statuses.last.should contain("export failed:")
    end
  end

  it "marks an Issues write failure as an error and keeps the export open" do
    with_export_error_host do |host, directory|
      host.session.store.insert_issue("Export me", Gori::Store::Severity::Medium, "example.test", nil).should_not eq(0_i64)
      IssuesController.new(host).issues_export_to(:json, directory).should be_false
      host.kinds.last?.should eq(:error)
    end
  end

  it "marks a Sequencer report write failure as an error and keeps the export open" do
    with_export_error_host do |host, directory|
      ctl = SequencerController.new(host)
      ctl.sequence_from_text((1..20).map { |i| "token_#{i}" }.join('\n'))
      view = ctl.current_view.not_nil!
      while view.running?
        Fiber.yield
        ctl.drain_events
      end
      view.report.usable_count.should eq(20)
      ctl.sequencer_export_to(:json, directory).should be_false
      host.kinds.last?.should eq(:error)
    end
  end

  it "marks a Params catalog write failure as an error" do
    with_wordlist_home do |catalog|
      File.write(catalog, "blocks the catalog directory")
      with_export_error_host do |host, _|
        ctl = ParamsController.new(host)
        row = Gori::ParamInventory::Row.new("https", "example.test", 443, "GET", "/",
          Gori::Miner::Location::Query, "q", 1, ["value"], false,
          1_i64, 1_i64, false, nil, false)
        ctl.view.report = Gori::ParamInventory::Report.new([row], 1, false)
        ctl.export_wordlist
        host.kinds.last?.should eq(:error)
        host.statuses.last.should contain("wordlist export failed:")
      end
    end
  end
end
