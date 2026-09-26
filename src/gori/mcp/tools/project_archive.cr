require "json"
require "../../project_archive"
require "../../project_registry"
require "../../paths"

module Gori
  module MCP
    class Tools
      # --- project archives ---------------------------------------------------
      #
      # The MCP counterpart of `gori run project export|import` and the picker's Export /
      # Import archive (#1271). Both tools are thin adapters over the one archive engine,
      # `ProjectArchive`: an agent's export is the same `.gori` file the CLI writes, and an
      # agent's import crosses the same trust boundary (#1264) — executable and file-backed
      # rules disabled, project routing reset, triggers/views refused, the 2 GiB cap — because
      # it is the same `prepare_import`. Paths resolve on the MCP SERVER's filesystem, the
      # boundary `import_flows` already draws, and are echoed back absolute.

      # How this surface names another project when the archive's own name is unusable.
      ARCHIVE_RENAME_HINT = "with the 'name' argument"

      # Said on every export, because the agent holding the result is the one that might move
      # the file next. The shared disclosure already says "unredacted"; this says what that
      # means for an agent that was not asked to hand the file anywhere.
      ARCHIVE_EXPORT_WARNING = "Agent-initiated export: this file is the complete, UNREDACTED project " \
                               "database, credentials included. Do not upload, attach, or share it " \
                               "unless the operator asked for exactly that."

      # Export writes a file on the operator's disk and changes no project, so it is gated
      # (a --read-only server writes nothing) and recorded in the event feed: an unredacted
      # copy of the engagement leaving gori is what the operator should see an agent do.
      @[Tool("export_project", gated: true, agent_action: true, unbound: true, permission: "projects")]
      private def export_project(h) : Result
        path = str(h, "path").try(&.strip).presence
        unless path
          return err("missing required 'path' (where to write the .gori archive)",
            "INVALID_ARGUMENT", field: "path")
        end
        overwrite = bool_arg(h, "overwrite", false)
        reg = registry
        source = archive_export_source(reg, str(h, "project").try(&.strip).presence)
        return source if source.is_a?(Result)
        project, registered = source

        # The destination is judged BEFORE the snapshot, which can be a multi-GiB VACUUM INTO:
        # a refused path should cost a stat, not a copy of the project. `write` judges it again
        # for the path it installs to.
        begin
          ProjectArchive.resolve_destination(path, project, overwrite: overwrite,
            loose_database: !registered, protected_dir: Paths.home_dir)
        rescue ex : Gori::Error
          return archive_destination_error(ex)
        end
        prepared = begin
          ProjectArchive.prepare_export(project, loose_database: !registered)
        rescue ex : Gori::Error
          return err(ex.message || "could not snapshot project #{project.name.inspect}",
            "INVALID_ARGUMENT", field: "project")
        rescue ex : File::Error | IO::Error | DB::Error | SQLite3::Exception
          return err("could not snapshot project #{project.name.inspect}: #{ex.message}",
            "INVALID_ARGUMENT", field: "project")
        end
        begin
          replaced = overwrite && ProjectArchive.destination_exists?(Path[path].expand(home: true).to_s)
          destination = begin
            prepared.write(path, overwrite: overwrite, protected_dir: Paths.home_dir)
          rescue ex : Gori::Error
            return archive_destination_error(ex)
          rescue ex : File::Error | IO::Error
            return err("could not write project archive: #{ex.message}", "INVALID_ARGUMENT", field: "path")
          end
          archive_export_result(reg, prepared, destination, registered, replaced)
        ensure
          prepared.close
        end
      end

      # A refused destination, in this surface's words. gori's home is protected because it
      # holds every project's database, the registry sidecars and the settings: the engine only
      # refuses the SOURCE project, so with overwrite:true an agent could otherwise rename an
      # archive over another project's gori.db — a delete that never went through
      # delete_project's dry run — or over settings.json. The CLI keeps that reach; its caller
      # is the operator.
      private def archive_destination_error(ex : Gori::Error) : Result
        message = case ex
                  when ProjectArchive::DestinationExists
                    "destination already exists: #{ex.path} — pass overwrite:true to replace it, or choose another 'path'"
                  when ProjectArchive::ProtectedDestination
                    "refusing to write a project archive inside gori's home (#{ex.dir}): it holds every " \
                    "project's database and gori's settings — choose a 'path' outside it"
                  else
                    ex.message || "could not write project archive"
                  end
        err(message, "INVALID_ARGUMENT", field: "path")
      end

      # The project an export reads: the named one, or the one this server is bound to. A
      # `--db` binding is not a registry project, so it exports by path and reports no id/slug.
      private def archive_export_source(reg : ProjectRegistry, name : String?) : {Project, Bool} | Result
        if name
          project = find_project(reg, name, "project")
          return project if project.is_a?(Result)
          return not_found("no such project: #{name} (match short id, id prefix, dir slug, or display name)") unless project
          return {project, true}
        end
        db_path = @db_path
        return no_project unless @store && db_path
        # A registry project's database is `<projects_dir>/<slug>/gori.db`; asking the path
        # answers that without listing (and stat-ing) every project on the host.
        registered = File.basename(db_path) == Project::DB_FILE &&
                     Paths.canonical_file(File.dirname(File.dirname(db_path))) == Paths.canonical_file(Paths.projects_dir)
        {Project.new(@project_name || File.basename(db_path, File.extname(db_path)), db_path), registered}
      end

      private def archive_export_result(reg : ProjectRegistry, prepared : ProjectArchive::PreparedExport,
                                        destination : String, registered : Bool, replaced : Bool) : Result
        project = prepared.project
        Result.new(JSON.build do |j|
          j.object do
            j.field "exported", true
            j.field "project", project.name
            j.field "id", registered ? reg.id_of(project) : nil
            j.field "slug", registered ? reg.slug_of(project) : nil
            j.field "path", destination
            j.field "bytes", File.size(destination)
            j.field "replaced_existing", replaced
            archive_fields(j, prepared.manifest, prepared.inventory)
            j.field "unredacted", true
            j.field "warning", ARCHIVE_EXPORT_WARNING
          end
        end)
      end

      # Import registers a NEW project and never reopens or overwrites one. Gated because it
      # writes into the registry; unbound because, like create_project, it needs no binding —
      # and it does not bind the new project either, so the server's binding never moves.
      #
      # Two calls, like the destructive bulk tools: without confirm:true the archive is fully
      # validated, the disclosure and the name it would take come back as CONFIRM_REQUIRED, and
      # nothing is registered. The confirmed call validates the file again and imports what it
      # read THEN, so its own result carries the inventory of what was actually imported.
      @[Tool("import_project", gated: true, agent_action: true, unbound: true, permission: "projects")]
      private def import_project(h) : Result
        path = str(h, "path").try(&.strip).presence
        return err("missing required 'path' (the .gori archive to import)", "INVALID_ARGUMENT", field: "path") unless path
        name = str(h, "name").try(&.strip).presence
        confirm = bool_arg(h, "confirm", false)
        source = Path[path].expand(home: true).to_s

        prepared = begin
          ProjectArchive.prepare_import(source)
        rescue ex : Gori::Error
          return err(ex.message || "could not read project archive", "INVALID_ARGUMENT", field: "path")
        rescue ex : File::Error | IO::Error | DB::Error | SQLite3::Exception
          return err("could not read project archive '#{source}': #{ex.message}", "INVALID_ARGUMENT", field: "path")
        end
        begin
          reg = registry
          return archive_import_preview(reg, prepared, source, name) unless confirm
          project = begin
            prepared.import_into(reg, name, rename_hint: ARCHIVE_RENAME_HINT)
          rescue ex : Gori::Error
            # `name` only when the name is what failed: an agent reads the field as the argument
            # to change, and renaming cannot fix anything else.
            name_failed = !prepared.name_problem(reg, name, rename_hint: ARCHIVE_RENAME_HINT).nil?
            return err(ex.message || "could not import project archive", "INVALID_ARGUMENT",
              field: name_failed ? "name" : nil)
          rescue ex : File::Error | IO::Error
            return err("could not register project: #{ex.message}", "INTERNAL")
          end
          archive_import_result(reg, prepared, source, project)
        ensure
          prepared.close
        end
      end

      # The refusal an unconfirmed import answers with. The disclosure is in the MESSAGE as well
      # as the details, so a client that shows only the text still puts it in front of the model
      # before it can confirm. A name the registry would refuse is reported here, so the
      # confirmed call is not the first to learn the archive's name is taken.
      private def archive_import_preview(reg : ProjectRegistry, prepared : ProjectArchive::PreparedImport,
                                         source : String, name : String?) : Result
        manifest = prepared.manifest
        target = prepared.target_name(name)
        problem = prepared.name_problem(reg, name, rename_hint: ARCHIVE_RENAME_HINT)
        next_step = if problem
                      "It cannot be imported as #{target.inspect}: #{problem}. Pass another 'name' with confirm:true."
                    else
                      "Pass confirm:true to import it as #{target.inspect}."
                    end
        message = "Validated archive #{manifest.project_name.inspect} " \
                  "(#{manifest.flow_count} #{manifest.flow_count == 1 ? "flow" : "flows"}, schema v#{manifest.schema_version}, " \
                  "exported by gori #{manifest.gori_version} at #{manifest.created_at}); nothing was imported. " \
                  "#{ProjectArchive.disclosure(prepared.inventory)} #{next_step}"
        details = JSON.build do |j|
          j.object do
            j.field "path", source
            j.field "name", Serialize.text(target)
            j.field "name_available", problem.nil?
            j.field "name_problem", problem if problem
            archive_fields(j, manifest, prepared.inventory)
          end
        end
        err(message, "CONFIRM_REQUIRED", field: "confirm", details: JSON.parse(details))
      end

      private def archive_import_result(reg : ProjectRegistry, prepared : ProjectArchive::PreparedImport,
                                        source : String, project : Project) : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "imported", true
            j.field "name", project.name
            j.field "id", reg.id_of(project)
            j.field "slug", reg.slug_of(project)
            j.field "db_path", project.db_path
            j.field "path", source
            archive_fields(j, prepared.manifest, prepared.inventory)
            # Named, because every other way a project reaches this server (create_project on
            # an unbound server, switch_project) moves the binding, and this one does not.
            j.field "switched", false
            j.field "note", archive_import_note(reg, project)
          end
        end)
      end

      private def archive_import_note(reg : ProjectRegistry, project : Project) : String
        binding = (bound = @project_name || @db_path) ? "still bound to #{bound.inspect}" : "still unbound"
        handle = reg.id_of(project) || project.name
        if serves?("switch_project")
          "Imported as a new project; this server is #{binding}. Call switch_project with project " \
          "#{handle.inspect} to work in it."
        else
          "Imported as a new project; this server is #{binding}."
        end
      end

      # What an archive holds and what importing it changes, in the same shape on all three
      # results that describe one: the manifest as written, the sensitive-data inventory, the
      # safety steps an import applies, and the one disclosure sentence every surface shows.
      private def archive_fields(j : JSON::Builder, manifest : ProjectArchive::Manifest,
                                 inventory : ProjectArchive::Inventory) : Nil
        # Field by field rather than `manifest.to_json`: the archive is untrusted, and its
        # project name may carry bytes that are not UTF-8 (the version and timestamp are
        # validated printable ASCII by the engine).
        j.field "archive" do
          j.object do
            j.field "format_version", manifest.format_version
            j.field "project_name", Serialize.text(manifest.project_name)
            j.field "gori_version", manifest.gori_version
            j.field "schema_version", manifest.schema_version
            j.field "created_at", manifest.created_at
            j.field "flow_count", manifest.flow_count
          end
        end
        j.field "inventory" do
          j.object do
            j.field "flows", inventory.flows
            j.field "session_slots", inventory.session_slots
            j.field "env_vars", inventory.env_vars
            j.field "upstream_credentials", inventory.upstream_credentials
            j.field "exec_repeaters", inventory.exec_repeaters
            j.field "exec_fuzz_templates", inventory.exec_fuzz_templates
            j.field "exec_env_vars", inventory.exec_env_vars
          end
        end
        j.field "import_safety" do
          j.object do
            j.field "disabled_pipe_rules", inventory.disabled_pipe_rules
            j.field "disabled_exec_probe_rules", inventory.disabled_exec_probe_rules
            j.field "disabled_body_file_stubs", inventory.disabled_body_file_stubs
            j.field "reset_network_settings", inventory.reset_network_settings
            j.field "reset_host_overrides", inventory.reset_host_overrides
            j.field "reset_global_overrides", inventory.reset_global_overrides
            j.field "disabled_auto_refresh_slots", inventory.disabled_auto_refresh_slots
            j.field "reset_probe_mode", inventory.reset_probe_mode.try(&.label)
          end
        end
        j.field "disclosure", ProjectArchive.disclosure(inventory)
      end

      # The tools/list schemas for the archive tools, kept beside the handlers that implement
      # them. Both write to disk, so neither is advertised under --read-only.
      private def list_project_archive_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "export_project",
          "Write a whole project to a portable .gori archive (a manifest plus a WAL-safe SQLite " \
          "snapshot) on the MCP SERVER's filesystem — the same file `gori run project export` " \
          "writes. Exports the bound project unless 'project' names another. The archive is " \
          "UNREDACTED: captured credentials, session slots, env values and upstream proxy " \
          "credentials all go in it, and the result carries the inventory and a disclosure. An " \
          "existing file is refused unless overwrite:true, and a path inside gori's home always is." do |s|
          s.field "path", strprop("destination file for the archive (relative paths resolve against " \
                                  "the MCP server's working directory; the result reports the absolute path)"), required: true
          s.field "project", strprop("project to export: short id, dir slug, or display name (default: the bound project)")
          s.field "overwrite", boolprop("replace an existing file at 'path' (default false)")
        end

        tool j, "import_project",
          "Import a .gori project archive as a NEW project (never reopens or overwrites one), " \
          "through the same validation as `gori run project import`: pipe Rewriter rules, exec " \
          "Probe rules and file-backed stubs are disabled, project network settings, host and " \
          "global-rule overrides, Probe mode and slot auto-refresh are reset, and archives over " \
          "2 GiB uncompressed are refused. Without " \
          "confirm:true nothing is imported: the archive is validated and the call returns " \
          "CONFIRM_REQUIRED with its inventory, the disclosure, and whether the name is free. " \
          "Does not change which project this server is bound to." do |s|
          s.field "path", strprop("the .gori archive on the MCP server's filesystem"), required: true
          s.field "name", strprop("display name for the imported project (default: the name in the archive)")
          s.field "confirm", boolprop("must be true to import; anything else validates and previews only")
        end
      end
    end
  end
end
