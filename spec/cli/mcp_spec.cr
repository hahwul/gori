require "../spec_helper"

# `gori mcp`'s own words about its catalogue: the `--tools` help and the start-up line (#1137).
# Both used to carry numbers — "~43k tokens" in the help, "all 179 tools" on a 62-tool
# read-only server — and both were wrong by the time anyone checked. The help now states no
# size at all, and the start-up line measures the listing it is about to serve.

private def banner(spec : String?, read_only = false) : String
  filter = spec.try do |sp|
    Gori::MCP::ToolFilter.parse(sp, Gori::MCP::Tools::TOOL_NAMES,
      Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
  end
  Gori::CLI.mcp_catalogue_banner(filter, read_only)
end

private def kb_of(spec : String?, allow_actions = true) : Int32
  filter = spec.try do |sp|
    Gori::MCP::ToolFilter.parse(sp, Gori::MCP::Tools::TOOL_NAMES,
      Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
  end
  Gori::MCP::Tools.catalogue_kb(Gori::MCP::Tools.catalogue_json(filter, allow_actions).bytesize)
end

describe "gori mcp catalogue wording" do
  total = Gori::MCP::Tools::TOOL_NAMES.size

  describe "--tools help" do
    help = Gori::CLI.mcp_tools_help

    it "names every profile beside its summary" do
      Gori::MCP::ToolFilter::PROFILES.each do |profile|
        # At least two spaces between name and summary: a fixed-width `ljust` pads only a
        # SHORTER value, so a long name used to run straight into its text.
        help.should match(/@#{profile.name} {2,}#{Regex.escape(profile.summary)}/)
      end
    end

    it "states no size, since a compiled-in number is the one that drifts" do
      help.should_not match(/\d\s*(KB|tokens|k\b)/)
    end

    it "explains required companions and conflicting exclusions" do
      help.should contain("Required companions are included automatically")
      help.should contain("conflicting explicit exclusions are refused")
    end
  end

  describe "the start-up line" do
    it "weighs the whole catalogue and points at the profiles" do
      line = banner(nil)
      line.should contain("advertising all #{total} tools (tools/list ~#{kb_of(nil)} KB)")
      line.should contain(Gori::MCP::ToolFilter.profile_names)
    end

    # The gate is part of the count AND the weight: a read-only server is a smaller catalogue.
    it "counts and weighs what --read-only actually serves" do
      served = Gori::MCP::Tools.served_names(nil, allow_actions: false).size
      banner(nil, read_only: true).should contain(
        "advertising #{served} of #{total} tools (--read-only) (tools/list ~#{kb_of(nil, false)} KB)")
    end

    it "weighs a profile" do
      served = Gori::MCP::ToolFilter::MINIMAL.size
      banner("@minimal").should contain(
        "--tools=@minimal advertises #{served} of #{total} tools (tools/list ~#{kb_of("@minimal")} KB)")
    end

    # A one-tool spec is a few hundred bytes, which rounds to zero KB: the line whose job is
    # the cost said there was none.
    it "says bytes, not ~0 KB, for a catalogue under half a KB" do
      line = banner("delete_note")
      line.should_not contain("~0 KB")
      line.should match(/tools\/list \d+ bytes/)
    end
  end
end
