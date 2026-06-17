require "file_utils"
require "./project"

module Gori
  # Discovers and creates project workspaces under a root directory. Named
  # projects live in `root/<slug>/`; temp projects in `root/.tmp-<token>/`
  # (hidden + ephemeral).
  class ProjectRegistry
    TEMP_PREFIX = ".tmp-"

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
        projects << Project.new(child, db)
      end
      projects.sort_by! { |p| -(p.last_modified.try(&.to_unix) || 0_i64) }
    end

    # Create (or reopen) a named project. The display name is slugified for the
    # directory; the original name is kept for display.
    def create(name : String) : Project
      display = name.strip
      slug = slugify(display)
      raise Gori::Error.new("invalid project name") if slug.empty?
      dir = File.join(@root, slug)
      FileUtils.mkdir_p(dir)
      Project.new(display, File.join(dir, Project::DB_FILE))
    end

    # A throwaway workspace, deleted when its session closes.
    def temp(token : String) : Project
      dir = File.join(@root, "#{TEMP_PREFIX}#{token}")
      FileUtils.mkdir_p(dir)
      Project.new("temp", File.join(dir, Project::DB_FILE), ephemeral: true)
    end

    def delete(project : Project) : Nil
      FileUtils.rm_rf(project.dir) if Dir.exists?(project.dir)
    end

    private def slugify(name : String) : String
      name.downcase.gsub(/[^a-z0-9._-]+/, "-").strip('-')
    end
  end
end
