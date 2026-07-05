require "file_utils"
require "./project"
require "./store"
require "./capture_lock"

module Gori
  # Discovers and creates project workspaces under a root directory. Named
  # projects live in `root/<slug>/`; temp projects in `root/.tmp-<token>/`
  # (hidden + ephemeral).
  class ProjectRegistry
    TEMP_PREFIX = ".tmp-"
    # Sidecar holding the verbatim display name, so `list` doesn't reconstruct it
    # (lossily) from the slugified directory. Lives inside the project dir, so it
    # is never itself listed as a project.
    NAME_FILE = ".name"

    def initialize(@root : String)
    end

    # Existing named projects, most-recently-active first.
    def list : Array(Project)
      return [] of Project unless Dir.exists?(@root)
      projects = [] of Project
      Dir.each_child(@root) do |child|
        next if child.starts_with?(TEMP_PREFIX) || child.starts_with?('.')
        dir = File.join(@root, child)
        db = File.join(dir, Project::DB_FILE)
        next unless Dir.exists?(dir) && File.exists?(db)
        projects << Project.new(display_name(dir, child), db)
      end
      projects.sort_by! { |p| -(p.last_modified.try(&.to_unix) || 0_i64) }
    end

    # The verbatim display name from the sidecar, falling back to the directory
    # name for legacy projects created before the name was persisted.
    private def display_name(dir : String, slug : String) : String
      name_path = File.join(dir, NAME_FILE)
      if File.exists?(name_path)
        n = File.read(name_path).strip
        return n unless n.empty?
      end
      slug
    rescue
      slug
    end

    # Create (or reopen) a named project. The display name is slugified for the
    # directory; the original name is kept for display.
    # `description` is optional and persisted immediately into the project's
    # settings (so it is available on first open in the Project tab).
    def create(name : String, description : String = "") : Project
      display = name.strip
      slug = slugify(display)
      raise Gori::Error.new("invalid project name") if slug.empty?
      dir = File.join(@root, slug)
      FileUtils.mkdir_p(dir)
      # Persist the verbatim display name so a later `list` shows "My Project", not
      # the lossy slug "my-project".
      File.write(File.join(dir, NAME_FILE), display) rescue nil
      proj = Project.new(display, File.join(dir, Project::DB_FILE))
      desc = description.strip
      unless desc.empty?
        # First open creates the DB + runs migrations (including settings table).
        s = Store.open(proj.db_path)
        s.set_setting("description", desc)
        s.close
      end
      proj
    end

    # A throwaway workspace, deleted when its session closes.
    def temp(token : String) : Project
      dir = File.join(@root, "#{TEMP_PREFIX}#{token}")
      FileUtils.mkdir_p(dir)
      Project.new("temp", File.join(dir, Project::DB_FILE), ephemeral: true)
    end

    # Removes a project's directory from disk. Refuses if another LIVE instance holds
    # its capture lock: rm_rf would unlink the db out from under the capturer, which
    # would then keep "successfully" writing flows into a now-pathless inode — a
    # silent, total loss of everything captured after the delete.
    def delete(project : Project) : Nil
      return unless Dir.exists?(project.dir)
      raise Gori::Error.new("project is in use by another gori instance — stop its capture first") if CaptureLock.held?(project.dir)
      FileUtils.rm_rf(project.dir)
    end

    # Slugify a display name into a safe directory name. gsub removes path
    # separators; stripping leading/trailing '-' AND '.' means a dot-only name
    # ("." / ".." / "...") collapses to "" and is rejected by create() — otherwise
    # File.join(@root, slug) would resolve to @root or its parent (traversal).
    private def slugify(name : String) : String
      name.downcase.gsub(/[^a-z0-9._-]+/, "-").strip("-.")
    end
  end
end
