require "../spec_helper"
require "file_utils"

# `Settings.agent_*` — the hosted coding-agent tab's spawn config (#1093). Same shape as
# `settings/companion.cr`: tolerant parse, normalize-on-the-way-in AND out, omit-at-default
# serialize. `Agent::Config.from_settings` is the consumer; this file pins the Settings layer
# alone.
private def with_agent_home(&)
  dir = File.tempname("gori-settings-agent")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev = {Gori::Settings.agent_command, Gori::Settings.agent_args, Gori::Settings.agent_model,
          Gori::Settings.agent_mcp_read_only?, Gori::Settings.agent_system_prompt_append,
          Gori::Settings.agent_permission_policy, Gori::Settings.agent_history_keep}
  begin
    ENV["GORI_HOME"] = dir
    yield dir
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.agent_command, Gori::Settings.agent_args, Gori::Settings.agent_model = prev[0], prev[1], prev[2]
    Gori::Settings.agent_mcp_read_only, Gori::Settings.agent_system_prompt_append = prev[3], prev[4]
    Gori::Settings.agent_permission_policy, Gori::Settings.agent_history_keep = prev[5], prev[6]
    FileUtils.rm_rf(dir)
  end
end

describe "Settings.agent_*" do
  it "is tolerant of a missing section — a fresh install keeps every default" do
    with_agent_home do
      File.write(Gori::Settings.path, %({}))
      Gori::Settings.load
      Gori::Settings.agent_command.should eq(Gori::Settings::DEFAULT_AGENT_COMMAND)
      Gori::Settings.agent_args.should eq(Gori::Settings::DEFAULT_AGENT_ARGS)
      Gori::Settings.agent_model.should eq(Gori::Settings::DEFAULT_AGENT_MODEL)
      Gori::Settings.agent_mcp_read_only?.should eq(Gori::Settings::DEFAULT_AGENT_MCP_READ_ONLY)
      Gori::Settings.agent_permission_policy.should eq(Gori::Settings::DEFAULT_AGENT_PERMISSION_POLICY)
      Gori::Settings.agent_history_keep.should eq(Gori::Settings::DEFAULT_AGENT_HISTORY_KEEP)
    end
  end

  it "is tolerant of a non-object section — keeps whatever was already loaded" do
    with_agent_home do
      Gori::Settings.agent_command = "custom"
      File.write(Gori::Settings.path, %({"agent": "nonsense"}))
      Gori::Settings.load
      Gori::Settings.agent_command.should eq("custom") # untouched, not reset to the default
    end
  end

  it "survives a stored `false` on reload — the load_bool_h trap" do
    with_agent_home do
      # `agent_command` is pinned off its default too, so the section keeps serializing once
      # mcp_read_only goes back to false — an all-default section OMITS itself (see the next
      # example), which would make this pass for the wrong reason: never having read a stored
      # `false` back at all.
      Gori::Settings.agent_command = "my-claude"
      Gori::Settings.agent_mcp_read_only = true
      Gori::Settings.save.should be_true
      Gori::Settings.agent_mcp_read_only = false # flip it in memory only
      Gori::Settings.load                        # reload from the file, which still says true
      Gori::Settings.agent_mcp_read_only?.should be_true

      # mcp_read_only defaults false; if `parse_agent` used `|| agent_mcp_read_only?` a
      # freshly-loaded `false` from disk would be indistinguishable from "absent" and the
      # `||` would silently resurrect whatever this process already had in memory (true).
      Gori::Settings.agent_mcp_read_only = false
      Gori::Settings.save.should be_true
      Gori::Settings.agent_mcp_read_only = true
      Gori::Settings.load
      Gori::Settings.agent_mcp_read_only?.should be_false # the stored false survives
    end
  end

  it "normalizes an out-of-set permission policy to the default, both ways" do
    Gori::Settings.normalize_agent_permission_policy("ask").should eq("ask")
    Gori::Settings.normalize_agent_permission_policy("deny").should eq("deny")
    # Deliberately no "allow" — see DEFAULT_AGENT_PERMISSION_POLICY's comment.
    Gori::Settings.normalize_agent_permission_policy("allow")
      .should eq(Gori::Settings::DEFAULT_AGENT_PERMISSION_POLICY)
    Gori::Settings.normalize_agent_permission_policy("bogus")
      .should eq(Gori::Settings::DEFAULT_AGENT_PERMISSION_POLICY)

    with_agent_home do
      File.write(Gori::Settings.path, %({"agent":{"permission_policy":"allow"}}))
      Gori::Settings.load
      Gori::Settings.agent_permission_policy.should eq(Gori::Settings::DEFAULT_AGENT_PERMISSION_POLICY)
    end
  end

  it "clamps history_keep to 1..1000, both on the way in and directly" do
    Gori::Settings.normalize_agent_history_keep(0).should eq(1)
    Gori::Settings.normalize_agent_history_keep(-50).should eq(1)
    Gori::Settings.normalize_agent_history_keep(5000).should eq(1000)
    Gori::Settings.normalize_agent_history_keep(50).should eq(50)

    with_agent_home do
      File.write(Gori::Settings.path, %({"agent":{"history_keep":0}}))
      Gori::Settings.load
      Gori::Settings.agent_history_keep.should eq(1)

      File.write(Gori::Settings.path, %({"agent":{"history_keep":99999}}))
      Gori::Settings.load
      Gori::Settings.agent_history_keep.should eq(1000)
    end
  end

  it "omits the section entirely at factory defaults, and round-trips a non-default value" do
    with_agent_home do
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should_not contain(%("agent"))

      Gori::Settings.agent_command = "my-claude"
      Gori::Settings.agent_args = "--verbose"
      Gori::Settings.agent_model = "opus"
      Gori::Settings.agent_mcp_read_only = true
      Gori::Settings.agent_system_prompt_append = "always run tests first"
      Gori::Settings.agent_permission_policy = "deny"
      Gori::Settings.agent_history_keep = 200
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should contain(%("agent"))

      Gori::Settings.agent_command = Gori::Settings::DEFAULT_AGENT_COMMAND
      Gori::Settings.agent_args = Gori::Settings::DEFAULT_AGENT_ARGS
      Gori::Settings.agent_model = Gori::Settings::DEFAULT_AGENT_MODEL
      Gori::Settings.agent_mcp_read_only = false
      Gori::Settings.agent_system_prompt_append = ""
      Gori::Settings.agent_permission_policy = "ask"
      Gori::Settings.agent_history_keep = 1
      Gori::Settings.load
      Gori::Settings.agent_command.should eq("my-claude")
      Gori::Settings.agent_args.should eq("--verbose")
      Gori::Settings.agent_model.should eq("opus")
      Gori::Settings.agent_mcp_read_only?.should be_true
      Gori::Settings.agent_system_prompt_append.should eq("always run tests first")
      Gori::Settings.agent_permission_policy.should eq("deny")
      Gori::Settings.agent_history_keep.should eq(200)

      # Back to every default → the section disappears again.
      Gori::Settings.agent_command = Gori::Settings::DEFAULT_AGENT_COMMAND
      Gori::Settings.agent_args = Gori::Settings::DEFAULT_AGENT_ARGS
      Gori::Settings.agent_model = Gori::Settings::DEFAULT_AGENT_MODEL
      Gori::Settings.agent_mcp_read_only = Gori::Settings::DEFAULT_AGENT_MCP_READ_ONLY
      Gori::Settings.agent_system_prompt_append = Gori::Settings::DEFAULT_AGENT_SYSTEM_PROMPT_APPEND
      Gori::Settings.agent_permission_policy = Gori::Settings::DEFAULT_AGENT_PERMISSION_POLICY
      Gori::Settings.agent_history_keep = Gori::Settings::DEFAULT_AGENT_HISTORY_KEEP
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("agent"))
    end
  end

  it "resets every field to its factory default" do
    with_agent_home do
      Gori::Settings.agent_command = "custom"
      Gori::Settings.agent_args = "--flag"
      Gori::Settings.agent_model = "sonnet"
      Gori::Settings.agent_mcp_read_only = true
      Gori::Settings.agent_system_prompt_append = "notes"
      Gori::Settings.agent_permission_policy = "deny"
      Gori::Settings.agent_history_keep = 5
      Gori::Settings.reset_to_factory
      Gori::Settings.agent_command.should eq(Gori::Settings::DEFAULT_AGENT_COMMAND)
      Gori::Settings.agent_args.should eq(Gori::Settings::DEFAULT_AGENT_ARGS)
      Gori::Settings.agent_model.should eq(Gori::Settings::DEFAULT_AGENT_MODEL)
      Gori::Settings.agent_mcp_read_only?.should eq(Gori::Settings::DEFAULT_AGENT_MCP_READ_ONLY)
      Gori::Settings.agent_system_prompt_append.should eq(Gori::Settings::DEFAULT_AGENT_SYSTEM_PROMPT_APPEND)
      Gori::Settings.agent_permission_policy.should eq(Gori::Settings::DEFAULT_AGENT_PERMISSION_POLICY)
      Gori::Settings.agent_history_keep.should eq(Gori::Settings::DEFAULT_AGENT_HISTORY_KEEP)
    end
  end
