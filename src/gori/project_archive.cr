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
require "./store/schema"

module Gori
  # A portable project archive. The archive is a ZIP containing exactly a manifest and a
  # consistent, single-file SQLite snapshot. Locks and machine-local workspace bindings stay
  # outside it; the registry gives an imported copy a fresh short id.
  module ProjectArchive
    FORMAT_VERSION     =               1
    MAX_ENTRY_BYTES    = 0xffff_ff00_i64 # stdlib ZIP is ZIP32 and cannot represent larger entries.
    MAX_MANIFEST_BYTES = 64 * 1024

    record Inventory,
      flows : Int64,
      session_slots : Int32,
      env_vars : Int32,
      upstream_credentials : Bool do
      def summary : String
        "#{flows} #{flows == 1 ? "flow" : "flows"}, " \
        "#{session_slots} #{session_slots == 1 ? "session slot" : "session slots"}, " \
        "#{env_vars} project #{env_vars == 1 ? "env var" : "env vars"}, " \
        "upstream proxy credentials #{upstream_credentials ? "set" : "not set"}"
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
        raise Gori::Error.new("project archive is already closed") if @closed
        registry.import_database(name.presence || @manifest.project_name, @database_path)
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
          File.link(temp, target)
          File.delete(temp)
        end
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
        raise Gori::Error.new("project database exceeds the ZIP32 4 GiB entry limit") if File.info(snapshot).size > MAX_ENTRY_BYTES
        version, inventory = inspect_database(snapshot)
        manifest = Manifest.new(FORMAT_VERSION, project.name, Gori::VERSION,
          version, Time.utc.to_rfc3339, inventory.flows)
        prepared = PreparedExport.new(workdir, snapshot, project, manifest, inventory)
        success = true
        prepared
      rescue ex : Gori::Error
        raise ex
      rescue ex : DB::Error | SQLite3::Exception | IO::Error
        raise Gori::Error.new("could not snapshot project '#{project.name}': #{ex.message}")
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

      begin
        manifest = parse_manifest(extract_entries(source, database))
        version, inventory = inspect_database(database)
        validate_manifest_database!(manifest, version, inventory)
        PreparedImport.new(workdir, database, manifest, inventory)
      rescue ex : Gori::Error
        FileUtils.rm_rf(workdir)
        raise ex
      rescue ex : Compress::Zip::Error | JSON::ParseException | DB::Error | SQLite3::Exception | IO::Error
        FileUtils.rm_rf(workdir)
        raise Gori::Error.new("could not read project archive '#{source}': #{ex.message}")
      end
    end

    private def self.extract_entries(source : String, database : String) : String
      manifest_json = nil.as(String?)
      seen_manifest = false
      seen_database = false
      Compress::Zip::Reader.open(source) do |zip|
        zip.each_entry do |entry|
          case entry.filename
          when "manifest.json"
            raise Gori::Error.new("project archive contains duplicate manifest.json entries") if seen_manifest
            seen_manifest = true
            manifest_json = String.new(read_entry(entry.io, MAX_MANIFEST_BYTES))
          when "gori.db"
            raise Gori::Error.new("project archive contains duplicate gori.db entries") if seen_database
            seen_database = true
            File.open(database, "w", perm: File::Permissions.new(0o600)) do |file|
              copy_entry(entry.io, file, MAX_ENTRY_BYTES)
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
      "Captured requests and responses, session values, env values, and proxy credentials " \
      "are copied as stored; project archives are not redacted."
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

    private def self.inspect_database(path : String) : {Int32, Inventory}
      DB.open("sqlite3:#{path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("PRAGMA query_only = ON")
          version = conn.scalar("PRAGMA user_version").as(Int64).to_i
          tables = conn.query_all("SELECT name FROM sqlite_master WHERE type = 'table' " \
                                  "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'", as: String)
          raise Gori::Error.new("not a gori project database") unless version > 0 && tables.includes?("flows")
          if version > Store::Schema::VERSION
            raise Gori::Error.new("database schema v#{version} was written by a newer version of gori " \
                                  "(this build understands up to v#{Store::Schema::VERSION}) — upgrade gori")
          end
          quick_check = conn.scalar("PRAGMA quick_check").as(String)
          raise Gori::Error.new("project database integrity check failed: #{quick_check}") unless quick_check == "ok"
          flows = conn.scalar("SELECT COUNT(*) FROM flows").as(Int64)
          raw_slots = setting(conn, Store::SESSION_SLOTS_KEY)
          slots = SessionSlot.parse_json(raw_slots).size
          env_vars = setting(conn, Env::PROJECT_VARS_KEY).try { |raw| Env.parse_vars_json(raw).size } || 0
          # The archive copies the full DB. Treat any stored auth row as sensitive, even if a
          # stale or malformed value cannot be parsed into the current credential record.
          upstream_credentials = !setting(conn, Settings::PROJECT_UPSTREAM_AUTH_KEY).try(&.strip.presence).nil?
          {version, Inventory.new(flows, slots, env_vars, upstream_credentials)}
        end
      end
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

    private def self.copy_entry(source : IO, destination : IO, limit : Int64) : Nil
      buffer = Bytes.new(64 * 1024)
      total = 0_i64
      while (read = source.read(buffer)) > 0
        total += read
        raise Gori::Error.new("project archive entry exceeds the supported ZIP32 size") if total > limit
        destination.write(buffer[0, read])
      end
    end
  end
end
