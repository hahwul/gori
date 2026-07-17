require "json"
require "../../project_registry"
require "../../paths"
require "../../capture_lock"
require "../../store"
require "../../env"

module Gori
  module MCP
    class Tools
      # --- project lifecycle --------------------------------------------------

      private def registry : ProjectRegistry
        ProjectRegistry.new(Paths.projects_dir)
      end

      # True while any fuzz/mine job is still running — switching or deleting a
      # project mid-job would repoint @store (and thus record_history writes) out
      # from under the running fiber, so both refuse until jobs settle.
      private def jobs_running? : Bool
        @jobs.each_value.any? { |j| j.status == :running } ||
          @mine_jobs.each_value.any? { |j| j.status == :running } ||
          @discover_jobs.each_value.any? { |j| j.status == :running }
      end

      private def list_projects : Result
        reg = registry
        projects = reg.list
        Result.new(JSON.build do |j|
          j.object do
            j.field "current_db_path", @db_path
            j.field "projects_root", Paths.projects_dir
            j.field("projects") do
              j.array do
                projects.each do |p|
                  j.object do
                    j.field "name", p.name
                    j.field "id", reg.id_of(p)
                    j.field "slug", reg.slug_of(p)
                    j.field "db_path", p.db_path
                    j.field "db_size", p.db_size
                    j.field "current", p.db_path == @db_path
                    j.field "workspace", reg.workspace_of(p)
                    if lm = p.last_modified
                      j.field "last_modified", lm.to_unix
                      j.field "last_modified_iso", lm.to_rfc3339
                    end
                  end
                end
              end
            end
          end
        end)
      end

      private def create_project(h) : Result
        name = str(h, "name")
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.strip.empty?
        description = str(h, "description") || ""
        reg = registry
        existed = !reg.find(name).nil?
        proj = reg.create(name, description)
        # Materialize the DB (create+migrate) so the project is immediately visible
        # to list_projects/switch_project even when no description was supplied.
        Store.open(proj.db_path).close unless File.exists?(proj.db_path)
        Result.new(JSON.build do |j|
          j.object do
            j.field "name", proj.name
            j.field "id", reg.id_of(proj)
            j.field "slug", reg.slug_of(proj)
            j.field "db_path", proj.db_path
            j.field "created", !existed # false = reopened an existing same-name project
          end
        end)
      rescue ex : Gori::Error
        err(ex.message || "could not create project", "INVALID_ARGUMENT", field: "name")
      end

      private def switch_project(h) : Result
        name = str(h, "project")
        return err("missing required 'project'", "INVALID_ARGUMENT", field: "project") if name.nil? || name.strip.empty?
        reg = registry
        proj = reg.find(name)
        return not_found("no such project: #{name} (match short id, id prefix, dir slug, or display name)") unless proj
        return busy("cannot switch project while a fuzz/mine job is running; stop it first") if jobs_running?

        new_store = begin
          Store.open(proj.db_path)
        rescue ex
          return err("could not open project database: #{ex.message}", "INTERNAL")
        end
        @store.close if @owns_store # never close the caller-owned initial store
        @store = new_store
        @owns_store = true
        @project_name = proj.name
        @project_slug = reg.slug_of(proj)
        @project_id = reg.id_of(proj)
        @db_path = proj.db_path
        @workspace_root = reg.workspace_of(proj)
        @selection_source = "switch_project"
        Env.load_project(@store)
        Result.new(JSON.build do |j|
          j.object do
            j.field "switched", true
            j.field "project", @project_name
            j.field "project_slug", @project_slug
            j.field "project_id", @project_id
            j.field "db_path", @db_path
            j.field "flows", @store.count
            j.field "issues", @store.count_issues
          end
        end)
      end

      private def delete_project(h) : Result
        name = str(h, "project")
        return err("missing required 'project'", "INVALID_ARGUMENT", field: "project") if name.nil? || name.strip.empty?
        reg = registry
        proj = reg.find(name)
        return not_found("no such project: #{name} (match short id, id prefix, dir slug, or display name)") unless proj
        return busy("cannot delete the project this server is currently serving; switch away first") if proj.db_path == @db_path
        return busy("cannot delete a project while a fuzz/mine job is running") if jobs_running?

        dry_run = bool_arg(h, "dry_run", true)
        return delete_project_dry_run(reg, proj) if dry_run
        delete_project_confirmed(h, reg, proj)
      rescue ex : Gori::Error
        err(ex.message || "could not delete project", "INVALID_ARGUMENT")
      end

      private def delete_project_dry_run(reg : ProjectRegistry, proj : Project) : Result
        flows, issues = count_project_objects(proj)
        token = "del_#{Random::Secure.hex(8)}"
        @delete_tokens[token] = {proj.db_path, Time.utc.to_unix_ms}
        Result.new(JSON.build do |j|
          j.object do
            j.field "dry_run", true
            j.field "name", proj.name
            j.field "id", reg.id_of(proj)
            j.field "slug", reg.slug_of(proj)
            j.field "db_path", proj.db_path
            j.field "dir", proj.dir
            j.field "flows", flows
            j.field "issues", issues
            j.field "db_size", proj.db_size
            j.field "disk_size", dir_size(proj.dir)
            j.field "capture_lock_held", CaptureLock.held?(proj.dir)
            j.field "confirmation_token", token
            j.field "token_expires_in_seconds", DELETE_TOKEN_TTL
            j.field "note", "Re-call with dry_run:false and this confirmation_token to delete."
          end
        end)
      end

      private def delete_project_confirmed(h, reg : ProjectRegistry, proj : Project) : Result
        token = str(h, "confirmation_token")
        return err("missing required 'confirmation_token' (obtain it from a dry_run:true call)", "INVALID_ARGUMENT", field: "confirmation_token") if token.nil? || token.empty?
        entry = @delete_tokens[token]?
        return err("invalid or unknown confirmation_token; re-run dry_run:true", "INVALID_ARGUMENT", field: "confirmation_token") unless entry
        db_path, issued_ms = entry
        if db_path != proj.db_path
          return err("confirmation_token was issued for a different project", "INVALID_ARGUMENT", field: "confirmation_token")
        end
        if (Time.utc.to_unix_ms - issued_ms) > DELETE_TOKEN_TTL * 1000
          @delete_tokens.delete(token)
          return err("confirmation_token expired; re-run dry_run:true", "INVALID_ARGUMENT", field: "confirmation_token", retryable: true)
        end
        reg.delete(proj) # raises Gori::Error if another instance holds the capture lock
        @delete_tokens.delete(token)
        Result.new(JSON.build do |j|
          j.object do
            j.field "deleted", true
            j.field "name", proj.name
            j.field "id", reg.id_of(proj)
            j.field "slug", reg.slug_of(proj)
            j.field "db_path", proj.db_path
          end
        end)
      end

      # Flow + issue counts for a project other than the one we serve — opened in
      # its own read-only-ish Store handle and closed immediately. Best-effort:
      # a locked/corrupt DB reports nil rather than failing the dry run.
      private def count_project_objects(proj : Project) : {Int64?, Int32?}
        return {nil, nil} unless File.exists?(proj.db_path)
        s = Store.open(proj.db_path)
        begin
          {s.count, s.count_issues}
        ensure
          s.close
        end
      rescue
        {nil, nil}
      end

      private def dir_size(dir : String) : Int64
        return 0_i64 unless Dir.exists?(dir)
        total = 0_i64
        Dir.glob(File.join(dir, "**", "*")).each do |f|
          total += File.info(f).size if File.file?(f)
        rescue
          # skip anything that vanished / is unreadable mid-walk
        end
        total
      end
    end
  end
end
