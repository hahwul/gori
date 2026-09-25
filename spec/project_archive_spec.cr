require "./spec_helper"
require "compress/zip"
require "file_utils"

private def with_archive_project(&)
  root = File.tempname("gori-archive-spec")
  registry = Gori::ProjectRegistry.new(root)
  project = registry.create("Archive source")
  store = Gori::Store.open(project.db_path)
  begin
    yield registry, project, store, root
  ensure
    store.close
    FileUtils.rm_rf(root)
  end
end

private def archive_request(target : String)
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64,
    scheme: "https",
    host: "archive.test",
    port: 443,
    method: "GET",
    target: target,
    http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: archive.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

private def write_archive(path : String, entries : Array({String, String})) : Nil
  File.open(path, "w") do |file|
    Compress::Zip::Writer.open(file) do |zip|
      entries.each { |name, contents| zip.add(name, contents) }
    end
  end
end

private def read_archive(path : String) : Hash(String, String)
  contents = {} of String => String
  Compress::Zip::Reader.open(path) do |zip|
    zip.each_entry { |entry| contents[entry.filename] = entry.io.gets_to_end }
  end
  contents
end

private def corrupt_second_entry_deflate(path : String) : Nil
  bytes = File.read(path).to_slice.dup
  count = 0
  (0...bytes.size - 4).each do |index|
    next unless bytes[index, 4] == Bytes[0x50, 0x4b, 0x03, 0x04]
    count += 1
    next unless count == 2
    name_len = bytes[index + 26].to_i + (bytes[index + 27].to_i << 8)
    extra_len = bytes[index + 28].to_i + (bytes[index + 29].to_i << 8)
    data = index + 30 + name_len + extra_len
    8.times { |offset| bytes[data + offset] = 0xff_u8 }
    break
  end
  File.write(path, bytes)
end

private def write_minimal_current_database(path : String) : Nil
  DB.open("sqlite3:#{path}") do |db|
    db.exec("CREATE TABLE flows (id INTEGER PRIMARY KEY)")
    db.exec("PRAGMA user_version = #{Gori::Store::Schema::VERSION}")
  end
end

class ProjectArchiveFallbackExportSpec < Gori::ProjectArchive::PreparedExport
  getter? link_attempted : Bool

  def initialize(workdir : String, project : Gori::Project, manifest : Gori::ProjectArchive::Manifest,
                 inventory : Gori::ProjectArchive::Inventory)
    @link_attempted = false
    super(workdir, project.db_path, project, manifest, inventory)
  end

  protected def link_archive(_source : String, _destination : String) : Nil
    @link_attempted = true
    raise IO::Error.new("hard links are unsupported")
  end
end

# A peer claims the destination between the existence check and the hard link.
class ProjectArchiveRacedExportSpec < Gori::ProjectArchive::PreparedExport
  def initialize(workdir : String, project : Gori::Project, manifest : Gori::ProjectArchive::Manifest,
                 inventory : Gori::ProjectArchive::Inventory)
    super(workdir, project.db_path, project, manifest, inventory)
  end

  protected def link_archive(_source : String, destination : String) : Nil
    File.write(destination, "a peer won")
    raise IO::Error.new("File exists")
  end
end

