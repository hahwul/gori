require "../spec_helper"
require "file_utils"

# `Settings.reload_env_from_disk` / `reload_user_agents_from_disk` (#1217, #1218): a long-lived
# process re-reads the global `$ENV.KEY` table and the `$GEN.USER_AGENT` corpus a peer changed,
# and nothing else. Both sections are OMITTED from the file when empty, so the absence of the key
# in a file that parsed is the peer's answer — the case a keep-memory reload would get wrong by
# sending a deleted token forever.
private def with_env_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-env-reload")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.forget_reloaded_sections
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.user_agents = [] of String
    yield dir
  ensure
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.user_agents = [] of String
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    Gori::Settings.forget_reloaded_sections
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

private def write_settings(dir : String, body : String) : Nil
  File.write(File.join(dir, "settings.json"), body)
end

describe "Settings.reload_env_from_disk" do
  it "adopts a peer's rotated value and prefix" do
    with_env_home do |dir|
      write_settings(dir, %({"env":{"syntax":"bare","vars":[{"key":"TOKEN","value":"old"}]}}))
      Gori::Settings.reload_env_from_disk
      Gori::Settings.env_vars.should eq([{"TOKEN", "old"}])

      write_settings(dir, %({"env":{"syntax":"bare","prefix":"@","vars":[{"key":"TOKEN","value":"new"}]}}))
      Gori::Settings.reload_env_from_disk
      Gori::Settings.env_vars.should eq([{"TOKEN", "new"}])
      Gori::Settings.env_prefix.should eq("@")
    end
  end

  it "reads an absent vars key as the peer deleting every global var" do
    with_env_home do |dir|
      write_settings(dir, %({"env":{"syntax":"bare","prefix":"@","vars":[{"key":"TOKEN","value":"old"}]}}))
      Gori::Settings.reload_env_from_disk
      Gori::Settings.env_vars.should_not be_empty

      # What `serialize_env` writes once the last var is gone: no `vars`, and no `prefix` at default.
      write_settings(dir, %({"env":{"syntax":"bare"}}))
      Gori::Settings.reload_env_from_disk
      Gori::Settings.env_vars.should be_empty
      Gori::Settings.env_prefix.should eq(Gori::Settings::DEFAULT_ENV_PREFIX)
    end
  end

  it "leaves the grammar to EnvMigration.follow_disk" do
    with_env_home do |dir|
      with_env_syntax(Gori::Env::Syntax::Bare) do
        write_settings(dir, %({"env":{"syntax":"namespaced","vars":[{"key":"TOKEN","value":"v"}]}}))
        Gori::Settings.reload_env_from_disk
        Gori::Settings.env_vars.should eq([{"TOKEN", "v"}])
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      end
    end
  end

  it "keeps memory over a file it cannot parse" do
    with_env_home do |dir|
      Gori::Settings.env_vars = [{"TOKEN", "held"}]
      write_settings(dir, %({"env":{"vars":[{"key":"TOKEN"))
      Gori::Settings.reload_env_from_disk
      Gori::Settings.env_vars.should eq([{"TOKEN", "held"}])
    end
  end
end

describe "Settings.reload_user_agents_from_disk" do
  it "adopts a peer's list, and its reset back to the built-in one" do
    with_env_home do |dir|
      write_settings(dir, %({"env":{"syntax":"bare"},"user_agents":["Peer-UA/1"]}))
      Gori::Settings.reload_user_agents_from_disk
      Gori::Settings.user_agents.should eq(["Peer-UA/1"])
      Gori::Env.user_agents_source.should eq("settings")

      # An empty list is omitted on save, so the section's absence IS the reset.
      write_settings(dir, %({"env":{"syntax":"bare"}}))
      Gori::Settings.reload_user_agents_from_disk
      Gori::Settings.user_agents.should be_empty
      Gori::Env.user_agents_source.should eq("built-in")
    end
  end
end
