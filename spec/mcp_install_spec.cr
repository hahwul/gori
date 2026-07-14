require "./spec_helper"

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

    it "raises on unknown targets" do
      expect_raises(ArgumentError, /Unknown install target/) do
        Gori::MCP::Install.config_path("nope")
      end
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
