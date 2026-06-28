require "./spec_helper"
require "file_utils"

describe Gori::Settings do
  describe ".upstream_proxy_addr" do
    it "returns nil when unset/blank" do
      Gori::Settings.upstream_proxy = "  "
      Gori::Settings.upstream_proxy_addr.should be_nil
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "parses host:port" do
      Gori::Settings.upstream_proxy = "127.0.0.1:8080"
      Gori::Settings.upstream_proxy_addr.should eq({"127.0.0.1", 8080})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "strips an http:// scheme + trailing slash" do
      Gori::Settings.upstream_proxy = "http://proxy.local:3128/"
      Gori::Settings.upstream_proxy_addr.should eq({"proxy.local", 3128})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "defaults the port to 8080 when omitted" do
      Gori::Settings.upstream_proxy = "proxy.local"
      Gori::Settings.upstream_proxy_addr.should eq({"proxy.local", 8080})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "parses a bracketed IPv6 literal, with and without a port" do
      Gori::Settings.upstream_proxy = "[::1]"
      Gori::Settings.upstream_proxy_addr.should eq({"::1", 8080})
      Gori::Settings.upstream_proxy = "[2001:db8::1]:3128"
      Gori::Settings.upstream_proxy_addr.should eq({"2001:db8::1", 3128})
    ensure
      Gori::Settings.upstream_proxy = ""
    end
  end

  it "persists and reloads the network settings as JSON" do
    dir = File.tempname("gori-settings")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.bind_host = "0.0.0.0"
      Gori::Settings.bind_port = 9999
      Gori::Settings.upstream_proxy = "up:1234"
      Gori::Settings.save.should be_true

      Gori::Settings.bind_host = "x"
      Gori::Settings.bind_port = 1
      Gori::Settings.upstream_proxy = ""
      Gori::Settings.load
      Gori::Settings.bind_host.should eq("0.0.0.0")
      Gori::Settings.bind_port.should eq(9999)
      Gori::Settings.upstream_proxy.should eq("up:1234")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_host = "127.0.0.1"
      Gori::Settings.bind_port = 8070
      Gori::Settings.upstream_proxy = ""
    end
  end

  it "keeps defaults on a missing/garbled settings file" do
    dir = File.tempname("gori-settings-empty")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.bind_port = 7000
      Gori::Settings.load # no file → unchanged
      Gori::Settings.bind_port.should eq(7000)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_port = 8070
    end
  end

  describe ".editor_command" do
    it "splits a configured command into program + args" do
      Gori::Settings.editor = "code --wait"
      Gori::Settings.editor_command.should eq(["code", "--wait"])
    ensure
      Gori::Settings.editor = ""
    end

    it "falls back to $VISUAL → $EDITOR → vi when unset" do
      Gori::Settings.editor = ""
      v = ENV["VISUAL"]?; e = ENV["EDITOR"]?
      begin
        ENV["VISUAL"] = "nvim"
        Gori::Settings.editor_command.should eq(["nvim"])
        ENV.delete("VISUAL"); ENV["EDITOR"] = "nano"
        Gori::Settings.editor_command.should eq(["nano"])
        ENV.delete("EDITOR")
        Gori::Settings.editor_command.should eq(["vi"])
      ensure
        v ? (ENV["VISUAL"] = v) : ENV.delete("VISUAL")
        e ? (ENV["EDITOR"] = e) : ENV.delete("EDITOR")
      end
    end
  end

  it "round-trips the editor command + loads it even with no network block" do
    dir = File.tempname("gori-settings-ed")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.editor = "vim -u NONE"
      Gori::Settings.save.should be_true
      Gori::Settings.editor = "" # clear, then reload from disk
      Gori::Settings.load
      Gori::Settings.editor.should eq("vim -u NONE")

      # regression: an editor-only file (no "network" block) still loads the editor
      File.write(Gori::Settings.path, %({"editor":{"command":"emacs -nw"}}))
      Gori::Settings.editor = ""
      Gori::Settings.load
      Gori::Settings.editor.should eq("emacs -nw")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.editor = ""
    end
  end

  it "round-trips the colour theme" do
    dir = File.tempname("gori-settings-theme")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.theme = "tokyonight"
      Gori::Settings.save.should be_true
      Gori::Settings.theme = "goridark" # flip, then reload from disk
      Gori::Settings.load
      Gori::Settings.theme.should eq("tokyonight")

      # an older file with no "theme" key keeps the in-memory default
      File.write(Gori::Settings.path, %({"network":{"bind_host":"127.0.0.1"}}))
      Gori::Settings.theme = "goridark"
      Gori::Settings.load
      Gori::Settings.theme.should eq("goridark")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = "goridark"
    end
  end

  it "round-trips the editor markdown toggle (false must survive, not default to true)" do
    dir = File.tempname("gori-settings-md")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.editor_markdown = false
      Gori::Settings.save.should be_true
      Gori::Settings.editor_markdown = true # flip, then reload from disk
      Gori::Settings.load
      Gori::Settings.editor_markdown.should be_false

      # a file without the markdown key keeps the in-memory default (true)
      File.write(Gori::Settings.path, %({"editor":{"command":"vi"}}))
      Gori::Settings.editor_markdown = true
      Gori::Settings.load
      Gori::Settings.editor_markdown.should be_true
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.editor_markdown = true
    end
  end

  it "round-trips the tab-bar layout (order + a hidden tab; false must survive)" do
    dir = File.tempname("gori-settings-tabs")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.tab_prefs = [{"help", true}, {"project", true}, {"agent", false}]
      Gori::Settings.save.should be_true
      Gori::Settings.tab_prefs = [] of {String, Bool} # clear, then reload from disk
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"help", true}, {"project", true}, {"agent", false}])

      # an older file with no "tabs" key keeps the current in-memory value (the default
      # [] at real startup), like the other fields — never resurrects a phantom layout
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.tab_prefs = [{"notes", false}]
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"notes", false}])

      # malformed entries are tolerated: blank/missing id dropped, non-bool visible ⇒ visible
      File.write(Gori::Settings.path, %({"tabs":[{"id":"replay"},{"id":""},{"visible":false},{"id":"notes","visible":"x"}]}))
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"replay", true}, {"notes", true}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tab_prefs = [] of {String, Bool}
    end
  end

  it "omits the tabs key entirely when tab_prefs is empty" do
    dir = File.tempname("gori-settings-notabs")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.tab_prefs = [] of {String, Bool}
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("tabs").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tab_prefs = [] of {String, Bool}
    end
  end

  it "round-trips the legacy Convert scratch state (input + chain + named chains)" do
    dir = File.tempname("gori-settings-convert")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.convert_sessions = [] of {String, String, String} # empty ⇒ legacy scalars are written
      Gori::Settings.convert_input = "hello world"
      Gori::Settings.convert_chain = "base64 > sha256"
      Gori::Settings.convert_chains = [{"hash", "base64 > sha256"}, {"enc", "url-encode"}]
      Gori::Settings.save.should be_true
      Gori::Settings.convert_input = ""
      Gori::Settings.convert_chain = ""
      Gori::Settings.convert_chains = [] of {String, String}
      Gori::Settings.load
      Gori::Settings.convert_input.should eq("hello world")
      Gori::Settings.convert_chain.should eq("base64 > sha256")
      Gori::Settings.convert_chains.should eq([{"hash", "base64 > sha256"}, {"enc", "url-encode"}])

      # an older file with no "convert" key keeps the current in-memory defaults
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.convert_input = "kept"
      Gori::Settings.convert_chains = [{"x", "hex"}]
      Gori::Settings.load
      Gori::Settings.convert_input.should eq("kept")
      Gori::Settings.convert_chains.should eq([{"x", "hex"}])

      # malformed named chains tolerated: entries missing name/spec are dropped
      File.write(Gori::Settings.path, %({"convert":{"chains":[{"name":"ok","spec":"hex"},{"name":""},{"spec":"md5"}]}}))
      Gori::Settings.load
      Gori::Settings.convert_chains.should eq([{"ok", "hex"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.convert_input = ""
      Gori::Settings.convert_chain = ""
      Gori::Settings.convert_chains = [] of {String, String}
      Gori::Settings.convert_sessions = [] of {String, String, String}
    end
  end

  it "round-trips open Convert sub-tabs (sessions) and reads a legacy file for migration" do
    dir = File.tempname("gori-settings-convert-sessions")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.convert_input = ""
      Gori::Settings.convert_chain = ""
      Gori::Settings.convert_chains = [] of {String, String}
      Gori::Settings.convert_sessions = [{"in1", "base64", "first"}, {"in2", "hex > upper", ""}]
      Gori::Settings.save.should be_true
      # sessions are the source of truth once present; the legacy scalars are not written
      raw = File.read(Gori::Settings.path)
      raw.includes?(%("sessions")).should be_true

      Gori::Settings.convert_sessions = [] of {String, String, String}
      Gori::Settings.load
      Gori::Settings.convert_sessions.should eq([{"in1", "base64", "first"}, {"in2", "hex > upper", ""}])

      # a legacy file (only input/chain, no "sessions" array) loads with sessions empty,
      # so the controller migrates the scalars into a single session
      File.write(Gori::Settings.path, %({"convert":{"input":"legacy","chain":"md5"}}))
      Gori::Settings.convert_sessions = [] of {String, String, String}
      Gori::Settings.load
      Gori::Settings.convert_sessions.empty?.should be_true
      Gori::Settings.convert_input.should eq("legacy")
      Gori::Settings.convert_chain.should eq("md5")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.convert_input = ""
      Gori::Settings.convert_chain = ""
      Gori::Settings.convert_chains = [] of {String, String}
      Gori::Settings.convert_sessions = [] of {String, String, String}
    end
  end

  it "omits the convert key entirely when the Convert state is empty" do
    dir = File.tempname("gori-settings-noconvert")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.convert_input = ""
      Gori::Settings.convert_chain = ""
      Gori::Settings.convert_chains = [] of {String, String}
      Gori::Settings.convert_sessions = [] of {String, String, String}
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("convert").should be_false

      # a single blank+unnamed open session is still "nothing to persist" — a cleared or
      # dirtied-but-empty workbench must not write a stub "convert" block either
      Gori::Settings.convert_sessions = [{"", "", ""}]
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("convert").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.convert_sessions = [] of {String, String, String}
    end
  end

  it "round-trips the hotkey overrides + OS profile (an unbind [] must survive)" do
    dir = File.tempname("gori-settings-hotkeys")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.keymap_os = "linux"
      Gori::Settings.keymap_overrides = {"rules.edit" => ["g"], "scope.edit" => [] of String}
      Gori::Settings.save.should be_true

      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.load
      Gori::Settings.keymap_os.should eq("linux")
      Gori::Settings.keymap_overrides.should eq({"rules.edit" => ["g"], "scope.edit" => [] of String})

      # tolerant: non-array entry dropped, unparseable chord dropped, [] preserved
      File.write(Gori::Settings.path,
        %({"hotkeys":{"os":"WINDOWS","bindings":{"a":"x","b":["ctrl-g","nope"],"c":[]}}}))
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.load
      Gori::Settings.keymap_os.should eq("windows")                 # normalized lowercase
      Gori::Settings.keymap_overrides.has_key?("a").should be_false # non-array dropped
      Gori::Settings.keymap_overrides["b"].should eq(["ctrl-g"])    # garbage label dropped
      Gori::Settings.keymap_overrides["c"].should eq([] of String)  # explicit unbind kept

      # a file with no "hotkeys" block keeps the in-memory defaults
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.keymap_os = "darwin"
      Gori::Settings.keymap_overrides = {"x" => ["y"]}
      Gori::Settings.load
      Gori::Settings.keymap_os.should eq("darwin")
      Gori::Settings.keymap_overrides.should eq({"x" => ["y"]})
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
    end
  end

  it "omits the hotkeys block entirely when untouched (auto + no overrides)" do
    dir = File.tempname("gori-settings-nohotkeys")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("hotkeys").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
    end
  end
end
