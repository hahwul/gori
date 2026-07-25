require "../../spec_helper"
require "file_utils"

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
    head: "GET / HTTP/1.1\r\nHost: ex.test\r\n\r\n".to_slice, body: nil))
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
