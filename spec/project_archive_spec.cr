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
        disclosure.should contain("not redacted")
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
          imported_store.setting(Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY).not_nil!.should contain("proxy-secret")
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
        error = expect_raises(Gori::Error) { prepared.write(archive_path) }
        error.message.not_nil!.should contain("use --force")
        File.read(archive_path).should eq("keep this file")

        dangling_link = File.join(root, "dangling.gori")
        File.symlink(File.join(root, "missing-target"), dangling_link)
        error = expect_raises(Gori::Error) { prepared.write(dangling_link) }
        error.message.not_nil!.should contain("use --force")
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
end
