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
        project = find_project_for_db(registry, expanded)
        # When it IS a registry project, carry the REGISTRY's spelling of the path forward, not
        # the caller's. Everything downstream compares this string: `list_projects` marks the
        # row whose `db_path` equals it, and `delete_project` refuses the project whose
        # `db_path` equals it. Handing on a differently-spelled path to the same file left the
        # served project unmarked in the listing and — the half that matters — outside the
        # "cannot delete the project this server is currently serving" guard.
        Selection.new(project.try(&.db_path) || expanded, project.try(&.name),
          project.try { |candidate| registry.slug_of(candidate) }, source,
          project_id: project.try { |candidate| registry.id_of(candidate) })
      end

      # The registry project whose database IS this path — compared through the filesystem, not
      # as strings. A registry db_path is built from `Paths.projects_dir`, i.e. from `$GORI_HOME`
      # exactly as it was spelled, so `--db` given the SAME file by its resolved path matched
      # nothing: the server correctly served that database while reporting name/slug/id as null
      # and marking no row `current`. `$GORI_HOME` through a symlink is the ordinary way to hit
      # this (a dotfiles-managed home, `/tmp` on macOS), and the workspace side of this resolver
      # already normalizes with `realpath` for the same reason.
      #
      # `Paths.canonical_file` owns the rule; `OpenLock` keys its lock files by the same one, so
      # a `--db` spelling that resolves to a registry project is matched here AND locked there
      # under one identity.
      private def self.find_project_for_db(registry : ProjectRegistry, expanded : String) : Project?
        wanted = Paths.canonical_file(expanded)
        registry.list.find { |candidate| Paths.canonical_file(candidate.db_path) == wanted }
      end

      private def self.active_fallback(registry : ProjectRegistry) : Selection
        if path = Paths.read_active_project
          if File.file?(path)
            # Same filesystem-identity match, and the same reason to prefer the registry's
            # spelling: the marker is written by whichever gori last opened a project, under
            # whatever form of `$GORI_HOME` that process was given.
            project_for_path = find_project_for_db(registry, path)
            return Selection.new(project_for_path.try(&.db_path) || path, project_for_path.try(&.name),
              project_for_path.try { |candidate| registry.slug_of(candidate) }, "active-tui",
              project_id: project_for_path.try { |candidate| registry.id_of(candidate) })
          end
        end
        if mru = ProjectRegistry.default_of(registry.list)
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
        # The project's registration when no workspace selected it (`--project`, the env var, the
        # MRU): `switch_project` reports `reg.workspace_of`, and `project_info` answered
        # `workspace_bound: false` for the same project bound the other way.
        Selection.new(project.db_path, project.name, registry.slug_of(project), source,
          workspace_root || registry.workspace_of(project), auto_created, project_id: registry.id_of(project))
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
