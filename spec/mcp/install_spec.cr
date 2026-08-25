require "../spec_helper"

# A throwaway `config.toml` (or the absence of one) for the `.install_toml` examples. They go
# through the REAL entry point rather than the line splice, because the refusals and the
# read-back guard live there.
private def with_toml(existing : String?, &)
  Dir.tempdir.try do |base|
    dir = File.join(base, "codex-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "config.toml")
    File.write(path, existing) if existing
    begin
      yield path
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe Gori::MCP::Install do
  describe ".config_path" do
    it "maps codex to ~/.codex/config.toml (or CODEX_HOME)" do
      Gori::MCP::Install.config_path("codex").should eq(
        File.join(ENV["CODEX_HOME"]?.presence || File.join(ENV["HOME"], ".codex"), "config.toml"))
    end

    it "maps grok to ~/.grok/config.toml" do
      Gori::MCP::Install.config_path("grok").should eq(File.join(ENV["HOME"], ".grok", "config.toml"))
    end

    it "maps hermes to ~/.hermes/config.yaml, or HERMES_HOME" do
      # Pinned to a literal, not rebuilt from `hermes_home`: an expectation that calls the
      # function under test moves with it, and only the `config.yaml` half would have failed.
      old_hermes = ENV["HERMES_HOME"]?
      ENV.delete("HERMES_HOME")
      begin
        Gori::MCP::Install.config_path("hermes").should eq(
          File.join(ENV["HOME"], ".hermes", "config.yaml"))
        ENV["HERMES_HOME"] = "/opt/hermes-eng"
        Gori::MCP::Install.config_path("hermes").should eq("/opt/hermes-eng/config.yaml")
      ensure
        old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
      end
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

  describe ".hermes_home" do
    # Same rule as claude_desktop_path: every branch asserted from every host, because the
    # one branch this platform cannot execute is the one that stays wrong.
    home = "/home/u"

    it "uses ~/.hermes on darwin and linux" do
      Gori::MCP::Install.hermes_home(home, :darwin, hermes_home_env: nil, local_appdata: nil)
        .should eq("/home/u/.hermes")
      Gori::MCP::Install.hermes_home(home, :linux, hermes_home_env: nil, local_appdata: nil)
        .should eq("/home/u/.hermes")
    end

    it "uses %LOCALAPPDATA% on windows, falling back to AppData/Local" do
      Gori::MCP::Install.hermes_home(home, :windows, hermes_home_env: nil,
        local_appdata: "C:/Users/u/AppData/Local").should eq("C:/Users/u/AppData/Local/hermes")
      Gori::MCP::Install.hermes_home(home, :windows, hermes_home_env: nil, local_appdata: nil)
        .should eq("/home/u/AppData/Local/hermes")
      Gori::MCP::Install.hermes_home(home, :windows, hermes_home_env: nil, local_appdata: "")
        .should eq("/home/u/AppData/Local/hermes")
    end

    it "lets HERMES_HOME win on every platform" do
      # A profile-per-engagement setup moves it, and the agent reads the variable on every
      # launch — install anywhere else and the client never sees the server.
      Gori::MCP::Install.hermes_home(home, :darwin, hermes_home_env: "/opt/h").should eq("/opt/h")
      Gori::MCP::Install.hermes_home(home, :linux, hermes_home_env: "/opt/h").should eq("/opt/h")
      Gori::MCP::Install.hermes_home(home, :windows, hermes_home_env: "D:/h").should eq("D:/h")
    end

    it "ignores an empty or all-whitespace HERMES_HOME" do
      # Hermes strips the variable before testing it, so " " is unset to the agent; honoring
      # it here would install into a directory named " " that nothing reads.
      Gori::MCP::Install.hermes_home(home, :linux, hermes_home_env: "").should eq("/home/u/.hermes")
      Gori::MCP::Install.hermes_home(home, :linux, hermes_home_env: "   ").should eq("/home/u/.hermes")
    end
  end

  describe ".upsert_yaml_server" do
    body = ["command: \"/bin/gori\"", "args:", "  - \"mcp\""]

    it "appends the whole block to a file that has no mcp_servers" do
      text = Gori::MCP::Install.upsert_yaml_server("model:\n  default: claude-sonnet-5\n",
        "mcp_servers", "gori", body)
      text.should eq(<<-YAML)
        model:
          default: claude-sonnet-5

        mcp_servers:
          gori:
            command: "/bin/gori"
            args:
              - "mcp"\n
        YAML
    end

    it "writes the block into an empty document" do
      Gori::MCP::Install.upsert_yaml_server("", "mcp_servers", "gori", body)
        .should eq("mcp_servers:\n  gori:\n    command: \"/bin/gori\"\n    args:\n      - \"mcp\"\n")
    end

    it "keeps sibling servers, their secrets, and the comments around them" do
      # The whole reason this splices lines instead of re-emitting a parse tree: a hermes
      # config.yaml is mostly commented documentation, and the servers beside gori hold
      # their own API keys.
      existing = <<-YAML
        model:
          provider: anthropic

        # ── MCP servers ──────────────────────────────
        mcp_servers:
          github:
            command: "npx"
            args: ["-y", "@modelcontextprotocol/server-github"]
            env:
              GITHUB_PERSONAL_ACCESS_TOKEN: "ghp_secret"

        plugins:
          enabled:
            - orca-status\n
        YAML
      text = Gori::MCP::Install.upsert_yaml_server(existing, "mcp_servers", "gori", body)
      text.should contain("# ── MCP servers ──────────────────────────────")
      text.should contain("GITHUB_PERSONAL_ACCESS_TOKEN: \"ghp_secret\"")
      text.should contain("provider: anthropic")
      text.should contain("    - orca-status")
      # The new entry sits inside the block, not after the `plugins:` section that follows it.
      text.index("  gori:").not_nil!.should be < text.index("plugins:").not_nil!
      YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
      YAML.parse(text)["plugins"]["enabled"][0].as_s.should eq("orca-status")
    end

    it "replaces an existing gori entry instead of adding a second one" do
      existing = <<-YAML
        mcp_servers:
          gori:
            command: "/old/gori"
            args:
              - "mcp"
              - "--project=old"
            env:
              STALE: "1"
          keep:
            command: "keep"\n
        YAML
      text = Gori::MCP::Install.upsert_yaml_server(existing, "mcp_servers", "gori", body)
      text.scan("  gori:").size.should eq(1)
      text.should_not contain("/old/gori")
      text.should_not contain("--project=old")
      text.should_not contain("STALE")
      parsed = YAML.parse(text)
      parsed["mcp_servers"]["gori"]["args"].as_a.map(&.as_s).should eq(["mcp"])
      parsed["mcp_servers"]["keep"]["command"].as_s.should eq("keep")
    end

    it "keeps the block's own indentation" do
      # A four-space block gets a four-space entry: one entry at a different depth from its
      # siblings is a parse error, not a style difference.
      text = Gori::MCP::Install.upsert_yaml_server(
        "mcp_servers:\n    other:\n        command: \"o\"\n", "mcp_servers", "gori", body)
      text.should contain("\n    gori:\n        command: \"/bin/gori\"\n        args:\n")
      YAML.parse(text)["mcp_servers"]["other"]["command"].as_s.should eq("o")
    end

    it "expands an inline-empty mcp_servers into a block" do
      ["mcp_servers: {}", "mcp_servers: null", "mcp_servers: ~"].each do |line|
        text = Gori::MCP::Install.upsert_yaml_server("#{line}\nmodel: x\n",
          "mcp_servers", "gori", body)
        YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
        YAML.parse(text)["model"].as_s.should eq("x")
      end
    end

    it "refuses an mcp_servers written as a populated flow mapping" do
      # Splicing indented lines under it would leave the servers already inside unreachable.
      expect_raises(Exception, /written inline/) do
        Gori::MCP::Install.upsert_yaml_server(%(mcp_servers: {github: {command: "npx"}}\n),
          "mcp_servers", "gori", body)
      end
    end

    it "refuses an mcp_servers that holds a sequence" do
      expect_raises(Exception, /sequence/) do
        Gori::MCP::Install.upsert_yaml_server("mcp_servers:\n  - name: github\n",
          "mcp_servers", "gori", body)
      end
    end

    it "does not mistake a nested args sequence for one" do
      # `args:`' items are sequence lines too; only the block's OWN indent decides.
      text = Gori::MCP::Install.upsert_yaml_server(
        "mcp_servers:\n  other:\n    args:\n      - \"-y\"\n", "mcp_servers", "gori", body)
      YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
    end

    it "does not end the block at a column-0 comment between entries" do
      existing = "mcp_servers:\n  a:\n    command: \"a\"\n# a note\n  b:\n    command: \"b\"\n"
      text = Gori::MCP::Install.upsert_yaml_server(existing, "mcp_servers", "gori", body)
      text.should contain("# a note")
      parsed = YAML.parse(text)
      parsed["mcp_servers"]["a"]["command"].as_s.should eq("a")
      parsed["mcp_servers"]["b"]["command"].as_s.should eq("b")
      parsed["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
    end

    it "matches a quoted key and leaves a look-alike nested key alone" do
      existing = "mcp_servers:\n  \"gori\":\n    command: \"/old\"\n  other:\n    gori: \"no\"\n"
      text = Gori::MCP::Install.upsert_yaml_server(existing, "mcp_servers", "gori", body)
      text.should_not contain("/old")
      parsed = YAML.parse(text)
      parsed["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
      parsed["mcp_servers"]["other"]["gori"].as_s.should eq("no")
    end

    it "leaves an ordinary mcp_servers line exactly as the user wrote it" do
      # Re-emitting the key canonically looked free: it deletes a comment on that line and
      # unquotes a quoted key, and the readback guard cannot see either — the gori entry is
      # perfect while the line above it lost what the user wrote.
      text = Gori::MCP::Install.upsert_yaml_server(
        "mcp_servers:  # my servers, do not remove\n  a:\n    command: \"a\"\n",
        "mcp_servers", "gori", body)
      text.should contain("mcp_servers:  # my servers, do not remove")
      text = Gori::MCP::Install.upsert_yaml_server(
        "\"mcp_servers\":\n  a:\n    command: \"a\"\n", "mcp_servers", "gori", body)
      text.should contain("\"mcp_servers\":")
      YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
    end

    it "expands an inline-empty mcp_servers that carries a comment or inner spaces" do
      # `{}` is the case the expansion exists for, and a placeholder line is exactly where a
      # trailing comment lives — refusing that shape refuses the most common first install.
      {"mcp_servers: {} # none yet", "mcp_servers: {  }", "mcp_servers: ~  # unset"}.each do |line|
        text = Gori::MCP::Install.upsert_yaml_server("#{line}\nmodel: x\n",
          "mcp_servers", "gori", body)
        YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
        YAML.parse(text)["model"].as_s.should eq("x")
      end
      # The comment survives the value being dropped.
      Gori::MCP::Install.upsert_yaml_server("mcp_servers: {} # none yet\n",
        "mcp_servers", "gori", body).should contain("mcp_servers: # none yet")
    end

    it "appends above a trailing comment inside the block, not below it" do
      # `# add more servers below` is an invitation, not a caption for whatever lands under
      # it — and appending past it made it read as gori's own.
      text = Gori::MCP::Install.upsert_yaml_server(
        "mcp_servers:\n  a:\n    command: \"a\"\n\n  # add more servers below\n",
        "mcp_servers", "gori", body)
      text.index("  gori:").not_nil!.should be < text.index("# add more servers below").not_nil!
      YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
    end

    it "leaves a mostly-LF file on LF, one stray CRLF line and all" do
      # A whole-file `includes?("\r\n")` turned an installer that adds one entry into a
      # whole-file diff in somebody's dotfiles repo.
      text = Gori::MCP::Install.upsert_yaml_server(
        "model: x\r\nplugins: y\nmcp_servers:\n  a:\n    command: \"a\"\n",
        "mcp_servers", "gori", body)
      text.should contain("model: x\r\n") # the line that had one keeps it
      text.should contain("plugins: y\n")
      text.should_not contain("plugins: y\r")
      text.should contain("  gori:\n") # a line gori added follows the majority (LF)
      YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
    end

    it "keeps a CRLF file on CRLF" do
      text = Gori::MCP::Install.upsert_yaml_server("model: x\r\n", "mcp_servers", "gori", body)
      text.should_not match(/[^\r]\n/)
      YAML.parse(text)["mcp_servers"]["gori"]["command"].as_s.should eq("/bin/gori")
    end
  end

  describe ".yaml_string" do
    it "always quotes, and escapes what would re-parse" do
      Gori::MCP::Install.yaml_string("/bin/gori").should eq(%("/bin/gori"))
      Gori::MCP::Install.yaml_string(%(a"b\\c)).should eq(%("a\\"b\\\\c"))
      Gori::MCP::Install.yaml_string("a\nb\tc").should eq(%("a\\nb\\tc"))
      Gori::MCP::Install.yaml_string("a\u0001b").should eq(%("a\\x01b"))
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

    # The header scan used to be a plain `strip.starts_with?("[mcp_servers.")` over every line,
    # and a config file's own worked example is written in a `"""…"""` block. So this fixture's
    # THIRD line matched, and everything from it to the next real `[` — the rest of the string,
    # its closing delimiter, and `model` — was deleted, leaving the file unparseable and
    # `model = "gpt-5"` gone. gori reported "Successfully installed".
    it "does not read a table header out of a multi-line string" do
      existing = <<-TOML
      instructions = """
      Example config:
      [mcp_servers.gori]
      command = "gori"
      """

      model = "gpt-5"
      TOML
      spliced = Gori::MCP::Install.upsert_toml_table(existing, "mcp_servers.gori",
        "command = \"/new\"\nargs = [\"mcp\"]\n")
      spliced.should contain(%(model = "gpt-5"))
      spliced.should contain("Example config:")
      spliced.should contain(%(command = "gori"))          # the example inside the string, untouched
      spliced.should contain(%(command = "/new"))          # …and the real entry, appended after it
      spliced.scan("[mcp_servers.gori]").size.should eq(2) # the example's, and gori's own
      # The whole point: what comes back still parses, with one gori server in it.
      doc = Gori::MCP::Install::TomlDoc.parse(spliced)
      doc.dig("mcp_servers", "gori").not_nil!.string?("command").should eq("/new")
      doc.dig("mcp_servers", "gori").not_nil!.string_array?("args").should eq(["mcp"])
    end

    it "leaves a literal multi-line string's look-alike header alone too" do
      existing = <<-TOML
      note = '''
      [mcp_servers.gori]
      '''
      model = "x"
      TOML
      spliced = Gori::MCP::Install.upsert_toml_table(existing, "mcp_servers.gori", "command = \"/new\"\n")
      spliced.should contain(%(model = "x"))
      spliced.should contain("'''")
    end
  end

  describe ".install_toml" do
    it "refuses a file it cannot parse instead of splicing into it" do
      with_toml("model = \"gpt-5\n[features]\nx = true\n") do |path|
        before = File.read(path)
        ex = expect_raises(Exception, /isn't valid TOML/) do
          Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp"])
        end
        ex.message.not_nil!.should contain(path)
        File.read(path).should eq(before) # …and nothing was written
      end
    end

    # `[mcp_servers]` with an INLINE `gori` entry is valid TOML that a header scan cannot see,
    # so appending `[mcp_servers.gori]` beside it produced `Cannot declare ('mcp_servers',
    # 'gori') twice` — a file Codex refuses to load, and one a re-run does not repair (the
    # second run replaces its own table and leaves the inline key exactly where it was).
    it "replaces an inline entry rather than declaring the table twice" do
      with_toml(<<-TOML) do |path|
        model = "gpt-5"

        [mcp_servers]
        other = { command = "/other", args = [] }
        gori = { command = "/old/gori", args = ["mcp"] }
        TOML
        Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp", "--read-only"])
        text = File.read(path)
        text.should_not contain("/old/gori")
        text.should contain(%(other = { command = "/other", args = [] })) # the sibling stays
        text.should contain(%(model = "gpt-5"))
        doc = Gori::MCP::Install::TomlDoc.parse(text) # would RAISE on the duplicate declaration
        doc.dig("mcp_servers", "gori").not_nil!.string?("command").should eq("/opt/gori")
        doc.dig("mcp_servers", "other").not_nil!.string?("command").should eq("/other")
      end
    end

    it "replaces a DOTTED inline entry too" do
      with_toml(<<-TOML) do |path|
        [mcp_servers]
        gori.command = "/old/gori"
        gori.args = ["mcp"]
        keep = { command = "/keep" }
        TOML
        Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp"])
        text = File.read(path)
        text.should_not contain("/old/gori")
        text.should contain("/keep")
        Gori::MCP::Install::TomlDoc.parse(text)
          .dig("mcp_servers", "gori").not_nil!.string?("command").should eq("/opt/gori")
      end
    end

    it "installs into a file whose example block mentions the table, keeping the file valid" do
      with_toml(<<-TOML) do |path|
        instructions = """
        Example config:
        [mcp_servers.gori]
        command = "gori"
        """

        model = "gpt-5"
        TOML
        Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp"])
        text = File.read(path)
        text.should contain(%(model = "gpt-5"))
        doc = Gori::MCP::Install::TomlDoc.parse(text)
        doc.dig("mcp_servers", "gori").not_nil!.string?("command").should eq("/opt/gori")
        doc.root.string?("model").should eq("gpt-5")
        doc.root.string?("instructions").not_nil!.should contain("[mcp_servers.gori]")
      end
    end

    it "is idempotent, and keeps comments and unrelated tables" do
      with_toml(<<-TOML) do |path|
        model = "o3"
        # keep me

        [mcp_servers.other]
        command = "other"

        [features]
        js_repl = false
        TOML
        Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp"])
        first = File.read(path)
        Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp"])
        File.read(path).should eq(first)
        first.should contain("# keep me")
        first.should contain("[mcp_servers.other]")
        first.should contain("js_repl = false")
        first.scan("[mcp_servers.gori]").size.should eq(1)
      end
    end

    it "writes a fresh file when there is none" do
      with_toml(nil) do |path|
        Gori::MCP::Install.install_toml(path, "/opt/gori", ["mcp"])
        Gori::MCP::Install::TomlDoc.parse(File.read(path))
          .dig("mcp_servers", "gori").not_nil!.string_array?("args").should eq(["mcp"])
      end
    end
  end

  describe "TomlDoc" do
    it "rejects a table declared twice, an unterminated string and a stray line" do
      expect_raises(Gori::MCP::Install::TomlError, /twice/) do
        Gori::MCP::Install::TomlDoc.parse("[a]\nx = 1\n[a]\ny = 2\n")
      end
      expect_raises(Gori::MCP::Install::TomlError, /unterminated/) do
        Gori::MCP::Install::TomlDoc.parse("x = \"open\n")
      end
      expect_raises(Gori::MCP::Install::TomlError, /line break/) do
        Gori::MCP::Install::TomlDoc.parse(%(x = "s" y = 2\n))
      end
      expect_raises(Gori::MCP::Install::TomlError, /key was expected/) do
        Gori::MCP::Install::TomlDoc.parse("x = 1\n]\n")
      end
      # An inline table is not reopenable — the shape `[mcp_servers]` + `gori = {…}` +
      # `[mcp_servers.gori]` produces, and the reason install_toml clears the inline entry.
      expect_raises(Gori::MCP::Install::TomlError, /twice/) do
        Gori::MCP::Install::TomlDoc.parse("[t]\ng = { a = 1 }\n\n[t.g]\nb = 2\n")
      end
    end

    it "reads the shapes a config file is written in" do
      doc = Gori::MCP::Install::TomlDoc.parse(<<-TOML)
        title = "gpt \\u0041\\n"     # escapes decode
        raw = 'C:\\not\\an\\escape' # literal strings do not

        [mcp_servers.gori]
        command = "/opt/gori"
        args = [
          "mcp",     # comments and newlines inside an array
          "--read-only",
        ]

        [[jobs]]
        id = 1
        TOML
      doc.root.string?("title").should eq("gpt A\n")
      doc.root.string?("raw").should eq("C:\\not\\an\\escape")
      entry = doc.dig("mcp_servers", "gori").not_nil!
      entry.string?("command").should eq("/opt/gori")
      entry.string_array?("args").should eq(["mcp", "--read-only"])
    end

    it "answers nil rather than a partial array when an element is not a string" do
      doc = Gori::MCP::Install::TomlDoc.parse("[t]\nargs = [\"mcp\", 3]\n")
      doc.dig("t").not_nil!.string_array?("args").should be_nil
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

    it "writes a YAML mcp_servers.gori entry for hermes and updates in place" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-hermes-#{Random::Secure.hex(4)}")
        hermes_dir = File.join(home, ".hermes")
        Dir.mkdir_p(hermes_dir)
        config = File.join(hermes_dir, "config.yaml")
        File.write(config, <<-YAML)
          model:
            provider: anthropic

          # keep me
          mcp_servers:
            github:
              command: "npx"
              env:
                GITHUB_PERSONAL_ACCESS_TOKEN: "ghp_secret"\n
          YAML
        old_home = ENV["HOME"]?
        old_hermes = ENV["HERMES_HOME"]?
        ENV["HOME"] = home
        ENV.delete("HERMES_HOME")
        begin
          path = Gori::MCP::Install.install("hermes", exe_path: "/opt/gori/bin/gori",
            project: "demo")
          path.should eq(config)
          # Second install updates rather than duplicating.
          Gori::MCP::Install.install("hermes", exe_path: "/opt/gori2", read_only: true)
          text = File.read(config)
          text.should contain("# keep me")
          text.scan("  gori:").size.should eq(1)
          text.should_not contain("--project=demo")
          parsed = YAML.parse(text)
          parsed["model"]["provider"].as_s.should eq("anthropic")
          parsed["mcp_servers"]["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"].as_s
            .should eq("ghp_secret")
          parsed["mcp_servers"]["gori"]["command"].as_s.should eq("/opt/gori2")
          parsed["mcp_servers"]["gori"]["args"].as_a.map(&.as_s).should eq(["mcp", "--read-only"])
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
        end
      end
    end

    it "creates the hermes config under HERMES_HOME when there is none yet" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-hermes-env-#{Random::Secure.hex(4)}")
        profile = File.join(home, "profiles", "engagement")
        Dir.mkdir_p(home)
        old_home = ENV["HOME"]?
        old_hermes = ENV["HERMES_HOME"]?
        old_appdata = ENV["LOCALAPPDATA"]?
        ENV["HOME"] = home
        ENV["HERMES_HOME"] = profile
        # A Windows host reads LOCALAPPDATA on the default path; HERMES_HOME wins over it,
        # and the var is kept inside the temp tree so a regression cannot escape the sandbox.
        ENV["LOCALAPPDATA"] = File.join(home, "AppData", "Local")
        begin
          path = Gori::MCP::Install.install("hermes", exe_path: "/opt/gori")
          path.should eq(File.join(profile, "config.yaml"))
          YAML.parse(File.read(path))["mcp_servers"]["gori"]["command"].as_s.should eq("/opt/gori")
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
          old_appdata ? (ENV["LOCALAPPDATA"] = old_appdata) : ENV.delete("LOCALAPPDATA")
        end
      end
    end

    it "refuses to clobber a hermes config that is not valid YAML" do
      # The file holds the user's providers, plugins and every other server's keys — a
      # hand-edit error must not be answered by replacing it with a two-line file.
      Dir.tempdir.try do |base|
        home = File.join(base, "home-hermes-bad-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(File.join(home, ".hermes"))
        bad = File.join(home, ".hermes", "config.yaml")
        File.write(bad, "model: [unterminated\n")
        old_home = ENV["HOME"]?
        old_hermes = ENV["HERMES_HOME"]?
        ENV["HOME"] = home
        ENV.delete("HERMES_HOME")
        begin
          expect_raises(Exception, /Refusing to overwrite/) do
            Gori::MCP::Install.install("hermes", exe_path: "/opt/gori")
          end
          File.read(bad).should eq("model: [unterminated\n")
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
        end
      end
    end

    it "refuses a hermes config whose document is not a mapping" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-hermes-seq-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(File.join(home, ".hermes"))
        bad = File.join(home, ".hermes", "config.yaml")
        File.write(bad, "- a\n- b\n")
        old_home = ENV["HOME"]?
        old_hermes = ENV["HERMES_HOME"]?
        ENV["HOME"] = home
        ENV.delete("HERMES_HOME")
        begin
          expect_raises(Exception, /isn't a YAML mapping/) do
            Gori::MCP::Install.install("hermes", exe_path: "/opt/gori")
          end
          File.read(bad).should eq("- a\n- b\n")
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
        end
      end
    end

    it "refuses a hermes config where the spliced entry would not be the one read back" do
      # Two documents, and `mcp_servers` lives in the second: the splice edits the first one
      # it finds and the client parses a different one. Text editing can be wrong in ways
      # only a re-read catches, which is why install_yaml re-parses before it writes — and
      # why the file on disk is still the one the user had.
      Dir.tempdir.try do |base|
        home = File.join(base, "home-hermes-docs-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(File.join(home, ".hermes"))
        config = File.join(home, ".hermes", "config.yaml")
        original = "model: x\n---\nmcp_servers:\n  other:\n    command: \"o\"\n"
        File.write(config, original)
        old_home = ENV["HOME"]?
        old_hermes = ENV["HERMES_HOME"]?
        ENV["HOME"] = home
        ENV.delete("HERMES_HOME")
        begin
          expect_raises(Exception, /did not read back as written/) do
            Gori::MCP::Install.install("hermes", exe_path: "/opt/gori")
          end
          File.read(config).should eq(original)
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
        end
      end
    end

    it "keeps the hermes config's permissions and leaves no temp file behind" do
      Dir.tempdir.try do |base|
        home = File.join(base, "home-hermes-perm-#{Random::Secure.hex(4)}")
        dir = File.join(home, ".hermes")
        Dir.mkdir_p(dir)
        config = File.join(dir, "config.yaml")
        File.write(config, "model:\n  provider: anthropic\n")
        File.chmod(config, 0o600)
        old_home = ENV["HOME"]?
        old_hermes = ENV["HERMES_HOME"]?
        ENV["HOME"] = home
        ENV.delete("HERMES_HOME")
        begin
          Gori::MCP::Install.install("hermes", exe_path: "/opt/gori")
          File.info(config).permissions.should eq(File::Permissions.new(0o600))
          Dir.children(dir).sort.should eq(["config.yaml"])
        ensure
          old_home ? (ENV["HOME"] = old_home) : ENV.delete("HOME")
          old_hermes ? (ENV["HERMES_HOME"] = old_hermes) : ENV.delete("HERMES_HOME")
        end
      end
    end
  end
end
