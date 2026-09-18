require "../spec_helper"
require "../../src/gori/agent/claude"
require "../../src/gori/agent/mcp_config"

# The launch contract for a Claude Code spawn (#1093), and the project binding it is handed.
#
# `argv` is a pure function of a config plus three ids, which is the whole reason it is split
# out of the session: flag order, what a nil model omits and where an operator's own args land
# are all assertable here without a `claude` binary anywhere on the machine. `McpConfig.write`
# is the one impure half, and what it must get right is a mode and a location — a config file
# naming the project database is a disclosure wherever it is world-readable.

private def base_config(db_path = "/tmp/gori-spec-agent.db") : Gori::Agent::Config
  Gori::Agent::Config.new(db_path: db_path)
end

private def flag_value(argv : Array(String), flag : String) : String?
  i = argv.index(flag)
  i ? argv[i + 1]? : nil
end

describe Gori::Agent::ClaudeBackend do
  backend = Gori::Agent::ClaudeBackend.new

  it "names the backend the way agent_sessions.backend spells it" do
    backend.name.should eq("claude")
  end

  describe "#argv" do
    it "builds the base shape with argv[0] as the command" do
      argv = backend.argv(base_config, "uuid-1", nil, "/p/mcp.json")

      argv.first.should eq("claude")
      # The stream-json conversation, both ways.
      flag_value(argv, "--input-format").should eq("stream-json")
      flag_value(argv, "--output-format").should eq("stream-json")
      argv.should contain("-p")
      # Without --verbose the stream carries only the result, and there is no transcript to
      # build; without --include-partial-messages the pane blinks instead of streaming.
      argv.should contain("--verbose")
      argv.should contain("--include-partial-messages")
      # The operator-in-the-loop flag. A proxy that runs an agent against live targets while
      # the child decides its own permissions is not a thing to ship.
      flag_value(argv, "--permission-prompt-tool").should eq("stdio")
      flag_value(argv, "--session-id").should eq("uuid-1")
      flag_value(argv, "--mcp-config").should eq("/p/mcp.json")

      # Nothing that was not asked for.
      argv.should_not contain("--resume")
      argv.should_not contain("--model")
      # Each flag once. (`stream-json` itself appears twice — it is the VALUE of two flags —
      # so this counts flags, not tokens.)
      flags = argv.select(&.starts_with?("--"))
      flags.should eq(flags.uniq)
    end

    it "honours a command that is an absolute path" do
      config = Gori::Agent::Config.new(db_path: "/tmp/x.db", command: "/opt/bin/claude")
      backend.argv(config, "u", nil, "/p/mcp.json").first.should eq("/opt/bin/claude")
    end

    it "resumes by naming the PREVIOUS uuid beside a fresh session id" do
      # Claude Code refuses a --session-id it has already issued, so a continued conversation
      # is a new uuid AND a resume of the old one — never one or the other.
      argv = backend.argv(base_config, "uuid-2", "uuid-1", "/p/mcp.json")
      flag_value(argv, "--session-id").should eq("uuid-2")
      flag_value(argv, "--resume").should eq("uuid-1")
    end

    it "passes a model only when one is set and non-blank" do
      with_model = Gori::Agent::Config.new(db_path: "/tmp/x.db", model: "opus")
      flag_value(backend.argv(with_model, "u", nil, "/p/m.json"), "--model").should eq("opus")

      # A settings field the operator cleared holds "", and `--model ""` is not "no model" —
      # it is a model named the empty string, which a CLI either refuses or resolves to
      # something surprising.
      ["", "   ", nil].each do |blank|
        blanked = Gori::Agent::Config.new(db_path: "/tmp/x.db", model: blank)
        backend.argv(blanked, "u", nil, "/p/m.json").should_not contain("--model")
      end
    end

    it "always sends the orientation preamble, and appends the operator's text to it" do
      plain = flag_value(backend.argv(base_config, "u", nil, "/p/m.json"),
        "--append-system-prompt").not_nil!
      plain.should eq(Gori::Agent::ClaudeBackend::PREAMBLE)
      plain.should contain("gori")
      plain.should contain("get_current_context")

      config = Gori::Agent::Config.new(db_path: "/tmp/x.db",
        system_prompt_append: "Prefer read-only tools.")
      combined = flag_value(backend.argv(config, "u", nil, "/p/m.json"),
        "--append-system-prompt").not_nil!
      # PREPENDED, not replaced: an operator adding a house style must not be able to silently
      # remove the orientation.
      combined.should start_with(Gori::Agent::ClaudeBackend::PREAMBLE)
      combined.should end_with("Prefer read-only tools.")
      combined.should contain("\n\n")
    end

    it "sends the preamble alone for a blank or whitespace-only append" do
      ["", "   ", "\n\t "].each do |blank|
        config = Gori::Agent::Config.new(db_path: "/tmp/x.db", system_prompt_append: blank)
        flag_value(backend.argv(config, "u", nil, "/p/m.json"), "--append-system-prompt")
          .should eq(Gori::Agent::ClaudeBackend::PREAMBLE)
      end
    end

    it "appends the operator's extra args LAST, after everything it builds" do
      config = Gori::Agent::Config.new(db_path: "/tmp/x.db", model: "opus",
        args: ["--model", "haiku", "--allowedTools", "Bash"])
      argv = backend.argv(config, "u", nil, "/p/m.json")

      # Last wins for the CLI parsers this feeds, which is the point of appending rather than
      # prepending: an operator's flag beats a default of the same name.
      argv.last(4).should eq(["--model", "haiku", "--allowedTools", "Bash"])
      argv.index("--mcp-config").not_nil!.should be < argv.index("--allowedTools").not_nil!
      # The built `--model opus` comes first; the operator's `--model haiku` is the later one.
      argv.index("--model").not_nil!.should be < argv.rindex("--model").not_nil!
      argv.index("--append-system-prompt").not_nil!.should be < argv.rindex("--model").not_nil!
    end

    it "is pure — the same inputs build the same argv, and nothing is shared between calls" do
      config = base_config
      first = backend.argv(config, "u", nil, "/p/m.json")
      first << "mutated by the caller"
      backend.argv(config, "u", nil, "/p/m.json").should_not contain("mutated by the caller")
    end
  end
