require "../../spec_helper"

# The command opens its own Store handle, unlike the shared in-memory tool facade.
describe "gori run fuzz create" do
  it "parses ordinary fuzz flags into a persistent tab without running the engine" do
    db = File.tempname("gori-fuzz-create", ".db")
    request = File.tempname("gori-fuzz-create", ".http")
    store = Gori::Store.open(db)
    store.close
    File.write(request, "GET /?q=seed HTTP/1.1\nHost: h\n\n")
    begin
      stdout_silenced do
        Gori::CLI::Run.dispatch(["fuzz", "create", "--db", db, "--request", request,
                                 "--target", "http://127.0.0.1:9", "--mark", "seed",
                                 "--payloads", "a,b", "--prefix", "P", "--no-encode",
                                 "--name", "--force", "--format", "json"])
      end
      store = Gori::Store.open(db)
      row = store.fuzz_sessions.first
      row.name.should eq("--force")
      row.template.should eq(File.read(request))
      store.fuzz_runs.should be_empty
      view = Gori::Tui::FuzzerView.new
      view.restore(row)
      view.run_request_count.should eq(2_i64)
      engine, error = view.build_engine(false, Gori::Scope.load(store), project: store)
      error.should be_nil
      engine.not_nil!.total.should eq(2_i64)
    ensure
      store.close
      File.delete?(request)
      delete_db_files(db)
    end
  end
end
