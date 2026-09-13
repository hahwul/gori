require "../spec_helper"
require "../support/mcp_harness"
require "file_utils"

# An MCP server FOLLOWS a token-grammar switch made in the operator's terminal.
#
# A `gori mcp` server reads `Settings.env_syntax` once, at startup, and lives for hours. Before
# `EnvMigration.follow_disk` it therefore kept answering `list_env.syntax` with the grammar it was
# born under — and kept WRITING rows in that grammar into a database `gori settings env-syntax` had
# already marked the other way. Those rows are unreachable afterwards: the reconcile compares the
# marker with the install and finds `from == to`, so it skips them forever.
#
# The tick is `refresh_project_env`, which every `env_refresh: true` tool takes before it runs —
# `list_env` among them, which is what makes the report itself the observation point.
private def with_mcp_syntax_home(&)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  dir = File.tempname("gori-mcp-env-syntax")
  db_dir = File.join(dir, "projects", "demo")
  Dir.mkdir_p(db_dir)
  path = File.join(dir, "settings.json")
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    File.write(path, %({"env":{"syntax":"bare"}}))
    Gori::Settings.load
    yield File.join(db_dir, "gori.db"), path
  ensure
    Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    Gori::Settings.path_override = nil
    Gori::Env.layer = nil
    File.write(path, snapshot)
    Gori::Settings.load
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

private def seed_bare_project(db_path : String) : Int64
  store = Gori::Store.open(db_path)
  begin
    store.set_setting(Gori::Env::PROJECT_VARS_KEY,
      Gori::Env.serialize_vars([{"API", "api.example.com"}]))
    store.insert_extract_rule("token", "", Gori::ExtractKind::Header, "set-cookie")
    id = store.insert_repeater("https://$API",
      "GET / HTTP/1.1\r\nAuthorization: $token\r\n\r\n".to_slice, false, true, nil, 0)
    store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
      "Authorization", "Bearer $token", name: "auth")
    store.flush
    id
  ensure
    store.close
  end
end

describe "MCP follows a peer's env.syntax switch" do
  it "adopts the flipped grammar on the next tick, re-spells the rows and moves the marker" do
    with_mcp_syntax_home do |db_path, settings_path|
      rep_id = seed_bare_project(db_path)
      store = Gori::Store.open(db_path)
      begin
        tools = Gori::MCP::Tools.new(store, true, false, project_name: "demo", db_path: db_path)
        # Born under bare, against a database whose (absent) marker agrees.
        mcp_ok_json(tools, "list_env", "{}")["syntax"].as_s.should eq("bare")
        Gori::EnvMigration.stored_syntax(store).should eq(Gori::Env::Syntax::Bare)

        # The operator switches in another terminal. `gori settings env-syntax` cannot reach this
        # already-open project — the marker check inside the reconcile is what stops two openers
        # doing it twice — so the switch is only a line in settings.json until this process looks.
        File.write(settings_path, %({"env":{"syntax":"namespaced"}}))

        # The next `env_refresh` tool call is the tick.
        got = mcp_ok_json(tools, "list_env", "{}")
        got["syntax"].as_s.should eq("namespaced")
        got["example"].as_s.should eq("$ENV.KEY")
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
        # …and the ROWS moved with it, which is the half that used to be missing: a flipped reading
        # over un-re-spelled bytes made every stored `$token` literal text.
        Gori::EnvMigration.stored_syntax(store).should eq(Gori::Env::Syntax::Namespaced)
      ensure
        store.close
      end
      store = Gori::Store.open(db_path)
      begin
        String.new(store.get_repeater_full(rep_id).not_nil!.request)
          .should contain("Authorization: $BIND.token\r\n")
        store.get_repeater_full(rep_id).not_nil!.target.should eq("https://$ENV.API")
        store.match_rules[0].replacement.should eq("Bearer $BIND.token")
        store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("namespaced")
      ensure
        store.close
      end
    end
  end

  # And the write side, from this surface: an MCP tool that runs BEFORE the tick (nothing in the
  # `create_repeater` path is `env_refresh`) still must not leave a bare row in a namespaced
  # database — `store/env_write_guard.cr` re-spells it on the way in.
  it "re-spells a row written by a tool that has not ticked yet" do
    with_mcp_syntax_home do |db_path, settings_path|
      seed_bare_project(db_path)
      store = Gori::Store.open(db_path)
      begin
        # Bound under bare, against a bare database: the open-time reconcile is a no-op.
        tools = Gori::MCP::Tools.new(store, true, false, project_name: "demo", db_path: db_path)
        # NOW a peer switches and re-spells this project — a second surface opening it after
        # `gori settings env-syntax` does exactly that, and the marker is how it says so. This
        # process is still reading bare and has not ticked (`create_repeater` is not `env_refresh`).
        store.set_setting(Gori::Env::PROJECT_SYNTAX_KEY, "namespaced")
        store.flush
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
        got = mcp_ok_json(tools, "create_repeater",
          %({"target":"https://$API","request":"GET / HTTP/1.1\\r\\nAuthorization: $token\\r\\n\\r\\n"}))
        id = got["id"].as_i64
        store.flush
        String.new(store.get_repeater_full(id).not_nil!.request)
          .should contain("Authorization: $BIND.token\r\n")
        store.get_repeater_full(id).not_nil!.target.should eq("https://$ENV.API")
      ensure
        store.close
      end
    end
  end
end
