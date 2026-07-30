# `gori run project` — list/create/delete projects, or manage project-scoped config:
# scope rules, env vars ($KEY substitution), and host overrides.
module Gori
  module CLI
    module Run
      private def self.cmd_project(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when nil
          cmd_project_list(args)
        when "-h", "--help"
          print_project_help
        when "list"
          cmd_project_list(args[1..])
        when "create"
          cmd_project_create(args[1..])
        when "delete", "rm"
          cmd_project_delete(args[1..])
        when "scope"
          cmd_project_scope(args[1..])
        when "sandbox"
          cmd_project_sandbox(args[1..])
        when "env"
          cmd_project_env(args[1..])
        when "host-override", "host-overrides"
          cmd_project_host_override(args[1..])
        else
          # Flags only (e.g. --format json) → list projects
          if (s = sub) && s.starts_with?('-')
            cmd_project_list(args)
          else
            STDERR.puts "gori run project: unknown subcommand '#{sub}'"
            print_project_help
            exit 1
          end
        end
      end

      private def self.print_project_help : Nil
        puts <<-HELP
        gori run project — list/create/delete projects, or manage project-scoped config

        Usage: gori run project [<subcommand>] [options]

        Subcommands:
          list               List known projects (default when no subcommand)
          create <name>      Create (or reopen) a project by name
          delete|rm <name>   Delete a project and everything captured in it
          scope              Manage scope rules (list, add, delete, enable/disable)
          sandbox            Get/set the hard-containment sandbox gate (status, on, off)
          env                Manage project env vars ($KEY substitution)
          host-override      Manage host overrides (list, add, update, delete)

        Examples:
          gori run project --format json
          gori run project create "API test" --description="staging sweep"
          gori run project delete api-test --yes
          gori run project scope add --kind=include --type=host --pattern=api.example.com
          gori run project sandbox on
          gori run project env set TOKEN=secret
          gori run project host-override add --host=api.example.com --ip=10.0.0.1

        See 'gori run project <subcommand> --help' for more.
        HELP
      end

      private def self.cmd_project_list(args : Array(String)) : Nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project [list] [options]"
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project: missing value for #{f}" }
        end
        parser.parse(args)

        registry = ProjectRegistry.new(Paths.projects_dir)
        projects = registry.list
        if format == :json
          puts(JSON.build do |j|
            j.array do
              projects.each do |pr|
                j.object do
                  j.field "name", pr.name
                  j.field "id", registry.id_of(pr)
                  j.field "slug", registry.slug_of(pr)
                  j.field "db_path", pr.db_path
                  j.field "db_size", pr.db_size
                  j.field "last_modified", pr.last_modified.try(&.to_unix)
                  j.field "time", pr.last_modified.try(&.to_local.to_s("%Y-%m-%dT%H:%M:%S%:z"))
                end
              end
            end
          end)
        elsif projects.empty?
          STDERR.puts "no projects yet — capture some traffic (gori run capture / the TUI) first"
        else
          projects.each do |pr|
            ts = pr.last_modified.try(&.to_local.to_s("%Y-%m-%d %H:%M")) || "—"
            id = registry.id_of(pr) || "—"
            puts "#{pr.name.ljust(24)}  #{id.ljust(8)}  #{ts}  #{CLI::Output.human_size(pr.db_size)}"
          end
        end
      end

      # `gori run project create` — make a project without capturing into it first.
      # `gori run capture --project=NAME` already creates on demand, but that is the only
      # headless way to get one today: every other run subcommand aborts on an unknown
      # --project. This is the explicit, traffic-free door (CLI parity with MCP
      # create_project). Reopening by name is not an error — it mirrors both.
      private def self.cmd_project_create(args : Array(String)) : Nil
        description = ""
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project create <name> [options]\n\n" \
                     "Create a project, or reopen the existing one with that name."
          p.on("--description=TEXT", "Description stored in the project's settings") { |v| description = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project create: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project create: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project create: missing <name>" if positional.empty?
        abort "gori run project create: too many arguments (quote a name that contains spaces)" if positional.size > 1
        name = positional[0]

        registry = ProjectRegistry.new(Paths.projects_dir)
        project, created = create_project_entry(registry, name, description)

        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "name", project.name
              j.field "id", registry.id_of(project)
              j.field "slug", registry.slug_of(project)
              j.field "db_path", project.db_path
              j.field "created", created # false = reopened an existing same-name project
            end
          end)
        elsif created
          puts "Project #{project.name.inspect} created (#{project.db_path})."
        else
          puts "Project #{project.name.inspect} already exists — reopened (#{project.db_path})."
        end
      end

      # create_or_reopen rejects a name that slugifies to nothing (blank / punctuation-only)
      # with a Gori::Error, and it both makes the directory and opens the DB — so a full,
      # read-only or otherwise unusable projects root surfaces as File::Error/IO::Error or a
      # driver error. Every one of them becomes a clean `gori run project create:` message
      # (the TUI picker's safe_create rescues the same four).
      private def self.create_project_entry(registry : ProjectRegistry, name : String,
                                            description : String) : {Project, Bool}
        registry.create_or_reopen(name, description)
      rescue ex : Gori::Error
        abort "gori run project create: #{ex.message} (#{name.inspect})"
      rescue ex : File::Error | IO::Error
        abort "gori run project create: could not create project #{name.inspect}: #{ex.message}"
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run project create: could not initialize the database for #{name.inspect}: #{ex.message}"
      end

      # `gori run project delete` — remove a project directory and everything in it. Until
      # now this lived only in the TUI picker (confirm modal) and MCP delete_project
      # (dry-run + token). Irreversible, so the headless form keeps the same two steps:
      # without --yes it prints what would go and exits non-zero.
      private def self.cmd_project_delete(args : Array(String)) : Nil
        yes = false
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project delete|rm <name> [options]\n\n" \
                     "Permanently removes the project directory: captured flows, issues,\n" \
                     "notes, scope, everything. Without --yes it only previews the target.\n" \
                     "<name> matches a short id, id prefix, directory slug, or display name."
          p.on("--yes", "Actually delete (without it, nothing is removed)") { yes = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project delete: missing <name>" if positional.empty?
        abort "gori run project delete: too many arguments (expected one <name>)" if positional.size > 1
        name = positional[0]

        registry = ProjectRegistry.new(Paths.projects_dir)
        project = registry.find(name) || abort_unknown_project(registry, name)
        abort_ambiguous_project(registry, name) if ambiguous_name?(registry, name)
        print_delete_preview(registry, project, format) unless yes # NoReturn

        # Read the sidecars while they still exist — rm_rf takes them with the directory.
        id = registry.id_of(project)
        slug = registry.slug_of(project)
        begin
          registry.delete(project) # refuses while another live instance holds the capture lock
        rescue ex : Gori::Error
          abort "gori run project delete: #{ex.message}"
        rescue ex : File::Error | IO::Error
          abort "gori run project delete: could not remove #{project.dir}: #{ex.message}"
        end

        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "deleted", true
              j.field "name", project.name
              j.field "id", id
              j.field "slug", slug
              j.field "dir", project.dir
              j.field "db_path", project.db_path
            end
          end)
        else
          puts "Project #{project.name.inspect} deleted (#{project.dir})."
        end
      end

      private def self.abort_unknown_project(registry : ProjectRegistry, name : String) : NoReturn
        projects = registry.list
        have = projects.empty? ? "" : " (have: #{projects.map(&.name).join(", ")})"
        abort "gori run project delete: no project matching '#{name}'#{have}"
      end

      # Display names are deliberately NOT unique (two workspaces sharing a basename get the
      # same name, e.g. slugs `api` and `api-2`), and #find resolves a name to the
      # most-recently-active match. Good enough for a read; not for an rm_rf. Refuse and make
      # the caller name the slug or short id — which, being unique, resolve before the name
      # pass in #find, so an exact one of those is never called ambiguous.
      private def self.ambiguous_name?(registry : ProjectRegistry, name : String) : Bool
        q = name.strip.downcase
        projects = registry.list
        return false if projects.any? { |p| registry.slug_of(p).downcase == q || registry.id_of(p).try(&.downcase) == q }
        projects.count { |p| p.name.downcase == q } > 1
      end

      private def self.abort_ambiguous_project(registry : ProjectRegistry, name : String) : NoReturn
        q = name.strip.downcase
        candidates = registry.list.select { |p| p.name.downcase == q }
        listed = candidates.map { |p| "#{registry.slug_of(p)} (id #{registry.id_of(p) || "—"})" }.join(", ")
        abort "gori run project delete: '#{name}' matches #{candidates.size} projects — " \
              "delete by slug or short id instead: #{listed}"
      end

      # What --yes would destroy. Exits NON-ZERO: this path removed nothing, and a script
      # that forgot --yes must not read a 0 as "it's gone".
      private def self.print_delete_preview(registry : ProjectRegistry, project : Project, format : Symbol) : NoReturn
        flows, issues = project_object_counts(project)
        locked = capture_running?(project)
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "dry_run", true
              j.field "deleted", false
              j.field "name", project.name
              j.field "id", registry.id_of(project)
              j.field "slug", registry.slug_of(project)
              j.field "dir", project.dir
              j.field "db_path", project.db_path
              j.field "flows", flows
              j.field "issues", issues
              j.field "db_size", project.db_size
              j.field "disk_size", project.disk_size
              j.field "capture_lock_held", locked
            end
          end)
        else
          puts "Project:  #{project.name}  (id #{registry.id_of(project) || "—"}, slug #{registry.slug_of(project)})"
          puts "Dir:      #{project.dir}"
          puts "Flows:    #{flows || "—"}"
          puts "Issues:   #{issues || "—"}"
          puts "On disk:  #{CLI::Output.human_size(project.disk_size)}"
          puts "Capture:  #{locked ? "RUNNING in another gori instance" : "not running"}"
        end
        abort "gori run project delete: nothing deleted — re-run with --yes to remove #{project.dir}"
      end

      # Is another live instance capturing into this project? CaptureLock.held? probes by
      # ACQUIRING the lock (it creates the lock file and re-raises anything that is not
      # contention), so a project directory this user can read but not write would blow up a
      # command that promised to only look. Unknown reads as "not running" here; the delete
      # itself re-probes through ProjectRegistry#delete, which is where being wrong matters.
      private def self.capture_running?(project : Project) : Bool
        CaptureLock.held?(project.dir)
      rescue
        false
      end

      # Flow + issue counts for the delete preview, from a short-lived handle of its own.
      # Best-effort: a locked or corrupt DB reports nil rather than failing the preview
      # (mirrors MCP delete_project's dry run).
      private def self.project_object_counts(project : Project) : {Int64?, Int32?}
        return {nil, nil} unless File.exists?(project.db_path)
        store = Store.open(project.db_path, retention_flows: Store::RETENTION_UNLIMITED)
        begin
          {store.count, store.count_issues}
        ensure
          store.close
        end
      rescue
        {nil, nil}
      end

      private def self.cmd_project_scope(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "add"
          cmd_scope_add(args[1..])
        when "update", "edit"
          cmd_scope_update(args[1..])
        when "delete", "rm"
          cmd_scope_delete(args[1..])
        when "enable"
          cmd_scope_set_enabled(true, args[1..])
        when "disable"
          cmd_scope_set_enabled(false, args[1..])
        when "list"
          cmd_scope_list(args[1..])
        when nil
          cmd_scope_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_scope_list(args)
          else
            STDERR.puts "gori run project scope: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project scope [list options] | add | delete|rm | enable | disable"
            exit 1
          end
        end
      end

      private def self.cmd_scope_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project scope add --kind=include/exclude --type=host/string/regex --pattern=...\n" \
                     "  gori run project scope delete|rm <rule-id>\n" \
                     "  gori run project scope enable\n" \
                     "  gori run project scope disable"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "enabled", scope.enabled?
                j.field "rules" do
                  j.array do
                    scope.rules.each do |r|
                      j.object do
                        j.field "id", r.id
                        j.field "kind", r.kind
                        j.field "type", r.match_type
                        j.field "pattern", r.pattern
                      end
                    end
                  end
                end
              end
            end)
          else
            puts "Scope filtering: #{scope.enabled? ? "ENABLED" : "DISABLED"}"
            if scope.rules.empty?
              puts "No scope rules configured."
            else
              scope.rules.each do |r|
                puts "##{r.id}  #{r.kind.ljust(8)}  #{r.match_type.ljust(6)}  #{r.pattern}"
              end
            end
          end
        ensure
          store.close
        end
      end

      # Edit a rule in place (the TUI scope list's `e`). Without this the only fix for a typo'd
      # pattern was delete + re-add, which changes the rule's id and briefly drops it from the
      # gate that decides what traffic may be probed.
      private def self.cmd_scope_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        kind : String? = nil
        match_type : String? = nil
        pattern : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope update <id> [options]\n\n" \
                     "Change an existing scope rule. Every field keeps its current value unless\n" \
                     "you pass it, so you can edit just the pattern."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-kKIND", "--kind=KIND", "Rule kind: include|exclude") { |v| kind = v }
          p.on("-tTYPE", "--type=TYPE", "Match type: host|string|regex") { |v| match_type = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "Pattern to match") { |v| pattern = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project scope update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope update: missing value for #{f}" }
        end
        parser.parse(args)

        id_s = positional.first? || abort("gori run project scope update: <id> is required (see `gori run project scope list`)")
        id = id_s.to_i64? || abort("gori run project scope update: invalid rule id #{id_s.inspect}")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          existing = scope.rules.find { |r| r.id == id } ||
                     abort("gori run project scope update: no scope rule with id #{id}")
          # `kind`/`match_type`/`pattern` are captured by the OptionParser blocks, so Crystal
          # keeps them nilable and `x || fallback` does not narrow — force a String each.
          new_kind = (kind || existing.kind).to_s
          new_type = (match_type || existing.match_type).to_s
          new_pattern = (pattern.try(&.strip).presence || existing.pattern).to_s
          abort "gori run project scope update: invalid kind '#{new_kind}' (must be include or exclude)" unless new_kind.in?(Scope::KINDS)
          abort "gori run project scope update: invalid type '#{new_type}' (must be host, string, or regex)" unless new_type.in?(Scope::TYPES)
          if err = Scope.validation_error(new_type, new_pattern)
            abort "gori run project scope update: #{err}"
          end
          unless store.update_scope_rule(id, new_kind, new_type, new_pattern)
            abort "gori run project scope update: rule NOT updated (store busy or unwritable); it is unchanged and still gates traffic"
          end
          puts "Scope rule ##{id} updated: #{new_kind} #{new_type} #{new_pattern}"
          # Re-read: the write went through the store, not this Scope instance, so the
          # in-memory rule list is one edit stale.
          warn_scope_blackhole(Scope.load(store), "gori run project scope update")
        ensure
          store.close
        end
      end

      private def self.cmd_scope_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        kind = "include"
        match_type = "host"
        pattern : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope add [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-kKIND", "--kind=KIND", "Rule kind: include|exclude (default: include)") { |v| kind = v }
          p.on("-tTYPE", "--type=TYPE", "Match type: host|string|regex (default: host)") { |v| match_type = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "Pattern to match (required)") { |v| pattern = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope add: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project scope add: --pattern is required" if (pat = pattern).nil? || pat.empty?
        abort "gori run project scope add: invalid kind '#{kind}' (must be include or exclude)" unless kind.in?(Scope::KINDS)
        abort "gori run project scope add: invalid type '#{match_type}' (must be host, string, or regex)" unless match_type.in?(Scope::TYPES)
        if err = Scope.validation_error(match_type, pat.strip)
          abort "gori run project scope add: #{err}"
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.add(kind, match_type, pat)
            store.close
            abort "gori run project scope add: failed to add rule (duplicate, empty, or invalid)"
          end
          puts "Scope rule added successfully."
        ensure
          store.close
        end
      end

      # A scope WRITE that leaves Sandbox holding an empty allowlist turns the proxy into a
      # black hole — every captured request refused. `sandbox on` already warns on its own
      # edge (see cmd_sandbox), but the scope-rule paths never re-asked, so deleting the
      # last include printed a plain "deleted successfully" and the next capture died
      # silently. Same question, same wording, now on both edges.
      private def self.warn_scope_blackhole(scope : Scope, prefix : String) : Nil
        return unless scope.sandbox? && scope.include_count == 0
        STDERR.puts "#{prefix}: warning — the sandbox is ON and the scope now has no include " \
                    "rules, so ALL captured traffic is blocked until you add one " \
                    "(gori run project scope add ...)"
      end

      private def self.cmd_scope_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope delete|rm <rule-id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope delete: missing value for #{f}" }
        end

        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)

        abort "gori run project scope delete: missing <rule-id>" if positional.empty?
        abort "gori run project scope delete: too many arguments (expected one <rule-id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project scope delete: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.rules.any? { |r| r.id == id }
            store.close
            abort "gori run project scope delete: no scope rule with id #{id}"
          end
          scope.remove(id)
          puts "Scope rule ##{id} deleted successfully."
          warn_scope_blackhole(scope, "gori run project scope delete")
        ensure
          store.close
        end
      end

      private def self.cmd_scope_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        action = enable ? "enable" : "disable"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope #{action} [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope #{action}: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          # enable/disable return false when the write didn't commit (store busy/locked/
          # closing, e.g. a live capture holds the writer): don't claim success then.
          ok = enable ? scope.enable : scope.disable
          unless ok
            store.close
            abort "gori run project scope #{enable ? "enable" : "disable"}: project is busy (write did not commit) — try again"
          end
          puts enable ? "Scope filtering enabled." : "Scope filtering disabled."
        ensure
          store.close
        end
      end

      # `gori run project sandbox` — get/set the HARD-CONTAINMENT sandbox gate (Scope's
      # blocking policy, distinct from the ⇧S display lens). Until now this could only be
      # toggled from the interactive TUI (Project NETWORK pane); this is the headless
      # bootstrap so a CI / authorized-testing run can enable containment without the UI.
      private def self.cmd_project_sandbox(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "on", "enable"
          cmd_sandbox_set(true, args[1..])
        when "off", "disable"
          cmd_sandbox_set(false, args[1..])
        when "status"
          cmd_sandbox_status(args[1..])
        when nil
          cmd_sandbox_status(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_sandbox_status(args)
          else
            STDERR.puts "gori run project sandbox: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project sandbox [status options] | on|enable | off|disable"
            exit 1
          end
        end
      end

      private def self.cmd_sandbox_status(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project sandbox [options]\n\n" \
                     "Show the hard-containment sandbox gate: when ON, the capture proxy forwards\n" \
                     "ONLY requests the scope allows and BLOCKS everything else (see\n" \
                     "'gori run project scope'). Or set it:\n" \
                     "  gori run project sandbox on|enable\n" \
                     "  gori run project sandbox off|disable"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project sandbox: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project sandbox: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "sandbox", scope.sandbox?
              end
            end)
          else
            puts "Sandbox: #{scope.sandbox? ? "ENABLED" : "DISABLED"}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_sandbox_set(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        action = enable ? "on" : "off"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project sandbox #{action} [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project sandbox #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project sandbox #{action}: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          # Enabling with NO include rule turns the proxy into a black hole (every captured
          # request blocked). The TUI danger-confirms this; a headless run can't prompt, so
          # it warns and proceeds (the whole point is to bootstrap containment for CI).
          if enable && scope.include_count == 0
            STDERR.puts "gori run project sandbox on: warning — the scope has no include rules, " \
                        "so the sandbox will BLOCK ALL captured traffic until you add one " \
                        "(gori run project scope add ...)"
          end
          # Scope's sandbox setters persist through the SAME settings-table write the TUI uses
          # (set_sandbox_unlocked → Store#set_setting) but return Nil, so confirm the flag
          # committed by reading it back — a busy/locked store must not report success
          # (mirrors scope enable/disable's committed check).
          enable ? scope.enable_sandbox : scope.disable_sandbox
          unless store.setting(Scope::SETTING_SANDBOX) == (enable ? "1" : "0")
            store.close
            abort "gori run project sandbox #{action}: project is busy (write did not commit) — try again"
          end
          puts enable ? "Sandbox enabled." : "Sandbox disabled."
        ensure
          store.close
        end
      end

      private def self.cmd_project_env(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "set"
          cmd_env_set(args[1..])
        when "delete", "rm"
          cmd_env_delete(args[1..])
        when "list"
          cmd_env_list(args[1..])
        when nil
          cmd_env_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_env_list(args)
          else
            STDERR.puts "gori run project env: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project env [list options] | set KEY=value | delete|rm KEY"
            exit 1
          end
        end
      end

      private def self.cmd_env_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env [options]\n\n" \
                     "List project env vars used for $KEY substitution in outbound requests.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project env set KEY=value\n" \
                     "  gori run project env set KEY value\n" \
                     "  gori run project env delete|rm KEY"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project env: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars
          if format == :json
            puts(JSON.build do |j|
              j.array do
                vars.each do |(key, val)|
                  j.object do
                    j.field "key", key
                    j.field "value", val
                  end
                end
              end
            end)
          elsif vars.empty?
            STDERR.puts "no project env vars configured"
          else
            vars.each { |(key, val)| puts "#{key}=#{val}" }
          end
        ensure
          store.close
        end
      end

      private def self.cmd_env_set(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env set KEY=value [options]\n" \
                     "       gori run project env set KEY value [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project env set: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env set: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project env set: missing KEY=value (or KEY value)" if positional.empty?
        line = positional.join(' ')
        parsed = Env.parse_line(line)
        abort "gori run project env set: invalid KEY (use [A-Za-z_][A-Za-z0-9_]*)" unless parsed
        key, val = parsed

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars.dup
          if idx = vars.index { |(k, _)| k == key }
            vars[idx] = {key, val}
          else
            vars << {key, val}
          end
          unless Env.save_project(store, vars)
            store.close
            abort "gori run project env set: project is busy (write did not commit) — try again"
          end
          puts "Env var #{key} set."
        ensure
          store.close
        end
      end

      private def self.cmd_env_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env delete|rm KEY [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project env delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project env delete: missing KEY" if positional.empty?
        abort "gori run project env delete: too many arguments (expected one KEY)" if positional.size > 1
        key = positional[0]
        abort "gori run project env delete: invalid KEY '#{key}'" unless Env.valid_key?(key)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars.dup
          before = vars.size
          vars.reject! { |(k, _)| k == key }
          if vars.size == before
            store.close
            abort "gori run project env delete: no env var named '#{key}'"
          end
          unless Env.save_project(store, vars)
            store.close
            abort "gori run project env delete: project is busy (write did not commit) — try again"
          end
          puts "Env var #{key} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_project_host_override(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "add"
          cmd_host_override_add(args[1..])
        when "update"
          cmd_host_override_update(args[1..])
        when "delete", "rm"
          cmd_host_override_delete(args[1..])
        when "list"
          cmd_host_override_list(args[1..])
        when nil
          cmd_host_override_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_host_override_list(args)
          else
            STDERR.puts "gori run project host-override: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project host-override [list options] | add | update | delete|rm"
            exit 1
          end
        end
      end

      private def self.cmd_host_override_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override [options]\n\n" \
                     "List project host overrides (/etc/hosts-style: dial IP for hostname).\n" \
                     "Project overrides win over global Settings: Hostnames on collision.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project host-override add --host=api.example.com --ip=10.0.0.1\n" \
                     "  gori run project host-override add 10.0.0.1 api.example.com\n" \
                     "  gori run project host-override update <id> --host=... --ip=...\n" \
                     "  gori run project host-override delete|rm <id>"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project host-override: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.array do
                ov.entries.each do |e|
                  j.object do
                    j.field "id", e.id
                    j.field "host", e.host
                    j.field "ip", e.ip
                  end
                end
              end
            end)
          elsif ov.entries.empty?
            STDERR.puts "no host overrides configured"
          else
            ov.entries.each do |e|
              puts "##{e.id}  #{e.ip.ljust(15)}  #{e.host}"
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        ip : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override add --host=HOST --ip=IP [options]\n" \
                     "       gori run project host-override add IP HOST [options]\n\n" \
                     "Add a project host override (dial IP for HOST; SNI/Host header unchanged)."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "Hostname to override (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "IPv4/IPv6 literal to dial") { |v| ip = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override add: missing value for #{f}" }
        end
        parser.parse(args)

        # Flags win when both are given; otherwise accept /etc/hosts-style "IP HOST".
        pair =
          if (h_flag = host) && (i_flag = ip)
            {h_flag, i_flag}
          elsif host || ip
            # A lone --host/--ip is ambiguous next to positional args, which would otherwise
            # silently win and drop the flag — require the pair to be fully one form or the other.
            abort "gori run project host-override add: give BOTH --host and --ip, or the positional IP HOST form (not a mix)"
          else
            abort "gori run project host-override add: need --host and --ip, or positional IP HOST" if positional.empty?
            parsed = HostOverrides.parse_line(positional.join(' '))
            abort "gori run project host-override add: invalid entry (expected IP HOST; IP must be a literal)" unless parsed
            parsed
          end
        h, i = pair
        abort "gori run project host-override add: invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.add(h, i)
            store.close
            abort "gori run project host-override add: failed to add override (duplicate host, empty, or invalid)"
          end
          entry = ov.entries.find { |e| e.host == h.strip.downcase }
          if e = entry
            puts "Host override ##{e.id} added: #{e.ip} → #{e.host}"
          else
            puts "Host override added: #{i} → #{h.strip.downcase}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        ip : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override update <id> --host=HOST --ip=IP [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "New hostname (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "New IPv4/IPv6 literal to dial") { |v| ip = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override update: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project host-override update: missing <id>" if positional.empty?
        abort "gori run project host-override update: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override update: invalid id '#{positional[0]}'")
        h = host
        i = ip
        abort "gori run project host-override update: --host and --ip are both required" unless h && i
        abort "gori run project host-override update: invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override update: no override with id #{id}"
          end
          unless ov.update(id, h, i)
            store.close
            abort "gori run project host-override update: failed (duplicate host, empty, or invalid)"
          end
          puts "Host override ##{id} updated: #{i} → #{h.strip.downcase}"
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override delete|rm <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project host-override delete: missing <id>" if positional.empty?
        abort "gori run project host-override delete: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override delete: invalid id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override delete: no override with id #{id}"
          end
          unless ov.remove(id)
            store.close
            abort "gori run project host-override delete: project is busy (write did not commit) — try again"
          end
          puts "Host override ##{id} deleted."
        ensure
          store.close
        end
      end
    end
  end
end
