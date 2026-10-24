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
require "./probe/mode"
require "./store/schema"
require "./protobuf/schemas"

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
    # Per-project answers to the exporter's GLOBAL rule libraries, keyed by that machine's ids.
    GLOBAL_OVERRIDE_KEYS = {Store::REWRITER_OVERRIDES_KEY, Store::COLORMARKER_OVERRIDES_KEY}
    # How the CLI and the picker name another project when the archive's own name is unusable.
    DEFAULT_RENAME_HINT = "with `--name NAME` or choose one in the project picker " \
                          "(`gori run project rename` changes it later)"

    # An export refused because its destination already exists. Typed, so each surface names
    # its own override (`--force`, the picker's confirm, an MCP argument) instead of this one
    # sentence naming a flag only the CLI has.
    class DestinationExists < Gori::Error
      getter path : String

      def initialize(@path : String)
        super("destination already exists: #{@path}")
      end
    end

    # An export refused because its destination is inside a directory the caller protected
    # (MCP protects gori's home, which holds every project's database and the settings).
    class ProtectedDestination < Gori::Error
      getter path : String
      getter dir : String

      def initialize(@path : String, @dir : String)
        super("project archives cannot be written inside #{@dir}: #{@path}")
      end
    end

    record Inventory,
      flows : Int64,
      session_slots : Int32,
      env_vars : Int32,
      upstream_credentials : Bool,
      disabled_pipe_rules : Int32,
      disabled_exec_probe_rules : Int32,
      disabled_body_file_stubs : Int32,
      reset_network_settings : Int32,
      reset_host_overrides : Int32,
      reset_global_overrides : Int32,
      disabled_auto_refresh_slots : Int32,
      reset_probe_mode : Probe::Mode?,
      exec_repeaters : Int32,
      exec_fuzz_templates : Int32,
      exec_decoder_tabs : Int32,
      exec_env_vars : Int32,
      local_file_paths : Array(String),
      reset_grpc_descriptors : Bool do
      def summary : String
        "#{flows} #{flows == 1 ? "flow" : "flows"}, " \
        "#{session_slots} #{session_slots == 1 ? "session slot" : "session slots"}, " \
        "#{env_vars} project #{env_vars == 1 ? "env var" : "env vars"}, " \
        "upstream proxy credentials #{upstream_credentials ? "set" : "not set"}"
      end

      def import_safety : String
        sentence = "disable #{disabled_pipe_rules} pipe Rewriter #{disabled_pipe_rules == 1 ? "rule" : "rules"}, " \
                   "#{disabled_exec_probe_rules} exec Probe #{disabled_exec_probe_rules == 1 ? "rule" : "rules"}, and " \
                   "#{disabled_body_file_stubs} file-backed short-circuit #{disabled_body_file_stubs == 1 ? "stub" : "stubs"}; " \
                   "reset #{reset_network_settings} project network #{reset_network_settings == 1 ? "setting" : "settings"}, " \
                   "#{reset_host_overrides} host #{reset_host_overrides == 1 ? "override" : "overrides"}, and " \
                   "#{reset_global_overrides} global rule #{reset_global_overrides == 1 ? "override" : "overrides"}; " \
                   "turn off automatic refresh on #{disabled_auto_refresh_slots} session " \
                   "#{disabled_auto_refresh_slots == 1 ? "slot" : "slots"}"
        reset_probe_mode.try { |mode| sentence += "; and reset Probe mode from #{mode.label} to passive" }
        sentence += "; and clear the gRPC descriptor-set path, a local file read when the project opens" if reset_grpc_descriptors
        sentence
      end

      # Stored Fuzzer `file` sets and Miner wordlists name a path on the AUTHOR's machine that
      # this one opens when that tab runs, and reads into requests sent to the tab's target. Like
      # `exec:`, they act only on an explicit run, so they are disclosed (by path, so the operator
      # can judge the file) rather than rewritten. The path is archive-authored, may not be valid
      # UTF-8, and this sentence reaches a terminal, so it is escaped byte-wise and capped.
      LISTED_PATHS = 5

      def local_files : String?
        return nil if local_file_paths.empty?
        shown = local_file_paths.first(LISTED_PATHS).map do |path|
          text = Export::Escape.comment(path)
          text = "#{text[0, 200]}…" if text.size > 200
          %("#{text}")
        end
        more = local_file_paths.size - shown.size
        "#{local_file_paths.size} Fuzzer or Miner wordlist #{local_file_paths.size == 1 ? "path reads" : "paths read"} " \
        "a local file into the requests that tab sends when run: #{shown.join(", ")}#{more > 0 ? " and #{more} more" : ""}."
      end

      # Stored `exec:` chain steps stay as the operator-visible bytes they are; they run a local
      # command only on an explicit send, so they are disclosed rather than rewritten.
      def exec_chains : String?
        return nil if exec_repeaters + exec_fuzz_templates + exec_decoder_tabs + exec_env_vars == 0
        "#{exec_repeaters} Repeater #{exec_repeaters == 1 ? "tab" : "tabs"}, " \
        "#{exec_fuzz_templates} Fuzzer #{exec_fuzz_templates == 1 ? "template" : "templates"}, " \
        "#{exec_decoder_tabs} Decoder #{exec_decoder_tabs == 1 ? "tab" : "tabs"} and " \
        "#{exec_env_vars} project #{exec_env_vars == 1 ? "env var" : "env vars"} contain exec:, " \
        "a chain step that runs a local command when that request is sent or that input is edited."
      end
    end

    record Manifest,
      format_version : Int32,
      project_name : String,
      gori_version : String,
      schema_version : Int32,
      created_at : String,
      flow_count : Int64,
      # The registry's `.tags` sidecar, which the database does not carry. Optional, so an
      # archive from before tags (or for a `--db` project) still reads; an older gori ignores it.
      # Any JSON, not `Array(String)`: a hand-made `"tags":"web"` must not refuse the archive.
      tags : JSON::Any? = nil do
      include JSON::Serializable

      # The string tags, whatever shape the untrusted manifest gave them.
      def tag_strings : Array(String)
        tags.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      end
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

      # *rename_hint* finishes the sentence for an archive whose own name is unusable, in the
      # caller's words: how THAT surface names a different project.
      def import_into(registry : ProjectRegistry, name : String? = nil, *,
                      rename_hint : String = DEFAULT_RENAME_HINT) : Project
        raise Gori::Error.new("project archive is already closed") if @closed
        project = registry.import_database(target_name(name), @database_path)
        # Best-effort and salvaged, not validated: the archive is untrusted, and a bad tag is no
        # reason to refuse the traffic it came with.
        unless (tags = @manifest.tag_strings).empty?
          registry.set_tags(project, ProjectRegistry.salvage_tags(tags)) rescue nil
        end
        project
      rescue ex : Gori::Error
        raise explain_name_error(ex, name, rename_hint)
      end

      # The refusal #import_into would give *name* for a reason the name itself decides (taken,
      # shadowed, unsluggable, control characters), or nil when the name is free right now.
      # Creates nothing; the import still claims its directory atomically.
      def name_problem(registry : ProjectRegistry, name : String? = nil, *,
                       rename_hint : String = DEFAULT_RENAME_HINT) : String?
        registry.import_target(target_name(name))
        nil
      rescue ex : Gori::Error
        explain_name_error(ex, name, rename_hint).message
      end

      # The display name an import under *name* asks the registry for: the override when one
      # was given, else the name the archive carries.
      def target_name(name : String? = nil) : String
        (name.presence || @manifest.project_name).strip
      end

      private def explain_name_error(ex : Gori::Error, name : String?, rename_hint : String) : Gori::Error
        override = name.presence
        using_archive_name = override.nil? || override == @manifest.project_name
        if using_archive_name && ex.message.to_s.includes?("control characters")
          return Gori::Error.new("archive project name contains control characters; provide an explicit " \
                                 "safe project name #{rename_hint}")
        end
        ex
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
                     @manifest : Manifest, @inventory : Inventory, @loose_database : Bool = false)
        @closed = false
      end

      # *protected_dir* is refused as a destination along with the source project, and
      # *archives_only* limits `overwrite` to an existing archive; see
      # `ProjectArchive.resolve_destination`, which runs again here for the path installed to.
      def write(path : String, *, overwrite : Bool = false, protected_dir : String? = nil,
                archives_only : Bool = false) : String
        raise Gori::Error.new("project archive is already closed") if @closed
        target = ProjectArchive.resolve_destination(path, @project, overwrite: overwrite,
          loose_database: @loose_database, protected_dir: protected_dir, archives_only: archives_only)
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
          rescue IO::Error
            # The destination appeared after the first check: the same refusal, not a raw link
            # error. Only the link is covered, so a later failure is never misreported as this.
            raise DestinationExists.new(target) if ProjectArchive.destination_exists?(target)
            return install_archive_copy(temp, target)
          end
          File.delete(temp)
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
        raise DestinationExists.new(target) if ProjectArchive.destination_exists?(target)
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

    # Where an export of *source* to *path* would land, or the refusal. A function of its
    # arguments alone, so a surface can run it BEFORE paying for the snapshot; `write` runs it
    # again for the path it installs to.
    #
    # *loose_database* is a bare database file (`gori mcp --db`), not a registry project: its
    # directory is the operator's, so only the database and its sidecars (`-wal`, `-shm`, the
    # open lock) are refused, not everything beside it.
    #
    # Replacing an existing file is refused outright when it is a database a running gori has
    # open: renaming the archive over it would unlink the file that process keeps writing into.
    # *archives_only* (MCP) also refuses replacing anything that is not already an archive
    # (`archive?`): the operator who types a CLI path chose it; an agent's path is not a choice.
    def self.resolve_destination(path : String, source : Project, *, overwrite : Bool = false,
                                 loose_database : Bool = false, protected_dir : String? = nil,
                                 archives_only : Bool = false) : String
      target = expand_destination(path)
      canonical_target = Paths.canonical_file(target)
      refuse_source_destination(canonical_target, source, loose_database)
      if dir = protected_dir
        raise ProtectedDestination.new(target, dir) if Paths.within?(canonical_target, Paths.canonical_file(dir))
      end
      refuse_existing_destination(target, overwrite)
      if archives_only && destination_exists?(target) && !archive?(target)
        raise Gori::Error.new("destination exists and is not a gori project archive: #{target} — overwrite:true " \
                              "replaces only an earlier export; choose another 'path'")
      end
      target
    end

    # Whether *path* has a project archive's shape: a zip holding exactly `manifest.json` and
    # `gori.db`, what `write_temporary_archive` writes. Read off the central directory, so a
    # multi-GiB archive costs a seek, not a decompress; anything unreadable is not one. Only a
    # regular file is opened: a FIFO would block the open, and the MCP server with it.
    def self.archive?(path : String) : Bool
      return false unless File.info(path, follow_symlinks: false).file?
      names = Compress::Zip::File.open(path, &.entries.map(&.filename))
      names.sort == ["gori.db", "manifest.json"]
    rescue Compress::Zip::Error | IO::Error
      false
    end

    private def self.expand_destination(path : String) : String
      raise Gori::Error.new("project archive destination is blank") if path.strip.empty?
      target = Path[path].expand(home: true).to_s
      raise Gori::Error.new("project archive destination is a directory: #{target}") if File.directory?(target)
      parent = File.dirname(target)
      raise Gori::Error.new("no such directory: #{parent}") unless Dir.exists?(parent)
      File.symlink?(target) && File.exists?(target) ? File.realpath(target) : target
    end

    private def self.refuse_source_destination(canonical_target : String, source : Project,
                                               loose_database : Bool) : Nil
      source_db = Paths.canonical_file(source.db_path)
      if loose_database
        # The exact set, not a prefix: `capture.db.gori` beside `capture.db` is an ordinary file.
        if canonical_target == source_db ||
           {"-wal", "-shm", "-journal", OpenLock::SUFFIX}.any? { |s| canonical_target == source_db + s }
          raise Gori::Error.new("project archives cannot be written over the source database or its sidecar files")
        end
      elsif canonical_target == source_db || Paths.within?(canonical_target, Paths.canonical_file(source.dir))
        raise Gori::Error.new("project archives cannot be written inside the source project directory")
      end
    end

    private def self.refuse_existing_destination(target : String, overwrite : Bool) : Nil
      return unless destination_exists?(target)
      raise DestinationExists.new(target) unless overwrite
      if OpenLock.in_use?(target)
        raise Gori::Error.new("destination is a database open in a running gori instance: #{target}")
      end
    end

    def self.prepare_export(project : Project, *, loose_database : Bool = false) : PreparedExport
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
        tags = project.canonical? ? ProjectRegistry.new(File.dirname(project.dir)).tags_of(project) : [] of String
        manifest = Manifest.new(FORMAT_VERSION, project.name, Gori::VERSION,
          version, Time.utc.to_rfc3339, inventory.flows, tags.empty? ? nil : JSON::Any.new(tags.map { |t| JSON::Any.new(t) }))
        prepared = PreparedExport.new(workdir, snapshot, project, manifest, inventory, loose_database)
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
        version, inventory = inspect_database(database, importing: true)
        validate_manifest_database!(manifest, version, inventory)
        sanitize_import_database(database)
        refuse_missing_keys!(database)
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
      "Import will #{inventory.import_safety}. #{inventory.exec_chains.try { |text| "#{text} " }}" \
      "#{inventory.local_files.try { |text| "#{text} " }}" \
      "The archive is unredacted and may contain " \
      "captured request/response credentials, session and env values, and upstream proxy credentials. " \
      "OAST sessions and provider tokens, plus Authorize identities, remain in the imported copy; " \
      "an imported OAST session is not used for probe payloads until you resume it. " \
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

    # The write behind a TUI export (issues, notes, sequencer report, evidence, OpenAPI), whose
    # overlay asked before overwriting anything `destination_exists?` saw. It never writes
    # THROUGH a link: a destination in a shared directory such as /tmp can be a symlink another
    # local user planted (`issues.md -> ~/.zshenv`), dangling so it read as absent, or live so
    # the operator confirmed "file exists" for a file that is not theirs.
    #
    # The content is staged in a temp file beside it (created under the umask, as `File.write`
    # would, and fsync'd), then:
    # * an existing regular file is replaced by a rename (the confirmed overwrite; its mode is
    #   carried over, and a crash leaves the old file, never a truncated one);
    # * anything else that exists — a symlink, a FIFO, a device — is refused;
    # * nothing there: hard-linked into place, which fails if anything (a link included)
    #   appeared meanwhile. A filesystem with no hard links gets the same existence check
    #   immediately before a rename, as `install_archive_copy` does.
    def self.write_export_file(path : String, content : String) : Nil
      existing = File.info?(path, follow_symlinks: false)
      raise Gori::Error.new("refusing to write through a symlink or special file: #{path}") if existing && !existing.file?
      staged = File.tempname(".#{File.basename(path)}", ".tmp", dir: File.dirname(path))
      File.open(staged, "w", perm: File::Permissions.new(0o666)) do |file|
        file.print(content)
        file.flush
        file.fsync
      end
      if existing
        File.chmod(staged, existing.permissions)
        File.rename(staged, path)
        return
      end
      begin
        File.link(staged, path)
      rescue IO::Error
        raise DestinationExists.new(path) if destination_exists?(path)
        File.rename(staged, path)
      end
    ensure
      staged.try { |t| File.delete?(t) }
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

    private def self.inspect_database(path : String, *, importing : Bool = false) : {Int32, Inventory}
      DB.open("sqlite3:#{path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("PRAGMA query_only = ON")
          version = conn.scalar("PRAGMA user_version").as(Int64).to_i
          # gori never creates a trigger or view, and SQLite reserves `sqlite_*` names, so
          # any one is foreign: no name exemption (an unescaped LIKE once let `sqliteXkeep` through).
          unsupported_objects = conn.query_all("SELECT type FROM sqlite_master " \
                                               "WHERE type IN ('trigger', 'view')", as: String)
          if importing && !unsupported_objects.empty?
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
          if importing
            refuse_exhausted_ids!(conn, tables, version)
            refuse_mistyped_cells!(conn, tables)
          end
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
      reset_global_overrides = GLOBAL_OVERRIDE_KEYS.sum { |key| override_entries(setting(conn, key)) }
      disabled_auto_refresh_slots = SessionSlot.parse_json(raw_slots).count { |slot| !slot.refresh_before.off? }
      reset_probe_mode = setting(conn, Probe::MODE_SETTING_KEY).try do |raw|
        mode = Probe::Mode.from_setting(raw)
        mode unless mode.passive?
      end
      exec_repeaters = tables.includes?("repeaters") ? count_exec_chains(conn, "repeaters", "request") : 0
      exec_fuzz_templates = tables.includes?("fuzz_sessions") ? count_exec_fuzz_sessions(conn) : 0
      exec_decoder_tabs = json?(setting(conn, Store::DECODER_SESSIONS_KEY)).try(&.as_a?).try(&.count do |tab|
        tab.as_h?.try(&.["chain"]?).try(&.as_s?).try { |chain| exec_text?(chain) }
      end) || 0
      exec_env_vars = setting(conn, Env::PROJECT_VARS_KEY).try do |raw|
        Env.parse_vars_json(raw).count { |(_, value)| exec_text?(value) }
      end || 0
      reset_grpc_descriptors = !setting(conn, Protobuf::Schemas::SETTING_KEY).try(&.strip.presence).nil?
      Inventory.new(flows, slots, env_vars, upstream_credentials,
        disabled_pipe_rules, disabled_exec_probe_rules, disabled_body_file_stubs,
        reset_network_settings, reset_host_overrides, reset_global_overrides,
        disabled_auto_refresh_slots, reset_probe_mode,
        exec_repeaters, exec_fuzz_templates, exec_decoder_tabs, exec_env_vars,
        local_file_paths(conn, tables), reset_grpc_descriptors)
    end

    # Every stored path a tab opens when run: a Fuzzer payload set of kind `file`
    # (`FuzzerView#config_json`) and a Miner's `user_wordlist` (`MinerView`). Tolerant, like
    # the other counts: a config this build cannot parse names nothing.
    private def self.local_file_paths(conn : DB::Connection, tables : Array(String)) : Array(String)
      paths = [] of String
      if tables.includes?("fuzz_sessions")
        conn.query_each("SELECT CAST(config AS BLOB) FROM fuzz_sessions") do |rs|
          sets = rs.read(Bytes?).try { |b| json?(String.new(b)).try(&.as_h?).try(&.["sets"]?).try(&.as_a?) }
          sets.try &.each do |set|
            o = set.as_h? || next
            next unless o["kind"]?.try(&.as_s?) == "file"
            o["value"]?.try(&.as_s?).try(&.presence).try { |path| paths << path }
          end
        end
      end
      if tables.includes?("miner_sessions")
        conn.query_each("SELECT CAST(config AS BLOB) FROM miner_sessions") do |rs|
          rs.read(Bytes?).try { |b| json?(String.new(b)).try(&.as_h?).try(&.["user_wordlist"]?).try(&.as_s?).try(&.presence) }
            .try { |path| paths << path }
        end
      end
      paths
    end

    # A Fuzzer session's template, or its gRPC field chains (`role¦exec:…`,
    # `GrpcFieldTemplate#runs_commands?`), which run on every send just as the template's do.
    # Read as bytes for `count_exec_chains`' reason.
    private def self.count_exec_fuzz_sessions(conn : DB::Connection) : Int32
      count = 0
      conn.query_each("SELECT CAST(template AS BLOB), CAST(config AS BLOB) FROM fuzz_sessions") do |rs|
        template, config = rs.read(Bytes?), rs.read(Bytes?)
        grpc = config.try { |bytes| json?(String.new(bytes)).try(&.as_h?).try(&.["grpc_fields"]?).try(&.as_s?) }
        count += 1 if template.try { |bytes| exec_text?(String.new(bytes)) } || grpc.try { |text| exec_text?(text) }
      end
      count
    end

    # Tolerant: a malformed value is nil, never a refused import.
    private def self.json?(raw : String?) : JSON::Any?
      raw.try { |text| JSON.parse(text) }
    rescue JSON::ParseException
      nil
    end

    # The entries the store's tolerant reader would honor (`Store#rewriter_overrides`).
    private def self.override_entries(raw : String?) : Int32
      return 0 if raw.nil? || raw.strip.empty?
      JSON.parse(raw).as_h?.try(&.count { |key, value| key.to_i64? && !value.as_bool?.nil? }) || 0
    rescue JSON::ParseException
      0
    end

    # Read as bytes: a TEXT read stops at a NUL, and a marker behind one still reaches the wire.
    private def self.count_exec_chains(conn : DB::Connection, table : String, column : String) : Int32
      count = 0
      conn.query_each("SELECT CAST(#{column} AS BLOB) FROM #{table}") do |rs|
        count += 1 if rs.read(Bytes?).try { |bytes| exec_text?(String.new(bytes)) }
      end
      count
    end

    # `Decoder.exec_spec` matches the step case-insensitively; a substring is the disclosure's
    # honest over-approximation (a `$KEY` in a chain spec can spell the step from an env var).
    private def self.exec_text?(text : String) : Bool
      text.downcase.includes?("exec:")
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
            # Flow reads, deletes and clears touch these: one missing raises "no such table" there.
            "intercept_originals" => %w[flow_id request],
            "flow_interims"       => %w[flow_id seq status head relayed omitted],
            "flow_live_chunks"    => %w[flow_id off bytes],
            "flow_event_times"    => %w[flow_id first times],
            "flow_rule_hits"      => %w[flow_id side scope rule_id],
            "rewrite_originals"   => %w[flow_id side head body],
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
      # Every `id` column every version created is the table's rowid alias: one rebuilt without
      # it (CREATE TABLE … AS SELECT) gives every later row a NULL id, which the store reads as
      # a non-nil Int64 and raises on.
      tables.each do |table|
        next unless table_columns(conn, table).includes?("id")
        keys = conn.query_all("SELECT name, upper(type) FROM pragma_table_info(?) WHERE pk > 0", table, as: {String, String})
        unless keys == [{"id", "INTEGER"}]
          raise Gori::Error.new("project archive database table #{table} has no INTEGER PRIMARY KEY id; refusing to import it")
        end
      end
    end

    # Every key the store writes through — the rowid `id`, and each `ON CONFLICT` target
    # (`settings.key`, `sitemap_tags (host, path)`, …) — must survive in the copy. A table
    # rebuilt with CREATE TABLE … AS SELECT keeps its columns and loses them, and every upsert
    # into it then fails inside the writer's batch, taking the flows batched with it. Judged
    # after migrating the copy, against a fresh schema, so an older archive is held to the keys
    # it will have once opened; a table the fresh schema lacks is left to the column checks.
    #
    # The converse is held the same way: a table may carry no constraint gori's own schema does
    # not. A `CHECK (created_at < 1000)` on flows passes every column check and then fails every
    # capture insert; the same on scope_rules or settings silently refuses an exclude or the
    # sandbox flag. Compared against the fresh schema rather than a list, so a constraint gori
    # itself adds later is not refused.
    private def self.refuse_missing_keys!(path : String) : Nil
      expected, expected_constraints = DB.open("sqlite3::memory:") do |db|
        Store::Schema.migrate!(db)
        {key_shapes(db), constraint_shapes(db)}
      end
      DB.open("sqlite3:#{path}?busy_timeout=5000") do |db|
        Store::Schema.migrate!(db)
        actual = key_shapes(db)
        expected.each do |table, shape|
          got = actual[table]?
          next if got.nil? || got == shape
          raise Gori::Error.new("project archive database table #{table} lacks the keys gori writes through; refusing to import it")
        end
        constraint_shapes(db).each do |table, (columns, clauses)|
          if foreign = foreign_constraint(columns, clauses, expected_constraints[table]?)
            raise Gori::Error.new("project archive database table #{table} carries a constraint gori's schema " \
                                  "does not (#{foreign}); refusing to import it")
          end
        end
      end
    end

    # Per table, what can make a write gori issues fail or change: each column's {NOT NULL,
    # default, generated/hidden} as SQLite parses it, and how often the stored CREATE text
    # spells a clause no pragma reports. A keyword inside a quoted name or a comment over-counts,
    # which only ever refuses a crafted file: gori writes none of them into a table.
    CONSTRAINT_WORDS = {"CHECK" => /\bCHECK\b/i, "COLLATE" => /\bCOLLATE\b/i, "REFERENCES" => /\bREFERENCES\b/i}

    alias ColumnShape = {Bool, String?, Bool}
    alias ConstraintShape = {Hash(String, ColumnShape), Hash(String, Int32)}

    private def self.constraint_shapes(db : DB::Database) : Hash(String, ConstraintShape)
      db.using_connection do |conn|
        conn.query_all("SELECT name, COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' " \
                       "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'", as: {String, String}).to_h do |table, sql|
          columns = conn.query_all("SELECT name, \"notnull\", dflt_value, hidden FROM pragma_table_xinfo(?)",
            table, as: {String, Int64, String?, Int64}).to_h do |name, notnull, dflt, hidden|
            {name, {notnull != 0, dflt, hidden != 0}}
          end
          {table, {columns, CONSTRAINT_WORDS.transform_values { |rx| sql.scan(rx).size }}}
        end
      end
    end

    # What the archive's table adds over gori's, named for the refusal, or nil. A table gori's
    # schema lacks is left alone, as the key check leaves it: gori never writes there.
    private def self.foreign_constraint(columns : Hash(String, ColumnShape), clauses : Hash(String, Int32),
                                        want : ConstraintShape?) : String?
      want_columns, want_clauses = want || return nil
      clauses.each { |word, n| return word if n > (want_clauses[word]? || 0) }
      columns.each do |name, column|
        if known = want_columns[name]?
          return "column #{name}" unless column == known
        else
          # An extra column is harmless only while gori's INSERTs can leave it out.
          notnull, dflt, hidden = column
          return "column #{name}" if hidden || (notnull && dflt.nil?)
        end
      end
      nil
    end

    # {primary-key columns with their declared type, every UNIQUE index's columns} per table.
    private def self.key_shapes(db : DB::Database) : Hash(String, {Array({String, String}), Array(Array(String?))})
      db.using_connection do |conn|
        tables = conn.query_all("SELECT name FROM sqlite_master WHERE type = 'table' " \
                                "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'", as: String)
        tables.to_h do |table|
          pk = conn.query_all("SELECT name, upper(type) FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
            table, as: {String, String})
          uniques = conn.query_all("SELECT name FROM pragma_index_list(?) WHERE \"unique\" = 1", table, as: String)
            .map { |index| conn.query_all("SELECT name FROM pragma_index_info(?) ORDER BY seqno", index, as: String?) }
          {table, {pk, uniques.sort_by(&.join(','))}}
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
    # Live chunks (#1631) are the exporting process's in-flight stream state, not a stored body:
    # the copy keeps only what the store finalized, and its Pending flows read as they would
    # have a moment before the first event arrived. Their arrival times go with them, or the
    # row would count events EVENTS cannot show; a finalized stream's times are flow data and
    # stay.
    private def self.drop_live_streams(conn : DB::Connection) : Nil
      conn.exec("DELETE FROM flow_live_chunks") if table_exists?(conn, "flow_live_chunks")
      return unless table_exists?(conn, "flow_event_times")
      conn.exec("DELETE FROM flow_event_times WHERE flow_id IN " \
                "(SELECT id FROM flows WHERE state = #{Store::FlowState::Pending.value})")
    end

    private def self.sanitize_import_database(path : String) : Nil
      DB.open("sqlite3:#{path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          begin
            refuse_hidden_labels!(conn)
            if table_exists?(conn, "settings")
              Settings::PROJECT_NETWORK_KEYS.each do |key|
                conn.exec("DELETE FROM settings WHERE key = ?", key.key)
              end
              # The request budget's count and clock go with the ceiling they were kept for (#1601).
              conn.exec("DELETE FROM settings WHERE key IN (?, ?)", Store::OUTBOUND_BUDGET_NEXT_KEY, Store::OUTBOUND_BUDGET_SPENT_KEY)
              GLOBAL_OVERRIDE_KEYS.each { |key| conn.exec("DELETE FROM settings WHERE key = ?", key) }
              # Probe mode is authorization, not configuration: an archive must not arm active
              # probes that fire at the stored flows the moment the copy is opened.
              conn.exec("DELETE FROM settings WHERE key = ?", Probe::MODE_SETTING_KEY)
              # The same for the hosts an operator approved for agent sends (#1585).
              conn.exec("DELETE FROM settings WHERE key = ?", Store::MCP_HOST_GRANTS_KEY)
              # Read from disk every time the project opens, unasked: a path on the author's
              # machine names, on this one, whatever file the operator never chose. Machine-local,
              # like the host overrides; the importer points it at their own descriptors.
              conn.exec("DELETE FROM settings WHERE key = ?", Protobuf::Schemas::SETTING_KEY)
              disable_slot_auto_refresh(conn)
            end
            conn.exec("DELETE FROM host_overrides") if table_exists?(conn, "host_overrides")
            drop_live_streams(conn)
            # A global rule's id was numbered by the exporting install, like GLOBAL_OVERRIDE_KEYS:
            # here it would name whatever local global rule holds that id. No install issues id 0
            # and `RuleRef.parse?` refuses it, so the flow still reads as rewritten (ORIGINAL kept)
            # but names no rule.
            if table_exists?(conn, "flow_rule_hits")
              conn.exec("UPDATE OR REPLACE flow_rule_hits SET rule_id = 0 WHERE lower(scope) = 'global'")
            end
            if table_exists?(conn, "match_rules")
              conn.exec("UPDATE match_rules SET enabled = 0 WHERE lower(op) = 'pipe'")
              if table_columns(conn, "match_rules").includes?("body_file")
                conn.exec("UPDATE match_rules SET enabled = 0 WHERE lower(op) = 'short_circuit' AND body_file != ''")
              end
            end
            if table_exists?(conn, "probe_custom_rules")
              conn.exec("UPDATE probe_custom_rules SET enabled = 0 WHERE lower(kind) = 'exec'")
            end
            # The active scan mints its out-of-band payloads against the most-recently-polled
            # session, so a stamp carried in the archive would choose where this install's probes
            # call home. Unstamped, an imported session is never a mint target until the operator
            # resumes it here (`OutOfBand::StoreMinter.pick_session`).
            if table_exists?(conn, "oast_sessions") && table_columns(conn, "oast_sessions").includes?("last_poll_at")
              conn.exec("UPDATE oast_sessions SET last_poll_at = NULL")
            end
            conn.exec("COMMIT")
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end
    end

    # The labels the store maps to behavior, per table. The store's TEXT read stopped at the
    # first NUL before `store/sqlite_text.cr`, so `pipe\0x` passed the sanitizer's SQL as unknown
    # and loaded as an enabled pipe rule on such a reader. gori never writes a NUL into one of
    # these, so an archive that has one is still refused rather than repaired.
    BEHAVIOR_LABELS = {
      "match_rules"        => %w[target part op match_kind respond],
      "probe_custom_rules" => %w[side region kind severity],
    }

    private def self.refuse_hidden_labels!(conn : DB::Connection) : Nil
      BEHAVIOR_LABELS.each do |table, labels|
        next unless table_exists?(conn, table)
        present = table_columns(conn, table)
        labels.each do |column|
          next unless present.includes?(column)
          next if count_rows(conn, "SELECT COUNT(*) FROM #{table} WHERE instr(CAST(#{column} AS BLOB), X'00') > 0") == 0
          raise Gori::Error.new("project archive database has a NUL byte in #{table}.#{column}; refusing to import it")
        end
      end
    end

    # An id counter an archive could leave at the top of int64: a `sqlite_sequence` row, or the
    # largest rowid of a table that is (or, once this build migrates it, will be) AUTOINCREMENT.
    # There SQLite fails every insert with SQLITE_FULL rather than pick another id, so the
    # imported project would record no capture at all, under a "database or disk is full" that
    # sends the operator to the disk. gori never issues an id at `Schema::SEED_CEILING` (2^62)
    # and only ever writes an integer there, so such an archive is refused rather than repaired.
    #
    # Every table this build keeps AUTOINCREMENT is read (`Schema.autoincrement_tables`), not a
    # list of the ones a recent migration moved: a table that was already AUTOINCREMENT before
    # V39 (`events`, the retest tables, …) can hold its top id with no `sqlite_sequence` row,
    # which SQLite then seeds from MAX(rowid), and a table an archive predates the move of is
    # seeded by that migration from what it holds. A pre-V10 archive is also checked for the
    # other half of V10's seed: it shipped taking an unfiltered MAX of the fuzz/miner
    # `entity_links` refs, so a ref there becomes the counter too.
    private def self.refuse_exhausted_ids!(conn : DB::Connection, tables : Array(String), version : Int32) : Nil
      ceiling = Store::Schema::SEED_CEILING
      counted = [] of String
      if table_exists?(conn, "sqlite_sequence")
        if bad = conn.query_one?("SELECT COALESCE(CAST(name AS TEXT), '') FROM sqlite_sequence " \
                                 "WHERE typeof(seq) != 'integer' OR seq >= ? LIMIT 1", ceiling, as: String)
          raise exhausted_ids(bad)
        end
        counted = conn.query_all("SELECT name FROM sqlite_sequence WHERE typeof(name) = 'text'", as: String)
      end
      monotonic = counted + Store::Schema.autoincrement_tables.to_a
      (monotonic.uniq & tables).each do |table|
        id_columns(conn, table).each do |column|
          col = quote_ident(column)
          top = conn.query_one?("SELECT MAX(#{col}) FROM #{quote_ident(table)} WHERE typeof(#{col}) = 'integer'", as: Int64?)
          raise exhausted_ids(table) if top && top >= ceiling
        end
      end
      if version < 10 && tables.includes?("entity_links")
        {"fuzz" => "fuzz_sessions", "miner" => "miner_sessions"}.each do |kind, table|
          bad = conn.query_one?("SELECT 1 FROM entity_links WHERE ref_kind = ? " \
                                "AND (typeof(ref_id) != 'integer' OR ref_id >= ?) LIMIT 1", kind, ceiling, as: Int64)
          raise exhausted_ids(table) if bad
        end
      end
    end

    # The columns that hold a table's id, BY NAME, never `rowid`: a crafted table can declare a
    # real column called `rowid` (or `_rowid_`, `oid`), which shadows the alias. The INTEGER
    # PRIMARY KEY is the rowid itself; an `id` column is what a migration's rebuild copies into
    # one.
    private def self.id_columns(conn : DB::Connection, table : String) : Array(String)
      info = conn.query_all("SELECT name, type, pk FROM pragma_table_info(?)", table, as: {String, String, Int64})
      keys = info.select { |(_, _, pk)| pk > 0 }
      columns = info.select { |(name, _, _)| name.downcase == "id" }.map(&.[0])
      if keys.size == 1 && keys[0][1].upcase == "INTEGER"
        columns << keys[0][0]
      end
      columns.uniq
    end

    # Columns the store reads back as an Int32 (a port, a status, a flag, a position). Past
    # Int32 the read raises `OverflowError`, which a foreign row turns into a project whose
    # History, Repeater tab or capture start dies on every open. Not every narrow column is
    # listed: one that is not just keeps today's behaviour.
    INT32_COLUMNS = {
      "color_rules"        => %w[enabled],
      "display_columns"    => %w[position pos_start pos_end width],
      "extract_rules"      => %w[enabled pos_start pos_end],
      "grpc_reflection"    => %w[services files],
      "h2_frames"          => %w[type flags length],
      "js_refs"            => %w[port],
      "probe_issues"       => %w[severity status],
      "flows"              => %w[port status state short_circuited],
      "flow_interims"      => %w[status omitted],
      "issues"             => %w[severity status],
      "issue_evidence"     => %w[status],
      "match_rules"        => %w[enabled position],
      "oast_providers"     => %w[enabled position],
      "fuzz_sessions"      => %w[http2 position],
      "miner_sessions"     => %w[http2 position],
      "sequencer_sessions" => %w[http2 position],
      "probe_custom_rules" => %w[enabled],
      "probe_oast_probes"  => %w[severity],
      "repeaters"          => %w[position http2 auto_content_length ws_keep_key ws_http_only],
      "ws_messages"        => %w[opcode],
    }

    STRING_ONLY_TABLES = %w[flows scope_rules]

    # gori binds only integers (or NULL) into an INTEGER column, and the store reads every one
    # of them with a typed read that raises `DB::ColumnTypeMismatchError` on anything else. So
    # a TEXT, REAL or BLOB cell there, or an out-of-range narrow one, is a crafted archive and
    # is refused like the others above, not repaired. One scan per table.
    private def self.refuse_mistyped_cells!(conn : DB::Connection, tables : Array(String)) : Nil
      tables.each do |table|
        narrow = INT32_COLUMNS[table]? || [] of String
        # Every column with INTEGER affinity, which is any declared type containing "INT"
        # (sqlite.org/datatype3.html §3.1): a CREATE TABLE … AS SELECT rebuild declares `INT`.
        checks = conn.query_all("SELECT name FROM pragma_table_info(?) WHERE instr(upper(type), 'INT') > 0",
          table, as: String).map do |column|
          col = quote_ident(column)
          check = "typeof(#{col}) NOT IN ('integer', 'null')"
          narrow.includes?(column) ? "#{check} OR #{col} NOT BETWEEN #{Int32::MIN} AND #{Int32::MAX}" : check
        end
        # A BLOB in a TEXT-affinity column is stored as-is and `rs.read(String)` raises on it.
        # Only tables whose TEXT columns the store always binds as Strings: elsewhere (a
        # repeater's `request`) gori itself binds bytes into a TEXT column.
        if STRING_ONLY_TABLES.includes?(table)
          checks += conn.query_all("SELECT name FROM pragma_table_info(?) WHERE instr(upper(type), 'INT') = 0 " \
                                   "AND (instr(upper(type), 'CHAR') > 0 OR instr(upper(type), 'TEXT') > 0)",
            table, as: String).map { |column| "typeof(#{quote_ident(column)}) NOT IN ('text', 'null')" }
        end
        next if checks.empty?
        next unless conn.query_one?("SELECT 1 FROM #{quote_ident(table)} WHERE #{checks.join(" OR ")} LIMIT 1", as: Int64)
        raise Gori::Error.new("project archive database has a value gori never writes in #{table.inspect}; refusing to import it")
      end
    end

    private def self.quote_ident(name : String) : String
      %("#{name.gsub('"', %(""))}")
    end

    private def self.exhausted_ids(table : String) : Gori::Error
      Gori::Error.new("project archive database has an id at or past 2^62 in #{table.inspect}, which gori never " \
                      "issues; every new row there would fail, so it is refused")
    end

    # Automatic refresh runs an archive-authored Repeater step before a send as the slot; an
    # imported slot keeps its steps (an explicit refresh still works) but never refreshes on
    # its own. Edited at the JSON level, as `SessionSlot.detach_refresh` is, so an entry this
    # build does not fully understand loses nothing but the one key.
    private def self.disable_slot_auto_refresh(conn : DB::Connection) : Nil
      raw = setting(conn, Store::SESSION_SLOTS_KEY)
      return if raw.nil?
      entries = begin
        JSON.parse(raw).as_a?
      rescue JSON::ParseException
        nil
      end
      return unless entries
      touched = false
      fresh = entries.map do |entry|
        o = entry.as_h?
        next entry unless o && o.has_key?("refresh_before")
        touched = true
        copy = o.dup
        copy.delete("refresh_before")
        JSON::Any.new(copy)
      end
      conn.exec("UPDATE settings SET value = ? WHERE key = ?", fresh.to_json, Store::SESSION_SLOTS_KEY) if touched
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
    rescue Time::Format::Error | ArgumentError | Time::Location::InvalidTimezoneOffsetError
      # A well-formed but impossible instant (Feb 31, hour 25, year 0, `+99:00`) passes the
      # format and raises from the `Time` constructor instead.
      raise Gori::Error.new("project archive has an invalid creation time")
    end

    private def self.validate_manifest!(manifest : Manifest) : Nil
      unless manifest.format_version == FORMAT_VERSION
        raise Gori::Error.new("unsupported project archive format v#{manifest.format_version}")
      end
      raise Gori::Error.new("project archive has no valid project name") if manifest.project_name.strip.empty?
      validate_schema_version!(manifest.schema_version)
      raise Gori::Error.new("project archive has an invalid flow count") if manifest.flow_count < 0
      # Both fields are shown to whoever reviews an import, and `Time.parse_rfc3339` accepts
      # trailing bytes, so an untrusted archive could otherwise carry escape sequences or text
      # posing as gori's own sentence. gori writes a version and an RFC 3339 UTC timestamp.
      unless manifest.gori_version.valid_encoding? && manifest.gori_version.matches?(/\A[\x21-\x7e]{1,64}\z/)
        raise Gori::Error.new("project archive has no valid gori version")
      end
      unless manifest.created_at.valid_encoding? && manifest.created_at.matches?(/\A[0-9A-Za-z:.+\-]{1,40}\z/)
        raise Gori::Error.new("project archive has an invalid creation time")
      end
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
