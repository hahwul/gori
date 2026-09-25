require "../spec_helper"
require "compress/zip"
require "file_utils"

# `export_project` / `import_project` (#1271) are adapters over `ProjectArchive`, so what is
# pinned here is the SURFACE: the arguments, the confirm step, the disclosure reaching the
# agent, and that the result is the same archive and the same imported project the CLI makes.
# The archive's own validation and sanitization are the engine's, specced in
# spec/project_archive_spec.cr.

# An isolated GORI_HOME holding one registry project, "Source", with a server bound to it.
private def with_archive_server(allow_actions = true, &)
  root = File.tempname("gori-mcp-archive")
  Dir.mkdir_p(root)
  prev = ENV["GORI_HOME"]?
  ENV["GORI_HOME"] = root
  # Archives go OUTSIDE the gori home: export refuses to write inside it.
  work = File.tempname("gori-mcp-archive-out")
  Dir.mkdir_p(work)
  registry = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
  project = registry.create("Source")
  store = Gori::Store.open(project.db_path)
  tools = Gori::MCP::Tools.new(store, allow_actions: allow_actions, verify_upstream: false,
    project_name: project.name, project_slug: registry.slug_of(project), db_path: project.db_path,
    project_id: registry.id_of(project))
  begin
    yield tools, registry, project, store, work
  ensure
    store.close rescue nil
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(work)
  end
end

private def archive_call(tools : Gori::MCP::Tools, name : String, args) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args.to_json))
end

private def archive_flow(target : String)
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "archive.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: archive.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

private def archive_entries(path : String) : Hash(String, String)
  contents = {} of String => String
  Compress::Zip::Reader.open(path) do |zip|
    zip.each_entry { |entry| contents[entry.filename] = entry.io.gets_to_end }
  end
  contents
end

