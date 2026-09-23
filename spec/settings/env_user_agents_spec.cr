require "../spec_helper"
require "file_utils"

# `user_agents` (#1154) — the operator's own list for `$GEN.USER_AGENT`, replacing the
# built-in one when non-empty. Every example runs in its own temp home and restores the
# process-global settings through a load of their serialization (the env_syntax_spec discipline).
private def with_ua_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  prev_io = Gori::Settings.warning_io
  dir = File.tempname("gori-env-ua")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.user_agents = [] of String
    yield dir
  ensure
    Gori::Settings.user_agents = [] of String
    Gori::Settings.warning_io = prev_io
    Gori::Settings.reset_load_warning_guard
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

private def write_settings(dir : String, body : String) : Nil
  File.write(File.join(dir, "settings.json"), %({"env": {"syntax": "namespaced"}, #{body}}))
end

describe "Settings user_agents" do
  it "round-trips through the file, and writes nothing while it is empty" do
    with_ua_home do |_dir|
      Gori::Settings.save.should be_true
      JSON.parse(File.read(Gori::Settings.path))["env"].as_h.has_key?("user_agents").should be_false

      Gori::Settings.user_agents = ["UA-One/1.0", "Mozilla/5.0 (X11) Firefox/156.0"]
      Gori::Settings.save.should be_true
      Gori::Settings.user_agents = [] of String
      Gori::Settings.load
      Gori::Settings.user_agents.should eq(["UA-One/1.0", "Mozilla/5.0 (X11) Firefox/156.0"])
    end
  end

  # A dropped line silently changes which browser gori claims to be, so a drop is SAID.
  it "drops an unusable entry with a load warning, keeping the rest" do
    with_ua_home do |dir|
      io = IO::Memory.new
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      write_settings(dir, %("user_agents": ["  Keep/1.0  ", "bad\\r\\nX-Injected: 1", 7, ""]))
      Gori::Settings.load
      Gori::Settings.user_agents.should eq(["Keep/1.0"])
      io.to_s.should contain("user_agents entry 2 carries a control character")
    end
  end

  # Its own section, so the merge that takes a changed section whole cannot trade it for an env
  # var edit: a list set by `gori settings user-agents` while a TUI is open survives that TUI's
  # next env save (the review repro for #1154).
  it "survives another process's env save" do
    with_ua_home do |_dir|
      Gori::Settings.save.should be_true
      Gori::Settings.load
      path = Gori::Settings.path
      peer = JSON.parse(File.read(path)).as_h
      peer["user_agents"] = JSON::Any.new([JSON::Any.new("Peer/1.0")])
      File.write(path, peer.to_json)

      Gori::Settings.env_vars = [{"TOKEN", "t"}]
      Gori::Settings.save.should be_true
      on_disk = JSON.parse(File.read(path))
      on_disk["user_agents"].as_a.map(&.as_s).should eq(["Peer/1.0"])
      on_disk["env"]["vars"].as_a.size.should eq(1)
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end
  end

  it "reads a non-array as the built-in list, and says so" do
    with_ua_home do |dir|
      io = IO::Memory.new
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      write_settings(dir, %("user_agents": "Mozilla/5.0"))
      Gori::Settings.load
      Gori::Settings.user_agents.should be_empty
      io.to_s.should contain("must be an array of strings")
    end
  end

  # The profile-import rule `vars` follows: a document that does not name the section is not a
  # request to empty the list.
  it "keeps the list when the document does not name the section" do
    with_ua_home do |dir|
      Gori::Settings.user_agents = ["Mine/1.0"]
      write_settings(dir, %("mouse": {"enabled": true}))
      Gori::Settings.load
      Gori::Settings.user_agents.should eq(["Mine/1.0"])
    end
  end
end

describe "Settings.user_agents_from_text" do
  it "reads one trimmed line each, skipping blank and comment lines" do
    text = "# mine\n  A/1.0 (X11) \n\nB/2.0\r\n"
    Gori::Settings.user_agents_from_text(text).should eq(["A/1.0 (X11)", "B/2.0"])
  end

  # Never a list with the bad line quietly gone: the caller refuses the whole text.
  it "refuses the whole text over one unusable line, naming it" do
    Gori::Settings.user_agents_from_text("A/1.0\nB\t2.0\n").should eq("line 2 carries a control character")
  end

  # Bidi overrides and zero-width characters (Cf) hide text in the editor and the CLI listing;
  # `Char#control?` covers them along with Cc, so they are refused too.
  it "refuses invisible format characters as well as C0/C1 controls" do
    ["A\u202E/1.0", "A\u200B/1.0", "A\u0085/1.0", "A\u007F/1.0"].each do |line|
      Gori::Settings.user_agent_error(line).should eq("carries a control character")
    end
    Gori::Settings.user_agent_error("Mozilla/5.0 (é)").should be_nil
  end
end
