require "compress/zip"
require "db"
require "sqlite3"
require "json"
require "file_utils"
require "./open_lock"
require "./paths"
require "./project_registry"
require "./session_slot"
require "./env"
require "./settings/network"
require "./settings/project_network"
require "./store/schema"

module Gori
  # A portable project archive. The archive is a ZIP containing exactly a manifest and a
  # consistent, single-file SQLite snapshot. Locks and machine-local workspace bindings stay
  # outside it; the registry gives an imported copy a fresh short id.
  module ProjectArchive
    FORMAT_VERSION     = 1
    MAX_MANIFEST_BYTES = 64 * 1024
    # ZIP32 can represent nearly 4 GiB per entry, but expanding an untrusted archive that large
    # into the private import directory is not a reasonable default. The manifest and database
    # together may use at most 2 GiB uncompressed; reserve the full manifest ceiling here.
    MAX_UNCOMPRESSED_BYTES = 2_i64 * 1024 * 1024 * 1024
    MAX_DATABASE_BYTES     = MAX_UNCOMPRESSED_BYTES - MAX_MANIFEST_BYTES

    record Inventory,
      flows : Int64,
      session_slots : Int32,
      env_vars : Int32,
      upstream_credentials : Bool,
      disabled_pipe_rules : Int32,
      disabled_exec_probe_rules : Int32,
      disabled_body_file_stubs : Int32,
      reset_network_settings : Int32,
      reset_host_overrides : Int32 do
      def summary : String
        "#{flows} #{flows == 1 ? "flow" : "flows"}, " \
        "#{session_slots} #{session_slots == 1 ? "session slot" : "session slots"}, " \
        "#{env_vars} project #{env_vars == 1 ? "env var" : "env vars"}, " \
        "upstream proxy credentials #{upstream_credentials ? "set" : "not set"}"
      end

      def import_safety : String
        "disable #{disabled_pipe_rules} pipe Rewriter #{disabled_pipe_rules == 1 ? "rule" : "rules"}, " \
        "#{disabled_exec_probe_rules} exec Probe #{disabled_exec_probe_rules == 1 ? "rule" : "rules"}, and " \
        "#{disabled_body_file_stubs} file-backed short-circuit #{disabled_body_file_stubs == 1 ? "stub" : "stubs"}; " \
        "reset #{reset_network_settings} project network #{reset_network_settings == 1 ? "setting" : "settings"} and " \
        "#{reset_host_overrides} host #{reset_host_overrides == 1 ? "override" : "overrides"}"
      end
    end

    record Manifest,
      format_version : Int32,
      project_name : String,
      gori_version : String,
      schema_version : Int32,
      created_at : String,
      flow_count : Int64 do
      include JSON::Serializable
    end

    # A validated, extracted archive that has not yet changed the local project registry.
    # Keeping this separate from the actual registration lets CLI and TUI show the archive's
    # contents and resolve a name before any project directory is created.
    class PreparedImport
      getter manifest : Manifest
      getter inventory : Inventory

      def initialize(@workdir : String, @database_path : String, @manifest : Manifest,
                     @inventory : Inventory)
        @closed = false
      end

      def import_into(registry : ProjectRegistry, name : String? = nil) : Project
        override = name.presence
        using_archive_name = override.nil? || override == @manifest.project_name
        raise Gori::Error.new("project archive is already closed") if @closed
        registry.import_database(override || @manifest.project_name, @database_path)
      rescue ex : Gori::Error
        if using_archive_name && ex.message.to_s.includes?("control characters")
          raise Gori::Error.new("archive project name contains control characters; provide an explicit safe project name " \
                                "with `--name NAME` or choose one in the project picker")
        end
        raise ex
      end

      def close : Nil
        return if @closed
        @closed = true
        FileUtils.rm_rf(@workdir)
      end
    end

    # A WAL-safe snapshot ready to be written as a ZIP. It lives in a private temp directory
    # until `close`, so a TUI can show a confirmation with counts from the exact DB it will
    # write rather than recapturing after the operator confirms.
    class PreparedExport
      getter project : Project
      getter inventory : Inventory
      getter manifest : Manifest

      def initialize(@workdir : String, @database_path : String, @project : Project,
                     @manifest : Manifest, @inventory : Inventory)
        @closed = false
      end

      def write(path : String, *, overwrite : Bool = false) : String
        raise Gori::Error.new("project archive is already closed") if @closed
        target = resolve_target(path)
        refuse_existing_target(target, overwrite)
        temp = write_temporary_archive(target)
        begin
          install_archive(temp, target, overwrite)
        ensure
          File.delete?(temp)
        end
        target
      rescue ex : Compress::Zip::Error
        raise Gori::Error.new("could not write project archive: #{ex.message}")
      end

      private def resolve_target(path : String) : String
        target = Path[path].expand(home: true).to_s
        raise Gori::Error.new("project archive destination is blank") if target.strip.empty?
        raise Gori::Error.new("project archive destination is a directory: #{target}") if File.directory?(target)
        parent = File.dirname(target)
        raise Gori::Error.new("no such directory: #{parent}") unless Dir.exists?(parent)
        target = File.realpath(target) if File.symlink?(target) && File.exists?(target)

        canonical_target = Paths.canonical_file(target)
        canonical_project_dir = Paths.canonical_file(@project.dir)
        if canonical_target == Paths.canonical_file(@project.db_path) ||
           canonical_target.starts_with?(canonical_project_dir + File::SEPARATOR)
          raise Gori::Error.new("project archives cannot be written inside the source project directory")
        end
        target
      end

      private def refuse_existing_target(target : String, overwrite : Bool) : Nil
        if ProjectArchive.destination_exists?(target) && !overwrite
          raise Gori::Error.new("destination already exists: #{target} (use --force to replace it)")
        end
      end

      private def write_temporary_archive(target : String) : String
        temp = nil.as(String?)
        File.tempfile(".#{File.basename(target)}.gori", ".tmp", dir: File.dirname(target)) do |file|
          temp = file.path
          Compress::Zip::Writer.open(file) do |zip|
            zip.add("manifest.json", @manifest.to_json)
            zip.add("gori.db") do |entry|
              File.open(@database_path, "r") { |db| IO.copy(db, entry) }
            end
          end
          file.flush
          file.fsync
        end
        temp || raise Gori::Error.new("could not create a temporary project archive")
      rescue ex
        temp.try { |path| File.delete?(path) }
        raise ex
      end

      private def install_archive(temp : String, target : String, overwrite : Bool) : Nil
        if overwrite
          File.rename(temp, target)
        else
          # Hard-linking the completed temp file claims the destination atomically, so a file
          # that appeared after the first exists? check is never silently overwritten.
          begin
            link_archive(temp, target)
            File.delete(temp)
          rescue ex : IO::Error
            raise ex if ProjectArchive.destination_exists?(target)
            install_archive_copy(temp, target)
          end
        end
      end

      # Some portable filesystems (notably exFAT and some SMB shares) do not support hard links.
      # Stage a copy beside the destination, sync it, then rename it into place. The immediate
      # existence check preserves the no-overwrite behavior for the ordinary non-racing case.
      private def install_archive_copy(temp : String, target : String) : Nil
        fallback = nil.as(String?)
        File.tempfile(".#{File.basename(target)}.gori-copy", ".tmp", dir: File.dirname(target)) do |file|
          fallback = file.path
          File.open(temp, "r") { |source| IO.copy(source, file) }
          file.flush
          file.fsync
        end
        raise Gori::Error.new("destination already exists: #{target} (use --force to replace it)") \
          if ProjectArchive.destination_exists?(target)
        fallback_path = fallback || raise(Gori::Error.new("could not stage project archive copy"))
        File.rename(fallback_path, target)
      ensure
        fallback.try { |path| File.delete?(path) }
      end

      protected def link_archive(source : String, destination : String) : Nil
        File.link(source, destination)
      end

      def close : Nil
        return if @closed
        @closed = true
        FileUtils.rm_rf(@workdir)
      end
    end

    def self.prepare_export(project : Project) : PreparedExport
      raise Gori::Error.new("project database is missing: #{project.db_path}") unless File.file?(project.db_path)
      workdir = private_tempdir("gori-export")
      snapshot = File.join(workdir, Project::DB_FILE)
      guard = nil.as(OpenLock?)
      success = false
      begin
        guard = OpenLock.try_shared(project.db_path)
        DB.open("sqlite3:#{project.db_path}?busy_timeout=5000") do |db|
          db.using_connection { |conn| conn.exec("VACUUM INTO ?", snapshot) }
        end
        File.chmod(snapshot, File::Permissions.new(0o600))
        raise Gori::Error.new("project database exceeds the 2 GiB uncompressed archive size limit") if File.info(snapshot).size > MAX_DATABASE_BYTES
        version, inventory = inspect_database(snapshot)
        manifest = Manifest.new(FORMAT_VERSION, project.name, Gori::VERSION,
          version, Time.utc.to_rfc3339, inventory.flows)
        prepared = PreparedExport.new(workdir, snapshot, project, manifest, inventory)
        success = true
        prepared
      rescue ex : Gori::Error
        raise ex
      rescue ex : DB::Error | SQLite3::Exception | IO::Error
        raise Gori::Error.new("could not snapshot project #{project.name.inspect}: #{ex.message}")
      ensure
        guard.try(&.close)
        FileUtils.rm_rf(workdir) unless success
      end
    end

    def self.prepare_import(path : String) : PreparedImport
      source = Path[path].expand(home: true).to_s
      raise Gori::Error.new("project archive does not exist: #{source}") unless File.file?(source)
      workdir = private_tempdir("gori-import")
      database = File.join(workdir, Project::DB_FILE)
      success = false

      begin
        manifest = parse_manifest(extract_entries(source, database))
        version, inventory = inspect_database(database, reject_user_schema_objects: true)
        validate_manifest_database!(manifest, version, inventory)
        sanitize_import_database(database)
        prepared = PreparedImport.new(workdir, database, manifest, inventory)
        success = true
        prepared
      rescue ex : Gori::Error
        raise ex
      rescue ex : Compress::Zip::Error | Compress::Deflate::Error | JSON::ParseException | DB::Error | SQLite3::Exception | IO::Error
        raise Gori::Error.new("could not read project archive '#{source}': #{ex.message}")
      ensure
        FileUtils.rm_rf(workdir) unless success
      end
    end

    private def self.extract_entries(source : String, database : String) : String
      validate_uncompressed_size!(source)
      manifest_json = nil.as(String?)
      seen_manifest = false
      seen_database = false
      uncompressed_bytes = 0_i64
      Compress::Zip::Reader.open(source) do |zip|
        zip.each_entry do |entry|
          case entry.filename
          when "manifest.json"
            raise Gori::Error.new("project archive contains duplicate manifest.json entries") if seen_manifest
            seen_manifest = true
            raw_manifest = read_entry(entry.io, MAX_MANIFEST_BYTES)
            uncompressed_bytes += raw_manifest.size
            ensure_uncompressed_limit!(uncompressed_bytes)
            manifest_json = String.new(raw_manifest)
          when "gori.db"
            raise Gori::Error.new("project archive contains duplicate gori.db entries") if seen_database
            seen_database = true
            File.open(database, "w", perm: File::Permissions.new(0o600)) do |file|
              uncompressed_bytes += copy_entry(entry.io, file, MAX_DATABASE_BYTES)
              ensure_uncompressed_limit!(uncompressed_bytes)
              file.flush
              file.fsync
            end
          else
            raise Gori::Error.new("project archive has an unexpected entry: #{entry.filename.inspect}")
          end
        end
      end
      raise Gori::Error.new("project archive is missing manifest.json") unless seen_manifest
      raise Gori::Error.new("project archive is missing gori.db") unless seen_database
      manifest_json || raise Gori::Error.new("project archive is missing manifest.json")
    end

    private def self.validate_manifest_database!(manifest : Manifest, version : Int32,
                                                 inventory : Inventory) : Nil
      if manifest.schema_version != version
        raise Gori::Error.new("project archive manifest says schema v#{manifest.schema_version}, " \
                              "but its database is v#{version}")
      end
      if manifest.flow_count != inventory.flows
        raise Gori::Error.new("project archive manifest says #{manifest.flow_count} flows, " \
                              "but its database has #{inventory.flows}")
      end
    end

    # The one operator-facing disclosure used before an archive is written or installed.
    def self.disclosure(inventory : Inventory) : String
      "Contains the complete project database: #{inventory.summary}. " \
      "Import will #{inventory.import_safety}. The archive is unredacted and may contain " \
      "captured request/response credentials, session and env values, and upstream proxy credentials. " \
      "OAST sessions and provider tokens, plus Authorize identities, remain in the imported copy. " \
      "Keep the archive as carefully as the source project."
    end

    # A zip-bomb ratio cannot be inferred safely from the compressed file's size. Read the
    # central directory first and reject a declared expansion above the cap before allocating
    # the extracted database. `copy_entry` enforces the same limit on bytes actually produced.
    private def self.validate_uncompressed_size!(source : String) : Nil
      total = 0_i64
      Compress::Zip::File.open(source) do |zip|
        zip.entries.each do |entry|
          total += entry.uncompressed_size.to_i64
          ensure_uncompressed_limit!(total)
        end
      end
    end

    private def self.ensure_uncompressed_limit!(total : Int64) : Nil
      if total > MAX_UNCOMPRESSED_BYTES
        raise Gori::Error.new("project archive exceeds the 2 GiB uncompressed size limit")
      end
    end

    # `File.exists?` follows symlinks, so a dangling link otherwise slips past the
    # overwrite check and fails later with a lower-level link/rename error.
    def self.destination_exists?(path : String) : Bool
      File.exists?(path) || File.symlink?(path)
    end

    private def self.private_tempdir(prefix : String) : String
      10.times do
        path = File.tempname("gori-#{prefix}")
        begin
          Dir.mkdir(path, 0o700)
          return path
        rescue File::AlreadyExistsError
          next
        end
      end
      raise Gori::Error.new("could not create a private temporary directory")
    end

    private def self.inspect_database(path : String, *, reject_user_schema_objects : Bool = false) : {Int32, Inventory}
      DB.open("sqlite3:#{path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("PRAGMA query_only = ON")
          version = conn.scalar("PRAGMA user_version").as(Int64).to_i
          unsupported_objects = conn.query_all("SELECT type FROM sqlite_master " \
                                               "WHERE type IN ('trigger', 'view') AND name NOT LIKE 'sqlite_%'", as: String)
          if reject_user_schema_objects && !unsupported_objects.empty?
            raise Gori::Error.new("project archive database contains unsupported SQLite triggers or views")
          end
          tables = conn.query_all("SELECT name FROM sqlite_master WHERE type = 'table' " \
                                  "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'", as: String)
          raise Gori::Error.new("not a gori project database") unless version > 0 && tables.includes?("flows")
          if version > Store::Schema::VERSION
            raise Gori::Error.new("database schema v#{version} was written by a newer version of gori " \
                                  "(this build understands up to v#{Store::Schema::VERSION}) — upgrade gori")
          end
          validate_core_schema!(conn, version, tables)
          quick_check = conn.scalar("PRAGMA quick_check").as(String)
          raise Gori::Error.new("project database integrity check failed: #{quick_check}") unless quick_check == "ok"
          flows = conn.scalar("SELECT COUNT(*) FROM flows").as(Int64)
          {version, build_inventory(conn, tables, flows)}
        end
      end
    end

    private def self.build_inventory(conn : DB::Connection, tables : Array(String), flows : Int64) : Inventory
      raw_slots = setting(conn, Store::SESSION_SLOTS_KEY)
      slots = SessionSlot.parse_json(raw_slots).size
      env_vars = setting(conn, Env::PROJECT_VARS_KEY).try { |raw| Env.parse_vars_json(raw).size } || 0
      # The archive copies the full DB. Treat any stored auth row as sensitive, even if a
      # stale or malformed value cannot be parsed into the current credential record.
      upstream_credentials = !setting(conn, Settings::PROJECT_UPSTREAM_AUTH_KEY).try(&.strip.presence).nil?
      rule_columns = table_columns(conn, "match_rules") if tables.includes?("match_rules")
      disabled_pipe_rules = count_rows(conn,
        "SELECT COUNT(*) FROM match_rules WHERE enabled != 0 AND lower(op) = 'pipe'")
      disabled_exec_probe_rules = if tables.includes?("probe_custom_rules")
                                    count_rows(conn,
                                      "SELECT COUNT(*) FROM probe_custom_rules WHERE enabled != 0 AND lower(kind) = 'exec'")
                                  else
                                    0
                                  end
      disabled_body_file_stubs = if rule_columns.try(&.includes?("body_file"))
                                   count_rows(conn,
                                     "SELECT COUNT(*) FROM match_rules WHERE enabled != 0 " \
                                     "AND lower(op) = 'short_circuit' AND body_file != ''")
                                 else
                                   0
                                 end
      reset_network_settings = if tables.includes?("settings")
                                 Settings::PROJECT_NETWORK_KEYS.reduce(0) do |count, key|
                                   count + count_rows(conn, "SELECT COUNT(*) FROM settings WHERE key = ?", key.key)
                                 end
                               else
                                 0
                               end
      reset_host_overrides = tables.includes?("host_overrides") ? count_rows(conn, "SELECT COUNT(*) FROM host_overrides") : 0
      Inventory.new(flows, slots, env_vars, upstream_credentials,
        disabled_pipe_rules, disabled_exec_probe_rules, disabled_body_file_stubs,
        reset_network_settings, reset_host_overrides)
    end

    private def self.validate_core_schema!(conn : DB::Connection, version : Int32,
                                           tables : Array(String)) : Nil
      required = {
        "flows" => %w[id created_at scheme host port method target http_version request_head request_body
          response_head response_body status reason content_type request_size response_size
          state ttfb_us duration_us error h2_conn_id h2_stream_id],
      }
      if version == Store::Schema::VERSION
        required["flows"] += %w[unsent fts_dirty short_circuited advisory request_content_type
          connect_protocol source source_surface source_ref static_asset]
        required.merge!(
          {
            "flows_fts"          => %w[req resp],
            "settings"           => %w[key value],
            "scope_rules"        => %w[id kind match_type pattern],
            "match_rules"        => %w[id enabled target part pattern replacement position op match_kind name host body_file respond respond_args],
            "probe_custom_rules" => %w[id title description side region kind pattern severity enabled],
            "host_overrides"     => %w[id host ip],
            "oast_providers"     => %w[id created_at updated_at name kind host token enabled position],
            "oast_sessions"      => %w[id created_at provider_id kind server_url correlation_id secret private_key_pem token last_poll_at provider_key],
          })
      end

      required.each do |table, columns|
        unless tables.includes?(table)
          raise Gori::Error.new("project archive database is missing required table #{table}")
        end
        missing = columns.reject { |column| table_columns(conn, table).includes?(column) }
        unless missing.empty?
          raise Gori::Error.new("project archive database table #{table} is missing required column(s): #{missing.join(", ")}")
        end
      end
    end

    private def self.table_columns(conn : DB::Connection, table : String) : Array(String)
      conn.query_all("SELECT name FROM pragma_table_info(?)", table, as: String)
    end

    private def self.count_rows(conn : DB::Connection, query : String, key : String? = nil) : Int32
      count = if key
                conn.scalar(query, key).as(Int64)
              else
                conn.scalar(query).as(Int64)
              end
      count.to_i
    end

    # A snapshot is imported as data, never as executable or local-machine configuration. Keep
    # this in the shared archive engine so the picker and CLI make exactly the same copy.
    private def self.sanitize_import_database(path : String) : Nil
      DB.open("sqlite3:#{path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          begin
            if table_exists?(conn, "settings")
              Settings::PROJECT_NETWORK_KEYS.each do |key|
                conn.exec("DELETE FROM settings WHERE key = ?", key.key)
              end
            end
            conn.exec("DELETE FROM host_overrides") if table_exists?(conn, "host_overrides")
            if table_exists?(conn, "match_rules")
              conn.exec("UPDATE match_rules SET enabled = 0 WHERE lower(op) = 'pipe'")
              if table_columns(conn, "match_rules").includes?("body_file")
                conn.exec("UPDATE match_rules SET enabled = 0 WHERE lower(op) = 'short_circuit' AND body_file != ''")
              end
            end
            if table_exists?(conn, "probe_custom_rules")
              conn.exec("UPDATE probe_custom_rules SET enabled = 0 WHERE lower(kind) = 'exec'")
            end
            conn.exec("COMMIT")
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end
    end

    private def self.table_exists?(conn : DB::Connection, table : String) : Bool
      conn.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", table).as(Int64) > 0
    end

    private def self.setting(conn : DB::Connection, key : String) : String?
      conn.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
    rescue DB::Error | SQLite3::Exception
      nil # old schemas may not have project settings yet
    end

    private def self.parse_manifest(raw : String) : Manifest
      manifest = Manifest.from_json(raw)
      validate_manifest!(manifest)
      manifest
    rescue Time::Format::Error
      raise Gori::Error.new("project archive has an invalid creation time")
    end

    private def self.validate_manifest!(manifest : Manifest) : Nil
      unless manifest.format_version == FORMAT_VERSION
        raise Gori::Error.new("unsupported project archive format v#{manifest.format_version}")
      end
      raise Gori::Error.new("project archive has no valid project name") if manifest.project_name.strip.empty?
      validate_schema_version!(manifest.schema_version)
      raise Gori::Error.new("project archive has an invalid flow count") if manifest.flow_count < 0
      raise Gori::Error.new("project archive has no gori version") if manifest.gori_version.strip.empty?
      Time.parse_rfc3339(manifest.created_at)
    end

    private def self.validate_schema_version!(version : Int32) : Nil
      if version > Store::Schema::VERSION
        raise Gori::Error.new("project archive requires database schema v#{version}, " \
                              "but this build supports up to v#{Store::Schema::VERSION} — upgrade gori")
      end
      raise Gori::Error.new("project archive has an invalid schema version") unless version > 0
    end

    private def self.read_entry(io : IO, limit : Int64) : Bytes
      output = IO::Memory.new
      copy_entry(io, output, limit)
      output.to_slice
    end

    private def self.copy_entry(source : IO, destination : IO, limit : Int64) : Int64
      buffer = Bytes.new(64 * 1024)
      total = 0_i64
      while (read = source.read(buffer)) > 0
        total += read
        raise Gori::Error.new("project archive entry exceeds the 2 GiB uncompressed size limit") if total > limit
        destination.write(buffer[0, read])
      end
      total
    end
  end
end
