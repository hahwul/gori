require "../../support/tui_contract"
require "file_utils"

include Gori::Tui

describe Gori::Tui::IssuesController do
  it "refuses to replace the active database or write a missing journal" do
    TuiContract.with_session("issues-export-db") do |session|
      id = session.store.insert_issue("keep this issue", Gori::Store::Severity::Low, "a.test", nil)
      controller = IssuesController.new(TuiContract::Host.new(session))
      db = session.project.db_path
      original = File.info(db)
      controller.issues_export_to(:json, Gori::ProjectArchive::ExportDestination.new(db)).should be_false
      File.info(db).same_file?(original).should be_true
      controller.issues_export_to(:json, Gori::ProjectArchive::ExportDestination.new(db + "-journal")).should be_false
      File.exists?(db + "-journal").should be_false
      session.store.get_issue(id).not_nil!.title.should eq("keep this issue")
    end
  end

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
        ctl.issues_export_to(:json, Gori::ProjectArchive::ExportDestination.new(path), [keep]).should be_true
        File.read(path).should contain("keep me")
        File.read(path).should_not contain("leave me")
        File.delete(path)
        ctl.issues_export_to(:json, Gori::ProjectArchive::ExportDestination.new(path)).should be_true
        File.read(path).should contain("leave me")
      ensure
        FileUtils.rm_rf(path)
      end
    end
  end
end

# The Issues twin of History's hidden-marks card (reports/loop #4): a mark the filter hides
# must not silently take a delete meant for the cursor row.
describe "IssuesController hidden-marks card" do
  it "asks before deleting a mark the filter hides, and `c` deletes only the cursor row" do
    TuiContract.with_session("issues-hidden-delete") do |session|
      store = session.store
      hidden = store.insert_issue("hidden finding", Gori::Store::Severity::High, "a.test", nil)
      shown = store.insert_issue("shown finding", Gori::Store::Severity::Low, "b.test", nil)
      host = TuiContract::Host.new(session)
      host.tab = :issues
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      "hidden".each_char { |c| ctl.view.query_insert(c) }
      ctl.issues_mark_toggle
      ctl.view.mark_count.should eq(1)
      "hidden".size.times { ctl.view.query_backspace }
      "shown".each_char { |c| ctl.view.query_insert(c) }
      ctl.view.selected_id.should eq(shown)
      ctl.view.marked_hidden_count.should eq(1)

      host.alt_answer = true
      ctl.issues_delete
      host.confirms.last[0].should eq("DELETE ISSUES")
      host.confirms.last[1].should start_with("Delete 1 marked issue?\n1 marked · 1 not on the list.\nCursor row: “")
      host.confirms.last[1].should end_with("This can't be undone.")
      host.alt_confirms.last[3].should eq("cursor row")
      store.get_issue(shown).should be_nil
      store.get_issue(hidden).should_not be_nil
    end
  end

  it "asks before the list `y` copies a hidden mark, and `c` copies the cursor row" do
    TuiContract.with_session("issues-hidden-copy") do |session|
      store = session.store
      store.insert_issue("hidden finding", Gori::Store::Severity::High, "a.test", nil)
      shown = store.insert_issue("shown finding", Gori::Store::Severity::Low, "b.test", nil)
      host = TuiContract::Host.new(session)
      host.tab = :issues
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      "hidden".each_char { |c| ctl.view.query_insert(c) }
      ctl.issues_mark_toggle
      "hidden".size.times { ctl.view.query_backspace }
      "shown".each_char { |c| ctl.view.query_insert(c) }
      ctl.view.selected_id.should eq(shown)

      host.alt_answer = true
      ctl.issues_copy_all
      host.confirms.last[0].should eq("COPY")
      cursor_row = "[#{Gori::Store::Severity::Low.label}] shown finding (b.test)"
      host.statuses.last.should eq("copied #{cursor_row.bytesize}b to clipboard")
    end
  end
end
