require "../spec_helper"

# An UNBOUND server whose catalogue was narrowed by `--tools` (#1136, #1142).
#
# Two different mistakes used to arrive as the same sentence. `Tools#call` ran the project
# gate before it had decided what the NAME was, so on an unbound server a typo and a tool
# the filter had removed both came back "no project bound; call list_projects,
# create_project, or switch_project first" — sending the agent to bind a project so it could
# retry a call that was never going to exist. And that recovery named three tools whatever
# the server was serving, two of which then answered `-32602 unknown tool`.
#
# So: classify the name first (it belongs to the transport, which turns UNKNOWN_TOOL into
# -32602), and name only the binders `tools/list` actually carries.
private def unbound_tools(spec : String?, allow_actions = true, &)
  root = File.tempname("gori-unbound-filter")
  Dir.mkdir_p(root)
  prev = ENV["GORI_HOME"]?
  ENV["GORI_HOME"] = root
  filter = spec.try do |s|
    f = Gori::MCP::ToolFilter.parse(s, Gori::MCP::Tools::TOOL_NAMES,
      Gori::MCP::Tools::TOOL_DEPENDENCIES)
    fail "expected a filter, got: #{f}" unless f.is_a?(Gori::MCP::ToolFilter)
    f
  end
  begin
    yield Gori::MCP::Tools.new(nil, allow_actions: allow_actions, verify_upstream: false,
      selection_source: "unbound", tool_filter: filter)
  ensure
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(root)
  end
end

# `instructions` is assembled by the Server, which builds its own Tools — so this reaches it
# the way a client does: one `server/discover`, answered in both eras and needing no handshake.
private def unbound_instructions(spec : String) : String
  filter = Gori::MCP::ToolFilter.parse(spec, Gori::MCP::Tools::TOOL_NAMES,
    Gori::MCP::Tools::TOOL_DEPENDENCIES)
  fail "expected a filter, got: #{filter}" unless filter.is_a?(Gori::MCP::ToolFilter)
  input = IO::Memory.new(%({"jsonrpc":"2.0","id":1,"method":"server/discover"}\n))
  output = IO::Memory.new
  Gori::MCP::Server.new(nil, allow_actions: true, verify_upstream: false,
    selection_source: "unbound", tool_filter: filter, input: input, output: output).run
  JSON.parse(output.to_s.each_line.reject(&.strip.empty?).first)["result"]["instructions"].as_s
end

describe "MCP unbound server with a filtered catalogue" do
  it "keeps an unknown name and a filtered-out tool as UNKNOWN_TOOL, not NO_PROJECT" do
    unbound_tools("list_projects") do |tools|
      typo = tools.call("not_a_tool", JSON.parse("{}"))
      typo.is_error.should be_true
      typo.error_code.should eq("UNKNOWN_TOOL")

      # A REAL tool the filter removed. It needs a project too, which is exactly why the
      # old order hid it: the gate answered before the filter was consulted.
      hidden = tools.call("get_flow", JSON.parse(%({"id":1})))
      hidden.is_error.should be_true
      hidden.error_code.should eq("UNKNOWN_TOOL")
      hidden.text.should contain("--tools=")
    end
  end

  it "still answers NO_PROJECT for a SERVED tool that needs a project" do
    unbound_tools("list_*,switch_project") do |tools|
      r = tools.call("list_history", JSON.parse("{}"))
      r.is_error.should be_true
      r.error_code.should eq("NO_PROJECT")
      # …and the recovery names only what this server serves.
      r.text.should contain("list_projects, switch_project")
      r.text.should_not contain("create_project")
    end
  end

  it "names all three binders when the catalogue is whole" do
    unbound_tools(nil) do |tools|
      r = tools.call("list_history", JSON.parse("{}"))
      r.error_code.should eq("NO_PROJECT")
      %w[list_projects create_project switch_project].each { |n| r.text.should contain(n) }
    end
  end

  # `list_projects` LISTS; it binds nothing. A server that serves it alone can hand the agent
  # a page of projects and then refuse every one of them, which is the retry loop this pair of
  # issues exists to stop — arrived at from the other side. So the picker, not the lister,
  # decides whether a recovery exists.
  it "does not offer list_projects as a recovery when no picker is served" do
    unbound_tools("list_*") do |tools|
      tools.unbindable?.should be_true
      r = tools.call("list_history", JSON.parse("{}"))
      r.error_code.should eq("NO_PROJECT")
      r.text.should contain("no project-selection tool")
      r.text.should_not contain("call list_projects")
    end
  end

  it "says the recovery is the OPERATOR's when no binder is advertised at all" do
    unbound_tools("list_history,project_info") do |tools|
      r = tools.call("list_history", JSON.parse("{}"))
      r.error_code.should eq("NO_PROJECT")
      r.text.should contain("no project-selection tool")
      r.text.should contain("--project")

      # project_info is the tool an agent orients itself with, so it must not disagree.
      info = JSON.parse(tools.call("project_info", JSON.parse("{}")).text)
      info["bound"].as_bool.should be_false
      info["note"].as_s.should contain("no project-selection tool")
    end
  end

  # …and neither may `instructions`, which is the FIRST text the model reads. It used to drop
  # the recovery sentence whole here, so the model learned "no project is bound" and had to
  # discover one refusal at a time that nothing it could call would change that.
  it "says the same thing in the server instructions" do
    unbound_tools("list_history,project_info") do |tools|
      tools.unbindable?.should be_true
      text = unbound_instructions("list_history,project_info")
      text.should contain("No project is bound yet.")
      text.should contain("no project-selection tool")
    end
  end

  it "keeps the recovery clause in the tool DESCRIPTIONS honest too" do
    # `list_projects` and `project_info` are the two tools whose description tells an agent
    # how to leave the unbound state. They read the same sentence the error does, so a
    # server that has kept one binder cannot advertise three.
    unbound_tools("list_projects,project_info,switch_project") do |tools|
      described = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
        .to_h { |t| {t["name"].as_s, t["description"].as_s} }
      recovery = "call list_projects, switch_project before traffic tools"
      described["list_projects"].should contain(recovery)
      described["project_info"].should contain("(bound:false), #{recovery}")
      described["switch_project"].should_not contain("create_project")
    end
  end
end