end

describe "Gori::Agent::Config.from_settings" do
  it "reads the seven properties, splitting agent_args into argv" do
    with_agent_home do
      Gori::Settings.agent_command = "my-claude"
      Gori::Settings.agent_args = %(--foo "bar baz")
      Gori::Settings.agent_model = "opus"
      Gori::Settings.agent_mcp_read_only = true
      Gori::Settings.agent_system_prompt_append = "house rules"
      Gori::Settings.agent_permission_policy = "deny"

      cfg = Gori::Agent::Config.from_settings("/tmp/db.sqlite3", cwd: "/repo")
      cfg.db_path.should eq("/tmp/db.sqlite3")
      cfg.command.should eq("my-claude")
      cfg.args.should eq(["--foo", "bar baz"])
      cfg.model.should eq("opus")
      cfg.mcp_read_only.should be_true
      cfg.system_prompt_append.should eq("house rules")
      cfg.permission_policy.should eq("deny")
      cfg.cwd.should eq("/repo")
    end
  end

  it "reads blank model/system_prompt_append as nil, not empty strings" do
    with_agent_home do
      Gori::Settings.agent_model = ""
      Gori::Settings.agent_system_prompt_append = ""
      cfg = Gori::Agent::Config.from_settings("/tmp/db.sqlite3")
      cfg.model.should be_nil
      cfg.system_prompt_append.should be_nil
      cfg.cwd.should be_nil
    end
  end

  it "tolerates an unparseable args string — no extra argv rather than a crash" do
    with_agent_home do
      Gori::Settings.agent_args = "'unterminated"
      cfg = Gori::Agent::Config.from_settings("/tmp/db.sqlite3")
      cfg.args.should be_empty
    end
  end
end
