require "../spec_helper"

describe Gori::MCP::Install do
  describe ".config_path" do
    it "maps codex to ~/.codex/config.toml (or CODEX_HOME)" do
      Gori::MCP::Install.config_path("codex").should eq(
        File.join(ENV["CODEX_HOME"]?.presence || File.join(ENV["HOME"], ".codex"), "config.toml"))
    end

    it "maps grok to ~/.grok/config.toml" do
      Gori::MCP::Install.config_path("grok").should eq(File.join(ENV["HOME"], ".grok", "config.toml"))
    end

    it "maps claude-code to ~/.claude.json" do
      Gori::MCP::Install.config_path("claude-code").should eq(File.join(ENV["HOME"], ".claude.json"))
    end

    it "maps agy to the antigravity-cli mcp_config.json" do
      Gori::MCP::Install.config_path("agy").should eq(
        File.join(ENV["HOME"], ".gemini", "antigravity-cli", "mcp_config.json"))
    end

    it "maps claude to the platform's Claude Desktop config" do
      Gori::MCP::Install.config_path("claude").should eq(
        Gori::MCP::Install.claude_desktop_path(ENV["HOME"]))
    end

    it "raises on unknown targets" do
      expect_raises(ArgumentError, /Unknown install target/) do
        Gori::MCP::Install.config_path("nope")
      end
    end
  end

  describe ".claude_desktop_path" do
    # Every branch is asserted from every host: the Linux path was wrong for as long as it
    # was the `{% else %}` a Mac build could never run, so a spec that only checks the
    # native platform reproduces the bug rather than catching it.
    home = "/home/u"

    it "uses the macOS application-support directory on darwin" do
      Gori::MCP::Install.claude_desktop_path(home, :darwin, xdg_config_home: "/xdg", appdata: "C:/AppData")
        .should eq("/home/u/Library/Application Support/Claude/claude_desktop_config.json")
    end

    it "uses %APPDATA% on windows, falling back to AppData/Roaming" do
      Gori::MCP::Install.claude_desktop_path(home, :windows, appdata: "C:/Users/u/AppData/Roaming")
        .should eq("C:/Users/u/AppData/Roaming/Claude/claude_desktop_config.json")
      Gori::MCP::Install.claude_desktop_path(home, :windows, appdata: nil)
        .should eq("/home/u/AppData/Roaming/Claude/claude_desktop_config.json")
      Gori::MCP::Install.claude_desktop_path(home, :windows, appdata: "")
        .should eq("/home/u/AppData/Roaming/Claude/claude_desktop_config.json")
    end

    it "uses ~/.config on linux when XDG_CONFIG_HOME is unset" do
      Gori::MCP::Install.claude_desktop_path(home, :linux, xdg_config_home: nil)
        .should eq("/home/u/.config/Claude/claude_desktop_config.json")
    end

    it "honors XDG_CONFIG_HOME on linux" do
      # Whatever the shell that launches both gori and the desktop app carries — Nix,
      # home-manager and per-user distro setups all move this. (NOT Flatpak: that value
      # only exists inside the sandbox, where a host-side install never runs.)
      Gori::MCP::Install.claude_desktop_path(home, :linux, xdg_config_home: "/home/u/cfg")
        .should eq("/home/u/cfg/Claude/claude_desktop_config.json")
    end

    it "ignores an empty or relative XDG_CONFIG_HOME on linux" do
      # The basedir spec says a relative value must be ignored; honoring one would write
      # the install under whatever directory the user happened to run gori from.
      Gori::MCP::Install.claude_desktop_path(home, :linux, xdg_config_home: "")
        .should eq("/home/u/.config/Claude/claude_desktop_config.json")
      Gori::MCP::Install.claude_desktop_path(home, :linux, xdg_config_home: ".config")
        .should eq("/home/u/.config/Claude/claude_desktop_config.json")
    end
  end

  describe ".build_args" do
    it "starts with mcp and appends optional flags" do
      Gori::MCP::Install.build_args.should eq(["mcp"])
      Gori::MCP::Install.build_args(project: "eng", read_only: true).should eq(
        ["mcp", "--project=eng", "--read-only"])
      Gori::MCP::Install.build_args(use_active_project: true).should eq(
        ["mcp", "--use-active-project"])
    end

    it "carries --no-project into the installed argv" do
      # Dropped here, the installed server path-binds to whatever workspace the client
      # spawns it in — the opposite of the flag the user typed and gori validated.
      Gori::MCP::Install.build_args(no_project: true).should eq(["mcp", "--no-project"])
      Gori::MCP::Install.build_args(no_project: true, read_only: true).should eq(
        ["mcp", "--no-project", "--read-only"])
    end

    it "carries --config into the installed argv, absolute" do
      # The client spawns this command from a directory the user never chose, so a
      # relative --config would resolve against the wrong tree (or not at all).
      args = Gori::MCP::Install.build_args(config_path: "./ci-settings.json")
      args.size.should eq(2)
      args[0].should eq("mcp")
      args[1].should eq("--config=#{File.expand_path("./ci-settings.json")}")
    end

    it "expands a quoted tilde instead of writing it as a literal directory" do
      # `gori mcp --db '~/e.db' --install-codex`: the shell never expanded it, and a `~`
      # joined onto the CWD becomes a permanent wrong path inside the client's config.
      home = ENV["HOME"]? || Path.home.to_s
      args = Gori::MCP::Install.build_args("~/e.db", config_path: "~/gori.json")
      args.should eq(["mcp", "--config=#{File.join(home, "gori.json")}",
                      "--db=#{File.join(home, "e.db")}"])
    end

    it "emits no selector flags when none were asked for" do
      Gori::MCP::Install.build_args(no_project: false, config_path: nil).should eq(["mcp"])
      Gori::MCP::Install.build_args(config_path: "").should eq(["mcp"])
    end
  end

  describe ".upsert_toml_table" do
    it "appends a table to empty content" do
      out = Gori::MCP::Install.upsert_toml_table("", "mcp_servers.gori",
        "command = \"/bin/gori\"\nargs = [\"mcp\"]\n")
      out.should contain("[mcp_servers.gori]")
      out.should contain(%(command = "/bin/gori"))
      out.should contain(%(args = ["mcp"]))
      out.should end_with("\n")
    end

    it "preserves other tables and comments when appending" do
      existing = <<-TOML
      model = "gpt"
      # keep me

      [mcp_servers.other]
      command = "other"
      TOML
      out = Gori::MCP::Install.upsert_toml_table(existing, "mcp_servers.gori",
        "command = \"/bin/gori\"\nargs = [\"mcp\"]\n")
      out.should contain("model = \"gpt\"")
      out.should contain("# keep me")
      out.should contain("[mcp_servers.other]")
      out.should contain("command = \"other\"")
      out.should contain("[mcp_servers.gori]")
      out.should contain(%(command = "/bin/gori"))
    end

    it "replaces an existing table including subtables" do
      existing = <<-TOML
      [features]
      x = true

      [mcp_servers.gori]
      command = "old"
      args = ["old"]

      [mcp_servers.gori.env]
      FOO = "bar"

      [mcp_servers.keep]
      command = "keep"
      TOML
      out = Gori::MCP::Install.upsert_toml_table(existing, "mcp_servers.gori",
        "command = \"/new\"\nargs = [\"mcp\", \"--read-only\"]\n")
      out.should contain("[features]")
      out.should contain("[mcp_servers.keep]")
      out.should contain(%(command = "/new"))
      out.should contain(%(args = ["mcp", "--read-only"]))
      out.should_not contain("old")
      out.should_not contain("[mcp_servers.gori.env]")
      out.should_not contain("FOO")
    end
  end

  describe ".install" do
    it "writes a JSON mcpServers entry for claude-style targets" do
      Dir.tempdir.try do |base|
        # Point HOME at a temp tree so we don't touch the real Claude config.
        home = File.join(base, "home-json-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(home)
        old_home = ENV["HOME"]?
        ENV["HOME"] = home
        begin
          path = Gori::MCP::Install.install("agy", exe_path: "/opt/gori/bin/gori",
            project: "demo", read_only: true)
          path.should eq(File.join(home, ".gemini", "antigravity-cli", "mcp_config.json"))
          parsed = JSON.parse(File.read(path))
          entry = parsed["mcpServers"]["gori"]
          entry["command"].as_s.should eq("/opt/gori/bin/gori")
          entry["args"].as_a.map(&.as_s).should eq(["mcp", "--project=demo", "--read-only"])
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
        end
      end
    end

    it "creates the Claude Desktop directory wherever this platform puts it" do
      # Nothing about the tree exists beforehand — on Linux that means gori has to create
      # $XDG_CONFIG_HOME/Claude, a directory only the fixed path names.
      Dir.tempdir.try do |base|
        home = File.join(base, "home-desktop-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(home)
        old_home = ENV["HOME"]?
        old_xdg = ENV["XDG_CONFIG_HOME"]?
        old_appdata = ENV["APPDATA"]?
        ENV["HOME"] = home
        # BOTH of the vars that can steer the path off $HOME, kept inside the temp tree:
        # this spec calls the real `install`, so whichever branch the host takes must land
        # in the sandbox. A Windows host reads APPDATA and would otherwise have merged an
        # entry into the developer's own %APPDATA%\Claude\claude_desktop_config.json.
        ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
        ENV["APPDATA"] = File.join(home, "AppData", "Roaming")
        begin
          path = Gori::MCP::Install.install("claude", exe_path: "/opt/gori")
          path.should eq(Gori::MCP::Install.claude_desktop_path(home))
          path.should start_with(home)
          JSON.parse(File.read(path))["mcpServers"]["gori"]["command"].as_s.should eq("/opt/gori")
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_xdg ? (ENV["XDG_CONFIG_HOME"] = old_xdg) : ENV.delete("XDG_CONFIG_HOME")
          old_appdata ? (ENV["APPDATA"] = old_appdata) : ENV.delete("APPDATA")
        end
      end
    end

    it "refuses to clobber a non-JSON config file" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-bad-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(File.join(home, ".gemini", "antigravity-cli"))
        bad = File.join(home, ".gemini", "antigravity-cli", "mcp_config.json")
        File.write(bad, "not-json{")
        old_home = ENV["HOME"]?
        ENV["HOME"] = home
        begin
          expect_raises(Exception, /Refusing to overwrite/) do
            Gori::MCP::Install.install("agy", exe_path: "/opt/gori")
          end
          File.read(bad).should eq("not-json{")
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
        end
      end
    end

    it "keeps the existing config's permissions and leaves no temp file behind" do
      # ~/.claude.json holds auth and every other MCP server: an update must not widen a
      # 0600 file to the umask default, nor litter the directory with partial writes.
      Dir.tempdir.try do |base|
        home = File.join(base, "home-perm-#{Random::Secure.hex(4)}")
        dir = File.join(home, ".gemini", "antigravity-cli")
        Dir.mkdir_p(dir)
        config = File.join(dir, "mcp_config.json")
        File.write(config, %({"other":{"keep":true}}))
        File.chmod(config, 0o600)
        old_home = ENV["HOME"]?
        ENV["HOME"] = home
        begin
          Gori::MCP::Install.install("agy", exe_path: "/opt/gori")
          File.info(config).permissions.should eq(File::Permissions.new(0o600))
          JSON.parse(File.read(config))["other"]["keep"].as_bool.should be_true
          Dir.children(dir).sort.should eq(["mcp_config.json"])
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
        end
      end
    end

    it "writes through a symlinked config instead of detaching it" do
      # Dotfiles are routinely symlinked into a dotfiles repo. Renaming over the LINK would
      # leave the client reading a plain file while the repo copy silently went stale.
      Dir.tempdir.try do |base|
        home = File.join(base, "home-link-#{Random::Secure.hex(4)}")
        dotfiles = File.join(base, "dotfiles-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(home)
        Dir.mkdir_p(dotfiles)
        real = File.join(dotfiles, "claude.json")
        File.write(real, %({"other":{"keep":true}}))
        link = File.join(home, ".claude.json")
        File.symlink(real, link)
        old_home = ENV["HOME"]?
        ENV["HOME"] = home
        begin
          Gori::MCP::Install.install("claude-code", exe_path: "/opt/gori")
          File.symlink?(link).should be_true # still a link, not replaced by a file
          parsed = JSON.parse(File.read(real))
          parsed["other"]["keep"].as_bool.should be_true
          parsed["mcpServers"]["gori"]["command"].as_s.should eq("/opt/gori")
          Dir.children(dotfiles).sort.should eq(["claude.json"])
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
        end
      end
    end

    it "installs every target and keeps going past one that fails" do
      # `gori mcp --install-claude-code --install-codex` with a hand-broken ~/.claude.json:
      # the client that CAN be configured still is, the one that cannot is named, and which
      # clients end up installed does not depend on the order the flags were typed in.
      Dir.tempdir.try do |base|
        home = File.join(base, "home-multi-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(File.join(home, ".codex"))
        broken = File.join(home, ".claude.json")
        File.write(broken, "not-json{")
        old_home = ENV["HOME"]?
        old_codex = ENV["CODEX_HOME"]?
        ENV["HOME"] = home
        ENV.delete("CODEX_HOME")
        begin
          outcomes = Gori::MCP::Install.install_all(
            ["claude-code", "codex", "codex"], exe_path: "/opt/gori")
          outcomes.map(&.target).should eq(["claude-code", "codex"]) # deduped, order kept
          outcomes[0].ok?.should be_false
          outcomes[0].error.to_s.should contain("Refusing to overwrite")
          outcomes[1].ok?.should be_true
          # The failing target left its file alone; the healthy one was written anyway.
          File.read(broken).should eq("not-json{")
          File.read(File.join(home, ".codex", "config.toml")).should contain("[mcp_servers.gori]")
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_codex ? (ENV["CODEX_HOME"] = old_codex) : ENV.delete("CODEX_HOME")
        end
      end
    end

    it "writes a TOML mcp_servers.gori table for codex" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-toml-#{Random::Secure.hex(4)}")
        codex_home = File.join(home, ".codex")
        Dir.mkdir_p(codex_home)
        File.write(File.join(codex_home, "config.toml"), "model = \"o3\"\n\n[features]\njs_repl = false\n")
        old_home = ENV["HOME"]?
        old_codex = ENV["CODEX_HOME"]?
        ENV["HOME"] = home
        ENV.delete("CODEX_HOME")
        begin
          path = Gori::MCP::Install.install("codex", exe_path: "/opt/gori/bin/gori",
            insecure_upstream: true)
          path.should eq(File.join(codex_home, "config.toml"))
          text = File.read(path)
          text.should contain("model = \"o3\"")
          text.should contain("[features]")
          text.should contain("js_repl = false")
          text.should contain("[mcp_servers.gori]")
          text.should contain(%(command = "/opt/gori/bin/gori"))
          text.should contain(%(args = ["mcp", "--insecure-upstream"]))
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_codex ? (ENV["CODEX_HOME"] = old_codex) : ENV.delete("CODEX_HOME")
        end
      end
    end

    it "writes a TOML mcp_servers.gori table for grok and updates in place" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-grok-#{Random::Secure.hex(4)}")
        grok_dir = File.join(home, ".grok")
        Dir.mkdir_p(grok_dir)
        File.write(File.join(grok_dir, "config.toml"), "[ui]\nyolo = true\n")
        old_home = ENV["HOME"]?
        ENV["HOME"] = home
        begin
          path = Gori::MCP::Install.install("grok", exe_path: "/opt/gori")
          path.should eq(File.join(grok_dir, "config.toml"))
          # Second install updates rather than duplicating.
          Gori::MCP::Install.install("grok", exe_path: "/opt/gori2", read_only: true)
          text = File.read(path)
          text.should contain("[ui]")
          text.should contain("yolo = true")
          text.scan("[mcp_servers.gori]").size.should eq(1)
          text.should contain(%(command = "/opt/gori2"))
          text.should contain(%(args = ["mcp", "--read-only"]))
          text.should_not contain(%(command = "/opt/gori"\n))
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
        end
      end
    end
  end
end