describe "MCP export_project" do
  it "writes the bound project as the CLI's archive and says it is unredacted" do
    with_archive_server do |tools, registry, project, store, root|
      store.insert_flow(archive_flow("/captured"))
      store.set_setting(Gori::Env::PROJECT_VARS_KEY, Gori::Env.serialize_vars([{"TOKEN", "env-secret"}]))
      target = File.join(root, "source.gori")

      r = archive_call(tools, "export_project", {"path" => target})
      r.is_error.should be_false
      body = JSON.parse(r.text)
      body["exported"].as_bool.should be_true
      body["project"].as_s.should eq("Source")
      body["id"].as_s.should eq(registry.id_of(project))
      body["slug"].as_s.should eq(registry.slug_of(project))
      body["path"].as_s.should eq(target)
      body["bytes"].as_i64.should eq(File.size(target))
      body["replaced_existing"].as_bool.should be_false
      body["unredacted"].as_bool.should be_true
      body["warning"].as_s.should contain("UNREDACTED")
      body["archive"]["project_name"].as_s.should eq("Source")
      body["archive"]["flow_count"].as_i64.should eq(1)
      body["archive"]["schema_version"].as_i.should eq(Gori::Store::Schema::VERSION)
      body["inventory"]["flows"].as_i64.should eq(1)
      body["inventory"]["env_vars"].as_i.should eq(1)
      body["disclosure"].as_s.should contain("unredacted")
      # The inventory names what is in the file, never the values themselves.
      r.text.should_not contain("env-secret")

      # The same two entries the engine writes for `gori run project export`, and a manifest
      # that agrees with the result the agent was handed.
      entries = archive_entries(target)
      entries.keys.sort!.should eq(["gori.db", "manifest.json"])
      manifest = Gori::ProjectArchive::Manifest.from_json(entries["manifest.json"])
      manifest.project_name.should eq("Source")
      manifest.flow_count.should eq(1_i64)
      manifest.created_at.should eq(body["archive"]["created_at"].as_s)
      (File.info(target).permissions.to_i & 0o777).should eq(0o600)
    end
  end

  it "exports a named project with no binding, and refuses to guess one" do
    root = File.tempname("gori-mcp-archive-unbound")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    begin
      Gori::ProjectRegistry.new(Gori::Paths.projects_dir).create("Loose")
      tools = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false, selection_source: "unbound")
      target = File.tempname("gori-mcp-loose", ".gori")

      guessed = archive_call(tools, "export_project", {"path" => target})
      guessed.error_code.should eq("NO_PROJECT")
      File.exists?(target).should be_false

      unknown = archive_call(tools, "export_project", {"path" => target, "project" => "nope"})
      unknown.error_code.should eq("NOT_FOUND")

      named = archive_call(tools, "export_project", {"path" => target, "project" => "loose"})
      named.is_error.should be_false
      JSON.parse(named.text)["project"].as_s.should eq("Loose")
      archive_entries(target).keys.sort!.should eq(["gori.db", "manifest.json"])
      File.delete(target)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end

  it "refuses an existing destination unless overwrite is true" do
    with_archive_server do |tools, _registry, _project, _store, root|
      target = File.join(root, "existing.gori")
      File.write(target, "keep this file")

      refused = archive_call(tools, "export_project", {"path" => target})
      refused.error_code.should eq("INVALID_ARGUMENT")
      refused.field.should eq("path")
      refused.text.should contain("overwrite:true")
      # The CLI's flag is not an MCP argument; the refusal names the one this surface takes.
      refused.text.should_not contain("--force")
      File.read(target).should eq("keep this file")

      replaced = archive_call(tools, "export_project", {"path" => target, "overwrite" => true})
      replaced.is_error.should be_false
      JSON.parse(replaced.text)["replaced_existing"].as_bool.should be_true
      archive_entries(target).keys.sort!.should eq(["gori.db", "manifest.json"])
    end
  end

  it "refuses any destination inside gori's home, even with overwrite" do
    with_archive_server do |tools, registry, _project, _store, _work|
      other = registry.create("Other")
      Gori::Store.open(other.db_path).close
      before = File.read(other.db_path)

      clobber = archive_call(tools, "export_project", {"path" => other.db_path, "overwrite" => true})
      clobber.error_code.should eq("INVALID_ARGUMENT")
      clobber.field.should eq("path")
      clobber.text.should contain("inside gori's home")
      File.read(other.db_path).should eq(before)

      settings = File.join(Gori::Paths.home_dir, "settings.json")
      archive_call(tools, "export_project", {"path" => settings, "overwrite" => true}).field.should eq("path")
      File.exists?(settings).should be_false
    end
  end

  it "refuses to overwrite the database a --db server is serving, and exports beside it" do
    home = File.tempname("gori-mcp-archive-dbhome")
    Dir.mkdir_p(home)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = home
    loose_dir = File.tempname("gori-mcp-archive-loose")
    Dir.mkdir_p(loose_dir)
    db_path = File.join(loose_dir, "acme.db")
    store = Gori::Store.open(db_path)
    begin
      Gori::ProjectRegistry.new(Gori::Paths.projects_dir).create("Other")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, db_path: db_path)
      store.insert_flow(archive_flow("/kept"))

      clobber = archive_call(tools, "export_project", {"project" => "Other", "path" => db_path, "overwrite" => true})
      clobber.error_code.should eq("INVALID_ARGUMENT")
      clobber.field.should eq("path")
      clobber.text.should contain("open in a running gori instance")
      store.count.should eq(1)

      # A bare --db file is not a registry project: the directory around it is the operator's.
      beside = File.join(loose_dir, "acme.gori")
      done = archive_call(tools, "export_project", {"path" => beside})
      done.is_error.should be_false
      body = JSON.parse(done.text)
      body["project"].as_s.should eq("acme")
      body["id"].raw.should be_nil
      archive_entries(beside).keys.sort!.should eq(["gori.db", "manifest.json"])
    ensure
      store.close rescue nil
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(loose_dir)
    end
  end

  it "names the argument a malformed call is missing or got wrong" do
    with_archive_server do |tools, _registry, project, _store, root|
      missing = archive_call(tools, "export_project", {} of String => String)
      missing.error_code.should eq("INVALID_ARGUMENT")
      missing.field.should eq("path")

      no_dir = archive_call(tools, "export_project", {"path" => File.join(root, "absent", "x.gori")})
      no_dir.field.should eq("path")
      no_dir.text.should contain("no such directory")

      inside = archive_call(tools, "export_project", {"path" => File.join(project.dir, "x.gori")})
      inside.field.should eq("path")
      inside.text.should contain("inside the source project directory")
    end
  end

  it "is recorded in the bound project's event feed as an agent action" do
    with_archive_server do |tools, _registry, _project, _store, root|
      archive_call(tools, "export_project", {"path" => File.join(root, "feed.gori")}).is_error.should be_false
      archive_call(tools, "list_events", {} of String => String).text.should contain("export_project ok")
    end
  end
end