describe Gori::ProjectArchive do
  it "exports a compact WAL snapshot and imports a fresh project without local sidecars" do
    with_archive_project do |registry, project, store, root|
      store.insert_flow(archive_request("/captured"))
      store.set_setting(Gori::Store::SESSION_SLOTS_KEY,
        Gori::SessionSlot.serialize([Gori::SessionSlot.new("admin",
          [{"Authorization", "Bearer session-secret"}])]))
      store.set_setting(Gori::Env::PROJECT_VARS_KEY,
        Gori::Env.serialize_vars([{"TOKEN", "env-secret"}]))
      auth = Gori::Settings::ProjectProxyAuth.new("basic", "proxy-user", "proxy-secret")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY, auth.to_json)

      # The live Store keeps SQLite in WAL mode and holds the shared open lock while export
      # snapshots it. Sidecars deliberately contain machine-local state and must stay behind.
      File.write(File.join(project.dir, Gori::ProjectRegistry::WORKSPACE_FILE), "/machine/local")
      File.write(File.join(project.dir, Gori::CaptureLock::LOCK_FILE), "")
      File.size("#{project.db_path}-wal").should be > 0

      prepared_export = Gori::ProjectArchive.prepare_export(project)
      begin
        prepared_export.inventory.flows.should eq(1_i64)
        prepared_export.inventory.session_slots.should eq(1)
        prepared_export.inventory.env_vars.should eq(1)
        prepared_export.inventory.upstream_credentials.should be_true
        disclosure = Gori::ProjectArchive.disclosure(prepared_export.inventory)
        disclosure.should contain("unredacted")
        disclosure.should_not contain("session-secret")
        disclosure.should_not contain("env-secret")
        disclosure.should_not contain("proxy-secret")

        archive_path = File.join(root, "snapshot.gori")
        prepared_export.write(archive_path).should eq(archive_path)
        read_archive(archive_path).keys.sort!.should eq(["gori.db", "manifest.json"])
        (File.info(archive_path).permissions.to_i & 0o777).should eq(0o600)

        # A later WAL commit does not change the already prepared snapshot.
        store.insert_flow(archive_request("/later"))
      ensure
        prepared_export.close
      end

      prepared_import = Gori::ProjectArchive.prepare_import(File.join(root, "snapshot.gori"))
      begin
        prepared_import.inventory.flows.should eq(1_i64)
        imported = prepared_import.import_into(registry, "Archive copy")
        imported.name.should eq("Archive copy")
        new_id = registry.id_of(imported).not_nil!
        new_id.should match(/\A[0-9a-f]{8}\z/)
        new_id.should_not eq(registry.id_of(project))
        File.exists?(File.join(imported.dir, Gori::ProjectRegistry::WORKSPACE_FILE)).should be_false
        File.exists?(File.join(imported.dir, Gori::CaptureLock::LOCK_FILE)).should be_false
        File.exists?(File.join(imported.dir, "#{Gori::Project::DB_FILE}#{Gori::OpenLock::SUFFIX}")).should be_false

        imported_store = Gori::Store.open(imported.db_path)
        begin
          imported_store.count.should eq(1)
          imported_store.setting(Gori::Store::SESSION_SLOTS_KEY).not_nil!.should contain("session-secret")
          imported_store.setting(Gori::Env::PROJECT_VARS_KEY).not_nil!.should contain("env-secret")
          imported_store.setting(Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY).should be_nil
        ensure
          imported_store.close
        end
      ensure
        prepared_import.close
      end
      store.count.should eq(2)
    end
  end

  it "refuses an archive with unexpected entries before extracting them" do
    with_archive_project do |_registry, _project, _store, root|
      archive_path = File.join(root, "unexpected.gori")
      write_archive(archive_path, [{"../../outside", "untrusted"}])
      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("unexpected entry")
      File.exists?(File.join(root, "outside")).should be_false
    end
  end

  it "requires explicit overwrite and refuses destinations inside the source project" do
    with_archive_project do |_registry, project, _store, root|
      prepared = Gori::ProjectArchive.prepare_export(project)
      begin
        archive_path = File.join(root, "existing.gori")
        File.write(archive_path, "keep this file")
        error = expect_raises(Gori::ProjectArchive::DestinationExists) { prepared.write(archive_path) }
        error.message.not_nil!.should eq("destination already exists: #{error.path}")
        error.path.should eq(archive_path)
        File.read(archive_path).should eq("keep this file")

        dangling_link = File.join(root, "dangling.gori")
        File.symlink(File.join(root, "missing-target"), dangling_link)
        error = expect_raises(Gori::ProjectArchive::DestinationExists) { prepared.write(dangling_link) }
        error.message.not_nil!.should eq("destination already exists: #{error.path}")
        prepared.write(dangling_link, overwrite: true).should eq(dangling_link)
        File.symlink?(dangling_link).should be_false
        read_archive(dangling_link).keys.sort!.should eq(["gori.db", "manifest.json"])

        prepared.write(archive_path, overwrite: true).should eq(archive_path)
        read_archive(archive_path).keys.sort!.should eq(["gori.db", "manifest.json"])

        source_path = File.join(project.dir, "inside.gori")
        error = expect_raises(Gori::Error) { prepared.write(source_path, overwrite: true) }
        error.message.not_nil!.should contain("inside the source project directory")
        File.exists?(source_path).should be_false
      ensure
        prepared.close
      end
    end
  end

  it "falls back to copying and renaming when hard links are unsupported" do
    with_archive_project do |_registry, project, _store, root|
      prepared = Gori::ProjectArchive.prepare_export(project)
      workdir = File.tempname("gori-link-fallback")
      Dir.mkdir(workdir)
      fallback = ProjectArchiveFallbackExportSpec.new(workdir, project, prepared.manifest, prepared.inventory)
      begin
        archive_path = File.join(root, "copy-installed.gori")
        fallback.write(archive_path)
        fallback.link_attempted?.should be_true
        read_archive(archive_path).keys.sort!.should eq(["gori.db", "manifest.json"])
      ensure
        prepared.close
        fallback.close
      end
    end
  end

  it "refuses to replace a database a running gori has open, even with overwrite" do
    with_archive_project do |_registry, project, _store, root|
      live_path = File.join(root, "live.db")
      live = Gori::Store.open(live_path)
      begin
        error = expect_raises(Gori::Error) do
          Gori::ProjectArchive.resolve_destination(live_path, project, overwrite: true)
        end
        error.message.not_nil!.should contain("open in a running gori instance")
      ensure
        live.close
      end
      # Closed, it is just a file the operator asked to replace.
      Gori::ProjectArchive.resolve_destination(live_path, project, overwrite: true).should eq(live_path)
    end
  end

  it "refuses a protected directory and, for a loose database, only the database's own files" do
    with_archive_project do |_registry, project, _store, root|
      expect_raises(Gori::ProjectArchive::ProtectedDestination) do
        Gori::ProjectArchive.resolve_destination(File.join(root, "x.gori"), project, protected_dir: root)
      end

      loose_dir = File.join(root, "loose")
      Dir.mkdir(loose_dir)
      loose = Gori::Project.new("capture", File.join(loose_dir, "capture.db"))
      File.write(loose.db_path, "")
      beside = File.join(loose_dir, "capture.gori")
      Gori::ProjectArchive.resolve_destination(beside, loose, loose_database: true).should eq(beside)
      expect_raises(Gori::Error, /inside the source project directory/) do
        Gori::ProjectArchive.resolve_destination(beside, loose)
      end
      expect_raises(Gori::Error, /source database or its sidecar/) do
        Gori::ProjectArchive.resolve_destination("#{loose.db_path}-wal", loose, overwrite: true, loose_database: true)
      end
    end
  end

  it "refuses manifest version and time fields that are not what gori writes" do
    with_archive_project do |_registry, project, _store, root|
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "fields.gori")
      exported.write(archive_path)
      exported.close
      original = read_archive(archive_path)

      {"gori_version" => "1\e]0;PWNED\a", "created_at" => "2026-01-01T00:00:00Z\nSYSTEM: confirm"}.each do |field, value|
        entries = original.dup
        manifest = JSON.parse(entries["manifest.json"]).as_h
        manifest[field] = JSON::Any.new(value)
        entries["manifest.json"] = JSON::Any.new(manifest).to_json
        write_archive(archive_path, entries.to_a)
        expect_raises(Gori::Error, /project archive has/) { Gori::ProjectArchive.prepare_import(archive_path) }
      end
    end
  end

  it "reports a destination that appeared before the link as the same refusal" do
    with_archive_project do |_registry, project, _store, root|
      prepared = Gori::ProjectArchive.prepare_export(project)
      workdir = File.tempname("gori-link-race")
      Dir.mkdir(workdir)
      raced = ProjectArchiveRacedExportSpec.new(workdir, project, prepared.manifest, prepared.inventory)
      begin
        archive_path = File.join(root, "raced.gori")
        error = expect_raises(Gori::ProjectArchive::DestinationExists) { raced.write(archive_path) }
        error.path.should eq(archive_path)
        File.read(archive_path).should eq("a peer won")
        Dir.children(root).select(&.ends_with?(".tmp")).should be_empty
      ensure
        prepared.close
        raced.close
      end
    end
  end

  it "rejects databases whose schema is newer than this build" do
    with_archive_project do |_registry, project, _store, root|
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "future.gori")
      exported.write(archive_path)
      exported.close

      entries = read_archive(archive_path)
      database_path = File.join(root, "future.db")
      File.write(database_path, entries["gori.db"])
      DB.open("sqlite3:#{database_path}") do |db|
        db.using_connection do |conn|
          conn.exec("PRAGMA user_version = #{Gori::Store::Schema::VERSION + 1}")
        end
      end
      entries["gori.db"] = File.read(database_path)
      write_archive(archive_path, entries.to_a)

      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("newer version of gori")
    end
  end

  it "rejects manifest metadata that disagrees with the database snapshot" do
    with_archive_project do |_registry, project, store, root|
      store.insert_flow(archive_request("/manifest"))
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "wrong-count.gori")
      exported.write(archive_path)
      exported.close

      entries = read_archive(archive_path)
      manifest = JSON.parse(entries["manifest.json"]).as_h
      manifest["flow_count"] = JSON::Any.new(2_i64)
      entries["manifest.json"] = JSON::Any.new(manifest).to_json
      write_archive(archive_path, entries.to_a)

      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("manifest says 2 flows")
      error.message.not_nil!.should contain("database has 1")
    end
  end

  it "disables imported command and file rules and clears network overrides" do
    with_archive_project do |registry, project, store, root|
      store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "GET", "id", Gori::Store::RuleOp::Pipe)
      store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "GET", "", Gori::Store::RuleOp::ShortCircuit, body_file: "/tmp/importer-secret")
      store.insert_probe_custom_rule("exec rule", "", "response", "body", "exec", "id",
        Gori::Store::Severity::Medium)
      store.set_setting(Gori::Settings::PROJECT_BIND_HOST_KEY, "0.0.0.0")
      store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "8443")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "http://proxy.attacker.test:8080")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY,
        Gori::Settings::ProjectProxyAuth.new("basic", "user", "secret").to_json)
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_DESTINATION_KEY, "*")
      store.set_setting(Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY, "15")
      store.set_setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY, "30")
      store.set_setting(Gori::Settings::PROJECT_CAPTURE_MAX_KEY, "16")
      store.add_host_override("api.example.test", "203.0.113.4")
      store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY,
        Gori::Authorize.serialize([Gori::SessionSlot.new("operator",
          [{"Authorization", "Bearer identity-secret"}])]))
      provider_id = store.insert_oast_provider("saved", "interactsh", "https://oast.test", "provider-token", true, 0)
      store.insert_oast_session(provider_id, "interactsh", "https://oast.test", "correlation",
        "session-secret", "private-key", "session-token")

      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "unsafe-config.gori")
      exported.write(archive_path)
      exported.close

      prepared = Gori::ProjectArchive.prepare_import(archive_path)
      begin
        disclosure = Gori::ProjectArchive.disclosure(prepared.inventory)
        disclosure.should contain("1 pipe Rewriter rule")
        disclosure.should contain("1 exec Probe rule")
        disclosure.should contain("1 file-backed short-circuit stub")
        disclosure.should contain("8 project network settings")
        disclosure.should contain("1 host override")
        disclosure.should contain("OAST sessions")
        disclosure.should contain("provider tokens")
        disclosure.should contain("Authorize identities")

        imported = prepared.import_into(registry, "Safe copy")
        copied = Gori::Store.open(imported.db_path)
        begin
          copied.match_rules.map(&.enabled?).should eq([false, false])
          copied.probe_custom_rules.map(&.enabled?).should eq([false])
          copied.setting(Gori::Settings::PROJECT_BIND_HOST_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_BIND_PORT_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_UPSTREAM_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_UPSTREAM_DESTINATION_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY).should be_nil
          copied.setting(Gori::Settings::PROJECT_CAPTURE_MAX_KEY).should be_nil
          copied.host_overrides.should be_empty
          copied.setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY).not_nil!.should contain("identity-secret")
          copied.oast_providers.first.token.should eq("provider-token")
          copied.oast_sessions.first.token.should eq("session-token")
          copied.oast_sessions.first.private_key_pem.should eq("private-key")
        ensure
          copied.close
        end
      ensure
        prepared.close
      end
    end
  end

  it "refuses imported SQLite triggers and views before they can affect sanitization" do
    with_archive_project do |_registry, project, _store, root|
      DB.open("sqlite3:#{project.db_path}") do |db|
        db.exec("CREATE TRIGGER keep_rule AFTER DELETE ON match_rules BEGIN INSERT INTO match_rules (enabled,target,part,pattern,replacement,op) VALUES (1,old.target,old.part,old.pattern,old.replacement,old.op); END")
        db.exec("CREATE VIEW attacker_view AS SELECT * FROM flows")
      end
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "schema-objects.gori")
      exported.write(archive_path)
      exported.close

      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("unsupported SQLite triggers or views")
    end
  end

  it "rejects a database with only a flows id column even at the current schema version" do
    with_archive_project do |_registry, _project, _store, root|
      database_path = File.join(root, "minimal.db")
      write_minimal_current_database(database_path)
      manifest = Gori::ProjectArchive::Manifest.new(1, "crafted", "x",
        Gori::Store::Schema::VERSION, Time.utc.to_rfc3339, 0_i64)
      archive_path = File.join(root, "minimal.gori")
      write_archive(archive_path, [{"manifest.json", manifest.to_json}, {"gori.db", File.read(database_path)}])

      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("missing required column")
    end
  end

  it "refuses an escape-laden project name from the archive manifest at registration" do
    with_archive_project do |registry, project, _store, root|
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "unsafe-name.gori")
      exported.write(archive_path)
      exported.close
      entries = read_archive(archive_path)
      manifest = JSON.parse(entries["manifest.json"]).as_h
      manifest["project_name"] = JSON::Any.new("Evil\e]0;PWNED\a")
      entries["manifest.json"] = JSON::Any.new(manifest).to_json
      write_archive(archive_path, entries.to_a)

      prepared = Gori::ProjectArchive.prepare_import(archive_path)
      begin
        error = expect_raises(Gori::Error, /control characters/) { prepared.import_into(registry) }
        error.message.not_nil!.should contain("provide an explicit safe project name")
        prefilled_error = expect_raises(Gori::Error) do
          prepared.import_into(registry, prepared.manifest.project_name)
        end
        prefilled_error.message.not_nil!.should contain("project picker")
        # A preview gives the same sentence without registering anything, and a caller's own
        # rename hint replaces the CLI's.
        prepared.name_problem(registry).not_nil!.should contain("project picker")
        mcp_problem = prepared.name_problem(registry, rename_hint: "with the 'name' argument").not_nil!
        mcp_problem.should contain("with the 'name' argument")
        mcp_problem.should_not contain("--name")
        expect_raises(Gori::Error, /with the 'name' argument/) do
          prepared.import_into(registry, rename_hint: "with the 'name' argument")
        end
        prepared.name_problem(registry, project.name).not_nil!.should contain("already exists")
        prepared.name_problem(registry, "Recovered copy").should be_nil
        registry.list.map(&.name).should eq([project.name])

        imported = prepared.import_into(registry, "Recovered copy")
        imported.name.should eq("Recovered copy")
        registry.list.map(&.name).sort!.should eq(["Recovered copy", project.name].sort!)
      ensure
        prepared.close
      end
    end
  end

  it "wraps corrupt deflate streams and removes the partial import directory" do
    with_archive_project do |_registry, project, _store, root|
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "corrupt-deflate.gori")
      exported.write(archive_path)
      exported.close
      corrupt_second_entry_deflate(archive_path)

      prefix = "gori-gori-import"
      before = Dir.children(Dir.tempdir).count(&.starts_with?(prefix))
      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("could not read project archive")
      Dir.children(Dir.tempdir).count(&.starts_with?(prefix)).should eq(before)
    end
  end

  it "rejects an archive whose total uncompressed content exceeds the documented cap" do
    with_archive_project do |_registry, project, _store, root|
      exported = Gori::ProjectArchive.prepare_export(project)
      archive_path = File.join(root, "oversized.gori")
      exported.write(archive_path)
      exported.close

      bytes = File.read(archive_path).to_slice.dup
      found_database = false
      (0...bytes.size - 46).each do |index|
        next unless bytes[index, 4] == Bytes[0x50, 0x4b, 0x01, 0x02]
        name_len = bytes[index + 28].to_i + (bytes[index + 29].to_i << 8)
        filename = String.new(bytes[index + 46, name_len])
        next unless filename == "gori.db"
        oversized = (2_i64 * 1024 * 1024 * 1024 + 1).to_u32
        4.times { |offset| bytes[index + 24 + offset] = ((oversized >> (offset * 8)) & 0xff).to_u8 }
        found_database = true
        break
      end
      found_database.should be_true
      File.write(archive_path, bytes)

      error = expect_raises(Gori::Error) { Gori::ProjectArchive.prepare_import(archive_path) }
      error.message.not_nil!.should contain("uncompressed size limit")
    end
  end
end
