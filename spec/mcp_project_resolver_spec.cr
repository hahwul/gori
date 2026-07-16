require "./spec_helper"

private def with_isolated_gori_home(&)
  Dir.tempdir.try do |tmp|
    base = File.join(tmp, "gori-mcp-resolver-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(base)
    old = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = File.join(base, "gori-home")
    begin
      yield base
    ensure
      old ? (ENV["GORI_HOME"] = old) : ENV.delete("GORI_HOME")
    end
  end
end

private def make_git_workspace(base : String, *parts : String) : String
  root = File.join(base, *parts)
  Dir.mkdir_p(File.join(root, ".git"))
  root
end

describe Gori::MCP::ProjectResolver do
  it "isolates an MCP launched in a Git workspace from the globally active TUI project" do
    with_isolated_gori_home do |base|
      Gori::Paths.ensure_dirs
      registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      active = registry.create("unrelated engagement")
      store = Gori::Store.open(active.db_path)
      store.close
      Gori::Paths.write_active_project(active.db_path)

      workspace = make_git_workspace(base, "src", "zaps-rest")
      nested = File.join(workspace, "internal", "server")
      Dir.mkdir_p(nested)
      selected = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: nested,
        env_db: nil, env_project: nil)

      selected.project_name.should eq("zaps-rest")
      selected.project_slug.should eq("zaps-rest")
      selected.project_id.not_nil!.should match(/\A[0-9a-f]{8}\z/) # stable short id
      selected.workspace_root.should eq(File.realpath(workspace))
      selected.source.should eq("workspace-created")
      selected.db_path.should_not eq(active.db_path)
    end
  end

  it "reuses an exact workspace binding on later launches" do
    with_isolated_gori_home do |base|
      workspace = make_git_workspace(base, "repo")
      first = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: workspace,
        env_db: nil, env_project: nil)
      # The binding is visible before SQLite has created the database, which
      # also closes the startup race between two MCP processes.
      before_open = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: workspace,
        env_db: nil, env_project: nil)
      before_open.db_path.should eq(first.db_path)
      store = Gori::Store.open(first.db_path)
      store.close

      second = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: workspace,
        env_db: nil, env_project: nil)
      second.db_path.should eq(first.db_path)
      second.source.should eq("workspace-binding")
      second.auto_created.should be_false
    end
  end

  it "does not silently adopt an unbound same-name project containing older traffic" do
    with_isolated_gori_home do |base|
      Gori::Paths.ensure_dirs
      registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      legacy = registry.create("repo")
      store = Gori::Store.open(legacy.db_path)
      store.close
      workspace = make_git_workspace(base, "repo")

      selected = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: workspace,
        env_db: nil, env_project: nil)
      selected.db_path.should_not eq(legacy.db_path)
      selected.project_slug.should eq("repo-2")
      selected.source.should eq("workspace-created")
    end
  end

  it "does not merge two workspaces that share the same basename" do
    with_isolated_gori_home do |base|
      first_root = make_git_workspace(base, "one", "api")
      second_root = make_git_workspace(base, "two", "api")

      first = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: first_root,
        env_db: nil, env_project: nil)
      store = Gori::Store.open(first.db_path)
      store.close
      second = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: second_root,
        env_db: nil, env_project: nil)

      second.db_path.should_not eq(first.db_path)
      second.project_slug.should eq("api-2")
      second.workspace_root.should eq(File.realpath(second_root))

      # Slug identity stays deterministic even though both display names are "api".
      first_by_slug = Gori::MCP::ProjectResolver.resolve(nil, "api", cwd: second_root,
        env_db: nil, env_project: nil)
      first_by_slug.db_path.should eq(first.db_path)

      # --project also resolves by the stable short id, decoupled from the ambiguous
      # "api" display name shared by both workspaces. (Unique-PREFIX matching is
      # covered deterministically with pinned ids in project_registry_spec.)
      first_by_id = Gori::MCP::ProjectResolver.resolve(nil, first.project_id.not_nil!,
        cwd: second_root, env_db: nil, env_project: nil)
      first_by_id.db_path.should eq(first.db_path)
    end
  end

  it "uses the active TUI project when workspace selection is explicitly disabled" do
    with_isolated_gori_home do |base|
      Gori::Paths.ensure_dirs
      registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      active = registry.create("active")
      store = Gori::Store.open(active.db_path)
      store.close
      Gori::Paths.write_active_project(active.db_path)
      workspace = make_git_workspace(base, "repo")

      selected = Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: workspace,
        workspace_project: false, allow_active_fallback: true,
        env_db: nil, env_project: nil)
      selected.db_path.should eq(active.db_path)
      selected.source.should eq("active-tui")
    end
  end

  it "fails closed outside a workspace instead of leaking the MRU project" do
    with_isolated_gori_home do |base|
      plain_dir = File.join(base, "not-a-repository")
      Dir.mkdir_p(plain_dir)
      expect_raises(Gori::MCP::ProjectResolver::Error, /cannot infer a project/) do
        Gori::MCP::ProjectResolver.resolve(nil, nil, cwd: plain_dir,
          env_db: nil, env_project: nil)
      end
    end
  end
end
