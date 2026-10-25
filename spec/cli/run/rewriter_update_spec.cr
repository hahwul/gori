require "../../spec_helper"

module Gori::CLI::Run
  def self.extract_update_for_spec(args : Array(String)) : Nil
    cmd_extract_update(args)
  end
end

# `with_store`'s shape plus the path, which the command opens on its own (`--db`).
private def with_db_store(&)
  path = File.tempname("gori-spec", ".db")
  store = Gori::Store.open(path)
  raised = run_capturing { yield store, path }
  store.close
  delete_db_files(path)
  raise raised if raised
end

# `gori run rewriter extract update <id>`: the headless `update_extract_rule`, in place.
describe "gori run rewriter extract update" do
  it "changes only what a flag names, strips a spelled name, and clears a field given ''" do
    with_db_store do |store, path|
      id = store.insert_extract_rule("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid", host: "acme.test")
      Gori::CLI::Run.extract_update_for_spec([id.to_s, "--db", path, "--name", "$TOKEN",
                                              "--host", "", "--disabled"])
      r = store.extract_rules.find! { |x| x.id == id }
      r.name.should eq("TOKEN")
      r.host.should eq("")
      r.match_filter.should eq("path:/login")
      r.selector.should eq("sid")
      r.enabled?.should be_false
    end
  end

  it "takes a position range, judged by the same Bindings validator" do
    with_db_store do |store, path|
      id = store.insert_extract_rule("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      Gori::CLI::Run.extract_update_for_spec([id.to_s, "--db", path, "--kind", "position", "--range", "4:9"])
      r = store.extract_rules.find! { |x| x.id == id }
      r.kind.position?.should be_true
      {r.pos_start, r.pos_end}.should eq({4, 9})
    end
  end
end