describe "MCP import_project" do
  it "validates and discloses without importing until confirm, then imports a sanitized copy" do
    with_archive_server do |tools, registry, project, store, root|
      store.insert_flow(archive_flow("/captured"))
      store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "GET", "id", Gori::Store::RuleOp::Pipe)
      store.add_host_override("api.example.test", "203.0.113.4")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "http://proxy.attacker.test:8080")
      archive = File.join(root, "source.gori")
      archive_call(tools, "export_project", {"path" => archive}).is_error.should be_false
      before = registry.list.map(&.name).sort!

      preview = archive_call(tools, "import_project", {"path" => archive, "name" => "Copy"})
      preview.error_code.should eq("CONFIRM_REQUIRED")
      preview.field.should eq("confirm")
      # The disclosure reaches a client that only shows the text, not just the details.
      preview.text.should contain("unredacted")
      preview.text.should contain("nothing was imported")
      preview.text.should contain("confirm:true")
      details = preview.details.not_nil!
      details["name"].as_s.should eq("Copy")
      details["name_available"].as_bool.should be_true
      details["name_problem"]?.should be_nil
      details["path"].as_s.should eq(archive)
      details["archive"]["project_name"].as_s.should eq("Source")
      details["inventory"]["flows"].as_i64.should eq(1)
      details["import_safety"]["disabled_pipe_rules"].as_i.should eq(1)
      details["import_safety"]["reset_host_overrides"].as_i.should eq(1)
      details["import_safety"]["reset_network_settings"].as_i.should eq(1)
      details["disclosure"].as_s.should contain("disable 1 pipe Rewriter rule")
      registry.list.map(&.name).sort!.should eq(before)

      done = archive_call(tools, "import_project", {"path" => archive, "name" => "Copy", "confirm" => true})
      done.is_error.should be_false
      body = JSON.parse(done.text)
      body["imported"].as_bool.should be_true
      body["name"].as_s.should eq("Copy")
      body["switched"].as_bool.should be_false
      body["note"].as_s.should contain("switch_project")
      body["disclosure"].as_s.should contain("unredacted")
      imported = registry.find("Copy").not_nil!
      body["id"].as_s.should eq(registry.id_of(imported))
      body["db_path"].as_s.should eq(imported.db_path)
      registry.id_of(imported).should_not eq(registry.id_of(project))

      # The #1264 boundary, applied by the shared engine rather than restated here.
      copied = Gori::Store.open(imported.db_path)
      begin
        copied.count.should eq(1)
        copied.match_rules.map(&.enabled?).should eq([false])
        copied.host_overrides.should be_empty
        copied.setting(Gori::Settings::PROJECT_UPSTREAM_KEY).should be_nil
      ensure
        copied.close
      end

      # Importing never moves this server's binding.
      JSON.parse(archive_call(tools, "project_info", {} of String => String).text)["project"].as_s.should eq("Source")
    end
  end

  it "reports a taken name in the preview, refuses it on confirm, and imports under another" do
    with_archive_server do |tools, registry, _project, _store, root|
      archive = File.join(root, "source.gori")
      archive_call(tools, "export_project", {"path" => archive}).is_error.should be_false

      preview = archive_call(tools, "import_project", {"path" => archive})
      preview.error_code.should eq("CONFIRM_REQUIRED")
      details = preview.details.not_nil!
      details["name"].as_s.should eq("Source")
      details["name_available"].as_bool.should be_false
      details["name_problem"].as_s.should contain("already exists")
      preview.text.should contain("Pass another 'name'")

      taken = archive_call(tools, "import_project", {"path" => archive, "confirm" => true})
      taken.error_code.should eq("INVALID_ARGUMENT")
      taken.field.should eq("name")
      taken.text.should contain("already exists")
      registry.list.size.should eq(1)

      renamed = archive_call(tools, "import_project", {"path" => archive, "name" => "Source 2", "confirm" => true})
      renamed.is_error.should be_false
      registry.list.map(&.name).sort!.should eq(["Source", "Source 2"])
    end
  end

  it "names the MCP argument, not the CLI flag, for an archive name it cannot use" do
    with_archive_server do |tools, _registry, _project, _store, root|
      archive = File.join(root, "source.gori")
      archive_call(tools, "export_project", {"path" => archive}).is_error.should be_false
      entries = archive_entries(archive)
      manifest = JSON.parse(entries["manifest.json"]).as_h
      manifest["project_name"] = JSON::Any.new("Evil\e]0;PWNED\a")
      entries["manifest.json"] = JSON::Any.new(manifest).to_json
      File.open(archive, "w") do |file|
        Compress::Zip::Writer.open(file) { |zip| entries.each { |name, body| zip.add(name, body) } }
      end

      preview = archive_call(tools, "import_project", {"path" => archive})
      problem = preview.details.not_nil!["name_problem"].as_s
      problem.should contain("with the 'name' argument")
      problem.should_not contain("--name")
      # The escape sequence reaches the text only escaped.
      preview.text.should_not contain("\e")

      refused = archive_call(tools, "import_project", {"path" => archive, "confirm" => true})
      refused.field.should eq("name")
      refused.text.should contain("with the 'name' argument")

      archive_call(tools, "import_project", {"path" => archive, "name" => "Recovered", "confirm" => true})
        .is_error.should be_false
    end
  end

  it "keeps a manifest name that is not UTF-8 out of the JSON it answers with" do
    with_archive_server do |tools, registry, _project, _store, root|
      archive = File.join(root, "source.gori")
      archive_call(tools, "export_project", {"path" => archive}).is_error.should be_false
      entries = archive_entries(archive)
      raw_manifest = entries["manifest.json"].to_slice.dup
      marker = %("project_name":"Source").to_slice
      index = (0..raw_manifest.size - marker.size).find { |i| raw_manifest[i, marker.size] == marker }.not_nil!
      raw_manifest[index + marker.size - 2] = 0xff_u8 # "Sourc\xFF"
      File.open(archive, "w") do |file|
        Compress::Zip::Writer.open(file) do |zip|
          zip.add("manifest.json", raw_manifest)
          zip.add("gori.db", entries["gori.db"])
        end
      end

      preview = archive_call(tools, "import_project", {"path" => archive, "name" => " Recovered "})
      preview.error_code.should eq("CONFIRM_REQUIRED")
      preview.text.valid_encoding?.should be_true
      details = preview.details.not_nil!
      details.to_json.valid_encoding?.should be_true
      # The name reported is the one the registry will store: trimmed.
      details["name"].as_s.should eq("Recovered")

      done = archive_call(tools, "import_project", {"path" => archive, "name" => "Recovered", "confirm" => true})
      done.is_error.should be_false
      done.text.valid_encoding?.should be_true
      JSON.parse(done.text)["archive"]["project_name"].as_s.should contain("Sourc")
      registry.find("Recovered").should_not be_nil
    end
  end

  it "refuses a missing or invalid archive without registering anything" do
    with_archive_server do |tools, registry, _project, _store, root|
      missing = archive_call(tools, "import_project", {"confirm" => true})
      missing.error_code.should eq("INVALID_ARGUMENT")
      missing.field.should eq("path")

      absent = archive_call(tools, "import_project", {"path" => File.join(root, "absent.gori"), "confirm" => true})
      absent.field.should eq("path")
      absent.text.should contain("does not exist")

      junk = File.join(root, "junk.gori")
      File.write(junk, "not a zip")
      bad = archive_call(tools, "import_project", {"path" => junk, "confirm" => true})
      bad.error_code.should eq("INVALID_ARGUMENT")
      bad.field.should eq("path")
      registry.list.size.should eq(1)
    end
  end

  it "works on an unbound server without binding the new project" do
    with_archive_server do |tools, registry, _project, _store, root|
      archive = File.join(root, "source.gori")
      archive_call(tools, "export_project", {"path" => archive}).is_error.should be_false

      unbound = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false, selection_source: "unbound")
      done = archive_call(unbound, "import_project", {"path" => archive, "name" => "Fresh", "confirm" => true})
      done.is_error.should be_false
      body = JSON.parse(done.text)
      body["switched"].as_bool.should be_false
      body["note"].as_s.should contain("still unbound")
      registry.find("Fresh").should_not be_nil
      archive_call(unbound, "list_history", {} of String => String).error_code.should eq("NO_PROJECT")
    end
  end
end

describe "MCP project archive tools under --read-only" do
  it "neither advertises nor runs them" do
    with_archive_server(allow_actions: false) do |tools, _registry, _project, _store, root|
      listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
      listed.should_not contain("export_project")
      listed.should_not contain("import_project")
      target = File.join(root, "ro.gori")
      archive_call(tools, "export_project", {"path" => target}).error_code.should eq("TOOL_DISABLED")
      File.exists?(target).should be_false
    end
  end
end
