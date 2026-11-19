require "../../support/tui_contract"
require "file_utils"

include Gori::Tui

describe Gori::Tui::IssuesController do
  # The export writes the ids it is handed (the marks or the filtered rows), through the one
  # exporter every surface shares; nil is every issue.
  it "exports only the issues it is given" do
    TuiContract.with_session("issues-export-ids") do |session|
      store = session.store
      keep = store.insert_issue("keep me", Gori::Store::Severity::High, "a.test", nil)
      store.insert_issue("leave me", Gori::Store::Severity::Low, "b.test", nil)
      ctl = IssuesController.new(TuiContract::Host.new(session))
      path = File.tempname("gori-issues-export", ".json")
      begin
        ctl.issues_export_to(:json, path, [keep]).should be_true
        File.read(path).should contain("keep me")
        File.read(path).should_not contain("leave me")
        File.delete(path)
        ctl.issues_export_to(:json, path).should be_true
        File.read(path).should contain("leave me")
      ensure
        FileUtils.rm_rf(path)
      end
    end
  end
end
