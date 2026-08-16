require "../spec_helper"
require "file_utils"

# A registry `db_path` is built from `Paths.projects_dir`, i.e. from `$GORI_HOME` spelled
# exactly as the process was given it. Matching `--db` against that as a STRING meant the same
# database, named by its resolved path, matched no project at all.
private def with_symlinked_home(&)
  real = File.tempname("gori-home-real")
  link = File.tempname("gori-home-link")
  Dir.mkdir_p(real)
  File.symlink(real, link)
  saved = ENV["GORI_HOME"]?
  begin
    ENV["GORI_HOME"] = link
    yield link, real
  ensure
    saved ? (ENV["GORI_HOME"] = saved) : ENV.delete("GORI_HOME")
    File.delete?(link)
    FileUtils.rm_rf(real)
  end
end

describe Gori::MCP::ProjectResolver do
  it "identifies a registry project's db given by its resolved path" do
    with_symlinked_home do |link, real|
      registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      created = registry.create("api")
      created.db_path.should start_with(link) # the registry spells it through the symlink

      through_link = Gori::MCP::ProjectResolver.resolve(created.db_path, nil,
        workspace_project: false, env_db: nil, env_project: nil)
      through_link.project_name.should eq("api")

      # The SAME file, named by its resolved path. It used to resolve to a nameless db.
      resolved = File.join(real, "projects", "api", Gori::Project::DB_FILE)
      File.exists?(resolved).should be_true
      through_real = Gori::MCP::ProjectResolver.resolve(resolved, nil,
        workspace_project: false, env_db: nil, env_project: nil)
      through_real.project_name.should eq("api")
      through_real.project_slug.should eq("api")
      through_real.project_id.should eq(registry.id_of(created))

      # And it carries the REGISTRY's spelling forward, which is what `list_projects` marks
      # `current` by and what `delete_project`'s serving-project refusal compares against.
      through_real.db_path.should eq(created.db_path)
    end
  end

  it "still serves a db that belongs to no project, under the path it was given" do
    with_symlinked_home do |link, _real|
      loose = File.join(link, "loose.db")
      selection = Gori::MCP::ProjectResolver.resolve(loose, nil,
        workspace_project: false, env_db: nil, env_project: nil)
      selection.db_path.should eq(loose) # not yet created — only the parent has to exist
      selection.project_name.should be_nil
      selection.source.should eq("--db")
    end
  end

  it "identifies the active-project marker through its resolved path too" do
    with_symlinked_home do |_link, real|
      registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      created = registry.create("marked")
      Gori::Paths.write_active_project(File.join(real, "projects", "marked", Gori::Project::DB_FILE))
      selection = Gori::MCP::ProjectResolver.resolve(nil, nil,
        workspace_project: false, allow_active_fallback: true, env_db: nil, env_project: nil)
      selection.source.should eq("active-tui")
      selection.project_name.should eq("marked")
      selection.db_path.should eq(created.db_path)
    end
  end
end
