require "../spec_helper"

# `Store#set_setting` / `#delete_setting` are `exec_task_ok`: they answer whether the write
# COMMITTED, precisely so a caller does not have to guess. A rolled-back write (another
# instance's writer holds the project, the store is closing) is transient — but only if the
# caller keeps its dirty flag up so a later exit path retries. These two views cleared the flag
# regardless, which turned the transient failure into loss of the operator's own prose.
#
# A CLOSED store is the honest seam for "the write did not commit": `exec_task_ok` catches
# Channel::ClosedError and answers false, which is the same false a rolled-back batch produces.
private def with_project_store(&)
  dir = File.tempname("gori-desc-persist")
  Dir.mkdir_p(dir)
  path = File.join(dir, "gori.db")
  store = Gori::Store.open(path)
  begin
    yield store, Gori::Project.new("p", path)
  ensure
    store.close rescue nil
    FileUtils.rm_rf(dir)
  end
end

describe Gori::Tui::ProjectView do
  it "keeps the description dirty when the write did not commit, and does not clobber it" do
    with_project_store do |store, project|
      view = Gori::Tui::ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.reload(project, store)
      view.replace_desc("staging sweep — creds in note 3")

      store.close # every write from here answers false
      view.save(store)

      # The flag must still be up: it is the only thing that would make a later exit retry.
      # `reload` is what ran next in the real path (tab enter), and it used to re-seed the
      # buffer from the stored value — which is where the text actually went.
      view.reload(project, store)
      view.desc_text.should eq("staging sweep — creds in note 3")
    end
  end

  it "clears the flag and persists when the write commits" do
    with_project_store do |store, project|
      view = Gori::Tui::ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.reload(project, store)
      view.replace_desc("api staging")
      view.save(store)
      store.flush
      store.setting(Gori::Tui::ProjectView::DESC_KEY).should eq("api staging")

      # A committed save leaves nothing dirty, so a reload legitimately refreshes from the db.
      store.set_setting(Gori::Tui::ProjectView::DESC_KEY, "edited by another window").should be_true
      view.reload(project, store)
      view.desc_text.should eq("edited by another window")
    end
  end
end

describe Gori::Tui::NotesView do
  it "keeps notes dirty when the write did not commit" do
    with_project_store do |store, _project|
      view = Gori::Tui::NotesView.new
      view.reload(store)
      view.insert('h')
      view.insert('i')

      store.close
      view.save(store)
      # Still dirty ⇒ a later exit path retries. Cleared, the notes were simply gone.
      view.dirty?.should be_true
    end
  end

  it "clears the flag when the write commits" do
    with_project_store do |store, _project|
      view = Gori::Tui::NotesView.new
      view.reload(store)
      view.insert('o')
      view.insert('k')
      view.save(store)
      view.dirty?.should be_false
      store.flush
      store.setting(Gori::Tui::NotesView::DOCS_KEY).to_s.should contain("ok")
    end
  end
end

# The contract the Project SETTINGS pane's persistence report rests on. Store setting writes
# return this Bool, and `apply_project_network` refuses to say "saved" when any field answers
# false. That pane cannot be driven without a live Session, so the seam it depends on is pinned
# here instead.
describe "per-project setting writes report whether they committed" do
  it "answers false for both store calls once the project can no longer be written" do
    with_project_store do |store, _project|
      store.set_setting("network.bind_host", "127.0.0.1").should be_true
      store.delete_setting("network.bind_host").should be_true
      store.close
      store.set_setting("network.bind_host", "0.0.0.0").should be_false
      store.delete_setting("network.bind_host").should be_false
    end
  end
end
