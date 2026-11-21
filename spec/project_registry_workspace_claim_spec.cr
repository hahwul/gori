require "./spec_helper"
require "file_utils"

private def with_root(&)
  root = File.tempname("gori-ws-claim")
  begin
    yield Gori::ProjectRegistry.new(root), root
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# `create_for_workspace` binds a directory to a source workspace and deliberately leaves
# the DB for the caller to open (so the binding is visible to a second MCP process before
# SQLite has created anything — see spec/mcp/project_resolver_spec.cr). That window is not
# always closed a moment later: the MCP entry point degrades to unbound when `Store.open`
# fails, and a killed process closes it never. So a workspace-bound directory with no db
# is a state the registry has to keep honouring.
describe Gori::ProjectRegistry do
  it "claims a workspace directory under a projects root that does not exist yet" do
    with_root do |registry, root|
      Dir.exists?(root).should be_false # no Paths.ensure_dirs ran first
      project = registry.create_for_workspace("api", File.join(root, "checkout"))
      File.basename(project.dir).should eq("api")
      registry.workspace_of(project).should eq(File.expand_path(File.join(root, "checkout")))
    end
  end

  it "keeps paths with and without a trailing space bound to separate projects" do
    posix_only!("trailing spaces in directory names")
    with_root do |registry, root|
      checkout = File.join(root, "checkout")
      spaced_checkout = "#{checkout} "
      Dir.mkdir_p(checkout)
      Dir.mkdir(spaced_checkout)

      spaced_project = registry.create_for_workspace("API", spaced_checkout)
      registry.workspace_of(spaced_project).should eq(File.realpath(spaced_checkout))
      registry.find_by_workspace(checkout).should be_nil

      plain_project = registry.create_for_workspace("API", checkout)
      plain_project.dir.should_not eq(spaced_project.dir)
      registry.create_for_workspace("API", spaced_checkout).dir.should eq(spaced_project.dir)
      registry.find_by_workspace(checkout).try(&.dir).should eq(plain_project.dir)
    end
  end

  it "leaves projects with absent or blank workspace sidecars unbound" do
    with_root do |registry, _root|
      legacy = registry.create("Legacy")
      registry.workspace_of(legacy).should be_nil
      File.write(File.join(legacy.dir, Gori::ProjectRegistry::WORKSPACE_FILE), " \t\n")
      registry.workspace_of(legacy).should be_nil
    end
  end

  describe "a workspace-bound directory whose database does not exist yet" do
    it "is not taken over by a same-slug create" do
      with_root do |registry, root|
        Dir.mkdir_p(root)
        bound = registry.create_for_workspace("api", File.join(root, "checkout"))
        File.basename(bound.dir).should eq("api")
        File.exists?(bound.db_path).should be_false # the window this is all about

        # A DIFFERENTLY-named project that slugifies onto the claimed directory: "Api!"
        # loses its punctuation to the slug, so it lands on "api" while its display name
        # is not the bound project's — the collision case.
        other = registry.create("Api!")
        File.basename(other.dir).should eq("api-2")

        # And the binding still resolves to the project that owns it.
        registry.workspace_of(bound).should eq(File.expand_path(File.join(root, "checkout")))
        found = registry.find_by_workspace(File.join(root, "checkout"))
        found.should_not be_nil
        found.not_nil!.db_path.should eq(bound.db_path)
      end
    end

    it "still reopens by name for the project that owns the binding" do
      with_root do |registry, root|
        Dir.mkdir_p(root)
        bound = registry.create_for_workspace("api", File.join(root, "checkout"))
        # Same display name => the documented reopen-by-name, which must keep working:
        # this is how `gori run project create api` reaches the project MCP made.
        same = registry.create("api")
        same.dir.should eq(bound.dir)
        registry.workspace_of(same).should eq(File.expand_path(File.join(root, "checkout")))
      end
    end

    it "does not treat a leftover empty directory as a collision" do
      with_root do |registry, root|
        # No db and no binding: a half-created or hand-made dir must still be reusable,
        # which is what the DB-only check got right and this must not regress.
        Dir.mkdir_p(File.join(root, "api"))
        project = registry.create("Api!") # slugifies to "api", display name differs
        File.basename(project.dir).should eq("api")
      end
    end
  end
end
