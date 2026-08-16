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
