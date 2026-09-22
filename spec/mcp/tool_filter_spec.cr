require "../spec_helper"

# `gori mcp --tools=SPEC`. The catalogue is JSON an MCP client parks in the model's context
# for the whole session before a single question is asked — how much is measured, not written
# here (spec/mcp/catalogue_size_spec.cr) — and `--read-only` was the only lever, cutting along
# one axis only.

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

  # Named profiles (#1137): a small catalogue an operator can pick without knowing the
  # registry's naming, resolved as one more kind of term.
  describe "profiles" do
    profiles = Gori::MCP::ToolFilter::PROFILES

    it "selects exactly a profile's tools, and composes with other terms" do
      recon = profiles.find! { |pr| pr.name == "recon" }
      names_for("@recon").should eq(recon.tools.sort)
      names_for("@minimal,send_request").should contain("send_request")
      names_for("@recon,-send_request").should_not contain("send_request")
      # A leading subtraction starts from everything, as it does for a glob.
      rest = names_for("-@minimal")
      rest.size.should eq(Gori::MCP::Tools::TOOL_NAMES.size - Gori::MCP::ToolFilter::MINIMAL.size)
      rest.should_not contain("list_history")
    end

    # A profile member `known` lacks would abort `gori mcp` at start-up with a refusal the
    # operator can do nothing about — so every member has to be a tool that exists, and a
    # profile names each at most once.
    it "names only real tools" do
      profiles.each do |profile|
        profile.tools.uniq.size.should eq(profile.tools.size), "@#{profile.name} repeats a tool"
        (profile.tools - Gori::MCP::Tools::TOOL_NAMES).should be_empty, "@#{profile.name} names a tool that does not exist"
      end
    end

    # A glob inside a profile would let it grow with the registry, the silent growth a
    # profile exists to rule out.
    it "names tools, never globs" do
      profiles.each do |profile|
        profile.tools.none?(&.includes?('*')).should be_true, "@#{profile.name} carries a glob"
      end
    end

    it "keeps @minimal inside @recon" do
      recon = profiles.find! { |pr| pr.name == "recon" }
      (Gori::MCP::ToolFilter::MINIMAL - recon.tools).should be_empty
    end

    # A profile has to survive every start it can be handed: unbound (#1136 — and BOTH
    # pickers, because `switch_project` has nothing to switch to on a host with no project yet,
    # where only `create_project` gets the agent out) and `--read-only` (a profile of gated
    # tools would abort).
    it "works unbound and under --read-only" do
      profiles.each do |profile|
        (Gori::MCP::Tools::PROJECT_PICKERS - profile.tools).should be_empty,
          "@#{profile.name} leaves out a project picker"
        filter = Gori::MCP::ToolFilter.parse("@#{profile.name}", Gori::MCP::Tools::TOOL_NAMES).as(Gori::MCP::ToolFilter)
        served = Gori::MCP::Tools.served_names(filter, allow_actions: false)
        served.should contain("project_info")
        served.should contain("list_history")
      end
    end

    it "refuses an unknown profile, and a profile named without its sigil" do
      refusal_for("@recn").should contain("did you mean @recon")
      refusal_for("@nope").should contain("unknown profile")
      refusal_for("@nope").should contain("@minimal, @recon")
      refusal_for("-@nope").should contain("unknown profile")
      refusal_for("recon").should contain("did you mean @recon")
    end

    it "refuses a profile against a registry that lacks one of its tools" do
      # Only reachable through a gori bug (the example above pins the real registry), and
      # then refused rather than served short.
      refusal_for("@minimal", ["list_history", "get_flow"]).should contain("does not serve")
    end
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

  # `--tools` names tools; `--read-only` withholds them. Folding the gate into the name table
  # `parse` resolves against made every action tool read as a MISSPELLING — including both
  # examples `gori mcp --tools` prints in its own help — so the two are kept apart and put
  # together in exactly one place.
  describe "composing with --read-only" do
    it "resolves an action tool's name that the gate will then withhold" do
      # What `gori mcp` passes, and the whole of the fix: the full catalogue. Against the
      # read-only subset this answered `"send_request" matches no tool`, which is the
      # sentence a typo gets.
      spec = "list_*,get_*,send_request"
      filter = Gori::MCP::ToolFilter.parse(spec, Gori::MCP::Tools::TOOL_NAMES)
      filter.should be_a(Gori::MCP::ToolFilter)
      filter = filter.as(Gori::MCP::ToolFilter)
      filter.names.should contain("send_request")

      served = Gori::MCP::Tools.served_names(filter, allow_actions: false)
      served.should_not contain("send_request") # withheld, not unknown
      served.should contain("list_history")
    end

    # The one combination that still leaves nothing to serve — and the reason `gori mcp`
    # refuses it by name rather than starting a server with an empty catalogue.
    it "serves nothing when every selected tool is gated" do
      filter = Gori::MCP::ToolFilter.parse("fuzz_*", Gori::MCP::Tools::TOOL_NAMES).as(Gori::MCP::ToolFilter)
      Gori::MCP::Tools.served_names(filter, allow_actions: false).should be_empty
      Gori::MCP::Tools.served_names(filter, allow_actions: true).should_not be_empty
    end

    # The invariant the start-up banner and the `instructions` count both now rest on: this
    # is the same set `tools/list` emits, for every combination of the two flags. The banner
    # promised "all 179 tools" on a server about to advertise 62 because it counted the
    # registry instead.
    it "counts exactly what tools/list carries, under either flag" do
      with_store do |store|
        {nil, "list_*,get_*,send_request", "-fuzz_*,-mine_*", "*"}.each do |spec|
          filter = spec.try { |sp| Gori::MCP::ToolFilter.parse(sp, Gori::MCP::Tools::TOOL_NAMES).as(Gori::MCP::ToolFilter) }
          {true, false}.each do |allow_actions|
            tools = Gori::MCP::Tools.new(store, allow_actions, false, tool_filter: filter)
            listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s).sort!
            expected = Gori::MCP::Tools.served_names(filter, allow_actions).sort
            listed.should eq(expected), "--tools=#{spec.inspect} allow_actions=#{allow_actions}"
            tools.served_count.should eq(listed.size)
            listed.each { |n| tools.serves?(n).should be_true }
          end
        end
      end
    end
  end
end
