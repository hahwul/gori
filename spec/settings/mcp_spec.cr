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
  prev_cfg = ENV["GORI_CONFIG"]?
  prev_channels = Gori::Settings.mcp_channels?
  prev_denied = Gori::Settings.mcp_denied_permissions
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.mcp_channels = Gori::Settings::DEFAULT_MCP_CHANNELS
    Gori::Settings.mcp_denied_permissions = Set(String).new
    yield dir
  ensure
    Gori::Settings.path_override = nil
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    Gori::Settings.mcp_channels = prev_channels
    Gori::Settings.mcp_denied_permissions = prev_denied
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

  # Preferences › AI › MCP permissions. Every group is allowed by default and the file records
  # only the denials, in a section of its own, so a default install writes nothing.
  describe "permissions" do
    it "allows every group by default and writes nothing for it" do
      with_mcp_home do
        Gori::Settings::MCP_PERMISSIONS.all? { |p| Gori::Settings.mcp_permitted?(p.key) }.should be_true
        Gori::Settings.document_keys.should_not contain("mcp_permissions")
      end
    end

    # Its own top-level section: the save merge reconciles whole sections, so sharing `mcp`
    # with `channels` let a window that toggled Channel delivery write back stale denials.
    it "writes only the denied groups, in their own section apart from channels" do
      with_mcp_home do
        Gori::Settings.set_mcp_permitted("send", false)
        Gori::Settings.document_keys.should contain("mcp_permissions")
        Gori::Settings.document_keys.should_not contain("mcp")
        perms = JSON.parse(Gori::Settings.export_document(["mcp_permissions"]))["mcp_permissions"].as_h
        perms.should eq({"send" => JSON::Any.new(false)})
      end
    end

    it "keeps another window's denials when this one saves only channels" do
      with_mcp_home do |dir|
        Gori::Settings.save.should be_true # base: nothing denied
        path = File.join(dir, "settings.json")
        File.write(path, %({"mcp_permissions":{"send":false}}))
        Gori::Settings.mcp_channels = true
        Gori::Settings.save.should be_true
        on_disk = JSON.parse(File.read(path))
        on_disk["mcp_permissions"]["send"].as_bool.should be_false
        on_disk["mcp"]["channels"].as_bool.should be_true
      end
    end

    it "round-trips through save/load" do
      with_mcp_home do
        Gori::Settings.set_mcp_permitted("intercept", false)
        Gori::Settings.save.should be_true
        Gori::Settings.mcp_denied_permissions = Set(String).new
        Gori::Settings.load
        Gori::Settings.mcp_permitted?("intercept").should be_false
        Gori::Settings.mcp_permitted?("send").should be_true
      end
    end

    it "treats the section as the whole set: a key it no longer names is allowed again" do
      with_mcp_home do
        Gori::Settings.set_mcp_permitted("send", false)
        Gori::Settings.import_document(%({"mcp_permissions":{"write":false,"send":true}}))
        Gori::Settings.mcp_permitted?("send").should be_true
        Gori::Settings.mcp_permitted?("write").should be_false
      end
    end

    it "keeps the current set for an absent or non-object section" do
      with_mcp_home do
        Gori::Settings.set_mcp_permitted("send", false)
        Gori::Settings.import_document(%({"mcp":{"channels":true}}))
        Gori::Settings.mcp_permitted?("send").should be_false
        Gori::Settings.import_document(%({"mcp_permissions":"none"}))
        Gori::Settings.mcp_permitted?("send").should be_false
      end
    end

    # A newer gori's group: it grants nothing here, and a save from here must not drop it.
    it "keeps an unknown denied key through a save" do
      with_mcp_home do
        Gori::Settings.import_document(%({"mcp_permissions":{"future":false}}))
        Gori::Settings.mcp_permitted?("future").should be_false
        JSON.parse(Gori::Settings.export_document(["mcp_permissions"]))["mcp_permissions"]["future"].as_bool.should be_false
      end
    end

    it "is cleared by the factory reset" do
      with_mcp_home do
        Gori::Settings.set_mcp_permitted("projects", false)
        Gori::Settings.save.should be_true
        Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)
        Gori::Settings.mcp_denied_permissions.empty?.should be_true
        Gori::Settings.document_keys.should_not contain("mcp_permissions")
      end
    end

    describe "mcp_enforced_denials" do
      it "is the loaded set when the file was read in full" do
        with_mcp_home do |dir|
          File.write(File.join(dir, "settings.json"), %({"mcp_permissions":{"send":false}}))
          Gori::Settings.load
          Gori::Settings.mcp_enforced_denials.should eq({Set{"send"}, nil})
        end
      end

      # A security switch must not fail open over a file nobody finished reading.
      it "denies every group when the settings file could not be read" do
        with_mcp_home do |dir|
          File.write(File.join(dir, "settings.json"), %({"mcp_permissions": {"send": false))
          Gori::Settings.load
          denied, warning = Gori::Settings.mcp_enforced_denials
          denied.should eq(Gori::Settings::MCP_PERMISSION_KEYS.to_set)
          warning.not_nil!.should contain("every MCP permission group is off")
        end
      end
    end
  end
end
