# `gori run project` — list/create/delete projects, or manage project-scoped config:
# scope rules, env vars ($ENV.KEY substitution, or $KEY under the legacy bare syntax), and
# host overrides.
module Gori
  module CLI
    module Run
      @[Subcommand("project", help: [
        {"project [list]", "List projects holding captured traffic (--all for every one)"},
        {"project create", "Create (or reopen) a project by name"},
        {"project switch", "Pin the default project for every --project-less command (--clear to unpin)"},
        {"project export", "Export a project to a portable archive"},
        {"project import", "Import a project archive as a new project"},
        {"project delete", "Delete a project and everything captured in it"},
        {"project scope", "Manage scope rules (list, add, update, delete, enable/disable)"},
        {"project sandbox", "Get/set the hard-containment sandbox gate (status, on, off)"},
        {"project env", "Manage project env vars ($ENV.KEY substitution; bare syntax: $KEY)"},
        {"project host-override", "Manage host overrides (list, add, update, delete)"},
        {"project network", "Get/set the project's own network settings (net.*: upstream proxy, timeouts, capture cap, bind)"},
      ])]
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
        when "switch", "use"
          cmd_project_switch(args[1..])
        when "export", "import"
          cmd_project_archive(args)
        when "delete", "rm"
          cmd_project_delete(args[1..])
        when "scope", "sandbox", "env", "host-override", "host-overrides", "network", "net"
          cmd_project_config(sub, args[1..])
        else
          cmd_project_other(sub, args)
        end
      end

      # The project-scoped configuration verbs, one dispatch of their own.
      private def self.cmd_project_config(sub : String, args : Array(String)) : Nil
        case sub
        when "scope"          then cmd_project_scope(args)
        when "sandbox"        then cmd_project_sandbox(args)
        when "env"            then cmd_project_env(args)
        when "network", "net" then cmd_project_network(args)
        else                       cmd_project_host_override(args)
        end
      end

      private def self.cmd_project_archive(args : Array(String)) : Nil
        case args.first?
        when "export" then cmd_project_export(args[1..])
        when "import" then cmd_project_import(args[1..])
        else               abort "gori run project: expected export or import"
        end
      end

      # Flags only (e.g. `--format json`) → list projects; any other word is refused.
      private def self.cmd_project_other(sub : String, args : Array(String)) : Nil
        if sub.starts_with?('-')
          cmd_project_list(args)
        else
          abort unknown_verb_message("gori run project", sub,
            %w[list create switch use export import delete rm scope sandbox env host-override network net])
        end
      end

      private def self.print_project_help : Nil
        puts <<-HELP
          gori run project — list/create/delete projects, or manage project-scoped config

          Usage: gori run project [<subcommand>] [options]

          Subcommands:
            list               List projects holding captured traffic (default when no subcommand);
                               --query=TEXT narrows to the ones whose name, slug, short id
                               or bound workspace path contains TEXT
            create <name>      Create (or reopen) a project by name
            switch <name>      Pin the project every --project-less command reads (--clear unpins;
                               no name prints the default). GORI_PROJECT=<name> wins over the pin
            export <name>      Write a portable project archive (-o PATH)
            import <archive>   Import a project archive as a new project
            delete|rm <name>   Delete a project and everything captured in it
            scope              Manage scope rules (list, add, update, delete, enable/disable)
            sandbox            Get/set the hard-containment sandbox gate (status, on, off)
            env                Manage project env vars ($ENV.KEY substitution; bare syntax: $KEY)
            host-override      Manage host overrides (list, add, update, delete)
            network            Get/set the project's own network settings (net.*): upstream proxy
                               and credentials, destination host, timeouts, capture cap, bind

          Examples:
            gori run project --format json
            gori run project list --all
            gori run project list --query=acme
            gori run project create "API test" --description="staging sweep"
            gori run project delete api-test --yes
            gori run project scope add --kind=include --type=host --pattern=api.example.com
            gori run project sandbox on
            gori run project env set TOKEN=secret
            gori run project host-override add --host=api.example.com --ip=10.0.0.1
            gori run project network set upstream_proxy=http://proxy.corp.example:3128
            gori run project network

          See 'gori run project <subcommand> --help' for more.
          HELP
      end

      # One row of `gori run project list`: the project (with the sidecars the row prints
      # already read), what the census found in it, and the two "this is the one your
      # commands are using" facts that pin it into the default listing however empty it is.
      record ProjectListRow,
        entry : ProjectRegistry::Entry,
        flows : Int64?,
        description : String?,
        current : Bool,
        tui_active : Bool do
        def project : Project
          entry.project
        end

        # Nothing was ever captured here. `flows == nil` is the census failing to read the
        # db, which is emphatically NOT the same answer — see `Store.captured_flows`.
        def empty? : Bool
          flows == 0
        end

        # Kept in the default listing no matter what: hiding the project a `--project`-less
        # `gori run` reads, or the one the TUI has open, would answer "which project am I
        # on?" with silence — which is the confusion this whole listing exists to end.
        def pinned? : Bool
          current || tui_active
        end
      end

      # Which projects the default listing prints, and why each is marked.
      #
      # An operator working across worktrees accumulates a project per checkout — hundreds
      # of them, each holding nothing but a schema — and `list` dumping all of them buries
      # the two or three that hold captured traffic. So the default hides the EMPTY ones:
      # zero captured flows, judged by counting rows and NOT by db_size, because a project
      # created a second ago is the same 4 kB as a leftover from March and the operator
      # very much wants to see the one they just made.
      #
      # `default_db` is passed IN rather than taken as the head of `counted`, because
      # `--query` narrows what reaches here: the project a `--project`-less `gori run` reads
      # is the head of the WHOLE registry, and deriving it from a filtered list would move
      # the `◆` marker onto whatever the filter happened to leave first — the listing's one
      # answer to "which project am I on?", quietly pointing at the wrong project.
      #
      # Pure and separately testable: the census and `$GORI_HOME` are the caller's problem.
      private def self.project_list_rows(counted : Array({ProjectRegistry::Entry, Store::ProjectCensus}),
                                         default_db : String?, active_db : String?,
                                         all : Bool) : Array(ProjectListRow)
        wanted = active_db.try { |path| Paths.canonical_file(path) }
        rows = counted.map do |entry, census|
          ProjectListRow.new(entry, census.flows, census.description,
            current: !default_db.nil? && entry.project.db_path == default_db,
            tui_active: !wanted.nil? && Paths.canonical_file(entry.project.db_path) == wanted)
        end
        all ? rows : rows.select { |row| row.pinned? || !row.empty? }
      end

      private def self.cmd_project_list(args : Array(String)) : Nil
        format = :text
        all = false
        query = nil.as(String?)
        leftover = parse_args(args, "gori run project") do |p|
          p.banner = "Usage: gori run project [list] [options]"
          p.on("--all", "Include projects with nothing captured in them (hidden by default)") { all = true }
          p.on("--query=TEXT", "Keep only projects whose name, dir slug, short id or bound " \
                               "workspace path contains TEXT (case-insensitive)") { |v| query = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refuse_list_leftovers(leftover, "project",
          "list, create, switch, export, import, delete/rm, scope, sandbox, env, network, host-override")

        registry = ProjectRegistry.new(Paths.projects_dir)
        entries = registry.entries
        # BEFORE the census, and that ordering is the point: `Store.captured_flows` opens
        # every project's database, while everything `--query` reads is a sidecar file
        # beside it. On a host with a project per worktree, `--query=acme` is now one
        # database open instead of hundreds.
        needle = ProjectRegistry.needle(query)
        matched = needle ? entries.select(&.matches?(needle)) : entries
        # ONE pass per project, carrying both things the listing prints — see
        # `Store.project_census`: the description used to need a second open, which is why
        # nothing headless ever reported it.
        counted = matched.map { |entry| {entry, Store.project_census(entry.project.db_path)} }
        # The default is resolved over the WHOLE registry, before `--query` narrowed anything —
        # see `project_list_rows` — and by the same rule every command uses (`default_project`),
        # so a `GORI_PROJECT` or `project switch` pin moves the `◆` with it. A pin that names
        # nothing marks no row and says so, rather than marking the project it would NOT read.
        default_db = case chosen = default_project(registry, ENV[DEFAULT_PROJECT_ENV]?, read_default_pin)
                     in Tuple then chosen[0].db_path
                     in String
                       STDERR.puts "gori run project: #{chosen}"
                       nil
                     in Nil then nil
                     end
        rows = project_list_rows(counted, default_db, Paths.read_active_project, all)
        hidden = matched.size - rows.size
        if format == :json
          puts(JSON.build do |j|
            j.array do
              rows.each do |row|
                pr = row.project
                j.object do
                  j.field "name", pr.name
                  j.field "id", row.entry.id
                  j.field "slug", row.entry.slug
                  j.field "db_path", pr.db_path
                  j.field "db_size", pr.db_size
                  # The fourth thing `--query` matches on, so a consumer filtering the same
                  # way has the field to do it with rather than a match it cannot explain.
                  j.field "workspace", row.entry.workspace
                  j.field "last_modified", pr.last_modified.try(&.to_unix)
                  j.field "time", pr.last_modified.try { |t| LocalTime.of(t).to_s("%Y-%m-%dT%H:%M:%S%:z") }
                  j.field "flows", row.flows
                  # What the project is FOR, as `project create --description` and MCP
                  # `create_project` store it. Written by this very command and readable
                  # nowhere headless until now — MCP `project_info` is its other reader.
                  j.field "description", row.description
                  j.field "current", row.current
                  j.field "tui_active", row.tui_active
                end
              end
            end
          end)
        elsif entries.empty?
          STDERR.puts "no projects yet — capture some traffic (gori run capture / the TUI) first"
        else
          rows.each do |row|
            pr = row.project
            ts = pr.last_modified.try { |t| LocalTime.of(t).to_s("%Y-%m-%d %H:%M") } || "—"
            id = row.entry.id || "—"
            flows = row.flows.try(&.to_s) || "?"
            puts "#{project_row_marker(row)} #{CLI::Output.pad(terminal_project_name(pr.name), 24)}  #{id.ljust(8)}  #{ts}  " \
                 "#{CLI::Output.human_size(pr.db_size).rjust(8)}  #{flows.rjust(6)} flows"
          end
        end
        # On STDERR in BOTH formats, so a `--format json` consumer's pipe stays a clean
        # array while the operator still learns why the list is short — the readings that
        # would otherwise send them to `create` for a project they already have.
        # `needle && query`, not `query`: a blank `--query=` narrowed nothing, so the notes
        # must not talk about a filter — while the sentences they DO print quote the
        # operator's own spelling, which only the raw string still has.
        project_list_notes(needle && query, entries, matched, rows, hidden, default_db).each do |line|
          STDERR.puts "gori run project list: #{line}"
        end
      end

      # What a shortened listing owes the operator, in the order it is worth saying. Three
      # absences, each of which reads as a finding about the host if left unsaid: a `--query`
      # that matched nothing is not "you have no projects", the empty-hiding lens still needs
      # its `--all` way out, and `--query` — unlike that lens, which PINS the row — can filter
      # out the very project the operator's other commands read, taking the `◆` marker that is
      # this listing's whole answer to "which project am I on?" with it.
      #
      # `query` is the operator's spelling of a narrowing that ACTUALLY narrowed, or nil.
      private def self.project_list_notes(query : String?, entries : Array(ProjectRegistry::Entry),
                                          matched : Array(ProjectRegistry::Entry),
                                          rows : Array(ProjectListRow), hidden : Int32,
                                          default_db : String?) : Array(String)
        notes = [] of String
        return notes if entries.empty?
        if query && matched.empty?
          notes << "no project matched --query=#{query} — #{entries.size} " \
                   "project#{entries.size == 1 ? "" : "s"} on this host; --query is a " \
                   "case-insensitive substring of the name, dir slug, short id or workspace path"
        elsif hidden >= 1
          notes << "#{hidden} empty project#{hidden == 1 ? "" : "s"} hidden " \
                   "(nothing captured) — pass --all to list every project"
        end
        # Only when something DID match: after "no project matched", naming the default as
        # another thing the query excluded is the same sentence twice.
        if query && !matched.empty? && !rows.any?(&.current) &&
           (default = entries.find { |e| e.project.db_path == default_db })
          notes << "the project a --project-less run reads (#{default.slug}) does not match --query=#{query}"
        end
        notes
      end

      # Project names can come from older `.name` sidecars, including ones written before the
      # registry rejected controls. Keep every human-facing CLI rendering safe while leaving
      # JSON values intact for scripts.
      private def self.terminal_project_name(name : String, *, quoted : Bool = false) : String
        safe = CLI::Output.term_safe(name)
        quoted ? safe.inspect : safe
      end

      # The leading glyph naming why a row is pinned. `◆` is the project a `gori run` with
      # no `--project` reads; `◇` is the one the TUI last opened, shown only when the two
      # have drifted apart (they usually have not — opening a project in the TUI makes it
      # the most-recently-active one).
      private def self.project_row_marker(row : ProjectListRow) : String
        return "◆" if row.current
        row.tui_active ? "◇" : " "
      end

      # `gori run project create` — make a project without capturing into it first.
      # `gori run capture --project=NAME` already creates on demand, but that is the only
      # headless way to get one today: every other run subcommand aborts on an unknown
      # --project. This is the explicit, traffic-free door (CLI parity with MCP
      # create_project). Reopening by name is not an error — it mirrors both.
      private def self.cmd_project_create(args : Array(String)) : Nil
        description = ""
        format = :text

        positional = parse_args(args, "gori run project create") do |p|
          p.banner = "Usage: gori run project create <name> [options]\n\n" \
                     "Create a project, or reopen the existing one with that name."
          p.on("--description=TEXT", "Description stored in the project's settings") { |v| description = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

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
          puts "Project #{terminal_project_name(project.name, quoted: true)} created (#{project.db_path})."
        else
          puts "Project #{terminal_project_name(project.name, quoted: true)} already exists — reopened (#{project.db_path})."
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
        abort "gori run project create: #{ex.message} (#{terminal_project_name(name, quoted: true)})"
      rescue ex : File::Error | IO::Error
        abort "gori run project create: could not create project #{terminal_project_name(name, quoted: true)}: #{ex.message}"
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run project create: could not initialize the database for #{terminal_project_name(name, quoted: true)}: #{ex.message}"
      end

      # Export first makes a WAL-safe snapshot, then shows the sensitive-data inventory before
      # writing the archive. Existing destinations require an explicit --force.
      private def self.cmd_project_export(args : Array(String)) : Nil
        output = nil.as(String?)
        force = false
        positional = parse_args(args, "gori run project export") do |p|
          p.banner = "Usage: gori run project export <name> -o PATH [--force]\n\n" \
                     "Snapshot a project database into one portable .gori archive."
          p.on("-o PATH", "--output=PATH", "Write the archive to PATH") { |v| output = v }
          p.on("--force", "Replace an existing destination file") { force = true }
        end
        abort "gori run project export: missing <name>" if positional.empty?
        abort "gori run project export: too many arguments (expected one <name>)" if positional.size > 1
        output_path = output.try(&.strip.presence) || abort "gori run project export: missing -o PATH"

        registry = ProjectRegistry.new(Paths.projects_dir)
        project = begin
          registry.find(positional.first)
        rescue ex : ProjectRegistry::Ambiguous
          abort "gori run project export: #{ex.message}"
        end
        abort "gori run project export: no project matching '#{terminal_project_name(positional.first)}'" unless project

        prepared = begin
          ProjectArchive.prepare_export(project)
        rescue ex : Gori::Error
          abort "gori run project export: #{ex.message}"
        rescue ex : File::Error | IO::Error | DB::Error | SQLite3::Exception
          abort "gori run project export: could not snapshot #{terminal_project_name(project.name, quoted: true)}: #{ex.message}"
        end
        begin
          STDERR.puts "gori run project export: #{terminal_project_name(project.name, quoted: true)} — " \
                      "#{ProjectArchive.disclosure(prepared.inventory)}"
          destination = begin
            prepared.write(output_path, overwrite: force)
          rescue ex : ProjectArchive::DestinationExists
            prepared.close
            abort "gori run project export: #{ex.message} (use --force to replace it)"
          rescue ex : Gori::Error
            prepared.close
            abort "gori run project export: #{ex.message}"
          rescue ex : File::Error | IO::Error | DB::Error | SQLite3::Exception
            prepared.close
            abort "gori run project export: could not write archive: #{ex.message}"
          end
          puts "Project #{terminal_project_name(project.name, quoted: true)} exported to #{destination}."
        ensure
          prepared.close
        end
      end

      # An import never reopens or overwrites an existing project. --name gives the imported
      # copy a different display name when the archive came from this same registry.
      private def self.cmd_project_import(args : Array(String)) : Nil
        name = nil.as(String?)
        positional = parse_args(args, "gori run project import") do |p|
          p.banner = "Usage: gori run project import <archive.gori> [--name NEW]\n\n" \
                     "Validate and register a portable project archive."
          p.on("--name=NAME", "Display name for the imported project (default: archive name)") { |v| name = v }
        end
        abort "gori run project import: missing <archive>" if positional.empty?
        abort "gori run project import: too many arguments (expected one <archive>)" if positional.size > 1

        prepared = begin
          ProjectArchive.prepare_import(positional.first)
        rescue ex : Gori::Error
          abort "gori run project import: #{ex.message}"
        rescue ex : File::Error | IO::Error | DB::Error | SQLite3::Exception
          abort "gori run project import: could not read archive: #{ex.message}"
        end
        begin
          STDERR.puts "gori run project import: #{terminal_project_name(prepared.manifest.project_name, quoted: true)} — " \
                      "#{ProjectArchive.disclosure(prepared.inventory)}"
          project = begin
            prepared.import_into(ProjectRegistry.new(Paths.projects_dir), name)
          rescue ex : Gori::Error
            prepared.close
            abort "gori run project import: #{import_error_message(ex.message || "", name)}"
          rescue ex : File::Error | IO::Error
            prepared.close
            abort "gori run project import: could not register project: #{ex.message}"
          end
          puts "Project #{terminal_project_name(project.name, quoted: true)} imported (#{project.db_path})."
        ensure
          prepared.close
        end
      end

      # The registry's refusal, with the flag that resolves a name clash named (#1389). The
      # sentence ("… choose another name") is shared with the TUI and MCP, which have their own
      # ways to pick one, so the CLI's spelling of "another name" is added here, not there —
      # and only when the operator has not already passed `--name`.
      def self.import_error_message(message : String, name : String?) : String
        return message unless name.nil? && message.includes?("choose another name")
        "#{message} (pass --name NEW to import it under another)"
      end

      # `gori run project delete` — remove a project directory and everything in it. Until
      # now this lived only in the TUI picker (confirm modal) and MCP delete_project
      # (dry-run + token). Irreversible, so the headless form keeps the same two steps:
      # without --yes it prints what would go and exits non-zero.
      private def self.cmd_project_delete(args : Array(String)) : Nil
        yes = false
        format = :text

        positional = parse_args(args, "gori run project delete") do |p|
          p.banner = "Usage: gori run project delete|rm <name> [options]\n\n" \
                     "Permanently removes the project directory: captured flows, issues,\n" \
                     "notes, scope, everything. Without --yes it only previews the target.\n" \
                     "<name> matches a short id, id prefix, directory slug, or display name."
          p.on("--yes", "Actually delete (without it, nothing is removed)") { yes = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        abort "gori run project delete: missing <name>" if positional.empty?
        abort "gori run project delete: too many arguments (expected one <name>)" if positional.size > 1
        name = positional[0]

        registry = ProjectRegistry.new(Paths.projects_dir)
        project = begin
          registry.find(name)
        rescue ex : ProjectRegistry::Ambiguous
          # Display names are deliberately NOT unique, and `#find` now refuses a name that
          # addresses two projects on every surface (#1163) — the rule this command used to
          # keep for itself, since a guess is not good enough for an rm_rf.
          abort "gori run project delete: #{ex.message}"
        end
        project ||= abort_unknown_project(registry, name)
        print_delete_preview(registry, project, format) unless yes # NoReturn

        # Read the sidecars while they still exist — rm_rf takes them with the directory.
        id = registry.id_of(project)
        slug = registry.slug_of(project)
        was_default = default_pinned?(registry, project)
        begin
          registry.delete(project) # refuses while another live instance holds the capture lock
        rescue ex : Gori::Error
          abort "gori run project delete: #{ex.message}"
        rescue ex : File::Error | IO::Error
          abort "gori run project delete: could not remove #{project.dir}: #{ex.message}"
        end
        # The pin named the project that is now gone (#1387): clear it rather than leave every
        # later command refusing a pin that can never resolve again.
        File.delete?(default_pin_path) rescue nil if was_default

        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "deleted", true
              j.field "name", project.name
              j.field "id", id
              j.field "slug", slug
              j.field "dir", project.dir
              j.field "db_path", project.db_path
              j.field "unpinned_default", true if was_default
            end
          end)
        else
          puts "Project #{terminal_project_name(project.name, quoted: true)} deleted (#{project.dir})."
          STDERR.puts "gori run project delete: it was the pinned default project — the pin is cleared " \
                      "(the default is the most recently active project again)" if was_default
        end
      end

      private def self.abort_unknown_project(registry : ProjectRegistry, name : String) : NoReturn
        projects = registry.list
        have = projects.empty? ? "" : " (have: #{projects.map { |project| terminal_project_name(project.name) }.join(", ")})"
        abort "gori run project delete: no project matching '#{terminal_project_name(name)}'#{have}"
      end

      # What --yes would destroy. Exits NON-ZERO: this path removed nothing, and a script
      # that forgot --yes must not read a 0 as "it's gone".
      #
      # BOTH guards `ProjectRegistry#delete` applies, not only the capture lock. Reporting
      # just that one, the preview said "Capture: not running" and "re-run with --yes" for a
      # project an MCP server merely had OPEN — and `--yes` then refused it with "project is
      # open in another gori instance — close it there first". The preview exists to describe
      # the delete about to happen, so it must not promise one the confirmed call declines.
      # MCP's dry run already reports both (`open_in_another_instance`), and the TUI picker
      # splits the blocked targets off before it offers the confirm at all; this is the same
      # pairing at the surface that missed it.
      #
      # After `project_object_counts`, which opens and closes a read-only handle of its own:
      # probing while that handle is alive would find OUR OWN lock and report every project
      # as held by a peer.
      private def self.print_delete_preview(registry : ProjectRegistry, project : Project, format : Symbol) : NoReturn
        flows, issues = project_object_counts(project)
        locked = capture_running?(project)
        open_elsewhere = OpenLock.in_use?(project.db_path)
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
              # NULL is a third answer, not a missing one: the probe itself can fail (see
              # `capture_running?`), and reporting that as `false` is the same lie as
              # reporting it as "not held" — `deletable` below folds it in.
              j.field "capture_lock_held", locked
              j.field "open_in_another_instance", open_elsewhere
              # One field for "would --yes actually remove this", so a script does not have to
              # re-derive the refusal rule from the two locks beside it.
              j.field "deletable", locked == false && !open_elsewhere
            end
          end)
        else
          puts "Project:  #{terminal_project_name(project.name)}  (id #{registry.id_of(project) || "—"}, slug #{registry.slug_of(project)})"
          puts "Dir:      #{project.dir}"
          puts "Flows:    #{flows || "—"}"
          puts "Issues:   #{issues || "—"}"
          puts "On disk:  #{CLI::Output.human_size(project.disk_size)}"
          puts "Capture:  #{capture_line(locked)}"
          puts "Open:     #{open_elsewhere ? "HELD by another gori instance (an MCP server, a second TUI, …)" : "no other instance"}"
        end
        abort "gori run project delete: #{delete_preview_verdict(project, locked, open_elsewhere)}"
      end

      private def self.capture_line(locked : Bool?) : String
        case locked
        when true  then "RUNNING in another gori instance"
        when false then "not running"
        else            "UNKNOWN — the capture lock could not be probed"
        end
      end

      # The preview's closing line: what `--yes` would do from here. Spelled from the same two
      # facts the guards above report, so the sentence cannot predict a delete that
      # `ProjectRegistry#delete` is going to refuse a moment later.
      #
      # `locked` is TRISTATE and the nil arm is not a rounding error: `ProjectRegistry#delete`
      # refuses a project whose capture lock it cannot probe ("cannot check the capture lock
      # for \u2026"), so folding "unknown" into "not running" would put this sentence right back
      # to inviting a `--yes` that aborts — the defect the rest of this method exists to close,
      # one state over.
      private def self.delete_preview_verdict(project : Project, locked : Bool?,
                                              open_elsewhere : Bool) : String
        return "nothing deleted — re-run with --yes to remove #{project.dir}" if locked == false && !open_elsewhere
        reason = case
                 # Capture named first when several are true: it is the most specific answer
                 # (a capturer also holds the database open), and the one with an obvious
                 # next step.
                 when locked      then "is held by a live capture"
                 when locked.nil? then "has a capture lock this command cannot read — check the directory's permissions"
                 else                  "is held by another gori instance"
                 end
        "nothing deleted — #{project.dir} #{reason}; " \
        "--yes would be refused until that clears"
      end

      # Is another live instance capturing into this project? `CaptureLock.held?` probes by
      # ACQUIRING the lock (it creates the lock file and re-raises anything that is not
      # contention), so a project directory this user can read but not write raises here —
      # and a command that promised to only look must not blow up on that.
      #
      # nil is UNKNOWN, not "no". It used to be `false`, on the reasoning that "the delete
      # itself re-probes through ProjectRegistry#delete, which is where being wrong matters"
      # — and that was exactly backwards: `delete` re-probes and REFUSES on the same failure,
      # so a preview calling it "not running" ended in "re-run with --yes" for a delete that
      # then aborted with "cannot check the capture lock for \u2026". Three states, reported as
      # three (`capture_line`, `deletable`, `delete_preview_verdict`).
      private def self.capture_running?(project : Project) : Bool?
        CaptureLock.held?(project.dir)
      rescue
        nil
      end

      # Flow + issue counts for the delete preview, from a short-lived READ-ONLY handle of its
      # own — two aggregates never needed a writer fiber, and the project being previewed for
      # deletion may well have a live capture on the other end of it (#752).
      # Best-effort: a locked or corrupt DB reports nil rather than failing the preview
      # (mirrors MCP delete_project's dry run).
      private def self.project_object_counts(project : Project) : {Int64?, Int32?}
        return {nil, nil} unless File.exists?(project.db_path)
        store = Store.open(project.db_path, retention_flows: Store::RETENTION_UNLIMITED, read_only: true)
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
            STDERR.puts "Usage: gori run project scope [list options] | add | update|edit <rule-id> | delete|rm <rule-id> | enable | disable"
            exit 1
          end
        end
      end

      private def self.cmd_scope_list(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text

        leftover = parse_args(args, "gori run project scope") do |p|
          p.banner = "Usage: gori run project scope [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project scope add --kind=include/exclude --type=host/string/regex --pattern=...\n" \
                     "  gori run project scope update|edit <rule-id> [--kind=... --type=... --pattern=...]\n" \
                     "  gori run project scope delete|rm <rule-id>\n" \
                     "  gori run project scope enable\n" \
                     "  gori run project scope disable"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refuse_list_leftovers(leftover, "project scope",
          "add, update/edit, delete/rm, enable, disable, list")

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project, read_only: true)
        begin
          scope = Scope.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "enabled", scope.enabled?
                j.field "active_send_gate", scope.configured?
                j.field "rules" do
                  j.array { scope.rules.each { |r| scope_rule_json(j, r) } }
                end
              end
            end)
          else
            puts "Scope filtering: #{scope.enabled? ? "ENABLED" : "DISABLED"}"
            puts scope_gate_line(scope)
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

      # The OTHER thing scope rules do (#1388). "Scope filtering" is the enabled flag — the TUI's
      # `s` lens — but the gate every active send passes (`Outbound.cli` / `.agent`) is armed by
      # the rules existing at all (`Scope#configured?`), enabled or not. A listing that said only
      # "DISABLED" read as "nothing is enforced" while `gori run send` refused out-of-scope
      # targets. By design; now said.
      def self.scope_gate_line(scope : Scope) : String
        n = scope.rules.size
        if scope.configured?
          "Active-send gate: ON (#{n} rule#{n == 1 ? "" : "s"}) — send/repeater/fuzz/mine/discover and MCP " \
          "refuse a target these rules leave out of scope unless --allow-unscoped / allow_unscoped:true"
        else
          "Active-send gate: no rules — `gori run` sends are not restricted (MCP refuses every send until a rule exists)"
        end
      end

      # One scope rule as JSON — the element of `scope list --format json`'s `rules`, and the
      # whole of `scope add --format json` (#1117): a script gets the same object whether it
      # reads the rule back or has just made it.
      private def self.scope_rule_json(j : JSON::Builder, r : Scope::Rule) : Nil
        j.object do
          j.field "id", r.id
          j.field "kind", r.kind
          j.field "type", r.match_type
          j.field "pattern", r.pattern
        end
      end

      # Edit a rule in place (the TUI scope list's `e`). Without this the only fix for a typo'd
      # pattern was delete + re-add, which changes the rule's id and briefly drops it from the
      # gate that decides what traffic may be probed.
      private def self.cmd_scope_update(args : Array(String)) : Nil
        proj = ProjectFlags.new
        kind : String? = nil
        match_type : String? = nil
        pattern : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope update <id> [options]\n\n" \
                     "Change an existing scope rule. Every field keeps its current value unless\n" \
                     "you pass it, so you can edit just the pattern."
          project_options(p, proj, "update")
          p.on("-kKIND", "--kind=KIND", "Rule kind: include|exclude") { |v| kind = v }
          p.on("-tTYPE", "--type=TYPE", "Match type: host|string|regex") { |v| match_type = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "Pattern to match") { |v| pattern = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run project scope update", "<id>") }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run project scope update", f, p) }
          p.missing_option { |f| abort "gori run project scope update: missing value for #{f}" }
        end
        parser.parse(args)

        id_s = positional.first? || abort("gori run project scope update: <id> is required (see `gori run project scope list`)")
        id = id_s.to_i64? || abort("gori run project scope update: invalid rule id #{id_s.inspect}")

        project = resolve_read_project(proj.name, proj.db)
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
          # `scope_rules` carries UNIQUE(kind, match_type, pattern) (store/schema.cr), and
          # `Scope#update` collapses a collision and a rolled-back write into ONE false.
          # Without this pre-check the busy-store abort below reported a duplicate as "store
          # busy or unwritable" — sending the operator to hunt for a lock. `scope add` already
          # names the duplicate; this makes the two agree, and leaves whatever false survives
          # it meaning the store, exactly as MCP's `update_scope_rule` splits the same pair.
          if scope.rules.any? { |r| r.id != id && r.kind == new_kind && r.match_type == new_type && r.pattern == new_pattern }
            store.close
            abort "gori run project scope update: rule ##{id} NOT updated — #{new_kind} #{new_type} #{new_pattern} " \
                  "already exists as another rule; the scope is unchanged"
          end
          # Through `Scope#update`, like `scope add`/`scope delete` beside it. Going straight at
          # the store skipped `ConfigLog`, which is recorded at the MODEL (see its header, which
          # names the CLI as the surface that gets forgotten) — so `scope_update` was an event
          # NO surface but the TUI ever emitted, and narrowing the include rule that gates every
          # active send left the project's config feed with nothing to show for it.
          unless scope.update(id, new_kind, new_type, new_pattern)
            abort "gori run project scope update: rule NOT updated (store busy or unwritable); it is unchanged and still gates traffic"
          end
          puts "Scope rule ##{id} updated: #{new_kind} #{new_type} #{new_pattern}"
          # `Scope#update` reloads its own rule list, so this reads the edit rather than the
          # list as it stood one write ago.
          warn_scope_blackhole(scope, "gori run project scope update")
        ensure
          store.close
        end
      end

      private def self.cmd_scope_add(args : Array(String)) : Nil
        proj = ProjectFlags.new
        kind = "include"
        match_type = "host"
        pattern : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope add [options]"
          project_options(p, proj, "update")
          p.on("-kKIND", "--kind=KIND", "Rule kind: include|exclude (default: include)") { |v| kind = v }
          p.on("-tTYPE", "--type=TYPE", "Match type: host|string|regex (default: host)") { |v| match_type = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "Pattern to match (required)") { |v| pattern = v }
          format_flag(p, [:text, :json], "Output: text (default) | json — the new rule, as `scope --format json` lists it") { |f| format = f }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run project scope add", f, p) }
          p.missing_option { |f| abort "gori run project scope add: missing value for #{f}" }
        end
        parse_no_positionals(parser, args, "gori run project scope add",
          "pass the pattern as --pattern P, with --kind include|exclude and --type host|string|regex")

        abort "gori run project scope add: --pattern is required" if (pat = pattern).nil? || pat.empty?
        abort "gori run project scope add: invalid kind '#{kind}' (must be include or exclude)" unless kind.in?(Scope::KINDS)
        abort "gori run project scope add: invalid type '#{match_type}' (must be host, string, or regex)" unless match_type.in?(Scope::TYPES)
        if err = Scope.validation_error(match_type, pat.strip)
          abort "gori run project scope add: #{err}"
        end

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.add(kind, match_type, pat)
            store.close
            abort "gori run project scope add: rule NOT added (duplicate, empty, invalid, " \
                  "or the store was busy/unwritable); the scope is unchanged"
          end
          # `Scope#add` reloads its own rule list, so the new rule — and the id every later
          # `scope update`/`delete` takes — is found by the triple it was added under (the
          # table is UNIQUE on it). It used to be printed nowhere, so a script adding a rule it
          # meant to remove later had no handle for it (#1117).
          added = scope.rules.find { |r| r.kind == kind && r.match_type == match_type && r.pattern == pat.strip }
          if format == :json
            unless rule = added
              # Committed, then gone before the read — a peer deleted it in between. Refused like
              # every other create's read-back: an `"id": null` a script feeds to `scope delete`
              # fails there, far from the cause.
              store.close
              abort "gori run project scope add: the rule was added, but another gori removed it before it could be read back"
            end
            puts(JSON.build { |j| scope_rule_json(j, rule) })
          else
            puts added ? "Scope rule ##{added.id} added successfully (#{kind} #{match_type} #{pat.strip})." : "Scope rule added successfully."
          end
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
        proj = ProjectFlags.new

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope delete|rm <rule-id> [options]"
          project_options(p, proj, "update")
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run project scope delete", f, p) }
          p.missing_option { |f| abort "gori run project scope delete: missing value for #{f}" }
        end

        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)

        abort "gori run project scope delete: missing <rule-id>" if positional.empty?
        abort "gori run project scope delete: too many arguments (expected one <rule-id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project scope delete: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.rules.any? { |r| r.id == id }
            store.close
            abort "gori run project scope delete: no scope rule with id #{id}"
          end
          # `Scope#remove` now hands back `remove_scope_rule`'s committed flag (it is
          # `exec_task_ok`, so the answer always existed). Without this a busy/locked project
          # reported a security rule "deleted successfully" while it was still gating traffic —
          # the failure mode `scope enable/disable` and `sandbox on/off` already refuse to have.
          unless scope.remove(id)
            store.close
            abort "gori run project scope delete: rule ##{id} NOT deleted (project busy) — try again"
          end
          puts "Scope rule ##{id} deleted successfully."
          warn_scope_blackhole(scope, "gori run project scope delete")
        ensure
          store.close
        end
      end

      private def self.cmd_scope_set_enabled(enable : Bool, args : Array(String)) : Nil
        proj = ProjectFlags.new
        action = enable ? "enable" : "disable"

        leftover = parse_args(args, "gori run project scope #{action}") do |p|
          p.banner = "Usage: gori run project scope #{action} [options]"
          project_options(p, proj, "update")
        end
        unless leftover.empty?
          abort "gori run project scope #{action}: unexpected argument#{leftover.size == 1 ? "" : "s"} " \
                "#{leftover.join(" ").inspect} — this #{action}s the whole filter, not a rule id. " \
                "Per-rule change: `gori run project scope update <id>`"
        end

        project = resolve_read_project(proj.name, proj.db)
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
      # blocking policy, distinct from the `s` display lens). Until now this could only be
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
        proj = ProjectFlags.new
        format = :text

        leftover = parse_args(args, "gori run project sandbox") do |p|
          p.banner = "Usage: gori run project sandbox [options]\n\n" \
                     "Show the hard-containment sandbox gate: when ON, the capture proxy forwards\n" \
                     "ONLY requests the scope allows and BLOCKS everything else (see\n" \
                     "'gori run project scope'). Or set it:\n" \
                     "  gori run project sandbox on|enable\n" \
                     "  gori run project sandbox off|disable"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        # The one in this family where the silent no-op is a CONTAINMENT failure: `project
        # sandbox --project=X on` printed the status, left the gate OFF and exited 0, so a CI
        # bootstrap believed its traffic was contained when it was not.
        refuse_list_leftovers(leftover, "project sandbox", "on/enable, off/disable, status",
          read_verb: "status")

        project = resolve_read_project(proj.name, proj.db)
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
        proj = ProjectFlags.new
        action = enable ? "on" : "off"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project sandbox #{action} [options]"
          project_options(p, proj, "update")
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run project sandbox #{action}", f, p) }
          p.missing_option { |f| abort "gori run project sandbox #{action}: missing value for #{f}" }
        end
        parse_no_positionals(parser, args, "gori run project sandbox #{action}",
          "`sandbox #{action}` takes no positional arguments; the project is named with --project")

        project = resolve_read_project(proj.name, proj.db)
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
          # The setters return whether the write COMMITTED (mirrors scope enable/disable's
          # check). A busy/locked store must not report success: the in-memory flag flips
          # either way, and the next reload reverts it to the disk value.
          unless enable ? scope.enable_sandbox : scope.disable_sandbox
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
        proj = ProjectFlags.new
        format = :text

        leftover = parse_args(args, "gori run project env") do |p|
          p.banner = "Usage: gori run project env [options]\n\n" \
                     "List project env vars used for $ENV.KEY substitution in outbound requests\n" \
                     "($KEY under the legacy bare syntax — see `gori settings env-syntax`).\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project env set KEY=value\n" \
                     "  gori run project env set KEY value\n" \
                     "  gori run project env delete|rm KEY"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refuse_list_leftovers(leftover, "project env", "set, delete/rm, list")

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project, read_only: true)
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
        proj = ProjectFlags.new

        positional = parse_args(args, "gori run project env set") do |p|
          p.banner = "Usage: gori run project env set KEY=value [options]\n" \
                     "       gori run project env set KEY value [options]"
          project_options(p, proj, "update")
        end

        abort "gori run project env set: missing KEY=value (or KEY value)" if positional.empty?
        parsed = env_set_pair(positional)
        abort "gori run project env set: #{env_set_refusal(positional)}" unless parsed
        key, val = parsed

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project)
        begin
          # `Env.set_project_var`, not a load-edit-`save_project`: this command owns ONE key,
          # and persisting the whole array from a copy read beforehand deletes every var a
          # concurrent writer (a running `gori mcp`, the TUI's ENV pane, a second shell) added
          # in between — while still printing "set". The read happens inside the write
          # transaction, so only this key changes.
          unless Env.set_project_var(store, key, val)
            store.close
            abort "gori run project env set: project is busy (write did not commit) — try again"
          end
          # Spelled through `Env.spell`, because the answer to "how do I use it now?" is
          # mode-dependent: `$ENV.KEY` on a namespaced install, `$KEY` on a bare one.
          puts "Env var #{key} set — reference it as #{Env.spell(key, Env::Namespace::Env)}."
        ensure
          store.close
        end
      end

      # argv has already separated KEY and VALUE for the two-argument form. Keep that split
      # intact; a one-argument assignment uses its first `=` and validates the whole key.
      private def self.env_set_pair(positional : Array(String)) : {String, String}?
        return nil if positional.empty?
        if positional.size == 1
          assignment = positional[0]
          eq = assignment.index('=')
          return nil unless eq
          key = assignment[0...eq]
          value = assignment[eq + 1..]
        else
          key = positional[0]
          value = positional[1..].join(' ')
        end
        return nil unless Env.valid_key?(key) && value.valid_encoding?
        {key, value}
      end

      # Which of `env_set_pair`'s three refusals applies, so a valid key with no value (or a
      # value that is not UTF-8) is not reported as a bad KEY.
      def self.env_set_refusal(positional : Array(String)) : String
        key = positional.size == 1 ? positional[0].partition('=')[0] : positional[0]
        return "invalid KEY (use [A-Za-z_][A-Za-z0-9_]*)" unless Env.valid_key?(key)
        return "missing value for #{key} (KEY=value, or KEY value; KEY= sets it empty)" if positional.size == 1 && !positional[0].includes?('=')
        "the value for #{key} is not valid UTF-8"
      end

      private def self.cmd_env_delete(args : Array(String)) : Nil
        proj = ProjectFlags.new

        positional = parse_args(args, "gori run project env delete") do |p|
          p.banner = "Usage: gori run project env delete|rm KEY [options]"
          project_options(p, proj, "update")
        end

        abort "gori run project env delete: missing KEY" if positional.empty?
        abort "gori run project env delete: too many arguments (expected one KEY)" if positional.size > 1
        key = positional[0]
        abort "gori run project env delete: invalid KEY '#{key}'" unless Env.valid_key?(key)

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project)
        begin
          # "no such key" is decided against the table this process just loaded (open_store
          # hydrates it), because `Env.delete_project_var` folds that case into the same
          # `false` a busy store returns and the two need different exit messages. The write
          # is transactional, so removing this key cannot drop a peer's.
          if Settings.project_env_vars.none? { |(k, _)| k == key }
            store.close
            abort "gori run project env delete: no env var named '#{key}'"
          end
          unless Env.delete_project_var(store, key)
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
        proj = ProjectFlags.new
        format = :text

        leftover = parse_args(args, "gori run project host-override") do |p|
          p.banner = "Usage: gori run project host-override [options]\n\n" \
                     "List project host overrides (/etc/hosts-style: dial IP[:PORT] for hostname).\n" \
                     "Project overrides win over global Settings: Hostnames on collision.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project host-override add --host=api.example.com --ip=10.0.0.1\n" \
                     "  gori run project host-override add 10.0.0.1 api.example.com\n" \
                     "  gori run project host-override update <id> --host=... --ip=...\n" \
                     "  gori run project host-override delete|rm <id>"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refuse_list_leftovers(leftover, "project host-override", "add, update, delete/rm, list")

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project, read_only: true)
        begin
          ov = HostOverrides.load(store)
          if format == :json
            puts(JSON.build { |j| j.array { ov.entries.each { |e| host_override_json(j, e.id, e.host, e.ip) } } })
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

      # One host override as JSON — the element of `host-override --format json`, and the whole
      # of `host-override add --format json` (#1117).
      private def self.host_override_json(j : JSON::Builder, id : Int64, host : String, ip : String) : Nil
        j.object do
          j.field "id", id
          j.field "host", host
          j.field "ip", ip
        end
      end

      private def self.cmd_host_override_add(args : Array(String)) : Nil
        proj = ProjectFlags.new
        host : String? = nil
        ip : String? = nil
        format = :text

        positional = parse_args(args, "gori run project host-override add") do |p|
          p.banner = "Usage: gori run project host-override add --host=HOST --ip=IP [options]\n" \
                     "       gori run project host-override add IP HOST [options]\n\n" \
                     "Add a project host override (dial IP — or IP:PORT — for HOST; SNI/Host header unchanged)."
          project_options(p, proj, "update")
          p.on("--host=HOST", "Hostname to override (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "IPv4/IPv6 literal to dial, optionally IP:PORT") { |v| ip = v }
          format_flag(p, [:text, :json], "Output: text (default) | json — the new override, as `host-override --format json` lists it") { |f| format = f }
        end

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
        abort "gori run project host-override add: invalid host/ip (host hostname-shaped; ip an IPv4/IPv6 literal, optionally IP:PORT or [v6]:PORT)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.add(h, i)
            store.close
            abort "gori run project host-override add: override NOT added (duplicate host, empty, " \
                  "invalid, or the store was busy/unwritable); nothing was created"
          end
          # `OverrideHost.key` is the form `add` stored, so this is the lookup that finds it.
          # `downcase` alone missed a fully-qualified `--host=api.test.` and dropped this to
          # the id-less fallback below — the id being the operator's only handle for a later
          # `update`/`delete`, and the echoed name one the table does not contain.
          key = OverrideHost.key(h)
          e = ov.entries.find { |x| x.host == key }
          if format == :json
            unless e
              store.close
              abort "gori run project host-override add: the override was added, but it was gone before it could be read back"
            end
            puts(JSON.build { |j| host_override_json(j, e.id, e.host, e.ip) })
          elsif e
            puts "Host override ##{e.id} added: #{e.ip} → #{e.host}"
          else
            puts "Host override added: #{i} → #{key}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_update(args : Array(String)) : Nil
        proj = ProjectFlags.new
        host : String? = nil
        ip : String? = nil

        positional = parse_args(args, "gori run project host-override update") do |p|
          p.banner = "Usage: gori run project host-override update <id> --host=HOST --ip=IP [options]"
          project_options(p, proj, "update")
          p.on("--host=HOST", "New hostname (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "New IPv4/IPv6 literal to dial, optionally IP:PORT") { |v| ip = v }
        end

        abort "gori run project host-override update: missing <id>" if positional.empty?
        abort "gori run project host-override update: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override update: invalid id '#{positional[0]}'")
        h = host
        i = ip
        abort "gori run project host-override update: --host and --ip are both required" unless h && i
        abort "gori run project host-override update: invalid host/ip (host hostname-shaped; ip an IPv4/IPv6 literal, optionally IP:PORT or [v6]:PORT)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override update: no override with id #{id}"
          end
          unless ov.update(id, h, i)
            store.close
            abort "gori run project host-override update: NOT updated (duplicate host, or store busy or unwritable)"
          end
          puts "Host override ##{id} updated: #{i} → #{OverrideHost.key(h)}" # the stored form, not the typed one
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_delete(args : Array(String)) : Nil
        proj = ProjectFlags.new

        positional = parse_args(args, "gori run project host-override delete") do |p|
          p.banner = "Usage: gori run project host-override delete|rm <id> [options]"
          project_options(p, proj, "update")
        end

        abort "gori run project host-override delete: missing <id>" if positional.empty?
        abort "gori run project host-override delete: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override delete: invalid id '#{positional[0]}'")

        project = resolve_read_project(proj.name, proj.db)
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
