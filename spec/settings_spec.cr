require "./spec_helper"
require "file_utils"

private def reset_net
  Gori::Settings.project_bind_host = nil
  Gori::Settings.project_bind_port = nil
  Gori::Settings.project_upstream_proxy = nil
  Gori::Settings.bind_host = "127.0.0.1"
  Gori::Settings.bind_port = 8070
  Gori::Settings.upstream_proxy = ""
end

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

  it "persists and reloads env settings as JSON" do
    dir = File.tempname("gori-settings-env")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.env_prefix = "%"
      Gori::Settings.env_vars = [{"HOST", "h.test"}, {"TOKEN", "t"}]
      Gori::Settings.save.should be_true

      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.load
      Gori::Settings.env_prefix.should eq("%")
      Gori::Settings.env_vars.should eq([{"HOST", "h.test"}, {"TOKEN", "t"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [] of {String, String}
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

  it "persists and reloads layout prefs; omits the layout section at factory defaults" do
    dir = File.tempname("gori-settings-layout")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_layout = {Gori::Settings.history_preview, Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.history_preview = true
      Gori::Settings.history_list_order = "oldest"
      Gori::Settings.sitemap_expand_depth = 2
      Gori::Settings.save.should be_true
      raw = File.read(Gori::Settings.path)
      raw.should contain(%("layout"))
      raw.should contain(%("history_preview":true))
      raw.should contain(%("history_list_order":"oldest"))

      Gori::Settings.history_preview = false
      Gori::Settings.history_list_order = "newest"
      Gori::Settings.sitemap_expand_depth = -1
      Gori::Settings.load
      Gori::Settings.history_preview.should be_true
      Gori::Settings.history_list_order.should eq("oldest")
      Gori::Settings.sitemap_expand_depth.should eq(2)

      # Back to defaults → section omitted
      Gori::Settings.history_preview = Gori::Settings::DEFAULT_HISTORY_PREVIEW
      Gori::Settings.history_list_order = Gori::Settings::DEFAULT_HISTORY_LIST_ORDER
      Gori::Settings.sitemap_expand_depth = Gori::Settings::DEFAULT_SITEMAP_EXPAND_DEPTH
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("layout"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.history_preview, Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth = prev_layout
    end
  end

  it "normalizes invalid sitemap expand depths to the default" do
    Gori::Settings.normalize_sitemap_depth(-1).should eq(-1)
    Gori::Settings.normalize_sitemap_depth(0).should eq(0)
    Gori::Settings.normalize_sitemap_depth(3).should eq(3)
    Gori::Settings.normalize_sitemap_depth(99).should eq(Gori::Settings::DEFAULT_SITEMAP_EXPAND_DEPTH)
  end

  it "reads pre-rename keys/ids for back-compat (convert/prism/findings/replay)" do
    dir = File.tempname("gori-settings-legacy")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    saved = {Gori::Settings.tab_prefs, Gori::Settings.keymap_overrides,
             Gori::Settings.probe_preview, Gori::Settings.issues_preview,
             Gori::Settings.decoder_input, Gori::Settings.decoder_sessions, Gori::Settings.decoder_chains}
    begin
      ENV["GORI_HOME"] = dir
      legacy = {
        "layout"  => {"prism_preview" => true, "findings_preview" => true},
        "tabs"    => [{"id" => "replay", "visible" => false}, {"id" => "convert", "visible" => true}],
        "hotkeys" => {"bindings" => {"replay.send" => ["ctrl+enter"], "finding.replay-flow" => ["r"], "prism.open" => ["o"]}},
        "convert" => {"input" => "aGk=", "sessions" => [] of String, "chains" => [] of String},
      }
      File.write(Gori::Settings.path, legacy.to_json)
      Gori::Settings.load

      Gori::Settings.probe_preview.should be_true                       # layout "prism_preview" -> probe_preview
      Gori::Settings.issues_preview.should be_true                      # layout "findings_preview" -> issues_preview
      Gori::Settings.decoder_input.should eq("aGk=")                    # "convert" section -> decoder_*
      Gori::Settings.tab_prefs.should contain({"repeater", false})      # tab id replay -> repeater (hidden kept)
      Gori::Settings.tab_prefs.should contain({"decoder", true})        # tab id convert -> decoder
      Gori::Settings.keymap_overrides.has_key?("repeater.send").should be_true   # verb id replay.send -> repeater.send
      Gori::Settings.keymap_overrides.has_key?("issue.repeater-flow").should be_true # compound finding.replay-flow -> issue.repeater-flow
      Gori::Settings.keymap_overrides.has_key?("probe.open").should be_true      # prism.open -> probe.open
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tab_prefs, Gori::Settings.keymap_overrides,
        Gori::Settings.probe_preview, Gori::Settings.issues_preview,
        Gori::Settings.decoder_input, Gori::Settings.decoder_sessions, Gori::Settings.decoder_chains = saved
    end
  end

  it "merges a concurrent writer's unrelated change instead of clobbering it" do
    dir = File.tempname("gori-settings-merge")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_theme = Gori::Settings.theme
    begin
      ENV["GORI_HOME"] = dir
      # Baseline file, then load it → establishes the 3-way-merge base.
      Gori::Settings.theme = "goriday"
      Gori::Settings.bind_port = 8070
      Gori::Settings.save
      Gori::Settings.load

      # A concurrent writer (another instance / hand-edit) changes an UNRELATED field
      # directly on disk, without touching this process's in-memory state.
      disk = JSON.parse(File.read(Gori::Settings.path)).as_h
      net = disk["network"].as_h
      net["bind_port"] = JSON::Any.new(4321_i64)
      disk["network"] = JSON::Any.new(net)
      File.write(Gori::Settings.path, disk.to_json)

      # This process changes a DIFFERENT field and saves.
      Gori::Settings.theme = "monokai"
      Gori::Settings.save

      Gori::Settings.load
      Gori::Settings.theme.should eq("monokai")    # my change won
      Gori::Settings.bind_port.should eq(4321_i32) # concurrent writer's change preserved (was clobbered to 8070)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = prev_theme
      Gori::Settings.bind_port = 8070
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
      Gori::Settings.tab_prefs = [{"help", true}, {"project", true}, {"miner", false}]
      Gori::Settings.save.should be_true
      Gori::Settings.tab_prefs = [] of {String, Bool} # clear, then reload from disk
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"help", true}, {"project", true}, {"miner", false}])

      # an older file with no "tabs" key keeps the current in-memory value (the default
      # [] at real startup), like the other fields — never resurrects a phantom layout
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.tab_prefs = [{"notes", false}]
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"notes", false}])

      # malformed entries are tolerated: blank/missing id dropped, non-bool visible ⇒ visible
      File.write(Gori::Settings.path, %({"tabs":[{"id":"repeater"},{"id":""},{"visible":false},{"id":"notes","visible":"x"}]}))
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"repeater", true}, {"notes", true}])
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

  it "round-trips the legacy Decoder scratch state (input + chain + named chains)" do
    dir = File.tempname("gori-settings-decoder")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.decoder_sessions = [] of {String, String, String} # empty ⇒ legacy scalars are written
      Gori::Settings.decoder_input = "hello world"
      Gori::Settings.decoder_chain = "base64 > sha256"
      Gori::Settings.decoder_chains = [{"hash", "base64 > sha256"}, {"enc", "url-encode"}]
      Gori::Settings.save.should be_true
      Gori::Settings.decoder_input = ""
      Gori::Settings.decoder_chain = ""
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.load
      Gori::Settings.decoder_input.should eq("hello world")
      Gori::Settings.decoder_chain.should eq("base64 > sha256")
      Gori::Settings.decoder_chains.should eq([{"hash", "base64 > sha256"}, {"enc", "url-encode"}])

      # an older file with no "decoder" key keeps the current in-memory defaults
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.decoder_input = "kept"
      Gori::Settings.decoder_chains = [{"x", "hex"}]
      Gori::Settings.load
      Gori::Settings.decoder_input.should eq("kept")
      Gori::Settings.decoder_chains.should eq([{"x", "hex"}])

      # malformed named chains tolerated: entries missing name/spec are dropped
      File.write(Gori::Settings.path, %({"decoder":{"chains":[{"name":"ok","spec":"hex"},{"name":""},{"spec":"md5"}]}}))
      Gori::Settings.load
      Gori::Settings.decoder_chains.should eq([{"ok", "hex"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.decoder_input = ""
      Gori::Settings.decoder_chain = ""
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [] of {String, String, String}
    end
  end

  it "round-trips open Decoder sub-tabs (sessions) and reads a legacy file for migration" do
    dir = File.tempname("gori-settings-decoder-sessions")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.decoder_input = ""
      Gori::Settings.decoder_chain = ""
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [{"in1", "base64", "first"}, {"in2", "hex > upper", ""}]
      Gori::Settings.save.should be_true
      # sessions are the source of truth once present; the legacy scalars are not written
      raw = File.read(Gori::Settings.path)
      raw.includes?(%("sessions")).should be_true

      Gori::Settings.decoder_sessions = [] of {String, String, String}
      Gori::Settings.load
      Gori::Settings.decoder_sessions.should eq([{"in1", "base64", "first"}, {"in2", "hex > upper", ""}])

      # a legacy file (only input/chain, no "sessions" array) loads with sessions empty,
      # so the controller migrates the scalars into a single session
      File.write(Gori::Settings.path, %({"decoder":{"input":"legacy","chain":"md5"}}))
      Gori::Settings.decoder_sessions = [] of {String, String, String}
      Gori::Settings.load
      Gori::Settings.decoder_sessions.empty?.should be_true
      Gori::Settings.decoder_input.should eq("legacy")
      Gori::Settings.decoder_chain.should eq("md5")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.decoder_input = ""
      Gori::Settings.decoder_chain = ""
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [] of {String, String, String}
    end
  end

  it "omits the decoder key entirely when the Decoder state is empty" do
    dir = File.tempname("gori-settings-nodecoder")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.decoder_input = ""
      Gori::Settings.decoder_chain = ""
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [] of {String, String, String}
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("decoder").should be_false

      # a single blank+unnamed open session is still "nothing to persist" — a cleared or
      # dirtied-but-empty workbench must not write a stub "decoder" block either
      Gori::Settings.decoder_sessions = [{"", "", ""}]
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("decoder").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.decoder_sessions = [] of {String, String, String}
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

  describe "per-project network override layer" do
    it "effective_* falls back to the global when no override is set" do
      reset_net
      Gori::Settings.upstream_proxy = "glob:3128"
      Gori::Settings.effective_bind_host.should eq("127.0.0.1")
      Gori::Settings.effective_bind_port.should eq(8070)
      Gori::Settings.effective_upstream_proxy.should eq("glob:3128")
    ensure
      reset_net
    end

    it "a project override wins over the global (incl. upstream_proxy_addr)" do
      reset_net
      Gori::Settings.upstream_proxy = "glob:3128"
      Gori::Settings.project_bind_host = "0.0.0.0"
      Gori::Settings.project_bind_port = 9100
      Gori::Settings.project_upstream_proxy = "corp:8888"
      Gori::Settings.effective_bind_host.should eq("0.0.0.0")
      Gori::Settings.effective_bind_port.should eq(9100)
      Gori::Settings.effective_upstream_proxy.should eq("corp:8888")
      Gori::Settings.upstream_proxy_addr.should eq({"corp", 8888})
    ensure
      reset_net
    end

    it "an explicit project '' upstream (direct) beats a non-blank global" do
      reset_net
      Gori::Settings.upstream_proxy = "glob:3128"
      Gori::Settings.project_upstream_proxy = ""
      Gori::Settings.effective_upstream_proxy.should eq("")
      Gori::Settings.upstream_proxy_addr.should be_nil # "" ⇒ direct
    ensure
      reset_net
    end

    it "never serializes the runtime project layer to settings.json" do
      dir = File.tempname("gori-settings-projnet")
      Dir.mkdir_p(dir)
      prev = ENV["GORI_HOME"]?
      begin
        ENV["GORI_HOME"] = dir
        Gori::Settings.project_bind_host = "10.9.9.9"
        Gori::Settings.project_bind_port = 9100
        Gori::Settings.project_upstream_proxy = "corp:8888"
        Gori::Settings.save.should be_true
        raw = File.read(Gori::Settings.path)
        raw.includes?("10.9.9.9").should be_false
        raw.includes?("9100").should be_false
        raw.includes?("corp:8888").should be_false
      ensure
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        reset_net
      end
    end
  end

  describe ".upstream_proxy_port_error" do
    it "accepts blank / no-port / valid ports (incl. bracketed IPv6)" do
      Gori::Settings.upstream_proxy_port_error("").should be_nil
      Gori::Settings.upstream_proxy_port_error("proxy.local").should be_nil
      Gori::Settings.upstream_proxy_port_error("proxy.local:3128").should be_nil
      Gori::Settings.upstream_proxy_port_error("[::1]:8080").should be_nil
    end

    it "rejects a non-numeric / out-of-range explicit port" do
      Gori::Settings.upstream_proxy_port_error("proxy:8O80").should_not be_nil
      Gori::Settings.upstream_proxy_port_error("proxy:99999").should_not be_nil
    end
  end
end
