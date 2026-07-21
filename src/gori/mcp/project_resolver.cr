require "../paths"
require "../project_registry"

module Gori
  module MCP
    # Resolves the database an MCP process serves. Explicit CLI/env selectors win;
    # otherwise a process started inside a Git workspace gets a path-bound gori
    # project. Non-workspace launches start *unbound* (no store) so the agent can
    # list/create/switch projects over MCP — unless the active-TUI fallback was
    # explicitly requested via --use-active-project.
    # This fail-safe prevents an agent in repository A from silently reading or
    # writing repository B's most-recently-used capture database.
    module ProjectResolver
      record Selection,
        db_path : String?,
        project_name : String?,
        project_slug : String?,
        source : String,
        workspace_root : String? = nil,
        auto_created : Bool = false,
        project_id : String? = nil do
        def bound? : Bool
          !db_path.nil?
        end
      end

      class Error < Exception
      end

      def self.resolve(db : String?, project : String?, *, cwd : String = Dir.current,
                       workspace_project : Bool = true,
                       allow_active_fallback : Bool = false,
                       env_db : String? = ENV["GORI_MCP_DB"]?,
                       env_project : String? = ENV["GORI_MCP_PROJECT"]?) : Selection
        Paths.ensure_dirs
        registry = ProjectRegistry.new(Paths.projects_dir)

        if selected = db.try(&.presence)
          return select_db(selected, "--db", registry)
        end
        if selected = project.try(&.presence)
          return select_project(selected, "--project", registry)
        end
        if selected = env_db.try(&.presence)
          return select_db(selected, "GORI_MCP_DB", registry)
        end
        if selected = env_project.try(&.presence)
          return select_project(selected, "GORI_MCP_PROJECT", registry)
        end

        if workspace_project && (root = find_workspace_root(cwd))
          if existing = registry.find_by_workspace(root)
            return from_project(existing, registry, "workspace-binding", root)
          end

          name = File.basename(root)
          project_for_workspace = registry.create_for_workspace(name, root)
          created = !File.exists?(project_for_workspace.db_path)
          source = created ? "workspace-created" : "workspace-binding"
          return from_project(project_for_workspace, registry, source, root, created)
        end

        return active_fallback(registry) if allow_active_fallback

        # Unbound: MCP handshake succeeds; traffic tools refuse until switch/create.
        # Never silently adopt the active TUI / MRU project without an explicit opt-in.
        Selection.new(nil, nil, nil, "unbound")
      end

      # Nearest Git worktree root. `.git` may be a directory or a worktree file.
      def self.find_workspace_root(cwd : String) : String?
        current = canonical(cwd)
        loop do
          marker = File.join(current, ".git")
          return current if Dir.exists?(marker) || File.file?(marker)
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end
        nil
      rescue
        nil
      end

      private def self.select_db(path : String, source : String,
                                 registry : ProjectRegistry) : Selection
        expanded = File.expand_path(path)
        parent = File.dirname(expanded)
        raise Error.new("#{source} directory does not exist: #{parent}") unless Dir.exists?(parent)
        project = registry.list.find { |candidate| candidate.db_path == expanded }
        Selection.new(expanded, project.try(&.name),
          project.try { |candidate| registry.slug_of(candidate) }, source,
          project_id: project.try { |candidate| registry.id_of(candidate) })
      end

      private def self.active_fallback(registry : ProjectRegistry) : Selection
        if path = Paths.read_active_project
          if File.file?(path)
            project_for_path = registry.list.find { |candidate| candidate.db_path == path }
            return Selection.new(path, project_for_path.try(&.name),
              project_for_path.try { |candidate| registry.slug_of(candidate) }, "active-tui",
              project_id: project_for_path.try { |candidate| registry.id_of(candidate) })
          end
        end
        if mru = registry.list.first?
          return from_project(mru, registry, "mru")
        end
        Selection.new(Paths.default_db, nil, nil, "default-db")
      end

      private def self.select_project(name : String, source : String,
                                      registry : ProjectRegistry) : Selection
        project = registry.find(name)
        raise Error.new("no such project: #{name} (match short id, id prefix, dir slug, or display name)") unless project
        from_project(project, registry, source)
      end

      private def self.from_project(project : Project, registry : ProjectRegistry,
                                    source : String, workspace_root : String? = nil,
                                    auto_created : Bool = false) : Selection
        Selection.new(project.db_path, project.name, registry.slug_of(project), source,
          workspace_root, auto_created, project_id: registry.id_of(project))
      end

      private def self.canonical(path : String) : String
        expanded = File.expand_path(path)
        begin
          File.realpath(expanded)
        rescue
          expanded
        end
      end
    end
  end
end
