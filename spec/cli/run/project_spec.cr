require "../../spec_helper"
require "file_utils"
require "json"

# `gori run project create / delete` — project resolution and the delete preview. These
# operate on the on-disk registry, so they are the CLI surface where a wrong answer
# destroys data: the delete preview is the only thing standing between `rm -rf` and a
# project the operator did not mean to name.

# Private CLI glue — reopen the module for bare-call wrappers.
module Gori::CLI::Run
  def self.project_object_counts_for_spec(project : Gori::Project) : {Int64?, Int32?}
    project_object_counts(project)
  end

  def self.ambiguous_project_name_for_spec(registry : Gori::ProjectRegistry, name : String) : Bool
    ambiguous_name?(registry, name)
  end

  def self.delete_preview_verdict_for_spec(project : Gori::Project, locked : Bool,
                                           open_elsewhere : Bool) : String
    delete_preview_verdict(project, locked, open_elsewhere)
  end

  def self.scope_rule_json_for_spec(rule : Gori::Scope::Rule) : JSON::Any
    JSON.parse(JSON.build { |j| scope_rule_json(j, rule) })
  end
end

private def with_project_root(&)
  root = File.tempname("gori-projroot")
  begin
    yield Gori::ProjectRegistry.new(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

private def seed_project_flow(store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "ex.test", port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: ex.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

# One handle, closed exactly once — Store#close is NOT idempotent (a 2nd @done.receive
# blocks forever), so each open gets its own short block instead of a close-then-flag.
private def with_project_store(project : Gori::Project, &)
  store = Gori::Store.open(project.db_path)
  begin
    yield store
  ensure
    store.close
  end
end

describe "gori run project create" do
  it "reports created-vs-reopened from the registry, not from a name lookup" do
    with_project_root do |registry|
      project, created = registry.create_or_reopen("spec proj")
      created.should be_true
      # A name that is a PREFIX of the first project's short id: #find would resolve it to
      # that project and call this brand-new one a reopen.
      id = registry.id_of(project).not_nil!
      other, other_created = registry.create_or_reopen(id[0, 4])
      other_created.should be_true
      other.dir.should_not eq(project.dir)

      registry.create_or_reopen("spec proj")[1].should be_false # same name → reopen
    end
  end

  it "materializes the DB so a description-less project is immediately listed" do
    with_project_root do |registry|
      # #list skips a directory with no DB; a lazily-created one would stay invisible to
      # `project list` / --project until something captured into it.
      project = registry.create("spec proj")
      File.exists?(project.db_path).should be_true
      registry.list.map(&.name).should eq(["spec proj"])
    end
  end

  it "leaves an existing DB untouched when create reopens the project" do
    with_project_root do |registry|
      project = registry.create("spec proj")
      with_project_store(project) { |store| seed_project_flow(store) }
      registry.create("spec proj") # reopen path: must not recreate the DB
      with_project_store(project, &.count.should(eq(1)))
    end
  end
end

describe "gori run project delete (preview)" do
  it "counts the flows and issues that deleting would destroy" do
    with_project_root do |registry|
      project = registry.create("spec proj")
      with_project_store(project) do |store|
        2.times { seed_project_flow(store) }
        store.insert_issue("finding", Gori::Store::Severity::Low, "ex.test", nil)
      end
      Gori::CLI::Run.project_object_counts_for_spec(project).should eq({2_i64, 1})
      # The whole directory is what rm_rf takes, so the preview sizes it (DB + WAL/SHM +
      # sidecars), never just the DB file.
      project.disk_size.should be > project.db_size
    end
  end

  it "reports nil counts for a project whose DB was deleted under it" do
    with_project_root do |registry|
      project = registry.create("empty proj")
      File.delete(project.db_path)
      Gori::CLI::Run.project_object_counts_for_spec(project).should eq({nil, nil})
      project.disk_size.should be > 0 # the .name/.id sidecars still go with the directory
    end
  end

  it "sizes a directory whose path contains glob metacharacters" do
    root = File.tempname("gori-proj[root]") # `[...]` is a glob character class
    begin
      project = Gori::ProjectRegistry.new(root).create("globby")
      project.disk_size.should be > 0
    ensure
      FileUtils.rm_rf(root)
    end
  end

  # `ProjectRegistry#delete` refuses on EITHER lock, so a preview that ends in "re-run with
  # --yes" while one of them is held is promising a delete its own next step declines.
  it "predicts the refusal instead of inviting --yes when the project is held" do
    with_project_root do |registry|
      project = registry.create("held proj")
      free = Gori::CLI::Run.delete_preview_verdict_for_spec(project, false, false)
      free.should contain("re-run with --yes")

      # The case the preview used to miss entirely: nobody is capturing, a peer merely has
      # the database open (an MCP server takes no capture lock and writes issues and notes
      # all the same).
      open_only = Gori::CLI::Run.delete_preview_verdict_for_spec(project, false, true)
      open_only.should contain("held by another gori instance")
      open_only.should_not contain("--yes to remove")

      capturing = Gori::CLI::Run.delete_preview_verdict_for_spec(project, true, false)
      capturing.should contain("held by a live capture")
    end
  end

  # The probe behind the second half of that verdict, against a REAL open handle — the
  # counts above run through a read-only Store of their own, so the preview has to ask
  # after closing it or it finds its own lock and calls every project held.
  it "reads a live peer's handle as 'open in another instance', and its own as not" do
    with_project_root do |registry|
      project = registry.create("lock proj")
      Gori::OpenLock.in_use?(project.db_path).should be_false
      with_project_store(project) do |_store|
        Gori::OpenLock.in_use?(project.db_path).should be_true
      end
      Gori::CLI::Run.project_object_counts_for_spec(project) # opens and closes its own handle
      Gori::OpenLock.in_use?(project.db_path).should be_false
    end
  end
end

describe "gori run project delete (resolution)" do
  it "refuses a display name shared by two projects, and accepts either slug" do
    root = File.tempname("gori-projroot")
    begin
      registry = Gori::ProjectRegistry.new(root)
      # What create_for_workspace produces for two checkouts with the same basename:
      # distinct slugs (my-api, my-api-2), one shared display name.
      registry.create("My API")
      twin = File.join(root, "my-api-2")
      Dir.mkdir_p(twin)
      File.write(File.join(twin, Gori::ProjectRegistry::NAME_FILE), "My API")
      Gori::Store.open(File.join(twin, Gori::Project::DB_FILE)).close

      registry.list.count { |p| p.name == "My API" }.should eq(2)
      Gori::CLI::Run.ambiguous_project_name_for_spec(registry, "My API").should be_true
      Gori::CLI::Run.ambiguous_project_name_for_spec(registry, "my api").should be_true # find is case-insensitive
      # Slugs are unique, and #find resolves them before the display-name pass.
      Gori::CLI::Run.ambiguous_project_name_for_spec(registry, "my-api").should be_false
      Gori::CLI::Run.ambiguous_project_name_for_spec(registry, "my-api-2").should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "does not call a uniquely-named project ambiguous" do
    with_project_root do |registry|
      registry.create("alpha")
      registry.create("beta")
      Gori::CLI::Run.ambiguous_project_name_for_spec(registry, "alpha").should be_false
    end
  end

  it "does not call an unknown name ambiguous (that is a separate, clearer error)" do
    # `ambiguous_name?` gates the "refuse to guess" abort; answering true for a name that
    # matches nothing would report a collision where the real problem is a typo.
    with_project_root do |registry|
      registry.create("alpha")
      Gori::CLI::Run.ambiguous_project_name_for_spec(registry, "no-such-project").should be_false
    end
  end
end

# `scope add --format json` (#1117): the success line used to carry no id at all, so a script
# that added a rule it meant to remove later had nothing to remove it by. The object is the one
# `scope --format json` lists, because both call `scope_rule_json`.
describe "gori run project scope add --format json" do
  it "is the listed rule, id included" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", " api.example.test ").should be_true
      rule = scope.rules.find { |r| r.pattern == "api.example.test" }.not_nil!
      j = Gori::CLI::Run.scope_rule_json_for_spec(rule)
      j.as_h.keys.should eq(["id", "kind", "type", "pattern"])
      {j["id"].as_i64, j["kind"].as_s, j["type"].as_s, j["pattern"].as_s}
        .should eq({rule.id, "include", "host", "api.example.test"})
    end
  end
end