end

describe Gori::Agent::Config do
  describe ".parse_args" do
    it "splits the settings-string form the way ProcessHook.parse_argv does" do
      [
        %(--allowedTools Bash),
        %(--model "claude sonnet" --verbose),
        %(--append 'a b' c),
        %(--path "C:\\tools\\dev.pem"),
      ].each do |spec|
        Gori::Agent::Config.parse_args(spec)
          .should eq(Gori::ProcessHook.parse_argv(spec).as(Array(String)))
      end
      Gori::Agent::Config.parse_args(%(--model "claude sonnet" --verbose))
        .should eq(["--model", "claude sonnet", "--verbose"])
    end

    it "is NOT a shell — a metacharacter is argv data, never an operator" do
      Gori::Agent::Config.parse_args(%(--x $HOME; rm -rf /))
        .should eq(["--x", "$HOME;", "rm", "-rf", "/"])
    end

    it "answers an empty argv for a spec that cannot be tokenized" do
      # `parse_argv` returns the PROBLEM as a String, and every write surface validates with it
      # before persisting — so by spawn time the useful answer is "no extra args", not a crash
      # in the middle of starting an agent.
      Gori::ProcessHook.parse_argv(%(--x "unterminated)).should be_a(String)
      Gori::Agent::Config.parse_args(%(--x "unterminated)).should be_empty
      # An empty spec takes the same branch ("no command") and lands on the same right answer.
      Gori::Agent::Config.parse_args("").should be_empty
      Gori::Agent::Config.parse_args("   ").should be_empty
    end
  end

  it "defaults to a claude spawn with nothing else decided" do
    config = base_config("/tmp/proj.db")
    config.db_path.should eq("/tmp/proj.db")
    config.command.should eq("claude")
    config.args.should be_empty
    config.model.should be_nil
    config.mcp_read_only.should be_false
    config.system_prompt_append.should be_nil
    config.permission_policy.should eq("ask")
    config.cwd.should be_nil
  end
end

describe Gori::Agent::McpConfig do
  it "writes a gori server entry naming the project db, at 0600 under a 0700 <db>.agent dir" do
    dir = File.tempname("gori-agent-mcpconfig")
    Dir.mkdir_p(dir)
    begin
      db_path = File.join(dir, "project.db")
      File.write(db_path, "") # canonical_file resolves an existing path through realpath

      path = Gori::Agent::McpConfig.write(db_path, false)

      # Beside the database, keyed on its canonical spelling — the `.agents`/`.windows`
      # convention AgentPresence established.
      File.basename(path).should eq("mcp.json")
      File.dirname(path).should eq(Gori::Agent::McpConfig.dir_for(db_path))
      File.dirname(path).should end_with(".agent")
      File.dirname(path).should start_with(Gori::Paths.canonical_file(db_path))
      # NOT in /tmp: the directory ENTRY of a world-readable temp dir discloses the project
      # database path to every other user on the host, which a 0600 file does not fix.
      File.dirname(File.dirname(path)).should eq(File.realpath(dir))

      File.info(path).permissions.should eq(File::Permissions.new(0o600))
      File.info(File.dirname(path)).permissions.should eq(File::Permissions.new(0o700))

      json = JSON.parse(File.read(path))
      server = json["mcpServers"]["gori"]
      server["command"].as_s.should eq(Gori::MCP::Install.executable_path)
      args = server["args"].as_a.map(&.as_s)
      args.first.should eq("mcp")
      args.should contain("--db=#{File.expand_path(db_path, home: true)}")
      args.should_not contain("--read-only")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "adds --read-only only when asked, and rewrites its own file in place" do
    dir = File.tempname("gori-agent-mcpconfig-ro")
    Dir.mkdir_p(dir)
    begin
      db_path = File.join(dir, "project.db")
      File.write(db_path, "")

      first = Gori::Agent::McpConfig.write(db_path, false)
      second = Gori::Agent::McpConfig.write(db_path, true)
      # Idempotent path: a resume overwrites its own file rather than accumulating.
      second.should eq(first)
      Dir.children(File.dirname(first)).should eq(["mcp.json"])

      args = JSON.parse(File.read(second))["mcpServers"]["gori"]["args"].as_a.map(&.as_s)
      args.should contain("--read-only")
      File.info(second).permissions.should eq(File::Permissions.new(0o600))
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "narrows a config file it finds at a wider mode" do
    # `DurableFile` preserves an existing destination's mode by default. This file names the
    # project database, so the mode is dictated rather than inherited.
    dir = File.tempname("gori-agent-mcpconfig-mode")
    Dir.mkdir_p(dir)
    begin
      db_path = File.join(dir, "project.db")
      File.write(db_path, "")
      path = Gori::Agent::McpConfig.write(db_path, false)
      File.chmod(path, 0o644)

      Gori::Agent::McpConfig.write(db_path, false)
      File.info(path).permissions.should eq(File::Permissions.new(0o600))
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "creates the directory for a database that does not exist yet" do
    # `gori mcp` creates the db on first serve, and a spawn may be configured before then.
    dir = File.tempname("gori-agent-mcpconfig-new")
    Dir.mkdir_p(dir)
    begin
      db_path = File.join(dir, "not-yet.db")
      path = Gori::Agent::McpConfig.write(db_path, false)
      File.file?(path).should be_true
      File.info(File.dirname(path)).permissions.should eq(File::Permissions.new(0o700))
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
