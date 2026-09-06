require "../spec_helper"

# `gori mcp --tools=SPEC`. The catalogue is ~172 KB of JSON — about 43,000 tokens an MCP
# client parks in the model's context for the whole session before a single question is
# asked — and `--read-only` was the only lever, cutting along one axis only.

private def names_for(spec : String, known = Gori::MCP::Tools::TOOL_NAMES) : Array(String)
  f = Gori::MCP::ToolFilter.parse(spec, known)
  fail "expected a filter, got: #{f}" unless f.is_a?(Gori::MCP::ToolFilter)
  f.names
end

private def refusal_for(spec : String, known = Gori::MCP::Tools::TOOL_NAMES) : String
  f = Gori::MCP::ToolFilter.parse(spec, known)
  fail "expected a refusal, got a filter of #{f.size}" if f.is_a?(Gori::MCP::ToolFilter)
  f
end

describe Gori::MCP::ToolFilter do
  it "selects by exact name and by prefix glob" do
    names_for("list_history,get_flow").should eq(["get_flow", "list_history"])
    kept = names_for("intercept_*")
    kept.should contain("intercept_list")
    kept.should contain("intercept_forward")
    kept.should_not contain("list_history")
  end

  it "starts from EVERYTHING when the first term subtracts" do
    all = Gori::MCP::Tools::TOOL_NAMES.size
    kept = names_for("-fuzz_*,-mine_*")
    kept.size.should be < all
    kept.should contain("list_history") # never named, still present
    kept.any?(&.starts_with?("fuzz_")).should be_false
    kept.any?(&.starts_with?("mine_")).should be_false
  end

  it "applies terms left to right, so a later subtraction wins" do
    names_for("list_*,-list_history").should_not contain("list_history")
    # …and a later addition puts one back.
    names_for("-list_*,list_history").should contain("list_history")
  end

  it "anchors a glob at both ends" do
    known = ["list_history", "x_list_history", "list_history_x"]
    names_for("list_*", known).should eq(["list_history", "list_history_x"])
    names_for("*_history", known).should eq(["list_history", "x_list_history"])
    names_for("*", known).size.should eq(3)
  end

  # The failure this exists to prevent: a server quietly advertising a handful of tools
  # because a name was misspelled reads to the agent exactly like a gori without the feature.
  it "refuses a pattern that matches nothing, and suggests the near miss" do
    refusal_for("list_hisotry").should contain("did you mean list_history")
    refusal_for("history").should contain("list_history") # a family stem, via substring
    refusal_for("zzzzzzzz").should contain("matches no tool")
  end

  it "refuses a spec that would advertise nothing" do
    refusal_for("list_*,-list_*").should contain("selects no tools")
    refusal_for("  ").should contain("no tool patterns")
  end

  describe "served through Tools" do
    it "hides the unselected from tools/list but still refuses them by name" do
      with_store do |store|
        filter = Gori::MCP::ToolFilter.parse("list_*,get_*", Gori::MCP::Tools::TOOL_NAMES)
        filter = filter.as(Gori::MCP::ToolFilter)
        tools = Gori::MCP::Tools.new(store, true, false, tool_filter: filter)

        listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
        listed.should contain("list_history")
        listed.should_not contain("fuzz_start")

        # Absent from the listing is not the same as absent from dispatch: `declared_args` is
        # harvested from `list`, so without an explicit refusal a hidden tool would run with
        # every argument unvalidated.
        r = tools.call("fuzz_start", JSON.parse("{}"))
        r.is_error.should be_true
        r.error_code.should eq("UNKNOWN_TOOL")
        r.text.should contain("--tools=")

        # A name that is not a tool at all still reads as one.
        tools.call("no_such_tool", JSON.parse("{}")).text.should contain("unknown tool")

        # And a tool that IS served still validates its arguments.
        bad = tools.call("list_history", JSON.parse(%({"bogus":1})))
        bad.is_error.should be_true
        bad.text.should contain("unknown argument")
      end
    end

    it "leaves every tool served when no filter is given" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, true, false)
        listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
        listed.size.should eq(Gori::MCP::Tools::TOOL_NAMES.size)
      end
    end
  end
end
