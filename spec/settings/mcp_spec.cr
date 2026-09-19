require "../spec_helper"
require "file_utils"

# `Settings.mcp_channels` — whether `gori mcp` declares the `claude/channel` capability and
# pushes "Tell the agent…" messages straight into an attached Claude Code session, on top of
# the inbox-socket and operator_messages poll layers that always run. See
# src/gori/settings/mcp.cr for why this defaults OFF.
private def with_mcp_home(&)
  dir = File.tempname("gori-mcp-settings")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev_channels = Gori::Settings.mcp_channels?
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.mcp_channels = Gori::Settings::DEFAULT_MCP_CHANNELS
    yield dir
  ensure
    Gori::Settings.path_override = nil
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.mcp_channels = prev_channels
    FileUtils.rm_rf(dir)
  end
end

describe "Settings mcp section" do
  describe "parse_mcp" do
    it "is tolerant of an absent section — keeps the current value" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.import_document(%({"theme":"goriday"}))
        Gori::Settings.mcp_channels?.should be_true
      end
    end

    it "is tolerant of a non-object section — keeps the current value" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.import_document(%({"mcp":"nope"}))
        Gori::Settings.mcp_channels?.should be_true
      end
    end

    it "is tolerant of a non-bool channels value — keeps the current value" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.import_document(%({"mcp":{"channels":"yes"}}))
        Gori::Settings.mcp_channels?.should be_true
      end
    end

    it "reads channels: true" do
      with_mcp_home do
        Gori::Settings.import_document(%({"mcp":{"channels":true}}))
        Gori::Settings.mcp_channels?.should be_true
      end
    end

    # load_bool_h, not a plain `||` — a stored `false` must survive, not resurrect the prior
    # in-memory value (which a naive `|| current` would do, since false is falsy).
    it "a stored false survives a reload, even from a prior true" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.save.should be_true
        Gori::Settings.import_document(%({"mcp":{"channels":false}}))
        Gori::Settings.mcp_channels?.should be_false
        Gori::Settings.load
        Gori::Settings.mcp_channels?.should be_false
      end
    end
  end

  describe "serialize_mcp" do
    it "omits the mcp section entirely at the factory default" do
      with_mcp_home do
        Gori::Settings.document_keys.should_not contain("mcp")
      end
    end

    it "writes the section once channels is non-default" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.document_keys.should contain("mcp")
        JSON.parse(Gori::Settings.export_document(["mcp"])).as_h["mcp"].as_h["channels"].as_bool.should be_true
      end
    end

    it "round-trips through save/load" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.save.should be_true
        Gori::Settings.mcp_channels = Gori::Settings::DEFAULT_MCP_CHANNELS
        Gori::Settings.load
        Gori::Settings.mcp_channels?.should be_true
      end
    end
  end

  describe "reset_mcp" do
    it "restores the factory default and drops the key from the file" do
      with_mcp_home do
        Gori::Settings.mcp_channels = true
        Gori::Settings.save.should be_true
        Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)
        Gori::Settings.mcp_channels?.should eq(Gori::Settings::DEFAULT_MCP_CHANNELS)
        Gori::Settings.document_keys.should_not contain("mcp")
      end
    end
  end
end
